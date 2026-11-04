#!/bin/bash
# 生成机器可读的「当前版本」指针 latest.json，由每次构建写到 Pages 的固定路径上。
#
# 为什么需要它：两条线都用**滚动 tag**（设备端 apk 源与 install.sh 都指向固定地址），
# 而 GitHub 的 tag 页把资产列表改成前端 JS 渲染、release 的 published_at 又永远停在
# 首次发布那一刻 —— 于是"到底有没有新固件"只能靠肉眼盯页面，前后已经被这个坑绕住三次。
# 有了 latest.json，人和脚本都只问一句：built_at / sha256 / run_id 变没变。
#
# 用法：make-latest.sh <输出目录> KEY=VAL [KEY=VAL ...]
#   KEY 建议用 ASCII，值里可以带空格与中文；值按字符串写入 JSON，键顺序保持传参顺序。
#   固定附带的字段：schema、generated_at_utc。
# 输出：<输出目录>/latest.json（单个 JSON 对象，不是数组）
set -euo pipefail
OUT="${1:?用法: make-latest.sh <输出目录> KEY=VAL ...}"
shift
[ "$#" -ge 1 ] || { echo "::error::至少要给一对 KEY=VAL"; exit 1; }
mkdir -p "$OUT"
for kv in "$@"; do
	case "$kv" in
		*=*) ;;
		*) echo "::error::参数必须是 KEY=VAL 形式，收到 [$kv]"; exit 1 ;;
	esac
done

printf '%s\n' "$@" | OUTFILE="$OUT/latest.json" node -e '
const fs = require("fs");
const lines = fs.readFileSync(0, "utf8").split("\n").filter((l) => l !== "");
const o = { schema: 1, generated_at_utc: new Date().toISOString().replace(/\.\d+Z$/, "Z") };
for (const l of lines) {
  const i = l.indexOf("=");
  const k = l.slice(0, i).trim();
  const v = l.slice(i + 1).trim();
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) {
    console.error(`::error::latest.json 的键不合法：[${k}]`);
    process.exit(1);
  }
  o[k] = v;
}
if (!o.sha256 || !o.firmware_url) {
  console.error("::error::latest.json 至少要含 sha256 与 firmware_url，否则判断不了新旧");
  process.exit(1);
}
// Pages 地址必须是 <owner>.github.io/<repo>/…；GITHUB_REPOSITORY 本身含 "owner/"，
// 拼错就会把 owner 写两遍，指出去是个 404。CI 真踩过，所以在产出前就地拦下。
for (const [k, v] of Object.entries(o)) {
  if (typeof v === "string" && /([A-Za-z0-9._-]+)\.github\.io\/\1\//.test(v)) {
    console.error(`::error::${k} 的 Pages 地址把 owner 写重了：${v}`);
    process.exit(1);
  }
}
fs.writeFileSync(process.env.OUTFILE, JSON.stringify(o, null, 2) + "\n");
console.log("latest.json：" + Object.keys(o).length + " 个字段 · " + o.firmware + " " + (o.size_bytes || "?") + " B · sha256 " + String(o.sha256).slice(0, 12) + "…");
'
