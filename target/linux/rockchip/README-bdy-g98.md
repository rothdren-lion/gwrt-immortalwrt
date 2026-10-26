# BDY G98 (RK3588) 移植说明

这块板是彼度云 G98 / BDY G98，RK3588，**10 个网口 = 8×1G（2× YT9215S 交换芯片走 DSA）+ 2×2.5G（PCIe RTL8125）**。
本文件记录把它的 DTS 和交换芯片驱动塞进本树的来龙去脉，方便以后接手。

## 来源

| 东西 | 仓库 / 分支 |
|---|---|
| 板级 DTS + 缺的 dtsi | `yifengyou/BDY_G98_RK3588-kernel` @ `kdev-recovery`（= `main`，两分支这批文件 md5 一致）<br>`arch/arm64/boot/dts/rockchip/` |
| DSA 驱动 + tag 驱动 | 同上：`drivers/net/dsa/yt921x.{c,h}`、`net/dsa/tag_yt921x.c`<br>作者 Copyright (c) 2025 David Yang，`GPL-2.0-or-later` |
| DT binding | 同上：`Documentation/devicetree/bindings/net/dsa/motorcomm,yt921x.yaml`<br>`GPL-2.0-only OR BSD-2-Clause` |
| 官方交换机 SDK（**未采用**） | `OpenEmbeddedBSP/motorcomm-yt9215-switch-sdk` —— 芯片寄存器配置库，出 `sdk.ko`，不提供网口；无 LICENSE 文件 |
| 预编译 ko（**未采用**） | `a276519803-sudo/fnos-drivers_for_BDY-G98` —— vermagic 绑 `6.18.18.cXXX-trim`，自编内核用不了 |

## 落地了什么

**1. DTS（`files/` overlay，拷进内核树，不动主线文件）**

```
target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/
    rk3588-bdy-g98.dts          ← 主角，945 行，正经 #include 写法
    rk3588-rk806-single.dtsi    ← PMIC，主线没有，必须
    rk3588-ramoops.dtsi         ← 主线没有
    rk3588s-ip.dtsi             ← 主线没有，会再 include 下面 4 个
    rk3588s-ip-supply.dtsi      ← 主线没有
    rk3588s-vpu.dtsi / rk3588s-gpu.dtsi / rk3588s-npu.dtsi / rk3588s-crypto.dtsi
```
> 传递闭包已经验过：这 8 个 dtsi 各自只再 include `dt-bindings/*`，没有更深依赖。
> 主线 `rk3588.dtsi`（166B）、`rk3588-opp.dtsi`、`rk3588-*-pinctrl.dtsi` 与 BDY 内核**逐字节一致**，直接用主线的。

**2. 驱动（源码走 `files/`，Kconfig/Makefile 走补丁）**

```
target/linux/rockchip/files/drivers/net/dsa/yt921x.c   (127 KB, DSA 主驱动)
target/linux/rockchip/files/drivers/net/dsa/yt921x.h
target/linux/rockchip/files/net/dsa/tag_yt921x.c       (DSA 标签驱动)
target/linux/rockchip/files/Documentation/devicetree/bindings/net/dsa/motorcomm,yt921x.yaml

target/linux/rockchip/patches-6.18/900-net-dsa-add-Motorcomm-YT921x-driver.patch
    → 4 个 hunk：drivers/net/dsa/{Kconfig,Makefile} + net/dsa/{Kconfig,Makefile}
```
补丁对主线 `linux-6.18.54` **dry-run 通过**，应用后这 4 个文件与 BDY 内核原文件**逐字节一致**。

**3. 内核配置**

`target/linux/rockchip/armv8/config-6.18` 加了：
```
CONFIG_NET_DSA_YT921X=y
CONFIG_NET_DSA_TAG_YT921X=y
```
（`CONFIG_NET_DSA=y` 和 `CONFIG_DWMAC_ROCKCHIP=y` 本来就有。）

**4. 设备**

`target/linux/rockchip/image/armv8.mk` 新增：
```make
define Device/bdy_g98
  $(Device/rk3588)
  DEVICE_VENDOR := BDY
  DEVICE_MODEL := G98
  DEVICE_DTS := rk3588-bdy-g98
  DEVICE_PACKAGES := kmod-r8169
endef
TARGET_DEVICES += bdy_g98
```

