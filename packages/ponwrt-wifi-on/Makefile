include $(TOPDIR)/rules.mk

PKG_NAME:=ponwrt-wifi-on
PKG_VERSION:=1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ponwrt-wifi-on
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Enable Wi-Fi radios on first boot
  DEPENDS:=+wifi-scripts
endef

define Package/ponwrt-wifi-on/description
  首启把 wireless 里所有 wifi-device 的 disabled 置 0 并重载射频。
  不创建 SSID、不改加密、不设密码：只是让射频处于"已启用"状态，
  广播什么仍由你在 网络 → 无线 里决定。上游的 board.d/03_wireless
  只写 country=CN，不启用射频，所以原厂状态下无线是关着的。
endef

define Build/Compile
endef

define Package/ponwrt-wifi-on/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-ponwrt-enable-radio $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,ponwrt-wifi-on))
