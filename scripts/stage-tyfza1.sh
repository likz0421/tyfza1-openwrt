#!/bin/bash
# TYFZA1（Realtek RTL9617C）线上只加三样：内核 BTF/eBPF、honk、我自己的 luci-theme-lucent。
#
# 不改动端口仓库任何文件，用它自己设计的扩展点：
#   port/scripts/sync-overlay.sh 里
#     if [ -n "${TYFZA1_CONFIG:-}" ]; then cp "$TYFZA1_CONFIG" "$TREE/.config"
#     elif [ ! -s "$TREE/.config" ]; then cp "$PORT/configs/tyfza1-boot.config" "$TREE/.config"
#   随后它自己补 CONFIG_VERSION_* / CONFIG_VERSION_REPO / 签名行，并合并 tyfza1-compat.config。
# 所以：TYFZA1_CONFIG = 他们的 tyfza1-boot.config 原文 + 我们追加的几行。
# 他们 build.sh 里那句 `make defconfig` 会保留已有 .config 的值，argon / luci-app-tyfza1-pon
# 等必需包的断言照旧执行。
#
# 参数1 = openwrt 树；参数2 = 端口仓库；参数3 = ctrl（本控制仓库）目录；
# 参数4 = 输出派生 config 的路径（workflow 用它设 TYFZA1_CONFIG）
set -euo pipefail
TREE="${1:?用法: stage-tyfza1.sh <openwrt树> <端口仓库> <ctrl> <输出config路径>}"
PORT="${2:?缺少端口仓库路径}"
CTRL="${3:?缺少 ctrl 路径}"
OUTCFG="${4:?缺少输出 config 路径}"
T=$(cd "$TREE" && pwd)
BASE="$PORT/port/configs/tyfza1-boot.config"
[ -s "$BASE" ] || { echo "::error::找不到上游底配置 $BASE（他们改路径了？）"; exit 1; }

# ---------- 1. 派生 config：上游原文 + 我们的追加 ----------
cp "$BASE" "$OUTCFG"
{
	echo ''
	echo '# —— likz0421/ponwrt-xg040gmd 追加：只要 BTF/eBPF + honk + luci-theme-lucent ——'
	# BTF 的 Kconfig 约束：depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED
	# 上游基座默认 REDUCED=y，不显式关掉 BTF 会被 defconfig 静默剔除。
	echo 'CONFIG_KERNEL_DEBUG_INFO=y'
	echo '# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set'
	echo 'CONFIG_KERNEL_DEBUG_INFO_BTF=y'
	echo 'CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y'
	# honk 的可选 UDP 收包追踪回退要 ftrace；缺了只是那一项降级
	echo 'CONFIG_KERNEL_FTRACE=y'
	echo 'CONFIG_KERNEL_FUNCTION_TRACER=y'
	echo 'CONFIG_KERNEL_DYNAMIC_FTRACE=y'
	echo 'CONFIG_KERNEL_BPF_EVENTS=y'
	# honk 运行期要的数据面模块与 geodata（BPF/BPF_SYSCALL/BPF_JIT 由 generic 提供，不写）
	echo 'CONFIG_PACKAGE_kmod-veth=y'
	echo 'CONFIG_PACKAGE_kmod-sched-core=y'
	echo 'CONFIG_PACKAGE_kmod-sched-bpf=y'
	echo 'CONFIG_PACKAGE_kmod-nft-queue=y'
	echo 'CONFIG_PACKAGE_kmod-nfnetlink-queue=y'
	echo 'CONFIG_PACKAGE_honk=y'
	echo 'CONFIG_PACKAGE_luci-app-honk=y'
	echo 'CONFIG_PACKAGE_luci-lib-daeuniverse=y'
	echo 'CONFIG_PACKAGE_v2ray-geoip=y'
	echo 'CONFIG_PACKAGE_v2ray-geosite=y'
	echo 'CONFIG_PACKAGE_flock=y'
	echo 'CONFIG_PACKAGE_coreutils-timeout=y'
	echo 'CONFIG_PACKAGE_luci-theme-lucent=y'
	# 开机启用射频（不建 SSID）：上游只设 country，默认无线是关的
	echo 'CONFIG_PACKAGE_ponwrt-wifi-on=y'
} >> "$OUTCFG"
# 先放到位，让后面的索引自检能跑（build.sh 里 sync-overlay 会用同一份内容再覆盖一次，幂等）
cp "$OUTCFG" "$T/.config"
echo "✅ 派生 config：上游 $(grep -c '^CONFIG_' "$BASE") 条 + 我们追加 $(grep -c '^CONFIG_' "$OUTCFG") 条总量"

