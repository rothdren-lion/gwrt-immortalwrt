# GWRT 下次编译待集成的基础命令

记录时间：2026-10-24  
当前镜像：`gwrt 261024-01`（主题 overlay `1.0-r112`）

## 必须加入基础镜像

- `lsblk`（util-linux，块设备列表）
- `blkid`（util-linux，块设备 UUID/文件系统）
- `nano`（命令行编辑器）
- `htop`（进程/资源查看）
- `lsusb`（`usbutils`，USB 设备列表）

建议一并带上的依赖/相关包：

```text
CONFIG_PACKAGE_lsblk=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_usbids=y
CONFIG_PACKAGE_libusb-1.0=y
CONFIG_PACKAGE_libudev-zero=y
```

`usbutils` 依赖 `libusb-1.0`、`usbids` 和 `libudev` 兼容层；上次
`make defconfig` 曾因缺 `libudev` 把它丢掉，下次要一起选上。

## 当前状态（刷机后实测）

```text
nano   已安装（/usr/bin/nano）
htop   已安装（/usr/bin/htop）
lsblk  缺失
blkid  缺失
lsusb  缺失
```

## 空间问题

当前基础镜像：

```text
fit volume: 31997952
image:      31969586
剩余:       28366 字节
```

只剩约 **28 KB**，不可能直接把 `nano/htop/lsblk/blkid/usbutils` 塞进基础
镜像。下次编译前必须先做其中一项：

1. 扩大 UBI `fit` 卷（同时缩小 `rootfs_data`）；或
2. 从基础镜像裁掉不需要的包/资源，腾出至少约 1 MB；或
3. 这些命令继续放 `rootfs_data` overlay，不叫“集成进基础镜像”。

按用户要求，下次编译优先走 **基础镜像集成**；因此要先处理 fit 空间，不能
只加 `CONFIG_PACKAGE_*` 然后让镜像构建因超容量失败。

## 说明

这轮没有编译；以上只是下次构建清单。当前设备上的 `nano`/`htop` 来自
overlay，`lsblk`/`blkid`/`lsusb` 仍没有。


## 2026-10-24 追加决定：扩大 fit

用户决定：**直接扩大 `fit`，`rootfs_data` 小一点可以接受**。

规划尺寸：

```text
fit:          48 MiB 左右（约 396 LEBs）
rootfs_data:  192 MiB 左右（约 1585 LEBs，当前 209.7 MiB）
```

`rootfs_data` 当前只用了约 35.6 MiB，缩到约 192 MiB 仍然很宽裕；
`fit` 从 30.5 MiB 扩到约 48 MiB，给 `lsblk/blkid/nano/htop/lsusb`
和后续基础包留出空间。

### 在线操作结果

直接在当前系统执行：

```sh
ubirsvol /dev/ubi0 -N rootfs_data -s 200MiB
ubirsvol /dev/ubi0 -N fit -s 40MiB
```

两个都返回：

```text
ubirsvol: error!: cannot UBI resize volume
          error 16 (Resource busy)
```

因为 `fit` 是当前 lower rootfs、`rootfs_data` 正作为 overlay 挂载，Linux
运行态不能改。必须从 **U-Boot / recovery initramfs** 离线操作。

### 下次刷机前顺序

1. 进入 U-Boot Web 恢复 / recovery initramfs，确保 overlay 未挂载。
2. 先缩 `rootfs_data`，再扩 `fit`（或按 LEB 数操作）。
3. 重启回正常系统，确认 `ubinfo -a` 和 overlay 正常。
4. 再编译带基础命令的镜像并刷入。
5. 刷完重新执行 `addons/install-addons.sh`。

离线命令示意（以实际 LEB 数为准）：

```sh
ubirsvol /dev/ubi0 -N rootfs_data -S 1585
ubirsvol /dev/ubi0 -N fit -S 396
```

这轮没有改 UBI 布局，也没有编译；当前设备仍保持原布局。

> **2026-10-25 修正：上面“先缩 rootfs_data 再扩 fit”的 `ubirsvol` 方案不要直接执行。**
> `rootfs_data` 是 UBIFS，`ubirsvol` 只改 UBI 卷大小，不会改 UBIFS 超级块；
> 缩小后挂载会报 `bad LEB count ... in superblock, ... on UBI volume`，overlay 会损坏。
> 正确做法见文末“fit 扩容修正”一节：备份配置 → 删除 rootfs_data →
> 扩 fit → `ubimkvol -N rootfs_data -m` 重建 → 重启后恢复配置。

## 2026-10-25 追加：AN7581 仪表盘 PON 卡片

已改主题（未刷机）：

- 规范源：`gwrt-theme-V3/theme/luci-theme-gwrt/`
- 仪表盘“网络接口状态图”最左侧新增 PON 卡片，PON 卡替代原来的 pon0 通用 WAN 卡。
- 卡片常显：PON 模式、RX/TX 光功率、模块温度、实时 ↓/↑ 速率、注册状态。
- 点击卡片打开 PON 面板：
  - 光模块：RX/TX 光功率、温度、电压、TX Bias、ONU/MPCP 状态、ONU ID。
  - 流量：本次运行累计、实时速率、XGEM RX/TX 帧。
  - PON WAN：启用、业务 VLAN、DHCP/PPPoE/静态、PPPoE 账号密码，保存后执行
    `/usr/libexec/pon-wan-apply apply`。
  - “线路模式 / SN / LOID 设置”跳到现有 `luci-app-pon` 配置页。
