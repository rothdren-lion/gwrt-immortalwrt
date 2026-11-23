# WORKLOG 2026-11-02 — 360T7 UBI 迁移事故 + Factory/BDF 缺失

机型：Qihoo 360T7（MT7981B + MT7976CN，实测 **DRAM 512MB**，SPI-NAND 128MB）
涉及：`/mnt/syNAS/Dowloads/Rout/mark/uboot/bl-mt798x-dhcpd`、本源码树

---

## 0. 结论速览

| # | 问题 | 定性 |
|---|---|---|
| 1 | `bl-mt798x-dhcpd` 的 `VARIANT=ubi` U-Boot 在 `bootm` 阶段野跳转到 BSS | **U-Boot 缺陷**（该 profile 未在真机验证） |
| 2 | WebUI 反复写 UBI `fip` 卷 → UBI 布局卷损坏 → BL2 连 UBI 都挂不上 | 砖态直接原因 |
| 3 | ubi 布局 ↔ 108M(stock/NMBM) 布局互转：BL2 的 FIP 位置模型不同 | 设计冲突，必须换 BL2 |
| 4 | Factory 分区只有 246 字节文本，4KB MTK EEPROM 丢失 | 校准丢失 → 无 WiFi |
| 5 | `mt7981_eeprom_mt7976_dbdc.bin` 未打进固件 | **待修（见 §7 TODO-B）** |

---

## 1. ubi 版 U-Boot 的 bootm 野跳转（核心 bug）

现象（串口）：

```
## Loading fdt (any) from FIT Image at 46000000 ...
   Verifying Hash Integrity ... crc32+ sha1+ OK
   Booting using the fdt blob at 0x465eb000
"Synchronous Abort" handler, esr 0x02000000
elr: 0000000041ed7198 lr : 0000000041ed7198 (reloc)
```

定位方法：把 reloc 前的地址丢进 U-Boot 的 `System.map`：

```
0x41ed7198 = images + 0xd0
  images = 0x41ed70c8   (boot/bootm.c 全局 struct bootm_headers)
  +0xd0  = os.image_len
```

崩溃时 `Code:` 转储的字节 `44001000 00000000 44001000 00000000 (005e9a44)`
正好是 `os.end / os.image_start / os.image_len` → **U-Boot 把结构体数据当指令执行**。

- `esr 0x02000000`：EC=0（Unknown reason），不是 instr/data abort → 是野跳转而非访问越界
- 崩溃点在 `boot/image-fdt.c:477` 那句 printf 之后，即 `boot_get_loadable()` 入口之前
  （从未打印过 `## Loading loadables ...`）
- **排除地址重叠**：FIT 放 0x46000000 与 0x44000000 崩溃完全一致
  （虽然实测 kernel 解压 0x48000000..0x48E7D808 与 static rootfs
  0x465f1000..0x48972000 确实重叠 9.7MB，但不是本次死因）

同一条 U-Boot 起 initramfs FIT 时是另一个崩法（证明是 U-Boot 本体问题，与 FIT 无关）：

```
Required FDT relocation for applying DTOs failed: 1610328671   ← 这个"错误码"是 DRAM 地址
"Synchronous Abort" handler, esr 0x96000061, far 0x16          ← 真正的 data abort
```

### ubi variant 的其它 4 处配置错误（佐证"未上过真机"）

1. `CONFIG_DEFAULT_DEVICE_TREE="mt7981-qihoo-360t7"` —— 用的是**非 ubi** 的 board DTS
2. env 引用 `green:status`/`red:status`，DTS 里是 `green:system`/`red:run`
   → 串口每次 `LED 'green:status' not found (err=-19)`
3. `CONFIG_ENV_SIZE=0x20000` 但 `ubi create ubootenv 0x1f000`
   → `saveenv` 永远 `size > volume size! Aborting!`，env 一次都没存进去
   （`bdinfo` 可见 `Environment size: 4396/131067`）
