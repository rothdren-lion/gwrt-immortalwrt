# WORKLOG 2026-10-26 — 京东云鲁班 RE-CP-02 (MT7621) 最低 mesh 集成 + GitHub Actions 云端编译

记录日期：2026-10-26　|　操作人：AI agent（pi）　|　项目：GWRT ImmortalWrt 源码树（NAS mark/immortalwrt）

## 1. 任务背景

- 用户要求编译 **jdc mt7621**（= 京东云鲁班 RE-CP-02，NAS 目录 `JDC-京东云/JDC-re-cp-02-鲁班` 对应）
  固件，最低要求：mesh 配对/主路由↔AP 状态机 + gwrt-agent。
- 初期计划本地编译，但 `/home`（系统盘）仅剩 **40G**，全量 ImmortalWrt 构建树需 ~25G
  （参考：mt7981 树 26G、an7581 树 39G），用户决定**暂缓本地编译、改走 GitHub Actions 云端编译**。
- 附加需求：**ipq5018 机型也加上**（待确认具体机型后移植，见 §5）。

## 2. 调查结论（关键事实）

| 项 | 结论 |
|---|---|
| 设备 profile | `target/linux/ramips/image/mt7621.mk` 中 `jdcloud_re-cp-02`（MT7621A+MT7915，IMAGE_SIZE 16000k）；另有 `jdcloud_re-sp-01b`（亚瑟 B 版，MT7621） |
| mesh 逻辑分布 | `wifiroamd.uc` 配对守护 + autopair + SSID/LAN/fw 默认值都在 `gwrt-device-defaults`；AP 状态机在 `gwrt-mesh-apmode`（PKGARCH:=all 纯脚本，服务缺失有 `[ -x ]` 保护）；APP 命令在 `gwrt-agent` shell shim（405 行，mesh.pair/role/apmode/ssid_sync 全 shell 实现） |
| 跨平台问题 | `gwrt-agent.bin` 是 aarch64 musl ELF；`gwrt-device-defaults/files/apk/*.apk`（含 aarch64 `ucode-mod-socket`）也是 aarch64。MT7621=mipsel_24kc 都不可用 |
| agent 无 .bin 可跑 | shim `payload()` 已有降级：`[ -x "$ORIG" ] || echo "{}"`，且带 ubus 卡死超时保护（2026-10-22 Nokia 2402b 验证过），遥测退回最小合法载荷，mesh.* 命令不受影响 |
| ucode 模块依赖 | `wifiroamd.uc` import `socket` + `digest`；`ucode-mod-digest` 默认已选，**`ucode-mod-socket` 必须显式编入**（aarch64 上原是预置 apk 装的） |
| 磁盘 | `/home` 剩 40G；本地编译树 + 缓存最低估计 15~25G，可行但挤（已搁置） |
| ipq5018 | 本源码树有 `qualcommax/ipq50xx` 子目标（glinet_gl-b3000、linksys、netgear 等），**无 jdcloud 设备**；本地所有树（mt7981/an7581/immortalwrt/nss-gwrt2）均无现成移植；NAS 有亚瑟原厂镜像 `JDC-京东云/京东云AX1800-AX6600JDC02-1.5.40.r2181/...signed.img` 可供移植抽 DTB/board 数据 |
| GitHub | gh CLI 已登录 `rothdren-lion`（keyring token，repo 权限） |

## 3. 已完成修改（文件清单与回滚）

### 源码树（NAS mark/immortalwrt，影响后续 mt7981 构建 → 已做架构条件，aarch64 行为不变）

| 文件 | 修改 | 回滚 |
|---|---|---|
| `package/gwrt-agent/Makefile` | `PKGARCH` aarch64_cortex-a53→**all**；`.bin` 安装包进 `ifneq ($(findstring aarch64,$(ARCH)),)` 条件 | 改回 `PKGARCH:=aarch64_cortex-a53` + 去掉 ifneq 包裹 |
| `package/gwrt-device-defaults/Makefile` | `96_gwrt-preset-apk` 与 `files/apk/*.apk` 安装包进同样的 aarch64 条件 | 去掉两处 ifneq/endif 包裹 |
| `gwrt-mk-cp02-config.sh` | 新增：cp02 最低配置生成器（target/device/VERSION_NUMBER/gwrt 三件套/ucode-mod-socket/uhttpd，无 luci） | 删除文件 |
| `gwrt-build-cp02.sh` | 新增：本地编译脚本（仿 wr630ax，显式传 REVISION） | 删除文件 |

> 注意：PKGARCH→all 后，mt7981 侧 gwrt-agent 的 apk 架构标签变为 "all"，包内容在 aarch64 上不变（.bin 照装），
> `CONFIG_PACKAGE_gwrt-agent=y` 选择不受影响。已验证两 Makefile ifneq/endif 配平。

### GitHub 仓库（新建私有仓）

- 仓库：<https://github.com/rothdren-lion/gwrt-immortalwrt>（私有；公开可获无限 Actions 分钟数，需用户自行改）
- 本地导出/推送副本：`/home/godsun/build/gwrt-github-export`（rsync 源码树，排除
  build_dir/staging_dir/dl/tmp/bin*/backup-*/.gwrt-logs/.git/.config/config.*/feeds/logs，**157M**）
- 首个提交 `61d15f9`，含上述 4 文件 + `.github/workflows/gwrt-build.yml`
- 工作流：手动触发（workflow_dispatch），输入 device=cp02 / version / release；
  流程 = 清磁盘(+6G swap) → 装依赖 → 缓存 dl → feeds → `OUT=.config sh gwrt-mk-cp02-config.sh`
  → defconfig → `make -j$(nproc)`（失败自动 `-j1 V=s`）→ 收集产物 → artifact(30天) → 可选 Release
