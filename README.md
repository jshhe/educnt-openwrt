# educnt

海南大学校园网（深澜 SRUN）**OpenWrt 自动登录 / 定时重认证**工具。

纯 `ucode` 实现，**不需要 Node.js、不需要 Chrome/Playwright**。唯一额外依赖是 `curl`（约 145 KiB），用于按虚拟 WAN 绑定源地址。

> 已在 Xiaomi Mi Router 3G（ramips/mt7621，OpenWrt 25.12.5）上验证，支持单 WAN 与单线多拨（多 MAC 虚拟 WAN）。

---

## 特性

- **无需浏览器**：登录算法直接按门户前端 `Portal.js` 实现（HMAC-MD5 + XXTEA + 自定义 Base64 + SHA-1）
- **多 WAN 分别认证**：`curl --interface <dev>` 绑定源地址，`wan` / `vwanb` / `vwanc` 各认证各的
- **内置门户路由修复**：解决 `mwan3` 在只有一条线在线时把本机认证包改写到其它 WAN、导致 `curl rc=7` 的问题
- **逐条重认证**：`reauth` 对每条线路执行 注销 → 登录 → 确认在线，确认后才处理下一条
- **掉线自动补登**：后台服务每 30 分钟 `check` 一次，每天 04:30 自动 `reauth`
- **开机自启**：procd 托管，异常退出自动重启
- **密码文件权限 600**，日志写 `/tmp`（不磨损闪存）

---

## 安装

### 方式一：作为软件源（推荐）

在路由器上添加本仓库为 opkg/apk 软件源后安装。

**OpenWrt 24.10（opkg）**

```sh
# 先在本仓库 Releases 下载对应架构的 .ipk，或自行编译
opkg install educnt_*.ipk
```

**OpenWrt 25.12（apk）**

```sh
apk add --allow-untrusted educnt-*.apk
```

### 方式二：源码编译（OpenWrt SDK）

```sh
# 1. 下载对应版本的 SDK
wget https://downloads.openwrt.org/releases/25.12.5/targets/ramips/mt7621/openwrt-sdk-25.12.5-ramips-mt7621_gcc-14.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-25.12.5-ramips-mt7621_*.tar.zst
cd openwrt-sdk-25.12.5-ramips-mt7621_*

# 2. 添加本仓库为 feed
echo "src-link educnt /path/to/educnt-openwrt" >> feeds.conf
./scripts/feeds update educnt
./scripts/feeds install educnt

# 3. 编译
echo "CONFIG_PACKAGE_educnt=m" >> .config
make defconfig
make package/educnt/compile V=s -j$(nproc)
```

产物在 `bin/packages/<arch>/educnt/`。

本仓库的 GitHub Actions 已配置好，每次 push 会自动编译 **24.10.4（ipk）** 与 **25.12.5（apk）** 两种包；打 tag 会自动上传到 Release。

### 方式三：手动拷贝（临时调试）

```sh
mkdir -p /usr/share/educnt /etc/hotplug.d/iface
cp package/educnt/files/educnt.uc     /usr/share/educnt/
cp package/educnt/files/educnt        /usr/bin/
cp package/educnt/files/educnt-setup  /usr/bin/
cp package/educnt/files/daemon.sh     /usr/share/educnt/
cp package/educnt/files/educnt.init   /etc/init.d/educnt
cp package/educnt/files/90-educnt     /etc/hotplug.d/iface/
cp package/educnt/files/educnt.conf   /etc/educnt.conf
chmod +x /usr/bin/educnt /usr/bin/educnt-setup /etc/init.d/educnt /etc/hotplug.d/iface/90-educnt /usr/share/educnt/daemon.sh
```

---

## 配置

```sh
educnt-setup
```

按提示输入学号和密码，会自动：

- 写入 `/etc/educnt.conf`（权限 600）
- 自动识别 `vwanb` / `vwanc` 等虚拟网卡并写入 `TARGETS`
- 启用并启动 `educnt` 后台服务

也可以手动编辑 `/etc/educnt.conf`：

```sh
USERNAME='2025xxxxxxx'
PASSWORD='your-password'
AC_ID='1'
PORTAL='https://xyw.hainanu.edu.cn'
DOMAIN=''
# 逻辑名:设备名
TARGETS='wan:wan wanb:vwanb wanc:vwanc'
```

改完重启服务：

```sh
/etc/init.d/educnt restart
```

---

## 命令

