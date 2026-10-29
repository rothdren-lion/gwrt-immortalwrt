# WORKLOG 2026-10-28 — SS-01 亚瑟 一键 MESH 按键 + wifiroam 无缝漫游入固

## 需求

- SS-01（亚瑟）/ CS-02（雅典娜，含 GWRT2 变体）的 **joy（Joylink 组网键）改成 mesh 键**：
  **短按 = 开 mesh，长按（≥3s）= 关 mesh**
- SS-01 固件加入 wifiroam 无缝漫游全家桶（此前 SS-01 配置里只有 gwrt-agent，mesh 三包全缺）
- 基础：用户最后一次 SS-01 编译 `config.ss01-261021-02`

## 改动清单（构建树 = `/home/godsun/build/immortalwrt-mt7981`，已全部同步回 NAS 树）

| 文件 | 改动 |
|---|---|
| `target/linux/qualcommax/dts/ipq6000-re-ss-01.dts` | `wps` 键节点 → `mesh`：`label="mesh"`、`linux,code=<0x100>`(BTN_0)、GPIO8 不变；reset 不动 |
| `target/linux/qualcommax/dts/ipq6010-re-cs-02.dts` | 同上（GPIO72）；CS-02-GWRT2 include 自动继承 |
| `package/gwrt-mesh-led/files/etc/rc.button/mesh`（新增） | 按键处理器，见下 |
| `package/gwrt-mesh-led/Makefile` | 安装 rc.button/mesh + 描述更新 |
| `gwrt-mk-cs02-config.sh` | 加 `gwrt-device-defaults`/`gwrt-mesh-led`/`gwrt-mesh-apmode`（3b 段，以后编雅典娜自带 mesh） |
| `config.ss01-261028-01`（新增） | 261021-02 + 上述三包 =y + 版本 261028-01 |

### rc.button/mesh 逻辑

- **短按**：`wifiroam` enable+start（等 ubus 就绪）→ 若 `gwrt.mesh_button.last_role=cap` 且当前
  unconfigured 则恢复 cap → 执行 `/usr/libexec/gwrt-mesh-pair`（cap 立即配对 / sap 断链回未配置 /
  unconfigured 等主AP；LED 由 gwrt-mesh-led 自动表达）
- **长按**：守护在线则 `set_backhaul {"enabled":false}`（cap 拆隐藏回传并推给已配对子AP）+
  记 `last_role` + `set_role unconfigured` → 本地删 wireless 的 `wifiroam_bh`/`wifiroam_bh2` 段并
  `wifi reload`（防已关设备经 WDS 偷偷回挂）→ `stop + disable`。apmode 检测 role 变化自动回退普通路由
- 故意**不调** `set_roam {"enabled":false}`：会把保存的漫游 SSID 组清空，导致下次开 mesh 漏配

## 构建

- `make -j6 REVISION=cb793d3 CONFIG_VERSION_DIST=GWRT CONFIG_VERSION_NUMBER=261028-01`
  日志 `.gwrt-logs/build-ss01-261028-0357.log`，03:57 启动 → 04:57 完整收尾（sha256sums 全写）
- 插曲：凌晨 02:48 / 06:47 两次 ps 里看到的 `gwrt-build-cs06.sh` 是 **qualcommbe 树（BE6500/BE10000）
  的另一会话构建，与本树无关**，未发生真实冲突；本树全程独占
- 切换前已存档当时 mediatek 多机型 .config → `config.mt7981-wr630ax-261027-01`

## 验证（全部通过）

- CONTROL `BOARD=jdcloud_re-ss-01`；`DISTRIB_RELEASE='261028-01'`
- **DTB**：`fdtdump` 确认 `label="mesh"` code=0x100，`label="wps"` 为 0，`reset` 完好
- **ath11k_ahb.ko / ath11k.ko 在 `/lib/modules/6.18.55`**（261011-08 历史惨案项 ✓）
- 镜像内：`/etc/rc.button/mesh`（可执行）、`/etc/rc.wps/50-gwrt-mesh`、
  预置 APK ×4（wifiroam/luci-app-wifiroam/i18n/ucode-mod-socket）在 `/usr/share/gwrt/apk/`
