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
