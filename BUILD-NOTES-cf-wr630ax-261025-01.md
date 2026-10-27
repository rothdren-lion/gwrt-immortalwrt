# XINGLOO AX3000 (COMFAST CF-WR630AX) — MT7981B / ImmortalWrt filogic 构建与刷机记录

- 固件：GWRT 261025-01 + Theme 1.0-r111，内核 Linux 6.18.55
- 配置：`config.mt7981-wr630ax-261025-01`（生成脚本 `gwrt-mk-wr630ax-config.sh`）
- 构建：`gwrt-build-wr630ax.sh 6 261025-01`（本地树 `/home/godsun/build/immortalwrt-mt7981`）
- 目标：`mediatek/filogic`，设备 `comfast_cf-wr630ax`（显示名 XINGLOO AX3000）
- 备份：`backup-cf-wr630ax/`（原厂全分区 + 提取方法，见其中 `BACKUP.md`）
- 产物副本：`bin-wr630ax-261025-01/`

## 1. 硬件确认（证据）

| 项目 | 结论 | 证据 |
|---|---|---|
| 机型 | 对外 XINGLOO AX3000；OEM `comfast,cf-wr630ax` | 原厂 DTB `model`/`compatible`，原厂 `/etc/board.d/02_network` |
| SoC / RAM | MT7981B / 256 MiB DDR3 | U-Boot `EMI: Detected DRAM size: 256MB`，DTB `memory@40000000` |
| Flash | Winbond SPI-NAND 128 MiB，NMBM | dmesg `Winbond SPI NAND ... 128 MiB`，`NMBM ... attached` |
| 分区 | BL2 1M / u-boot-env 512K / Factory 2M / FIP 2M / ubi 64M | `/proc/mtd`、原厂 DTB |
| 交换 | MT7531AE @ MDIO 0x1f：port0..3 = lan1..lan4，port6 = CPU 2.5G | 原厂 DTB、dmesg `mt7530-mdio ... lan1..lan4` |
| WAN | gmac1 + MT7981 内置 GbE PHY（gmii） | dmesg `eth1: PHY [mdio-bus:00] MediaTek MT7981 PHY`，1G link |
| WLAN | MT7976CN（mt7915e），eeprom = Factory@0 | `ieee80211/phy0,phy1`，phy0 MAC = Factory+0x4（…:6b） |
| LED | red gpio8 / wan gpio13 / green gpio34 / blue gpio35（低有效） | 原厂 DTB；实测 `white:wan` netdev trigger 生效 |
| 按键 | reset gpio0 / wps gpio1（低有效） | 原厂 DTB；`gpio_button_hotplug` 已绑定 `gpio-keys` 平台设备 |
| 原厂固件 | Xingloo 2.0.3m6 `r0+24026-6fadcee50b`，Linux 5.15.164 | `/etc/banner`、`uname -a` |

## 2. 源码改动

| 文件 | 说明 |
|---|---|
| `target/linux/mediatek/dts/mt7981b-comfast-cf-wr630ax.dts` | 新机型 DTS（逐项对照原厂 DTB）：`model = "XINGLOO AX3000"`，compatible 保留 `comfast,cf-wr630ax`；MT7531 四口 + CPU 2.5G；WAN = gmac1 + `int_gbe_phy`；MAC 取 Factory@0xe000 的 `mac-base`；NMBM 分区；LED/按键；`bootargs-override = "console=ttyS0,115200n8"` |
| `target/linux/mediatek/image/filogic.mk` | `Device/comfast_cf-wr630ax`：XINGLOO AX3000（ALT：COMFAST CF-WR630AX）、KERNEL_IN_UBI、128k/2048、KERNEL_LOADADDR 0x44000000、DTS_LOADADDR 0x43f00000、`factory.bin`(append-ubi) + `sysupgrade.bin`(sysupgrade-tar) |
| `.../filogic/base-files/etc/board.d/02_network` | `comfast,cf-wr630ax` → `ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" eth1` |
| `.../filogic/base-files/etc/board.d/01_leds` | `white:wan` 走 `eth1` link/tx/rx |
| `gwrt-mk-wr630ax-config.sh` / `gwrt-build-wr630ax.sh` | 配置生成 / 构建（插件集 = AN7581 去掉 PON） |

与原厂 DTB 的有意差异：
- `spi_nand` 用 `reg = <0>`（原厂写 `<1>`；mt65xx SPI 驱动只有一条硬件 CS，`mtk_spi_set_cs()` 忽略 `chip_select`，实测 NAND 正常 `spi0.0`）
- 按键 `user` 的 code 由原厂 `0x100`(BTN_0) 改为 `KEY_WPS_BUTTON`，这样能直接触发 OpenWrt 的 `/etc/rc.button/wps`
- WAN LED 的 function 由 `status` 改为 `wan`，便于配 netdev trigger

## 3. 构建环境两个坑（重要）

1. **本地树没有 `.git`** → `REVISION=unknown` → apk 打包报
   `ERROR: info field 'version' has invalid value`（`package/base-files failed to build`）。
   解决：构建时显式 `REVISION=cb793d3`（已写进 `gwrt-build-wr630ax.sh`）。
2. **用 `rsync --exclude=bin` 复制源码树会漏掉 `package/base-files/files/bin/`**
   （`config_generate`、`board_detect`、`ipcalc.sh`），导致固件启动后**不生成 `/etc/board.json` 和 `/etc/config/network`**（LAN/WAN 全无、hostname `(none)`）。
   已补回；以后复制源码树不要排除 `bin` 目录名。

另外：`ip-full` → `libbpf`/`bridger` 会带出 `NEED_BPF_TOOLCHAIN`，首次构建要编 ~1 小时 LLVM（`tools/llvm-bpf`，3456 个目标）。

## 4. 产物（sha256）