- 数据源：
  - `ponctl --device pon0 status --json`（线路/光模块/注册/计数）。
  - `network.device status pon0` 的 `statistics.rx_bytes/tx_bytes`（收发数据）。
- IPQ/无 pon0 的板子不显示 PON 卡片；没有复制第二套主题，避免双份维护。
- 主题 ACL 增加 `pon_wan` 读写、`ponctl` 和 `pon-wan-apply` 执行权限。
- 因为 `cascade.css` 被 csstidy 截断，PON 样式单独放在
  `htdocs/luci-static/gwrt/css/pon.css`，并在 `header.ut` 引入。

当前主题版本：`2026.10.25-16`（已 `integrate.sh` 同步并通过主题包编译）。

仍未编译整机、未刷机；fit 仍只剩约 28 KB，下一次整机编译前仍需按上面的
UBI 扩容步骤先离线扩 fit。

## 2026-10-25 修正：fit 扩到 64/80 MiB 的正确做法

### 尺寸建议

LEB 大小按当前布局算是 `126,976` 字节（124 KiB）：

| fit 目标 | fit LEBs | fit 实际大小 | rootfs_data 重建后（约） |
| --- | ---: | ---: | ---: |
| 48 MiB | 396 | 47.95 MiB | 1588 LEBs / 192.3 MiB |
| **64 MiB（推荐）** | **528** | **63.94 MiB** | **1456 LEBs / 176.3 MiB** |
| **80 MiB（一次到位）** | **660** | **79.92 MiB** | **1324 LEBs / 160.3 MiB** |
| 96 MiB | 792 | 95.91 MiB | 1192 LEBs / 144.3 MiB |

当前 fit 是 252 LEBs（31,997,952 字节），rootfs_data 约 1732 LEBs
（209.7 MiB）。实际以 `ubinfo -a` 为准。

48 MiB 只多出约 16 MiB，装完 `lsblk/blkid/nano/htop/lsusb` 和主题后
余量不多；**建议直接 64 MiB，想一次到位就 80 MiB**。96 MiB 以上没必要，
fit 空着也是浪费，rootfs_data 反而变小。

### 关键：不能直接缩 rootfs_data

`ubirsvol -N rootfs_data -S ...` 只改 UBI 卷大小，不会改 UBIFS 超级块。
缩小后挂载会报：

```text
UBIFS error: validate_sb: bad LEB count: ... in superblock, ... on UBI volume
```

也就是 overlay 直接损坏。**不要执行之前那两条 `ubirsvol` 缩容命令。**

### 正确离线步骤（以 80 MiB 为例）

在 recovery initramfs / U-Boot 恢复环境操作，确保 `rootfs_data` 没有挂载。

```sh
# 0. 先看当前布局，确认 fit/rootfs_data 的 LEB 数和可用空间
ubinfo -a
ubinfo /dev/ubi0 -N fit
ubinfo /dev/ubi0 -N rootfs_data

# 1. 备份 overlay 里重要的东西（至少 /etc/config、密码、dropbear、/root）
mkdir -p /mnt/old
mount -t ubifs ubi0:rootfs_data /mnt/old
tar -czf /tmp/rootfs-config.tgz -C /mnt/old \
    etc/config etc/passwd etc/shadow etc/dropbear root
umount /mnt/old
# 把 /tmp/rootfs-config.tgz 拷到 U 盘或电脑；/tmp 重启会丢

# 2. 删除旧 rootfs_data（会清空 overlay）
ubirmvol /dev/ubi0 -N rootfs_data

# 3. 扩 fit 到 80 MiB（660 LEBs）
ubirsvol /dev/ubi0 -N fit -S 660

# 4. 用剩余空间重建 rootfs_data
ubimkvol /dev/ubi0 -N rootfs_data -m

# 5. 校验
ubinfo -a
ubinfo /dev/ubi0 -N fit
ubinfo /dev/ubi0 -N rootfs_data
```

然后重启。OpenWrt 会把新的 `rootfs_data` 格式化并挂载；恢复
`/etc/config`，再重新执行 `addons/install-addons.sh`。

64 MiB 把第 3 步换成：

```sh
ubirsvol /dev/ubi0 -N fit -S 528
```

### 如果一定要保留 overlay

只有一种不丢数据的情况：`ubinfo -a` 显示还有足够的 `avail_lebs`，
直接扩 fit，不碰 rootfs_data：

```sh
ubinfo -a          # 看 avail_lebs
ubirsvol /dev/ubi0 -N fit -S $((252 + AVAIL_LEBS))
```

但当前布局大概率没有 276/408 个空闲 LEBs，所以想上 64/80 MiB
基本都要重建 rootfs_data。零风险方案是继续把新命令放 overlay，
不扩 fit。

## 2026-10-25 实测：主题已推到 192.168.3.3

设备：Nokia XG-040G-MD (UBI)，ImmortalWrt SNAPSHOT，内核 6.18.55。

已安装主题：`luci-theme-gwrt-2026.10.25-r07`。

实测结果：

- “网络接口状态图”最左侧 PON 卡片正常渲染：`XG-PON`、RX/TX -40.00 dBm、
  41.6 °C、0 B/s、等待光信号。
