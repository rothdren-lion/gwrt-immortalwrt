# WORKLOG 2026-11-17 — 跨系列无线生成与首启优化

## 1. 目标与当前状态

用户在 SS-01、CS-02、CS-07 最新 Honk 固件启动排查后，要求继续深查并优化其它系列的公共启动流程。此前复核见 `docs/WORKLOG-20261117-ipq60xx-wireless-startup-review.md`。本轮目标是新 radio 生成配置时一次写好默认值，消除竞争性改写，并保留校准、用户配置和 Mesh 功能。

实现工作树为 `/home/godsun/build/gwrt-startup-opt-261117`。它是 NAS 定点源码快照，基线提交 `b023127`、补充基线 `a1a6235`，不是可直接全量构建的源码副本。目标 NAS 源树为 `/run/user/1000/gvfs/smb-share:server=192.168.9.242,share=dowloads/Rout/mark/immortalwrt`。

最终源码验证：无线生成 18 项、启动行为 14 项回归通过，SS-01 完整延后链、校准重启保护、预设一致性和 diff 检查通过。独立只读复核 `del_mwkjz7lb_nfd3` 达到 15 分钟上限退出（143），没有提交完整结论；不将其计为复核通过。主代理在该任务终止后完成生产差异自查，并使用持久归档的真实 ucode 重新运行全部上述检查，原始输出保存在证据目录 `verification/`。29 个变更文件已选择性同步到 NAS，全部通过同步前基线检查和同步后 SHA-256 回读核验。实机问题尚未确认修复。

本轮没有编译固件、推送 GitHub、连接或修改路由器、刷机、重启；没有使用 `192.168.9.9` 作无线对照。CS-07 红灯、CS-02 5.2G phy 未注册和实际分钟级首启耗时的根因仍未确认。

## 2. 具体改变

### 2.1 新 radio 单次生成默认配置

- 在 `package/network/config/wifi-scripts/files/lib/wifi/gwrt-defaults.uc` 增加可选生成策略，由 `mac80211.uc` 创建新 radio 时使用。已有 radio 按原生成器识别并跳过，不改已有 SSID、密码、Mesh 配置、关闭状态、信道或带宽。
- `wifi-detect.uc` 同时记录射频和频段的可用信道，策略只在探测支持的信道中选默认值。JDCloud SS-01/CS-02/GWRT2 的 AHB 优先 ch149，PCIe 等其它 5G 优先 ch36；无候选时保留探测结果。不按 radio 编号判断角色。
- 5G HE 默认上限 80 MHz；实际信道不完整时降到 HE40/HE20。旧 VHT/HT 设备保持其能力模式。保留 6G 原有安全和国家码默认行为。不同 board country 不套用策略国家码的信道偏好。
- SSID 为 `GWRT_<频段>_<MAC后四位>`，优先使用同一有效以太网 MAC，避免射频探测顺序改变后缀；缺少有效以太网 MAC 时才用其它来源。默认 WPA2-CCMP 和密码由生成策略提供。明确的 board 默认 SSID/加密/密码优先。
- 新轻量包 `package/gwrt-wifi-defaults/` 只安装 `/usr/share/gwrt/wifi-defaults.json`，依赖 wifi-scripts。完整主题、精简主题、V3 主题及 device-defaults 均依赖它，覆盖只选主题、没有 device-defaults 的配置。没有有效策略的普通 ImmortalWrt 保留原生成行为。

### 2.2 取消重复改写，保留首启屏障和校准保护

- `95_gwrt-wifi-defaults` 改为 SS-01 的配置就绪屏障，不再写无线或请求 reload；其它机型直接完成。
- 完整主题、精简主题、V3 中的 `30-gwrt-ssid-name` 和 `40-gwrt-5g2-radio` 保留文件但立即返回，用于安全覆盖旧版本 hook。旧的强制 HE160/国家码/功率改写随之退出启动路径。
- IPQ60xx 的 `gwrt-caldata` 只允许 SS-01、CS-02、CS-02-GWRT2 进入 eMMC ART 校准兜底；CS-07 等其它板跳过。已有校准时只处理尚未完成的 SS-01 首启链，不轮询 phy 或重新命名。
- 保留缺失校准提取、overlay READY 符号链接目标 `2`、持久重启 guard、sync 和最多 360 秒等待的保护。没有将校准必需步骤删掉。

### 2.3 离线 APK 与 wifiroam 失败重试

- `96_gwrt-preset-apk` 在没有预置 APK 时不再等待 APK 数据库。socket 依赖优先安装，成功文件只装一次，第二遍只重试失败项；任意安装失败都保留重试，不再被旧数据库条目掩盖。
- `97_gwrt-wifiroam-defaults` 等待 96 完成；否则下次补装 APK 会把已经完成的覆盖层盖回旧版。这一约束适用于所有机型。
- 一次选定最终旧版/v5 overlay，再复制和应用配置，最后统一处理一次必要的服务激活及 rpcd reload。预置 APK 自身 postinst 会 enable/start，因此不宣称整段开机服务总共只启动一次。
- 保留用户已配置角色、凭据、漫游列表及关闭状态。只有与预置 APK 原配置逐字节一致时才应用 GWRT 新装默认值；新增原包配置模板 532 字节，已用实际 APK 解压内容核对一致。
- 保留仅 `wifiroam_bh`/`wifiroam_bh2` 的已知 WDS 1→0 兼容迁移，不改自定义 STA。列表添加失败时撤销半成品，保留完整重试。