- 回滚：`gh repo delete rothdren-lion/gwrt-immortalwrt` + 删本地导出目录

## 4. MT7621 本地编译步骤（备用，等换大硬盘后可用）

```sh
B=/home/godsun/build/immortalwrt-mt7621
rsync -a --exclude .git --exclude tmp --exclude bin --exclude 'bin-*' --exclude dl \
  --exclude 'config.*' --exclude .config --exclude .gwrt-logs \
  /mnt/syNAS/Dowloads/Rout/mark/immortalwrt/ $B/
ln -s ../immortalwrt-mt7981/dl $B/dl          # 复用下载缓存
cd $B && ./scripts/feeds update -a && ./scripts/feeds install -a
VER=261026-01 sh gwrt-mk-cp02-config.sh && cp config.cp02-$VER .config
make defconfig   # 复核: CONFIG_TARGET_PROFILE=DEVICE_jdcloud_re-cp-02 且 gwrt 三件套=y
sh gwrt-build-cp02.sh 6 $VER    # -j6 铁律，禁 -j8
```

预计首次编译 1~2 小时（mipsel_24kc 工具链全新）。产物按 gwrt-firmware-delivery 技能命名归档。

## 5. 待办 / 未完成

- [ ] **ipq5018 机型确认**（亚瑟 AX1800 Pro？羿哪吒？）→ 确认后从原厂镜像抽 DTB/board-2.bin，
      按 qualcommax/ipq50xx 现有设备（如 gl-b3000）模板移植 DTS + ipq-wifi + base-files board.d，
      再加 `gwrt-mk-<机型>-config.sh` 与 workflow preset
- [ ] GitHub Actions 首跑验证（cp02），检查 config grep 输出与产物
- [ ] 产物归档：下载 artifact → `bin-cp02-<ver>/`（源码树根，仿 bin-wr630ax 惯例）+ sha256sums；
      `openwrt-rom` 交付盘当前未挂载（/run/media/godsun/f092...）
- [ ] 实机验证清单（AGENTS.md §5：未组网/配对/强制退出）
- [ ] 固件内确认：mipsel 镜像里 `usr/sbin/gwrt-agent.bin` **不存在**、`usr/lib/ucode/socket.so` 存在

## 6. 环境备注

- NAS：`/mnt/syNAS/Dowloads/Rout`（注意乱码树 `JDC-äº¬ä¸œäº‘/`，勿动；中文路径用 find 定位）
- gh 账号：rothdren-lion；git 推送用 https + keyring token（`gh auth setup-git` 已跑）
- 编译并行度：本地 **-j6** 禁 -j8（gwrt-firmware-delivery 技能）；CI 用 `-j$(nproc)`（runner 4 核）
- 本地构建树无 .git，编译必须显式传 `REVISION`（脚本已处理，fallback cb793d3）

---

# 追加 2026-10-28 — GitHub Actions 首跑成功 + pzl8 预设

## 云端编译踩坑记录（cp02）

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | 推送被拒 workflow scope | token 只有 repo | `gh auth refresh -s workflow`（设备码授权） |
| 2 | 私有仓 Actions 被计费锁死 | 账号付款失败/限额 | 用户选择转**公开仓**（内容已含 mesh 文档，知悉） |
| 3 | `./scripts/feeds: No such file` | rsync `--exclude feeds` 未锚定，误删 `scripts/feeds`、`package/base-files/files/bin/*` 等 245 个文件 | 改为 `--exclude /feeds` 锚定根目录重新同步 |
| 4 | 内核补丁 102-01-pwm-mediatek 打不上 | 树里残留上游已删除的陈旧补丁（内核已到 6.18.55） | 删除该补丁，其余 46 个 ramips 补丁与上游对齐 |
| 5 | artifact 缺 easytier 核心 apk | collect 只收 bin/targets | 增加 `bin/packages/**/easytier*.apk` 与 buildinfo 收集 |

## 成功构建

- **run 40560326049**：cp02 `gwrt-ramips-mt7621-jdcloud_re-cp-02` **261027-01**（rev 13c2b66），1h18m ✅
- 拆包验证 7/7 通过：DISTRIB_RELEASE=261027-01；agent shim 在 / **aarch64 .bin 不在**（mipsel 降级生效）；
  ucode socket.so ✓ / wifiroamd.uc ✓ / mesh.html ✓ / easytier 核心 =m 不占 flash ✓ / 预置 aarch64 apk 不在 ✓
- 归档：`bin-cp02-261027-01/`（sysupgrade + initramfs + manifest + config + sha256sums 全部 OK）
- 注意：cp02 的 easytier 核心 apk 在 261027-01 artifact 里**未收集**，261027-02 起补齐（bin/packages）

## 新增

- `gwrt-mk-pzl8-config.sh`：CMCC PZ-L8（用户叫 PL08）IPQ5018+QCN6122 预设；
  树内设备定义缺 WiFi 固件包 → 预设显式选 `ath11k-firmware-ipq5018-qcn6122`
  （该包自带 IPQ5018 通用 board-2）；128M NAND，easytier 核心直接进镜像
- 工作流 preset：cp02 / pzl8；工具链缓存（staging_dir/toolchain-*，跨 run 省 ~30min）
- 定位确认：**这批固件都是给 GWRT mesh 当子 AP 用**（未组网→APP 配对→真 AP 模式）

## 待办更新

