# TYFZA1 专用 OpenWrt 构建仓库

设备：天翼 TYFZA1（Realtek RTL9617CVW，4×Cortex-A55，XG-PON ONU，RTL8852C 5G + RTL8192XB 2.4G）。
这个仓库只做这一台设备，和 `ponwrt-xg040gmd`（Nokia XG-040G-MD）互不影响。

## 为什么先跑探针而不是直接出固件

要求是"官方 25.12.6 稳定版"。实测（GitHub contents API，逐条复核过）：

| 事实 | 结果 |
|---|---|
| `v25.12.6` 是否存在 | 存在，25.12 线已到 `.6` |
| 25.12.6 有没有 `rtl9617c` 目标 | **没有**（`target/linux/realtek` 只有 rtl838x/839x/930x/931x） |
| 25.12.6 支持的内核系列 | 只有 `target/linux/generic/kernel-6.12`；**6.18 只在 master** |
| 端口要求的内核 | `KERNEL_PATCHVER:=6.18`，且端口**不**自带 `generic/kernel-6.18` |
| 端口基座与 25.12 线的关系 | `diverged`：相对 `openwrt-25.12` ahead 4651 / behind 1047 |
| 25.12.6 有没有 `airoha` 目标 | **有**（`an7581`/`an7583`，内核 6.12）——XG 那条线可走稳定版 |
| 官方包索引架构 | a53 / a72 / a76 / **aarch64_generic** / x86_64；**没有 aarch64_cortex-a55** |

所以 `先做 tyfza1` 的第一步不是写固件，是回答一个问题：**25.12.6 承载得了这套端口吗**。
`base-probe.yml` 就是干这个的，三道门槛按顺序给硬结论：

1. `scripts/port-overlay.sh` 把端口铺到指定基座（**故意不做上游那句 HEAD==PIN 断言**），
   `openwrt-patches/*.patch` 逐个 `git apply --check`，打不上就一条条列出原因并 `exit 2`；
2. 检查目标声明的 `KERNEL_PATCHVER` 在这棵树里有没有版本文件（没有 → `exit 3`，这就是答案）；
3. 过了才 `make defconfig` 验 WiFi 驱动能否被选中，再按需编内核与驱动。

输入项：`openwrt_ref`（`v25.12.6` / `openwrt-25.12` / `master`）、`kernel_patchver`（强制降级试验）、
`do_defconfig`、`do_kernel_build`。

## 开源面（整合对象，都不 fork，按 SHA 取）

- `LeoooChen/PonWRT-TYFZA1`（53★）— 端口本体：rtl9617c target、`rtl_ax_ap` 驱动、PE 卸载、`tyfza1-*` 包。
- `LeoooChen/U-Boot-TYFZA1`（14★）— 原生 U-Boot 与网页恢复流程（刷写前置）。
- `lyq1996/rtl9617c-uboot`·`-factory`·`-migration-tools`（5★/2★/2★，本周仍在更新）— 刷写、原厂分区与迁移工具链。

GitHub 上 tyfza1/rtl9617c 的公开仓库搜索命中就是上面这些，没有更多可"结合"的现成适配。

## 软件源策略（按"不用自建源"的要求）

设备是 `aarch64_cortex-a55`，官方与 daeuniverse 都**不发**这个架构的索引，只有
`aarch64_generic`。能否让 a55 设备直接使用 generic 索引，取决于 apk 的架构匹配 ——
我不猜：由构建打印镜像里真实的 `/etc/apk/arch` 并用 host apk 实跑 `apk update` 给结论，
验过才写进固件；验不过我会把原因贴出来并给替代方案，而不是默默塞一条永远 404 的源。

## 已知风险（另开一条任务跟踪）

设备出现非预期自动重启。**没有重启前的日志不修**：本仓库的固件默认带崩溃取证
（pstore/ramoops + 日志持久化 + 看门狗来源审计），先拿到证据再定位。
