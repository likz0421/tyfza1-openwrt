#!/bin/bash
# 把 honk 变成真正的 in-tree 包（package/custom/honk + 两个 LuCI 包）。
#   二进制：honk 官方 release 资产（musl 静态、内嵌 doona），
#           下载与 sha256 校验交给 buildroot（PKG_HASH）—— 不在脚本里自己下。
#   init/UCI/config.dae + luci-app-honk + luci-lib-daeuniverse：
#           从 daeuniverse/openwrt-packages 按 SHA 取源码。
# 参数1 = openwrt 源码根。所有版本/哈希的唯一真相是 honk-manifest.txt。
set -euo pipefail
ROOT="${1:?用法: stage-honk.sh <openwrt源码根>}"
CTRL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$CTRL/honk-manifest.txt"
[ -f "$M" ] || { echo "::error::找不到 $M"; exit 1; }
val() {   # 取 key=value，剥掉行内注释与首尾空白
	awk -F= -v k="$1" '$1==k{
		sub(/^[^=]*=/, "");            # 去掉 key=
		sub(/[ \t]+#.*$/, "");         # 去掉行内注释（曾经把 install 的目标路径吃掉）
		gsub(/^[ \t]+|[ \t]+$/, "");   # 去首尾空白
		print
	}' "$M" | tail -1
}
HONK_VERSION="$(val HONK_VERSION)"; HONK_ASSET="$(val HONK_ASSET)"
HONK_PKG_VERSION="$(val HONK_PKG_VERSION)"
HONK_URL="$(val HONK_URL)";        HONK_SHA256="$(val HONK_SHA256)"
HONK_FILE="$(val HONK_FILE)"
DAEUNIV_URL="$(val DAEUNIV_URL)";  DAEUNIV_SHA="$(val DAEUNIV_SHA)"
for v in HONK_VERSION HONK_PKG_VERSION HONK_ASSET HONK_URL HONK_SHA256 HONK_FILE DAEUNIV_URL DAEUNIV_SHA; do
	[ -n "${!v}" ] || { echo "::error::honk-manifest.txt 缺 $v"; exit 1; }
done
# 值必须是干净 token：带空格/# 的取值会拼进 Makefile recipe，install 会吃掉目标路径
case "$HONK_FILE" in *[!A-Za-z0-9._-]*) echo "::error::HONK_FILE 含非法字符: [$HONK_FILE]"; exit 1;; esac
case "$HONK_ASSET" in *[!A-Za-z0-9._+-]*) echo "::error::HONK_ASSET 含非法字符: [$HONK_ASSET]"; exit 1;; esac
case "$HONK_SHA256" in *[!0-9a-f]*) echo "::error::HONK_SHA256 不是十六进制: [$HONK_SHA256]"; exit 1;; esac
[ "${#HONK_SHA256}" = 64 ] || { echo "::error::HONK_SHA256 长度 ${#HONK_SHA256} ≠ 64"; exit 1; }
# apk 版本号：`-` 只许一次（是 revision 分隔符），所以这里根本不能再出现；
# 上一轮 `0.1.0-beta.4-r1` 被 apk mkpkg 判 "package version is invalid" 就是踩这条。
case "$HONK_PKG_VERSION" in *-*) echo "::error::HONK_PKG_VERSION 里不能有 -（apk 拿它当 revision 分隔符）: [$HONK_PKG_VERSION]"; exit 1;; esac
case "$HONK_PKG_VERSION" in *[!0-9A-Za-z._~+]*) echo "::error::HONK_PKG_VERSION 含 apk 不接受的字符: [$HONK_PKG_VERSION]"; exit 1;; esac
case "$HONK_PKG_VERSION" in [0-9]*) ;; *) echo "::error::HONK_PKG_VERSION 要以数字开头: [$HONK_PKG_VERSION]"; exit 1;; esac
echo "honk $HONK_VERSION  资产 $HONK_ASSET"
echo "     sha256 $HONK_SHA256（与 release 的 SHA256SUMS 逐字核对过）"
echo "     包版本号用 $HONK_PKG_VERSION（apk 合法形态，与 daeuniverse 自己的一致）"
echo "feed  $DAEUNIV_URL @ ${DAEUNIV_SHA:0:7}"