- [ ] cp02 261027-02（补收 easytier apk）+ pzl8 261028-01 首编（进行中）
- [ ] pzl8 首编后拆包验证 WiFi 固件/board-2 是否齐全（设备定义未带 packages，若有问题需补 DEVICE_PACKAGES）
- [ ] 羿哪吒 jdcloud_ax3000 移植（NAS 有 Nwrt factory.bin 可抽 DTB/board；或找 Nwrt 源码抄 DTS）
- [ ] git 全局有 ghproxy 重写，本仓推送需用 `https://rothdren-lion@github.com/...` 直连 URL

---

# 追加 2026-10-28 — cp02-02/pzl8-01 双成功 + PZ-L8 WiFi 使能 + 分区说明

## 构建结果（全部成功）

| run | 内容 | 结果 |
|---|---|---|
| 40602199533 | cp02 **261027-02**（补收 easytier mipsel apk 9.0M） | ✅ 1h03m |
| 40602205139 | pzl8 **261027-01** 首编（factory.ubi 32M + sysupgrade 31M + easytier aarch64 apk 15M） | ✅ 1h10m |
| 40698610224 | pzl8 **261027-02**（WiFi 使能版，见下） | 🏃 进行中 |

- 归档：`bin-cp02-261027-02/`（sysupgrade+initramfs+manifest+config+easytier mipsel apk，sha256 全 OK）；
  `bin-pzl8-261027-01/`（factory.ubi+sysupgrade+initramfs.itb+manifest+config+easytier aarch64 apk，sha256 全 OK）
- pzl8 manifest 确认：ath11k-firmware-ipq5018-qcn6122 / easytier / gwrt 三件套 / ucode-mod-socket / kmod-ath11k 俱全
- 注意：另一会话同期在树上活跃（cs06/cs08 qualcommbe、ss01 mesh 按键、mac80211/ath 补丁等），
  本次只提交了 pzl8-wifi 相关 4 项，其余 290+ 文件未动

## PZ-L8 WiFi 使能（上游默认禁用，本次打开）

- 现状：上游 `ipq5018-pz-l8.dts` 把 `q6v5_wcss`/`wifi`/`wifi1` 全部 `status="disabled"`；
  对比：有 board 文件的 gl-b3000/mr3000d-ci/elecom 全是 `okay`。
  qca-wireless 快照（2026-09-10）里**没有** `cmcc_pz-l8` board，只有 mr3000d-ci/rm2-6。
- 根因链：缺 board → 上游禁用 WiFi → 只剩有线路由，**当 mesh 子AP 无意义**。
- 修复（4 项，已推仓，pzl8 261027-02 包含）：
  1. `package/firmware/pz-l8-wifi-board/`（新包）：从 `PZL8-AX3000-openwrt-v1.6.bin`
     的 wifi_fw 卷（squashfs，`hsqs` 魔数）抽出两份原厂 BDF（WLAN.HK.2.5，各 128K，
     md5 已核对），分别装为 `ath11k/IPQ5018/hw1.0/board.bin`（2.4G）和
     `ath11k/QCN6122/hw1.0/board.bin`（5G）fallback。
     依据：DD-WRT 的 board-2.bin 只含 `bus=ahb,qmi-board-id=` 条目（4 条，无 variant），
     对不上 PZ-L8 时驱动自动回落到 board.bin。
  2. DTS：三处 `disabled`→`okay`，OOM 警告改为 GWRT mesh 说明。
  3. `11-ath11k-caldata`：`cmcc,pz-l8` 并入 `cmcc,mr3000d-ci` 分支
     （同为 CMCC 的 art 布局：0x1000/0x26800，MAC 取 art+12/+18）。
  4. `gwrt-mk-pzl8-config.sh`：选中新包。
- 待实机验证（261027-02 刷机后）：`dmesg | grep ath11k`（确认用了 board.bin 还是 qmi-board-id 条目）、
  `iw list`（2.4G+5G 双频）、`cat /proc/mtd`（见下）、内存水位（上游 OOM 警告是否应验）。

## PZ-L8（128M NAND）重分区说明

- 分区表来源：DTS 用 `qcom,smem-part`，即**分区表由 SBL（bootloader）经 SMEM 传给内核**，
  DTS 里只声明了 `0:art`。改分区 = 动 bootloader 区，**必须有串口 + 全盘 nanddump 备份**；
  NAS 里没有 PZ-L8 的 uboot 备份（只有羿哪吒的 jdcax3000uboot.bin/gpt），先别碰 SBL。
- 好消息：UBI 内部没有浪费 —— UbiFit + autoresize，overlay 自动吃掉 `ubi` 分区全部剩余 LEB。
  当前 IMAGE_SIZE=59392k（58M）只是**镜像体积上限**，factory.ubi 实际 32M。
- 原厂 Nwrt v1.6 的 UBI 实测（`ubireader_display_info`）：PEB 128K/LEB 126976，共 265 块 ≈ 34.7M
  （kernel 30 + wifi_fw 29 + bt_fw 1 + ubi_rootfs 203 + rootfs_data 0）。
  注意这是 Nwrt 自己的 ubi 像，不是全盘 128M 地图。