- uci-defaults：92(wifiroam防火墙放行 50607/50608)/96(preset-apk)/97(wifiroam defaults)/
  98(mesh-apmode)/99(mesh-led) 全在；caldata 走 hotplug `11-ath11k-caldata`（新机制）
- manifest：板包唯一 `ipq-wifi-jdcloud_re-ss-01`；`gwrt-device-defaults/mesh-led/mesh-apmode/agent` 全进
- `gwrt-verify.sh image`：FAIL=3 均为 **10-17 时代脚本的过时预期**（38/39 wifi 脚本、
  gwrt-ath11k-caldata init 已在现树被 95_gwrt-wifi-defaults + hotplug 机制取代，261021-02 同样会 FAIL）；
  WARN=1（gwrt-agent hardware_id，旧问题）

## 交付

`/mnt/syNAS/Dowloads/Rout/mark/openwrt-rom/jdcloud_re-ss-01/`：

- `gwrt-261028-01-亚瑟ss-01-factory.bin`（119M）
- `gwrt-261028-01-亚瑟ss-01-sysupgrade.bin`（114M）
- `gwrt-261028-01-亚瑟ss-01-initramfs.itb`（114M）
- `gwrt-261028-01-亚瑟ss-01.manifest` + `sha256sums-261028-01`（sha256sum -c 全 OK）

## 遗留 / 待办

1. **360T7/WR630AX 未跟进**：mediatek 配置里 `gwrt-device-defaults=m` 没进固件 → 它们的
   WPS/MESH 键在现役固件上仍是空转。要不要在 `gwrt-mk-wr630ax-config.sh` 补，**等用户拍板**
2. CS-02/CS-02-GWRT2（雅典娜）下次编译：跑 `sh gwrt-mk-cs02-config.sh`（注意它的 SRC 基底
   默认还是 `config.ss01-261018-01`，建议 SRC 指到 config.ss01-261028-01 再派生）
3. CS-07（太乙）未动（DTS 无 joy 键；mesh 三包按需自行加）

---

# 追加（2026-10-28 晚）— 真机串口体检 + 5 个 Bug 修复

刷入 261028-01 后实机联调（串口 /dev/ttyACM0 115200 + SSH），发现并修复：

## Bug 1【致命】apmode 硬编码 eth1 → IPQ6010 永远进不了主路由网段

`gwrt-mesh-apmode` 用 `cat /sys/class/net/eth1/carrier` 判有线上联，这是 MT7981 的 WAN 名。
IPQ6010（SS-01/CS-02，DSA）的 WAN 是 `wan`（`network.wan.device='wan'`），eth1 根本不存在
→ 永远判成「无线回传」→ 走 NAT relay，br-lan 停在 192.168.3.3，**永远进不了 9.0/24**。

修复：新增 `wan_dev_name()`（UCI → 默认路由 → eth1 兜底）+ `wan_carrier()`，
7 处 eth1 硬编码全部替换（含 save_state 的 bridged_eth1 → wandev、restore 的拆桥、守护循环的 carrier 轮询）。

**实测通过**（SS-01 有线接主AP）：
`br-lan=192.168.9.156/24`、`ports='lan1 lan2 lan3 wan'`、`wan proto=none`、`dhcp.lan.ignore=1`（不再抢 DHCP）。

## Bug 2【致命】mesh 按键脚本名错 → 按键完全无反应

procd 按 **驱动映射后的按键名** 派发 `/etc/rc.button/%BUTTON%`
（`package/system/procd/files/hotplug.json`），DTS 的 `label="mesh"` 只影响 sysfs 显示。
`BTN_0` 在 gpio-button-hotplug 的 button_map 里映射名就是 `BTN_0` → 脚本必须叫 `BTN_0`。