4. `CONFIG_MTDPARTS_DEFAULT="spi-nand0:2048k(bl2),-(ubi)"`（ubi@0x200000），
   而同批编译的 ATF ubi 配置是 `OVERRIDE_UBI_START_ADDR=0x100000`

---

## 2. BL2 的 FIP 位置模型（互转必须换 BL2）

| BL2 | 名字 | FIP 位置 |
|---|---|---|
| ubi 版 | `...-ubi-ddr3-1866` | **UBI 卷 `fip`** |
| 非 ubi 版 | `...-ddr3-1866` | **裸偏移 `0x380000`** |

`atf-20250711/plat/mediatek/mt7981/bl2/bl2_dev_snfi.c:13` → `#define FIP_BASE 0x380000`
（正好 = `1024k(bl2)+512k(u-boot-env)+2048k(factory)`）

**关键推论**：failsafe WebUI 的 "Upgrading ATF FIP" 只会 `ubi_write_fip`
（日志 `Updating volume 'fip'`），**写不到裸 0x380000** → 在 ubi 布局下无论换哪个 FIP
都回不到 108M 布局，必须同时换 BL2。

---

## 3. 两种布局对照

| | 108M（stock/NMBM，目标） | 全盘 ubi（`-ubi` 产物） |
|---|---|---|
| 产物 | `gwrt-...-qihoo_360t7-squashfs-sysupgrade.itb` | `gwrt-...-qihoo_360t7-ubi-...itb` |
| 布局 | `bl2 1M / u-boot-env 512K / Factory 2M / fip 2M / ubi **108M**@0x580000 / config 1M / factory 512K / log 4M` | `bl2 1M / ubi 127M@0x100000`（factory/fip/env/fit 全在内） |
| U-Boot mtdparts | `nmbm0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),108M(ubi),1M(stock-config),512k(stock-factory),4M(stock-log)` | `spi-nand0:2048k(bl2),-(ubi)` |

两者共用 `Device/qihoo_360t7-common`（`KERNEL_IN_UBI=1`、`UBOOTENV_IN_UBI=1`），
差别只在 DTS 里 `ubi` 分区起点 —— **这就是 ubi 版固件放进 108M 布局起不来的原因**。

---

## 4. 救砖链（已验证）

```
BROM(0x7981) → mtk_uartboot → RAM-boot BL2(带 UART DL) → FIP over UART → BL31/U-Boot
```

1. 编 RAM-boot BL2（普通 `bl2.img` 是 SPIM-NAND 引导版，`-f` 用不了）：

```sh
# .config 至少要有这 5 行
_PLAT_MT7981=y
_MT7981_BOARD_BGA=y
_LOG_LEVEL_INFO=y
_BOOT_DEVICE_RAM=y
_RAM_BOOT_RAM_BOOT_UART_DL=y
make -f Makefile all CONFIG_CROSS_COMPILER=aarch64-linux-gnu- CROSS_COMPILER=aarch64-linux-gnu- -j8
# 产出 build/mt7981/release/bl2.bin（裸镜像，无 SPINAND! 头），当前归档：
#   ~/gwrt-tftp/bl2-ramboot-uartdl.bin  214464B  md5 9c1a4f96531a9e79b1777c5769abf958
```

2. 断电 → 执行 → 上电：

```sh
mtk_uartboot -s /dev/ttyACM0 -a -p bl2-ramboot-uartdl.bin -f fip.bin
```

3. **波特率陷阱**：BL2 收 FIP 时切到 **921600**，BL31/U-Boot 又回 **115200**。
   若只按 921600 读，会把 BL31+U-Boot 的正常输出读成乱码，误判为"卡死"。

---

## 5. 写入命令（U-Boot 侧，108M 布局）

```
mtd erase bl2 / mtd write bl2 <addr> 0x0 0x3B360        # bl2.bin 242528
mtd erase fip / mtd write fip <addr> 0x0 0xE9EEC        # fip.bin 958188（按分区名，别算裸偏移）
mtd erase ubi / ubi part ubi / ubi create fit 0x29720FB dynamic
mtd erase factory / mtd write factory <addr>            # 2MB 备份
```

