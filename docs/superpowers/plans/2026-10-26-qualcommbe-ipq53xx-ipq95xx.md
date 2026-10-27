# qualcommbe ipq53xx/ipq95xx（BE6500/BE10000/CS-06）同步 + CS-06 配置 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans（本计划各任务写入同一棵源码树，按写入冲突红线不拆子代理，inline 顺序执行）。步骤用 `- [ ]` 跟踪。

**Goal:** 源码树引入 VIKINGYFY owrt 的 qualcommbe ipq53xx/ipq95xx 机型与驱动（保留 XER5），新建编译树，派生京东云 RE-CS-06（eMMC）配置。

**Architecture:** 整目录对齐上游 + 本地增量回植（XER5）；固件包随设备定义同步；generic 不动；CS-06 配置从 config.cs02-gwrt2-261021-04 派生（插件集照搬，剔除 CS-02 的 ath11k 栈与 ipq-wifi，eMMC 由新目标 config 自动归一）。

**Tech Stack:** OpenWrt/ImmortalWrt build system, kernel 6.18.55, uci/kconfig。

**变量约定：**
- `SRC` = /mnt/syNAS/Dowloads/Rout/mark/immortalwrt（git 源码树）
- `UP` = /home/godsun/tmp-vky/vky-owrt/immortalwrt-owrt（上游参考副本，丢失则重新下载 tarball）
- `BLD` = /home/godsun/build/immortalwrt-qualcommbe（新建编译树）

---

### Task 1: qualcommbe 整目录对齐上游 + XER5 回植

**Files:**
- 替换: `target/linux/qualcommbe/`（整目录）
- 回植: `target/linux/qualcommbe/dts/ipq9574-xfinity-xer5.dts`
- 合并: `target/linux/qualcommbe/image/ipq95xx.mk`、`target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network`、`target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh`

- [ ] **Step 1.1: 从 git 提取 XER5 本地内容到 /tmp**

```sh
cd $SRC
mkdir -p /tmp/xer5-keep
git show HEAD:target/linux/qualcommbe/dts/ipq9574-xfinity-xer5.dts > /tmp/xer5-keep/ipq9574-xfinity-xer5.dts
git show HEAD:target/linux/qualcommbe/image/ipq95xx.mk > /tmp/xer5-keep/local-ipq95xx.mk
git show HEAD:target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network > /tmp/xer5-keep/local-02_network
git show HEAD:target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh > /tmp/xer5-keep/local-platform.sh
ls -la /tmp/xer5-keep/   # 4 个文件必须都在
```

- [ ] **Step 1.2: 整目录换上游**

```sh
rm -rf target/linux/qualcommbe
cp -a $UP/target/linux/qualcommbe target/linux/
```

- [ ] **Step 1.3: 回植 XER5**

```sh
cp /tmp/xer5-keep/ipq9574-xfinity-xer5.dts target/linux/qualcommbe/dts/
# ipq95xx.mk：把 /tmp/xer5-keep/local-ipq95xx.mk 的 xer5 Device 块追加到上游文件末尾
sed -n '/^define Device\/xfinity_xer5$/,/^TARGET_DEVICES += xfinity_xer5$/p' \
  /tmp/xer5-keep/local-ipq95xx.mk >> target/linux/qualcommbe/image/ipq95xx.mk
```

02_network / platform.sh 的 xer5 case 用 edit 工具手工合并（从 /tmp/xer5-keep 的 local 版把 `xfinity,xer5)` 两个 case 按上游文件的结构插入正确位置）。

- [ ] **Step 1.4: 验证**

```sh
ls target/linux/qualcommbe/                      # 含 ipq53xx ipq95xx base-files
ls target/linux/qualcommbe/dts/ | grep -c dts    # ≥ 25
ls target/linux/qualcommbe/dts/ | grep xer5      # xer5 dts 在
grep -c xer5 target/linux/qualcommbe/image/ipq95xx.mk \
  target/linux/qualcommbe/ipq95xx/base-files/etc/board.d/02_network \
  target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh   # 各 ≥2
grep SUBTARGETS target/linux/qualcommbe/Makefile # SUBTARGETS:=ipq53xx ipq95xx
ls target/linux/qualcommbe/patches-6.18/ | wc -l # ~230
```

