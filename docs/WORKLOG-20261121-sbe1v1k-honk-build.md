# WORKLOG 2026-11-21 — SBE1V1K (Askey RTQ7300T, IPQ9570) Honk 构建接入

## 任务

按用户要求：用 GWRT 当前共享层 + 与 SS-01（Honk + EasyTier 构建）相同的插件
配置，接入新机型 Askey SBE1V1K（IPQ9570，qualcommbe/ipq95xx，eMMC），推
GitHub master 并触发 Actions 编译。

## 硬件定位

- 设备 profile：`askey_sbe1v1k`（`target/linux/qualcommbe/image/ipq95xx.mk`），
  FitImage + EmmcImage（产物 `factory.bin` / `sysupgrade.bin` tar）。
- 无线：IPQ9570 内置 2.4/5G 走 ath11k-ahb（`ath11k-firmware-ipq9574-ddwrt`），
  PCIe QCN9274 6G 走 ath12k（`ath12k-firmware-qcn9274-ddwrt`，image mk 自带）。
- 有线 Realtek phy（`kmod-phy-realtek rtl826x-firmware kmod-hwmon-pwmfan` 由
  image mk 自带）；PPE 数据面补 `kmod-qcom-ppe` + `kmod-qrtr-mhi`。

## 交付文件

- `gwrt-mk-sbe1v1k-config.sh` — 配置生成器（tyfza1 骨架）：
  - 插件集 = SS-01 Honk + EasyTier 构建：honk(Doona Lite v0.1.0-beta.6) +
    mesh 四件套 + gwrt-wifiroam-v5 + gwrt-tv-adblock + easytier/iptv/smartdns
    LuCI + OAF + bandix-plus/ttyd + luci-theme-gwrt + coremark + 网络基础。
  - 与 tyfza1 的差异：去掉 rtl 内核内无线栈与 PON 用户态（不适用）；不 unset
    kmod-mac80211/kmod-cfg80211（ath11k/ath12k 是 backports 驱动，必须保留）。
  - 存储：eMMC，不装 NAND/UBI 工具链，换 ext4/f2fs + automount。
  - `CONFIG_KERNEL_DEBUG_INFO_BTF=y` 在生成器内打开（不动 target config，
    不影响 cs06/cs08/be6500/xer5 预设），vmlinux-btf-builtin 占位。
- `configs/sbe1v1k-feeds.conf` — 与 tyfza1-feeds.conf 相同锁定 revision，
  去掉 PON 两个 feed（非光猫设备）。
- `gwrt-check-target.sh` — PRESETS 表新增
  `sbe1v1k  ipq95xx  qualcommbe  ipq95xx  DEVICE_askey_sbe1v1k`。
- `.github/workflows/gwrt-sbe1v1k-build.yml` — 照 gwrt-tyfza1-build.yml：
  honk 源码锁定 v0.1.0-beta.6、Rust stable+nightly(rust-src)、pinned
  bpf-linker；输出目录 `bin/targets/qualcommbe/ipq95xx/`；上传
  `*sysupgrade*` 与 `*factory*`（EmmcImage 无 itb/rootfs 单件）。

## 验证

- `sh -n` 两脚本语法通过；workflow YAML 解析 18 步。
- `gwrt-check-target.sh --list` 新行正确。
- NAS 树 `tmp/.config-target.in` 含
  `TARGET_qualcommbe_ipq95xx_DEVICE_askey_sbe1v1k`（设备 symbol 真实存在）。
- 完整 defconfig 收敛与包断言由 CI「Generate SBE1V1K config」步骤验证
  （make defconfig + check-target + grep 断言），本地树无 feeds 无法复现。

## 风险 / 后续

- ath11k-ahb（IPQ9574 内置 radio）+ ath12k（QCN9274）组合在 qualcommbe 6.18
  的实际运行未上机验证。
- honk 依赖内核 BTF；qualcommbe patches-6.18 下 BTF 生成若失败会在编译期
  暴露（需 pahole/dwarves，CI 已安装）。
- 编译产物暂未实机刷写；`factory.bin` 为 eMMC raw rootfs 镜像，刷写方式待
  与设备分区布局核对。
