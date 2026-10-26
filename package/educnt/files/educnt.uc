#!/usr/bin/ucode
// educnt - OpenWrt 校园网（深澜 SRUN）自动登录工具
// 纯 ucode 实现，无 Node.js / 无浏览器依赖；仅需 curl 用于按网卡绑定源地址。
//
// 用法：
//   educnt status           查看各线路在线状态
//   educnt login            未在线则登录（默认）
//   educnt logout           注销
//   educnt reauth           先注销再登录（推荐定时任务使用）
//   educnt login wan        只操作某一条逻辑线路（wan / wanb / wanc）
//   educnt -v ...           输出调试信息

'use strict';

let fs = require('fs');
let digest = require('digest');

const CONF_PATH = '/etc/educnt.conf';
const LOG_PATH = '/tmp/educnt.log';
const DEFAULT_PORTAL = 'https://xyw.hainanu.edu.cn';

// ---------------------------------------------------------------- 基础工具

let DEBUG = false;

function now_str() {
	let lt = localtime(time());
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		lt.year, lt.mon, lt.mday, lt.hour, lt.min, lt.sec);
}

function logmsg(level, msg) {
	let line = sprintf('[%s] [%s] %s\n', now_str(), level, msg);
	try {
		let f = fs.open(LOG_PATH, 'a');
		f.write(line);
		f.close();
	} catch (e) { }
	warn(line);
}

function dbg(msg) {
	if (DEBUG)
		logmsg('DBG', msg);
}

function shellquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function nz(v, fallback) {
	if (v == null || v == '')
		return fallback;
	return v;
}

function json_escape(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let ch = substr(s, i, 1);
		let c = ord(ch);
		if (ch == '"' || ch == '\\')
			out += '\\' + ch;
		else if (c < 0x20)
			out += sprintf('\\u%04x', c);
		else
			out += ch;
	}
	return out;
}

// 读取 "KEY='value'" 形式的配置文件
function load_conf() {
	let conf = {};
	let raw;
	try {
		raw = fs.readfile(CONF_PATH);
	} catch (e) {
		logmsg('ERR', '无法读取配置 ' + CONF_PATH + ': ' + e);
		exit(2);
	}
	let lines = split(raw, '\n');
	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);
		if (line == '' || substr(line, 0, 1) == '#')
			continue;
		let pos = index(line, '=');
		if (pos < 0)
			continue;
		let key = trim(substr(line, 0, pos));
		let val = trim(substr(line, pos + 1));
		if (length(val) >= 2) {
			let q = substr(val, 0, 1);
			if ((q == "'" || q == '"') && substr(val, length(val) - 1, 1) == q)
				val = substr(val, 1, length(val) - 2);
		}
		conf[key] = val;
	}
	return conf;
}

// ---------------------------------------------------------------- 加密原语

// 字符串 -> UTF-8 字节数组
function to_bytes(s) {
	let out = [];
	let n = length(s);
	for (let i = 0; i < n; i++)
		push(out, ord(substr(s, i, 1)) & 0xff);
	return out;
}

function bytes_to_hex(b) {
	let out = '';
	for (let i = 0; i < length(b); i++)
		out += sprintf('%02x', b[i]);
	return out;
}

function concat_bytes(a, b) {
	let out = [];
	for (let i = 0; i < length(a); i++) push(out, a[i]);
	for (let i = 0; i < length(b); i++) push(out, b[i]);
	return out;
}

function u32(x) {
	return (x | 0) & 0xFFFFFFFF;
}

// MD5（输入/输出均为字节数组）
const MD5_S = [
	7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
	5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
	4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
	6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
];

const MD5_K = [
	0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
	0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
	0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
	0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
	0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
	0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
	0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
	0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
];

