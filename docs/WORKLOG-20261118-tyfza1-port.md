# WORKLOG 2026-11-18 TYFZA1（Realtek RTL9617C）平台迁入 gwrt-immortalwrt

用户要求：把 PonWRT-TYFZA1-new 里这套 rtl 平台所需的驱动与配置复制到
`rothdren-lion/gwrt-immortalwrt`，内核与 an7581 序列同步，插件/主题配置与整个
项目保持一致，且不影响其它 SoC。

## 结论

- **源码移植完成**：`target/linux/rtl9617c/` 全量（240 文件）+ 三个 PON 包已进树；
  主题依赖已改为 `luci-theme-gwrt`；配置生成器与编译脚本就位。
- **补丁栈验证通过**：在真实 ImmortalWrt generic 补丁栈（backport 180 + pending 213
  + hack 71）之上按 OpenWrt 顺序应用 `target/linux/rtl9617c/patches-6.18` 36 个补丁，
  `patch` 零失败、无 `.rej`（vanilla 内核单独测试时失败的 205/211/231 在这里全部干净）。
- **未编译、未刷机**：当前工作副本位于 gvfs SMB 挂载点，路径含冒号，OpenWrt 无法在
  该路径编译（见「已知限制」）；共享盘当时也处于降级状态（目录列举 8.6 秒、tar 读取
  挂起），无法完成本地全量拷贝后编译。

## 改动清单（全部为新增或只影响新设备）

新增：

- `target/linux/rtl9617c/`：Makefile（aarch64 / cortex-a55 / KERNEL_PATCHVER 6.18）、
  `config-6.18`、`modules.mk`（`kmod-rtl-ax-ap`、`kmod-tyfza1-usb-led`）、
  `patches-6.18/`（36 个）、`files-6.18/`（150 个驱动源文件）、`dts/`（12 个）、
  `image/Makefile`、`base-files/`、`generic/`、`python/`。
- `package/tyfza1-pon-control/`（25 文件）、`package/tyfza1-storage/`（6 文件）、
  `package/luci-app-tyfza1-pon/`（19 文件）。
- `gwrt-mk-tyfza1-config.sh`、`gwrt-build-tyfza1.sh`。

修改：

- `package/luci-app-tyfza1-pon/Makefile`：`LUCI_DEPENDS` 由
  `+luci-theme-argon +luci-i18n-argon-config-zh-cn` 改为 `+luci-theme-gwrt`。
- 删除 `package/luci-app-tyfza1-pon/root/etc/uci-defaults/95-tyfza1-argon`
  （会把默认主题强制切回 Argon）。
- `target/linux/rtl9617c/image/Makefile` 重写为自包含：原来依赖 PonWRT 仓库的
  `port/tools/make_boot_fit.py`（其 import 会读 `port/sources.lock.json`），改为
  使用同目录自写的 `python/make_ubi_fit.py`，签名密钥改为可选
  （`TYFZA1_SIGNING_KEYS`，空则输出未签名 FIT 并在 stderr 警告）。
- 删除 `target/linux/rtl9617c/base-files.mk`：它把 apk 源固定到
  `downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53`，与本树的
  ImmortalWrt feed（cortex-a55）冲突，改用仓库默认。

未改动：`target/linux/generic/`、`package/kernel/mac80211/`、其它 target、feeds。

## 与 an7581 序列的一致性

| 项目 | an7581 | tyfza1 |
|---|---|---|
| 内核线 | 6.18 | 6.18（`CONFIG_LINUX_6_18`） |
| mesh 四件套 | gwrt-device-defaults / gwrt-mesh-led / gwrt-mesh-apmode / gwrt-agent | 同 |
| 广告拦截 | gwrt-tv-adblock / luci-app-gwrt-tvadblock | 同 |
| 主题 | luci-theme-gwrt | 同 |
| 额外 | PON 用户态（AN7581 自有） | tyfza1-pon-control / tyfza1-storage / luci-app-tyfza1-pon + luci-app-pon-wan |

无线栈差异：rtl9617c 把 cfg80211/mac80211 编在内核树里（`patches-6.18/203..221`
改的是 `net/mac80211/`），`kmod-rtl-ax-ap` 直接打包 `mac80211.ko` 与
`rtl_ax_ap.ko`。因此配置生成器显式关闭 `CONFIG_PACKAGE_kmod-mac80211` 与
`kmod-cfg80211`，否则与 backports 7.2 同名模块冲突。

## 已知限制（编译前必读）

1. **不能在 SMB 路径编译**。本工作副本路径含冒号
   （`/run/user/1000/gvfs/smb-share:server=...`），GNU make 会把
   `include/toplevel.mk:65` 的规则解析成静态模式规则并报
   `*** 目标模式不含有“%”`；实测 `make defconfig` 在该路径直接失败。
   编译请在无冒号的本地副本进行（如 `/home/godsun/build/gwrt-tyfza1`），
   源码改动仍以 SMB 工作副本为准。
2. **FIT 签名缺密钥**。原仓库用
   `evidence/rtl-workspace/private/tyfza1-build-keys`，本机没有。未签名 FIT 能否被
   原厂 U-Boot 接受需实机确认；若必须签名：
   `TYFZA1_SIGNING_KEYS=<keys 目录> TYFZA1_MKIMAGE=/usr/bin/mkimage make ...`
   （staging 的 mkimage 未开 TOOLS_LIBCRYPTO）。
3. FIT 上限 0x600000 字节由脚本强制检查；rootfs 上限 33648640 字节由
   `tyfza1-rootfs-size` 检查。

## 编译步骤

```sh
# 1) 本地副本（无冒号路径）
mkdir -p /home/godsun/build/gwrt-tyfza1
tar -C <SMB 工作副本> -cf - . | tar -C /home/godsun/build/gwrt-tyfza1 -xf -
# 2) 生成配置 + 编译
cd /home/godsun/build/gwrt-tyfza1
sh gwrt-build-tyfza1.sh 6 261118-01
# 产物：bin/targets/rtl9617c/generic/gwrt-rtl9617c-generic-tianyi_tyfza1-*sysupgrade.bin
```

## 待办

- [ ] 在本地副本跑通 `make defconfig` + `make world`，产物拆包核对
      `kmod-rtl-ax-ap`、`mac80211.ko`、PON 三个包、gwrt 主题 r122。
- [ ] 确认未签名 FIT 是否需要签名（实机或查原厂 U-Boot 校验逻辑）。
- [ ] 实机刷入验证：PON WAN 起链、2.4G/5G 广播与关联、mesh 配对。
- [ ] GitHub 恢复推送后，把本 target 加入 CI 构建矩阵。