```
59fcba22be601300512b19adfe9c701e42e86a7c1ba8a573fe93bf01a0673b14  ...-initramfs-kernel.bin    40720228 B
c4324eb56e9997d2ced6b936ee65aae18fc609f44ac8fdaad397d5330915715d  ...-squashfs-factory.bin    18481152 B  (md5 0075ce5ed903666f2c77fabfcfbfe73e，已刷入)
18f7a523e167fe636d828d69e1bed638ac4541d409633b200c9a80ece0a567dc  ...-squashfs-sysupgrade.bin  16886038 B
```

## 5. 刷机流程（已验证，保留原厂 BL2/FIP/U-Boot）

1. U-Boot（串口 115200，`MT7981>`）：
   ```
   setenv ipaddr 192.168.1.1; setenv serverip 192.168.1.254; setenv tftpblocksize 1468
   tftpboot 0x4b000000 gwrt-mediatek-filogic-comfast_cf-wr630ax-initramfs-kernel.bin
   bootm 0x4b000000
   ```
   （网线插 WAN 口；PC 用 tftp 服务，1.8 MiB/s，约 25 秒）
2. initramfs 里（**只在内存运行，不动 flash**）：
   ```
   ip link set eth1 up; ip addr add 192.168.1.2/24 dev eth1
   ip route add 192.168.1.254/32 dev eth1     # br-lan 也是 192.168.1.0/24，需要 /32 路由
   nc 192.168.1.254 5566 < /dev/null > /tmp/factory.bin   # PC 端 send.py 推文件
   md5sum /tmp/factory.bin                                # 与 PC 一致
   ubidetach -m 4                                          # 注意：-m 要 MTD 号，不是设备名
   ubiformat -q -y -f /tmp/factory.bin /dev/mtd4
   sync; reboot
   ```
3. 首次启动自动建 `rootfs_data`（355 LEB ≈ 43 MiB），uci-defaults 生成 network/system/wireless。

注意 `wget`(uclient-fetch) 在 initramfs 里会报 `Failed to send request: Operation not permitted`（即使清了 firewall），改用 `nc` 传输即可。

## 6. 刷机后实测（GWRT 261025-01）

- `Machine model: XINGLOO AX3000`；`/proc/mtd` 5 个分区与 DTB 一致
- UBI：kernel 38 LEB / rootfs 96 LEB / rootfs_data 355 LEB，`/overlay` 35.8M 可用
- 网络：`br-lan` = lan1..lan4 + 192.168.1.1/24（dnsmasq 正常发地址，PC 拿到 192.168.1.236），WAN = eth1 (DHCP)
- LuCI `http://192.168.1.1/` → HTTP 200；dropbear 22 端口 banner 正常
- WiFi：phy0 2.4G ch1 / phy1 5G ch40 80MHz，AP `ImmortalWrt`，hostapd ×2，MAC 取自 Factory eeprom
- LED：`red:status / green:status / blue:status / white:wan`，WAN 灯已挂 netdev trigger
- 按键：`gpio_button_hotplug` 已绑定 `gpio-keys`（`/sys/bus/platform/drivers/gpio-keys/`）
- 未测：WAN 口 DHCP 上网（现场没有上游）、sysupgrade 在线升级

## 7. 换 512 MiB 内存后要做什么

1. DTS 改一行并重编：
   `memory@40000000 { reg = <0 0x40000000 0 0x10000000>; }` → `0x20000000`
   然后 `sh gwrt-build-wr630ax.sh 6 261025-02`，用新 `sysupgrade.bin` 在线升级即可（内核/rootfs 都变，但 bootloader 不动）。
2. BL2 **先不动**：换颗粒后直接上电，看 U-Boot 打印的 `DRAM: xxx MB`。
   - 显示 512MB → 只改 DTS 就够了（BL2 的 EMI 参数能自适应容量）。
   - 只认 256MB / DDR 训练失败 → 才需要按新颗粒（DDR3 位宽/rank）重编 `mt7981-bl2` 并刷 BL2 分区（风险最高，需备份 + 编程器兜底）。

## 8. 现场遗留

- 主机 `net.ipv4.ip_unprivileged_port_start` 被改成 0（临时），需要时改回：
  `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=1024`
- 系统自带的 `tftp.socket`（`/var/lib/tftpboot`）被停过，需要时：
  `sudo systemctl start tftp.socket`
- 设备 root 无密码（首次登录请 `passwd`）。

---

# 追加：GWRT 261025-02（主题完善 + 插件补齐 + 端口修正）

## 变更清单

| 项 | 内容 |
|---|---|
| 网口 | 该机实际 4 个口：**1 WAN(eth1) + 3 LAN(lan1/lan2/lan3)**；`02_network` 由 `lan1 lan2 lan3 lan4` 改为 `lan1 lan2 lan3`（DTS 仍保留 4 个 MT7531 port，lan4 不桥接） |
| 主题-型号 | `pixelText(displayModel(board))` → `textContent`，型号用普通字体（不再点阵/LED 风格） |
| 主题-SoC | MTK 分支改为读 `compatible` + `/proc/cpuinfo` 核数 + `cpufreq/cpuinfo_max_freq`，显示如 `MediaTek MT7981B · 2×Cortex-A53 @1.3GHz` |
| 主题-温度 | 先解析 `tempinfo`，缺失时直接读 sysfs（`thermal_zone*/temp`、`ieee80211/phy*/hwmon*/temp1_input`） |
| 插件（编进固件） | `luci-app-oaf` + `luci-i18n-oaf-zh-cn` + `appfilter` + `kmod-oaf`（oaf.ko 6.18 编译通过，`/usr/bin/oafd`）、`luci-app-bandix-plus` + `bandix-plus`、`coremark`（O3 + 多线程）、`luci-app-ttyd` + `ttyd`、`autocore`（提供 `/sbin/tempinfo`）、`curl`、`ca-bundle`、`ca-certificates`、`jsonfilter`、`xz` |
| 移除 | `luci-app-easytier` + i18n（组网/mesh 面板）；openclash、gecoosac 仍不带 |
| 版本 | `VER=261025-02`，脚本新增 `autocore` 起 `/sbin/tempinfo`，主题插件不再被“复检”清掉 |

## 实测（261025-02，sysupgrade 在线升级 35s）