cd "$ROOT"
PKG_DIR=package/custom
mkdir -p "$PKG_DIR"

# ---- 1. 按 SHA 取 feed 源码 ----
TMP="$(mktemp -d)/daeuniv"
git init -q "$TMP"
git -C "$TMP" remote add origin "$DAEUNIV_URL"
git -C "$TMP" fetch -q --depth 1 origin "$DAEUNIV_SHA"
git -C "$TMP" checkout -q FETCH_HEAD
[ "$(git -C "$TMP" rev-parse HEAD)" = "$DAEUNIV_SHA" ] || { echo "::error::feed SHA 不匹配"; exit 1; }

for p in luci-app-honk luci-lib-daeuniverse; do
	[ -f "$TMP/$p/Makefile" ] || { echo "::error::$p/Makefile 不存在"; exit 1; }
	grep -q 'call BuildPackage' "$TMP/$p/Makefile" || {
		echo "::error::$p 的 Makefile 没有 call BuildPackage 字样，会被 include/scan.mk 静默跳过"; exit 1; }
	rm -rf "$PKG_DIR/$p"
	cp -a "$TMP/$p" "$PKG_DIR/"
	rm -rf "$PKG_DIR/$p/.git"
	echo "✅ 已放置 $p"
done

# ---- 2. 生成 wrapper 包 honk ----
HB="$PKG_DIR/honk"
rm -rf "$HB"; mkdir -p "$HB/files"
for f in honk.init honk.config config.dae; do
	[ -f "$TMP/honk/files/$f" ] || { echo "::error::缺 honk/files/$f"; exit 1; }
	cp -a "$TMP/honk/files/$f" "$HB/files/$f"
done
rm -rf "$(dirname "$TMP")"

# 依赖按「静态二进制」写：官方资产是 statically linked，所以不需要 libstdcpp；
# 内核模块与 geodata 是运行期真要用的。BTF 由本固件的
# CONFIG_KERNEL_DEBUG_INFO_BTF=y 提供，故不依赖 vmlinux-btf blob。
cat > "$HB/Makefile" <<MK
# 由 scripts/stage-honk.sh 依 honk-manifest.txt 生成 —— 改版本请改那个文件。
# 官方 release 的 musl 静态二进制（内嵌 doona 面板）。honk 的 eBPF 对象在产物里，
# 源码重编要 nightly Rust + bpf-linker + BoringSSL(Go)，故此处取发布资产，
# 下载与校验由 buildroot 做（PKG_HASH）。
include \$(TOPDIR)/rules.mk

PKG_NAME:=honk
# 用 apk 合法形态的版本号（manifest 里 HONK_PKG_VERSION），下载名仍用资产原名
PKG_VERSION:=$HONK_PKG_VERSION
PKG_RELEASE:=1

PKG_SOURCE:=$HONK_ASSET
PKG_SOURCE_URL:=$(dirname "$HONK_URL")
PKG_HASH:=$HONK_SHA256

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
# include/unpack.mk: TAR_CMD=\$(HOST_TAR) -C \$(1)/.. \$(TAR_OPTIONS) —— 解包落在
# PKG_BUILD_DIR 的**父目录**，也就是指望 tar 自己顶层那个目录名正好等于 PKG_BUILD_DIR
# 的名字。官方资产的顶层是 honk-core-v<版本>-aarch64-unknown-linux-musl-full，
# 上一轮把它写成 honk-<版本>，解出来的东西在别处，install 时
# "cannot stat .../honk-0.1.0-beta.4/honk-core-v.../honk-core: No such file"。
# 所以 PKG_BUILD_DIR 必须就叫 tar 里那个名字。
PKG_BUILD_DIR:=\$(BUILD_DIR)/${HONK_ASSET%.tar.gz}