- [ ] **Step 1.5: 提交**

```sh
git add target/linux/qualcommbe
git commit -m "qualcommbe: sync ipq53xx+ipq95xx from VIKINGYFY owrt (BE6500/BE10000/CS-06...), keep xfinity_xer5"
```

### Task 2: package/firmware 配套同步

**Files:**
- 替换: `package/firmware/ipq-wifi/`（src 构建版）
- 新增: `package/firmware/ath12k-firmware/`
- 更新: `package/firmware/linux-firmware/qca_ath11k.mk`、`qca_ath12k.mk`、`package/firmware/ath11k-firmware/Makefile`、`package/firmware/wireless-regdb/Makefile`

- [ ] **Step 2.1: 同步**

```sh
cd $SRC
rm -rf package/firmware/ipq-wifi
cp -a $UP/package/firmware/ipq-wifi package/firmware/
cp -a $UP/package/firmware/ath12k-firmware package/firmware/
cp $UP/package/firmware/linux-firmware/qca_ath11k.mk package/firmware/linux-firmware/
cp $UP/package/firmware/linux-firmware/qca_ath12k.mk package/firmware/linux-firmware/
cp $UP/package/firmware/ath11k-firmware/Makefile package/firmware/ath11k-firmware/Makefile
cp $UP/package/firmware/wireless-regdb/Makefile package/firmware/wireless-regdb/Makefile
```

- [ ] **Step 2.2: 验证 + 提交**

```sh
grep -c "generate-ipq-wifi-package" package/firmware/ipq-wifi/Makefile   # 与上游一致
grep "xiaomi_be6500\|xiaomi_be10000\|jdcloud_re-cs-06" package/firmware/ipq-wifi/Makefile
ls package/firmware/ath12k-firmware/Makefile
git add package/firmware && git commit -m "firmware: ipq-wifi src build + ath12k-firmware (ddwrt), sync qca ath11k/ath12k firmware.mk"
```

### Task 3: 工作流脚本（sync / mk-config / build）

**Files:**
- 新增: `scripts/gwrt-sync-qualcommbe.sh`、`gwrt-mk-cs06-config.sh`、`gwrt-build-cs06.sh`
- 复制存档: `config.cs02-gwrt2-261021-04`（从 /home/godsun/build/immortalwrt 拷入源码树作为派生基准）

- [ ] **Step 3.1: gwrt-sync-qualcommbe.sh**（rsync 全树，排除编译产物与 .git；dl 用软链共享）

```sh
#!/bin/sh
# gwrt-sync-qualcommbe.sh — 源码树 → qualcommbe 编译树 全量同步
# 用法: sh scripts/gwrt-sync-qualcommbe.sh
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
DST=${1:-/home/godsun/build/immortalwrt-qualcommbe}
mkdir -p "$DST"
rsync -a --delete \
  --exclude=.git --exclude=build_dir --exclude=staging_dir --exclude=tmp \
  --exclude=dl --exclude=bin --exclude=logs --exclude=.gwrt-logs \
  --exclude='*.log' --exclude='config.*' --exclude='.config' \
  --exclude=feeds --exclude=package/feeds \
  "$SRC/" "$DST/"
[ -e "$DST/dl" ] || ln -s "$SRC/dl" "$DST/dl"
echo "==> synced $SRC -> $DST"
```

- [ ] **Step 3.2: gwrt-mk-cs06-config.sh**（从 cs-02 派生；设备 choice 陷阱：旧设备必须同时停用）

