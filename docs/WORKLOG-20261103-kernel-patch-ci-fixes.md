# WORKLOG 2026-11-03 — 内核补丁冲突 / CI 失败根治 + BE9300 出固件

本轮把连续多天出现在 GitHub Actions（`rothdren-lion/gwrt-immortalwrt`）以及本地
构建树上的“`.prepared_*` / `world` Error 2”类失败一次性定位并修掉了，
同时完成 qualcommbe（BE）GL-BE9300 的首次可编译出固件。

---

## 1. 失败现象

CI（cp02 / MT7621 mipsel）日志尾部：

```
make[4]: *** [Makefile:33: .../linux-ramips_mt7621/linux-6.18.55/.prepared_73d2...] Error 1
make[3]: *** [Makefile:12: compile] Error 2
make: *** [include/toplevel.mk:268: world] Error 2
```

本地 qualcommax 树（`/home/godsun/build/immortalwrt`）则是：

```
net/dsa/tag_oob.c:41: error: 'DSA_TAG_PROTO_OOB' undeclared
drivers/net/ethernet/qualcomm/qca_ppe_main.c:606: error: 'DSA_TAG_PROTO_OOB' undeclared
```

`.prepared` 失败 = 内核补丁应用失败（quilt 阶段），不是编译错误。

---

## 2. 根因

### 2.1 DSA tag 枚举尾部冲突（主因）

`include/net/dsa.h` 的 `enum dsa_tag_protocol` / `*_VALUE` 定义尾部被多个补丁
抢着插入同一位置：

| 补丁 | 插入点 | 追加内容 |
|---|---|---|
| `generic/hack-6.18/752` | `MXL862_8021Q` 之后 | `RTL837X_8021AD_VALUE 34` |
| `generic/hack-6.18/753` | `RTL837X_8021AD` 之后 | `RTL9303_8021AD_VALUE 35` |
| `ramips/patches-6.18/761` | `MXL862_8021Q` 之后 | `RALINK_VALUE 32` |
| `realtek/patches-6.18/721` | 同上 | `RTL_OTTO` |
| `qualcommax/patches-6.18/0950` | 同上 | `OOB_VALUE 32` |
| `ipq40xx/patches-6.18/701` | 同上 | `OOB_VALUE 32` |

内核补丁顺序固定：`generic/backport → generic/pending → generic/hack → 机型 patches`
（`include/quilt.mk` 的 `PatchDir` 顺序）。752/753 先插入后，
机型补丁的 hunk 上下文（`MXL862_8021Q` 紧接空行/`};`）就不存在了。

`patch` 默认 fuzz 无法覆盖“上下文中间被插入新行”的情况，
因此直接 `2 out of 2 hunks FAILED`。

> qualcommbe 的 `0386/0395` 反而是“针对 752/753 已插入后的状态”写的，
> 所以这两组补丁的假设是互斥的 —— 只能改其中一组。

### 2.2 新增 Kconfig 符号未声明（第二个坑）

752/753 新增 `NET_DSA_TAG_RTL837X_8021AD`、`NET_DSA_TAG_RTL9303_8021AD`，
但 `generic/config-6.18` 里没有对应条目。非交互环境下：

```
Tag driver for external Realtek RTL9303 switches (NET_DSA_TAG_RTL9303_8021AD) [N/m/y/?] (NEW)
make[8]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
```

### 2.3 两个对 6.18.55 已失效的补丁

| 补丁 | 原因 |
|---|---|
| `ramips/patches-6.18/102-01-pwm-mediatek-set-mt7628-pwm45_fixup-flag-to-false.patch` | 6.18.55 内核里 `mt7628_pwm_data.pwm45_fixup` 已经是 `false`，改动重复，hunk 失败 |
| `mediatek/patches-6.18/863-arm64-dts-mt7986-add-sound-wm8960.patch` | 目标 `arch/arm64/boot/dts/mediatek/mt7986a-rfb-spim-nand.dts` 在 6.18 已改名为 `mt7986a-rfb.dts`，`No file to patch` |

### 2.4 本地 BE 构建特有

1. `target/linux/qualcommbe/image/ipq53xx.mk` 反复合并后出现重复
   `define Device/glinet_gl-be9300` 与 `endef`，make 直接
   `recipe commences before first target`；
   且 `TARGET_DEVICES += jdcloud_re-cs-06` 被误删，导致 CS-06 在 menuconfig 里消失。
2. 用 GWRT 旧版 `ipq53xx/base-files` **整体覆盖** LEDE 新版，回退了
   `ubnt,u7-pro-xgs` / `gl.inet,gl-be6500` / `xiaomi,be3600-pro-*` / `xiaomi,be6500`
   在 `02_network`、`platform.sh`、`12-ath12k-caldata` 中的支持。