`mtd write|erase <name> [<off> [<size>]]` 的 offset 是**分区内相对**且需块对齐
（`cmd/mtd.c: do_mtd_erase` / `do_mtd_write`）。

---

## 6. Factory 分区与 WiFi 校准

### 6.1 DTS 要求

```dts
partition@180000 { label = "Factory"; reg = <0x180000 0x200000>; read-only;
    nvmem-layout { eeprom@0 { reg = <0x00 0x1000>; }; }; };
```

→ `Factory+0x0` 前 **4KB** 必须是 MTK EEPROM，魔数 **LE16 `0x7981`**（mt7915/mt7986 为 0x7915/0x7916/0x7986）。

### 6.2 如何辨认备份对不对

```sh
hexdump -C -n 4 <备份>
81 79                     → ✅ 正确的 EEPROM（2MB，4KB 数据 + 其余 FF）
68 77 76 65  ("hwve")     → ❌ 只是原厂文本信息区（hwver/lanMac/sn/ssid），来自 stock-factory
```

本次事故后 Board 上 `Factory` 只有 **246 字节**文本、其余全 `0xFF`，
扫全 `mtd2/mtd5/mtd6` 均无 EEPROM 魔数 → 校准确实丢失。
正确备份（桌面 `360T7factory (1).bin`，2MB，md5 `86dd077a2942484ab67cfdd1b533ec6e`）
前 4KB md5 `84fc5d3b9e6d9644b6bb0457cae7a903`，内含真实 WiFi MAC `00:0c:43:49:c3:57`。

### 6.3 Linux 下写 Factory：需先解锁（已打通）

DTS 标了 `read-only` → `mtd2` 的 `flags=0x0`（`MTD_WRITEABLE` 未置位），
`dd` 报 `Permission denied`、`mtd erase/write Factory` 报 `Could not open mtd device`。

**`kmod-mtd-rw` 官方就有，不用手写**：`feeds/packages/kernel/mtd-rw`
（上游 `github.com/jclehner/mtd-rw`）。已在 `gwrt-mk-wr630ax-config.sh` 的包列表里
`add_pkg kmod-mtd-rw`，开机自动 `/etc/modules.d/90-mtd-rw` 里是
`mtd-rw i_want_a_brick=1`。

> 踩坑：一开始在 `package/kernel/mtd-rw` 手写了一份，结果 `tmp/.packagedeps` 把
> `kmod-mtd-rw` 映射到 `feeds/packages/mtd-rw`（feeds 优先），手写那份永远轮不到 →
> `make package/kernel/mtd-rw/compile` 报 *No rule to make target*。
> 已在源码树和构建树里删除手写包。

现编模块验证（构建树被清、无 `Module.symvers` 时的临时手段）：

```sh
K=$TOPDIR/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-6.18.55
TC=$TOPDIR/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.4.0_musl/bin
export PATH=$TC:$PATH STAGING_DIR=$TOPDIR/staging_dir
cd $K && make ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- modules_prepare -j8
make M=/tmp/mtd-rw ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- KBUILD_MODPOST_WARN=1 modules
# vermagic 必须等于运行内核：6.18.55 SMP mod_unload aarch64

# 路由上：
insmod /tmp/mtd-rw.ko i_want_a_brick=1     # dmesg: mtd-rw: Factory (rw) unlocked
cat /sys/class/mtd/mtd2/flags               # 应变为 0x400
rmmod mt7915e
mtd erase Factory && mtd write /tmp/factory-2m.bin Factory
dd if=/dev/mtd2 bs=64k | md5sum             # 回读比对 86dd077a…
modprobe mt7915e && wifi up
```

> 也可以从 **U-Boot** 写（`mtd write Factory` 或 WebUI 的 `factory` 页面），不需要模块。

### 6.4 临时生效技巧（不写 flash，备用）