- 三档方案（按风险排序）：
  - A（推荐先做，零风险）：上机跑 `cat /proc/mtd; ubinfo -a; df -h`，看 smem 里 `ubi` 分区到底多大；
    若有 80~90M，直接把 IMAGE_SIZE 放大到贴着分区上限重编，多出 20M+ overlay。
    我们的 factory.ubi 只有 kernel+rootfs 卷，不碰 wifi_fw/bt_fw（Nwrt 遗留卷，sysupgrade 保留）。
  - B（不动 SBL，用闲置分区）：若 `0:rootfs_data` 或其它数据分区有空闲，
    首启脚本挂载为 `/opt` 给 easytier/docker 用，系统区不动。
  - C（重做 bootloader 分区表，高风险）：改 MIBIB/SMEM 分区 → 需串口救砖 + 原厂全盘备份；
    且 SBL 签名/校验链（CMCC 定制机常见）可能拒绝改过的分区表。**等 A 的数据回来再定**。
- 要推进 A：把 PZ-L8 上 `cat /proc/mtd` 和 `ubinfo -a` 的输出贴给我（跑 Nwrt v1.6 或我们的 261027-01 都行）。

---

# 追加 2026-10-28 — 全插件方案 + 羿哪吒移植 + 四线并编

## 需求变更（用户）

- easytier：**只留 LuCI 界面（70K），核心不编**（用户自理）
- 加：SSR（gwrt-ssr-plus-luci）/ HomeProxy / IPTV（igmpproxy+udpxy）/ UPnP / 常用工具
  （htop/nano/usbutils-lsusb/lsblk/blkid，另 cp02 上 fdisk=m、pzl8 上 fdisk=y）
- cp02（16M SPI）尽量塞满；pzl8 按最优方案；羿哪吒一起做，GitHub 编译

## 包体积侦察（aarch64 apk 实测，mipsel 接近）与决策

| 包 | 体积 | cp02(16M) | pzl8(58M) | 依据 |
|---|---|---|---|---|
| xray-core | 11M | =m | =y | SSR 核心 |
| sing-box | 15M | =m | =m | HomeProxy 核心，pzl8 也放不下（32+15+11+…>58） |
| v2ray-geoip+geosite | 5M | =m | =y | xray 路由数据 |
| chinadns-ng | 264K | =m | =y | 16M 差 0.26M 只能让路 |
| gwrt-ssr-plus-luci | 3.2M | =y | =y | lua/js，跨架构同体积 |
| luci-app-homeproxy+i18n | 0.57M | =y | =y | 核心另装 |
| dns2socks/dns2tcp/ipt2socks/microsocks | ~0.06M | =y | =y | |
| miniupnpd-nftables+luci+i18n | ~0.1M | =y | =y | 显式钉 nftables 变体（勿选 iptables） |
| igmpproxy+udpxy | ~0.12M | =y | =y | luci-app-iptv 树里不存在，直接用核心包 |
| htop/nano/usbutils/lsblk/blkid+libs | ~0.75M | =y | =y | cp02 自带 kmod-usb 系列，lsusb 可用 |
| kmod-tun / kmod-inet-diag | 小 | y / =m | y / =m | sing-box 依赖 inet-diag，=m 会连带编 apk |
| easytier core | 15/9M | 删除 | 删除 | 只留 luci-app-easytier+i18n |

- cp02 算账：现状 11.8M/16M（剩 3.8M）+ 瘦身（去 ppp 全套 ~0.3M、
  wpad-openssl→wpad-mesh-wolfssl ~0.3M（保留 11r，mt7981 实测 mesh 用 openssl，
  mt76 配 wolfssl 为常规组合）、dnsmasq-full→dnsmasq ~0.07M（DHCPv6 由 odhcpd 接））
  ≈ 4.5M 空间 vs 新增 ~4.6M（含 chinadns=m、fdisk=m）→ **擦线，check-size 仲裁**；
  若爆，log 看溢出数再 demote（候选：homeproxy-luci→=m）。
- xray/sing-box 均支持 mipsel（GO_ARCH_DEPENDS 含 mipsel，no-mips16 标志即为 MIPS 准备）；
  ssr-plus 系 C/Go 实现跨架构无碍，用户判断正确。
- workflow artifact 收集同步加：xray-core/sing-box/v2ray-geo*/chinadns-ng/fdisk/kmod-inet-diag。

## 羿哪吒 = JDCloud RE-CS-03（u-boot 文件名实锤），IPQ5018，eMMC

- 硬件解码来源：Nwrt-2025-06-01 factory.bin = FIT（5.4 内核+DTB，config@mp03.5-c2）
  填充到 6M + squashfs rootfs；DTB 反编译得全机硬件；rootfs 得原厂 BDF。
- GPT（jdcax3000gpt.bin）：0:HLOS 6M + rootfs 256M + rootfs_data 960M + swap 1G +
  ART 512K（0:ART）+ APPSBLENV 等。**内核 FIT 必须 ≤6M**：实测本树 6.18 内核 4.47M
  （从 pzl8 sysupgrade.tar 量出），FIT 后 ~4.6M，装得下。
- 网口：ESS + 外置 QCA8337（复位 gpio39），LAN1-4 在外部 switch（phys 0-3，
  lan_bmp=0x1e），WAN 在内部 GE PHY（wan_bmp=0x00，Nwrt 里 eth0=WAN）。
  DTS：gmac0 直连 ge_phy（phy-mode gmii，label wan，仿 mx6200 的 standalone gmac+label
  写法）；gmac1 SGMII 接 switch CPU 口。若 gmii 模式不对，WAN 不通但 LAN/WiFi 不受影响，
  实机 dmesg 定。
- 按键/LED：reset gpio25 / wps gpio38（低有效）；蓝31/绿32/红33（Nwrt flag 猜高有效，
  错了只反相反，不致命，实机核对）。