- 升级路径验证：`sysupgrade -n /tmp/su.bin`（20.9MB，md5 6308165999d6a198776729bd9ef33471）→ 自动重启进入新固件，banner `GWRT 261025-02`
- `/sbin/tempinfo` → `CPU: 70.9°C, WiFi: 53.0°C 53.0°C`（hwmon1/2 = mt7915_phy0/1）
- `network.@device[0].ports='lan1' 'lan2' 'lan3'`、`wan=device eth1` ✓
- `oaf` 模块已加载（`lsmod` oaf 122880），`/usr/bin/oafd` 运行；`bandix-plus`、`ttyd` 启动脚本就绪
- LuCI 首页 200，页面内含 `gwrtApplyCpuTemp`（3 处）与 `MT7981B`，已无 `pixelText(displayModel…)`

## 内存识别结论（实测）

- U-Boot **不会**修 `/memory`：把运行时 `/sys/firmware/fdt` 取回反编译，与编译出的 DTB 中 `memory@40000000` 完全一致（`reg = <0 0x40000000 0 0x10000000>`）。
- 所以换内存必须改 DTS（`0x20000000` = 512MiB）；想“自动识别”只能改 U-Boot（在 `ft_board_setup()` 里调 `fdt_fixup_memory()`），需要另编 bootloader，风险高于收益。
- AN7581 也没法照搬：那边是 Airoha 平台，U-Boot 行为不同。

## 待确认 / 没有做的

- `ipk@apk` 里的 4 个 wifiroam 相关包（`.apk` v3）和 `luci-app-ssr-plus`（旧 `.ipk`）是**预编译包**，当前 apk 体系不能直接编进镜像；可做“首次启动离线安装”（参考 gecoosac 的方式），或提供源码重新编译。
- `lan4` 未桥接；如果实际外壳 3 个 LAN 口对应的是 lan1/lan2/lan4，需要把 02_network 改成 `lan1 lan2 lan4`。

---

# 追加：GWRT 261025-03 … 261025-09（真机联调记录）

## 261025-09（最终版，已刷入并验证）

### 首页“监测”全空的根因（自己埋的坑）
我在温度兜底代码里写了注释：
```js
/* ... WiFi -> /sys/class/ieee80211/phy*/hwmon*/temp1_input */
```
注释里的 `*/` 提前结束了块注释，剩下的 `hwmon*/temp1_input` 变成代码 → 运行时
`ReferenceError: hwmon is not defined` → `loadAll().then()` 中断 → 型号/SoC/设备数/接入设备/拓扑/连接数全部不渲染（端口状态图是独立 `refreshPorts()`，所以它是好的）。
用 CDP（`Debugger.setPauseOnExceptions=all`）在真机上直接抓到该异常。
修法：注释改写，不再出现 `*/`。

### 首页数据/显示
- SoC：新增 `/usr/libexec/gwrt-socinfo`（输出 mt7981 / 核数 / max freq），ACL 加 exec 权限；显示 **`MT7981B ×2`**
- 频率：MT7981 没启用 cpufreq，改读 `/sys/kernel/debug/clk/clk_summary` 的 `armpll`（动态），显示 **`1.3 GHz`**
- 温度：`autocore` 的 `/sbin/tempinfo` → `CPU: 68.2°C, WiFi: 53.0°C 53.0°C`（hwmon1/2 = mt7915_phy0/1）
- 型号：普通字体（去掉 pixelText 点阵）
- 真机 CDP 实测：`model=XINGLOO AX3000, soc=MT7981B ×2, freq=1.3 GHz, temp=68.2°C, devs=1, topoNodes=7, ports=6`

### 其它
- **内存自动识别已确认**：512MiB 硬件 + DTS 里 256MiB 时，U-Boot 会把 `/memory` 改成 `0x20000000`（live fdt 实测），内核看到 483MiB。所以换内存**不用改 DTS**；`comfast_cf-wr630ax-512m` 只是保险 profile。
- WiFi 默认值：`GWRT-AX3000` / `GWRT-AX3000-5G`，WPA2 `12345678`（`95_gwrt-wifi-defaults`，只改空/默认值，并修复带引号的脏值）
- EQoS 限速后端：新增 `package/gwrt-eqos`（`/etc/init.d/eqos` + `/etc/config/eqos`，tc htb：WAN 出口按源 IP、br-lan 出口按目的 IP），真机实测 `qdisc htb 1:`/`2:` 生效；主题面板读写 `uci eqos`
- 插件：`oaf`(appfilter+kmod-oaf+luci-app-oaf+i18n)、`bandix-plus`+面板、`coremark`(O3+多线程)、`ttyd`+面板、`autocore`、`luci-app-turboacc`(FW3 卸载 + 全锥 NAT nft-fullcone，拥塞控制 CUBIC)、`gwrt-ssr-plus-luci`(预编译 ssr-plus 面板 + lua-neturl/lyaml/bind-dig/dns2tcp/ipt2socks/microsocks/nping)、wifiroam(预置 APK 首次启动离线安装)
- 工具：`lsblk` `blkid` `nano` `htop`
- 移除：`luci-app-attendedsysupgrade`（含中文包）、`luci-app-easytier`（组网面板）
- 端口：1 WAN(eth1) + 3 LAN(lan1/2/3)

### 真机升级方式（已多次验证）
```sh
# PC 上推文件，设备上：
nc <PC_IP> <port> < /dev/null > /tmp/su.bin
sysupgrade -n /tmp/su.bin      # 约 38 秒，自动重启
```

---

# 追加：GWRT 261025-10（漫游组网 + 默认地址）

- **默认 LAN 网关改为 `192.168.3.3/24`**（`94_gwrt-lan-ip`，只在还是 192.168.1.1 时改；PC 会自动拿到 192.168.3.x 租约）
- **wifiroam（漫游组网）默认值**（`97_gwrt-wifiroam-defaults`）：
  - 角色 `cap`（主 AP）
  - 无线回传 SSID `mesh-gwrt` / 密码 `Abc123abc8888`
  - 主题「网络拓扑图」下方新增一行：`漫游组网 主AP 在线 N 回传 mesh-gwrt`（读 ubus `wifiroam.status`）
