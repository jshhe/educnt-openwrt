# educnt

海南大学校园网（深澜 SRUN）自动登录 / 定时重认证。

纯 `ucode` + `curl`，不需要 Node.js，也不需要 Chrome / Playwright。

> **测试范围**：只在 OpenWrt 25.12.5（Xiaomi Mi Router 3G，ramips/mt7621）上实测。
> 理论上任何 Linux 只要装上 `ucode` 和 `curl` 都能跑，但 OpenWrt 之外的发行版**未测试**（init 脚本和 hotplug 路径是按 OpenWrt 写的）。

---

## 上游与来源

本项目是 **[taffy123d/hainanu-auto-login](https://github.com/taffy123d/hainanu-auto-login)**（ISC License）的无浏览器重写版。

- 上游用 Node.js + Playwright 启动无头 Chrome 填表单，约 4–7 秒；
- 本项目直接调用门户 JSONP 接口，通常 < 1 秒，依赖只有 145 KiB 的 `curl`；
- 接口端点参考了上游的 [页面分析文档](https://github.com/taffy123d/hainanu-auto-login/blob/main/docs/hainanu-campus-net-page-analysis.md)。

登录加密算法（HMAC-MD5 / XXTEA / 自定义 Base64 / SHA-1）是对学校门户线上 `Portal.js`、`all.min.js` 的独立复现，未复制上游代码。

---

## 依赖

| 依赖 | 说明 |
|---|---|
| `curl` | 唯一需要安装的包 |
| `ucode` | OpenWrt 自带；其他 Linux 需自行编译 [jow-/ucode](https://github.com/jow-/ucode)，未测试 |

---

## 安装（OpenWrt）

### 编译成 ipk / apk

```sh
cp feeds.conf.default feeds.conf
echo "src-link educnt /path/to/educnt-openwrt" >> feeds.conf
./scripts/feeds update -a && ./scripts/feeds install -a

echo "CONFIG_PACKAGE_educnt=m" >> .config
make defconfig && make package/educnt/compile V=s
```

产物在 `bin/packages/<arch>/educnt/`。

### 或者手动部署

```sh
install -Dm755 package/educnt/files/educnt       /usr/bin/educnt
install -Dm755 package/educnt/files/educnt-setup /usr/bin/educnt-setup
install -Dm755 package/educnt/files/educnt.uc    /usr/share/educnt/educnt.uc
install -Dm755 package/educnt/files/daemon.sh    /usr/share/educnt/daemon.sh
install -Dm755 package/educnt/files/educnt.init  /etc/init.d/educnt
install -Dm755 package/educnt/files/90-educnt    /etc/hotplug.d/iface/90-educnt
install -Dm600 package/educnt/files/educnt.conf  /etc/educnt.conf

/etc/init.d/educnt enable
```

---

## 配置

```sh
educnt-setup
```

也可以直接编辑 `/etc/educnt.conf`：

```sh
USERNAME='2025xxxxxxx'
PASSWORD='your-password'
AC_ID='1'
PORTAL='https://xyw.hainanu.edu.cn'
DOMAIN=''
TARGETS='wan:wan wanb:vwanb wanc:vwanc'
```

| 字段 | 说明 |
|---|---|
| `USERNAME` / `PASSWORD` | 学号 / 密码 |
| `AC_ID` | 海大固定 `1` |
| `PORTAL` | 门户地址，一般不改 |
| `DOMAIN` | 账号后缀，没有就留空 |
| `TARGETS` | `逻辑名:设备名`，单 WAN 写 `wan:wan` |

---

## 命令

```text
educnt [选项] <命令> [线路]

  login  [线路]   登录（默认；不带线路则全部）
  logout [线路]   注销
  reauth [线路]   逐条 注销 → 登录 → 确认在线
  check  [线路]   仅掉线时补登录
  status [线路]   查看状态（无需账号密码）
  routing         重建门户分流路由（hotplug 调用）

  -h, --help      帮助
  -v, --verbose   调试日志
```

日志：`/tmp/educnt.log`，同时进 syslog。

---

## 定时任务

安装后由 procd 服务托管，无需配置 cron：

- 启动时 + 每 30 分钟：`educnt check`
- 每天 04:30–04:59：`educnt reauth`
- 进程异常退出：自动重启

```sh
/etc/init.d/educnt status | restart | disable
```

---

## 原理

```
get_challenge → srun_portal (login) → rad_user_info 确认
```

| 字段 | 算法 |
|---|---|
| `password` | `HMAC-MD5(key=challenge, msg=password)`，前缀 `{MD5}` |
| `info` | JSON → XXTEA（key=challenge）→ 自定义 Base64，前缀 `{SRBX1}` |
| `chksum` | SHA-1 拼接串 |

自定义 Base64 字母表：`LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA`

---

## 多 WAN 的坑

`mwan3` 在部分线路离线时，会在 `OUTPUT` 把本机包强制标记走在线线路。此时 `curl --interface vwanb` 的包会从 `wan` 的 MAC 发出去，被学校源地址校验丢弃（`curl rc=7`）。

修复：门户 IP 加入 `mwan3_custom_ipv4` ipset，并加 `ip rule from <WAN_IP> lookup <table>`；`90-educnt` 在每次 `ifup` 后重建。

---

## 安全

- `PORTAL` 必须是 `https://`，脚本会拒绝 `http://`；curl 也加了 `--proto '=https'`
- `/etc/educnt.conf` 权限 `600`，安装脚本会强制修正
- `-v` 只打印接口和 URL，不打印 challenge / password / info
- 日志 `/tmp/educnt.log` 权限 `600`

---

## FAQ

**`获取 challenge 失败`**：该线路连门户都超时，通常是 MAC 在学校系统里的绑定掉了，去自助服务重新登记该 MAC。

**`auth_info_error`**：门户前端可能升级了。附 `educnt -v login` 输出提 issue（调试日志已脱敏）。

**`E2620 / already online`**：IP 已在线（MAC 免认证常见），视为成功。

---

## License

MIT。上游 [taffy123d/hainanu-auto-login](https://github.com/taffy123d/hainanu-auto-login) 为 ISC License。