- WiFi：IPQ5018+QCN6122（同 PZ-L8），默认使能，calibration-variant "JDCloud-AX3000"，
  BDF 用 Nwrt 自带两份（与 PZ-L8 的 md5 不同，已单独成包 jdcloud-ax3000-wifi-board）。
- eMMC：chosen 不写 root=（APPSBL 按 GPT 自动给，同 Nwrt）；sysupgrade 单槽直写
  0:HLOS + rootfs（platform.sh 新增 jdcloud,ax3000 分支，复用 emmc_do_upgrade）；
  MAC/caldata 走 0:ART（caldata_extract_mmc + mmc_get_mac_binary，偏移套 CMCC 布局待核）。
- 移植文件：dts/ipq5018-jdcloud-ax3000.dts、ipq50xx.mk Device 块（FitImage+EmmcImage，
  DTS_CONFIG=config@mp03.5-c2 对齐原厂 bootloader 预期）、wifi-board 包、caldata、
  02_network（lan1-4+wan，MAC art+12/+1）、platform.sh。
- nezha 配置：rootfs 256M 全套 =y（含 xray+sing-box+geo），easytier 仅界面。
- 待实机验证：WAN 通断、LAN1-4、双频、MAC、LED 极性、内存、sysupgrade 回写。

## 在飞的构建（2026-10-28 14:0x 触发）

| run | 内容 | 状态 |
|---|---|---|
| 40698610224 | pzl8 261027-02（WiFi 版，旧插件集） | 跑完即验证 WiFi 改动 |
| 40700849063 | cp02 261028-01（全插件+16M 瘦身） | 并行跑，重点看 check-size |
| 40700858548 | pzl8 261028-01（最优方案） | 排队（同组串行） |
| 40702165180 | nezha 261028-01（首编，移植验证） | 并行跑，重点看 DTS/内核 FIT |

## 待办更新

- [ ] 四 run 收割：拆包验证 + 归档 bin-cp02-261028-01 / bin-pzl8-261028-01 / bin-nezha-261028-01
- [ ] nezha 首刷建议 initramfs.itb 先行（串口看启动），再 sysupgrade
- [ ] PZ-L8/羿哪吒都要回传：dmesg ath11k、iw list、cat /proc/mtd（含 ubinfo -a，定分区方案）
- [ ] cp02 若 check-size 爆：按溢出数 demote（预案见上）

---

# 追加 2026-10-28 — cp02 16M 爆炸根因 + homeproxy 硬依赖 + pzl8 WiFi 验证通过

## cp02 261028-01：37.9M vs 16M，构建“成功”但无 sysupgrade

- 现象：run 成功，artifact 只有 initramfs（35M）+ apks，没有 sysupgrade.bin。
  查 log：`WARNING: Image file ...-squashfs-sysupgrade.bin is too big: 37879812 > 16384000`
  —— oversize 只告警跳过该镜像，不 fail 整个构建（以后必须检查 artifact 有没有 sysupgrade）。
- 根因：`luci-app-homeproxy` 的 Makefile 里 `LUCI_DEPENDS` 写死 `+sing-box`，
  UI(=y) 强制把 19M 核心拽进镜像。本地版和 feeds 版都有这行，躲不掉。
- 修复：cp02/pzl8 的 homeproxy UI+i18n 一律改为 =m（apk 手动装，workflow 已加收集）。
  nezha（rootfs 256M）不受影响，保持全 =y。
- 教训：任何带核心的 LuCI（如 homeproxy）先查 Makefile 的 LUCI_DEPENDS 有没有硬依赖；
  ssr-plus-luci 无此问题（只依赖 luci-compat/curl）。

## pzl8 261027-02 WiFi 验证（拆包，全部通过）

- 双频 board.bin 都在镜像里（IPQ5018/hw1.0 + QCN6122/hw1.0），md5 与原厂 BDF 一致
  （05abc70a… / 200f445b…），manifest 有 pz-l8-wifi-board 1.0-r1 +
  ath11k-firmware-ipq5018-qcn6122。
- 归档 `bin-pzl8-261027-02/`（factory.ubi+sysupgrade+initramfs+manifest+config+
  easytier aarch64 apk，sha256 全过）。注意这是旧插件集（easytier 核心=y、无 ssr），
  但 WiFi 部分与新配置一致，可先刷验证 WiFi。
- 待实机：dmesg 确认 fallback icked board.bin（非 qmi-board-id 条目）、iw list 双频。

## 在飞（2026-10-28 15:23 触发）

- cp02 261028-02（homeproxy 双=m，16M 二次冲击，check-size 仲裁）
- pzl8 261028-01（同修，58M 充裕，预期一次过）
- nezha 261028-01（1h20m+，首编，重点 DTS/FIT）

---

# 追加 2026-10-29 — cp02-02 一次过 + 双机 uboot 本地编完

## cp02 261028-02：16,122,402 / 16,384,000，剩 261K，擦线过 ✅

- homeproxy UI+i18n 改 =m 后，sing-box 不再被拽入，sysupgrade 正常产出。
- manifest 确认进镜像：ssr-plus-luci / upnp（nftables）/ igmpproxy+udpxy /
  htop+nano+usbutils+lsblk+blkid+libs / wpad-mesh-wolfssl / dnsmasq-std /
  easytier-luci / mesh 三件套 / socket；不在镜像（=m apk）：xray / sing-box /
  geoip+geosite / chinadns / fdisk / homeproxy-UI。
- 拆包：DISTRIB_RELEASE=261028-02，agent 降级 OK（无 .bin），socket OK，
  ssr-plus 界面文件在（ssrurl.htm + i18n lmo）。