- **去掉 wifiroam 拓扑页的“用得爽，打个赏”**：预编译 apk 里的 `topology.js` 在首次启动被替换为打过补丁的版本
  （`/usr/share/gwrt/wifiroam/topology.js`，删掉打赏按钮和弹窗函数；APK 本身未改动）
- 真机实测（192.168.3.3）：`soc=MT7981B ×2, freq=1.3 GHz, temp=67.9°C, devs=1, topoNodes=7, ports=6, meshInfo=漫游组网 主AP 在线 0 回传 mesh-gwrt`

### 换内存/换地址后注意
- 设备地址变了以后，调试脚本里的 IP 要一起改（`192.168.3.3`）。
- 想恢复 192.168.1.1：`uci set network.lan.ipaddr=192.168.1.1/24; uci commit network; /etc/init.d/network restart`

---

# 追加：GWRT 261025-13（SSID 命名 / 5G 160MHz / 拓扑增强 / 去终端图标）

## SSID 命名（沿用 GWRT 项目约定）
`GWRT_<频段>_<MAC后4>`，真机实测（MAC 40:A5:EF:69:25:69 → 2569）：
```
2.4G : GWRT_2.4G_2569   (ch1, HE20)
5G   : GWRT_5.2G_2569   (ch36→ch40, HE160 160MHz, country=CN)
```
- 命名逻辑：`/usr/libexec/gwrt-ssid-name`（首启由 `95_gwrt-wifi-defaults` 调用）
- 主题自带 `/etc/hotplug.d/ieee80211/30-gwrt-ssid-name` + `/lib/functions/gwrt-wireless.sh`，
  已扩展 `gwrt_wifi_role()` 支持 MT7981（`platform/soc/18000000.wifi[+1]`）并按信道区分 5.2G/5.8G
- MAC 取 `eth0`（DSA master = 标签 MAC），避免 br-lan 未就绪时误用 WAN MAC
- 只改默认/空 SSID，用户自定义不动

## 5G HE160
- 硬件支持（VHT/HE 160MHz），已默认 `htmode=HE160`、`channel=36`、`country=CN`
- 实测：`channel 40 (5200 MHz), width: 160 MHz, center1: 5250 MHz`
- 若想回到 80MHz：`uci set wireless.radio1.htmode=HE80`

## 漫游组网（wifiroam）
- 默认角色 `cap`（主 AP），无线回传 `mesh-gwrt` / `Abc123abc8888`
- `roam.ssids` 首启自动预选本机 AP 的 SSID（真机：`GWRT_2.4G_2569 GWRT_5.2G_2569`）
- 无缝漫游前提：**所有 AP 用同一 SSID + 同一密码/加密**（同 ESS）；wifiroam 只负责下发 802.11k/v/r + FT 参数
- 主题首页拓扑下方新增 `漫游组网 主AP 在线 N 回传 mesh-gwrt` 一行；
  有子 AP 后自动在拓扑下方画出「漫游组网节点」（数据来自 `ubus call wifiroam topology`）
- 去掉了 wifiroam 拓扑页的“用得爽，打个赏”（补丁版 topology.js 首启覆盖）

## 概述页终端图标
已删除（不再注入 ttyd 快捷图标），Services 里的 ttyd 页面保留。

## CPU 调频（结论：这版做不了）
- `mediatek-cpufreq` 的 of_match 表里**没有 mt7981**（只有 mt2701/2712/7622/7623/7988a/8167/817x/8183…）
- MT7981 的 topckgen 驱动**没有把 CPU 时钟/分频暴露给 clk 框架**（只有 apmixedsys 的 armpll，固定）
- 该驱动还需要 `cpu-supply`(Vproc) 调压器，MT7981 无 PMIC
- DTS 也没有 OPP 表
→ 要做等于新写一个平台驱动 + 补时钟树，风险高收益低；当前频率显示走 `clk_summary` 的 armpll（动态，1.3 GHz）

---

# 追加：GWRT 261025-14（集成 gwrt-agent）

- `package/gwrt-agent` 原本 `DEPENDS:=@TARGET_qualcommax`（只能 IPQ 编），已放开为 `+jsonfilter +libubox +curl`，
  MT7981(filogic) 现在能装：`/usr/sbin/gwrt-agent`（10.8KB shim，遥测上报 op.gwrt.uk）+ `/etc/config/gwrt-agent`
- **默认不启动**：`98_gwrt-agent-off` 把 `gwrt-agent` / `gwrt-ipv6-auto` / `gwrt-mesh-window` 三个服务都 disable
  （需要联网 + 配对码再手动开）
- 包里缺 `/usr/sbin/gwrt-mesh-window`（init 脚本引用了但文件不存在），所以 mesh-window 服务开了也会失败
- 真机实测：文件已装、`/etc/rc.d` 无 S* 软链、进程未运行；SSID/温度/IP 均正常

## mesh 组网（wifiroam）实现方式（源码结论）
1. **回传**：`apply_backhaul_local()` 生成一个隐藏 wifi-iface（section `wifiroam_backhaul`）
   - 主 AP（role=cap）：`mode=ap` + `hidden=1` + `wds=1`，SSID=`mesh-gwrt`，psk2+ccmp
   - 子 AP（role=sap）：同一 section 但 `mode=sta` + `wds=1`；检测到有线上行时自动 `disabled=1`（有线优先）
2. **漫游**：`apply_roam_local()` 对 `roam.ssids` 里的 SSID 写 802.11k/v/r：
   `ieee80211r=1` + `mobility_domain`(按 SSID 哈希) + `ft_over_ds` + `reassociation_deadline=2000`，
   simple 模式用 `ft_psk_generate_local=1`，explicit 模式下发 r0kh/r1kh；k/v 用 `ieee80211k/rrm_*`、`ieee80211v/bss_transition`
