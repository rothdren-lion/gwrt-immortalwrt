# AGENTS.md — GWRT MT7981 固件项目

本仓库是 **GWRT** 定制 ImmortalWrt 源码树，目标机型：

- **XINGLOO AX3000**（COMFAST CF-WR630AX，MT7981B + MT7531AE + MT7976CN）
- **Qihoo 360T7**（MT7981B，原厂分区 / UBI 两个 profile）
- **H3C Magic NX30 Pro**（MT7981B，OpenWrt U-Boot 布局）
- **Xiaomi Mi Router AX3000T**（原厂 / OpenWrt U-Boot 布局）
- **CMCC RAX3000M**（MT7981B，NAND/eMMC/UBI）
> 以上 MT7981 NAND 机型共用同一套 GWRT 插件/默认值/ mesh，配置生成器一次全编。

> 详细 mesh 设计见 `docs/GWRT-MESH.md`；完整构建/调试记录见
> `BUILD-NOTES-cf-wr630ax-261025-01.md`。

---

## 1. 构建与刷机

2026-11-19 AN758x NPU 状态数据链路修复：主题 `gwrt-accelinfo` NPU 探测补齐 Airoha
节点（`airoha-npu` 驱动、`soc/*.npu` 绑定设备），AN758x 首页 NPU 行不再被隐藏；
`luci-app-airoha-npu` rpcd 后端补 per-SoC 固件回退（纯 ONT 板无 firmware-name 时
版本不再 Unknown）、修 `npu_cores` "0\n0" 退化，PKG_RELEASE r3；mk-config 与种子
config 固化 `CONFIG_KERNEL_DEVMEM`/busybox devmem（Frame Engine 与 CPU PLL/超频
数据源，261022-01 首版缺失导致详情页整段无数据，需重编生效）。SoC 显示 en7581 属
设计内核对无误。新增 `scripts/tests/test-gwrt-an758x-npu-status.sh`，与 socinfo
回归均过；未编译/刷机/操作设备。详见 `docs/WORKLOG-20261119-an758x-npu-status.md`。

2026-11-20 AN758x 固件加回 bandix-plus：主题流量监控取样唯一源是 Bandix
（`luci.bandix_plus getSnapshot`），261022-01 按 50MB 预算排除导致光猫首页
流量卡无数据；mk-config 把 bandix-plus/luci-app-bandix-plus/zh-cn 翻译移入
安装清单并从两处 unset 清单移除，种子 config 同步 =y（本地产物不入库）。
bandix-plus 为 aarch64 预编译 Rust 二进制（压缩包 2.6MB），依赖 zoneinfo-all/
conntrack/iw 由构建自动解析。用户指示"没有就加入，然后推到 ihu"，改动连同
NPU 修复一起推 `rothdren-lion/gwrt-immortalwrt` master。首次 CI 失败系
gwrt-device-defaults 缺 wifiroam 文件（继承自 master，已被并行会话
f146faa08d 修复）。另按用户要求新增 AN758x 专属构建工作流
`.github/workflows/gwrt-an758x-build.yml`（薄包装复用 gwrt-build.yml，
device 固定 an758x，运行名 an758x-<版本>）；注意包装层顶层 concurrency
组名不能与 callee 相同（嵌套同组会秒失败且无 job/日志），当前构建
run 44644876664 / commit 1cb1a31468db。
2026-11-20 AN7581 IPv6 PPPoE PPE 卸载根治补丁移植：集成
wuziwei/ponwrt-ZN504-HG5585F 的 931-net-airoha-fix-wan-ipv6-pppoe-flow-offload
（4 项修复：foe_insert_entry 阻断路由 L3 跌入网桥子流 / 保留
AIROHA_FOE_MAC_PPPOE_ID / AN7581 IPv6 条目豁免 NPU 计数器 / WAN MTU0/MTU1+16
预算）。内核补丁 source of truth 已在远端仓库（6.18.62/164 补丁链；NAS 树为
6.18.55 旧链勿动）。上游补丁 hunk 计数有误，已按 GWRT 基线用重建源
（6.18.62 tarball + 74 个 airoha 补丁）重新生成并在其上验证。已触发
261120-03 构建（run 44707204533，commit 4e0ea36193bc）。
2026-11-20 仪表盘 SoC 显示改用 AN758x 商品名：gwrt-socinfo（双副本）compatible
匹配优先 `airoha,an[0-9]*`，machine 串接受 an[0-9]*，en7581/en7583 输出映射为
an7581/an7583（与插件页 socLabel 一致）；test-gwrt-socinfo.sh 增加三个用例。
已热更 192.168.3.3 验证输出 an7581*4（scp 的 sftp 子系统被 dropbear 拒绝，
改 ssh 管道直传）。

2026-11-19 Mesh 回传优化：已组网的有线漏收广播时，核对载波、掉线计数、桥和租约后，
从 LAN 桥限时探测已配对主 AP；连续失败才回退，新接线仍走原配对检查。重连优先试本次
开机中同一配对上次成功的频段。主 AP 拓扑显示从 AP 的回传方式和切换原因，并以当前
已认证连接的管理 IPv4 打开 LuCI。保留隐藏 SSID `mesh-gwrt` 及 120/60 秒默认窗口。
验证和本次单独回滚见 `docs/WORKLOG-20261119-mesh-optimization.md`。

2026-11-19 无线漫游回传更新：旧版/v5 去打赏，回传探测、切换、无线和配置恢复拆成独立模块。
从 AP 确认 WAN 通往已配对主 AP 后优先走有线，拔线后确认脱桥再转无线；两路断开时
默认搜索 120 秒、恢复原路由 60 秒并循环，两段时间可在 LuCI 调整，配对保留。
状态、首启、目标 ucode、桌面/手机设置页及双回传隔离 IPv4/DHCP/管理路径验证见
`docs/WORKLOG-20261119-mesh-backhaul.md`；未编译固件或上机，实机无线和无线 IPv6 待验证。

2026-11-18 SS-01 `.3.3` 首页 WAN 曲线恢复：固件 `261118-04/671b86b`、主题 r123，
Bandix 只监控 `br-lan` 导致双栈无样本；已保留 LAN 并追加 `wan`，仅重启 Bandix。
两协议曲线在桌面/手机显示并更新，累计继续增长；统计进程及 boot ID 不变。未改主题、
固件默认或其它设备。备份和回滚见 `docs/WORKLOG-20261118-ss01-wan-curve.md`。

2026-11-18 GWRT 主题 r125 登录入口优化：登录表单取消单独“登录”按钮和旧的
登录前切换链接，将 GWRT/原生作为两个直接提交按钮。GWRT 走当前管理入口，原生
按钮提交同一表单到 81/444，成功后由 LuCI 直接进入目标页面。两份源码和桌面/手机/
路由专项回归通过；`.9.9` 热更新后实机登录页与目标地址验证通过，boot ID 不变，
未发送凭据；`.8.8` SSH 认证不可用，未更新。未编译/推送/刷机/重启。
实机备份 `/root/gwrt-backups/20261118-theme-r125-login-before/`；详见
`docs/WORKLOG-20261118-gwrt-theme-r125-login.md`。

2026-11-18 GWRT 主题 r124：修正 r123 顶栏今天/周期/总量未高亮，流量值接入
原有正常绿色/未知灰色状态；陈旧数据保留数值，恢复后重新高亮。源码双副本六文件
SHA 一致，相关主题/安全回归通过；`.9.9` 六文件热更新及桌面/手机浏览器通过，
导航仍 72px、无横向溢出，统计服务/PID 与 boot ID 未变，累计继续增加。
仅 reload uhttpd；`.8.8` 因当前 SSH 凭据不可用未更新，仍为 r123。
未改统计持久化/APP 轮询，未构建/推送/刷机/重启路由器。备份
`/root/gwrt-backups/20261118-theme-r124-highlight-before/`；详见
`docs/WORKLOG-20261118-gwrt-theme-r124-traffic-highlight.md`。

2026-11-18 GWRT 主题 r123：按用户最新要求，以固定汇总替代 r122 日明细；
`/etc/gwrt/traffic-daily.json` schema v3 仅保留累计/当前日周月年与计数基线，
每 1800 秒原子替换并 sync，首次/迁移可立即写入，服务重启不强制提前写盘。
两台文件约 1 KB，实测位于内置 eMMC F2FS overlay；不随天数增加明细。
复用 wifiroam v5 产品图，CS-02/GWRT2 均为京东云 AX6600，SS-01 为 AX1800Pro；
主路由/AP/可匹配接入设备均接入，未知或缺图退回 SVG，图片限 40px 保持紧凑。
双栈同图透明背景，今天/周期/总量移到导航；35 个源码/测试文件 SHA 与最终候选一致，
55 项流量及主题/Mesh 相关回归、两台桌面/手机浏览器通过；`.9.9`/`.8.8` 各 15 文件
热更新核对通过，累计递增、boot ID 不变。保留 `.8.8` APP 15 秒轮询差异。
仅重启统计服务、reload uhttpd，未构建/推送/刷机/重启路由器；仍依赖 Bandix。
突然断电可能丢失最近约半小时增量；真实完整半小时落盘、断电及 NAND 实机尚未验证。
备份 `/root/gwrt-backups/20261118-theme-r123-before/`；详见
`docs/WORKLOG-20261118-gwrt-theme-r123-traffic-artwork.md`。