驱动的 fallback 路径就是把 `mediatek/mt7981_eeprom_mt7976_dbdc.bin` 当 EEPROM 用。
把真实 4KB 校准放到该路径（overlay 持久，重启不丢、刷机丢）：

```sh
head -c 4096 "360T7factory (1).bin" | ssh root@<ip> 'cat > /lib/firmware/mediatek/mt7981_eeprom_mt7976_dbdc.bin'
ssh root@<ip> 'rmmod mt7915e; modprobe mt7915e'
```

验证：`iw dev` 里 MAC 变成 `00:0c:43:49:c3:57`（通用 BDF 时是假的 `82:0c:43:26:60:00`）。

> **2026-11-02 实测结果（360T7）**：先用本节的方法恢复校准，随后又把 2MB Factory
> 正式写回 flash（§6.3）。写回后：`/dev/mtd2` md5 与备份一致、驱动不再打
> `eeprom load fail`、BDF 兜底文件已删除、真实 MAC `00:0c:43:49:c3:57` 直接来自 nvmem。
> 即：**只要 Factory 正确，驱动根本不需要那个 BDF 文件**；TODO-B 只是防呆。

---

## 7. TODO — 下次编译处理

### TODO-B（必做）：把默认 BDF 打进固件

现状：`package/kernel/mt76/Makefile` 只在 `Build/InstallDev` 里
`$(CP) $(PKG_BUILD_DIR)/firmware/mt7981_eeprom_mt7976_dbdc.bin $(STAGING_DIR_IMAGE)/`，
**没有任何包装它到 `/lib/firmware/mediatek/`**。
后果：Factory 一旦为空，驱动 `eeprom load fail` → `Direct firmware load ... failed (-2)`
→ `probe with driver mt798x-wmac failed with error -12` → **完全无 radio**。

改法（在 `Package/kmod-mt7915e/install` 里加两行）：

```make
	$(INSTALL_DIR) $(1)/lib/firmware/mediatek
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/firmware/mt7981_eeprom_mt7976_dbdc.bin \
		$(1)/lib/firmware/mediatek/
```

> 该文件既可作为 `mt7981+mt7976` 的兜底 BDF，也是 §6.4 那条"不写 flash 恢复校准"的载体。
> 顺带：`360T7`/`cf-wr630ax` 等 MT7981 NAND 机型共用，影响面广。

### 待观察（不阻塞）

- `bl-mt798x-dhcpd` 的 `VARIANT=ubi` 建议先修 §1 的 4 处配置错误 + `bootm` 崩溃再用于真机；
  360T7 推荐继续用 `VARIANT=default`（fixed-parts / NMBM / 108M）。
- 通用 BDF 的 txpower 是 27/29 dBm（BDF 上限值），恢复真实校准后应复查。

### TODO-C（必做）：DHCP 指纹链被旧 dhcpscript 打断

**现象**：每次 DHCP 客户端上下线都刷
`daemon.debug dnsmasq-script[1]: /usr/lib/dnsmasq/dhcp-script.sh: /usr/libexec/gwrt-dhcp-fp: line 16: tr: not found`，
且 `/tmp/gwrt-dhcp-fp.list` **永远不存在** → 主题按系统显示图标一直拿不到数据。

**链路**（已实机验证）：

1. `package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt/root/etc/uci-defaults/37_gwrt-dhcp-fp`
   首启写入 `dhcp.@dnsmasq[0].dhcpscript=/usr/libexec/gwrt-dhcp-fp`
2. `dnsmasq.init:1269` → `procd_set_param env USER_DHCPSCRIPT=<该值>`
3. dnsmasq 在 **ujail 沙箱**里执行 `/usr/lib/dnsmasq/dhcp-script.sh`
4. `dhcp-script.sh:3` → `[ -f "$USER_DHCPSCRIPT" ] && . "$USER_DHCPSCRIPT" "$@"` → **source 旧脚本**
5. 旧脚本第 16 行 `tr 'A-F' 'a-f'`：沙箱只挂 `/bin/sh`、`/bin/ubus` 和少数 lib，
   **没有 `/usr/bin`、没有 `/bin/busybox`** → `tr: not found`，`mac` 为空
