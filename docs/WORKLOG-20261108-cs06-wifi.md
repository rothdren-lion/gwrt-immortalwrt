# WORKLOG 2026-11-08 — CS-06 无无线日志与修复候选

## 用户范围

本轮只构建：RE-CS-06、TR3000 256MB v1、360T7 原厂 DTS（不选 UBI）、
RE-CS-02、RE-CS-02-GWRT2、RE-CS-07、S20P。S20P 必须带 PCI/NVMe。
CS-01 尚无对应 profile，不用其它设备代替。CS-07 为无无线硬件，不加入无线驱动。
交付只收 factory（设备支持时）和 sysupgrade 镜像。

## 日志证据

用户提供 `/home/godsun/Downloads/log-11.7.rar` 和 `log-11.8.rar`。
两份日志在同一步失败：

```text
Booting fw image ath12k/IPQ5332/hw1.0/q6_fw0.mdt, size 11812
error -5 initializing firmware ath12k/IPQ5332/hw1.0/q6_fw0.mdt
Failed to load program segments: -5
RootPD boot failed
failed to boot the remote processor Q6
probe with driver ath12k_wifi7_ahb failed with error -5
```

后续 PCI QCN9274 HW2.0 被识别，选择 board ID 0x2，但未见无线注册成功。
现有 WSI 设备组包含 AHB 和 PCI 两个成员，不能把 PCI 枚举成功等同于 AP 可用。

`firmware-2.bin` 缺失不是本次确认的漏包：IPQ5332 使用 split MDT/API-1，
`ath12k_fw_map()` 在 API-2 请求失败后回退 API-1；所固定的专用固件仓库本来
没有这个文件。不能创建空文件或把其它芯片固件改名替代。

## 源码遗漏与候选修复

逐步追到 `qcom_mdt_pas_init()`：日志中的 `initializing firmware` 错误由
`qcom_scm_pas_init_image()` 返回，发生在程序段拷贝和 Q6 启动之前。
因此不能先归因为 SSID、hostapd 或板级校准数据。

当前补丁集已引入 WCSS secure PIL 驱动，却缺少同系列的 SCM 元数据长度补丁。
高通上游明确说明 IPQ5332 TrustZone 需要这个长度：

<https://lore.kernel.org/r/20260803-rproc-v14-1-a1f87b0b0ad2@oss.qualcomm.com>

新增 `2010-00-firmware-qcom-scm-pass-IPQ5332-PAS-metadata-size.patch`，
适配本树 Linux 6.18 的 SCM 实现：探测 PAS INIT_IMAGE_V2（0x1a），支持时
使用三个参数传递 metadata size；不支持时保留旧命令。没有绕过固件认证，
没有改动 DTS、校准偏移、固件字节或专用固件策略。

固件源归档中 q6_fw0.mdt 恰为 b00 + b01，长度 11812；SHA-256 为
`cbeaccd7f7dae3a751594c9640e47f9b2a892c7e92b40398ed38c297fbbed79e`。
上游 2026-11-07 刷新未改变这套 IPQ5332 的 MDT/分段文件，故本次不盲升固件。

这是一项已确认的源码遗漏，也是当前有依据的修复候选；仍需实机验证它是否
解释本机全部故障。不能在新日志确认前宣称 Wi-Fi 已恢复。

## 验证与编译

- 新补丁以 `patch --fuzz=0` 应用到现有 qualcommbe/ipq53xx Linux 6.18.55 内核，
  两个文件均无 reject。
- 使用现有 aarch64 GCC 14.4 工具链、J6、CPU 0–5 重新交叉编译
  `drivers/firmware/qcom/qcom_scm.o`，退出码 0。
- `sh scripts/gwrt-source-preflight.sh` 通过：主题副本、JS/shell/JSON、
  aria2、机型筛选、SoC 线程显示、固件收集和 APK 首次恢复检查通过。
- 技能旧 audit 仍假定已不存在的包目录，并误要求 LAN Makefile 使用字面量；
  本树采用已有 `$(if CONFIG_TARGET_PREINIT_IP,...)` 回退配置，实际默认地址仍为
  192.168.3.3/24。该历史差异见 2026-11-07 工作记录，不为旧检查器重写原配置。
- 未连接、刷写或重启用户设备。

旧 CS-06 单独编译 run `42479128610` 已取消，防止未修复镜像自动发布。
选定队列 run `42478183710` 的旧 CS-06 配置筛选失败已另行修复，MT7981
仍在运行；此记录不表示新固件已完成或通过实机验收。