include \$(INCLUDE_DIR)/package.mk

# 载荷直接就在 PKG_BUILD_DIR 下（不再有一层同名子目录）
HONK_DIST:=\$(PKG_BUILD_DIR)

define Package/honk
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=eBPF transparent proxy engine (honk-core, embedded doona UI)
  URL:=https://github.com/daeuniverse/honk
  DEPENDS:=+kmod-veth +kmod-sched-core +kmod-sched-bpf +kmod-nft-core \\
           +kmod-nft-queue +kmod-nfnetlink-queue +kmod-nf-conntrack \\
           +v2ray-geoip +v2ray-geosite
endef

define Package/honk/description
 TC/cgroup eBPF 透明代理引擎，需内核 BTF（本固件已开 DEBUG_INFO_BTF）。
 endef

# 二进制是预编译的，没有本机编译步骤
define Build/Compile
	true
endef

define Package/honk/conffiles
/etc/config/honk
/etc/honk/config.dae
endef

define Package/honk/install
	\$(INSTALL_DIR) \$(1)/usr/bin
	\$(INSTALL_BIN) \$(HONK_DIST)/$HONK_FILE \$(1)/usr/bin/honk-core
	\$(INSTALL_DIR) \$(1)/usr/share/licenses/honk
	\$(INSTALL_DATA) \$(HONK_DIST)/LICENSE \$(1)/usr/share/licenses/honk/LICENSE
	\$(INSTALL_DIR) \$(1)/etc/init.d
	\$(INSTALL_BIN) ./files/honk.init \$(1)/etc/init.d/honk
	\$(INSTALL_DIR) \$(1)/etc/config
	\$(INSTALL_CONF) ./files/honk.config \$(1)/etc/config/honk
	\$(INSTALL_DIR) \$(1)/etc/honk
	\$(INSTALL_CONF) ./files/config.dae \$(1)/etc/honk/config.dae
endef

\$(eval \$(call BuildPackage,honk))
MK
grep -q 'call BuildPackage' "$HB/Makefile" || { echo "::error::生成的 honk/Makefile 缺扫描标记"; exit 1; }
echo "✅ 已生成 $HB/Makefile（上游 release $HONK_VERSION → 包版本 $HONK_PKG_VERSION）"

# ---- 3. 重建索引并断言三个包 + 关键依赖存在 ----
rm -f tmp/.packageinfo tmp/.targetinfo
rm -f tmp/info/.files-packageinfo.stamp tmp/info/.files-packageinfo-* \
      tmp/info/.files-targetinfo.stamp tmp/info/.files-targetinfo-*
make -s prepare-tmpinfo OPENWRT_BUILD= >/dev/null 2>&1 || true
for p in honk luci-app-honk luci-lib-daeuniverse; do
	if ! grep -qx "Package: $p" tmp/.packageinfo; then
		echo "::error::$p 没进 tmp/.packageinfo"
		# 与"扫描器压根没看这个目录"不同，dump 失败会留下这个文件——里面才是真原因
		# （例如缺 feeds/luci/luci.mk、依赖符号不存在等）
		for f in "logs/package/custom/$p/dump.txt" "logs/package/$p/dump.txt"; do
			[ -f "$f" ] && { echo "----- $f -----"; tail -20 "$f"; }
		done
		exit 1
	fi
	echo "✅ 索引确认: $p"
done
# honk DEPENDS 里这几个必须真在索引里，否则 buildroot 会静默丢掉整个包
for d in kmod-veth kmod-sched-core kmod-sched-bpf kmod-nft-core kmod-nft-queue \
         kmod-nfnetlink-queue kmod-nf-conntrack v2ray-geoip v2ray-geosite \
         flock coreutils-timeout jshn; do
	grep -qx "Package: $d" tmp/.packageinfo || { echo "::error::依赖 $d 不在索引里（honk 会被 defconfig 剔除）"; exit 1; }
done
echo "✅ honk 的全部依赖符号都在索引里"
