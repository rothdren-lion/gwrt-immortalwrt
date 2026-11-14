# WORKLOG 2026-11-14 — SS-01 / CS-02 / GWRT2 / CS-07 同源构建

## 授权与范围

用户要求 `ss-01 cs-02 cs-02-gwrt2 cs-07 按照dts 编译用最新修复修改的的源码，插件配置和当前 ss-01一样`。
本轮恢复这四款的 GitHub 构建，版本 `261114-01`、`release=false`，不操作路由器。
隔离树 `/home/godsun/build/gwrt-ipq60xx-github-261114-01`，证据目录
`/home/godsun/build/gwrt-ipq60xx-261114-01`。未丢弃 NAS 及其它隔离树的修改。

## 源码与配置

起点为最新 GitHub master `d8c1ce2b62b75d556f6126bb2b806c0e38f729aa`。
保留 daed 2.1.1-r3 的 runtime1 流量修复、主题 r117、SS-01 WAN 动态 UNIPHY 时钟候选、
校准/无线/Mesh 首启修复、OAF 在线更新及空默认 Key、eMMC sgdisk。
源码及全部七个 Git feeds 已 fetch 比对，无落后项，版本记录见证据 `source-revisions.txt`。
四任务使用 `configs/ipq60xx-feeds.conf` 固定本次验证过的相同 feeds，再应用 GWRT overlays；
不把各任务启动时间不同导致的 feed 漂移带入四款成品。

新增 `scripts/gwrt-mk-ipq60xx-config.py`，四款均从当前 SS-01 保存配置派生，
只调整 profile 和硬件依赖，统一 PREINIT 为 192.168.3.3。
保留 daed 及 SS-01 的公共应用，不再沿用 CS-07 旧配置中缺少 daed 的策略。
CS-07 保留 Bandix，只解除该机型无用的 iw 依赖。

| preset | DTS | Ethernet | 无线/屏幕 | HLOS |
| --- | --- | --- | --- | --- |
| ss01 | ipq6000-re-ss-01 | NSS/SSDK，dp2/3/4=lan1/2/3，dp5=wan | IPQ6018 AHB，无 QCN9074/Athena | 12288k |
| cs02 | ipq6010-re-cs-02 | DSA，1–4=lan1–4，5=wan | AHB+QCN9074 PCI、DD-WRT 固件、Athena | 12288k |
| cs02-gwrt2 | ipq6010-re-cs-02-gwrt2 | 当前 DTS 包含标准 CS-02，端口映射相同 | 同 CS-02 | 12288k |
| cs07 | ipq6010-re-cs-07 | DSA，1=wan，2–4=lan1–3 | 无无线/PCI/Athena；保留 DTS 状态灯 | 12288k |

旧技能关于 GWRT2 WAN 位置、CS-07/SS-01 6M 的记载与当前源码不符，按用户 DTS 要求及
已确认的 12M 定义执行，不重写板级端口布局。daed 使用本次 SS-01 已启用的内核集成 BTF，
保留 kmod-sched-bpf/XDP，未换成旧技能的外置 vmlinux-btf 策略。

发现 CS 系列 DTS 的 PPE/EDMA 已存在源码，但目标 config 默认关闭两个驱动，同时继承 NSS
默认包。新增 kmod-qca-ppe/kmod-qca-edma，使 CS 的配置与 DTS 匹配，并排除竞争的 NSS/SSDK；
SS-01 继续保持 NSS 路径。新增通用镜像审计检查实际 DTB、端口/无线状态、12M factory
偏移、驱动模块、daed runtime1、主题与 Mesh。CI 保留 SS-01 专项，并为四款上传包表、
profiles/checksums/buildinfo、实际 .config、feeds SHA 和审计记录。

## 本地验证

- 四款均经过真实 feeds 扫描、make defconfig 收敛、仓库配置验证器及技能只读硬件 guard。
- 准备好的真实 Linux 6.18.62 与当前全部 QCA dataplane 文件逐一相同；在独立 reflink 内核
  副本中，PPE 七个源文件及 EDMA 编译并链接为 ARM64 .o 成功。完整模块 modpost 及整机
  内核/镜像仍由云端构建验证，未把对象编译表述为完整固件成功。