3. **配对/同步**：ubus `wifiroam.discover` / `pair` / `set_role` / `push_roam_config`，主 AP 把漫游参数推给成员
4. **拓扑**：`ubus call wifiroam topology` 返回 nodes（ap/client）+ uplink（wired/wifi/ssid/rssi），
   首页拓扑下方据此画「漫游组网节点」
5. 前提：所有 AP 的用户 SSID + 密码必须一致（同 ESS），回传 SSID 独立（mesh-gwrt）

---

# 追加：GWRT 261025-15 ~ 18（菜单/中文/漫游真生效/mesh 灯/一键配对/360T7）

## 261025-15
- 删掉 `luci-base.json` 里的空 `admin/vpn`（无子项时点开报错）
- wifiroam 菜单/页面中文化：无线漫游 / 网络拓扑 / 客户端 / 漫游设置 / Mesh 配对
  （补丁文件随镜像 `/usr/share/gwrt/wifiroam/*.js` + `menu.json`，首启覆盖）
- ssr-plus 中文：`gwrt-ssr-plus-luci` 同时解包 `luci-i18n-ssr-plus-zh-cn` → `ssr-plus.zh-cn.lmo`
- easytier 恢复（VPN 菜单不再为空）：`kmod-tun + easytier + luci-app-easytier`
- 新增 `gwrt-wifiroam-autopair`（主AP 每 60s 发现并配对未配置 AP）

## 261025-16
- **修复漫游根本没生效的 bug**：`roam.ssids` 之前被写成
  `wifiroam.roam.ssids='GWRT_2.4G_2569 GWRT_5.2G_2569'`（一个带空格的字符串），
  守护进程按单个 SSID 处理 → 一个都匹配不上 → `kvr{r:false,k:false,v:false}`。
  改成 UCI list（`add_list`），并默认 `roam.enabled=1`
- 首次启动立刻调用 `ubus call wifiroam set_roam`（守护进程只在 set_roam 时写
  wireless，光改 uci 不生效）；重启后由 autopair 服务补一次
- 实测：`kvr{r:true,k:true,v:true}`，`wireless.*.ieee80211r=1`，
  `mobility_domain=42e4`（按 SSID 哈希）
- 新增 mesh 状态灯 + 一键配对包 `gwrt-mesh-led`

## 261025-17
- 默认界面语言固定 `luci.main.lang=zh_cn`（93_gwrt-lang），
  否则英文浏览器下 SSR/EasyTier 这类 Lua 页面全是英文
- 实测整站中文：状态/服务/无线漫游/VPN→异地组网/网络监控/Turbo ACC

## 261025-18
- Qihoo 360T7 加入同一份配置（一次编译出 4 个 profile）：
  `qihoo_360t7`（原厂分区）+ `qihoo_360t7-ubi`
- 360T7 的 `DEVICE_PACKAGES` 追加 `kmod-ledtrig-network gwrt-eqos gwrt-device-defaults`
  （否则首启默认值/SSID 命名/wifiroam 安装都不会发生）
- 360T7 默认 LAN `192.168.3.4`（避免和 XINGLOO 的 .3.3 冲突），见 `94_gwrt-lan-ip`

## mesh 指示灯 / 一键配对

`gwrt-mesh-led` 包（`/etc/init.d/gwrt-mesh-led` + `/usr/libexec/gwrt-mesh-led`）：

| 状态 | 灯 |
|---|---|
| 已组网（主AP 有在线成员 / 子AP 已连上主AP） | 常亮 |
| 主AP 发现有未配对设备 | 快闪 |
| 未配置 / 子AP 还没连上主AP | 慢闪 |
| 已配置但当前没有成员 | 灭 |
| 守护进程没跑 | 灭 |

- LED 由 `gwrt.mesh_led.leds` 决定，默认 `auto`：
  有 `blue:status` 用蓝灯（XINGLOO AX3000），否则 `red:status + green:status`（360T7）
- **XINGLOO AX3000 的 DTB 里只有 4 个 GPIO 灯**：red(gpio8) / white:wan(gpio13) /
  green(gpio34) / blue(gpio35)，没有单独的 mesh GPIO；原厂固件把 blue 当 running 灯，
  所以这里默认用 `blue:status` 当 mesh 灯。若面板上 mesh 图标其实是绿灯：
  `uci set gwrt.mesh_led.leds='green:status'; uci commit gwrt; /etc/init.d/gwrt-mesh-led restart`
- **360T7 只有红/绿两个灯**，两灯同时亮 = **琥珀色（黄色/橙色）**，即 mesh 组网成功
- 一键配对：WPS/MESH 键（两个机型都是 `wps` 键）→ `/etc/rc.wps/50-gwrt-mesh`
  → `/usr/libexec/gwrt-mesh-pair`
  - 主AP：立即配对 `discover` 到的所有未配置 AP（配对后自动下发漫游+回传配置）
  - 子AP：已连上主AP 则不动；没连上则回到 `unconfigured`，等主AP 自动配对
  - 也可以命令行直接跑：`/usr/libexec/gwrt-mesh-pair`

## 镜像
- `bin-wr630ax-261025-18/`（sysupgrade sha256 `53933228e88bbb9015a0b388…`）
- `bin-360t7-261025-18/`（`qihoo_360t7` sha256 `9ed54a6d8212340cfac80a83…`；
  `-ubi` sha256 `38373d29b6a2209eb0526d13…`）
- 真机：XINGLOO = `GWRT 261025-18`，192.168.3.3，root 空密码

---

# 追加：GWRT 261025-19 ~ 21（配对失败根因：防火墙；默认角色；mesh 灯定时器）

## 现象
在 192.168.9.9（JDCloud RE-CS-02，cap）点「配对」这台 XINGLOO，
9.9 显示请求已发出，但 XINGLOO 一直停在 unconfigured，界面上也没有任何确认。

## 根因
这台机是「WAN 口」接在 9.9 的 LAN 上（eth1 = 192.168.9.243）。
wifiroam 的发现/配对端口是 **UDP 50607 + TCP 50608**，落在 wan 区域，
被 OpenWrt 防火墙默认 REJECT：