- 当前 PON 没有接光纤：`ponctl` 返回 `optical_signal=false`、
  `lifecycle=wait-optical-signal`、`rx/tx_power=-40 dBm`，所以卡片显示
  -40 dBm 是正常的“无光”值。
- 点击卡片面板正常：RX/TX 光功率、温度、电压、TX Bias、ONU O1、
  MPCP 不适用、累计流量、XGEM 帧。
- PON WAN 表单读取到实际配置：启用、VLAN 41、DHCP。
- PPPoE / 静态 IP 字段切换正常；VLAN 9999 会被前端拦截。
- “线路模式 / SN / LOID 设置”能在内嵌窗口打开现有 PON 配置页。
- 点击“保存并应用”成功，日志确认：
  `PON WAN service applied (enabled=1 uplink=pon0 vlan=41 iface=wan proto=dhcp)`。
- 页面无 JS 异常；只有旧主题已有的两个控制台提示（meta X-Frame-Options、
  PON WAN 密码框不在 form 内），不影响功能。
- `pon.css` 的 cache-buster 已改为跟随 `/usr/share/gwrt/theme-version`，
  当前为 `?v=2026.10.25-07`。

回滚包已放在设备 `/tmp/luci-theme-gwrt-1.0-r112.apk`。

### 实测 UBI 布局（与扩容有关）

```text
LEB size: 126976 bytes (124 KiB)
Total LEBs: 2047
Available LEBs: 0

fip           9 LEBs
fit         252 LEBs (31,997,952 bytes)
ubootenv      1 LEB
ubootenv2     1 LEB
bosa          3 LEBs
ri            3 LEBs
rootfs_data 1732 LEBs (219,922,432 bytes)
```

所以扩到 80 MiB 时 `fit=660 LEBs`，`rootfs_data` 重建后为
`1732 - (660-252) = 1324 LEBs`（约 160.3 MiB）。因为当前
`Available LEBs=0`，不能只扩 fit；必须按“删除/重建 rootfs_data”的
安全流程做，不能直接 `ubirsvol` 缩 UBIFS。

## 2026-10-25 追加：固件版本和 SoC 显示修复

### 固件版本

新增主题文件：

```text
gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/gwrt/firmware-version
内容：gwrt 261024-01
```

仪表盘“固件”行、页脚和 SSH 登录 banner 都直接读这个文件，不再显示 `ImmortalWrt SNAPSHOT`。
OTA 返回的 `current_version` 只有符合 `gwrt YYMMDD-NN` 时才允许覆盖，
`ImmortalWrt SNAPSHOT r0-...` 会被忽略。

`scripts/gwrt-next-firmware-version.sh` 已修正为同时写：

```text
gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/gwrt/firmware-version
package/gwrt-theme/luci-theme-gwrt/root/usr/share/gwrt/firmware-version
package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt/root/usr/share/gwrt/firmware-version
```

下次编译前运行一次，会生成当天版本，例如 `gwrt 261025-01`。

### SoC 显示

原实现依赖 `/sys/devices/soc0/machine` 和
`/proc/device-tree/compatible`，但这台设备：

- `/sys/devices/soc0/machine` 不存在；
- `ubus file exec cat /proc/device-tree/compatible` 只返回第一个字符串
  `nokia,xg-040g-md-ubi`，后面的 `airoha,an7581` 被 NUL 截断。

所以之前退回显示 `Nokia XG-040G-MD (UBI) · 4 cores`。

现在优先从 `board.release.target` 识别：

```text
airoha/an7581 -> AN7581
airoha/an7583 -> AN7583
```

核心数仍从 `/proc/cpuinfo` 统计，显示为：

```text
AN7581*4
AN7583*2
```

已用 7581/7583 模拟数据验证；真机 192.168.3.3 实测显示 `AN7581*4`。

### 一个 ucode 模板坑

ucode 字符串不支持 JS 风格的 `.trim()`，会报
`left-hand side expression is not an array or object`。模板里必须用
`trim(readfile(...) ?? '')`。这轮已经修正，主题版本 `2026.10.25-09`。

## 2026-10-25 OAF 显示检查

OAF 实际是启动的：

```text
/etc/init.d/appfilter status  -> running
/etc/init.d/appfilter enabled -> enabled
ps: /usr/bin/oafd
    /usr/bin/lua /usr/bin/rule_manager
lsmod: oaf
ubus: fwx 存在，get_all_users/class_list 返回 code 2000
```

主配置是 `/etc/config/fwx`，不是 `/etc/config/appfilter`；服务脚本是
`/etc/init.d/appfilter`，没有 `/etc/init.d/oaf`。

主题里原来把 OAF 的菜单标题（Parental Control）翻译成“应用过滤”，
容易让人以为 OAF 没出现。已在 `menu-i18n.js` 增加 `oaf` 别名，
侧栏和仪表盘“服务”网格现在显示“OAF 行为管理”。主题版本
`2026.10.25-11`。

OAF 页面本身能打开，状态显示服务版本 7.0.1、引擎 6.0.1、特征库
26.09.07。当前在线用户/流量是 0，原因是：

- 唯一客户端 ChromBox（`00:e0:4c:00:c0:b0`）被 OAF 访问控制规则
  `dsa` 标记为 `mac_blocked`；
- PON WAN 当前无光/未连接，也没有外网流量。