修复：`rc.button/mesh` → `rc.button/BTN_0`（Makefile 同步）。

## Bug 3【致命】长按判据用了不存在的 SECONDS

gpio-button-hotplug 只传 `ACTION` / `BUTTON` / `SEEN`（= 按住秒数，`(now-press)/HZ`），
没有 `SECONDS`（那是 shell 自身的变量）→ `${SECONDS:-0}` 恒为 0 → **长按永远当短按**。

修复：改用 `$SEEN`，阈值 3s。实测：
- 短按 `SEEN=0` → `short press(0s): mesh on` + `already paired (cap 192.168.9.9)`
- 长按 `SEEN=5` → `long press(5s): mesh off`，role→unconfigured、服务 disable、回传段删除

## Bug 4【中】回传 SSID 污染漫游组

`wifiroamd.uc` 的 `wifi_ifaces()` 只排除 `wifiroam_bh`、`wifi_export()` 也只排一个，
`wifiroam_bh2`（2.4G 回传 AP）漏网 → `mesh-gwrt` 被当成用户 SSID 进 `roam.ssids`
（FT/802.11r 被套到隐藏 WDS 上，还可能被当用户 SSID 下发给子AP）。

修复：新增 `is_backhaul_sec()`，两个函数都排除 bh/bh2；97 脚本预选 SSID 时也排除。

## Bug 5【中】回退路由模式后 dropbear 消失 → SSH 失联

`restore_routermode` 里 `network reload` 后立刻 `dropbear restart`，
此时 br-lan 还没有地址 → DirectInterface=lan 绑定失败 → 22 端口没了，只能串口救。

修复：两个 restore 分支都改成「等 br-lan 有 inet，再检查/重启 dropbear」的后台补刀。

## Bug 6【小】多台同型号设备无法分辨

所有机器 `hostname` 和 `wifiroam.core.name` 都是 `GWRT`，拓扑里全是 GWRT。

修复：97 脚本首启时按 br-lan MAC 后 4 位自动命名 `GWRT-XXXX`（同时设 hostname）。
注：wifiroam 拓扑本身也显示 MAC，且支持 `ubus call wifiroam set_alias '{"mac":"...","name":"客厅亚瑟"}'`
按 MAC 设中文别名。

## 其它观察（未修）

1. **2.4G 无线回传 `4WAY_HANDSHAKE_TIMEOUT` 反复出现**（子AP STA ↔ 主AP 隐藏回传 AP）：
   子AP 侧 `wds=0`、主AP 侧回传 AP `wds=1`，WDS 不对称 → 四步握手失败。有线回传不受影响。
2. 已知无害告警：`clk-rcg2 update_config WARNING`（ipq6018 上游已知）、`Failed to find NVMEM device`。
3. 测试期间 SS-01 出现 2 次重启（`__do_sys_reboot`，非 panic），原因待确认（是否为手动断电）。
4. **串口适配器在测试后失效**：/dev/ttyACM0 只读到持续 0xFF（线路浮空/板子断电/需重新插拔），
   网络仍正常。

## 热补丁（已应用到实机，未重新出固件）

- SS-01（192.168.9.156 / 现 192.168.9.159 relay）：apmode + rc.button/BTN_0 + wifiroamd.uc
- 主AP 雅典娜（192.168.9.9，老固件 260920-05）：wifiroamd.uc + `core.name=GWRT-8413`
- 主AP 侧 `set_roam` 重推后，SS-01 已与主AP 同 SSID（AX6600_Gaming-jdc / Rodren）+ r/k/v + ft_over_ds
- 源码树（build + NAS）已同步全部修复，**下次出固件即固化**

---

# 追加 2 — 无线回传 WDS 不对称修复 + 261028-02 出固件

## Bug 7【中】无线回传 4WAY_HANDSHAKE_TIMEOUT（WDS 两边不对称）

