# educnt

> 海南大学校园网（深澜 SRUN）**OpenWrt 自动登录 / 定时重认证**工具
>
> 纯 `ucode` 实现，**不需要 Node.js，不需要 Chrome / Playwright**。唯一新增依赖是 `curl`（约 145 KiB）。

---

## 来源与致谢

本项目是基于以下上游项目的**重写版本**，不是从零开始的原创：

- 上游项目：**[taffy123d/hainanu-auto-login](https://github.com/taffy123d/hainanu-auto-login)**（ISC License）
- 上游实现：Node.js + Playwright 无头 Chrome，模拟人工填写门户表单
- 上游文档：**[hainanu-campus-net-page-analysis.md](https://github.com/taffy123d/hainanu-auto-login/blob/main/docs/hainanu-campus-net-page-analysis.md)** —— 本项目登录接口（`get_challenge` / `srun_portal` / `rad_user_info`）的来源

**为什么重写：**

| | 上游项目 | 本项目 |
|---|---|---|
| 运行时 | Node.js + Playwright + Chrome | 系统自带的 `ucode` |
| 依赖体积 | 数百 MB | `curl` 145 KiB |
| 登录耗时 | 约 4–7 秒（启动浏览器） | 通常 < 1 秒 |
| 适用设备 | PC / 服务器 | OpenWrt 路由器（mipsel/arm/aarch64 等） |
| 多 WAN | 不支持 | 支持按虚拟网卡分别认证 |
| 定时重认证 | 需自行配 cron | 内置 procd 服务 |

登录协议的具体算法（HMAC-MD5、XXTEA、自定义 Base64、SHA-1）来自对学校门户线上前端 `Portal.js` / `all.min.js` 的逐字节比对，没有复制上游代码。上游的页面分析文档对定位接口端点帮助很大，在此致谢。

> 本项目与海南大学官方无关，使用风险自负。

---

## 特性

- **无浏览器**：直接走深澜门户的 JSONP 接口
- **多 WAN 分别认证**：`curl --interface <dev>` 绑定源地址，`wan` / `vwanb` / `vwanc` 各登各的
- **内置门户路由修复**：解决 `mwan3` 在部分线路离线时把认证请求改写到在线线路、导致 `curl rc=7` 的问题
- **逐条重认证**：`reauth` 对每条线路执行 注销 → 登录 → 确认在线，确认成功后才处理下一条
- **掉线自动补登**：每 30 分钟 `check` 一次
- **每日自动重认证**：每天 04:30 自动 `reauth`，刷新会话 / IP
- **开机自启**：procd 托管，异常退出自动重启
- **密码文件权限 600**，运行日志写 `/tmp`，不磨损闪存

---

## 适用环境

- OpenWrt **24.10+ / 25.12+**（`ucode` 随系统提供）
- 已安装 `curl`
- 已在 **Xiaomi Mi Router 3G（ramips/mt7621，OpenWrt 25.12.5）** 上验证
- 单 WAN、单线多拨（macvlan 虚拟 WAN）均可

检查依赖：

```sh
command -v ucode curl
```

缺少时：

```sh
apk update && apk add curl     # OpenWrt 25.12
# 或
opkg update && opkg install curl   # OpenWrt 24.10
```

---

## 安装

### 方式一：安装编译好的包（推荐）

到本仓库的 **Releases** 下载与你的 OpenWrt 版本匹配的包。

**OpenWrt 24.10（opkg）**

```sh
opkg install educnt_*.ipk
```

**OpenWrt 25.12（apk）**

```sh
apk add --allow-untrusted educnt-*.apk
```

安装后会自动启用 `educnt` 服务，但**不会自动登录**，需要先配置账号（见下一节）。

### 方式二：用 OpenWrt SDK 自己编译

```sh
# 1. 下载对应版本 SDK（以 25.12.5 / ramips-mt7621 为例）
wget https://downloads.openwrt.org/releases/25.12.5/targets/ramips/mt7621/openwrt-sdk-25.12.5-ramips-mt7621_gcc-14.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-25.12.5-ramips-mt7621_*.tar.zst
cd openwrt-sdk-25.12.5-ramips-mt7621_*

# 2. 添加本仓库为 feed
cp feeds.conf.default feeds.conf
echo "src-link educnt /path/to/educnt-openwrt" >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 编译
echo "CONFIG_PACKAGE_educnt=m" >> .config
make defconfig
make package/educnt/compile V=s -j$(nproc)
```

产物位于 `bin/packages/<arch>/educnt/`。

### 方式三：手动拷贝文件（临时调试）

```sh
mkdir -p /usr/share/educnt /etc/hotplug.d/iface

cp package/educnt/files/educnt.uc      /usr/share/educnt/educnt.uc
cp package/educnt/files/daemon.sh      /usr/share/educnt/daemon.sh
cp package/educnt/files/educnt         /usr/bin/educnt
cp package/educnt/files/educnt-setup   /usr/bin/educnt-setup
cp package/educnt/files/educnt.init    /etc/init.d/educnt
cp package/educnt/files/90-educnt      /etc/hotplug.d/iface/90-educnt
cp package/educnt/files/educnt.conf    /etc/educnt.conf

chmod +x /usr/share/educnt/educnt.uc /usr/share/educnt/daemon.sh \
         /usr/bin/educnt /usr/bin/educnt-setup \
         /etc/init.d/educnt /etc/hotplug.d/iface/90-educnt

/etc/init.d/educnt enable
```

---

## 配置

### 交互式配置（推荐）

```sh
educnt-setup
```

会提示输入学号和密码，然后自动：

1. 写入 `/etc/educnt.conf`，权限 `600`
2. 自动识别 `vwanb` / `vwanc` 等虚拟网卡，生成 `TARGETS`
3. 启用并启动 `educnt` 服务

### 手动配置

编辑 `/etc/educnt.conf`：

```sh
USERNAME='2025xxxxxxx'
PASSWORD='your-password'
AC_ID='1'
PORTAL='https://xyw.hainanu.edu.cn'
DOMAIN=''
# 逻辑名:设备名，多个用空格分隔
TARGETS='wan:wan wanb:vwanb wanc:vwanc'
```

| 字段 | 说明 |
|---|---|
| `USERNAME` | 学号 |
| `PASSWORD` | 校园网密码 |
| `AC_ID` | 门户的 `ac_id`，海大固定为 `1` |
| `PORTAL` | 门户地址，一般不用改 |
| `DOMAIN` | 账号后缀（如 `@telecom`），没有就留空 |
| `TARGETS` | `逻辑名:设备名` 列表；单 WAN 写 `wan:wan` |

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

示例：

```sh
educnt status              # 查看三条线状态
educnt reauth              # 三线逐条重认证
educnt reauth wanb         # 只重认证 wanb
educnt check               # 掉线才登录
educnt -v login wanc       # 调试单条线路
```

日志：`/tmp/educnt.log`，同时会输出到 syslog（`logread | grep educnt`）。

---

## 定时任务

安装包后由 procd 服务托管，**不需要额外配置 cron**。

| 触发 | 动作 |
|---|---|
| 服务启动时 | `educnt check` |
| 每 30 分钟 | `educnt check` |
| 每天 04:30–04:59 | `educnt reauth` |
| 进程异常退出 | procd 自动重启 |

管理服务：

```sh
/etc/init.d/educnt status
/etc/init.d/educnt restart
/etc/init.d/educnt disable    # 关闭开机自启
```

> 如果你之前手动往 `/etc/crontabs/root` 写过 `educnt` 任务，建议删掉，避免和 procd 服务重复执行。

---

## 工作原理

深澜门户的登录本质是三个 HTTP 请求，不需要浏览器：

```
get_challenge   →  拿到 challenge
srun_portal     →  action=login，提交加密后的 password / info / chksum
rad_user_info   →  确认是否在线
```

前端 `Portal.js` 使用的算法：

| 字段 | 算法 |
|---|---|
| `password` | `HMAC-MD5(key=challenge, msg=password)`，前缀 `{MD5}` |
| `info` | JSON → **XXTEA**（key = challenge）→ **自定义字母表 Base64**，前缀 `{SRBX1}` |
| `chksum` | `SHA-1(challenge + username + challenge + hmd5 + challenge + ac_id + challenge + ip + challenge + n + challenge + type + challenge + info)` |

其中自定义 Base64 字母表为：

```text
LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA
```

`educnt.uc` 用纯 ucode 实现了 MD5 / HMAC-MD5 / XXTEA / 自定义 Base64 / SHA-1，并在 **64 字节真实 challenge** 下与站点 `all.min.js` + `Portal.js` 的输出逐字节比对通过。

---

## 多 WAN 的关键坑（已内置修复）

当 `mwan3` 检测到某条 WAN 未认证（离线）时，它会在 `OUTPUT` 链把本机发出的包强制打上 `0x100` 标记，改走仍然在线的 `wan`。

结果就是：`curl --interface vwanb` 明明绑定了源 IP `10.210.10.58`，包却从 `wan` 的 MAC 发出去，被学校交换机的源地址校验丢弃 —— 表现为 `curl rc=7`，另外两条线永远登不上。

本项目的处理：

1. 把门户 IP（`210.37.41.66`）加入 `mwan3_custom_ipv4` ipset，让 mwan3 放行；
2. 建立高优先级源地址策略路由：`ip rule from <WAN_IP> lookup <1|2|3> pref 510+`；
3. `/etc/hotplug.d/iface/90-educnt` 在每次 `ifup` 后调用 `educnt routing` 重建上述规则（mwan3 重启会清空 ipset）。

相关实现见 `educnt.uc` 的 `ensure_routing()`。

---

## 常见问题

**Q：`获取 challenge 失败（网络不通或被拦截）`**

先确认该线路能访问门户：

```sh
curl -4 -sS --interface vwanb \
  'https://xyw.hainanu.edu.cn/cgi-bin/rad_user_info?callback=cb'
```

如果超时，通常是该 MAC 在学校系统里的绑定掉了（“MAC 免认证”失效）。脚本无法修改学校自助服务系统，需要你手动删除并重新登记该 MAC。

**Q：登录返回 `auth_info_error`**

说明 `info` 解密失败。本项目已经按真实 64 字节 challenge 对拍；如果你改了 `PORTAL`，或学校升级了门户前端，请提 issue，并附上 `educnt -v login` 的输出（**请打码密码与 challenge**）。

**Q：登录返回 `E2620 / already online`**

表示该 IP 已经在线（常见于 MAC 免认证秒上线）。脚本会视为成功，不需要额外处理。

**Q：学校每几天强制下线 / IP 过期**

服务每天 04:30 自动 `reauth`，每 30 分钟 `check`。要改时间，编辑 `/usr/share/educnt/daemon.sh` 里的时间窗口，或改 `CHECK_INTERVAL`。

**Q：密码会明文存在路由器上吗？**

会存在 `/etc/educnt.conf`，权限 `600`（仅 root 可读）。这是自动登录无法避免的；请勿把该文件提交到公开仓库。

---

## 目录结构

```text
educnt-openwrt/
├── .github/workflows/build.yml     # 自动编译 24.10(ipk) / 25.12(apk)
├── package/educnt/
│   ├── Makefile                    # DEPENDS:=+curl +ucode
│   └── files/
│       ├── educnt.uc               # 主程序（ucode）
│       ├── educnt                  # /usr/bin/educnt
│       ├── educnt-setup            # 配置向导
│       ├── educnt.init             # procd 服务
│       ├── daemon.sh               # 定时调度
│       ├── 90-educnt               # ifup hotplug
│       └── educnt.conf             # 默认配置（conffile）
├── docs/mwan3.user.example         # 可选 mwan3 钩子（等价方案）
├── LICENSE
└── README.md
```

---

## 开发与发布

- 本地修改后可用 SDK 编译验证（见「方式二」）
- push 到 GitHub 会自动构建两个版本；打 tag 会自动发布 Release：

```sh
git tag v1.0.0
git push origin v1.0.0
```

---

## License

本项目采用 **MIT License**（见 [LICENSE](LICENSE)）。

上游项目 [taffy123d/hainanu-auto-login](https://github.com/taffy123d/hainanu-auto-login) 采用 **ISC License**。本项目为其协议逻辑的独立重写实现，未直接复制上游源代码；上游的接口分析文档与思路对本文档和实现有重要参考价值。