2026-11-17 GWRT 主题 r122 流量刷新修复与监控完善：恢复 /tmp/gwrt-theme/traffic-state.json
作为页面只读状态，主题后台采样每 5 秒更新；Bandix ubus 不可用时退回其固定 snapshot 命令，
.9.9 与 .8.8 的 IPv4/IPv6 WAN 计数均已恢复。首页同一流量图按颜色显示双栈曲线，
保留两协议上下行/累计值、总量/今天/本周/本月/本年（覆盖时间不足时隐藏）；日检查点写入
/etc/gwrt/traffic-daily.json，刷新页面不写闪存。导航显示 uptime、真实在线设备、进程数及
最高 CPU 进程。两台实机桌面/手机页面、30 项统计测试及 r122 行为测试通过；主题热更新 reload
rpcd/uhttpd，随后修复只重启流量服务，设备 boot ID 未变。功能依赖 Bandix 正常运行且 WAN 已纳入监控。突然断电最多丢失当天上次检查点
之后的增量。详见 docs/WORKLOG-20261117-gwrt-theme-r122-traffic.md。

2026-11-17 GWRT 主题 r121 首页监控和存储/双栈流量修正：运行存储的 MEM、SWAP、ROOTFS、DISK
统一显示“已用/总容量”；WAN 流量拆为独立 IPv4/IPv6 栏、速率、累计值和趋势曲线；SoC 由
`gwrt-socinfo` 按设备实际识别并显示 `ipq6010*4` 这类值，NSS/PPE/NPU 仅显示实际存在的能力。
WAN/设备卡保持 196px 紧凑高度。两个主题副本、SoC helper 权限及 r121 缓存版本已同步；新增
`scripts/tests/test-gwrt-theme-r121.js`，模板双栈/NSS/存储/SoC/CSS 回归和既有安全/客户端测试通过。
主题已热更新并在 `192.168.9.9`、`192.168.8.8` 浏览器和实机读取验证，执行 uhttpd reload，未刷机或重启。
9.9 有 NSS 双栈累计统计；8.8 无独立 NSS 双栈计数器时正确显示“暂无统计”。详见
`docs/WORKLOG-20261117-gwrt-theme-r121.md`。
全量 `scripts/gwrt-source-preflight.sh` 本轮返回 143 且无诊断输出，未计为通过；主题专项及相关回归通过。

2026-11-17 跨系列无线生成/首启优化候选：用户在前述复核后授权继续深查并优化其它
系列。隔离树 `/home/godsun/build/gwrt-startup-opt-261117` 已将新 radio 的默认
SSID/MAC 后缀/加密/支持信道/HE80 上限接入生成器，新增轻量策略包，由完整/精简主题
和 device-defaults 依赖；已有用户/Mesh/关闭配置保留。95 只作 SS-01 就绪屏障，
六个旧主题 hook 退役；caldata 限 SS-01/CS-02/GWRT2，CS-07 跳过无关校准，保留
overlay READY/guard/sync。离线 APK 仅失败重试，最终 overlay 等安装成功再执行，
wifiroam 保留用户角色及已知 WDS 兼容迁移。18 项真实 ucode 生成、14 项 shell 启动、
SS-01 延后链、校准重启及预设检查通过。独立复核 15 分钟超时退出，未计为通过；
主代理完成源码自查和全部回归复跑，29 个文件已选择性同步 NAS，原始备份、
同步前基线检查及同步后 SHA-256 回读全部完成，证据目录含校验清单和回滚工具；
未编译/推送/操作设备，缺 phy/红灯/实际慢启动根因仍未确认，未使用 `.9.9` 对照。
详见 `docs/WORKLOG-20261117-cross-platform-startup-optimization.md`。

2026-11-17 SS-01/CS-02/CS-07 启动逻辑只读复核：对照 Honk 四机型运行
`43704312163` / `aeb771fea65a210d9f7aaada967b14a07fd48eb0`，确认 SSID 同时由
首启 defaults、主题 phy hotplug、子目标 `gwrt-caldata` 写入；沙盒复现 AHB/ch36
在两套规则下被分别命名为 5.2G/5.8G。硬件按机型区分：SS-01 只有 IPQ6018 AHB
双频（`phy0`/`phy1` 都挂在 `c000000.wifi`，无 PCIe 无线），AHB 记 5.8G；CS-02/CS-07
才带 PCIe QCN9074（记 5.2G）。
`wifi reload` 是 netifd 重读请求，不能直接等同射频完整重启；`gwrt-caldata` 随
base-files 安装，manifest 无独立包不代表缺失。此前“只有一处调用”“SS-01 不 reload”
“省2–4秒”“CS-07 已排除软件”均缺依据或不正确。校准首次补齐存在等待 overlay
READY 后一次重启的路径，但本次分钟级耗时、CS-02 缺 phy、CS-07 红灯根因仍未确认。
用户要求配置生成阶段尽量一次写好默认值；本轮仅复核和记录，未实施重构、编译或操作
设备，未使用 `.9.9` 对照。此前源树 HE80 改动仍保留，未进入新镜像。详见
`docs/WORKLOG-20261117-ipq60xx-wireless-startup-review.md`。

2026-11-16 CS-06 最小插件测试成品已完成本地恢复审计：GitHub `43690954669`
正式编译成功，整轮仍为 failure，原因是包守卫误将 dnsmasq-full 视为缺少 dnsmasq。
已修提供者检查，8 项回归通过，校验修正选择性同步 NAS；复用原 261115-01/1d5d9ba
镜像，未重编。原始哈希/222包manifest/真实6.18.62内核/CMA64/7M布局/两无线DTB及
TX opt-out/实际ARM64驱动/双芯片固件/无APK恢复均核对通过。云端编译后源文件专项
被跳过，无编译后源哈希，不宣称该步骤成功；原始failure和恢复审计边界如实保存。
成品在 `/home/godsun/build/gwrt-releases/cs06-7M-minimal/`，交付文件含版本/7M/minimal；
sysupgrade SHA `108cff21fecf3f918c1365a49ed818fd618fb53a41509a0b63e66fb014a39df6`。
尚待实机验证认证，未连接/刷机/重启。详见 `docs/WORKLOG-20261115-cs06-minimal-tx-encap.md`。


2026-11-15 wifiroam v5 覆盖层接入 SS-01 测试构建：用户要求“合并成一个新的不覆盖原有的，
先最小量编译一个 SS-01 测试”。新增 `package/gwrt-wifiroam-v5/`（上游 0.1.0-r47 守护进程
5498 行 + 两处 GWRT 补丁 = 5522 行、v5 四个页面去“打赏”、资源/中文菜单/ACL/翻译、
重建的 `wifiroam-dpi.c`），全部装到 `/usr/share/gwrt/wifiroam-v5/`；由已有
`97_gwrt-wifiroam-defaults` 新增 `1b)` 段在首启拷入并重启 wifiroam，预置 apk 与旧文件零覆盖。
未移植：回传改 wwan/3-addr、漫游引导按有线回传过滤（两个变量分次验证）。
内核无需改动（只加 `kmod-nfnetlink-queue` 模块），但 SS-01 无本地缓存，仍走 GitHub：
提交 `845873c`、运行 `43708396373`、版本 `261115-05`、release=false。
语法/交叉编译/配置生成检查已过，实机首启替换与页面渲染待验证。
详见 `docs/WORKLOG-20261115-wifiroam-v5-merge.md`。

2026-11-15 CS-06 最小插件测试已启动：用户授权修改并按最低插件配置编译。
独立分支 `cs06-auth-minimal-261115` / 提交 `1d5d9ba1`，新增仅 CS-06 的 TX encap
卸载 opt-out；保留 Linux6.18.62/CMA64/7M/MLO关闭/整组恢复，不改 RX/PPE-DS。
保留基础 LuCI/SSH/联网/双频/诊断，独立 defaults 不带 APK 恢复和 Mesh/大型插件；
本地展开232个基础依赖包。113补丁零fuzz、32恢复/15MLO/5绑定/12TX/15内核选择/6最小
专项与仓库源码预检通过，本地复用feeds仍有Kconfig递归诊断，云端再次配置核验。
GitHub运行 `43690954669`，CS-06 `261115-01`、minimal=true、release=false，已实际
启动；云端配置/编译前专项通过，已进入Build firmware正式编译，尚无新成品。收集与严格镜像审计已启动，状态见
`/home/godsun/build/gwrt-cs06-auth-minimal-261115-evidence/delivery-status.json`。
候选已选择性同步NAS并保留R68S/其它并发改动。旧261114-02实机认证故障版已移出
交付目录到系统废纸篓，诊断证据保留。尚不能宣称认证修好，未连接/刷机/重启设备。
详见 `docs/WORKLOG-20261115-cs06-minimal-tx-encap.md`。