function md5_raw(bytes) {
	let n = length(bytes);
	let msg = [];
	for (let i = 0; i < n; i++) msg[i] = bytes[i] & 0xff;
	let ml = n;
	msg[ml] = 0x80;
	ml++;
	while ((ml % 64) != 56) { msg[ml] = 0; ml++; }
	let bits = n * 8;
	let lo = u32(bits);
	let hi = int(bits / 4294967296);
	for (let i = 0; i < 4; i++) msg[ml + i] = (lo >> (8 * i)) & 0xff;
	for (let i = 0; i < 4; i++) msg[ml + 4 + i] = (hi >> (8 * i)) & 0xff;
	ml += 8;

	let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

	for (let chunk = 0; chunk < ml; chunk += 64) {
		let M = [];
		for (let j = 0; j < 16; j++) {
			let o = chunk + j * 4;
			M[j] = u32(msg[o] | (msg[o + 1] << 8) | (msg[o + 2] << 16) | (msg[o + 3] << 24));
		}
		let A = a0, B = b0, C = c0, D = d0;
		for (let i = 0; i < 64; i++) {
			let F, g;
			if (i < 16) {
				F = (B & C) | ((~B) & D);
				g = i;
			} else if (i < 32) {
				F = (D & B) | ((~D) & C);
				g = (5 * i + 1) % 16;
			} else if (i < 48) {
				F = B ^ C ^ D;
				g = (3 * i + 5) % 16;
			} else {
				F = C ^ (B | (~D));
				g = (7 * i) % 16;
			}
			F = u32(F + A + MD5_K[i] + M[g]);
			let sh = MD5_S[i];
			let rot = u32((F << sh) | (F >> (32 - sh)));
			A = D; D = C; C = B;
			B = u32(B + rot);
		}
		a0 = u32(a0 + A);
		b0 = u32(b0 + B);
		c0 = u32(c0 + C);
		d0 = u32(d0 + D);
	}

	let vals = [a0, b0, c0, d0];
	let out = [];
	for (let i = 0; i < 4; i++) {
		let v = vals[i];
		push(out, v & 0xff);
		push(out, (v >> 8) & 0xff);
		push(out, (v >> 16) & 0xff);
		push(out, (v >> 24) & 0xff);
	}
	return out;
}

function md5_hex(str) {
	return bytes_to_hex(md5_raw(to_bytes(str)));
}

// HMAC-MD5（站点前端 md5(password, token) = HMAC(key=token, msg=password)）
function hmac_md5_raw(key_bytes, msg_bytes) {
	let key = key_bytes;
	if (length(key) > 64)
		key = md5_raw(key);
	let kb = [];
	for (let i = 0; i < 64; i++)
		kb[i] = i < length(key) ? key[i] : 0;
	let ipad = [], opad = [];
	for (let i = 0; i < 64; i++) {
		ipad[i] = kb[i] ^ 0x36;
		opad[i] = kb[i] ^ 0x5c;
	}
	let inner = md5_raw(concat_bytes(ipad, msg_bytes));
	return md5_raw(concat_bytes(opad, inner));
}

function hmac_md5_hex(key_str, msg_str) {
	return bytes_to_hex(hmac_md5_raw(to_bytes(key_str), to_bytes(msg_str)));
}

// XXTEA（对应 Portal.js 的 encode(str, key)）
function xxtea_encrypt_bytes(data, key_str) {
	let v = [];
	let c = length(data);
	for (let i = 0; i < c; i += 4) {
		let w = data[i];
		if (i + 1 < c) w |= (data[i + 1] << 8);
		if (i + 2 < c) w |= (data[i + 2] << 16);
		if (i + 3 < c) w |= (data[i + 3] << 24);
		v[i >> 2] = u32(w);
	}
	v[length(v)] = c;

	let key_bytes = to_bytes(key_str);
	let key_words = int((length(key_bytes) + 3) / 4);
	if (key_words < 4)
		key_words = 4;
	let kk = [];
	for (let i = 0; i < key_words; i++) {
		let w = 0;
		let base = i * 4;
		for (let j = 0; j < 4; j++) {
			let b = (base + j < length(key_bytes)) ? key_bytes[base + j] : 0;
			w |= b << (8 * j);
		}
		kk[i] = u32(w);
	}

	let n = length(v) - 1;
	let z = v[n];
	let y = v[0];
	let delta = 0x9E3779B9;
	let rounds = 6 + int(52 / (n + 1));
	let sum = 0;
	let p = 0;

	for (let q = 0; q < rounds; q++) {
		sum = u32(sum + delta);
		let e = (sum >> 2) & 3;
		for (p = 0; p < n; p++) {
			y = v[p + 1];
			let m = u32((z >> 5) ^ u32(y << 2));
			m = u32(m + u32((y >> 3) ^ u32(z << 4) ^ (sum ^ y)));
			m = u32(m + u32(kk[(p & 3) ^ e] ^ z));
			z = v[p] = u32(v[p] + m);
		}
		y = v[0];
		let m2 = u32((z >> 5) ^ u32(y << 2));
		m2 = u32(m2 + u32((y >> 3) ^ u32(z << 4) ^ (sum ^ y)));
		m2 = u32(m2 + u32(kk[(p & 3) ^ e] ^ z));
		z = v[n] = u32(v[n] + m2);
	}

	let out = [];
	for (let i = 0; i <= n; i++) {
		push(out, v[i] & 0xff);
		push(out, (v[i] >> 8) & 0xff);
		push(out, (v[i] >> 16) & 0xff);
		push(out, (v[i] >> 24) & 0xff);
	}
	return out;
}