- 归档 `bin-cp02-261028-02/`：sysupgrade + initramfs + manifest + config +
  7 个 sideload apk（已改名 *-mipsel_24kc.apk，sha256 全过）。
  刷机后手动装：xray → geo → chinadns → sing-box → homeproxy-UI（eMMC/overlay）。

## uboot（QSDK 12.5 树，本地编，工具链自带）

- 结论：`mark/uboot/uboot-qsdk12.5-build` 就是现成的（uBootKit，带 Web/ failsafe，
  自己的 GitHub CI 也有）；`bl-mt798x-dhcpd` 是 MT798x 的用不上；
  **mt7621/cp02 无对应源码**，鲁班沿用原厂 uboot（sysupgrade 不碰 uboot，无影响）。
- PZ-L8：`./build.sh build cmcc_pz-l8` ✅ → uboot-ipq50xx-cmcc_pz-l8-261029.bin
  （640K），已归档进 `bin-pzl8-261027-02/`。
- 羿哪吒：`./build.sh build jdcloud_ax3000` ✅（defconfig 是上游自带的 f431dc42）→
  uboot-ipq50xx-jdcloud_ax3000-261029.bin（640K），已放入 `bin-nezha-261028-01/`（等固件）。
- 注意： Eventually 如需改动 uboot，走 fork（1.2G）+ 自己的 CI；目前只是用现成 defconfig 本地编。

## 待收割

- pzl8 261028-01（全插件最优，58M 充裕，预期过）
- nezha 261028-02（DTS 文件名修复后重编，重点：dtb 过不过、FIT 体积 ≤6M、sysupgrade 产物）

---

# 追加 2026-10-29 — cp02-03 / nezha-02 双成功归档 + 真机 mesh 修好

## 真机排障（192.168.3.3，261028-02）：三症状根因全找到

1. 无 mesh 漫游：wifiroam 三 apk 是纯脚本，却被 Makefile 架构条件误杀
   （mipsel 不装），97 脚本三步全跳过。已真机手动装包+跑 97+启动，
   mesh 活了（GWRT-BFE9/unconfigured，ubus 正常）。构建侧已修：
   96 脚本 + wifiroam 三包全架构安装，仅 socket 包 aarch64 专属。
2. ssr 报错：有界面无 xray 核心。按用户指示代理栈全拿掉。
3. 无中文：LuCI 本身 zh_cn，mesh.html 中文；英文的是 SSR 旧式页面，随移除消失。
4. 附带：hostname 改 gwrt（即时+commit）；5G 改 149 后重跑改名得 GWRT_5.8G_BFE9，
   漫游组已同步；发现 overlay 落 tmpfs（rootfs_data 仅 64K，重启丢配置），
   -03（~14.5M）留 ~1.7M overlay，自动解决。

## WiFi 命名规则（用户定）

- 双频：2.4G + 5.8G（第一个 5G 射频固定 149/HE80）
- 三频：第三射频才用 5.2G（第二个 5G 射频 36/HE160）
- 实现：95 脚本按 5G 射频顺序分配；命名脚本保持按信道判（>=149 → 5.8G）；
  另补 6G 标签。已真机验证改名。

## cp02 261028-03 ✅（14,484,002 / mtd3 16,187,392，余 1.7M）

- 内容：mesh 全套（预置包进镜像）+ LuCI中文 + 精简主题 + UPnP + IPTV +
  工具（htop/nano/lsusb/lsblk/blkid/fdisk 转正）+ easytier 界面 +
  wol/eqos/vlmcsd；无代理/无ppp；wpad-mesh；hostname 默认 gwrt。
- 拆包 7/7：agent 降级 / socket / wifiroamd / 预置三包（无 socket 包）/
  96 脚本 / 主题目录 / 261028-03。
- 归档 `bin-cp02-261028-03/`（sha256 5/5）。刷机建议 sysupgrade -n
  （首次启动全自动：mesh/SSID/hostname/主题，旧手工配置无保留必要）。

## 精简主题 luci-theme-gwrt-lite（新包，与完整版并存）

- 去 app_icons(3.4M)+plugin_icons+containers，留 logo/brands/css/js/模板/后端，
  源码 1.4M → apk 约 0.9M；同路径安装，uci-defaults 改名避免文件冲突。
- 再生方法见包内 Makefile 头。完整版 3.0M 对 16M 太险，未采用。

## nezha 261028-02 ✅（DTS 修后一次过）

- 修：DEVICE_DTS 显式覆盖（设备名 lastword 映射到 ax3000，对不上 jdcloud-ax3000 文件名）。
- 验证：内核 FIT 5,895,760 ≤ HLOS 6,291,456（余 386K）；BOARD=jdcloud_ax3000；
  双频 board.bin md5 与 Nwrt 提取一致；mesh/agent/预置包/全插件俱全。
- 归档 `bin-nezha-261028-02/`（factory.bin+sysupgrade+initramfs+manifest+config+uboot，
  sha256 6/6）。首刷建议 initramfs 先行。

## mtd 实测（cp02 鲁班 QWRT 下）

- 16M SPI：bootloader 256K + config 64K + factory 256K + firmware 0xf70000
  (16,187,392) + fullflash 16M。构建 IMAGE_SIZE(16,384,000) 比真实分区宽松，
  **真上限是 mtd3**，以后加包以此为准。
- stock uboot 备份（191K，U-Boot 2018.09）在 NAS，流程不碰 bootloader。
- eMMC：用户明确不折腾，只做 mesh-AP（overlay 够用即止）。

---