2026-11-15 CS-06 新日志实机复核：用户提供 `RE-CS-06 log-11.15.rar`，启动 revision
确为 `0580ee9`（261114-02）、Linux6.18.62/CMA64/板级MLO关闭。PCI共崩溃7次，
4份实际dump的Q6-SFR全文均与11.14相同：`wal_tx_de_mgmt.c:338` / `WLAN_TX_DE` /
PC `0x0122fe5c`。整组恢复7次均越过停止屏障，6次明确双pdev恢复完成，第6次仅见
双路restart请求；上一轮恢复补丁有效，但首次断言未修好。2.4G在首次PCI崩溃前
已有两轮关联后9秒去认证，全日志无AP-STA-CONNECTED/握手完成记录，不能全归因于
5G崩溃。未见OOM/CMA分配失败/panic。上游同QCN9274/WBE.1.6-01270已有EAPOL
msg3/4与TX encap offload触发同断言的原始报告，作为下一步单变量验证线索，尚非
本机已证实根因；本包无实际加密配置/EAPOL抓包/hostapd DEBUG。原云端43619639969
已成功并完成cs06-7M离线审计归档，但该版实机认证仍失败，不作为稳定无线版本。
本轮只分析记录，未改固件实现、重编、连接设备或刷机重启。详见
`docs/WORKLOG-20261115-cs06-authentication.md`；证据
`/home/godsun/build/gwrt-cs06-log-20261115-giesa9yj/`。

2026-11-15 SS-01 `261115-03` 隔离候选：Honk + Doona、EasyTier LuCI-only、广告拦截、IPTV/UDPXY/Vlmcsd、Mesh LAN 地址刷新及插件弹窗自适应已在 `/home/godsun/build/gwrt-ss01-honk-easytier-261115-01` 准备。实际 init 生成规则的 176 次 DNS 查询通过：七个 360 根域及子域的 A/AAAA，经 IPv4/IPv6、UDP/TCP 均为 NXDOMAIN，正常地址对照通过；旧库补根域/备份/失败保留回归通过。Mesh 和六尺寸弹窗本地回归通过；`make defconfig` 返回 0 且专项通过，但有 feeds/Kconfig 递归依赖错误，不能称为干净配置解析。**SS-01 本轮实机热更新仍未完成：原 `.9.152/.153` 不可达，串口无回显，等待设备连接信息。** 后续用户明确授权在主 AP `.9.9` 修改广告拦截；此独立广告包与文档/test 已从隔离候选选择性同步到 NAS，并完成主AP实测，详见 `docs/WORKLOG-20261115-mainap-adblock-ipv6.md`。SS-01 的 Honk/EasyTier/IPTV/主题/Mesh 实现仍仅在隔离树；未触发新编译、刷机或重启。


2026-11-15 主 AP 广告拦截（后续明确授权）：用户确认可直接在 `192.168.9.9` 修改。设备型号 `jdcloud,re-cs-02-gwrt2`。保留原五分类开关与用户规则，补齐七个360根域；修复 daed 先于 dnsmasq 接管 DNS 的路径，将广告库464个去重后缀通过所选 daed DNS 策略发往本机dnsmasq，其他域名原有分流不变；另持久添加 LAN 双栈 TCP/UDP53 fw4重定向。实测经路由器IPv4、外部IPv4和两路全局IPv6 DNS的A/AAAA UDP/TCP检查416/416通过，其中广告拦截400项为NXDOMAIN、正常地址对照16项；48项终测、正常域名解析、真实客户端https访问和LuCI页面通过。发现并修复LuCI Lua域名校验拒绝所有有效域名的问题，26项目标Lua测试通过。隔离树修复后仅选择性同步15个广告包、测试和文档文件到NAS，SHA逐项核对；未全树同步/重编/刷机/重启。boot ID和daed PID保持，DHCPv6/RA/NDP relay未修改。link-local DNS仍超时并如实列为未验证；DoH/DoT/硬编码IP与终端缓存不属DNS层覆盖。设备完整回滚需先经`gwrt-sync-daed-adblock.py --restore`还原原daed DNS，再运行留存远端的`/root/gwrt-backups/20261115-072806-adblock-ipv6/rollback.sh`。日志 `docs/WORKLOG-20261115-mainap-adblock-ipv6.md`。

2026-11-15 CS-06 再次构建失败已定位：`43598266385/10bc2209` 正式编译、镜像哈希和
32恢复/15MLO实际源码测试均通过；末尾校验误把同级 `linux-atm-2.5.2` 当作第二份
内核。修正 `0580ee9a` 已推送 `cs06-recovery-261114`，仅匹配数字内核版本目录；
保留版本/CMA/重复内核严格检查，并补存原始目标内核配置。15项回归通过，旧脚本
4项失败，仓库源码预检及workflow语法通过。新运行 `43619639969` 已启动，仍为
CS-06 / 261114-02 / release=false；Linux6.18.62/CMA64/板级MLO关闭保留，未降内核。
自动下载改为完整临时目录通过后才发布，避免部分下载因文件已存在反复失败；
收集与镜像审计/归档进程已启动，状态在证据目录 `rebuild-43619639969/`。
旧inspection包尚待下载核查，未绕过失败校验交付。此授权覆盖此前CS-06停止状态，
仅修PCI崩溃后整组恢复，不修 `wal_tx_de_mgmt.c:338` 初始闭源固件断言，未刷机或重启。
详情与云端后续状态见 `docs/WORKLOG-20261114-cs06-group-recovery.md`。

2026-11-14 CS-06 新转储补充：`RE-CS-06 log-11.14-1.rar` 包含同版本另一轮
07:41:34 复现的 PCI dump，结构化 Q6-SFR 明确为 `wal_tx_de_mgmt.c:338`
主动断言、线程 `WLAN_TX_DE`，PC `0x0122fe5c`，与旧 MLO peer 空指针不同。
5G AP 启用约数秒、客户端关联的同一秒崩溃，随后 AHB invalid pdev 持续到
385.077188秒（崩溃后178.43秒）；未见内存分配失败/OOM/panic，本次没有sband
warning。已定位管理帧发送相关模块与行号，具体断言条件尚不明；可映射执行段
未覆盖当前PC。宿主整组恢复缺口与两轮现象吻合但等待分支未获实机trace。
转储已收到，不再以缺文件阻断当前分析；本轮仅离线分析记录，未改固件实现、
编译或操作设备。详见 `docs/WORKLOG-20261114-cs06-pci-assert.md`，证据在
`/home/godsun/build/gwrt-cs06-coredump-20261114-9qyo7em4/`。

2026-11-14 CS-06 刷入后回归：用户提供 `RE-CS-06 log-11.14.rar`，确认实际运行
`261114-01/13bcc6a`、Linux 6.18.62、CMA 64 MiB，板级 MLO 关闭已生效，双频
AP 均启动且有关联记录。5G 客户端关联的同一秒（uptime 197.458876）PCI 固件
发生一次 RDDM 崩溃；随后 AHB 管理帧 invalid pdev 持续，至499.75秒仍未恢复。
未见内存分配失败/OOM/panic。源码存在 PCI 仅排入自身 reset、却清理全组并
等待未复位伙伴的恢复缺口，现象吻合但等待分支尚无实机 trace；不能据此确认
首次 PCI 内部崩溃原因。包内缺少设备已保存的
`/root/coredumps/20261114-062838-devcd1-0001:01:00.0.gz`，待用户补充对照旧dump。
本轮仅离线分析与记录，未改固件实现、编译或操作设备。详见
`docs/WORKLOG-20261114-cs06-wifi-regression.md`，证据在
`/home/godsun/build/gwrt-cs06-log-20261114-gV9I8d/`。

2026-11-14 CS-08 修复：用户指出 Athena 点阵屏为 CS-02 专用、其它机型不应携带，并要求修好重编；实测 CS-08 无 NVMe 驱动。实现提交 `76a93fa5`（`gwrt-mk-cs08-config.sh` 剔除 `athena-led`/`luci-app-athena-led` 并强制 `CONFIG_PACKAGE_kmod-nvme=y`；`ipq53xx.mk` 中 `jdcloud_re-cs-08` 的 `DEVICE_PACKAGES` 加 `kmod-nvme`）已推送 master，云端运行 `43462319841`（`261114-01`，release=false）成功，约 2h38m。拆包核验：athena 文件 0 个，`nvme.ko`/`nvme-core.ko` 与 `modules.d/30-nvme` 存在，SFP 与各 PHY 驱动齐全。产物归档 `/home/godsun/build/gwrt-releases/cs08-261114-01/`，sysupgrade sha256 `bbbc9499859a0895c2b292c3b7ea2b0b0170cdf5b5723705c8bc8c1e8305baf3`。未刷机、未重启；SFP 实插、M.2 上盘、USB3 WWAN 未实机验证。Athena 另有 22 个 config 文件受 cs02 基线污染，仅 CS-08 已修，统一清理待确认。详见 `docs/WORKLOG-20261114-cs08-athena-nvme.md`。