```sh
#!/bin/sh
# ---------------------------------------------------------------------------
# gwrt-mk-cs06-config.sh — 由 CS-02 (京东云亚瑟, IPQ6018 NAND) 配置派生
#                          JDCloud RE-CS-06 (IPQ5322 eMMC) 配置
#
# 用法: VER=261026-01 sh gwrt-mk-cs06-config.sh [输出目录]
#
# 派生规则（用户指定）:
#   1. 插件集照搬 CS-02（config.cs02-gwrt2-261021-04，640 包）
#   2. 剔除 CS-02 机型专属驱动（ath11k 全家 + ipq-wifi-jdcloud_re-cs-02）
#   3. 目标板切到 qualcommbe/ipq53xx DEVICE_jdcloud_re-cs-06
#   4. CS-06 自身必需驱动由设备定义/子目标默认带出，不手填:
#      ipq-wifi-jdcloud_re-cs-06、kmod-ath12k、ath12k-firmware-{ipq5332,qcn9274}-ddwrt、
#      kmod-qcom-ppe、kmod-dsa-qca8k(QCA8386)、kmod-qrtr-mhi/smd
#   5. eMMC：内核存储选项由 qualcommbe config-6.18 经 defconfig 重新归一，
#      CS-02 的 NAND 内核选项(CONFIG_NAND_SUPPORT/UBIFS 等)不迁移
# ---------------------------------------------------------------------------
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/config.cs02-gwrt2-261021-04}
VER=${VER:-261026-01}
OUT=${OUT:-${1:-$TOP/config.cs06-$VER}}
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

cp "$SRC" "$OUT"

flip() { # flip <file> <old=y 行> [新行...]
  sed -i "s|^$2\$|$( [ $# -gt 2 ] && echo "$3" || echo '# ${SRC##*/} 占位' )|" "$1"
}

# --- 1. 目标板切换（旧目标全停用 + 新目标启用，行不存在则追加） -------------
sed -i \
  -e 's|^CONFIG_TARGET_qualcommax=y$|# CONFIG_TARGET_qualcommax is not set|' \
  -e 's|^CONFIG_TARGET_qualcommax_ipq60xx=y$|# CONFIG_TARGET_qualcommax_ipq60xx is not set|' \
  -e 's|^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y$|# CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02 is not set|' \
  -e 's|^CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-02"$|# CONFIG_TARGET_PROFILE 占位|' \
  "$OUT"
cat >> "$OUT" <<EOF
CONFIG_TARGET_qualcommbe=y
CONFIG_TARGET_qualcommbe_ipq53xx=y
CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_jdcloud_re-cs-06=y
CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-06"
EOF

# --- 2. 剔除 CS-02 机型专属驱动（保留 kmod-ath/mac80211/cfg80211 公共栈） ---
for p in ipq-wifi-jdcloud_re-cs-02 ath11k-firmware-ipq6018-ddwrt \
         ath11k-firmware-qcn9074-ddwrt kmod-ath11k kmod-ath11k-ahb kmod-ath11k-pci; do
  sed -i "s|^CONFIG_PACKAGE_${p}=y\$|# CONFIG_PACKAGE_${p} is not set|" "$OUT"
  sed -i "s|^CONFIG_DEFAULT_${p}=y\$|# CONFIG_DEFAULT_${p} is not set|" "$OUT"
done

echo "==> $OUT generated (from $(basename "$SRC"))"
```

- [ ] **Step 3.3: gwrt-build-cs06.sh**（模式同 gwrt-build-wr630ax.sh：显式 REVISION）

```sh
#!/bin/sh
# gwrt-build-cs06.sh — 编译 JDCloud RE-CS-06 (IPQ5322 eMMC) 固件
# 用法: sh gwrt-build-cs06.sh [jobs] [version]
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
JOBS=${1:-6}
VER=${2:-261026-01}
REV=${REVISION:-$(git -C "$TOP" rev-parse --short HEAD 2>/dev/null || echo 13822ca)}
LOG="$TOP/.gwrt-logs/build-cs06-$(date +%y%m%d-%H%M).log"
mkdir -p "$TOP/.gwrt-logs"
echo "==> log: $LOG"; echo "==> REVISION=$REV"
nice -n 15 make -j"$JOBS" REVISION="$REV" \
  CONFIG_VERSION_DIST=GWRT CONFIG_VERSION_NUMBER="$VER" 2>&1 | tee "$LOG"
echo "==> done:"
ls -lh bin/targets/qualcommbe/ipq53xx/*cs-06* 2>/dev/null || true
```