主AP 的隐藏回传 AP 写死 `wds=1`（hostapd `wds_sta=1`，4-addr），
子AP 的 STA 则在两处被反复改写：`wifiroamd.uc` 写 `wds=1`、`apmode ensure_backhaul` 写 `wds=0`
→ 谁后跑谁生效，两边经常不一致 → 四步握手超时（`Reason: 15=4WAY_HANDSHAKE_TIMEOUT`），
无线回传时断时续。

按既定设计（无线回传 = 3-addr STA + NAT，4-addr 在 JDCloud 上不稳）统一关掉 WDS：
- `wifiroamd.uc apply_backhaul_local`：cap 侧隐藏 AP / sap 侧 STA 全改 `wds=0`
- `gwrt-mesh-apmode ensure_backhaul`：有线分支也改 `wds=0`（STA 本来就是 disabled）
- `97_gwrt-wifiroam-defaults`：加一次性迁移，把历史 `wds=1` 清成 0

**实测**：主AP `set_backhaul` 重应用后 hostapd 配置不再有 `wds_sta`，
日志出现 `phy1-ap1: STA dc:d8:7c:48:7c:cc WPA: pairwise key handshake completed (RSN)`
+ `EAPOL-4WAY-HS-COMPLETED` —— 一次握手成功，不再超时。

## 固件 261028-02（固化上述全部修复）

- 构建：`make -j6 REVISION=cb793d3 CONFIG_VERSION_DIST=GWRT CONFIG_VERSION_NUMBER=261028-02`
  （18:38 → 18:51，只重编 3 个脚本包 + 镜像重打包）
- 拆包验证：apmode 里 `wan_dev_name` ×7、`eth1/carrier` ×0；`/etc/rc.button/BTN_0` 在（无 mesh）；
  97 含补丁拷贝/设备名/wds 迁移/漫游组排除回传；`/usr/share/gwrt/wifiroam/wifiroamd.uc` 含
  `is_backhaul_sec` 且无 `wds=1`
- `gwrt-verify.sh`：ath11k_ahb.ko OK、BOARD OK；3 个 FAIL 仍是 10-17 老脚本的过时预期
- 交付：`openwrt-rom/jdcloud_re-ss-01/gwrt-261028-02-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}`
  + `sha256sums-261028-02`（sha256sum -c 全 OK）

## 待办

- 主AP 雅典娜（CS-02-GWRT2，现跑 260920-05）尚未出新固件，目前靠热补丁；
  需要时：`SRC=config.ss01-261028-02 PROFILE=DEVICE_jdcloud_re-cs-02-gwrt2 VER=261028-02 sh gwrt-mk-cs02-config.sh` 后编译
- 串口适配器仍需物理复查（持续 0xFF）

---

# 追加 3 — 第二轮代码审查再挖 5 个 bug + 261028-03

## Bug 8【会咬人】2.4G 无线回传不追主AP 信道

AP+STA 共用同一射频，本机 2.4G 热点必须和主AP 的 2.4G 回传 AP 同信道，否则 STA 起不来。
原代码只给 5G 分支做了信道对齐（`if band != "2g"`），2.4G 完全没管；主AP 把 2.4G 从 ch1
改成 6/11 时无线回传直接失效（默认还就是走 2.4G，等于埋着随时炸）。

修复：主AP 侧 `apply_backhaul_local` 额外记录 `channel2g`（`radio_running_channel(r2)`），
随 `current_backhaul_cfg()` 自动下发给子AP；子AP 侧 `<14` 时把本机 2.4G 射频信道对齐。
推送里没有 `channel2g` 时（老主AP）不覆盖本机已有值。

## Bug 9【边缘】apply_wifi_from_cap 只排除 wifiroam_bh，漏了 bh2

子AP 若曾是主AP、残留 `wifiroam_bh2`，SSID 同步会把隐藏回传 AP 改成用户 SSID
（等于把隐藏回传变成可见热点）。改用 `is_backhaul_sec()` 同时排除 bh/bh2。

## Bug 10【会咬人】预置 APK 每次开机重装、永不清理

