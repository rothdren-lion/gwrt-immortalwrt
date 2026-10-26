# 设计：qualcommbe 新机型同步（ipq53xx / ipq95xx，BE6500 / BE10000）

日期：2026-10-26
状态：已批准（方案 A 精确版，用户确认保留本地增量机型与按需驱动补丁）

## 1. 背景与目标

用户要求从 VIKINGYFY/immortalwrt 的 `owrt` 分支引入新机型与驱动：

- **Xiaomi BE6500**（IPQ5312，ipq53xx 子目标，全新子目标）
- **Xiaomi BE10000 / BE10000 Pro**（IPQ9570 / IPQ9574，ipq95xx 子目标）

本地树为 immortalwrt master 快照（cb793d3，浅克隆，1558 处未提交本地定制，
涉及 airoha/mediatek 等），当前 `target/linux/qualcommbe` 只有 ipq95xx 骨架
（kiwi-dvk、sbe1v1k、rdp433、xfinity_xer5 四台设备）。

**关键前提**：两树内核同为 **6.18.55**（LINUX_KERNEL_HASH 完全一致），
上游 qualcommbe 补丁可整套套用。

## 2. 上游基准

- 仓库：https://github.com/VIKINGYFY/immortalwrt
- 分支：`owrt`，commit `3205cb9a378cbcc34a798d07521f7e59b3964ad1`
- 参考副本：`/home/godsun/tmp-vky/vky-owrt/immortalwrt-owrt/`（tarball 解包，
  可随时用 codeload 重下）
- 说明：上游 owrt 的 generic 补丁集比本地新（多 160 个、重组 72 个、少 86 个），
  本次**只取 qualcommbe 及其依赖**，不整体对齐 generic（见 §5）

## 3. 变更范围

### 3.1 `target/linux/qualcommbe/` 整目录对齐上游 + 保留 XER5

| 动作 | 内容 |
|---|---|
| 新增 | `ipq53xx/`（target.mk、config-default、base-files）、`image/ipq53xx.mk`、`image/glinet_gl-be6500.bootscript` |
| 新增 | ipq53xx 全部 DTS：`ipq5332-common*.dtsi`(3)、`ipq5312-be6500.dts`、`ipq5300-be3600-pro-wired-*`(3)、`ipq5322-{gl-be6500,re-cs-06,re-cs-08}.dts`、`ipq5332-u7-pro-xgs.dts` |
| 新增 | ipq95xx 新设备 DTS：`ipq9574-common*.dtsi`(3)、`ipq9554-{be7000,linksys-ln6001}.dts`、`ipq9574-{be10000-pro,be7000-pro,beacon10}.dts`、`ipq9570-be10000.dts` |
| 更新 | `Makefile`（SUBTARGETS += ipq53xx；DEFAULT_PACKAGES 增加 kmod-ath12k、kmod-dsa-qca8k、kmod-phy-qca83xx、kmod-qrtr-mhi/smd 等） |
| 更新 | `config-6.18`（仅 34 行差异）、`ipq95xx/target.mk`、`image/ipq95xx.mk` |
| 更新 | `ipq95xx/base-files/`：01_leds（新增）、02_network、platform.sh、11-ath12k-caldata、11-ath11k-caldata（新增）、ln6001.sh（新增）、init.d、uci-defaults |
| 更新 | `ipq9570-kiwi-dvk.dts`、`ipq9570-sbe1v1k.dts`（改用上游 ipq9574-common.dtsi 结构） |
| 替换 | `patches-6.18/` 整目录换上游版（约 230 个）：本地 0322、0335、0336、0357–0361 已被上游 0323-01..08 重组取代；新增 IPQ5332 NSSCC/CMN PLL、QCA8386 DSA、PPE 桥接与 L3 流表 offload、ath11k/ath12k remoteproc、IPQ5332 USB3 uniphy 等 |
| 保留 | **XER5（本地增量机型）**：`dts/ipq9574-xfinity-xer5.dts` 原样保留；`image/ipq95xx.mk` 的 xer5 Device 块原样保留；`ipq95xx/base-files/etc/board.d/02_network` 与 `lib/upgrade/platform.sh` 的 xer5 case 合并进上游版 |

ipq53xx 子目标设备（随 ipq53xx.mk 全量带入）：xiaomi_be6500、
xiaomi_be3600-pro-wired-p5/p8、glinet_gl-be6500、jdcloud_re-cs-06/08、
ubnt_u7-pro-xgs。ipq95xx 新增：xiaomi_be7000/-pro、xiaomi_be10000/-pro、
linksys_ln6001、nokia_beacon10。

### 3.2 `package/firmware/` 配套同步

