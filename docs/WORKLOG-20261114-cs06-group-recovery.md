# CS-06 PCI 崩溃后的整组恢复修复

## 范围与基线

用户在补充 PCI 转储后授权先修宿主恢复缺口，再推送 GitHub 编译。
目标为 `cs06 / jdcloud_re-cs-06 / 261114-02 / release=false`。
保留 Linux 6.18.62、CMA 64 MiB 和 CS-06 板级 MLO opt-out，双频独立运行。
设备定义的 factory 内核槽仍为 7168 KiB；本机型不套用 IPQ60xx 的 6M/12M 规则。

本补丁不修闭源 QCN9274 固件的 `wal_tx_de_mgmt.c:338` 初始断言。
原日志只能证明崩溃后长期未恢复；具体等待分支仍待新版本实机日志确认。

## 实现

- PCI MHI RDDM 回调仍只排入自己的 reset work；在进程上下文的 reset worker
  中调用共用组恢复函数，调度已注册且 QMI ready 的伙伴一起复位。
- AHB UserPD/RootPD 与 PCI 使用同一组恢复入口；保留原 `hw_group_ref` /
  `num_started` 屏障，全部成员停止后才重置共享内存并重新上电。
- 跳过未就绪、正在退出、已有 reset 工作的成员；退出标志与跨设备任务提交
  使用组 mutex 协调，取消 AHB reset work，QMI_FAIL 的 AHB/PCI 退出分支也先排空任务。
- 普通内核日志记录组恢复调度、伙伴等待、全部停止后重启和上电错误。
- mac80211 release 16→17。CS-06 workflow 在编译前及实际编译源上运行恢复/MLO
  测试，并保存内核配置、源码校验值及固件验证记录。

组恢复改动在 ath12k 公共代码中，包含单设备、原有 MLO 和混合总线用例；
此次仅触发 CS-06 构建，其他机型未做实机验证。

## 验证

- 哈希核验 backports 7.2 原始包后，112 个 ath12k 补丁按顺序以 `--fuzz=0` 应用成功。
- 32 项恢复/退出测试、15 项 MLO 策略测试、5 项旧无线绑定迁移测试通过。
- 恢复测试提取真实 C 函数，用 Clang UBSan 运行；workqueue、HIF、析构操作为模拟，
  覆盖 PCI 单独崩溃、共享内存屏障、重复事件、伙伴未就绪、退出和 QMI_FAIL。
  它不能代替完整内核并发、固件、无线射频或实机稳定性验证。
- 负对照：原恢复实现 16/28 用例失败；只缺 QMI 退出补丁时，新增两个
  QMI_FAIL 退出用例失败，补丁后全部通过。
- 本地完整 feed 投影配置通过 `gwrt-check-target.sh` 与
  `gwrt-validate-build-config.py`，仅选择 `jdcloud_re-cs-06` 且无线驱动/固件齐全。
- 仓库 `scripts/gwrt-source-preflight.sh` 通过。
  通用技能的旧审计因 IPQ60xx 路径/LAN 布局假设及现存 OAF 调试输出不通过，
  未把该审计记录为成功；本次按仓库 CS-06 目标检查及 CI 源码预检执行。

证据目录：`/home/godsun/build/gwrt-cs06-recovery-261114-evidence/`。
尚未连接设备、刷机或重启。提交、云端运行与产物状态在后续段追加。

## 云端任务

恢复提交 `7bf511b23de0ff9f94466f3920e0eb995f33c1e0` 已推送到
`cs06-recovery-261114`，基于远端 `562abfb6` 并包含既有 MLO 兼容补丁。
已触发 CS-06 `261114-02`、`release=false`，运行
https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43586551887 。
触发时排队中，不能据此宣称编译成功或实机恢复成功。
构建使用隔离分支的 Linux 6.18.62/CMA64，不使用 NAS 树的旧内核配置。
补丁、测试与 mac80211 release 已选择性同步 NAS；NAS workflow 与隔离分支
有既存差异，保留原文件，云端按已推送分支的 workflow 执行。

## 云端正式编译与结果收集

2026-11-14T10:48:29.688670+00:00 核实：运行 `43586551887` 配置生成和编译前 CS-06 专项检查通过，
现已进入 `Build firmware`，尚无固件成品。提交为 `7bf511b2`。
已启动仅监测本次 run 的后台收集器，成功后下载镜像与验证 artifact，
检查目标、镜像 SHA256、内核/CMA 配置和前后两轮回归记录；失败则保存日志。
状态文件：`/home/godsun/build/gwrt-cs06-recovery-261114-evidence/delivery-status.json`。
收集器不会刷机、重启或自动重跑任务；下载后仍须检查 FIT/DTB、实际模块和 rootfs，再归档交付。