const B64_ALPHA = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA';

function b64_custom(bytes) {
	let out = '';
	let n = length(bytes);
	for (let i = 0; i < n; i += 3) {
		let b0 = bytes[i];
		let b1 = 0;
		let b2 = 0;
		if (i + 1 < n) b1 = bytes[i + 1];
		if (i + 2 < n) b2 = bytes[i + 2];
		let v = (b0 << 16) | (b1 << 8) | b2;
		out += substr(B64_ALPHA, (v >> 18) & 63, 1);
		out += substr(B64_ALPHA, (v >> 12) & 63, 1);
		if (i + 1 < n)
			out += substr(B64_ALPHA, (v >> 6) & 63, 1);
		else
			out += '=';
		if (i + 2 < n)
			out += substr(B64_ALPHA, v & 63, 1);
		else
			out += '=';
	}
	return out;
}

// ---------------------------------------------------------------- 网络

function http_get(dev, url, params) {
	let cmd = sprintf("curl -4 -sS --connect-timeout 5 --max-time %d --interface %s -G %s",
		12, shellquote(dev), shellquote(url));
	if (params) {
		let ks = keys(params);
		for (let i = 0; i < length(ks); i++) {
			let k = ks[i];
			cmd += ' --data-urlencode ' + shellquote(k + '=' + params[k]);
		}
	}
	cmd += ' 2>/dev/null';
	dbg('HTTP ' + cmd);
	for (let attempt = 0; attempt < 3; attempt++) {
		let p = fs.popen(cmd);
		let out = p.read('all');
		let rc = p.close();
		if (rc == 0 && out != null && out != '')
			return out;
		dbg(sprintf('HTTP 第 %d 次失败 (rc=%s)，重试', attempt + 1, rc));
		sleep(2);
	}
	return null;
}

function unwrap_jsonp(s) {
	if (s == null)
		return null;
	let i = index(s, '(');
	let j = rindex(s, ')');
	if (i < 0 || j <= i)
		return null;
	let body = substr(s, i + 1, j - i - 1);
	try {
		return json(body);
	} catch (e) {
		dbg('JSON parse failed: ' + body);
		return null;
	}
}

function iface_ip(dev) {
	let p = fs.popen("ip -4 addr show dev " + shellquote(dev) + " 2>/dev/null");
	let out = p.read('all');
	p.close();
	if (out == null)
		return null;
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		let line = lines[i];
		let pos = index(line, 'inet ');
		if (pos < 0)
			continue;
		let rest = substr(line, pos + 5);
		let sp = index(rest, '/');
		if (sp < 0)
			continue;
		return substr(rest, 0, sp);
	}
	return null;
}