- 使用当前板级 DTS 及 6.18.62 头文件编出四份实际 DTB；三个 DSA DTB 的 compatible、
  PPE/EDMA、端口、AHB/PCI 状态审计通过。SS-01 最终 FIT 由已有专项审计确认。
- 当前仓库 source-preflight、校准重启保护、Mesh preset/firstboot/autopair、真实内核
  时钟 68 项回归通过。包集对比与负对照见证据目录。
- 技能旧 preflight 因仓库布局、原有 OAF/磁盘管理调试内容和旧 LAN 默认路径不匹配失败；
  不以此为由删除无关插件，采用本仓库 CI 实际 source-preflight。
- 当前 video feed 未选择的 Qt5 包有原有 Kconfig 递归诊断；defconfig 完成且目标应用、
  驱动校验通过。未改与本轮无关的 Qt5 包。

## 云端与交付状态

实现提交 `5c0024cb14ea6562943a017afd6f32caaa764582` 已原子推送至 GitHub master 与固定构建分支
`build/ipq60xx-261114-01`。四任务均使用该分支的同一提交，`release=false`。

| 机型 | GitHub run | 初始状态（UTC 2026-11-13 18:28） |
| --- | --- | --- |
| ss01 | [43482919662](https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43482919662) | in_progress |
| cs02 | [43482945138](https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43482945138) | in_progress |
| cs02-gwrt2 | [43482974072](https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43482974072) | in_progress |
| cs07 | [43483003456](https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43483003456) | in_progress |

后续只以对应 run 的最终结果和实际产物为依据更新状态；成功后按模型归档至
`/home/godsun/build/gwrt-releases/`，交付文件均带 `12M`，一起保存 manifest、profiles、
buildinfo 与校验文件。运行输入和精确 SHA 见证据 `runs.json`。
SS-01 WAN/LAN 反复插拔、CS 系列 DSA 实机性能仍需刷入后验证；本轮不刷机、不重启。

已启动只处理上述四个 run 的 `finish-four-builds.py`（证据目录内），直接读取 GitHub 状态，
成功后下载镜像及验证 artifact、核对 feeds 锁、包表、DTB、12M 布局、主题与 Mesh，并以
qemu 运行成品 ARM64 daed 做浏览器验证。四款最终应用版本一致后才生成带模型与 `12M`
的交付文件，核对归档校验和；不会操作设备。实时状态为证据 `delivery-status.json`。
脚本未将正在编译的镜像视为成品，失败时留证并停止交付。

UTC 2026-11-13T18:34:15.955569+00:00: 四款 `Generate config`（含配置与源码预检）均成功，
SS-01 校准保护及 Mesh 专项成功；四任务正在 `Build firmware` 步骤，尚无本轮成品。
监控/校验/归档进程 PID `73952`，日志 `finish-four-builds.log`；状态直接来自 GitHub，
不会依赖旧 SS-01 的缓存监控文件。固定远端构建分支仍为实现提交 `5c0024cb`，
后续仅文档提交不改变这四次运行的源码。


---

## 最终状态（覆盖上文历史的“构建中”记录）

本节记录最终结果；上文的初始授权、预检和“正在构建”状态保留作历史追踪。源码固定为 5c0024cb14ea6562943a017afd6f32caaa764582，版本 261114-01，release=false，固定构建分支 build/ipq60xx-261114-01；镜像审计与复核修复提交为 7452f64668cdb9140e2e4ddf8194c8a9f5edc747。

| 机型 | 原始 GitHub 运行 | 原始结论 | 修复后的复核 |
| --- | --- | --- | --- |
| SS-01 | 43482919662 | 成功 | 不需要复核 |
| CS-02 | 43482945138 | 编译、包和哈希成功；末尾镜像审计误报 | 43532124001 成功 |
| CS-02-GWRT2 | 43482974072 | 编译、包和哈希成功；末尾镜像审计误报 | 43532123823 成功 |
| CS-07 | 43483003456 | 编译、包和哈希成功；末尾镜像审计误报 | 43532123981 成功 |