## 首轮云端编译与末尾校验失败

恢复提交 `7bf511b23de0ff9f94466f3920e0eb995f33c1e0` 已推送到
`cs06-recovery-261114`，运行
https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43586551887 。
`Build firmware` 在 2026-11-14 12:33:32 UTC 成功结束，随后包和镜像哈希检查通过。
实际编译源上的 32 项恢复、15 项 MLO 测试全部通过，但同一步末尾的内核配置
校验返回 1。后续固件上传被跳过，仅保留失败日志，不能把这次运行交付为成功。

校验使用 `find build_dir -name linux-6.18.62 -print -quit`，未限制目标。
工具链头文件树也有同名内核且默认 CMA 为 32 MiB；本地真实树也含其他板型。
在本机 build 所在文件系统创建工具链 32 MiB 和 CS-06 64 MiB 两目录后，
旧命令实际选中工具链并返回 1，新校验选中 CS-06 并通过。
旧云端没有打印所选目录，无法仅凭旧日志直接证明当时选中了哪份配置；
新运行保留所选路径、实际值和目标内核配置，用于确认最终编译结果。

CI 修正只检查 `target-aarch64*/linux-qualcommbe_ipq53xx/linux-*`，拒绝缺失或
多份目标内核；检查编译生成的 release 为 6.18.62，并保留 CMA/DMA_CMA 启用、
64 MiB 与按 MiB 选择的严格验证。10 项目录选择/错误配置回归通过，覆盖同名
工具链、其他目标、错误版本、重复目标及真实 CMA/release 不符；仓库源码预检、
workflow YAML 和各 run 块 shell 语法检查通过。未修改无线驱动补丁或内核配置。
同时在编译成功但后续检查失败时上传 CS-06 `inspection` 证据包，保留镜像、
配置、清单和校验日志；此包不代表已通过验证的固件。

复现证据：`gwrt-cs06-recovery-261114-evidence/ci-kernel-selection-regression.log`。
校验修正提交 `10bc220956a4e078bd83ba64c3dec8ae4f34dc65` 已推送同分支。
新运行 https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43598266385 ，
继续 CS-06 `261114-02`、`release=false`。截至 2026-11-14 13:26 UTC，
配置生成和编译前专项检查通过，正式 `Build firmware` 进行中，尚无新成品。
新任务监测/收集状态：
`/home/godsun/build/gwrt-cs06-recovery-261114-evidence/rebuild-43598266385/delivery-status.json`。
本次仅将新增目标内核校验/测试脚本同步 NAS；NAS 不同的 workflow 继续保留。
未连接设备、刷机或重启。

## 补齐本次运行的下载后收尾

续接时重新查询 GitHub：`43598266385` / `10bc2209` 仍为 `in_progress`，
正在 `Build firmware`，配置与编译前专项测试成功，尚无新固件产物。
本地收集器一次 API 连接失败后会重试，不能据此判定云端构建失败。

已补齐只处理本 run 的后台镜像审计/归档收尾：
`rebuild-43598266385/finish-delivery.py` 等待收集器校验下载记录，随后执行
`audit-and-archive.py`，核对 FIT 内核、双无线 DTB/MLO opt-out、7 MiB factory
布局、64 KiB rootfs 对齐、实际 ath12k 模块/恢复日志和配置迁移文件；
全部通过后才归档到 `/home/godsun/build/gwrt-releases/cs06-7M/` 并记为 `archived`。
下载与镜像审计任一失败都会留证，收尾程序不会重跑 GitHub 任务或操作路由器。

本地审计原先固定要求 revision 前 8 位，已改为锚定解析
`DISTRIB_REVISION`，接受完整提交的 7–40 位十六进制前缀，以兼容云端浅克隆
生成的 7 位短 SHA；云端 provenance 仍严格绑定完整提交。
3 个有效长度及 5 个错误版本/来源用例通过；本轮尚未有镜像可做完整拆包验证。
收尾状态在同一证据目录的 `finisher-status.json`，审计日志为 `image-audit.log`，
最终镜像报告为 `image-audit.json`；隔离源码树未再修改或推送。


## 2026-11-15 再次失败：同目录的软件包被识别为内核