// 确保本机发往门户的包按绑定的源地址走对应 WAN 表，避免被 mwan3 改写到已在线的其他 WAN
function ensure_routing(targets, portal) {
	let host = replace(portal, /^https?:\/\//, '');
	let slash = index(host, '/');
	if (slash >= 0) host = substr(host, 0, slash);
	let colon = index(host, ':');
	if (colon >= 0) host = substr(host, 0, colon);

	let p = fs.popen('nslookup ' + shellquote(host) + ' 2>/dev/null');
	let out = p.read('all');
	p.close();
	let portal_ips = ['210.37.41.66'];
	if (out != null) {
		let seen_name = false;
		let lines = split(out, '\n');
		for (let i = 0; i < length(lines); i++) {
			let l = trim(lines[i]);
			if (substr(l, 0, 5) == 'Name:')
				seen_name = true;
			else if (seen_name && substr(l, 0, 8) == 'Address:') {
				let a = trim(substr(l, 8));
				if (index(a, ':') < 0 && index(a, '.') >= 0)
					push(portal_ips, a);
			}
		}
	}
	for (let i = 0; i < length(portal_ips); i++) {
		let cmd = 'ipset add mwan3_custom_ipv4 ' + shellquote(portal_ips[i]) + ' -exist 2>/dev/null';
		let h = fs.popen(cmd);
		h.read('all');
		h.close();
	}

	// 为每条线路建立高优先级源地址策略路由（pref 510+i -> table i+1）
	for (let i = 0; i < length(targets); i++) {
		let ip = iface_ip(targets[i].dev);
		if (ip == null)
			continue;
		let pref = 510 + i;
		let tbl = i + 1;
		let cmd = sprintf('ip rule del pref %d 2>/dev/null; ip rule add from %s lookup %d pref %d 2>/dev/null',
			pref, shellquote(ip), tbl, pref);
		let h = fs.popen(cmd);
		h.read('all');
		h.close();
	}
}

// ---------------------------------------------------------------- 认证流程

function get_challenge(dev, ip, username, portal) {
	let raw = http_get(dev, portal + '/cgi-bin/get_challenge', {
		callback: 'cb',
		username: username,
		ip: ip
	});
	dbg('challenge raw: ' + nz(raw, '(null)'));
	let r = unwrap_jsonp(raw);
	if (r == null)
		return null;
	if (r.error && r.error != 'ok')
		return null;
	return r.challenge;
}

function do_login(conf, target) {
	let dev = target.dev;
	let iface = target.iface;
	let ip = iface_ip(dev);
	if (ip == null) {
		logmsg('ERR', sprintf('%s(%s) 没有 IPv4 地址，跳过', iface, dev));
		return false;
	}
	let username = conf.USERNAME + nz(conf.DOMAIN, '');
	let password = conf.PASSWORD;
	let acid = nz(conf.AC_ID, '1');
	let portal = nz(conf.PORTAL, DEFAULT_PORTAL);

	let challenge = get_challenge(dev, ip, username, portal);
	if (challenge == null) {
		logmsg('ERR', sprintf('%s 获取 challenge 失败（网络不通或被拦截）', iface));
		return false;
	}
	dbg(sprintf('%s challenge=%s', iface, challenge));

	let hmd5 = hmac_md5_hex(challenge, password);
	// 与浏览器 JSON.stringify 完全一致的紧凑 JSON（注意 acid 在 Portal.js 里是字符串，例如 "1"）
	let info_json = '{"username":"' + json_escape(username) + '","password":"' +
		json_escape(password) + '","ip":"' + json_escape(ip) + '","acid":"' +
		json_escape('' + acid) + '","enc_ver":"srun_bx1"}';
	let info = '{SRBX1}' + b64_custom(xxtea_encrypt_bytes(to_bytes(info_json), challenge));

	let n = '200', type = '1';
	let chk = challenge + username + challenge + hmd5 + challenge + acid +
		challenge + ip + challenge + n + challenge + type + challenge + info;
	let chksum = digest.sha1(chk);

	let resp = unwrap_jsonp(http_get(dev, portal + '/cgi-bin/srun_portal', {
		callback: 'cb',
		action: 'login',
		username: username,
		password: '{MD5}' + hmd5,
		os: 'Linux',
		name: 'Linux',
		double_stack: '0',
		chksum: chksum,
		info: info,
		ac_id: acid,
		ip: ip,
		n: n,
		type: type
	}));

	if (resp == null) {
		logmsg('ERR', sprintf('%s 登录请求无响应', iface));
		return false;
	}
	let code = '';
	if (resp.error)
		code = resp.error;
	else if (resp.ecode)
		code = resp.ecode;
	let suc = '';
	if (resp.suc_msg)
		suc = resp.suc_msg;
	if (code == 'ok' || suc == 'login_ok') {
		logmsg('OK', sprintf('%s (%s) 登录成功', iface, ip));
		return true;
	}
	if (code == 'ip_already_online_error' || resp.error_msg == 'ip_already_online_error' ||
	    resp.ecode == 'E2620' || index(nz(resp.error_msg, ''), 'already online') >= 0) {
		logmsg('OK', sprintf('%s (%s) 已在线', iface, ip));
		return true;
	}
	logmsg('ERR', sprintf('%s 登录失败: error=%s ecode=%s msg=%s',
		iface, code, nz(resp.ecode, ''), nz(resp.error_msg, '')));
	return false;
}

function do_logout(conf, target) {
	let dev = target.dev;
	let iface = target.iface;
	let ip = iface_ip(dev);
	if (ip == null)
		return false;
	let username = conf.USERNAME + nz(conf.DOMAIN, '');
	let acid = nz(conf.AC_ID, '1');
	let portal = nz(conf.PORTAL, DEFAULT_PORTAL);

	let resp = unwrap_jsonp(http_get(dev, portal + '/cgi-bin/srun_portal', {
		callback: 'cb',
		action: 'logout',
		username: username,
		ip: ip,
		ac_id: acid
	}));
	if (resp == null) {
		logmsg('ERR', sprintf('%s 注销请求无响应', iface));
		return false;
	}
	if (resp.error == 'ok') {
		logmsg('OK', sprintf('%s (%s) 注销成功', iface, ip));
		return true;
	}
	logmsg('WARN', sprintf('%s 注销返回: %s', iface, nz(resp.error, nz(resp.ecode, 'unknown'))));
	return false;
}

function do_status(conf, target) {
	let dev = target.dev;
	let iface = target.iface;
	let ip = iface_ip(dev);
	if (ip == null) {
		logmsg('WARN', sprintf('%s(%s) 无 IPv4 地址', iface, dev));
		return;
	}
	let portal = nz(conf.PORTAL, DEFAULT_PORTAL);
	let r = unwrap_jsonp(http_get(dev, portal + '/cgi-bin/rad_user_info', { callback: 'cb' }));
	if (r == null) {
		logmsg('WARN', sprintf('%s (%s) 查询失败/未认证', iface, ip));
		return;
	}
	if (r.error == 'ok') {
		let bytes = (r.all_bytes != null) ? r.all_bytes : ((r.sum_bytes != null) ? r.sum_bytes : '?');
		logmsg('INFO', sprintf('%s (%s) 在线  流量=%s  在线设备=%s',
			iface, ip, bytes, nz(r.online_device_total, '?')));
	} else {
		logmsg('WARN', sprintf('%s (%s) 未在线 (%s)', iface, ip, r.error));
	}
}

// ---------------------------------------------------------------- 主程序

const HELP_TEXT = join('\n', [
	'educnt - 海南大学校园网自动登录 (OpenWrt)',
	'',
	'用法:',
	'  educnt [选项] <命令> [线路]',
	'',
	'命令:',
	'  login  [线路]   登录；不带线路时依次登录全部线路（默认）',
	'  logout [线路]   注销；不带线路时依次注销全部线路',
	'  reauth [线路]   重新认证：逐条 注销 → 登录 → 确认在线 后才处理下一条',
	'  check  [线路]   仅在掉线时补登录（推荐放 cron）',
	'  status [线路]   查看在线状态（无需账号密码）',
	'  routing         仅重建门户分流路由（hotplug 调用，无需账号密码）',
	'',
	'选项:',
	'  -h, --help      显示本帮助',
	'  -v, --verbose   输出调试日志',
	'',
	'线路:',
	'  wan / wanb / wanc（对应配置 TARGETS 里的逻辑名）',
	'',
	'示例:',
	'  educnt                 登录全部三条线路',
	'  educnt reauth          三条线路逐条重认证（确认一条再下一条）',
	'  educnt reauth wanb     只重认证 wanb',
	'  educnt check           掉线才登录',
	'  educnt status          查看状态',
	'',
	'配置: /etc/educnt.conf    日志: /tmp/educnt.log'
]);

function do_check(conf, target) {
	let dev = target.dev;
	let ip = iface_ip(dev);
	if (ip == null)
		return false;
	let portal = nz(conf.PORTAL, DEFAULT_PORTAL);
	let r = unwrap_jsonp(http_get(dev, portal + '/cgi-bin/rad_user_info', { callback: 'cb' }));
	if (r != null && r.error == 'ok')
		return true;
	dbg(sprintf('%s (%s) 未在线，准备登录', target.iface, ip));
	return false;
}

function verify_online(conf, target, tries) {
	for (let i = 0; i < tries; i++) {
		sleep(2);
		if (do_check(conf, target))
			return true;
		dbg(sprintf('%s 第 %d 次在线确认未通过', target.iface, i + 1));
	}
	return false;
}

function wait_offline(conf, target, tries) {
	for (let i = 0; i < tries; i++) {
		sleep(2);
		if (!do_check(conf, target))
			return true;
	}
	return false;
}

function do_reauth(conf, target) {
	do_logout(conf, target);
	wait_offline(conf, target, 4);
	for (let attempt = 0; attempt < 2; attempt++) {
		if (do_login(conf, target) && verify_online(conf, target, 5)) {
			logmsg('OK', sprintf('%s 重认证完成并确认在线', target.iface));
			return true;
		}
		sleep(2);
	}
	logmsg('ERR', sprintf('%s 重认证后仍未确认在线', target.iface));
	return false;
}

function parse_targets(conf) {
	// TARGETS="wan:wan wanb:vwanb wanc:vwanc"  (逻辑名:设备名)
	let spec = nz(conf.TARGETS, 'wan:wan wanb:vwanb wanc:vwanc');
	let out = [];
	let items = split(trim(spec), ' ');
	for (let i = 0; i < length(items); i++) {
		let item = items[i];
		if (item == '')
			continue;
		let pos = index(item, ':');
		if (pos < 0)
			push(out, { iface: item, dev: item });
		else
			push(out, { iface: substr(item, 0, pos), dev: substr(item, pos + 1) });
	}
	return out;
}

function main() {
	let argv = [];
	let want_help = false;
	for (let i = 0; i < length(ARGV); i++) {
		let a = ARGV[i];
		if (a == '-h' || a == '--help' || a == 'help')
			want_help = true;
		else if (a == '-v' || a == '--verbose')
			DEBUG = true;
		else
			push(argv, a);
	}

	if (want_help) {
		print(HELP_TEXT, '\n');
		exit(0);
	}

	let action = 'login';
	if (length(argv) > 0)
		action = argv[0];
	let only = null;
	if (length(argv) > 1)
		only = argv[1];

	let known = ['status', 'login', 'logout', 'reauth', 'check', 'routing'];
	let valid = false;
	for (let i = 0; i < length(known); i++) {
		if (known[i] == action)
			valid = true;
	}
	if (!valid) {
		warn(sprintf("未知操作: %s\n\n", action));
		print(HELP_TEXT, '\n');
		exit(2);
	}

	let conf = load_conf();
	let need_cred = (action != 'status' && action != 'routing');
	if (need_cred && (!conf.USERNAME || !conf.PASSWORD)) {
		logmsg('ERR', '配置缺少 USERNAME / PASSWORD，请先运行 educnt-setup');
		exit(2);
	}

	let all = parse_targets(conf);
	ensure_routing(all, nz(conf.PORTAL, DEFAULT_PORTAL));
	if (action == 'routing') {
		logmsg('INFO', '门户路由规则已重建');
		exit(0);
	}
	let targets = [];
	for (let i = 0; i < length(all); i++) {
		if (only == null || all[i].iface == only)
			push(targets, all[i]);
	}
	if (length(targets) == 0) {
		logmsg('ERR', '没有匹配的线路: ' + nz(only, '(空)'));
		exit(2);
	}

	let ok = 0, fail = 0;
	for (let i = 0; i < length(targets); i++) {
		let t = targets[i];
		let r = false;
		if (action == 'status') {
			do_status(conf, t);
			r = true;
		} else if (action == 'logout') {
			r = do_logout(conf, t);
		} else if (action == 'reauth') {
			r = do_reauth(conf, t);
		} else if (action == 'login') {
			r = do_login(conf, t);
		} else if (action == 'check') {
			let online = do_check(conf, t);
			r = online;
			if (!online)
				r = do_login(conf, t);
		} else {
			logmsg('ERR', '未知操作: ' + action);
			exit(2);
		}
		if (r) ok++; else fail++;
		if (i + 1 < length(targets))
			sleep(2);
	}

	if (action != 'status')
		logmsg('INFO', sprintf('完成: 成功 %d，失败 %d', ok, fail));
	if (fail > 0)
		exit(1);
	exit(0);
}

main();
