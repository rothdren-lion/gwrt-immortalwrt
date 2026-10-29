# WORKLOG 2026-10-26 — qualcommbe ipq53xx/ipq95xx 同步 + CS-06 (RE-CS-06) 集成

## 目标

从 VIKINGYFY/immortalwrt `owrt` 分支（commit 3205cb9）引入新机型与驱动：

- **京东云 RE-CS-06**（IPQ5322，eMMC，QCA8386 交换，ath12k AHB 内置 WiFi）← 本次主要交付
- 小米 BE6500（IPQ5312）、BE10000/BE10000 Pro（IPQ9570/9574）、BE7000(-Pro)
- GL.iNet GL-BE6500、京东云 RE-CS-08、Ubiquiti U7-Pro-XGS、be3600-pro-wired、Linksys LN6001、Nokia Beacon10
- 保留本地增量机型 **Xfinity XER5**（未推上游，仅本地）

## 源码树提交（全部本地，无任何上游推送）

| commit | 内容 |
|---|---|
| 15fb34c | qualcommbe 整目录对齐上游（ipq53xx 新子目标 + ipq95xx 扩充 + patches-6.18 约 228 个），XER5 dts/设备块/02_network/platform.sh case 回植 |
| 0ab23a4 | package/firmware：ipq-wifi src 构建 + ath12k-firmware(ddwrt) 新增 + qca_ath11k/12k.mk + ath11k-firmware + wireless-regdb |
| 8dff4aa | kernel：mac80211 整目录同步（ath12k ATH12K_AHB / PPE_DS；6 个本地独有补丁全部有上游等价物）+ netdevices.mk（dsa-qca8k 依赖）+ netsupport.mk（qrtr-smd 允许 qualcommbe） |
| bdefc15 | 脚本：gwrt-mk-cs06-config.sh / gwrt-build-cs06.sh / scripts/gwrt-sync-qualcommbe.sh |

## 关键决策与坑

1. **内核基线一致**：两树同为 6.18.55（hash 相同），上游补丁直接可用。
2. **`target/linux/generic` 未动**：PPE 流表补丁不依赖 675 系桥接流表补丁（无符号引用），
   避免影响 mediatek/airoha。
3. **mac80211 必须同步**：IPQ5332 内置 WiFi 靠 `ATH12K_AHB`（同一 kmod-ath12k 编译开关，
   无独立 -ahb 包），上游 ath.mk 才有；本地 6 个独有补丁（950 CE-irq-AHB / 100 ltssm /
   984 atomic-rx / 949 monitor / 410 debugfs / 311 DFS-AP）全部被上游等价补丁取代。
4. **kmod-qrtr-smd / kmod-dsa-qca8k 的 DEPENDS 更新是硬依赖**：
   `@TARGET_qualcommax` → `@(qualcommax||qualcommbe)`，否则 ath12k 依赖断裂。
5. **设备 choice 陷阱（配置派生）**：cs-02 设备（`jdcloud_re-cs-02-gwrt2`）必须与
   `DEVICE_jdcloud_re-cs-06=y` 同时处理（停旧 + 启新 + 改 PROFILE），否则 defconfig 回退旧机型。
6. **显式 n 压过 default y**：cs-02 基准有 `# CONFIG_PACKAGE_kmod-ath12k is not set`，
   defconfig 后 kmod-ath12k 仍是 not set（`default y if DEFAULT_kmod-ath12k` 被显式 n 压制）。
   修复：mk 脚本对 qualcommbe 目标默认包列表删除陈旧 not-set 行（只删行，不硬置 =y）。
7. **rsync 排除锚定**：`--exclude=bin` 会误杀 `package/base-files/files/bin`（系统脚本），
   必须写 `--exclude=/bin`（顶层锚定）。已修复并重新同步。
8. **CS-06 是 eMMC**：上游定义 `FitImage + EmmcImage`（KERNEL_SIZE 7168k，config@mi01.6），
   DTS 只有 mmc 无 NAND；配置派生不迁移 cs-02 的 NAND 内核选项。

## CS-06 配置（config.cs06-261026-01）

