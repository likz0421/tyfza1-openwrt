#!/bin/bash
# 把 LeoooChen/PonWRT-TYFZA1 的端口铺到**任意** OpenWrt 基座上，并且不断言基座 SHA。
#
# 为什么要自己写：上游的 port/scripts/sync-overlay.sh 与 prepare.sh 都硬要求
#   test "$(git -C "$TREE" rev-parse HEAD)" = "$PIN"   # PIN=79bc56cb…（master）
# 换基座就一步拒绝——这对他们是正确的保守设计，但我们要回答的正是
# "25.12.6 稳定版 + 这套端口"能不能成立，所以必须绕开这道断言，同时
# 把每一步的成败**逐条打印**出来，而不是中途 abort 后只剩一句 error。
#
# 用法：port-overlay.sh <openwrt树> <端口仓库> [config 文件]
#   环境变量 TYFZA1_VERSION_REPO 可覆盖上游写死的 CONFIG_VERSION_REPO。
set -uo pipefail
TREE="${1:?用法: port-overlay.sh <openwrt树> <端口仓库> [config]}"
PORT="${2:?缺少端口仓库路径}"
CFG="${3:-}"
[ -d "$TREE/.git" ] || { echo "::error::$TREE 不是 git 工作树"; exit 1; }
# 端口仓库的结构是 <repo>/port/{overlay,packages,host-patches,openwrt-patches,configs}。
# 传仓库根还是传 port/ 都认，但两处都找不到就直接死——上一轮就是传错了一层，
# 结果 overlay 一步没铺、glob 空转还报"补丁失败 0 个"，等于给了个假结论。
if [ ! -d "$PORT/overlay/target/linux" ] && [ -d "$PORT/port/overlay/target/linux" ]; then
  PORT="$PORT/port"
fi
[ -d "$PORT/overlay/target/linux" ] || {
  echo "::error::在 $PORT 里找不到 overlay/target/linux —— 端口仓库结构变了？"; exit 1; }
for d in packages host-patches openwrt-patches configs; do
  [ -d "$PORT/$d" ] || { echo "::error::端口缺 $PORT/$d"; exit 1; }
done
shopt -s nullglob
echo "端口目录：$PORT（$(git -C "$PORT/.." rev-parse --short HEAD 2>/dev/null || echo '?')）"
T=$(cd "$TREE" && pwd)
FAIL=0

echo "== 基座事实 =="
echo "  HEAD $(git -C "$T" rev-parse --short HEAD) $(git -C "$T" show -s --format=%cI HEAD)"
echo "  通用内核细节文件：$(ls "$T/target/linux/generic" 2>/dev/null | grep '^kernel-' | tr '\n' ' ')"
if [ -d "$T/target/linux/realtek" ]; then
  echo "  realtek 子目标：$(ls "$T/target/linux/realtek" | grep '^rtl' | tr '\n' ' ')"
fi