3. `ipq-wifi` 只有 `files-glinet_gl-be9300/` 目录，Makefile 里没有
   `glinet_gl-be9300` 的 board 列表与 `generate-ipq-wifi-package` 定义，
   且该包没有 `Build/Prepare` 去拷贝 `files-*`。
4. 构建树缺 `package/firmware/ath12k-firmware`（BE 必需的 `-ddwrt` 固件包）。
5. 构建树没有 `.git` → `REVISION=unknown` → apk 报
   `failed to create package: package version is invalid`
   （`base-files-260924.34220~unknown.apk`）。

---

## 3. 修复

### 3.1 补丁修复（已推送 CI 仓 master）

提交 `9e02321`、`d72575c`、`1139007`、`4ae4f4c`：

| 文件 | 改动 |
|---|---|
| `target/linux/ramips/patches-6.18/761-*` | dsa.h hunk 重新锚定到 `RTL9303_8021AD` 之后 |
| `target/linux/realtek/patches-6.18/721-*` | 同上 |
| `target/linux/qualcommax/patches-6.18/0950-*` | 同上 |
| `target/linux/ipq40xx/patches-6.18/701-*` | 同上 |
| `target/linux/ramips/patches-6.18/102-01-*` | 删除（重复改动） |
| `target/linux/mediatek/patches-6.18/863-*` | 删除（目标文件名已变） |
| `target/linux/generic/config-6.18` | 新增 `# CONFIG_NET_DSA_TAG_RTL837X_8021AD is not set`、`# CONFIG_NET_DSA_TAG_RTL9303_8021AD is not set` |
| `target/linux/mediatek/filogic/config-6.18` | 去掉重复的 RTL9303 行 |

保留 `generic/hack-6.18/752`、`753` 原始形态（qualcommbe `0386/0395` 依赖其位置），
只调整“后插入”的机型补丁，避免影响 BE。

### 3.2 BE 本地树修复

| 文件 | 改动 |
|---|---|
| `target/linux/qualcommbe/image/ipq53xx.mk` | 以 LEDE 原版为基，插入单个 `glinet_gl-be9300` 设备块 + `metadata_gl_json` + `Build/append-gl-metadata` + `Build/gl-be9300-factory`，恢复全部 8 个 `TARGET_DEVICES` |
| `ipq53xx/base-files/etc/board.d/02_network` | LEDE 版 + `gl.inet,gl-be9300` 分支 |
| `ipq53xx/base-files/etc/hotplug.d/firmware/12-ath12k-caldata` | LEDE 版 + be9300 的 `caldata_extract_mmc "0:ART"`（0x1000/0x20000 与 0x58800/0x27800） |
| `ipq53xx/base-files/lib/upgrade/platform.sh` | LEDE 版 + be9300 的 `glinet_emmc_do_upgrade`/`glinet_emmc_check_image`/`emmc_copy_config`，`RAMFS_COPY_BIN` 加 `dumpimage` |
| `package/firmware/ipq-wifi/Makefile` | 增加 `glinet_gl-be9300` 到 `ALLWIFIBOARDS` 与 `generate-ipq-wifi-package`，并加 `Build/Prepare` 拷贝 `files-*/*` |
| 构建树 `package/firmware/ath12k-firmware` | 从源码树同步 |
| 构建树 `target/linux/{generic,mediatek,ramips,realtek,qualcommax,ipq40xx}` | 同步本轮补丁修复 |

### 3.3 版本号

构建树无 `.git`，必须显式传：

```sh
make -j$(nproc) REVISION=<sha> CONFIG_VERSION_CODE=<sha> \
     CONFIG_VERSION_DIST=GWRT CONFIG_VERSION_NUMBER=<ver>
```

`gwrt-build-*.sh` 已按此方式传参，直接跑脚本即可。

---

## 4. 验证方式（可复现）

不跑整包，只对 6.18.55 内核完整应用补丁序列验证：

```sh
cd /tmp && mkdir k && tar -xf dl/linux-6.18.55.tar.xz -C k && cd k/linux-6.18.55
SRC=<repo>/target/linux
for d in generic/backport-6.18 generic/pending-6.18 generic/hack-6.18; do
  for p in $(ls $SRC/$d/*.patch|sort); do patch -p1 -f -s -i "$p" || echo "GENFAIL $p"; done
done
for p in $(ls $SRC/<target>/patches-6.18/*.patch|sort); do
  patch -p1 -f -s -i "$p" || echo "FAIL $p"
done
find . -name '*.rej' | wc -l    # 必须为 0
```