如果这不是有意拦截，在 OAF → 访问控制里停用/删除该规则，再接通 PON
并产生流量，OAF 才会显示应用和流量数据。

## 2026-10-25 版本命名与 IPQ 统一：GWRT YYMMDD-NN

IPQ/qualcommax 侧（192.168.9.9）的固件信息是：

```text
DISTRIB_ID='GWRT'
DISTRIB_RELEASE='260920-05'
DISTRIB_DESCRIPTION='GWRT 260920-05 r40261+...'
镜像名: gwrt-261021-04-qualcommax-ipq60xx-...-squashfs-sysupgrade.bin
```

做法是编译配置里打开版本选项：

```text
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="GWRT"
CONFIG_VERSION_NUMBER="YYMMDD-NN"
CONFIG_VERSION_MANUFACTURER="GWRT"
CONFIG_VERSION_FILENAMES=y
```

AN7581 现在完全对齐这套命名。

### 编译配置

`.config` 与 `gwrt-theme-V3/manifest/config.fragment` 增加：

```text
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="GWRT"
CONFIG_VERSION_MANUFACTURER="GWRT"
CONFIG_VERSION_FILENAMES=y
# CONFIG_VERSION_CODE_FILENAMES is not set
```

`CONFIG_VERSION_NUMBER` 不写进 fragment，由脚本按日期和编译次数生成，避免每次
`integrate.sh` 把它覆盖回固定值。

下一次整机编译后：

```text
/etc/openwrt_release   DISTRIB_ID='GWRT'  DISTRIB_RELEASE='261025-01'
/etc/os-release        NAME="GWRT"  PRETTY_NAME="GWRT 261025-01"
镜像名                 gwrt-261025-01-airoha-an7581-nokia_xg-040g-md-ubi-squashfs-sysupgrade.itb
```

### 版本号自动递增

`scripts/gwrt-next-firmware-version.sh` 已重写：

```text
GWRT YYMMDD-NN
   YYMMDD = 编译日期
   NN     = 当天第几次编译（跨天回到 01）
```

它读取并回写 `.config` 的 `CONFIG_VERSION_NUMBER`，同时更新三份主题
`firmware-version` 文件。用法：

```sh
scripts/gwrt-next-firmware-version.sh            # 递增，输出 GWRT 261025-02
scripts/gwrt-next-firmware-version.sh --show     # 只查看
scripts/gwrt-next-firmware-version.sh --set 261025-01
```

`gwrt-theme-V3/scripts/build-with-theme.sh` 会在 `make` 前自动调用一次，
所以正常整机编译不需要手动执行。设置 `GWRT_NO_VERSION_BUMP=1` 可跳过。

### 显示

- 仪表盘固件行、页脚、SSH banner 统一显示 `GWRT 261025-01`；
- 模板优先使用 `/etc/openwrt_release` 里的 GWRT 版本，读不到才退回
  `/usr/share/gwrt/firmware-version`，避免主题包里的旧值盖住固件真实版本；
- `30_gwrt-banner` 在发行版为 GWRT 时会用 `DISTRIB_RELEASE` 回写
  `firmware-version`。

### 真机验证（192.168.3.3）

当前运行镜像仍是旧的 ImmortalWrt 构建，overlay 上已同步改成 GWRT 版本
（原文件备份在 `/root/gwrt-release-backup-*`）：

```text
/etc/openwrt_release   DISTRIB_ID='GWRT'  DISTRIB_RELEASE='261025-01'
/usr/lib/os-release    NAME="GWRT"  VERSION="261025-01"  ID="gwrt"
ubus system board      GWRT 261025-01 r0-cb793d3
仪表盘固件行           GWRT 261025-01
页脚                   GWRT 261025-01
SSH banner             GWRT 261025-01 + Theme 2026.10.25-12
```

主题包：`luci-theme-gwrt-2026.10.25-r12.apk`。下次刷入新固件后，
`/etc/openwrt_release` 会由编译配置直接生成，不再需要 overlay 补丁。

## 2026-10-25 仪表盘 PPE 改为真实硬件数据

之前第二个卡片的 `PPE` 行其实是**上联口利用率**：读 `network.device status`
的 rx/tx 字节差分除以链路速率，只是标签写成了 PPE，和 Airoha PPE 无关。

现在拆成三行，数据全部来自本机：

| 行 | 来源 | 含义 |
| --- | --- | --- |
| `PPE` | `/sys/kernel/debug/ppe/entries` | `已绑定流/流表容量`，占用条按全部有效条目 |
| `PPE 流量` | 同上的 `packets=/bytes=` | 硬件计数差分得到的速率；无计数时显示 `-` |
| `PPE 类型` | 同上的 type 字段 | 前两种加速类型及条数，超出用 `+N` 表示 |
| `上联` | `network.device status` | 原来的端口利用率，标签改回真实含义 |

鼠标悬停 `PPE` 行还能看到：SoC、`N×PPE`、容量、`BND/UNB/FIN`、NPU 是否挂载。

### 数据脚本

新增 `/usr/libexec/gwrt-ppe-stats`，只读 debugfs，不写任何状态：

```text
/sys/kernel/debug/ppe/config    npu_attached、ppeN_table_cfg
/sys/kernel/debug/ppe/entries   每条有效加速流（state/type/packets/bytes）
```

输出单行 JSON：

