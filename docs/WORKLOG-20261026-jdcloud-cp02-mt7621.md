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