2026-11-14 CS-08 后续实机复核：用户刷入 `261114-01/76a93fa` 后 NVMe 仍未枚举。`nvme` 模块已加载；PCIe 仅有根端口、无端点，根端口 `LnkSta=0x1011` / `DLL Active=0`，启动 `Device not found` 对应 LTSSM Detect 状态。运行 DT 中 PCIe controller/PHY 双 lane、GPIO47 PERST 已释放、相关时钟已开；一次 PCI rescan 仍无端点。问题在 PCIe link/endpoint 检测阶段，尚不能判定 SSD 协议/接触供电、板级布线或控制器初始化。仅触发非持久总线 rescan，未重启/刷机/改配置。待确认 SSD 型号、槽位及原厂识别结果。详见同一 CS-08 工作日志追加段和 `/home/godsun/build/gwrt-cs08-nvme-20261114/`。

2026-11-14 最终状态：用户要求 SS-01、CS-02、CS-02-GWRT2、CS-07 按当前 DTS、最新修复源码构建，插件配置与当前 SS-01 一致。源码固定为 5c0024cb14ea6562943a017afd6f32caaa764582，版本 261114-01，release=false，四款均为 12M。SS-01 原始 GitHub 运行 43482919662 成功；CS-02 43482945138、CS-02-GWRT2 43482974072、CS-07 43483003456 均完成编译、包生成和哈希，但末尾镜像审计误把 factory rootfs 与 sysupgrade root 的 1 KiB 对齐零填充判为不一致。修复提交 7452f64668cdb9140e2e4ddf8194c8a9f5edc747 更新审计、真实 mksquashfs 回归和复核 workflow；三款原始镜像随后分别由 43532124001、43532123823、43532123981 复核通过，没有重编固件。有效 squashfs 均从 12 MiB 偏移开始并与 factory 逐字节一致，sysupgrade 对齐零填充分别为 303、227、481 字节；DTB、DSA/PPE/EDMA、daed、主题和 Mesh 审计均通过。交付归档位于 /home/godsun/build/gwrt-releases/{ss01-12M,cs02-12M,cs02-gwrt2-12M,cs07-12M}/，四款有 48 项公共 SS-01 应用且 daed ARM64 校验一致。三款 CS 原始云端运行没有上传完整 .config/buildinfo，交付中的 .local-defconfig 明确标为本地生成文件；原始运行日志和固定 feeds 记录仍保留。未刷机、未重启，WAN/DSA、Mesh 和长期稳定性仍待实机验证；详见 docs/WORKLOG-20261114-ipq60xx-build.md。

2026-11-13 最新授权：用户要求“把 homepoxy 替换成 daed 然后重新编译”，并确认使用
GitHub；**仅恢复 SS-01 `261113-04`，release=false**，其它机型保持原范围。
隔离树 `/home/godsun/build/gwrt-ss01-daed-github-261113-04` 的实现提交 `8584a2c1`
禁用 HomeProxy，daed 2.1.1-r3 从固定源码构建 runtime1 流量修复，合入 WAN 动态
UNIPHY 候选及 sgdisk。配置/源码/Mesh 专项、68项时钟回归、本地 ARM64 daed 包
和 qemu 浏览器验证通过。首次运行 `43445745283` 因 LuCI 覆盖 Makefile 缺少
包扫描标记在配置阶段失败、未编译；`971c1823` 补齐 daed/Aria2 标记并加入预检，
冷扫描、配置与源码检查通过。新 GitHub运行 `43447840820` 的配置/源码预检、
校准保护和 Mesh 专项已通过，截至 UTC 15:19 正在编译，尚无成品。监控及只针对此
运行的下载/拆包/浏览器核验/12M归档收尾脚本已在本地证据目录启动，状态见
`/home/godsun/build/gwrt-ss01-261113-04/delivery-status.json`。
物理布局保持12M，WAN修复须刷入实测；本轮未刷机、重启或改实机。详见
`docs/WORKLOG-20261113-ss01-daed-build.md`。

2026-11-13 此前停止状态（已被上面的 SS-01 重新编译授权部分替代）：
用户停止 GitHub 编译，当前不是最终版。
SS-01候选 `7fecca5b` 保持本地；9.9 daed/OAF修复本地 `e18a085c`、离线库 `480e494b`
已选择性同步NAS，并从远端master单独合入为 `6c59fc04`、`50e7af85` 后推送GitHub。
远端feature.bin SHA和31,372字节回读核对通过，运行中/排队固件任务均为空。
最终在线更新修正本地提交 `d2eea381` 已选择性发布为 GitHub master `0e40fa97`；
远端在线页面/API/依赖/特征库6文件回读一致，旧禁用补丁不存在，运行中/排队/等待任务均为空。
SS-01 r117 运行 `43354566787` 已取消，旧 `43350331850` 同样取消；结束前运行中与
排队任务均为空。用户断电重上后，SS-01 `261113-01/ce91005` 插 WAN 再次复现 LAN TX
停止，地址仍为 `.3.3`；已确认 NSS 固定时钟对象与 SSDK 动态 UNIPHY 父级不匹配，
GCC 名称回退 + 移除固定占位的源码候选已同步 NAS/隔离树，真实 Linux 6.18.62 函数
68 项回归、负对照和最终 DTB 检查通过，**未编译刷入，实机仍未确认修复**。本轮未主动
重启或再卸载 NSS。后续 eMMC 固件补 sgdisk（含 AN7581/AN7583 eMMC），配置/包展开通过。
`.9.9` 是另一台 RE-CS-02 GWRT2。后续已用原账号复现并修复 daed 统计读取对象错误，
替换为 `daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`，生产 LuCI 的真实
上传/下载速率、累计与曲线均恢复。OAF 旧 appfilter 后台与新 fwx 页面/API 混装，
已匹配更新用户态/init/rule_manager/特征文件，保留原配置规则和内核模块；fwx API、
实时流量、客户端/应用识别正常，已验证与 daed 同时运行。后续按用户要求统一新版fwx：
移除旧appfilter接口权限/两个旧首启脚本，后台设置统一读fwx，移除旧特征路径自动搬迁；
重编用户态并更新init/ACL，旧appfilter ubus对象不存在。6个页面/6个读取API通过，
现有特征库26.11.11/565个应用原样保留，应用记录已从0增加到1；长期持久记录尚未验证。
手机活跃应用图标较多时仍有横向溢出，已留证。仅重启服务，未重启路由器。
用户最终澄清保留在线更新，仓库不可包含其Key：565项feature.bin保留；已撤回禁用补丁，
恢复在线模块/5个API/LuCI Key输入与保存、列表和切换。默认新安装Key为空，用户可填写
自己的Key，设备本地Key不变；实机10项配置/特征SHA一致，565项加载正常、记录15条。
生产浏览器以合成Key拦截写入/远程更新测试，桌面和手机在线页控件与换行通过，未使用
用户Key请求更新服务器；仅重启OAF，daed PID和boot ID未变。源码选择性同步NAS，
清理复用feed的旧禁用补丁，保留独立脚本差异及CS-06日志；最终状态详见
`docs/WORKLOG-20261113-oaf-online-key.md`。SS-01候选保持本地，禁止恢复固件构建。
默认固件 daed v2.1.1 尚未自动接入定制runtime补丁。
详见 `docs/WORKLOG-20261113-daed-oaf-livefix.md`；证据在
`/home/godsun/build/gwrt-daed-oaf-livefix-20261113/`，远端回滚目录
`/root/gwrt-backups/20261113-daed-oaf/`，fwx清理另有独立备份/rollback.sh于
`/root/gwrt-backups/20261113-oaf-fwx-only/`。此前SS-01诊断见
`docs/WORKLOG-20261113-ss01-wan-daed-oaf.md`；不恢复固件构建。

2026-11-13 CS-06 离线诊断：用户补充 `京东云赵云.zip`，含三份板载转储和一份
PCI 转储。QCN9274 `WLAN RT0` 的 PC `0x01967814` / BADVA `0x30`，反汇编及
8项上下文交叉核对指向 MLO peer 对象为空后读取 link 2 字段；板载为伙伴崩溃断言。
首次触发顺序、空对象来源及 CMA 16→64 MiB 的因果关系仍未确认；不把 PCI 单radio
限制视为 MLO 未形成。证据保存 `/home/godsun/build/gwrt-cs06-coredump-20261113/`，
详见 `docs/WORKLOG-20261113-cs06-coredump.md`。未改固件实现、未连接设备、未构建刷机。