运行 `43598266385` 的正式编译、镜像哈希和实际编译源的 32 项恢复 / 15 项
MLO 回归全部成功；2026-11-14 15:05:13 UTC 末尾校验明确报出两个候选：
`linux-6.18.62` 和同级软件包 `linux-atm-2.5.2`。此前 `linux-*` 通配过宽，
这次失败发生在目录识别阶段，尚未检查实际目标内核 CMA，不能凭此确认 CMA 值。
失败时已保留 `inspection` 镜像和配置证据包；原运行结论仍为失败。

校验改为完整匹配数字版本的内核目录（含 rc 版本用于严格拒绝错误版本），
排除 linux-atm / linux-firmware / linux-tools 软件包，保留重复内核、版本、
实际编译 release 与 CMA64 的严格检查。新增真实 linux-atm 目录布局、只有软件包、
错误版本与多个版本的回归；旧脚本 4/15 失败，修正后 15/15 通过。
失败证据包同时补存原始目标内核 `.config` 和 `kernel.release`，避免校验失败后
丢失核实实际配置所需证据。没有改无线实现、Linux 6.18.62、CMA64 或板级 MLO 策略。
源码预检、workflow YAML 与全部 15 个 run 块 shell 语法检查通过。

负对照、正向回归和源码预检分别保存在证据根目录的
`ci-kernel-package-negative.log`、`ci-kernel-package-regression.log`、
`ci-kernel-package-preflight.log`。继续原授权 CS-06 分支重编，运行编号和结果随后补记。


修正提交 `0580ee9aa1976b81dc75933c155944b2b51aebb1` 已推送
`cs06-recovery-261114`；已触发 CS-06 `261114-02` / `release=false`：
https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43619639969 。
本轮只改 CI 内核识别、回归和失败证据保留，保持既有无线实现和内核/CMA策略。
截至 2026-11-14 17:12 UTC，运行在依赖安装阶段，尚无新成品。

停止旧运行的两个监测进程（PID与脚本路径、独立进程组核对通过），保留日志并把
状态准确记为 cloud_failed。旧收集器对已存在日志再次执行 gh 解包导致反复失败，
新收集器改为全新临时目录下载，完成后带 run/SHA/artifact 标记原子发布，重复调用
只复用来源一致的完整目录；部分下载清理、完整发布、幂等复用、来源不符拒绝均通过。
失败时独立收集日志和inspection后退出，不再因一个解包失败无限轮询旧任务。

新运行收集/严格镜像审计及归档收尾已启动，仅处理 `43619639969/0580ee9a`：
`/home/godsun/build/gwrt-cs06-recovery-261114-evidence/rebuild-43619639969/delivery-status.json`。
收尾须通过15项目录选择、原始内核配置与release、32恢复+15MLO+5无线配置记录、
实际编译源码哈希、FIT/DTB、7MiB槽位、rootfs和实际模块核查后，才归档
`/home/godsun/build/gwrt-releases/cs06-7M/`。未绕过校验将失败包交付。
旧运行401263209字节的inspection artifact已另起只读下载核查；它不含通过的内核
配置校验记录，不能替代新运行的完整校验。未连接设备、刷机或重启。

2026-11-14 17:14:30 UTC：新运行 `43619639969` 的配置生成和编译前专项检查已成功，
进入正式 `Build firmware`；尚无成品。收集器已按慢速artifact下载延长单次网络
超时至3600秒，避免大镜像下载到一半反复超时重下；仅后台传输等待，不阻塞交互。

## 2026-11-15 结果补记与实机认证失败

只读重新查询确认运行 `43619639969 / 0580ee9a` 已于 2026-11-14 19:20:35 UTC
成功结束，后台下载和严格镜像审计已完成，归档为
`/home/godsun/build/gwrt-releases/cs06-7M/`。原始离线报告和 SHA 保留。
用户随后提供 `RE-CS-06 log-11.15.rar`，运行 revision 确认就是该镜像：
7 次 PCI 崩溃均已越过整组停止屏障，6 次明确有两路 pdev 恢复完成，证明本补丁
在实机有恢复进展；但 4 份实际 dump 仍是原 `wal_tx_de_mgmt.c:338` 断言，
认证仍失败，不能将其当作稳定无线版本。详细新证据和认证路径线索见
[2026-11-15 认证诊断](WORKLOG-20261115-cs06-authentication.md)。
本次仅离线分析，没有继续改实现或重编。