三款 CS 的旧红色运行仍保留，复核运行直接读取这些原始运行留下的实际镜像，没有重新编译。旧审计把 factory 中的完整 rootfs 与 sysupgrade 中的 root 逐字节比较；mksquashfs -nopad 生成的有效 squashfs 本来相同，而 sysupgrade 会按 1 KiB 边界补零。四款有效 rootfs 均位于 12 MiB 偏移并与 factory 逐字节一致；CS-02、CS-02-GWRT2、CS-07 的 sysupgrade 补零分别为 303、227、481 字节。修复后的审计继续检查有效 payload、偏移、零填充、hash、DTB、DSA 驱动、daed、主题和 Mesh；基于真实 mksquashfs 的错误偏移、损坏、截断、无效长度及多余/非零填充等 7 项回归均通过。

交付目录与镜像 SHA-256：

| 机型 | sysupgrade | factory |
| --- | --- | --- |
| SS-01 | /home/godsun/build/gwrt-releases/ss01-12M/gwrt-261114-01-qualcommax-ipq60xx-jdcloud_re-ss-01-12M-squashfs-sysupgrade.bin — d79d8a8e5ffa4e5b23972fca30bcb5e4d84aefe050aa65bf8036889a6410366f | 9fce1e1af72593c5bc436e4d844ed8f4a0c4b273264ea06e2f06e35594cca7be |
| CS-02 | /home/godsun/build/gwrt-releases/cs02-12M/gwrt-261114-01-qualcommax-ipq60xx-jdcloud_re-cs-02-12M-squashfs-sysupgrade.bin — f6b32206e0c953c9da82f7dd43bb8b307084078cf7df728005f96fc97f78e501 | 5a5769b8cefdbde08ab645f493b43cd79517a534e0fbff79491f2d0dd447c26e |
| CS-02-GWRT2 | /home/godsun/build/gwrt-releases/cs02-gwrt2-12M/gwrt-261114-01-qualcommax-ipq60xx-jdcloud_re-cs-02-gwrt2-12M-squashfs-sysupgrade.bin — 4bd3140a463042754964fe052b4f886b7b572810654b43bd14bbe92f1b15c9d4 | d62400a0952f06e907b89858c26305bea7f442565c30abb15457a1a7ca6b1382 |
| CS-07 | /home/godsun/build/gwrt-releases/cs07-12M/gwrt-261114-01-qualcommax-ipq60xx-jdcloud_re-cs-07-12M-squashfs-sysupgrade.bin — a66fdf293de5a7e3b52d7b9e804d8a60827ed5868a250133f01865a68a68b724 | 05349057d46e8b2416dba09dfd2d5eabf12c7835284b533d2ebbd45b6acf490c |

四个目录均保留 factory、sysupgrade、manifest、profiles、sha256sums 和审计日志，归档校验已通过。四款镜像有 48 项公共 SS-01 应用及版本完全一致；板级 Wi-Fi/Athena/NSS 包按 DTS 合理不同，CS-07 保持无无线。四款 daed ARM64 程序 SHA-256 均为 fde527ce86b73fef061a437837eef2ef8c5069e423097ec325bba9e39db1cac9；从 SS-01 实际镜像提取后用 qemu-aarch64 与 Playwright 完成登录、CORS/GraphQL、流量和移动页面验证。

元数据限制：SS-01 保留原始云端 .config、feeds-revisions 和 buildinfo；三款 CS 的原始 workflow 没有上传完整云端 .config/buildinfo，交付中的 .local-defconfig 是本地生成并明确标注的复核辅助文件，不能当作原始云端配置。原始 GitHub 运行日志、源 SHA 和固定 feeds 记录均已保留，可追溯原始结果。

变更备份与回滚：NAS 变更前备份为 /home/godsun/build/gwrt-ipq60xx-261114-01/nas-before-audit-fix.tar.gz；隔离树和证据目录均保留原始失败日志、复核记录与镜像审计输出。若需回滚审计修复，可回退 7452f646；固定构建分支仍指向 5c0024cb，不应把文档提交混入固件构建。整个过程未刷机、未重启、未连接或修改任何设备；WAN 时钟、CS DSA 稳定性、Mesh 配对和长期运行仍需实机验证。
