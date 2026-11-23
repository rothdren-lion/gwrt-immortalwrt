# WORKLOG 2026-11-13 — R68S (RK3568 eMMC) GitHub 构建

## 需求

用户要求编译 Lunzn FastRhino R68S（RK3568）固件：

- 明确是 **eMMC** 机型（`rk3568-fastrhino-r68s.dts`），不是 R66S 的 TF 卡
  （`rk3568-fastrhino-r66s.dts`）
- 硬件：2x 2.5G RTL8125（PCIe）+ 2x 1G GMAC（RGMII）
- 插件集合同 SS-01，但驱动用 R68S 自己的；把 passwall 换成 daed
- 在 GitHub Actions 编译

## 源码改动

分支 `r68s-261113-01`（基于远端 master `48c54a2`，最终 `3ec1483`）：

1. `gwrt-mk-r68s-config.sh`（新增）
   - 以 `config.ss01-261101-01-nss` 为插件集
   - 切到 `rockchip/armv8 DEVICE_lunzn_fastrhino-r68s`
   - 去掉 SS-01 的 ath11k/ipq-wifi/qca-nss/qca-ssdk/qca PHY/USB-QCOM/NSS 固件
   - 去掉 passwall，保留 daed/daed-geoip/daed-geosite/luci-app-daed
   - eMMC 分区：256M kernel + 4096M rootfs；保留 sgdisk/e2fsprogs/f2fs-tools
2. `target/linux/rockchip/image/armv8.mk`
   - R68S 显式 `DEVICE_DTS := rk3568-fastrhino-r68s`（eMMC，非 R66S TF）
3. `gwrt-check-target.sh` / `scripts/gwrt-validate-build-config.py`
   - 新增 `r68s` 预设（rk3568/rockchip/armv8）和包校验
4. `.github/workflows/gwrt-build.yml`
   - 新增 `r68s` 选项与配置生成分支
   - 安装 `python3-pyelftools`（u-boot binman 需要）
5. `gwrt-overlays/feeds/luci/applications/luci-app-daed/Makefile`、
   `luci-app-aria2/Makefile`
   - 补回 `# call BuildPackage - OpenWrt buildroot signature` 扫描标记；
     缺这行时 `include/scan.mk` 会直接忽略包，导致 `luci-app-daed` 不进配置
6. `target/linux/rockchip/patches-6.18/901-net-dsa-yt921x-fix-build.patch`（新增）
   - 6.18.62 上补 `DSA_TAG_PROTO_YT921X`（值 36，排在 MXL862/RTL837X/RTL9303 后）
     和 `ETH_P_YT921X = 0x9988`
7. `target/linux/rockchip/files/drivers/net/dsa/yt921x.c`
   - 去掉 6.19-only 的 `dsa_port_simple_hsr_join/leave` 回调
8. `target/linux/rockchip/files/net/dsa/tag_yt921x.c`
   - 去掉 6.19-only 的 `port_fnos.h`，使用自带 `dsa_xmit_port_mask` 回退

## 构建

- 运行：`43428769652`，device=`r68s`，version=`261113-05`，release=false
- 结果：**success**，1h38m
- 产物：`gwrt-r68s-261113-05`（273,755,535 bytes）
  - `gwrt-261113-05-rockchip-armv8-lunzn_fastrhino-r68s-squashfs-sysupgrade.img.gz`
    SHA-256 `7fc27fed81463831932de58548976affccfe51971f7555ae09319546ef652a5b`
  - `gwrt-261113-05-rockchip-armv8-lunzn_fastrhino-r68s-ext4-sysupgrade.img.gz`
    SHA-256 `e24e783588ef38169dc259a2f6479a2a53522d1bedc30eb21b02d39a311b57ac`
- 本地归档：`/home/godsun/build/gwrt-releases/r68s-261113-05/`
  与 `bin-r68s-261113-05/`

## 验证

- FIT：`ARM64 OpenWrt lunzn_fastrhino-r68s device tree blob`，
  compatible `lunzn,fastrhino-r68s`，model `Lunzn FastRhino R68S`
  → 确认用的是 eMMC DTS，不是 R66S TF
- U-Boot：`U-Boot SPL 2026.07-ImmortalWrt-3ec1483`
- 分区：kernel 256M + rootfs 4G（MBR，`pine64-img`，含 U-Boot）
- 根文件系统：GWRT 261113-05 / Linux 6.18.62 / rockchip armv8 / aarch64_generic
- APK 数据库：`daed`、`daed-geoip`、`daed-geosite`、`luci-app-daed`、
  `luci-i18n-daed-zh-cn`、`kmod-r8125`、`sgdisk`、`gwrt-*` 均在；
  无 passwall 包、无 ath11k/qca-nss
- 未刷机、未连接设备、未改 eMMC

## 说明

- 日志中的 `recursive dependency detected` 是 OpenWrt kconfig 的已知告警，
  `make defconfig` 仍成功；不是构建失败
- eMMC 8GB 当前只用了约 4.3GB（256M kernel + 4G rootfs），其余未分区；
  如需用满可在后续版本调整 `CONFIG_TARGET_ROOTFS_PARTSIZE` 或增加数据分区