| 机型目录 | 结果 |
|---|---|
| `ramips`（cp02/MT7621） | 0 rejects |
| `mediatek`（MT7981 全系） | 0 rejects |
| `qualcommbe`（BE9300/CS-06 等） | 0 rejects |
| `realtek` | 0 rejects |

> `qualcommax`（MX/ipq60xx）仍存在 NSS 相关补丁与 generic `767/768/769`
> （PPP/lwt tunnel/ip6 tunnel 生命周期）的冲突，属另一条线，
> 需要把这几支 generic hack 迁到 `qualcommbe/patches-6.18/` 才能彻底隔离。

---

## 5. 产物

本地 BE9300（GWRT 261103-01，`REVISION=581e8531`）：

```
bin-be9300-261103-01/
├── gwrt-261103-01-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-sysupgrade.bin  110M
├── gwrt-261103-01-qualcommbe-ipq53xx-glinet_gl-be9300-squashfs-factory.bin    110M
├── gwrt-261103-01-qualcommbe-ipq53xx-glinet_gl-be9300-initramfs-uImage.itb    110M
└── SHA256SUMS
```

---

## 6. 经验

1. 新增“往公共头文件尾部追加枚举”的 generic 补丁时，必须同步检查所有机型的
   同类补丁锚点，否则 `.prepared` 会以“上下文不匹配”失败。
2. 新增 Kconfig 符号必须同步写进 `generic/config-6.18`，否则 `syncconfig` 在 CI 上必挂。
3. 换内核小版本（6.18.x）后，针对具体文件名的 DTS/驱动补丁要复查目标是否还存在。
4. 同步上游目录时用 `--delete` 前先备份；`rsync -a` 会保留旧 mtime，
   导致 `tmp/.targetinfo` 等缓存不刷新（需要 `touch`）。
5. 构建树无 `.git` 时永远记得传 `REVISION`，否则 `~unknown` 会在 `package/base-files` 炸。

---

## 7. 追加：mac80211 补丁互相打架（第二轮 CI 失败）

内核补丁问题解决后，cp02 构建推进到用户态包阶段，卡在：

```
patching file net/mac80211/debugfs.c
9 out of 9 hunks FAILED
Patch failed! .../package/kernel/mac80211/patches/build/410-mac80211-retain-native-debugfs-on-new-kernels.patch
ERROR: package/kernel/mac80211 failed to build (build variant: regular).
```

### 原因

CI 仓的 `package/kernel/mac80211/patches/` 里同时存在**同一编号、互斥**的两支补丁：

| 补丁 | 做法 |
|---|---|
| `build/410-mac80211-convert-short-fops-to-debugfs-files.patch` | 把 `debugfs_short_fops` 改写成 `struct file_operations` |
| `build/410-mac80211-retain-native-debugfs-on-new-kernels.patch` | 保留原生 `debugfs_short_fops`（6.14+ 新方案） |

同前缀排序时 `convert-short-fops` 先执行，已经把代码改走，`retain-native-debugfs`
的上下文全部消失 → 9/9 hunk 失败。

另外还有 4 支旧变体与主树新版重复（同样“先老后新”导致后者失败）：

- `ath11k/949-wifi-ath11k-fix-monitor-rx-pktlen.patch`（新版：`949-...-scope-IPQ-monitor-tail-quirk`）
- `ath11k/950-wifi-ath11k-implement-CE-interrupt-enable-disable-for-AHB.patch`（新版 `950-01-...`）
- `ath11k/984-ath11k-workaround-for-memory-leak.patch`（新版：`984-...-use-atomic-RX-buffer-allocations`）
- `ath12k/100-ath12k-prevent-ltssm-startup-crash.patch`（新版 `100-01-...`）
- `subsys/311-cfg80211-allow-concurrent-AP-operation-on-DFS-channe.patch`（新版 `314-...`）

### 修复（提交 `908feff`、`b990abe`）

删除上述 6 个被取代的旧补丁，保留主树里的新版本。
验证方式：把 `package/kernel/mac80211/patches/` 按
`build→subsys→ath→ath5k→ath9k→ath10k→ath11k→ath12k→rt2x00→mt7601u→mwl→brcm→rtl`
顺序整体打到 `backports-7.2` 上，**0 rejects**。

顺带对 `nftables-1.1.6`、`iproute2-6.18.0` 也做了同样的全量 patch 验证（均为 0 rejects）。

### 教训

同一目录下的补丁编号必须唯一；编号重复时按字典序执行，
“老变体 + 新变体”共存必然导致后者全 hunk 失败。