```
PC(192.168.9.171) -> 192.168.9.243:50608   Connection refused
```

所以 9.9 的 join 根本没到这台机 —— **不是缺确认按钮**（目标机本来就不需要确认，
unconfigured 收到带正确 nonce 的 join 会自动接受）。

## 修复
- 新增 `92_gwrt-wifiroam-fw`：放行 tcp/udp `50607 50608`（src=*，LAN/WAN 都行）
- 实测：放行后 9.9 点配对 → 本机 `role=sap, cap_ip=192.168.9.9, peers_online=1`，
  漫游 + 回传配置自动下发，`wifiroam: link to CAP established`

## 默认角色改成「AP / 未配置」
按需求「mesh 默认是 AP」：
- 首启 `wifiroam.core.role=unconfigured`（仍然是普通 AP，SSID 正常广播）
- 插网线 或 靠近主AP（自动连 `mesh-gwrt` 回传）→ 主AP 能发现 → 一键配对
- 要当主路由：无线漫游 → Mesh 配对 → 「设为主AP」
  （或 `ubus call wifiroam set_role '{"role":"cap"}'`）
- `gwrt-wifiroam-autopair` 改成常驻循环：运行中切成 cap 也会开始自动配对

## mesh 状态灯修正
- 闪烁改用内核 `timer` trigger（busybox `sleep` 不支持小数秒，之前刷 `sleep 0.6` 报错）
  顺序必须是：`trigger=timer` → `delay_on/delay_off`（否则属性不存在）
- 「等配对」慢闪 2 分钟后停（与原厂一致），用 tick 计数而不是 `date`（开机 NTP 跳时会瞬间超时）
- 加 pidfile 单实例，避免 uci-defaults 与 rcS 各起一个
- 实测：unconfigured → `[timer] delay_on=700` 慢闪；配对成功 → `state wait -> ok`，蓝灯常亮

## 版本
- 真机：**GWRT 261025-21**，当前已和 192.168.9.9 配对成功（sap）
- `bin-wr630ax-261025-21/`（sysupgrade sha256 `28c080e2a1a8db7a92fb…`）
- `bin-360t7-261025-21/`（`qihoo_360t7` `aa8787fbd56cb78807d4…`；
  `-ubi` `bb4ea339fe07930c8306…`）

---

# 追加：GWRT 261025-24（组网后变真 AP + 插件自动关闭 + OAF/防火墙修复）

## 三态逻辑（实测通过）
| 状态 | 行为 |
|---|---|
| 未组网 | 普通路由：`192.168.3.3` + 本机 DHCP，所有插件正常运行 |
| 已组网（配对成功） | 真 AP：关本机 DHCP、LAN 改 DHCP 客户端（IP 由主路由分配）、有线回传时把 WAN 并进 br-lan（取消 NAT） |
| 掉线/解绑 | 自动恢复普通路由（192.168.3.3 + DHCP + 插件全部恢复） |

- 服务：`gwrt-mesh-apmode`（`/etc/init.d/gwrt-mesh-apmode`），UCI 开关
  `gwrt.mesh_apmode.enabled=0` 可整体关闭
- 判定「真的连着主路由」用 `role=sap && cap_ip && peers_online>0`
  （重启后 cap_ip 还在但没连上，不能算）
- 防抖：连续 2 次（约 20s）确认才切换；断连同样 2 次才回滚
- 兜底：切 AP 后 25s 内拿不到主路由地址 → 自动回滚，不会失联

### AP 模式关闭的服务（省内存/CPU，避免和主路由抢 DHCP）
`dnsmasq odhcpd turboacc eqos shadowsocksr microsocks easytier bandix-plus appfilter ttyd`
（`appfilter` 同时带走 oafd/rule_manager；恢复路由模式时按原启用状态逐个恢复）

## 关键坑：MT7981 运行时把 WAN 并进 br-lan 会挂死网卡
```
mtk_soc_eth 15100000.ethernet eth1: NETDEV WATCHDOG: transmit queue 1 timed out
```
原因：HNAT/PPE + turboacc 流量卸载 hook 在 WAN 口上，运行中改桥接成员直接挂 TX 队列。
**修复顺序（必须严格按这个来）**：
1. 先停 AP 模式用不上的服务（含 turboacc/eqos）
2. 关 HNAT：`echo 0 > /sys/kernel/debug/hnat/hook_toggle`（路径存在才写）
3. 再 `add_list network.@device[0].ports=eth1` + `wan proto=none`
4. `lan proto=dhcp`、`dhcp.lan.ignore=1`、`network reload`、`ifup lan`
- 回滚同理：先关 HNAT → 拆 eth1 → 恢复 lan/wan → 再开 HNAT
- 实测 261025-24：配对→AP 切换 16s 完成，`NETDEV WATCHDOG=0`，ping 主路由正常

## dropbear 在 AP 模式会失联（已修）
dropbear 用 `-l br-lan` 绑定；开机早期 br-lan 还没地址时会放弃，
br-lan 重新配置（改 DHCP）后也不会自动重绑 → 22 端口消失。
修复：切换 AP 后 / 恢复路由后 / 开机已在 AP 模式时，各 `dropbear restart` 一次。

## 防火墙放行改进
原来的单条 `Allow-wifiroam`（src=*、全开）改成两条：
- `Allow-wifiroam-udp`：udp 50607（发现）
- `Allow-wifiroam-tcp`：tcp 50608（配对/同步）
- `family=ipv4`，`src_ip` 限制私网：`192.168.0.0/16` / `10.0.0.0/8` / `172.16.0.0/12`
- 旧规则自动清理，幂等

## OAF 报错根因（已修）
`rule_manager` 是 Lua 脚本，`require "uci"` 需要 `/usr/lib/lua/uci.so`，
但镜像里没装 **libuci-lua**：
```
daemon.err rule_manager: no file '/usr/lib/lua/uci.so'
daemon.err oafd: killall: rule_manager: no process killed   ← 因为 rule_manager 早就崩了
```
- 加入 `libuci-lua` 后实测：`rule_manager` + `oafd` 都在跑，OAF 页面 200 且中文正常
- `killall: rule_manager: no process killed` 是 oafd 停止时的固定噪音，进程在跑时不会再出现