`96_gwrt-preset-apk` 用 `grep -qiE 'ERROR|failed' 日志` 判成功。apk 对已装包会打
"already installed"/world 之类字眼 → 永远判失败 → **每次开机重跑一遍 apk add**，
`/usr/share/gwrt/apk/` 的 ~500KB 预置包也永远不删除。
（实机证据：APK 都装上了，但 `/etc/gwrt/wifiroam-apk.done` 不存在、预置包还在。）

修复：改成用 `apk info wifiroam && apk info luci-app-wifiroam` 核对数据库，成功才写 mark + 清理。

## Bug 11【小】mesh 灯在子AP 掉线后仍常亮

`gwrt-mesh-led` 的 sap 分支只要有 `cap_ip` 就显示常亮；`cap_ip` 是持久化的，
重启/断链后仍然残留 → 灯假常亮。

修复：新增 `sta_link_up()`，要求 `peers_online>0` 或 `*sta*` 接口 operstate=up 才算已组网。

## Bug 12【会咬人】回传频段两处代码互相覆盖

`wifiroamd` 子AP 默认「先试 5G，失败降级 2G」；`gwrt-mesh-apmode` 的 `ensure_backhaul`
默认强制 2.4G。两边抢写同一段 `wireless.wifiroam_bh` → 每 10s 可能来回改，
STA 反复重配。按 AGENTS.md 结论（无线默认 2.4G 最稳）统一：`wifiroamd` 子AP 默认也 2G，
只有显式 `backhaul.band=5g` 才用 5G。

## 已核查但不是 bug

- `bridge` 命令在镜像里不存在，但 `parse_fdb()` 会退回 `brctl showmacs`，
  且 `bridge_port_names()` 用 `brctl showstp` 的 `name (N)` 格式能正确建映射
  （实机 `phy1-ap1 (8)` → 判为无线 ✓）
- `97` 的漫游 SSID 用 `add_list` 逐条加入（注释里已踩过写成 "a b" 单条字符串的坑）

## 固件 261028-03

- 21:57 → 21:11（本轮只重编 3 个脚本包 + 镜像重打包）
- 拆包验证：`channel2g`×9、`is_backhaul_sec`×4、`(band == "5g") ? "5g" : "2g"`×1、
  `apk info wifiroam`×1、`sta_link_up`×2
- 交付 `openwrt-rom/jdcloud_re-ss-01/gwrt-261028-03-亚瑟ss-01-*` + `sha256sums-261028-03`（全 OK）

---

# 追加 4（2026-10-29 凌晨，真机 512M SS-01 全流程）— 3 机型出固件

## 关键事实订正

- **真 SS-01（亚瑟）内存只有 512 MiB（可用 413 MiB）**，不是 1GB。
  ath11k 的固件/DMA 内存（Slab ~134MB）不可回收，空闲常态只有 ~100MB。
  → 全插件固件在这台机上余量极小，**绝不能把 100MB+ 镜像写进 /tmp（tmpfs 吃 RAM）**，
  否则直接 OOM，dropbear/hostapd 被杀（本次踩过）。
- **真 SS-01 是 eMMC**（7.2 GiB，GPT A/B 布局）：`0:HLOS`(kernel) / `rootfs`(1GiB) /
  `rootfs_1`(62.9MB，装不下我们 107MB 的 rootfs，所以只能刷主槽) / `0:ART`(p15, caldata)。
  A/B 槽由 `0:BOOTCONFIG` 第 148 字节决定（实测 0x00 → 主槽）。

## Bug 17【致命】ath11k 校准数据时序：WiFi 永远起不来

现象：刷机后首次启动没有 WiFi，`ls /sys/class/ieee80211/` 为空，
dmesg：`qmi failed to load CAL data file:cal-ahb-c000000.wifi.bin` + `-110`。

