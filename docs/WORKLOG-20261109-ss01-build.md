# WORKLOG 2026-11-09 — SS-01 主题与网口验证固件

## 范围与状态

用户在主题/网口诊断后要求恢复编译，先只编译 SS-01。其它机型继续停止。
版本 `261109-01`，设备 `jdcloud_re-ss-01`；仅交付 factory 与 sysupgrade。
本轮不刷机、不重启路由器。有线修复仍需新固件实机验证。

隔离构建工作树：`/home/godsun/build/gwrt-ss01-261109-01`，分支
`ss01-theme-ethernet-261109`，基于云端 master
`ce4a0e2802f4d4b1a8e9d884c95ad56fd4684e95`。没有重置 NAS 或旧 CI 树的未提交改动。
云端使用 `rothdren-lion/gwrt-immortalwrt` 的 `gwrt-build.yml`，J6、CPU 0–5。

## 分区证据

通过 `/dev/ttyACM0` 115200 串口只读检查物理 SS-01，型号/compatible 匹配。
`/sys/class/block/*/uevent` 与 `size` 确认：

| 分区 | 设备 | 512 字节扇区数 | 容量 |
|---|---|---:|---|
| 0:HLOS | mmcblk0p16 | 24576 | 12 MiB |
| 0:HLOS_1 | mmcblk0p17 | 12288 | 6 MiB |
| rootfs | mmcblk0p18 | 2097152 | 1 GiB |
| rootfs_1 | mmcblk0p20 | 122880 | 60 MiB |

`0:BOOTCONFIG` 位于 mmcblk0p2，偏移 148 的值为 0；当前 platform.sh 的 eMMC
升级逻辑因此使用主分区 `0:HLOS/rootfs`。当前 /rom 也来自主 rootfs。
保留已有设备定义 `KERNEL_SIZE := 12288k`，成品明确标注 `12M`。
技能旧版的 SS-01 固定 6M 说明不适用于这台已经调整过主分区的实机，不能据此回退。
证据保存在 `/tmp/ss01-{partitions,upgrade-layout,bootconfig}-20261109.log`，归档时一并保存。

## 修复与检查

- 保留现有 DD-WRT IPQ6018 AHB 无线固件、SS-01 校准包和 wpad-openssl。
- SS-01 DTS 使用匹配 NSS 驱动的 ESS/EDMA/dp2–dp5，映射 lan1/lan2/lan3/wan。
  配置及 DEVICE_PACKAGES 加入 kmod-qca-nss-dp，保留 kmod-qca-ssdk。
- 主题 r114 禁止 CSSTidy 压缩，保留完整现代 CSS；资源缓存版本 20261109r114。
  首页型号显示 IPQ6010 × 4，流量明细按每 5 秒采样标注。
- 关闭 SS-01 seed 的 initramfs，保持仅 squashfs factory/sysupgrade。
- 新增 `scripts/gwrt-verify-ss01-image.py`，云端成品拆包核对两种镜像 SHA256、
  factory 12M rootfs 偏移、嵌入 DTB 的 ESS/EDMA/四端口、七个主题文件逐字节一致、
  NSS DP 自动加载、DP/SSDK 模块以及最终主题包版本。

本地 `check-target-profile.sh ss01`、项目配置校验器和项目 source-preflight 已通过。
构建工作树仅临时链接现有 luci feed 做源码检查，未更新或覆盖脏 feed。
云端重新安装 feeds 并在 make defconfig 后再次验证实际配置。

技能附带的旧 preflight 仍假定历史 gwrt-bandix/turboacc/unishare 路径，并要求
base-files 中已经改写的字面 pi_ip 表达式；与当前仓库布局不符。没有修改无关插件来
迎合旧规则，改用云端已经调用的 `scripts/gwrt-source-preflight.sh`，覆盖主题副本、
CSS 开关、JS/shell/JSON、LAN 默认值、型号筛选、SoC 和 APK 首次恢复行为。

## 交付与待办

通过全部成品检查后归档至 `/home/godsun/build/gwrt-releases/ss01/`。
当前历史 `/home/godsun/work` 和 `/home/godsun/openwrt-rom` 均指向未挂载的 SSD，
因此本轮使用仍可用的本地交付根目录；只给用户两份带 12M/版本标记的固件。
诊断材料、manifest/hash 证据保存在 build 下单独备份目录。

待完成：推送、只触发 SS-01、检查构建结果和成品、记录运行链接与 SHA256。