2026-11-13 后续 CS-06 兼容候选：已按用户“能修了吗”在本地实现板级 MLO opt-out，
仅 CS-06 两无线节点启用；QMI 显式传 MLO=0，跳过伙伴 ready/teardown，分别分配
双频 wiphy，保留原 WSI 分组、内存和协调恢复。保留配置升级会迁移已知旧 AHB
`5g:radio1` 绑定到 PCI sysfs path，不改 SSID/密码。mac80211 r16、wifi-scripts r3；
完整 110 个 ath12k 补丁零 fuzz 应用、15 项实际函数/5 项配置回归通过，修改前负对照
失败。DTS 属性对比通过（依赖本地已准备 6.18.55，非 6.18.62 完整构建）。这是关闭
跨芯片聚合的兼容措施，未根治闭源固件空 peer，实机双频与稳定性仍未证实；CMA 未改。
源码候选未推送、未构建、未连接设备或刷机，禁止恢复固件构建。详见
`docs/WORKLOG-20261113-cs06-mlo-workaround.md`，证据在
`/home/godsun/build/gwrt-cs06-fix-20261113/`。

2026-11-13 实机观察：用户已刷入 `261113-01`。按用户要求注册 Netcatty stdio MCP，
列出工具并调用 `get_environment` 成功，通过现有 `/dev/ttyACM0` 会话读取串口。
banner 确认 SS-01 / `ce91005` / Theme r115；运行 `43262429011` 已成功完成。
当前启动 LAN1 已以 1000 Mbps 建链、br-lan 为 `192.168.3.3/24`；两路 AP 启动，
无线 STA 有成功关联记录。仍有 UNIPHY `set parent fail`、接口重建时 ath11k vdev
警告；Netcatty 串口执行接口报无可写 PTY，未取得当前速率、Mesh 认证或长期稳定性证据。
本轮未刷机、重启或更改路由器；详见 `docs/WORKLOG-20261113-netcatty-serial.md`。

2026-11-13：用户授权主题修复推送 GitHub 并编译；隔离工作树
`/home/godsun/build/gwrt-theme-261113` 基于远端 `432d03c8`，功能提交 `ce91005e`。
主题升至 r115，合并安全/持久化/卡片导航/网口与无线速率修复，同时保留远端 PON；
SS-01 校准/无线/Mesh 首启策略与 12M 布局保留。按当前恢复范围先编 SS-01
`261113-01`，release=false；本地源码预检、目标检查、SS-01 专项和浏览器回归已通过。
`ce91005e` 已同步 GitHub master；云端运行 `43262429011` 已成功完成，刷机后观察见上。
详情见 `docs/WORKLOG-20261113-theme-github-build.md`；未刷机或重启。

2026-11-13 接入设备信号排版修正（r117）：用户要求缩短速率单位，并恢复信号强度在上、速率在下。实机页面显示 LAN1 `1Gbps`；无线模板恢复四格信号强度与 dBm 在上、速率在下，例如 `-48dBm` / `2.4Gbps`，悬停保留 RX/TX 精确 Mbps。桌面/手机浏览器模拟回归及 source preflight 通过，r117 已热更新 SS-01，备份 `/tmp/gwrt-theme-r116-before-compact-signal.tgz`。提交 `dc78eab2` 已推送；SS-01 `261113-03`（release=false）运行 `43354566787` 已于 UTC 02:53:12 通过前置检查并进入固件编译，尚无成品；旧 r116 运行 `43350331850` 已取消以便 r117 优先。详见 `docs/WORKLOG-20261113-theme-client-link.md`。

2026-11-13 接入设备显示修复：实机发现 `gwrt-clients` 因固件 BusyBox 缺少 `stat` 进入 crash loop，已将私有运行目录的 root/非符号链接/0700 校验改为 `ls -nd` 数字 UID，服务恢复运行。接入设备表现在按实时数据显示 LAN1/LAN2 或 WiFi 2.4G/5.2G/5.8G/6G；有线信号列显示当前协商速率（实机 PC 为 `1000 Mbps`），无线显示当前收发协商速率较大值及 dBm；WiFi 当前接口优先覆盖旧 FDB 端口。主题 r116 热更新已在 SS-01 `192.168.3.3` 验证，更新前备份已持久保存到 `/home/godsun/build/gwrt-theme-r116-validation-20261113/backups/`。串口诊断原网口 TX 卡死期间，卸载 `qca_nss_drv` 曾触发 `destroy_workqueue(NULL)` panic 并自动重启；重启后恢复 SSH/HTTP 和千兆短测，TX 卡死触发原因尚未查明。此后未再次卸载驱动、主动重启或刷机。NSS symbol-only cleanup 补丁 `021-fix-symbol-only-module-cleanup.patch` 已加入源码并通过上游 dry-run 和 9 项实际函数 harness，补丁前失败已复现，驱动包 release 18→19，尚未随镜像验证。提交 `eda276cb6a74835ef9658b34a038263414289870` 已推送，SS-01 `261113-02` 构建运行 `43350331850` 已启动、release=false；截至 UTC 2026-11-13 02:15:22，配置/源码预检、校准保护与 Mesh 专项均通过，已进入固件编译，尚无成品。详情见 `docs/WORKLOG-20261113-theme-client-link.md`。

2026-11-12 后续：SS-01 无线和 Mesh 首启修复已同步到 NAS、隔离工作树并推送 GitHub，
提交 `92ad8fa2`，后续提交 `f7948498` 修复 GitHub 测试的 shell 环境；保留远端 Ubuntu
24.04 构建环境修复。运行 `43160479256` 的 Mesh 配对测试因 Ubuntu Dash 不支持
OpenWrt 库的 `export -n` 失败；运行 `43161129582` 因 Ubuntu BusyBox 未包含 `flock`
而失败；两次都未进入编译。提交 `432d03c8` 修复锁命令的测试环境选择，SS-01 测试构建
`261112-02` 的运行 `43162126875`（release=false）现已成功完成：配置生成、源码预检、
校准保护、Mesh 专项测试、编译、包/哈希、主题/以太网审计均通过。产物已下载到
`/tmp/gwrt-ss01-261112-02/`，sysupgrade SHA-256 为
`68f0021fb24c033482ea9269bb9c3c274a274d0be0bd2d2eb91f9b63869c0e80`，factory SHA-256 为
`98e0999c76768bf806157a6060abbb893456e4b1b621442ada19d514eb2461ae`。
旧运行 `43058011609` 虽成功，但其镜像缺少无线首启脚本，未包含本次修复。当前串口
`/dev/ttyACM0` 只读监听 45 秒为 0 字节，无法据此确认设备当前版本或启动状态；NSS、
LAN/DHCP、Wi-Fi 和真实 Mesh 配对仍待刷入后验证，本次未刷机或重启。旧技能源码审计因
目录布局不匹配、原有插件调试内容未通过；仓库 CI 预检及目标检查已在投影本地通过。
详见 `docs/WORKLOG-20261112-ss01-wifi-mesh.md`。

2026-11-12 修复进度：`gwrt-caldata` 已改为后台等待 `/overlay/.fs_state` 的
READY 状态（符号链接目标 `2`），再写 guard、`sync`、重启；最多等待 360 秒，
超时或 guard/sync 失败则跳过重启。修复提交 `5f2947e0` 已推送私有仓
`rothdren-lion/gwrt-immortalwrt` 的 master，仅触发 SS-01 `261112-01`，
运行 `43058011609`（release=false）。首次因 runner 的 Ubuntu 镜像源 DNS 失败而
停在依赖安装；原提交重跑 attempt 2 后，feeds、配置/source-preflight 和新增回归测试
均成功，该运行后来成功结束；旧镜像的无线/Mesh 缺项见上。隔离工作树
`/home/godsun/build/gwrt-ss01-caldata-261112-01`；详见
`docs/WORKLOG-20261112-ss01-caldata-fix.md`。NAS 相关启动脚本与测试已同步；
没有刷机或主动重启设备，其它机型未触发。

2026-11-11 实机状态：SS-01 串口运行 `261111-01` (`4e20145`, Linux 6.18.62)。
内核和 squashfs 可启动，但 `S18gwrt-caldata` 每次启动提取 ART 校准数据后延迟 8 秒重启；
`mount_root done` 尚未把 overlay 标为 READY，下一轮 fstools 按 UNKNOWN/PENDING 清理逻辑清空
校准文件和 guard，因此形成重启循环。详见
`docs/WORKLOG-20261111-ss01-boot-loop.md`。只做串口只读诊断，未由本次操作刷机或主动重启；
已复现故障并将 `ss01-261111-01` 错误版本交付包及镜像副本移入系统废纸篓，保留诊断日志。
实机 NSS 时钟及 LAN 收发/DHCP 尚未验证；其它机型继续停止。物理 SS-01 主 HLOS 为 12 MiB，
BOOTCONFIG=0，沿用已有 12288k 定义，交付名称标注 12M。

2026-11-09 起的 SS-01 构建背景：只恢复主题 r114 / NSS 网口验证固件构建；物理布局如上。
本次隔离工作树 `/home/godsun/build/gwrt-ss01-261109-01`，成品交付根目录
`/home/godsun/build/gwrt-releases/<model>/`；历史 SSD 交付路径目前未挂载。