链式原因：
1. `procd` 写固件 `loading` 报 `Bad file descriptor` → `11-ath11k-caldata` hotplug 没及时触发
2. 实测 caldata 直到开机 **207 秒**才落盘，而 ath11k 在 **23 秒**就 probe 了
3. 校准数据必须**在 probe 之前**存在 → 错过就永久失败（不会自动重试成功）
4. 更糟：首启"没有 phy"时生成的 `/etc/config/wireless` 里连 `radio0/radio1` 都没有，
   以后重启也不会补 → 即使 phy 好了也没有 SSID

修复（`target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata`，START=18）：
- caldata 缺失 → 从 GPT `0:ART`(p15) 偏移 0x1000 长 0x10000 dd 出来（与 hotplug 规则一致，
  真机验证 65536 字节与可用 caldata 完全一致）→ **自动重启一次**（重启后 probe 就能拿到）
- 防死循环：`/etc/gwrt-caldata-rebooted` 标记，补过一次仍失败就不再重启
- 正常启动（caldata 已在）→ 后台等 phy 就绪，若 wireless 无 radio 段就 `wifi config`
  重新生成 + 套 `gwrt-ssid-name` + 默认 psk2/12345678 + `wifi reload`

> 踩坑记录：第一版把"已存在"也当成"刚提取"，导致 **无限重启**（`procd: - reboot -` 每一轮）。
> 已修正为显式分支 + 防循环标记。

## 刷机方式与教训

- `sysupgrade` 在这台机 **刷完不会重启**（RAM 不够整镜像进 tmpfs；手动复制会 OOM）。
- 采用「流式写分区」：`wget -O - <url> | tar -xOf - '<pkg>/kernel' | dd of=/dev/mmcblk0p16`，
  rootfs 同理写 `/dev/mmcblk0p18`（不占 RAM）。**已验证可成功刷入并启动**。
- ⚠️ 但这会**覆盖正在运行的 rootfs**：刷写完成后必须立刻重启，否则运行中的系统
  会大面积 `SQUASHFS error`（本次就是把 busybox 读没了，`reboot` 都执行不了，
  sysrq 也没开，只能等断电）。
  **下次脚本末尾必须加 `echo b > /proc/sysrq-trigger` 兜底**，并保证刷完立即重启。

## 交付（261029-02，三个机型，全部 sha256sum -c 通过）

| 机型 | 目录 | 产物 |
|---|---|---|
| 亚瑟 SS-01 | `openwrt-rom/jdcloud_re-ss-01/` | `gwrt-261029-02-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}` |
| 雅典娜 CS-02-GWRT2 | `openwrt-rom/jdcloud_re-cs-02-gwrt2/` | `gwrt-261029-02-雅典娜cs-02-lan1-is-wan-{factory,sysupgrade}` + initramfs/manifest |
| 太乙er1 CS-07 | `openwrt-rom/jdcloud_re-cs-07/` | `gwrt-261029-02-太乙er1-cs-07-{factory,sysupgrade}` + initramfs/manifest |

配置存档：`config.ss01-261029-02` / `config.cs02-gwrt2-261029-02` / `config.cs07-261029-02`

### CS-02 派生陷阱（再次复现）

`gwrt-mk-cs02-config.sh` 用 sed 切换设备 choice 时，源配置里 SS-01 是 `=y`（不是
`is not set`），脚本只处理后者 → `defconfig` 又收敛回 SS-01。
**手工补**：把 `CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y` 改成
`is not set`、cs-02-gwrt2 设 `=y`、`CONFIG_TARGET_PROFILE` 改成 gwrt2，再 defconfig 校验。
CS-07 的脚本没这个问题（它处理了）。

## 设备当前状态（2026-10-29 03:30）

真 SS-01 因上面的"覆盖运行中 rootfs"卡在 SQUASHFS error 循环，**需要断电重启**。
新 rootfs（261029-02）已完整写入，断电后应直接启动新固件——
若 overlay 保住则 caldata 还在、WiFi 直接起来；若 overlay 被重建则走"提取+自动重启一次"。

---

# 追加 5（2026-10-30）— 远程 SS-01 升级 + 「WiFi 用一会儿就没了」真因

