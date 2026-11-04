include $(TOPDIR)/rules.mk

PKG_NAME:=ponwrt-diag
PKG_VERSION:=1
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ponwrt-diag
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Reboot / crash evidence collector
endef

define Package/ponwrt-diag/description
  /usr/sbin/ponwrt-reboot-report：把"为什么自动重启"能看到的线索一次打全
  （内核日志里的 panic/oops/watchdog/thermal/OOM 行、温度、内存、pstore、
  U-Boot 环境变量、logread）。--watch 模式把 dmesg 尾部定期写到 /overlay，
  硬复位后仍能看到复位前最后几行 —— 这台机器的 DTS 没有 ramoops 预留区，
  内核现场默认不会留下，这是不需要改上游 DTS 的兜底。
endef

define Build/Compile
endef

define Package/ponwrt-diag/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/ponwrt-reboot-report $(1)/usr/sbin/
endef

$(eval $(call BuildPackage,ponwrt-diag))