本地树就是源码树；实际编译在 `/home/godsun/build/immortalwrt-mt7981`
（通过 rsync 同步 `package/` 等目录）。

```sh
# 生成配置（同时启用 wr630ax + 360T7，一次编出 4 个 profile）
VER=<版本> sh gwrt-mk-wr630ax-config.sh

# 编译（build 树）
cd /home/godsun/build/immortalwrt-mt7981
sh gwrt-build-wr630ax.sh 6 <版本>

# 产物
bin/targets/mediatek/filogic/gwrt-mediatek-filogic-*
```

刷机（设备 LAN 默认 `192.168.3.3`，root 空密码）：

```sh
scp <sysupgrade.bin> root@192.168.3.3:/tmp/su.bin
ssh root@192.168.3.3 'sysupgrade -n /tmp/su.bin'
```

注意：build 树没有 `.git`，必须给 `REVISION`（`gwrt-build-wr630ax.sh` 已处理）。

### MT7621（京东云鲁班 RE-CP-02）— 走 GitHub Actions 云端编译

本地磁盘不足（剩 ~40G，全量树需 ~25G），MT7621 编译在私有仓
`rothdren-lion/gwrt-immortalwrt`（含同名源码快照 + CI）：

```sh
# 触发云端编译（可加 -f version=261026-01 -f release=true）
gh workflow run gwrt-build.yml -R rothdren-lion/gwrt-immortalwrt -f device=cp02
gh run list -R rothdren-lion/gwrt-immortalwrt --limit 3
gh run download <run-id> -R rothdren-lion/gwrt-immortalwrt -D /tmp/cp02-out
```

改 cp02 相关文件后需同步到该仓（导出副本在 `/home/godsun/build/gwrt-github-export`，
rsync + commit + push）。本地备份编译步骤见 `docs/WORKLOG-20261026-jdcloud-cp02-mt7621.md`。

> **2026-10-28 首跑成功**：cp02 261027-01 已归档到 `bin-cp02-261027-01/`（拆包验证 7/7，
> mipsel 降级生效）。preset：`cp02` / `pzl8`。注意推送需直连 URL
> `https://rothdren-lion@github.com/...`（全局 ghproxy 重写不能认证推送）。

---

## 2. 代码地图

| 路径 | 内容 |
|---|---|
| `gwrt-mk-wr630ax-config.sh` | 配置生成器（设备 profile、插件集、turboacc/coremark 选项） |
| `gwrt-mk-cp02-config.sh` / `gwrt-build-cp02.sh` | MT7621 鲁班 RE-CP-02 最低 mesh 配置生成器 + 本地编译脚本（主走 GitHub CI） |
| `gwrt-mk-pzl8-config.sh` | CMCC PZ-L8（PL08）IPQ5018 预设，mesh 子AP + easytier 全家桶 |
| `target/linux/mediatek/dts/mt7981b-comfast-cf-wr630ax*.dts` | XINGLOO 设备树（含 512M 变体） |
| `target/linux/mediatek/image/filogic.mk` | 设备定义（`comfast_cf-wr630ax*`、`qihoo_360t7*`） |
| `package/gwrt-device-defaults/` | 首启默认值（LAN IP、SSID、wifiroam、防火墙、APK 预置） |
| `package/gwrt-mesh-led/` | mesh 状态灯 + WPS/MESH 一键配对 |
| `package/gwrt-mesh-apmode/` | 从 AP 有线优先、无线中继和临时路由的状态机 |
| `package/gwrt-agent/` | gwrt-agent shim（遥测 + APP 命令，含 mesh.*） |
| `gwrt-control/` | Control 17.17 服务端/界面与容器打包（独立部署，不是路由器镜像） |
| `package/gwrt-tv-adblock/` | 2026-11-15 已选择性同步六分类纯文本库522条，独立360分类默认拦截；旧库保留迁移及`.9.9`实机双栈DNS验证见 `docs/WORKLOG-20261115-mainap-adblock-ipv6.md` |
| `package/gwrt-theme/luci-theme-gwrt/` | gwrt 主题（首页/温度/拓扑/mesh 行） |
| `gwrt-theme-V3/` | 主题源码（同步到 `package/gwrt-theme/`） |
| `docs/GWRT-MESH.md` | mesh 设计、协议、APP 命令契约、验证清单 |
| `bin-wr630ax-<ver>/`、`bin-360t7-<ver>/` | 每版归档镜像（只保留最新） |

---

## 3. mesh 关键实现（改动前必读）

1. **配对发现**：`wifiroamd.uc` 每 5 秒发发现广播。控制器只信 WAN 或无线
   实际入接口收到的同配对指纹、同主 AP 地址的近期报文；有线还须先取到同网段租约。
2. **回传切换**：有线优先。先停止 relayd 和 STA、确认无线断开，再将 WAN 并入
   `br-lan`；拔线后启用无线回传。无线使用隔离的 `gwrt_mesh` DHCP 和
   relayd，不走从 AP NAT。两路模式管理 IPv4 和普通客户端都由主 AP 分配。
   已建立的有线才允许漏收广播时用桥上探测保活；无线重连优先试上次成功的频段。
3. **掉线回退**：默认搜索 120 秒、原路由 60 秒，循环并保留配对。
   「无线漫游 → 回传切换」可调。原 LAN/SSID/密码以已保存配置为准，运行时
   使用临时 UCI 变更，旧快照只在升级时迁移。
4. **服务顺序**：先停本地 DHCP/RA 并关 HNAT 再桥接 WAN。恢复路由先拆桥，
   再启动原本运行的服务。Dropbear 有线绑定 LAN、无线绑定 DHCP 地址。
5. **SSID 同步**：只在回传就绪时按频段套用主 AP 的普通 SSID；跳过隐藏回传与访客网。
   旧版和 v5 共用协议状态、主 AP 隐藏回传和前台 SSID 模块。
6. **显式退出**：`/usr/libexec/gwrt-mesh-apmode off` 或 APP
   `mesh.apmode {"enabled":0}` 解绑并恢复原路由；自动回退不会解绑。
7. **跨架构**：APP aarch64 二进制仅随 aarch64 安装；mipsel 用脚本遥测，
   由目标固件提供 ucode socket/digest/struct。v5 和旧版均由首启脚本安装对应覆盖层。

---

## 4. APP 命令契约

上报字段：`gwrt_mesh`（role/cap_ip/peers_online/apmode/ssids/discover/firmware）。

2026-11-12：agent `1712-r8` 的 shell API 增加 IPv6 优先双入口：
`https://op6.gwrt.uk:8443`（2/4 秒连接/总超时）→ 原 `endpoint`
（3/15 秒），直连失败冷却 60 秒再探测；支持纯 IPv6 网络。旧官方配置自动生效，
自建入口须显式配置 `endpoint_ipv6`，`prefer_ipv6=0` 可关闭。
29 项回归（含目标 curl 的真实本地 IPv6 HTTPS）及 APK 签名/14 文件拆包核对通过。
完整包在 `/home/godsun/build/gwrt-releases/agent-1712-r8/delivery/`，并已按用户要求直传
`\\192.168.9.9\gwrt\gwrt-agent\` 根目录，未安装；用户后续恢复 op6 DNS，线上速度未验证。原生 pair/CGI 内部联网、完整包自动 OTA
及同步遥测可能延迟命令轮询的问题仍存；Control 17.17 未改。详见
`docs/WORKLOG-20261112-agent-ipv6.md`。

2026-11-07：agent `1712-r7` 增加 `discovered_devices`（名称/IP/型号/可添加状态）、
已认证 `members` 和 `refresh_interval=5`；保留 `discover` MAC 数组兼容旧调用方。
JSON helper 位于 `package/gwrt-agent/files/usr/share/gwrt-agent/json.uc`，依赖 ucode/fs。
主题首页可发现并添加同 LAN 未组网 GWRT AP；本地界面为 5 秒周期，慢请求不重叠。
配套 Control 17.17 接收 `gwrt_mesh`、支持 Mesh 添加命令，pull 返回实时周期；agent
命令轮询独立每 5 秒，空闲遥测不再阻塞打开界面。打包产物交付 SMB 的
`gwrt/gwrt-agent/release-17.17-agent-1712-r7/`，由用户部署，未安装或替换线上服务。

命令（pull → commands[]）：

| action | 参数 |
|---|---|
| `mesh.pair` | `mac`（可选） |
| `mesh.unpair` | `mac`（必填） |
| `mesh.role` | `role` = cap/sap/unconfigured |
| `mesh.apmode` | `enabled` = 0/1 |
| `mesh.ssid_sync` | 无 |
| `system.reboot` / `system.hostname.set` | 需 `remote_exec=1` |

---

## 5. 验证清单

```sh
# 查当前回传及主网段管理地址
/usr/libexec/gwrt-mesh-apmode status
ubus call wifiroam mesh_policy
uci get wifiroam.core.role          # 自动回退依旧为 sap
ubus call network.interface.lan status       # 有线时拿到的租约
ubus call network.interface.gwrt_mesh status # 无线时拿到的租约