# ---------- 1b. 先装 luci feed（必须在放 LuCI 包之前）----------
# luci-app-honk / luci-lib-daeuniverse / 主题的 Makefile 都 include
# $(TOPDIR)/feeds/luci/luci.mk；上游是在 build.sh 里第 26 行才跑
# prepare_luci_feeds.sh，那时我们的包还没进树，自检就会因 luci.mk 不存在而 dump 失败。
# 这里先调他们自己的脚本（幂等，build.sh 再跑一次无影响），不自己拼 feeds 命令。
FEEDPREP=""
for c in "$PORT/scripts/prepare_luci_feeds.sh" "$PORT/../scripts/prepare_luci_feeds.sh"; do
	[ -f "$c" ] && { FEEDPREP="$c"; break; }
done
[ -n "$FEEDPREP" ] || { echo "::error::找不到 prepare_luci_feeds.sh，luci.mk 将不存在"; exit 1; }
echo "--- 先准备 luci feed: $FEEDPREP ---"
sh "$FEEDPREP" "$T" 2>&1 | tail -5
[ -f "$T/feeds/luci/luci.mk" ] || { echo "::error::跑完仍没有 feeds/luci/luci.mk"; exit 1; }
echo "✅ luci.mk 就位"

# ---------- 2. 主题（和 XG 线同一 SHA、同一校验）----------
set -a; . "$CTRL/pins.env"; set +a
THEME_TMP="$(mktemp -d)/lucent"
git init -q "$THEME_TMP"
git -C "$THEME_TMP" remote add origin "$THEME_URL"
git -C "$THEME_TMP" fetch -q --depth 1 origin "$THEME_SHA"
git -C "$THEME_TMP" checkout -q FETCH_HEAD
[ "$(git -C "$THEME_TMP" rev-parse HEAD)" = "$THEME_SHA" ] || { echo "::error::主题 SHA 不匹配"; exit 1; }
# include/scan.mk 是静态 grep 'call BuildPackage' 决定是否扫这个目录，缺标记=静默不索引
grep -q 'call BuildPackage' "$THEME_TMP/Makefile" || {
	echo "::error::主题 Makefile 缺 call BuildPackage 扫描标记"; exit 1; }
mkdir -p "$T/package/custom"
rm -rf "$T/package/custom/luci-theme-lucent"
cp -a "$THEME_TMP" "$T/package/custom/luci-theme-lucent"
rm -rf "$T/package/custom/luci-theme-lucent/.git" "$(dirname "$THEME_TMP")"
echo "✅ 主题已放置 luci-theme-lucent @ ${THEME_SHA:0:7}"

# ---------- 2b. 开机启用射频的小包（我们自己写的，不动上游）----------
# 放 package/custom/ 和 honk/主题同一层；Makefile 里有 `call BuildPackage`
# 扫描标记（缺了会被 include/scan.mk 静默跳过，这条踩过）。
WIFIPKG="$CTRL/packages/ponwrt-wifi-on"
[ -s "$WIFIPKG/Makefile" ] && [ -s "$WIFIPKG/files/etc/uci-defaults/99-ponwrt-enable-radio" ] || {
	echo "::error::找不到 $WIFIPKG（Makefile 或 uci-defaults 脚本缺失）"; exit 1; }
grep -q 'call BuildPackage' "$WIFIPKG/Makefile" || {
	echo "::error::ponwrt-wifi-on 的 Makefile 缺 call BuildPackage 扫描标记"; exit 1; }
rm -rf "$T/package/custom/ponwrt-wifi-on"
cp -a "$WIFIPKG" "$T/package/custom/ponwrt-wifi-on"
echo "✅ 已放置 ponwrt-wifi-on（首启启用射频，不建 SSID）"

# ---------- 3. honk：复用与 XG 线完全同一套（同一 manifest、同一 wrapper）----------
bash "$CTRL/scripts/stage-honk.sh" "$T"

# ---------- 4. 主题再自检一次（stage-honk 只验它自己那三个）----------
cd "$T"
grep -qx "Package: luci-theme-lucent" tmp/.packageinfo || {
	echo "::error::luci-theme-lucent 没进 tmp/.packageinfo"; exit 1; }
grep -qx "Package: ponwrt-wifi-on" tmp/.packageinfo || {
	echo "::error::ponwrt-wifi-on 没进 tmp/.packageinfo"; exit 1; }
echo "✅ 索引确认: luci-theme-lucent, ponwrt-wifi-on"
echo "✅ TYFZA1 注入完成（$OUTCFG + package/custom/{honk,luci-app-honk,luci-lib-daeuniverse,luci-theme-lucent,ponwrt-wifi-on}）"