echo "== 1) target overlay（照 sync-overlay 的目录逐个 rsync）=="
ovl=("$PORT"/overlay/target/linux/*/)
[ "${#ovl[@]}" -gt 0 ] || { echo "::error::$PORT/overlay/target/linux 下没有任何目标目录"; exit 1; }
for d in "${ovl[@]}"; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  mkdir -p "$T/target/linux/$name"
  rsync -a --delete "$d" "$T/target/linux/$name/"
  echo "  target/linux/$name ← overlay（KERNEL_PATCHVER=$(sed -n 's/^KERNEL_PATCHVER:=\(.*\)$/\1/p' "$T/target/linux/$name/Makefile" 2>/dev/null | head -1)）"
done

echo "== 2) 端口自带的包 =="
for p in luci-app-tyfza1-pon tyfza1-pon-control tyfza1-storage; do
  if [ -d "$PORT/packages/$p" ]; then
    mkdir -p "$T/package/$p"
    rsync -a --delete "$PORT/packages/$p/" "$T/package/$p/"
    echo "  package/$p 已铺"
  else
    FAIL=$((FAIL + 1))
    echo "  ::error::端口里没有 packages/$p（预期结构对不上，不能当没事发生）"
  fi
done

echo "== 3) host-patches 落到各包的 patches/ =="
map_host_patch() {   # <patch 文件> <包目录>
  local f="$1" dest="$2"
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL + 1)); echo "  ::error::端口补丁文件不存在：$f"; return
  fi
  if [ -d "$dest" ]; then
    mkdir -p "$dest/patches"
    cp -f "$f" "$dest/patches/" && echo "  $(basename "$f") → ${dest#"$T"/}/patches/"
  else
    echo "  ::warning::$(basename "$f") 的目标包目录不存在：${dest#"$T"/}（基座里包位置变了？）"
  fi
}
HP="$PORT/host-patches"
map_host_patch "$HP/471-hostapd-acs-no-survey.patch"        "$T/package/network/services/hostapd"
map_host_patch "$HP/120-firewall4-netifd-lower-devices.patch" "$T/package/network/config/firewall4"
map_host_patch "$HP/121-firewall4-interface-topology.patch"   "$T/package/network/config/firewall4"
map_host_patch "$HP/120-netifd-interface-topology.patch"      "$T/package/network/config/netifd"
map_host_patch "$HP/130-iwinfo-txpower-unknown.patch"         "$T/package/network/utils/iwinfo"
map_host_patch "$HP/131-iwinfo-ap-scan.patch"                 "$T/package/network/utils/iwinfo"
map_host_patch "$HP/132-iwinfo-scan-timeout.patch"            "$T/package/network/utils/iwinfo"
map_host_patch "$HP/132-rpcd-scan-pause.patch"                "$T/package/system/rpcd"
map_host_patch "$HP/110-wireless-regdb-signed.patch"          "$T/package/firmware/wireless-regdb"

echo "== 4) openwrt-patches 逐个试（这是兼容性的真答案，一个都不许含糊）=="
pls=("$PORT"/openwrt-patches/*.patch)
[ "${#pls[@]}" -gt 0 ] || {
  echo "::error::$PORT/openwrt-patches 里一个补丁都没有 —— glob 空转不等于全部通过"; exit 1; }
n_ok=0; n_skip=0; n_ign=0
for c in "${pls[@]}"; do
  b=$(basename "$c")
  if git -C "$T" apply --reverse --check "$c" 2>/dev/null; then
    echo "  已应用过（跳过）：$b"; n_skip=$((n_skip + 1)); continue
  fi
  if err=$(git -C "$T" apply --check "$c" 2>&1); then
    git -C "$T" apply "$c" && { echo "  可应用 ✔：$b"; n_ok=$((n_ok + 1)); }
  else
    printf '%s\n' "$err" | sed 's/^/      /' | head -8
    if [ "${SKIP_UNAPPLICABLE:-0}" = "1" ]; then
      echo "  跳过（SKIP_UNAPPLICABLE=1，可行性试验用，产出物不可刷）：$b"
      n_ign=$((n_ign + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  打不上 ✘：$b"
    fi
  fi
done
echo "  小结：试了 ${#pls[@]} 个（可应用 $n_ok，本来已在 $n_skip，跳过 $n_ign，失败 $FAIL）"

echo "== 5) luci 补丁（feed 装好之后再跑，这里只探测）=="
if [ -d "$T/feeds/luci/modules/luci-mod-status" ] && [ -x "$PORT/scripts/apply-luci-patches.sh" ]; then
  sh "$PORT/scripts/apply-luci-patches.sh" "$T" && echo "  luci 补丁已应用" || echo "  ::warning::luci 补丁应用失败"
else
  echo "  · feeds/luci 还没装，luci 补丁留到构建阶段"
fi

echo "== 6) .config =="
if [ -n "$CFG" ] && [ -s "$CFG" ]; then
  cp "$CFG" "$T/.config"; echo "  用传入的 config：$CFG"
elif [ -s "$PORT/configs/tyfza1-boot.config" ]; then
  cp "$PORT/configs/tyfza1-boot.config" "$T/.config"; echo "  用端口 boot config 原文"
else
  echo "::error::既没传 config，端口里也没有 configs/tyfza1-boot.config"; exit 1
fi
# 与上游 sync-overlay 一致：版本标识 + 兼容层必选包，保持行为可对齐
VERSION=$(cat "$PORT/../VERSION" 2>/dev/null || echo probe)
sed -i '/^CONFIG_VERSIONOPT=/d; /^# CONFIG_VERSIONOPT is not set$/d; /^CONFIG_VERSION_NUMBER=/d; /^CONFIG_VERSION_REPO=/d; /^CONFIG_SIGNED_PACKAGES=/d; /^# CONFIG_SIGNED_PACKAGES is not set$/d; /^CONFIG_SIGN_EACH_PACKAGE=/d; /^# CONFIG_SIGN_EACH_PACKAGE is not set$/d' "$T/.config"
printf 'CONFIG_VERSIONOPT=y\nCONFIG_VERSION_NUMBER="%s"\n' "$VERSION" >> "$T/.config"
REPO="${TYFZA1_VERSION_REPO:-https://downloads.openwrt.org/snapshots}"
printf 'CONFIG_VERSION_REPO="%s"\nCONFIG_SIGNED_PACKAGES=y\nCONFIG_SIGN_EACH_PACKAGE=y\n' "$REPO" >> "$T/.config"
echo "  CONFIG_VERSION_REPO=$REPO（上游原值是官方 snapshots）"
if [ -s "$PORT/configs/tyfza1-compat.config" ]; then
  while IFS= read -r setting; do
    case "$setting" in
      CONFIG_PACKAGE_*=y)
        option=${setting%%=*}
        sed -i "/^$option=/d; /^# $option is not set$/d" "$T/.config"
        printf '%s\n' "$setting" >> "$T/.config" ;;
    esac
  done < "$PORT/configs/tyfza1-compat.config"
  echo "  compat 必选包已并入（$(grep -c '^CONFIG_PACKAGE_.*=y' "$PORT/configs/tyfza1-compat.config") 条）"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "VERDICT: 端口在 $(git -C "$T" describe --tags --always 2>/dev/null || git -C "$T" rev-parse --short HEAD) 上有 $FAIL 个 openwrt 补丁打不上——见上面逐条原因"
  exit 2
fi
echo "VERDICT: 端口文件与 openwrt 补丁全部落位，可以继续做 configure/编译验证"