- 基准：`config.cs02-gwrt2-261021-04`（插件集照搬，632 包 vs 基准 640，差值 = ath11k 全家 + cs-02 ipq-wifi）
- 保留：kmod-ath / kmod-mac80211 / kmod-cfg80211 / wpad-openssl / luci-theme-gwrt / gwrt-agent
- 自动带出（defconfig select）：kmod-ath12k、ath12k-firmware-{ipq5332,qcn9274}-ddwrt、
  ipq-wifi-jdcloud_re-cs-06、kmod-qcom-ppe、kmod-dsa-qca8k、kmod-phy-qca83xx、kmod-qrtr-mhi/smd
- ath11k 残留：0；NAND_SUPPORT=y 来自 qualcommbe 目标自身 config（be10000 是 NAND，无害）

## 编译树

- `/home/godsun/build/immortalwrt-qualcommbe`（401M，dl 软链源码树）
- 建树/核心更新：`sh scripts/gwrt-sync-qualcommbe.sh`
- 日常插件更新：`sh scripts/gwrt-sync-mesh.sh /home/godsun/build/immortalwrt-qualcommbe`
- 编译：`sh gwrt-build-cs06.sh 6 261026-01`

## 内核构建排坑记录（generic 按需增量补丁，全部为上游独有、纯新增）

| 补丁 | 作用 | 由谁触发 |
|---|---|---|
| hack-6.18/752 + 753 | rtl837x/rtl9303 8021ad 标签驱动（dsa.h VALUE 34/35 上下文） | qualcommbe 0386 (QCA_8021Q=32) / 0395 (QCA_4B=33) |
| backport-6.18/706-01 | dev_fill_forward_path 改为 net_device_path_ctx 签名 | PPE 0507-01 ppe_flowtable.c |
| hack-6.18/767 | flow_action_entry.tunnel_type（lwt 隧道元数据） | PPE 0514 隧道系 |
| hack-6.18/768 | PPP 通道生命周期事件（PPP_CHANNEL_CONNECT） | PPE 0652 dsa-pppoe |
| hack-6.18/769 | ip6_tnl_flow_offload_key | PPE 0514-05 ip6 隧道 |
| pending-6.18/775 | tc_tbf_qopt_offload_replace_params.limit | PPE 0515/0644 TBF offload |
| hack-6.18/901 | 换上游版（为 768 的 ppp_channel.o rebase） | 768 先应用后 901 上下文不匹配 |

其它坑：
- **误拷双份**：一条 cp 多源把 767/768 同时拷进了 backport 和 hack 目录，backport 先应用后
  hack 再应用必失败（同一改动应用两次）。已清理，正本在 hack-6.18。
- **新 kconfig 符号卡死 syncconfig**：752/753 引入的 NET_DSA_TAG_RTL837X/RTL9303 无 default，
  内核 .config 无答案时 kmod 注入触发 syncconfig 交互提示→报错。在两个子目标
  config-default 里显式 not set。
- **上游 675 系（bridge flowtable）与本地 699 碰 nf_flow_table_path.c**：本次未加 675；
  如后续需要 bridge flowtable offload，需先 rebase 699。
- **本地独有 mediatek/airoha 补丁（732/736/739/785/720-03..08 等）全部保留**，未做 generic 全量对齐。

## 编译结果（全部完成）

| 验证项 | 结果 |
|---|---|
| qualcommbe/ipq53xx 内核（691 补丁） | ✅ 通过 |
| **CS-06 全量镜像** | ✅ `gwrt-261026-01-qualcommbe-ipq53xx-jdcloud_re-cs-06-{squashfs-sysupgrade,factory}.bin` (120M) + initramfs-uImage.itb (118M) |
| sysupgrade sha256 | `9f3320bda09853fe3e2ef63bab6c6ff223637487cad21b8b1259539fb988620b` |
| manifest 关键包 | kmod-ath12k / ath12k-firmware-{ipq5332,qcn9274}-ddwrt / ipq-wifi-jdcloud_re-cs-06 / kmod-qcom-ppe / kmod-dsa-qca8k / kmod-phy-qca83xx / kmod-qrtr-{mhi,smd} / wpad-openssl / gwrt-agent / luci-theme-gwrt 全部在 |
| ipq95xx 内核冒烟（BE10000/XER5 子目标） | ✅ 通过 |
| BE6500 | ✅ 与 CS-06 同 ipq53xx 内核，共用验证 |
| mediatek 回归冒烟 | ✅ defconfig 通过，.config 已还原 |