# 显式退出：解绑并恢复原路由配置
/usr/libexec/gwrt-mesh-apmode off
```

---

## 6. 同步 mesh 到其它源码树

```sh
sh scripts/gwrt-sync-mesh.sh /path/to/openwrt
```

该脚本同步所有 `package/gwrt-*` 自定义包、项目文档、配置生成器和构建脚本。
仅同步本轮组网改动时使用工作日志中的清单。

---

## 7. 操作日志索引

- `docs/WORKLOG-20261119-mesh-backhaul.md` — 去除打赏页、有线优先和无线接替、失联循环、
  主网段管理、测试证据及同步回滚清单。

- `docs/WORKLOG-20261118-ss01-wan-curve.md` — `.3.3` 的 Bandix 加入实际 WAN，恢复首页双栈实时曲线；桌面/手机实测及回滚。

- `docs/WORKLOG-20261118-gwrt-theme-r125-login.md` — 登录页改为 GWRT/原生两个直接提交按钮，分别使用当前入口与原生 81/444；不再登录前选择/登录后切换。源码、路由专项和桌面/手机测试通过；`.9.9` 实机热更新并检查最终目标，未发送凭据；`.8.8` SSH 不可达未更新。备份与回滚见日志。

- `docs/WORKLOG-20261118-gwrt-theme-r124-traffic-highlight.md` — 顶栏流量与原监控正常值统一绿色高亮，未知状态转灰且保留累计；源码双副本、主题/安全回归及 `.9.9` 桌面/手机实机通过，仅 reload uhttpd。`.8.8` 当前凭据不可用未更新，统计/持久化/APP 轮询未改；备份及回滚见日志。

- `docs/WORKLOG-20261118-gwrt-theme-r123-traffic-artwork.md` — 半小时固定汇总覆盖写入系统 overlay，取代 r122 日明细；两台约 1 KB，服务重启不提前写盘。CS-02/GWRT2 共用 AX6600 图，拓扑主路由/AP/已识别设备复用 Mesh 产品图并保留紧凑尺寸；源码双副本/实机 SHA、55 项统计及浏览器验证通过。未构建/推送/刷机/重启，断电最多约半小时增量边界与备份回滚见日志。

- `docs/WORKLOG-20261118-tyfza1-port.md` — Realtek RTL9617C（TYFZA1 天邑光猫）平台迁入：`target/linux/rtl9617c/` 240 文件 + 三个 PON 包 + 自写 FIT 打包脚本 + `gwrt-mk/build-tyfza1`，主题依赖改 `luci-theme-gwrt`；36 个目标补丁在真实 generic 栈上零失败。全部为新增，未改 generic/其它 target/feeds。未编译未刷机：SMB 路径含冒号导致 make 无法解析，共享盘当时降级，需在无冒号本地副本编译。

- `docs/WORKLOG-20261117-emmc-storage-defaults.md` — eMMC 存储默认编排：新增 `gwrt-emmc-storage` 统一处理末尾数据分区自动挂载、仅标签/GPT 类型匹配的 swap 初始化与启用、SMB/NFS/Aria2 预配路径（服务仍默认关闭）；旧 40/41/42/43 首启脚本与 block hotplug 改为调用该助手，去掉重置密码、删除全部共享和静态 export 等破坏性动作；本地 18 项测试（10+8）通过，21+1 文件已同步 NAS 并读回校验；未编译、未上机，真实 eMMC 分区与 LuCI 按钮未验证。

- `docs/WORKLOG-20261118-luci-app-pon-info.md` — 新建 `luci-app-pon-info`（ucode 采集器 + procd 采样 + ubus `luci.pon-info` + LuCI 页面），记录 PON 光口/身份/OMCI/接口统计到 `/etc/poninfo/history.jsonl`；PON 平台设备按 `*.pon` 自动发现并兼容 Airoha 厂商工具，已在 `gwrt-mk-an7581-config.sh` 的 PON 包列表接入（仅 AN7581/AN7583 光猫）；TYFZA1（xgpon）实机验证 CLI/ubus/ACL/页面 200，记录该 ucode/rpcd 构建的 `(?:)`、`json(对象)`、无 schema 传参三个坑；GitHub 当前全通路超时未推送，未编固件、未刷机。

- `docs/WORKLOG-20261117-gwrt-theme-r121.md` — 主题 r121 的存储“已用/总容量”、IPv4/IPv6 独立 WAN 流量与趋势、实际 SoC/加速能力识别和 196px 紧凑卡片；两个主题副本、设备 `.9.9`/`.8.8` 热更新、浏览器/模板回归和备份路径已记录，未刷机或重启。

- `docs/WORKLOG-20261117-cross-platform-startup-optimization.md` — 用户授权跨系列无线生成/启动优化；新 radio 单次默认生成、旧 hook 退役、校准白名单、APK/overlay 失败重试及用户 Mesh 配置保留；源码回归完成，独立复核超时未完成，同步状态与回滚见日志，实机根因仍待确认。

- `docs/WORKLOG-20261117-ipq60xx-wireless-startup-review.md` — Honk 固定提交下三路 SSID 配置复核；命名冲突沙盒复现、AHB/PCIe 角色与 reload/base-files 更正，配置生成阶段统一默认值的建议；仅记录，缺 phy/红灯/实际启动耗时仍未定位。

- `docs/WORKLOG-20261115-cs06-minimal-tx-encap.md` — 用户授权CS-06最低插件测试构建；板级关闭TX封装卸载，专项/负对照通过，GitHub 43690954669已启动，认证效果待实机。

- `docs/WORKLOG-20261115-cs06-authentication.md` — 0580ee9 新固件实机日志：7 次 PCI 崩溃，4 份 dump 均为原管理发送断言；组恢复已有实机进展，认证仍失败，2.4G 在首次崩溃前亦有 9 秒去认证。上游同固件 EAPOL/TX encap 报告作为待验证线索，未改实现或重编。

- `docs/WORKLOG-20261115-ss01-honk-easytier.md` — 历史 `261115-01` 已由用户刷入；`261115-03` 的 Honk/EasyTier/IPTV/主题/Mesh 仍是隔离候选，本地DNS/Mesh/六尺寸弹窗通过。SS-01不可达，实机热更新待完成；广告包后来获新增主AP授权并已实测/选择性同步NAS，见独立日志。未触发新编译、刷机或重启。

- `docs/WORKLOG-20261115-mainap-adblock-ipv6.md` — 在明确授权的`.9.9`主AP修复daed→dnsmasq广告DNS路径，添加LAN双栈53转发；400项NXDOMAIN拦截/16项正常地址对照、48项终测、HTTPS和实际LuCI页面通过。独立广告包及测试15文件选择性同步NAS并核SHA；DNS策略/配置有完整回滚，无刷机/重启。新增库域名或更换daed DNS策略后需手动重跑同步工具，现有缓存会延迟开关生效。

- `docs/WORKLOG-20261114-ipq60xx-build.md` — SS-01/CS-02/GWRT2/CS-07 同源、同插件的 12M 构建；DTS/驱动匹配与四款配置、feeds 固定和成品审计，具体云端/交付状态见日志。

- `docs/WORKLOG-20261113-ss01-daed-build.md` — 用户恢复仅 SS-01 GitHub 编译；HomeProxy 替换、从源码构建 daed runtime1 流量修复、WAN UNIPHY 候选和 sgdisk；本地软件包/浏览器及源代码专项已通过，云端成品状态见该日志。

- `docs/WORKLOG-20261113-cs06-mlo-workaround.md` — CS-06 双频独立运行兼容候选：板级 MLO opt-out/QMI 0/伙伴命令保护与旧绑定迁移；110 补丁应用、15+5 离线回归和负对照完成，跨芯片聚合关闭，闭源固件根因与实机效果未证实，不构建、不推送、不刷机。

- `docs/WORKLOG-20261113-tv-adblock-package.md` — `package/gwrt-tv-adblock` 演进：电视/国内广告 dnsmasq 域名层拦截 → r2 纯文本库五档（tv218/tv-ext115/cn148/sec79/kill4=564，sec=360全家桶+腾讯管家+微软Defender/遥测+WindowsUpdate，kill=hao123/2345 无开关必拦），12 机型生成器接入并推送 GitHub `e740babd`；仅源码未编固件。

- `docs/WORKLOG-20261113-oaf-online-key.md` — 用户澄清保留在线更新，GitHub默认Key为空，可填自己的Key；恢复模块/5个API/LuCI，保留565项库，实机配置与Key不变，拦截写入的浏览器验证通过；清理旧feed禁用补丁，不编固件、不刷机。

- `docs/WORKLOG-20261113-oaf-offline-feature.md` — 先前固定565项特征库并禁用在线模块的历史记录；禁用行为已由后续在线Key要求替代，特征库继续保留，未上传用户Key。

- `docs/WORKLOG-20261113-cs06-coredump.md` — `京东云赵云.zip` 实际转储分析：PCI WLAN RT0 在 MLO peer 路径读 `0x30`，寄存器/指令8项交叉核对吻合；三份板载为伙伴崩溃断言。CMA因果与首次触发顺序未确认，未改固件实现、未构建或操作设备。

- `docs/WORKLOG-20261113-cs06-log-review.md` — 复核此前 CS-06 `261111-01` 文本包；确认 ath12k/MLO 恢复循环及第73次板载非法读。该文本包不含 `.gz`，后续实际转储见 coredump 记录；未构建或操作设备。

- `docs/WORKLOG-20261113-daed-oaf-livefix.md` — 9.9 daed实例流量统计修复；OAF统一fwx后台/权限/配置，移除旧首启脚本与特征路径兼容；6页面/6API、565应用特征和新增应用记录实测通过，与daed同时运行。配置规则/内核/加速保留，独立回滚齐全；手机图标行溢出待修，固件构建继续停止。

- `docs/WORKLOG-20261113-ss01-wan-daed-oaf.md` — 用户停止全部云端编译；SS-01 WAN 后 LAN TX 卡死、UNIPHY 时钟父级候选修复及 68 项回归；daed 实机页面热更新/验证边界，OAF API 混装诊断；后续 eMMC 加 sgdisk，未刷机或重启。

- `docs/WORKLOG-20261113-netcatty-serial.md` — 注册 Netcatty MCP 并验证工具环境；现有串口确认 SS-01 `261113-01`/主题 r115，LAN1 千兆和 Wi-Fi/STA 关联；记录 UNIPHY/ath11k 警告及串口执行接口无可写 PTY 限制，未改设备。

- `docs/WORKLOG-20261113-theme-client-link.md` — 修复 `gwrt-clients` 缺少 `stat` 导致的 crash loop；接入设备显示实时 LAN/WiFi 位置、协商速率和 dBm；实机热更新验证 LAN1/1000 Mbps、浏览器刷新与回归测试；NSS 卸载 panic 保护完成 dry-run 和 9 项实际函数 harness；TX 卡死触发原因仍未确定，构建和验证状态见日志。

- `docs/WORKLOG-20261113-theme-github-build.md` — 主题 r115 与 Mesh 速率修复选择性合入远端最新工作树，保留 PON；本地预检和 SS-01/浏览器回归通过，用户授权推送和 SS-01 `261113-01` 云端编译，实际状态见日志。

- `docs/WORKLOG-20261112-gwrt-theme-dashboard.md` — 主题卡片打开菜单、等宽响应式端口格与 DTS/PHY 色环、Wi-Fi/Mesh 协商速率、设备标签按 MAC/IP 持久化；源码、flat/nested 包副本上的 UI/持久化/安全和 Mesh mock 回归通过，integrate 检查通过；未完整编译、未刷机、未实机验证。

- `docs/WORKLOG-20261112-gwrt-theme-audit.md` — GWRT 主题安全审计与多机型网口兼容：
  收紧 rpcd/CGI 权限、隔离临时运行目录、校验 DHCP/IPv6 输入、按 netifd 和 bridge 成员
  识别 WAN/LAN（含 AN7581 `lan1`-`lan4`），同步两个主题包副本；ACL、客户端、Mesh UI、
  SoC、模板 JS 和 shell 回归通过，未编译、未刷机、未实机验证，深度扫描未启动。

- `docs/WORKLOG-20261112-ss01-wifi-mesh.md` — SS-01 无线/Mesh 包和延后首启修复；`92ad8fa2` 及 CI 修复 `f7948498`、`432d03c8` 已推送，`261112-02` 运行 `43162126875` 已成功并完成镜像审计；串口只读监听无输出，仍未刷机或实机验证；记录旧技能审计限制。

- `docs/WORKLOG-20261112-agent-ipv6.md` — agent 1712-r8 IPv6 直连优先、Tunnel 回退与 60 秒冷却；修复纯 IPv6 网络检测、错误返回及 URL 斜杠，29 项回归/签名/拆包通过，完整 APK 已直传 SMB 共享根目录并校验，等待 DNS 恢复后在线验证，未安装或更新服务端。

- `docs/WORKLOG-20261112-ss01-caldata-fix.md` — 校准提取后的重启改为等待 overlay READY 并有界退出；回归测试接入 SS-01 workflow，提交 `5f2947e0` 已推送；运行 `43058011609` 后来成功结束，旧镜像的无线/Mesh 缺项见后续日志，未刷机。

- `docs/WORKLOG-20261111-ss01-boot-loop.md` — 串口确认 `261111-01` 启动后由 `S18gwrt-caldata` 重复触发软件重启；`mount_root done` 未及时把 overlay 标为 READY，fstools 后续清除校准文件和重启 guard；故障镜像已移出交付路径，设备与源码未改。

- `docs/WORKLOG-20261114-an7581-daed.md` — AN7581（an758x）集成 daed(runtime1)/tv-adblock/主题 r117 的完整过程：261114-03 镜像实际缺 daed 的两个根因（`KERNEL_XDP_SOCKETS` 未开使 daed 成 hidden symbol 被 defconfig 静默丢弃；`KERNEL_DEBUG_INFO_BTF` 依赖 `!KERNEL_DEBUG_INFO_REDUCED`），修复提交 `3d5ef936`/`baee92f1`，BTF/DWARF 撞 145G 运行器磁盘墙后拆两组编译（`43754362387` 11 profile、`43771997024` 10 profile，均 success），21 个 sysupgrade 拆包核验 daed 2.1.1-r3/runtime1 marker/ads-library 564 条/主题 r117/act_bpf.ko 均通过；交付 `/home/godsun/build/gwrt-releases/an758x-261115/sysupgrade/`，未刷机。

- `docs/WORKLOG-20261111-an7581-overclock.md` — FiberHome HG5585F CT（AN7581）实机验证 CPU PLL 1200/1300/1400 MHz；四核 SHA-256 校验、1400 MHz 连通性检查通过，测试后恢复 ondemand 默认 policy，未刷机。

- `docs/WORKLOG-20261109-ss01-build.md` — 用户恢复仅 SS-01 构建；串口核对主分区 12M、保留 DD-WRT 无线策略，主题 r114 / NSS 设备树与驱动、成品拆包检查；只交付 factory/sysupgrade，尚未刷机。

- `docs/WORKLOG-20261109-ss01-theme-ethernet.md` — SS-01 首页热修复已实机验证；CSSTidy 删掉现代 CSS 是样式异常根因，主题 r114 禁用 CSS 压缩，SoC 显示型号 × 线程。串口确认 LAN/WAN 网卡未创建，准备 NSS/SSDK DTS 与驱动修复候选；此记录完成时全部构建停止，后续仅 SS-01 恢复见新构建日志。

- `docs/WORKLOG-20261108-cs06-wifi.md` — CS-06 Q6/PAS 初始化修复候选；TR3000 当前版本 Wi-Fi 已正常，本轮全部构建已停止；记录 SS-01 `.3.3` 直连、mesh `.157` missing-ACK 掉线及串口诊断。

- `docs/WORKLOG-20261107-selected-builds.md` — 指定 8 个 SoC/机型任务、25 个 profile 云端编译；CS-05 沿用 RE-CP-03，SS-01 保留专用固件策略。

- `docs/WORKLOG-20261107-agent-mesh-refresh.md` — agent 结构化 Mesh 发现/添加确认、
  JSON/SSID/绑定兼容修复、界面 5 秒周期；`.9.9` 脚本热更新及可回滚备份，未刷机；
  后续 agent APK 与 Control 17.17 ARM64/AMD64 镜像本地打包、验签及 SMB 交付。
- `docs/WORKLOG-20261026-qualcommbe-cs06-be6500-be10000.md` — qualcommbe ipq53xx/ipq95xx
  同步（BE6500/BE10000/CS-06 等新机型）、XER5 保留、CS-06 配置派生与编译验证、
  generic 按需增量补丁（706/752/753/767/768/769/775/901）
- `docs/WORKLOG-20261026-jdcloud-cp02-mt7621.md` — cp02 最低 mesh 集成、
  gwrt-agent/device-defaults 跨架构改造、GitHub Actions 云端编译（ipq5018 待确认机型后移植）
- `docs/WORKLOG-20261103-kernel-patch-ci-fixes.md` — `.prepared`/`world` Error 2 根治：
  DSA tag 枚举尾部冲突（ramips/realtek/qualcommax/ipq40xx 锚点重排）、
  generic config 补 `NET_DSA_TAG_RTL837X_8021AD`/`RTL9303_8021AD`、
  删除 6.18 失效补丁（ramips 102-01、mediatek 863）；
  BE9300 本地出固件（ipq53xx.mk 重建、base-files 合并、ipq-wifi/ath12k-firmware、REVISION）
- **务必**：构建树无 `.git`，`make` 必须带 `REVISION=<sha>`，否则 `package/base-files` 报
  `package version is invalid`（`~unknown`）
