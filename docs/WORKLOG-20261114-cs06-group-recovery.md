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
修正后继续同分支 CS-06 `261114-02`、`release=false`，运行编号随后追加。
