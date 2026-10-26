#
# educnt - 海南大学校园网（深澜 SRUN）自动登录
#
# 本项目是 taffy123d/hainanu-auto-login 的 OpenWrt 重写版本：
#   Upstream: https://github.com/taffy123d/hainanu-auto-login (ISC License)
#
# 这是一个纯脚本包：只依赖 curl 与系统自带的 ucode，
# 不需要 Node.js / Chrome / Playwright。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=educnt
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=jshhe

PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/educnt
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Hainan University campus network (SRUN) auto login
  URL:=https://github.com/jshhe/educnt-openwrt
  DEPENDS:=+curl +ucode
endef

define Package/educnt/description
  海南大学校园网（深澜 SRUN）自动登录 / 定时重认证工具。
  纯 ucode 实现，仅依赖 curl；支持多 WAN 分别认证，
  内置门户路由修复，避免 mwan3 把认证请求改写到其他线路。
endef

define Package/educnt/conffiles
/etc/educnt.conf
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/educnt/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/educnt $(1)/usr/bin/educnt
	$(INSTALL_BIN) ./files/educnt-setup $(1)/usr/bin/educnt-setup

	$(INSTALL_DIR) $(1)/usr/share/educnt
	$(INSTALL_BIN) ./files/educnt.uc $(1)/usr/share/educnt/educnt.uc
	$(INSTALL_BIN) ./files/daemon.sh $(1)/usr/share/educnt/daemon.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/educnt.init $(1)/etc/init.d/educnt

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/90-educnt $(1)/etc/hotplug.d/iface/90-educnt

	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) ./files/educnt.conf $(1)/etc/educnt.conf
endef

define Package/educnt/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 600 /etc/educnt.conf 2>/dev/null
	chown root:root /etc/educnt.conf 2>/dev/null
	/etc/init.d/educnt enable
}
exit 0
endef

define Package/educnt/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/educnt disable
	/etc/init.d/educnt stop
}
exit 0
endef

$(eval $(call BuildPackage,educnt))