## 两条“看起来像报错”的日志（无害）
- `procd: failed to remove busy cgroup of gwrt-mesh-led::instance1`
  只在**手动重启该服务**时出现一次：procd 停实例时正好有个 `ubus call` 子进程在跑。
  已加 pidfile 单实例；正常运行不会刷。
- `crond: time disparity of 45477 minutes detected`
  开机时钟是构建时间（SOURCE_DATE_EPOCH=2026-09-24），NTP 校时后跳到当前时间，
  busybox crond 提示一次，属正常，不影响功能。

## 版本
- 真机：**GWRT 261025-24**，当前为未组网普通路由（192.168.3.3）
- `bin-wr630ax-261025-24/`（sysupgrade sha256 `8d0873e444650aa90a4e…`）
- `bin-360t7-261025-24/`（`qihoo_360t7` `ea5b789670fb6998a063…`；
  `-ubi` `0f06c23a2a5d27d3106f…`）

---

# 追加：GWRT 261025-25（SSID/密码下发 + gwrt-agent 接入 APP 控制）

## 1. 漫游的最后一环：主AP 下发 SSID + 密码

之前 wifiroam 只下发 k/v/r + 回传配置，**不下发 SSID/PSK**，子AP 广播自己的
`GWRT_*_XXXX`，和主路由不是同一个 ESS → 无缝漫游不成立。

已扩展 wifiroam 守护进程（`/usr/share/wifiroam/wifiroamd.uc`，ucode 源码可改）：

- 主AP：`push_roam_config` 增加 `wifi` 数组
  `[{ssid,key,encryption,band,isolate}]`（排除回传 SSID `wifiroam_bh`）
- 子AP：新增 `apply_wifi_from_cap()`，按频段套用主AP 的 SSID/加密/密码，
  然后再执行原来的 k/v/r 下发（同一次 `wifi reload` 生效）
- 实测（9.9 主AP → XINGLOO 子AP）：
  ```
  2.4G : Rodren            psk2  <主AP 的密码>
  5G   : AX6600_Gaming-jdc psk2  <主AP 的密码>
  ieee80211r=1（两频段）  kvr{r:true,k:true,v:true}
  ```
- 两台机（9.9 和 XINGLOO）都打了补丁；本固件已把补丁版守护进程内置
  （`/usr/share/gwrt/wifiroam/wifiroamd.uc`，首启由 `97_gwrt-wifiroam-defaults` 覆盖）
- 配套修复：`gwrt-ssid-name` / 主题 hotplug 只在「GWRT_* 后缀 = 本机 MAC 后4位」时
  才当默认名改名；主AP 下发的同名 SSID 不会被改回本机后缀

## 2. gwrt-agent 接入 APP 控制

`gwrt-agent` 默认开启（`98_gwrt-agent-defaults`），自注册后 APP 可见在线。
上报 payload 新增 `gwrt_mesh` 字段（原来的 `mesh` 字段是原二进制自带，避免冲突）：

```json
"gwrt_mesh": {
  "available": true,
  "role": "cap|sap|unconfigured",
  "cap_ip": "192.168.9.9",
  "peers_online": 1,
  "apmode": 1,
  "ssids": ["AX6600_Gaming-jdc","Rodren"],
  "discover": ["40:A5:EF:69:25:69"],
  "firmware": "GWRT 261025-25 cb793d3"
}
```

### 云端/APP 可下发的命令（pull → commands[]）

| action | 参数 | 作用 |
|---|---|---|
| `mesh.pair` | `mac`（可选，不填=全部发现的未配置AP） | 配对 |
| `mesh.role` | `role` = `cap` / `sap` / `unconfigured` | 设为主AP/未配置 |
| `mesh.apmode` | `enabled` = 0/1 | 开关「组网后变真AP」 |
| `mesh.ssid_sync` | 无 | 主AP 立即重推一次 SSID/密码+k/v/r；子AP 重启 wifiroam 接收 |
| `system.reboot` | 无 | 重启（仍需 `remote_exec=1`） |
| `system.hostname.set` | `hostname` | 改主机名（仍需 `remote_exec=1`） |

- `mesh.*` 默认允许（`gwrt-agent.main.mesh_control=1`），不碰系统；
  危险命令仍要 `gwrt-agent.main.remote_exec=1`
- 本机调试：`gwrt-agent cmd '{"action":"mesh.pair","command_id":"t1"}'`
- 修复：身份重置后原来调用 `gwrt-agent.bin pair`（旧契约）不会注册，
  改为调用 shim 自己的 `/api/agent/register`，实测 `report ok`

## 3. 版本
- 真机：**GWRT 261025-25**，当前已和 9.9 配对（sap / AP 模式）
- `bin-wr630ax-261025-25/`（sysupgrade sha256 `dd93411865992c69f9ec…`）
- `bin-360t7-261025-25/`（`qihoo_360t7` `3398ebc60220dd36916c…`；
  `-ubi` `035210ff1fc3db3bad06…`）

---

# 追加：GWRT 261025-30 ~ 34（mesh 收尾 + 清理 + 文档化）

## 配对发现的两个硬伤（30 修复）
1. HELLO 只发 br-lan 广播（192.168.3.255），WAN 侧的主AP 收不到
   → 同时发 `255.255.255.255`
2. HELLO 里 `ip` 是 br-lan 的 192.168.3.3，主AP 路由不到
   → 改用默认路由源地址（WAN/回传口 IP），另带 `lan_ip` 字段

实测：9.9 的 `discover` 立刻能看到 `40:A5:EF:69:25:69 / 192.168.9.246`，
配对成功。

## mesh 灯（已验证）
- 未配置：慢闪 2 分钟后熄灭
- 配对成功：`state wait -> ok`，蓝灯 **常亮**（`brightness=1, trigger=none`）
- 若面板 MESH 图标是绿灯：`uci set gwrt.mesh_led.leds='green:status'`