## 3. 验证与复现

本机没有现成 ucode，使用免 root 工具目录 `/tmp/gwrt-hosttools/` 构建真实 host ucode；源码 commit 为 `a2c42eac6369a0bba0315007c7dc7b7130275340`。只构建解释器和本轮需要的 fs 模块；完整工具构建的 resolv 模块因静态非 PIC 库失败，没有作为通过项。已将解释器、fs 模块、libucode 和精确源码归档到证据目录的 `host-ucode/`、`ucode-source.tar`，记录 SHA-256；下面使用持久路径，不依赖临时构建目录。

```sh
cd /home/godsun/build/gwrt-startup-opt-261117
export LD_LIBRARY_PATH=/home/godsun/build/gwrt-startup-opt-261117-evidence/host-ucode
export UCODE=/home/godsun/build/gwrt-startup-opt-261117-evidence/host-ucode/ucode
export UCODE_LIB=/home/godsun/build/gwrt-startup-opt-261117-evidence/host-ucode
python3 scripts/tests/test-gwrt-wifi-generation.py
python3 scripts/tests/test-gwrt-startup-optimization.py
python3 scripts/tests/test-ss01-firstboot.py
sh scripts/tests/test-gwrt-caldata-reboot.sh
sh scripts/tests/test-ss01-mesh-preset.sh
git diff --check
```

- 无线生成 18 项：运行实际 detector/generator，只替换 nl80211、UCI 和文件系统输入；覆盖 SS-01、CS-02 探测顺序、多 radio 频率范围、MT7981/AN7581/IPQ53xx/IPQ5018/MT7621 代表能力夹具、旧 HT/VHT、6G、晚出现 phy、缺省/无效策略、用户配置、国家码、稀疏信道、MAC 回退等。
- 启动行为 14 项：实际 shell 脚本，隔离 UCI/APK/sysfs/services；覆盖安装次数和失败重试、overlay 等待安装、禁用 Mesh、原包新装默认、保存角色、WDS 迁移、列表中途失败回滚、无无线板跳过校准、已有校准不写配置、六个退役 hook。
- SS-01 延后链：真实 shell 子进程/PID 与 flock，验证检测串行、APK/复制/UCI/服务失败重试及已有无线参数保留。
- 校准重启：READY、guard、sync 失败和等待上限均有沙盒验证。
- 预设一致性：检查策略安装依赖、SS-01 就绪屏障、支持的高信道偏好和 HE80 上限。

先增加失败用例再修实现：原包新装 backhaul `0 != 1`、已知 WDS `1 != 0`、不同国家码 `149 != 36`、稀疏信道 `HE80 != HE20`、无效策略仍生成 GWRT、APK 未完成时 overlay 返回 `0 != 1` 均已实际复现。开发期测试沙盒缺少 `/dev/null` 造成的失败已修正，未当作生产故障。

这些测试证明代码在给定输入下的行为，不证明设备启动耗时、驱动加载、无线认证或 Mesh 真实配对。

## 4. 同步、清单和回滚

只同步本轮变更；原 NAS 文件先逐项与快照基线 SHA-256 比较，再备份、写入并回读核验。检测到并发差异时先合并，不进行全树 rsync。独立复核因超时未完成，本轮依据源码自查和实际回归推进同步，并保留这一验证限制。

证据目录为 `/home/godsun/build/gwrt-startup-opt-261117-evidence/`，其中 `sync_verified.py` 在全体文件预检和备份后才写入，逐文件再次检查并发差异并回读 SHA-256。`sync-manifest.json` 保存原始、计划及实际部署哈希，`originals/` 保存每个旧文件；新文件在回滚时删除。本轮实际同步 29 个文件（21 个既有文件和 8 个新增文件），基线无并发差异，29 项回读 SHA-256 全部一致。工作日志和 AGENTS 状态更新后再次按清单同步并核对；没有同步未修改文件或生成的 Python 缓存。

```sh
python3 /home/godsun/build/gwrt-startup-opt-261117-evidence/sync_verified.py preflight
python3 /home/godsun/build/gwrt-startup-opt-261117-evidence/sync_verified.py apply
# 回滚：先检查没有后续改动，恢复原文件并回读核验。
python3 /home/godsun/build/gwrt-startup-opt-261117-evidence/sync_verified.py rollback
```

回滚只涉及本次 NAS 源文件，不涉及设备。工具发现同步后的内容又被别人修改时会拒绝覆盖，需要先人工合并。同步工具本身已在临时 Git 仓库验证：并发差异阻断全体写入、备份原文件、重复同步保留初始备份、回滚拒绝覆盖后续编辑、原文件恢复与新文件删除均通过。公共 `scripts/gwrt-sync-mesh.sh` 只复制自定义包，无法单独传播这次 wifi-scripts 和 target base-files 修改；向其它构建树集成时必须包含这些生成器和校准文件，不能只更新主题。

## 5. 仍待实机确认

- CS-07 红灯根因尚未定位；跳过无关校准流程是已验证的源码优化，不足以证明可以启动。
- CS-02 的 5.2G phy 未注册原因尚未定位；配置生成不会使未注册的 phy 出现。
- SS-01/CS-02 的分钟级首启耗时缺少有效启动时间线，本轮不承诺减少多少秒。
- 新固件的真实 overlay 持久化、无线就绪、离线安装、v5 页面、Mesh 配对和长期稳定性尚未验证；本轮不自动触发构建或刷机。