```json
{"available":1,"soc":"AN7581","num_ppe":2,"capacity":32768,"npu":0,
 "bound":0,"unbound":0,"fin":0,"used":0,"packets":0,"bytes":0,"types":{}}
```

容量公式与驱动一致（`drivers/net/ethernet/airoha/airoha_ppe.c`）：

```text
capacity = num_ppe * 8192 + 16384
AN7581  2 个 PPE -> 32768
AN7583  1 个 PPE -> 24576
```

`num_ppe` 不写死，直接数 `config` 里的 `ppeN_table_cfg` 行数，所以 AN758x
全系列（含以后新增的 SoC）都能用；没有 debugfs 的平台脚本返回
`{"available":0}`，整行自动隐藏。

主题 ACL 增加：

```text
"/usr/libexec/gwrt-ppe-stats": ["exec"]
```

### 标题

Airoha 平台不再显示 Qualcomm 的 `NSS`：

```text
CPU · NSS · PPE · 温度   ->   CPU · PPE · 温度
```

判定条件：`ubus system board` 的 target 含 `airoha`，或 SoC 显示为 `ANxxxx`。

### 为什么现在 PPE 流量是 `-`

当前内核 `CONFIG_NET_AIROHA_FLOW_STATS` 没有打开，并且没有 WAN 流量时
NPU 还没 attach（`npu_attached: 0`），所以 `packets/bytes` 恒为 0：

```text
target/linux/airoha/an7581/config-6.18
# CONFIG_NET_AIROHA_FLOW_STATS is not set
```

驱动里 `airoha_ppe_foe_entry_get_stats()` 只有在该选项打开且 NPU 已挂载时才
填充计数；AN7583 明确返回 `-EOPNOTSUPP`。

要拿到硬件字节/速率，需要单独做一次内核改动并验证：

```text
CONFIG_NET_AIROHA_FLOW_STATS=y
```

注意：`airoha_ppe_offload_setup()` 在统计初始化失败时会连带让硬件 offload
setup 失败，所以这个选项**没有在本次改动里打开**，等有一次可刷机的完整
编译时再验证，避免影响现有转发。

### 真机验证（192.168.3.3，主题 2026.10.25-16）

```text
标题        CPU · PPE · 温度
PPE         0/32768           （AN7581 双 PPE，容量 32768）
PPE 流量    -                 （NPU 未挂载）
PPE 类型    隐藏              （当前 0 条加速流）
上联        0%                （lan3 1G 无流量）
SoC         AN7581*4
```

用合成 entries 验证过解析：`2/32768`、`IPv4 5T 1 · L2B 1 · +2`、
`硬件计数 1507 包 / 466500 字节`，busybox awk 与 x86 gawk 结果一致。

## 仪表盘端口角色跟随真实 UCI 配置（动态 WAN 识别）

### 问题

`luci.getBuiltinEthernetPorts` 返回的是 board 默认值，例如 AN7581 固定为：

```text
lan1 lan2 lan3 lan4 -> role=lan
pon0               -> role=wan
```

用户把 `lan1`（2.5G）配置成 WAN（`network.wan1.device='lan1'`）后，端口条
仍然把 `lan1` 画在绿色 LAN 组里，与实际配置不符。

### 事实来源

端口角色不再依赖 board 默认值，而是每次刷新时从 UCI 推导：

1. `uci get network` + `uci get firewall`（RPC，5 秒缓存）；
2. 取 `firewall` 中 `name='wan'` 的 zone 的 `network` 列表；
3. 再并上名字匹配 `wan` / `wanN` 的 interface 作为兜底；
4. 对每个 WAN interface 展开 `device` / `ifname` / `ports`；
5. 递归解析 `type='8021q'`、`type='bridge'` 等 device section；
6. 剥掉 VLAN 后缀（`lan1.41` → `lan1`，`pon0.41` → `pon0`）。

结果是一张 `设备名 → WAN interface section` 映射，例如当前设备：

```text
pon0.41 -> wan
pon0    -> wan
lan1    -> wan1
```

### 界面行为

- 被配置成 WAN 的 LAN 口自动从绿色 LAN 组移到左侧 WAN 区；
- 该端口使用 `.gwrt-port.wan` 的蓝色 3px 边框与蓝色状态点，和 PON 一致；
- 标签只跟随角色：LAN 口改成 WAN 后直接显示 `WAN`，不保留物理口名；
  右侧仍显示 `2.5G` 协商速率，端口身份可在设置面板查看；
- LAN 组仍为绿色边框，只包含剩余 LAN 口（当前 `LAN4 LAN3 LAN2`）；
- 拓扑图支持多个 WAN 上联：PON 与新的 `WAN` 口并排显示，PON 优先；
- 点击该 `WAN` 口打开的是对应接口 `wan1` 的设置（标题
  `WAN 设置 · WAN1`），不会再误改 PPPoE 的 `network.wan`；
- 顶部 WAN 状态/地址/实时速率跟随实际在用的 WAN（优先 up 的接口），
  PON 无光时自动显示 `wan1` 的 DHCP 地址。

### 代码位置

```text
gwrtWanDeviceSet(netvals, fwvals)    UCI → WAN 设备集合
gwrtUciConfigCached(config, ttl)     uci get 缓存（失败自动清缓存）
ethPortEntries(ports, states, wans)  端口角色/标签/wanSection
refreshPorts()                       拉取 network + firewall 后重绘
renderTopology()                     多 WAN 节点并排
gwrtWanSection(port)                 设置面板定位真实 interface section
```