```text
educnt - 海南大学校园网自动登录 (OpenWrt)

用法:
  educnt [选项] <命令> [线路]

命令:
  login  [线路]   登录；不带线路时依次登录全部线路（默认）
  logout [线路]   注销；不带线路时依次注销全部线路
  reauth [线路]   重新认证：逐条 注销 → 登录 → 确认在线 后才处理下一条
  check  [线路]   仅在掉线时补登录
  status [线路]   查看在线状态（无需账号密码）
  routing         仅重建门户分流路由（hotplug 调用，无需账号密码）

选项:
  -h, --help      显示本帮助
  -v, --verbose   输出调试日志

线路:
  wan / wanb / wanc（对应配置 TARGETS 里的逻辑名）
```

常用：

```sh
educnt status            # 看三条线状态
educnt reauth            # 三线逐条重认证
educnt reauth wanb       # 只重认证 wanb
educnt -v login wanc     # 调试单条线路登录
```

日志：`/tmp/educnt.log`（`logread` 里也能看到 `educnt` 的输出）。

---

## 工作原理

深澜门户的登录并不需要浏览器，`Portal.js` 只做了三件事：

| 字段 | 算法 |
|---|---|
| `password` | `HMAC-MD5(key=challenge, msg=password)`，前缀 `{MD5}` |
| `info` | `JSON` → **XXTEA**（key = challenge）→ **自定义字母表 Base64**，前缀 `{SRBX1}` |
| `chksum` | `SHA-1(challenge + username + challenge + hmd5 + challenge + ac_id + challenge + ip + challenge + n + challenge + type + challenge + info)` |

`educnt.uc` 用纯 ucode 实现了 MD5 / HMAC-MD5 / XXTEA / 自定义 Base64 / SHA-1，输出与站点 `all.min.js` + `Portal.js` 在 64 字节真实 challenge 下逐字节一致。

请求流程：

```
get_challenge  →  srun_portal (login)  →  rad_user_info 确认在线
                ↘ srun_portal (logout)
```

---

## 多 WAN 的关键坑（已内置修复）

当 `mwan3` 检测到某条 WAN 未认证（离线）时，它会在 `OUTPUT` 链把本机发出的包强制打上 `0x100` 标记，改走仍然在线的 `wan`。此时 `curl --interface vwanb`（源 IP `10.210.10.58`）的包会从 `wan` 的 MAC 发出去，被学校交换机的源地址校验丢弃，表现为 `curl rc=7`，永远登不上另外两条线。

本项目的处理：

1. 把门户 IP（`210.37.41.66`）加入 `mwan3_custom_ipv4` ipset，让 mwan3 直接放行；
2. 建立高优先级源地址策略路由：`ip rule from <WAN_IP> lookup <1|2|3> pref 510+`；
3. `/etc/hotplug.d/iface/90-educnt` 在每次 `ifup` 后重建上述规则（mwan3 重启会清空 ipset）。

相关逻辑在 `educnt.uc` 的 `ensure_routing()` 与 `educnt routing` 子命令里。

---

## 常见问题

**Q：提示 `获取 challenge 失败（网络不通或被拦截）`**

先确认该线路能否访问门户：

```sh
curl -4 -sS --interface vwanb 'https://xyw.hainanu.edu.cn/cgi-bin/rad_user_info?callback=cb'
```

如果超时，通常是该 MAC 在学校系统里的绑定掉了（“MAC 免认证”失效）。脚本无法替你改学校自助服务系统，需要你手动删除并重新登记该 MAC。

**Q：`auth_info_error`**

说明加密链路没对上。本仓库已按真实 64 字节 challenge 对拍；如果你改了 `PORTAL` 或学校升级了门户，请提 issue 并附上 `educnt -v login` 的输出（**注意打码密码与 challenge**）。

**Q：学校每几天强制下线**

`educnt` 每天 04:30 自动 `reauth`，每 30 分钟 `check` 掉线补登。如需改时间，编辑 `/usr/share/educnt/daemon.sh` 里的窗口或改 `CHECK_INTERVAL`。

---

## 目录结构

```
educnt-openwrt/
├── .github/workflows/build.yml     # 自动编译 24.10 / 25.12
├── package/educnt/
│   ├── Makefile
│   └── files/
│       ├── educnt.uc               # 主程序（ucode）
│       ├── educnt                  # /usr/bin/educnt
│       ├── educnt-setup            # 配置向导
│       ├── educnt.init             # procd 服务
│       ├── daemon.sh               # 定时调度
│       ├── 90-educnt               # ifup hotplug
│       └── educnt.conf             # 默认配置
├── docs/mwan3.user.example         # 可选的 mwan3 钩子（等价于 hotplug 方案）
├── LICENSE
└── README.md
```

---

## License

MIT