6. 旧脚本 `[ -n "$mac" ] || exit 0` → 在 **sourced 上下文里 `exit 0` 会终止整个 dhcp-script.sh**
7. → 末尾的 `[ -n "$hotplugobj" ] && ubus call hotplug.dhcp call ...` **永远不执行**
8. → 2026-09-20 重写的 hotplug 版 `/etc/hotplug.d/dhcp/30-gwrt-dhcp-fp` **从不触发**
   （该脚本注释里已写明沙箱问题，但**旧路径没删**）

**验证**（本机实测，已回滚）：

```sh
uci delete dhcp.@dnsmasq[0].dhcpscript; uci commit dhcp; /etc/init.d/dnsmasq restart
# → 真实客户端立刻出现在 /tmp/gwrt-dhcp-fp.list
#    06:8e:e3:34:fc:56|unknown||
#    3a:c4:c1:fb:9c:5f|unknown||
#    手工投递 ubus 事件可正确识别：de:ad:be:ef:00:01|android|android-dhcp-13|1,3,6,...
```

**修法（下次编译）**：

1. 删除 `etc/uci-defaults/37_gwrt-dhcp-fp`（或让它不再设置 dhcpscript，仅保留 hotplug 版）
2. 删除旧的 `/usr/libexec/gwrt-dhcp-fp`
3. 已有设备的兜底：`uci -q delete dhcp.@dnsmasq[0].dhcpscript; uci commit dhcp; /etc/init.d/dnsmasq restart`

**遗留待观察**：真实客户端落到的 vendor_class / requested_options 为空（`|unknown||`），
只有手工投递的事件能拿到 option 55/60。需确认 dnsmasq 在 `add/old` 事件里导出
`DNSMASQ_VENDOR_CLASS` / `DNSMASQ_REQUESTED_OPTIONS` 的时机（可能与租约已存在、
只走 `old` 有关），修好主问题后再复测一次真实上下线。

### TODO-D（低优先）：108M UBI 没给坏块留余量

```
ubi0 warning: ubi_eba_init: cannot reserve enough PEBs for bad PEB handling, reserved 17, need 20
```

`ubi create rootfs_data - dynamic` 把 108M 里剩下的 PEB 全占了（20 PEB ≈ 2.5MB 才够）。
建卷时建议 `ubi create rootfs_data <fit剩余-3M> dynamic`，或建完 `ubirsvol` 调小。

### TODO-E（记录）：ubi 变体 DTS 内存只有 256MB

`gwrt-...-qihoo_360t7-**ubi**-...itb` 的 kernel DTS `memory@40000000` = `0x10000000`（256MB），
但实测板子是 **512MB**（非 ubi 版 DTS 也确实是 512MB，`MemTotal 495324 kB`）。
→ ubi 变体又一处未校对，若将来要用需一并修。

---

## 8. 参考文件

| 用途 | 路径 | 大小 | md5 |
|---|---|---|---|
| BL2（108M 布局） | `~/gwrt-tftp/bl2.bin` | 242528 | `ad3bcd82021c451f2b4674204e61d296` |
| FIP（fixed-parts） | `~/gwrt-tftp/fip.bin` | 958188 | `80ce667861440ca2a749ebd25c8f2447` |
| 固件（非 ubi） | `~/gwrt-tftp/fw.itb` | 43458811 | `45159fe7fcf782c251668e6b3d8c1232` |
| RAM-boot BL2（救砖） | `~/gwrt-tftp/bl2-ramboot-uartdl.bin` | 214464 | `9c1a4f96531a9e79b1777c5769abf958` |
| Factory 2MB | `~/Desktop/360T7factory (1).bin` | 2097152 | `86dd077a2942484ab67cfdd1b533ec6e` |