全量构建日志：/tmp/cs06-full4.log；内核日志 /tmp/cs06-kernel8.log。

产物仍在编译树 `bin/targets/qualcommbe/ipq53xx/`；交付盘（/run/media/...）未挂载，
归档待用户定 cs-06 中文代号后执行（openwrt-rom/jdcloud_re-cs-06/）。

## 交付（已归档，sha256sum -c 全 OK）

| 机型 | 代号 | 归档目录 | 文件 |
|---|---|---|---|
| `jdcloud_re-cs-06` | **赵云**（= 京东云 BE6500） | `Rout/JDC-京东云/BE6500赵云/` | `gwrt-261026-01-赵云cs-06-{factory,sysupgrade}.bin` 120M<br>`...-initramfs.itb` 118M<br>`...-赵云cs-06.manifest` |
| `jdcloud_re-cs-08` | **太乙2plus**（= ER2-Plus） | `Rout/JDC-京东云/JDC-ER2-Plus-IPQ53XX太乙2/` | `gwrt-261026-01-太乙2pluscs-08-{factory,sysupgrade}.bin` 108M<br>`...-initramfs.itb` 108M<br>`...-太乙2pluscs-08.manifest` |

### cs-08 = cs-06 同方案（IPQ5322 eMMC + QCA8386），差异：

| | cs-06 赵云 | cs-08 太乙2plus |
|---|---|---|
| 无线 | ath12k 内置 WiFi（ATH12K_AHB） | **无**（整条无线栈剔除） |
| 万兆 | — | **SFP + Marvell 10G PHY**（kmod-sfp / kmod-phy-marvell / -10g） |
| 插件数 | 635 | 624 |
| 镜像 | 120M | 108M |

- 配置派生：`gwrt-mk-cs08-config.sh`（基于 config.cs06-261026-01），编译 `gwrt-build-cs08.sh`
- `libiwinfo` / `rpcd-mod-iwinfo` 因 luci-mod-network/status 硬依赖保留（~50KB，无法去）；
  ath12k 固件通过 device 定义负号 `-ath12k-firmware-*` 剔除（子目标 DEFAULT 会强制带，
  仅靠 config 改不掉）

## 验证清单

- [x] CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-06"
- [x] kmod-ath12k / ath12k-firmware-ddwrt / ipq-wifi-cs-06 / qcom-ppe / dsa-qca8k 全部 =y
- [x] ath11k 零残留
- [x] 固件产物 bin/targets/qualcommbe/ipq53xx/*cs-06*（sysupgrade/factory/initramfs）
- [x] be10000 / xer5 ipq95xx 内核冒烟（be6500 共用 ipq53xx 内核）
- [x] 源码树 mediatek .config 回归冒烟

## ⚠️ 事故：跨文件系统 mv 固件导致内容变异（已修复）

把 `bin/targets/...` 的镜像 `mv` 到 NAS（`/mnt/syNAS/.../mark/openwrt-rom`）后，
发现文件**大小不变、manifest 相同，但 sha256 与编译树记录不符**（3 个镜像全中）。

- 编译树 `bin/.../ipq53xx/sha256sums`（14:19 生成）与早先 `cp` 到 `JDC-京东云/` 的副本一致，
  说明 **cp 的副本是原件，mv 过去的那份被改动了**
- 已用副本回写 openwrt-rom，重新生成 `sha256sums`，并做结构验证：
  `tar -tf` 能列 CONTROL/kernel/root，`CONTROL` BOARD 正确，
  kernel 为 FIT(Device Tree Blob)，squashfs(xz) 可读，全部 OK

**教训：固件写入 NAS/移动介质后必须 `sha256sum` 对编译树记录复核，`mv` 不能当作“可靠传输”。**
今后归档流程固定为：先 `cp` → 校验 sha256 → 再删源（即不要用 mv 直传）。

## 后续事项

1. 实机刷机验证（eMMC 线刷 sysupgrade；京东云原厂布局 factory）
2. ath12k PPE-DS Direct Switch 运行状态检查（/sys/kernel/debug/ppe）——仅 cs-06
3. cs-08 插 SFP 模块验证 Marvell 10G PHY 链路与 2500/10000BASE-X 协商
4. 如需 bridge flowtable offload：加上游 675 系 generic 补丁（先 rebase 本地 699）
