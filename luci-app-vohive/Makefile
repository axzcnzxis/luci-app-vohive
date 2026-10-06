include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vohive
VOHIVE_PLUGIN_VERSION?=0.1.23
PKG_VERSION:=$(VOHIVE_PLUGIN_VERSION)
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=VoHive
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vohive
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for VoHive
  DEPENDS:=+luci-base +rpcd +rpcd-mod-file +curl +ca-bundle +jsonfilter
  PKGARCH:=all
endef

define Package/luci-app-vohive/description
  LuCI management page for installing, configuring, and controlling VoHive.
endef

define Build/Compile
endef

define Package/luci-app-vohive/conffiles
/etc/config/vohive
endef

define Package/luci-app-vohive/install
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/usr/share/vohive
	echo "$(PKG_VERSION)" > $(1)/usr/share/vohive/plugin_version
endef

define Package/luci-app-vohive/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/vohive/config /etc/vohive/data /tmp/vohive/logs /tmp/vohive/download
	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
	fi
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-vohive))