# 追加 2026-10-29 — -03 刷机风波 + hostname 链 + 开箱验证全过

## “变砖”乌龙：写入被打断，uboot 重刷即好

- 现象：sysupgrade -n 后失联，uboot 还在。镜像法医鉴定：内核有效、
  结构与能开机的 -02 一致、体积 fits → 镜像无辜，系 14.5M NOR 写入中被打断。
- 用户 uboot 下重刷同一镜像，一次点亮。教训：NOR 机 sysupgrade 后
  10 分钟内勿动电源；“连上过一次又掉线”多半是首次启动中，别慌。
- 44/97 hostname 链：主题包 44_gwrt-hostname 定 GWRT → 97 加 MAC 后缀
  得 GWRT-$sfx（多机唯一，DHCP/拓扑可分）。用户要的“gwrt”小写与该设计冲突
  （多 AP 全叫 gwrt 会撞名，且 agent/配对生态全认 GWRT 前缀），已解释保留
  GWRT-$sfx；97 里我加的小写块属死代码，已删（下版生效，不值得为此重编）。

## -03 开箱验证（首次启动，全自动，全部通过）

- 261028-03，hostname GWRT-BFE9，zh_cn，wifiroamd 运行中，role unconfigured
- SSID：GWRT_2.4G_BFE9 + GWRT_5.8G_BFE9（149/HE80 新规则生效）+ mesh-gwrt
- 漫游组 roam.ssids 已同步新 SSID，k/v/r 开；主题目录 /luci-static/gwrt 在，
  mediaurlbase 已设；overlay 落 jffs2（mtdblock6，1.6M），agent 降级 OK。

---

# 追加 2026-10-29 — pzl8-01 归档 + Nwrt 升级框架确认

## pzl8 261028-01 ✅（58M 预算内，约 42M）归档 `bin-pzl8-261028-01/`（sha 11/11）

- 内容：全插件（xray+geo+chinadns 进镜像，sing-box/homeproxy 只留 apk），
  WiFi board 双频 md5 与原厂一致，mesh 三件套，261028-01。
- 注意：归档时 initramfs.itb 拷坏过一次（NAS 写入问题），重拷后 11/11 全过。
  以后归档必须 sha256sum -c 全过才算完（本次立规矩）。
- sideload apk：xray/sing-box/geo 双件/chinadns/homeproxy 界面（aarch64）。

## 首刷方式待定（等真机信息）

- Nwrt v1.6 是 QSDK 升级框架（do_flash_ubi 双槽/failsafe），不是标准 sysupgrade，
  我们的 sysupgrade.bin 直刷可能不认。已解出 Nwrt rootfs 确认。
- 备选：Nwrt shell 下 ubiformat 刷 factory.ubi（卷名 kernel/rootfs 与 SBL 预期一致，
  wifi_fw/bt_fw 遗留卷由我们 platform.sh 清理，ath11k 固件自带 /lib/firmware）。
- 等用户贴 `cat /proc/mtd; ubinfo -a`（Nwrt 下）再定；顺带定重分区方案。

---

# 追加 2026-10-29 — PZ-L8 ART 备份完成（串口直读+crc校验）+ 首刷方案

## ART 备份 ✅（存 IPQ/PL08/art-backup-261029/）

- TTL（CH340 /dev/ttyACM0，本机直连）进 uboot，用 `nand read + md.b + crc32` 全自动备份。
- smem 分区：0:ART 在 0x780000/1M；ubi（"rootfs"）在 0x4300000/58M；
  卷 kernel/wifi_fw/bt_fw/ubi_rootfs/rootfs_data；无 factory 分区；另有 rootfs_1 双槽。
- 方法：ART 读入内存，分 16×64K 逐块 crc32；后 11 块 crc 恰等于全 FF 块 crc
  （deab7e4e，本地算出一致，数学证明全空，免倒）；前 5 块串口 md 倒出，
  逐块 crc 与 uboot 算的一致（31db4da7/514891d7/cba712ec/5b7761fd/10ccf7fc），
  逐字节精确。MAC@+12 = a4:39:b6:10:96:77（与 caldata 偏移猜测一致，0/+6 系占位）。
- `nand bad`：全片零坏块 → raw nand write 安全。
- 教训：md 解析注意行首 \r；大文件走串口务必分块+crc，不能裸倒。

## 首刷方案（待传文件通道）

- 路径：uboot 下 `tftpboot factory.ubi → nand erase 0x4300000 0x3a00000 →
  nand write → reset`（SBL 读 kernel 卷，rootfs 卷 ID 固定，autoresize 接管剩余）。
- 卡点：本机开不了 69 端口，板子 DTS 无 USB，33M 走不了串口；
  需用户 PC 开 tftpd（或 U 盘）。自带 uboot 暂不刷（SBL 完好，无需动）。

---

# 追加 2026-10-30 — PZ-L8 实机攻坚：刷机链路打通、内存定性、WiFi 修复、ART 备份

## 一、ART 备份（务必保留）

`/mnt/syNAS/Dowloads/Rout/IPQ/PL08/art-backup-261029/art-pzl8-1M.bin`
- 来源：uboot 下 `nand read 0x780000 0x100000` → 串口分块 `md.b` 导出
- 校验：16×64K 逐块 crc32 与 uboot 计算值逐字节一致；后 11 块 crc 恰等于
  crc32(64K 全 FF)=deab7e4e（数学证明为空）
- MAC 在 +12：a4:39:b6:10:96:77（0、+6 位是 00:11:22:33:44:5x 占位）
- 全片 `nand bad` 零坏块；无 factory 分区