| 包 | 动作 |
|---|---|
| `ipq-wifi` | 对齐上游 **src 构建版**（src/ 6.1MB 板卡源文件；新增 xiaomi_be6500、xiaomi_be10000、xiaomi_be10000-pro 条目） |
| `ath12k-firmware` | **新增**（ddwrt 固件包，git 源 VIKINGYFY/ath12k-firmware-ddwrt；ipq53xx target.mk 的 DEFAULT_PACKAGES 依赖 ath12k-firmware-ipq5332-ddwrt / -qcn9274-ddwrt） |
| `linux-firmware` | `qca_ath11k.mk`、`qca_ath12k.mk` 取上游版 |
| `ath11k-firmware`、`wireless-regdb` | 取上游版 |

### 3.3 新增脚本（编译树工作流）

- `scripts/gwrt-sync-qualcommbe.sh`：把源码树全量 rsync 到
  `/home/godsun/build/immortalwrt-qualcommbe`（排除 `.git`、build_dir、
  staging_dir、tmp、dl、bin、.gwrt-logs、*.log、config.* 备份），首次建树与
  以后核心树更新都用它（一条命令）
- `gwrt-mk-qualcommbe-config.sh`：生成验证用最小配置
  （qualcommbe/ipq95xx + ipq53xx，选中 xiaomi_be10000、xiaomi_be6500、
  xfinity_xer5）
- `gwrt-build-qualcommbe.sh`：编译脚本（模式同 gwrt-build-wr630ax.sh，
  显式 REVISION）
- 编译树内 dl/ 软链到源码树 dl/ 复用下载缓存

### 3.4 编译树

- 位置：`/home/godsun/build/immortalwrt-qualcommbe`
- 空间：/home 剩 39G；源码净重 4.9G + aarch64 工具链约 2G + 内核×2 子目标
  约 10–15G，预计 15–20G，可容纳
- 日常插件更新（主题/agent 等）不依赖本脚本：改源码树后跑既有的
  `sh scripts/gwrt-sync-mesh.sh /home/godsun/build/immortalwrt-qualcommbe`

## 4. XER5 保留细节（防回归）

- DTS、Device 块、PACKAGE（kmod-ath12k、ath12k-firmware-qcn9274、
  rtl826x-firmware）一字不动
- 02_network / platform.sh 合并时 xer5 的两个 case（board detect + upgrade）
  必须仍在
- 验证：CONFIG 中 xer5 仍可被选中（mk-config 默认选上）

## 5. `target/linux/generic` 处理（重要决策）

**本次不动 generic**。依据（已静态验证）：

- 上游 qualcommbe PPE 流表 offload 补丁（0506/0507/0514 系）**不引用** 675 系
  bridge-flowtable 补丁新增的符号（dev_fill_bridge_path /
  DEV_PATH_BR_VLAN_KEEP_HW / nf_flow_rule_route_* 均无命中）
- qcomsmem（403）、fitblk（512–515）非 qualcommbe 硬依赖（smem 分区解析器
  内核 6.18 已自带）
- generic 未动 → mediatek/airoha 构建零影响（内核同基线）

若编译报缺符号：按报错从上游 generic 精确补对应补丁，并在 WORKLOG 记录。

## 6. 明确不做的事

- 不碰 `target/linux/{mediatek,airoha,generic,ipq40xx,...}` 等其它目标
- 不碰本地 1558 处未提交修改（提交时只 add 本次涉及路径）
- 不引入 NSS/QSDK 用户态包（上游走内核内 PPE offload）
- 不升级 tools/、toolchain/、include/ 基线
- 不动 feeds.conf.default 与 feeds/

## 7. 验证标准

1. `git status` 仅出现 §3 所列路径
2. 编译树 `make defconfig` 通过
3. `qualcommbe/ipq95xx`：编出 `xiaomi_be10000`（kernel + sysupgrade.bin）
4. `qualcommbe/ipq53xx`：编出 `xiaomi_be6500`（kernel + sysupgrade.bin）
5. `xfinity_xer5` 设备仍可编译选中（冒烟：编 kernel）
6. 源码树 mediatek 现有 .config 冒烟 `make defconfig` 不报错（generic 未动的
   回归检查）

## 8. 风险与回滚

| 风险 | 应对 |
|---|---|
| 上游 qualcommbe 补丁与本地 generic 补丁个别冲突 | 内核同 6.18.55，概率低；编译暴露后逐个处理 |
| ath12k-firmware 需构建时联网 git | 失败则手动放入 dl/ 缓存 |
| ipq-wifi src 构建版首次编译 | 按上游 Makefile 原样走，出问题对照上游 CI |
| 磁盘紧张（39G） | 编译树独立，异常可直接 rm；只编 3 台设备控制 build_dir 体积 |

回滚：所有源码树改动单独成 commit（可多个），`git revert` 即回滚；
编译树独立目录，`rm -rf` 即回收。

## 9. 实施顺序（概要，详细计划见实施 plan）

1. 源码树：qualcommbe 对齐 + XER5 合并 → 提交
2. 源码树：package/firmware 同步 → 提交
3. 新增 sync/mk-config/build 脚本 → 提交
4. 建编译树（sync 脚本 + dl 软链）
5. mk-config → defconfig → 编译验证（§7）
6. WORKLOG 记录