读取失败时回退到 board 默认值，端口条不会因为 UCI RPC 异常而消失。

### 真机验证（192.168.3.3，主题 2026.10.25-20）

```text
端口条顺序   PON | WAN(蓝框) | [LAN4 LAN3 LAN2](绿框)
WAN          2.5G，已连接（物理口 lan1）
拓扑         PON(down) + WAN(2.5G) 并排 -> GWRT
点击 WAN      WAN 设置 · WAN1，DHCP，IP 192.168.9.123
```

## 2026-10-27 AN7581 主题独立成线 + mesh 定点合并

### 背景：mesh 同步覆盖了 package 副本

另一棵树用 `scripts/gwrt-sync-mesh.sh`（内部 `rsync -a --delete package/gwrt-*`）
把 MT7981 的 mesh 主题同步过来，结果：

- `package/gwrt-theme/luci-theme-gwrt`（扁平）和
  `package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt`（嵌套）被换成 `1.0-r94`；
- 丢掉 `gwrtWanDeviceSet`（动态 WAN）、`gwrt-ppe-stats`（真实 PPE）、
  `pon.css`、`/usr/share/gwrt/firmware-version`、header 里的 pon.css 引用；
- 换来了 `renderMeshInfo` / `wifiroam`；
- 规范源 `gwrt-theme-V3` 没被覆盖（`2026.10.25-20` 仍完整）。

结论：`integrate.sh --check` 报 `flat theme package differs from canonical source`，
此时直接编固件会装出没有 PPE/动态 WAN 的旧主题。

### 处理方式：主题按 SoC 分线，不再共用

`gwrt-theme-V3/SERIES` = `an7581`，AN7581 主题只在本树维护，自带
PPE / PON / 动态 WAN / 固件版本 / mesh 摘要。MT7981 主题仍在那棵树里。

两层保护：

1. **同步脚本自动跳过**：MT7981 树的 `scripts/gwrt-sync-mesh.sh` 检测目标
   `.config` 里 `CONFIG_TARGET_BOARD="airoha"` 时跳过 `package/gwrt-theme`
   （`--with-theme` 可强制覆盖）。
2. **本树自己的同步脚本**：`scripts/gwrt-sync-mesh.sh` 永远不同步主题。

主题更新按文件挑选，不整目录覆盖：

```sh
# 列出两棵树的主题差异（+ 对方新增 / 不同 / ! 本树独有）
./gwrt-theme-V3/scripts/gwrt-theme-pull.sh --from /path/to/other/tree

# 看单个文件差异
./gwrt-theme-V3/scripts/gwrt-theme-pull.sh --from /path/to/other/tree \
  --diff root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut

# 只拉指定文件（VERSION / SERIES 受保护，不会被覆盖）
./gwrt-theme-V3/scripts/gwrt-theme-pull.sh --from /path/to/other/tree \
  --apply htdocs/luci-static/gwrt/resources/menu-i18n.js
```

### 合并进 AN7581 主题的 mesh 增量（5 项）

| 项 | 位置 |
|---|---|
| `#gwrtMeshInfo` 容器 | 网络拓扑下方 |
| `renderMeshInfo()` | `wifiroam topology` 画节点、`wifiroam status` 显示主AP/子AP·在线·回传 |
| `.gwrt-mesh-*` 样式 | `cascade.css` 末尾 |
| ACL | `wifiroam status/peers/topology` |
| `--` | 未引入 `gwrt-socinfo`：本主题直接读 `/proc/device-tree/compatible` |

**没有合入**的 mesh 改动：

- `30-gwrt-ssid-name` / `gwrt-wireless.sh` 的 MT7981 逻辑（eth0 MAC 优先、
  `mac_suffix` 取法变化、band 参数）——AN7581 有 `label-mac-device`，
  现有版本能正常生成 `GWRT_*_xxxx`；
- `header.ut` / `footer.ut` / `banner`（mesh 副本是 7 月版本，比我们旧）。

### 顺手修掉的 ACL 缺失

首页用 `file exec` 读 `/proc/device-tree/compatible` 和
`/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq`，但 ACL 里没有对应
`read` 权限，rpcd 会拒绝（SoC 型号/频率静默回落）。已补：

```json
"/proc/device-tree/compatible": ["read"],
"/sys/devices/system/cpu/cpufreq/*/*": ["read"]
```

### 结果

```text
主题版本    2026.10.27-01（integrate.sh 自动递增，日期已跨到 10-27）
package 副本 扁平 + 嵌套，均与规范源一致
integrate --check 通过
apk         luci-theme-gwrt-2026.10.27-r01.apk
打包内容    PPE 脚本 + pon.css + firmware-version + 动态 WAN + mesh 行 全在
固件版本    未动，仍 GWRT 261025-01
```

> 注意：`192.168.3.3` 在本轮期间 ping 不通、SSH 超时，**尚未装机验证**。
> 设备恢复后执行：
>
> ```sh
> scp bin/packages/aarch64_cortex-a53/base/luci-theme-gwrt-2026.10.27-r01.apk \
>   root@192.168.3.3:/tmp/gwrt.apk
> ssh root@192.168.3.3 'apk add --allow-untrusted --force-overwrite /tmp/gwrt.apk;
>   rm -f /tmp/gwrt.apk; /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart'
> ```
>
> 验收点：端口条仍有 `WAN(蓝框)`、PPE 卡片有真实数据、拓扑下出现
> 「漫游组网」一行（未装 wifiroam 时该行自动隐藏，属正常）。