## 现场：192.168.8.8（远程 SS-01，1GB 内存版，PPPoE + easytier 访问）

- 原固件：`GWRT 260819-60`（内核 6.18.44）
- 症状：**用一段时间 5G 就没了**，只剩 2.4G
- 升级方式：`sysupgrade`（**不带 `-n`** → 保配置），升级前做了双备份：
  - `sysupgrade -b` 官方备份 4MB
  - 原始 `/etc/config` 打包 11KB
- 结果：`261029-02` / 内核 6.18.55，**SSID（AX6600_Gaming、Rodren）/ 加密 / LAN 192.168.8.8 全部原样**

> 注意：这台是经上游路由 + easytier 才能访问，链路抖动时"失联"是正常的，
> 不要误判成升级失败（本次升级中途正好赶上抖动，等 10 分钟自己回来了）。

## Bug 18【致命，产品级】HE160 + ch36 → DFS CAC 失败 → hostapd 禁用整个 5G

日志铁证：

```
hostapd: phy0-ap0: interface state HT_SCAN->DFS
hostapd: DFS-CAC-START freq=5180 chan=36 sec_chan=1, width=2, seg0=50 cac_time=60s
hostapd: DFS start_dfs_cac() failed, -1
hostapd: phy0-ap0: interface state DFS->DISABLED
hostapd: phy0-ap0: AP-DISABLED
hostapd: hostapd_free_hapd_data: Interface phy0-ap0 wasn't started   ← 用户看到的那条
```

原因：`ch36 + 160MHz` 会跨到 ch52-64（DFS 雷达信道），必须先做 60s CAC；
而 **ath11k 的 `start_dfs_cac()` 直接返回 -1** → hostapd 放弃 → 整个 5G 接口 DISABLED。
每次 5G 重启（开机 / 雷达事件 / `wifi reload`）都会重来一遍 ⇒ 表现就是「WiFi 用一阵就没了」。

**产品规则（用户确认）**：
- **双频机型**：5G 走 **5.8G 高频（ch149+）**，**不支持 160MHz**
- **三频机型**：才允许 5.2G 低频 + 160MHz

修复（`gwrt-caldata` 的 `wifi_bootstrap`，每次开机幂等执行）：
1. 统计 5G 射频个数；`ndev5 <= 1`（双频）时：
   - 5G 信道 `< 149` → 强制改 `149`（5.8G）
   - `htmode` 含 `160` → 强制 `HE80`
2. 三频机型不动

实测（8.8）：改 `ch149/HE80` 后立即 `AP-ENABLED`，日志 `dfs=0`，5 分钟无复现。

## Bug 19【运维】gwrt-agent 失败日志是空的

```
user.notice gwrt-agent: report FAILED:
user.notice gwrt-agent: pull FAILED:
```

`api()` 用 `curl -s ... 2>/dev/null`，失败时返回空串，日志里什么都看不到，没法判断是
DNS / 连不上 / 超时 / TLS / HTTP 4xx。

修复：`api()` 改为
- `-w '\n__HTTP__%{http_code}'` 拿 HTTP 码
- 捕获 curl 退出码并映射成人话（6=dns 7=connect 28=timeout 35/60=tls 52=empty-reply 56=recv）
- 非 2xx 也返回 `__API_FAIL__ http <code>: <响应片段>`
- 失败返回 `__API_FAIL__ <原因> (endpoint=...)`

⇒ `report/pull FAILED:` 后面会带上真实原因。

> 8.8 上那两次失败（00:42-00:54）经查是链路抖动，之后 01:04 起连续 `report ok`，
> 说明 agent 本身没坏，是**没有错误细节**导致无法判断——已用上面的改动解决。

## 261029-03（含上述两条规则）

已出：SS-01（亚瑟）`gwrt-261029-03-亚瑟ss-01-*`，交付 `openwrt-rom/jdcloud_re-ss-01/`。
CS-02-GWRT2 / CS-07 用同一份 base-files 规则，按需重编。