## 对上游 DTS 的唯一改动 ⚠️

上游 DTS 里有这么一段：
```dts
&system_sram2 { /delete-node/ rkvdec-sram@0; /delete-node/ rkvdec-sram@78000; };
&rkvdec0 { rockchip,sram = <&vdec0_sram>; };
&rkvdec1 { rockchip,sram = <&vdec1_sram>; };
```
`vdec0_sram` / `vdec1_sram` **只在 BDY 私改的 `rk3588-base.dtsi` 里定义**（主线 6.18 的 `system_sram2` 是个空节点，没有子节点）。不删就编不过：

```
ERROR (phandle_references): /rkvdec-core@fdc38000: Reference to non-existent node or label "vdec0_sram"
```

处理：**整段删掉**，并留了注释说明。视频解码的 SRAM 池对路由器毫无意义，删掉后 `rkvdec` 继续用 `rk3588s-vpu.dtsi` 自己定义的 `rkvdec0_sram/rkvdec1_sram`（那两个标签是存在的），没有悬空引用、也没有重叠池。

> 没有采用"把 BDY 的 `rk3588-base.dtsi` 一起 vendor"的方案——那样会**替换掉本 target 下所有 rk3588 板子的 SoC dtsi**（BDY 版本与主线差 252 行 / 11 个 hunk，还加了 rga3 节点、power-domain 标签等），影响面太大。

## 验证状态

| 项 | 状态 |
|---|---|
| `cpp → dtc` 完整编译 DTS | ✅ `dtc exit=0`，产物 123385 B；0 error / 6 warning（全是主线 dtsi 自带的 `unique_unit_address`） |
| 产物自检 | ✅ `model = "BDY G98"`，`motorcomm,yt9215` ×2，`dsa,member` ×2，`lan1`~`lan8`，`r8125,led` ×8 |
| 驱动补丁 dry-run（全新 linux-6.18.54） | ✅ 4/4 干净应用，结果与源仓库逐字节一致 |
| `files/` 拷贝落位 | ✅ 模拟 `cp -fpR files/. $(LINUX_DIR)/` 路径正确 |
| **整机 `make` 编译** | ⬜ **未做**——本树 `.config` 仍是 qualcommax，且当时有 `make world` 在跑，没敢切 target |

## 还没定 / 没做

1. **启动路径**（最关键，决定最终镜像怎么出）
   - `Device/bdy_g98` 继承了 `BOOT_FLOW := pine64-img`，会去 `dd`
     `$(STAGING_DIR_IMAGE)/g98-rk3588-u-boot-rockchip.bin` —— **这个文件不存在**，
     除非给 `package/boot/uboot-rockchip/Makefile` 加一条 `U-Boot/g98-rk3588`。
   - 这板子走的是自己的 **BDY_G98_UEFI（SPI EDK2）**，标准 u-boot 流程本来就对不上。
   - 另一条路是 `armsr/armv8`（UEFI/GRUB，出 `combined-efi.img.gz`），但它的 `grub-efi.cfg`
     只有 `linux ...`，**没有 `devicetree` 行**，需要补一行
     `devicetree /efi/openwrt/rk3588-bdy-g98.dtb`，或者让 UEFI 通过 EFI DT 配置表交 DTB。
2. **RTL8125 LED**：DTS 里的 `r8125,led0..3` 需要 r8169 的 DT 支持补丁（`rtl8125_set_led_mode`）。
   BDY 内核里有；飞牛那个 `r8169-upstream-patch/` 目录下的两个 `.patch` 文件**实际是 1 字节的空文件**，取不到内容。
   不打补丁属性会被忽略，**只是 LED 不亮，不影响联网**。
3. **编译出包还没跑过**，见上面的验证状态表。

## 以后怎么编

```sh
# 等 make world 跑完、.config 备份好之后
make menuconfig
#   Target System: Rockchip — RK33xx/RK35xx boards (64 bit)
#   Subtarget:     RK33xx/RK35xx boards (64 bit)
#   Target Profile: BDY G98
make defconfig
make -j$(nproc) download
make -j$(nproc)
```
产物里 DTB 叫 `image-rk3588-bdy-g98.dtb`（FIT 打包），单独编 DTB 可用 `make compile-dtb`。