## 回退路由模式恢复原 SSID（关键）
- 首次同步前保存 `/etc/gwrt-wireless-orig`（路由模式无线快照）
- 路由模式下持续刷新（用户改 SSID 也能记住）
- 回滚时恢复原 SSID/密码 + 删回传 STA + `wifiroam.roam.config_ver=0`
- 实测：`off` 后 SSID 从 `Rodren/AX6600_Gaming-jdc` 回到
  `GWRT_2.4G_2569 / GWRT_5.2G_2569`，192.168.3.3 可进

## 强制退出 AP 的语义（30~32 修复）
- `off` / `mesh.apmode enabled=0`：解绑（role=unconfigured）+ 回路由模式
  + 恢复原 SSID + 停止 HELLO 广播（防止被主AP 自动配对回去）
- `on` / `mesh.apmode enabled=1`：恢复广播，等主AP 再配对
- 修复：`enabled=0` 时守护进程不再 `exit`（否则 procd 当崩溃反复重启，
  日志出现 `crash loop`）；改为 sleep 继续循环
- 修复：`set_role unconfigured` 放到 restore 之前，避免 restore 期间 daemon 忙导致失败
- 修复：`apply_wifi_from_cap` 在 `mesh_apmode=0` 时忽略主AP 的 SSID 下发

## 其它
- 移除 `gwrt-mesh-led` / `gwrt-mesh-apmode` 的 `procd_add_reload_trigger`：
  每次 `uci commit wifiroam/gwrt` 都会重启服务，造成
  `procd: failed to remove busy cgroup` 噪音
- 删除主题里遗留的 `index_gwrt.ut.bak-ppe`（会被装进镜像）
- 新增 `AGENTS.md`、`docs/GWRT-MESH.md`、`scripts/gwrt-sync-mesh.sh`
- 清理旧镜像目录与旧 config，只保留最新一版

## 版本
- **最终：GWRT 261025-34**（真机已刷 33，34 为清理后的最终镜像）
- `bin-wr630ax-261025-34/`（sysupgrade sha256 `eb65c7e369489eba…`）
- `bin-360t7-261025-34/`（`qihoo_360t7` `81e8f4aa3e381f58…`；
  `-ubi` `8a6425ade3f085f0…`）

---

# 追加：GWRT 261025-35 ~ 43（纯无线配对 + 回传策略定稿）

## 型号显示
- 去掉 `DEVICE_ALT0`（COMFAST CF-WR630AX），UI/APP 统一 XINGLOO AX3000
- profile 名保留 `comfast_cf-wr630ax`（sysupgrade BOARD 校验需要），镜像文件名不变

## 纯无线配对（已验证）
- 未组网 + 无网线：自动建 **2.4G STA（wds=0，network=wwan）** 连主AP 的 `mesh-gwrt`
- 主AP 2.4G 隐藏 AP（`wifiroam_bh2`，ch1）由守护进程创建
- 子AP 拿到 192.168.9.110 → 主AP discover → 配对成功

## 回传策略（最终）
| 上行 | 模式 |
|---|---|
| 有线 | 真 AP（WAN 并 br-lan、LAN DHCP、关插件、无缝漫游） |
| 无线 | 路由/NAT（STA 2.4G wds=0 在 wwan，LAN 192.168.3.3+DHCP，NAT） |

实测（无网线）：配对后 `ping 8.8.8.8` 通（~190ms），5G 热点保持 ch36/160 给客户端。
- 4-addr WDS：JDCloud 主AP 会 40s 后移除 WDS station → 不可用
- relayd：本树 netifd 缺 `relay` proto handler → 不可用
- 因此无线用 NAT 保证有网；要无缝漫游用有线

## 版本
- **GWRT 261025-43**（真机已刷，无线 NAT 模式验证通过）
- `bin-wr630ax-261025-43/`（sysupgrade `3073f3a0c0e6caad…`）
- `bin-360t7-261025-43/`（`0f4753d8236528a7…` / UBI `738a1446a89203bb…`）

---

# 追加：GWRT 261025-44 ~ 45（有线/无线自动切换 + 多机型 MT7981）

## 261025-44：上行自动切换（已验证）
- apmode 循环跟踪 `eth1 carrier`，变化时 `restore_network_only` + `apply_apmode force`
- 插 WAN：~30s 内切「真 AP」（br-lan 拿主路由 IP、eth1 并入 br-lan、插件关闭）
- 拔 WAN：~40s 内切「无线 NAT」（LAN 192.168.3.3、STA 在 wwan、NAT 出网）
- 实测：插线后 `AP mode ok (wired), br-lan 192.168.9.243`；拔线后
  `router/NAT mode`，`ping 8.8.8.8` 通（~180ms）

## 261025-45：多机型 MT7981 NAND（同配置一次编译）
新增设备 profile（均加 `kmod-ledtrig-network gwrt-eqos gwrt-device-defaults`）：
- `h3c_magic-nx30-pro`（H3C Magic NX30 Pro）
- `xiaomi_mi-router-ax3000t` / `-ubootmod`（小米 AX3000T）
- `cmcc_rax3000m`（CMCC RAX3000M）
- 原有 `comfast_cf-wr630ax(+512m)`、`qihoo_360t7(+ubi)`

产物：`bin-mt7981-261025-45/`（8 个 profile）
```
wr630ax     5f06504dd6a0fe38
360t7       18e71a853e3c46c0 / ubi d586a66982bb96a3
h3c nx30pro 62e4565264d15067
ax3000t     b80e4977e4c3bcca / ubootmod 24f94e403859cf13
rax3000m    a63d9545ce8aff02
```
- 这些机型共用同一套 mesh/插件/默认值；LED 由 `gwrt.mesh_led.leds=auto` 自动识别
  （有 blue:status 用蓝灯，否则 red+green）
- 未上机验证（H3C/小米/CMCC 无硬件）；XINGLOO 已验证