## 二、PZ-L8 uboot 关键参数（smem 实测）

| 项 | 值 |
|---|---|
| 0:ART | 0x780000 / 1M |
| rootfs(ubi) | **0x4300000 / 0x3a00000 (58M)** |
| rootfs_1 双槽 | 0x900000 / 0x3a00000 |
| UBI | PEB 128K / LEB 126976 / VID offset 2048 / data offset 4096 |
| 卷 | kernel / wifi_fw / bt_fw / ubi_rootfs / rootfs_data |
| 串口 | /dev/ttyACM0 115200（本机 dialout 组可直连） |
| 网络 | uboot 只有 **eth0 = WAN 口**能通（LAN 口 uboot 不通） |
| DRAM | 256 MiB |

## 三、刷机链路（脚本 `/home/godsun/pz/flash.py`，可复用）

TFTP 走不通的坑与解法：
1. **TFTP 服务**：本机 systemd 的 `in.tftpd`（socket 激活，根 `/var/lib/tftpboot`）可用；
   `dnsmasq --enable-tftp` 会撞 69 端口且受 SELinux 限制读不了 NAS 目录 → 用 in.tftpd
2. **防火墙**：firewalld 会把 eno0 抢回 FedoraWorkstation 区导致 UDP 回包被丢，
   必须 `firewall-cmd --zone=FedoraWorkstation --remove-interface=eno0` +
   `--zone=trusted --add-interface=eno0`（NM 重连会重置，每次刷机前复查）
3. **整包 TFTP 会静默损坏**：32M 一次传，每次坏不同 64K 块（crc 对不上）
   → **必须分片**：2MB 一片，逐片 tftp + crc32 校验，坏了只重传该片
4. **最后一片要按实际长度写**（如 p09=0xa0000），写多了会把内存残留写进 flash，
   造成 UBI 里出现重复/错 seq 的 EC 头 → `UBI init error 22`
5. 掩写后必须 `nand read` 回读到**独立内存地址**再 crc（用同地址会把源数据覆盖）
6. 写之前必须 `nand erase`（未擦写报 `NAND write to offset ... failed -5`）
7. 校验通过后 `run bootcmd`；若停在 uboot，注意之前残留的空格会中断 autoboot

## 四、内存定性（决定性结论）

| 版本 | DTS | used | Slab | available | WiFi |
|---|---|---|---|---|---|
| 261029-01 | mode1 双频 | 157M | 113M | **0** | `PHY is undefined`/OOM |
| 261029-02 | mode2 双频 | 156M | — | **0** | OOM，shell 无法执行 |
| **261029-03** | mode2 **单频** | **114M** | **70M** | **21M** | ✅ AP 正常 |

- **每路射频 ≈ 43M 内核 Slab**（113→70M），`fw-memory-mode=2` 对内存**无帮助**
- 用户态全部进程 AnonPages 仅 **0.5~1.4M** → **砍插件无用**（这是本次最大误区，别再试）
- `q6_region` 固定预留 48M（`ipq5018-qcn6122.dtsi`）→ MemTotal 只有 184M
- 结论：**64 位 + 双射频 = 256M 装不下**；原厂/集客能用双频是因为它们是
  **32 位 ARM**（busybox ELF 32-bit ARM EABI5 实测），指针减半
- 32 位不可行：内核 `arch/arm` 无 IPQ5018（只有 IPQ4019），那套在 QSDK 私有树
- **最终决定（用户拍板）**：PZ-L8 只做 **5G 单频 mesh AP**，不死磕双频

## 五、WiFi 起来的真 bug：信道超限

- 现象：AP 接口建出来但 `Channel 0 / Tx-Power 0`，日志
  `hostapd.add_iface failed`，`Frequency 5745 is not allowed (seg0)`
- 根因：`ipq5018-pz-l8.dts` 的 `&wifi1 { ieee80211-freq-limit = <5150000 5730000>; }`
  → 149 信道(5745) 超上限，hostapd `Could not select hw_mode and channel (-3)`
- 修复：`95_gwrt-wifi-defaults` 增加 `gwrt_5g_has_unii3()`，用
  `iw phy <phy> info | grep "5745 MHz"` 探测；不支持则 5G 默认 36 信道
- 验证（改 36 后立即正常）：
  `phy0-ap0 ESSID GWRT_5.8G_4456  Master  Channel 40(5.200GHz) HE160  Tx-Power 22dBm
   Encryption WPA-PSK(CCMP)  HW Mode 802.11ax/ac/n`
- 注意：SSID 名由信道推导（>=149 → 5.8G），所以 PZ-L8 上是 `GWRT_5.2G_xxxx`

## 六、最终固件与验证清单

- **261029-04**（`Version 261029-04`）：单频 5G + 信道自适应 + mesh 全套 + 精简主题
- 已验证通过：系统启动/load 0.13、WiFi AP 22dBm HE160 WPA2、wifiroamd
  (role=unconfigured, name=GWRT-xxxx)、gwrt-agent、uhttpd 200、br-lan 192.168.3.3
  DHCP、MemAvailable ~21M 稳定
- 待验：客户端实际连接/漫游、mesh 与主 AP 配对、长时间稳定性

## 七、其它记录

- **uboot 未刷、也不要刷**：无 9008 无 USB，坏了只能拆 NAND 飞线；只动 rootfs 分区
- 编好的 web 版 uboot 存 `bin-pzl8-261027-02/`，仅留档不刷
- 哪吒模式里也有 `phy0/phy1` 双射频；其 DTS 若同样有 freq-limit，需同样处理