### 追加：从 MT7981 已测版本直接复制（同日 r03）

MT7981 那边已经实机测过，把它的成品文件直接搬过来，避免两边逻辑分叉。
复制源是 MT7981 树的 **package 副本**（真正编译进固件的那份），不是它的
`gwrt-theme-V3` 规范源（那份还停在 10-04）。

| 文件 | 变化 |
|---|---|
| `package/gwrt-mesh-apmode/files/usr/libexec/gwrt-mesh-apmode` | 新增 `restore_network_only()`（有线/无线回传切换时只重放网络，不动 SSID）、`apply_apmode force` 参数、`save_state` 不再覆盖已有状态 |
| `root/lib/functions/gwrt-wireless.sh` | `gwrt_wifi_role()` 增加 MT7981/86/88 的 `18000000.wifi` 分支和 5.2G/5.8G 按信道区分；默认 SSID 判定只认本机 MAC 后 4 位（避免把主AP 下发的同名 SSID 改回本机后缀） |
| `root/etc/hotplug.d/ieee80211/30-gwrt-ssid-name` | MAC 优先取 `eth0`，回退 `get_mac_label`；`mac_suffix` 改 `tail -c 4`；`gwrt_wifi_role` 多传 channel |
| `gwrt-mk-wr630ax-config.sh` | 增加 h3c_nx30-pro / ax3000t / ax3000t-ubootmod / rax3000m 四个 profile |

AN7581 没有无线射频（Nokia XG-040G-MD 是纯光猫，DTS 里没有 wifi 节点），
所以 SSID 命名逻辑在这台机器上是空跑；`eth0` 不存在时自动回退
`label-mac-device = &gdm1`，行为不变。

**主题本身的 mesh 代码已核对为逐字一致**（`renderMeshInfo()` 与
`.gwrt-mesh-*` 样式，仅中文用 `\u` 转义写法不同），所以不需要再搬。

### 编译位置

全部在系统盘编译：

```text
源码/产物   /home/godsun/build/immortalwrt-an7581   (/dev/mmcblk0p3, btrfs)
BUILD_DIR   $(TOPDIR)/build_dir                     （树内，不在 NAS）
.config     CONFIG_CCACHE_DIR=""  CONFIG_BUILD_LOG_DIR=""  无 /mnt 路径
NAS 树      /mnt/syNAS/.../immortalwrt              只做参考，不编译
```

主题版本 `2026.10.27-03`，产物
`bin/packages/aarch64_cortex-a53/base/luci-theme-gwrt-2026.10.27-r03.apk`。

## 2026-10-28 整包编译：原 config + 同步过来的 mesh

设备没开机，直接出固件。做法是在**原 .config 基础上只加 4 个 mesh 包**，
不重跑 `gwrt-mk-an7581-config.sh`，避免把 PON / 主题 / 插件集又改一遍。

```text
目标       airoha / an7581 / nokia_xg-040g-md-ubi（多 profile）
版本       GWRT 261025-01（未改）
新增       CONFIG_PACKAGE_gwrt-mesh-led=y
           CONFIG_PACKAGE_gwrt-mesh-apmode=y
           CONFIG_PACKAGE_gwrt-agent=y
           CONFIG_PACKAGE_gwrt-device-defaults=y
依赖解析   jsonfilter / curl / ucode-mod-digest 均为 y
备份       .config.bak-mesh-20261028-002725
```

`gwrt-device-defaults` 在这台机器上的实际效果：

| uci-defaults | AN7581 上的行为 |
|---|---|
| `94_gwrt-lan-ip` | 仍是 `192.168.3.3/24`（只在出厂 192.168.1.1 时替换） |
| `95_gwrt-wifi-defaults` | 无射频，空跑 |
| `96_gwrt-preset-apk` | 首启从 `/usr/share/gwrt/apk` 装 wifiroam + luci-app-wifiroam + ucode-mod-socket（aarch64，与本机匹配） |
| `97/98_gwrt-wifiroam-defaults` | 写 wifiroam / gwrt-agent 默认值 |

编译在系统盘 `build_dir` 内增量进行（原树 10-24 已有完整产物）。

### 内核配置修复：CONFIG_WIREGUARD_DEBUG（NEW 符号）

第一次 `make -j8` 在 `target/linux` 就挂了，日志：

```text
    WireGuard secure network tunnel (WIREGUARD) [M/n/y/?] m
      Debugging checks and verbose messages (WIREGUARD_DEBUG) [N/y/?] (NEW)
make[7]: *** [scripts/kconfig/Makefile:85: syncconfig] Error 1
```

原因：6.18 内核新加了 `WIREGUARD_DEBUG`，本树 `config-6.18` 里只写了
`CONFIG_WIREGUARD=m`，没有这个新符号，`syncconfig` 在非交互环境里读到 EOF
就报错。`make defconfig` 重写 `.config` 只是让它从「碰巧能过」变成「必然触发」。

修复（只加一行，位置紧跟 `CONFIG_WIREGUARD=m`）：