- [ ] **Step 3.4: 拷入 cs-02 基准存档 + 提交**

```sh
cp /home/godsun/build/immortalwrt/config.cs02-gwrt2-261021-04 $SRC/config.cs02-gwrt2-261021-04
chmod +x scripts/gwrt-sync-qualcommbe.sh gwrt-mk-cs06-config.sh gwrt-build-cs06.sh
git add scripts/gwrt-sync-qualcommbe.sh gwrt-mk-cs06-config.sh gwrt-build-cs06.sh
git commit -m "gwrt: cs-06 (RE-CS-06 ipq53xx eMMC) config/build workflow, qualcommbe tree sync script"
```

### Task 4: 建编译树

- [ ] **Step 4.1:**

```sh
cd $SRC && sh scripts/gwrt-sync-qualcommbe.sh
ls /home/godsun/build/immortalwrt-qualcommbe/target/linux/qualcommbe/ipq53xx/  # 子目标在
readlink /home/godsun/build/immortalwrt-qualcommbe/dl
```

### Task 5: 生成 CS-06 配置并验证

- [ ] **Step 5.1:**

```sh
cd $BLD
VER=261026-01 sh gwrt-mk-cs06-config.sh $BLD
cp config.cs06-261026-01 .config
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/godsun make defconfig
```

- [ ] **Step 5.2: 复核（kconfig 收敛检查）**

```sh
grep -E "CONFIG_TARGET_PROFILE|CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE" .config
# 期望: CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-06"
grep -E "^CONFIG_PACKAGE_(kmod-ath12k|ath12k-firmware-ipq5332-ddwrt|ath12k-firmware-qcn9274-ddwrt|ipq-wifi-jdcloud_re-cs-06|kmod-qcom-ppe|kmod-dsa-qca8k|wpad-openssl)=y" .config
grep -E "ath11k" .config | grep "=y"    # 期望: 无（CS-02 的 ath11k 栈不残留）
grep -E "CONFIG_NAND_SUPPORT=|CONFIG_TARGET_UBIFS" .config   # 期望: 无
```

### Task 6: 编译验证

- [ ] **Step 6.1: CS-06 全量镜像** `cd $BLD && sh gwrt-build-cs06.sh 6 261026-01`（产物 bin/targets/qualcommbe/ipq53xx/gwrt-...-jdcloud_re-cs-06-*）
- [ ] **Step 6.2: be10000/be6500 内核冒烟**（从 cs-06 .config 派生临时配置只切设备，`make -j6 target/linux/compile` 验证 ipq95xx/ipq53xx 两个子目标内核均通过）
- [ ] **Step 6.3: XER5 内核冒烟**（同法切 DEVICE_xfinity_xer5，验证保留机型内核可选可编）
- [ ] **Step 6.4: 源码树 mediatek 回归冒烟**（$SRC 下 cp .config /tmp/.config.bak; make defconfig; 恢复 .config）

### Task 7: WORKLOG + 收尾

- [ ] **Step 7.1:** 写 `docs/WORKLOG-20261026-qualcommbe-cs06-be6500-be10000.md`（变更清单、命令、产物、坑）
- [ ] **Step 7.2:** AGENTS.md 代码地图补 qualcommbe 行 + 日志索引

## Self-Review

1. Spec 覆盖：§3.1→T1、§3.2→T2、§3.3/3.4→T3/T4、§4→T1 Step1.3/1.4、§5→不动 generic（无任务即验证）、§6→各任务 git add 限定路径、§7→T5/T6、§9→顺序一致 ✓
2. 占位符：无 TBD/TODO；脚本内容完整内嵌 ✓
3. 一致性：cs-06 设备名 `jdcloud_re-cs-06`、存档名 `config.cs06-261026-01`、编译树 `$BLD` 全程一致 ✓
