#!/bin/bash
# 把本轮「apk 架构探针」的结论变成刷机后能直接跑的设备端脚本。
#
# 为什么不是直接写进固件：探针必须跑在编译之后（要拿到真实 rootfs 里的 apk 库和
# 二进制），那时镜像已经打包完，再写 files/ 也进不了这一轮的固件。所以按结论生成
# 一个随 Release 交付的 setup-apk-repos.sh；结论不成立时它不写任何源，绝不塞 404。
#
# 用法: make-apk-setup.sh <输出脚本路径> <verdict>
#   verdict ∈ ok | needs-alias | unavailable | inconclusive
set -euo pipefail
OUT="${1:?用法: make-apk-setup.sh <输出脚本路径> <verdict>}"
V="${2:?缺少探针结论}"
DAE_ADB="https://openwrt.daeuniverse.org/25.12/packages/aarch64_generic/packages.adb"
case "$V" in
  ok|needs-alias|unavailable|inconclusive) ;;
  *) echo "::error::未知探针结论 [$V]"; exit 1 ;;
esac

{
  echo '#!/bin/sh'
  echo "# 由 PonWrt 构建自动生成 · 本轮 apk 架构探针结论：$V"
  echo '# 幂等：重复执行不会重复追加别名，也不会重复停用 distfeeds。'
  echo 'set -eu'
  echo 'REPO_DIR=/etc/apk/repositories.d'
  echo 'mkdir -p "$REPO_DIR/disabled"'
  echo '# 上游写死的官方 snapshots/a53 源对本设备（a55）不可用；保留文件，可 mv 回滚'
  echo 'if [ -f "$REPO_DIR/distfeeds.list" ]; then'
  echo '  mv -f "$REPO_DIR/distfeeds.list" "$REPO_DIR/disabled/distfeeds.list"'
  echo 'fi'
  case "$V" in
    ok|needs-alias)
      if [ "$V" = needs-alias ]; then
        echo '# probe: needs-alias —— 需要额外声明 aarch64_generic 才会匹配 generic 索引'
        echo 'grep -qx aarch64_generic /etc/apk/arch 2>/dev/null || echo aarch64_generic >> /etc/apk/arch'
      fi
      echo "printf '%s\\n' '@daeuniverse $DAE_ADB' > \"\$REPO_DIR/daeuniverse.list\""
      echo 'echo "已写入 @daeuniverse（aarch64_generic）；验签公钥由镜像自带"'
      echo 'apk update || echo "apk update 失败：检查网络与 /etc/apk/keys 里的公钥" >&2'
      ;;
    unavailable)
      echo 'echo "本轮探针证明 aarch64_generic 索引不可用：保持纯上游源，不写任何第三方源。"'
      echo 'echo "需要装包请用镜像自带的源，或自行确认架构兼容后再改。"'
      ;;
    inconclusive)
      echo 'echo "本轮探针环境没跑通（inconclusive）：不写任何源，避免塞进一条 404。"'
      echo 'echo "看构建日志里 apk update 的真实报错，修好探针再重跑。"'
      ;;
  esac
} > "$OUT"
chmod +x "$OUT"
echo "✅ 已生成 $OUT（结论 $V，$(wc -l < "$OUT") 行）"