```text
target/linux/airoha/an7581/config-6.18
  CONFIG_WIREGUARD=m
+ # CONFIG_WIREGUARD_DEBUG is not set
```

`generic/config-6.18` 里是 `# CONFIG_WIREGUARD is not set`，subtarget 这份
是覆盖值，所以新符号也放同一份，顺序正确（target 在 generic 之后合并）。

验证合并结果（`kconfig.pl` 与构建时同一命令）：

```sh
./scripts/kconfig.pl +target/linux/airoha/an7581/config-6.18 \
    target/linux/generic/config-6.18 \
    target/linux/airoha/an7581/config-6.18 | grep WIREGUARD
# CONFIG_WIREGUARD=m
# CONFIG_WIREGUARD_DEBUG is not set
```

用 `make ARCH=arm64 oldconfig </dev/null` 扫过一遍，`(NEW)` 符号**只有这一个**，
不存在其它待答项。

另外把内核构建目录里的 `.config` / `.config.prev` 还原成 `Kernel/Configure`
生成的那份（之前手工跑 `olddefconfig` 把它重排并改了 12 个符号，例如
`NF_TABLES_BRIDGE y->m`、`SCSI_MOD y->m`，这些不是我们要的），再删掉
`include/config/auto.conf`、`include/generated/autoconf.h`，让 `syncconfig`
按新配置重新生成，避免 `.config` 与 `.config.set`（vermagic 来源）不一致。

### 编译完成（-j6）

按用户要求全程 `make -j6`（中途从 -j8 切到 -j6，杀进程后重跑，内核已编部分自动续编），
日志 `/tmp/opencode/build-mesh-j6-0048.log`，**无报错**（`EXIT=0`）。

```text
目标      airoha / an7581 / nokia_xg-040g-md-ubi（multiprofile）
版本      GWRT 261025-01
内核      6.18.55（Image 93.1 MB，模块 111 个，CONFIG_WIREGUARD_DEBUG=n）
产物      01:08
```

| 文件 | 大小 | sha256（前 16） |
|---|---|---|
| `gwrt-261025-01-...-ubi-squashfs-sysupgrade.itb` | 32 612 652 | `bd16057a4901f947` |
| `gwrt-261025-01-...-ubi-initramfs-recovery.itb` | 28 311 552 | `fd651234ce4d0490` |

manifest 256 个包，mesh 全部在内：

```text
gwrt-mesh-led         1.0-r1
gwrt-mesh-apmode      1.0-r1
gwrt-agent            1712-r6
gwrt-device-defaults  1.0-r1
luci-theme-gwrt       2026.10.27-r03
jsonfilter / curl / libcurl4 / ucode-mod-digest   （依赖自动带上）
```

原有插件未丢：`luci-app-openclash 0.48.002`、`luci-app-bandix-plus 0.1.2-r2`、
`bandix-plus 0.1.2-r1`、`luci-app-ttyd`、`coremark`。

镜像根内已确认落地：

```text
/usr/libexec/gwrt-mesh-apmode      20481
/usr/sbin/gwrt-agent               14476
/etc/init.d/gwrt-mesh-led            328
/etc/uci-defaults/94_gwrt-lan-ip     705
/etc/uci-defaults/96_gwrt-preset-apk 1351
/usr/share/gwrt/theme-version      2026.10.27-03
/usr/share/gwrt/firmware-version   GWRT 261025-01
/usr/share/gwrt/apk/               wifiroam + luci-app-wifiroam + i18n + ucode-mod-socket
```

`etc/config/wifiroam` 不在镜像里是设计如此：wifiroam 由 `96_gwrt-preset-apk`
首启装 apk，配置文件随包生成，`97_gwrt-wifiroam-defaults` 再写默认值。

刷机：

```sh
scp bin/targets/airoha/an7581/gwrt-261025-01-airoha-an7581-nokia_xg-040g-md-ubi-squashfs-sysupgrade.itb \
    root@192.168.3.3:/tmp/su.itb
ssh root@192.168.3.3 'sysupgrade -n /tmp/su.itb'
```

### 归档与清理（2026-10-28 14:24）

固件按型号归档到 NAS：

```text
/mnt/syNAS/Dowloads/Rout/mark/openwrt-rom/xg-040g-md/
  gwrt-261025-01-xg-040g-md-sysupgrade.itb   32 612 652
  gwrt-261025-01-xg-040g-md-initramfs.itb    28 311 552
  gwrt-261025-01-xg-040g-md.manifest              7 502
  sha256sums / sha256sums-261025-01
```

命名沿用 jdcloud 归档目录的习惯（`gwrt-<版本>-<型号>-{sysupgrade,initramfs}.itb`
+ `.manifest` + `sha256sums`），`sha256sums` 为最新一份。

复制后逐字节 `sha256sum` 比对通过：

```text
bd16057a4901f9479002ee3e2eeacbbc0d1c940a33c11203dea6d294dc39e44c  sysupgrade.itb
fd651234ce4d049046f0ac8757ab1ed8ef632c32b064484a7dedda798814ea5d  initramfs.itb
```

构建树 `bin/` 已清空（`bin/targets`、`bin/packages` 全删，170 MB）。
固件本体只在 NAS 那份；再编时 `make` 会按需重建 `bin/`（`build_dir` 里的
`.pkgdir` 和编译产物都在，不会整包重编）。
