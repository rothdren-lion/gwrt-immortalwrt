# WORKLOG 2026-11-14 — CS-06 双频启动后 PCI 固件崩溃

后续补充：用户提供 `RE-CS-06 log-11.14-1.rar`，包含同版本另一次开机复现
的实际 PCI 转储和更新日志。已结构化解析出 `wal_tx_de_mgmt.c:338` /
`WLAN_TX_DE` 断言，与旧 MLO peer 空指针不同；本记录末尾索取转储的需求已
由新包补足。详见 [新 PCI 断言分析](WORKLOG-20261114-cs06-pci-assert.md)。

## 1. 结果与验证边界

用户刷入本轮 GitHub 编译的固件后反馈“wifi 出来了，但还是有问题”，提供
`/home/godsun/Downloads/RE-CS-06 log-11.14.rar`。日志确认版本为
`261114-01 / 13bcc6a`，Linux **6.18.62**，CMA **64 MiB**，板级 MLO
关闭策略已经运行，2.4G 和 5G 都有 AP-ENABLED，且都有客户端关联记录。

**兼容改动解决了本次启动时双频无法启用的现象，但没有解决无线稳定性：
5G 客户端关联的同一秒，PCI QCN9274 固件发生一次 RDDM 崩溃；之后两路无线的
恢复没有完成，AHB 持续丢弃管理帧。** 本日志中没有内存分配失败、OOM 或内核
panic，不能把此次故障直接归为先前的内存不足。

本轮仅离线读取日志、检查对应驱动源码并记录结论。没有修改固件实现、触发
编译、连接设备、刷机或重启。此前用户的 CS-06 推送/编译授权及实际刷入结果
已使历史记录中的“尚未推送/构建/实机验证”不再代表当前交付状态；历史记录中
关于闭源固件根因未解决的边界仍成立。

## 2. 输入与独立复核

- RAR SHA-256：`c47008e2129978105da43c2ac03dc3c36bc5292164be74f257ae793b5b017727`。
- 解包及证据目录：`/home/godsun/build/gwrt-cs06-log-20261114-gV9I8d/`。
- 顶层为 kernel/syslog 两份汇总和 plog.tgz；tgz 内有 424 个 `.log` 快照，
  没有实际固件转储 `.gz`。
- 原始快照按内核时间及消息去重得到 `kernel-raw-union.txt`，共 1097 行，
  覆盖开机至 uptime `499.752961` 秒，与汇总中的主要故障一致。
- `analysis-statistics.json` 保存独立统计：PCI RDDM 崩溃 1 次，AHB
  `invalid pdev_id 1 in mgmt_rx_event` 567 条，beacon 的 invalid vdev 4 条，
  sband 异常 2 条。限流合计 suppressed callbacks 7764 次，不能把该数字当作
  崩溃次数，也不能把共享限流的全部计数归给单一报错。

当前用于核对的 ath12k 源码投影：
`/home/godsun/build/gwrt-cs06-fix-20261113/source-verified/backports-7.2/drivers/net/wireless/ath/ath12k/`。
已核对 NAS 与已发布隔离树
`/home/godsun/build/gwrt-cs06-github-261114/` 的全部 110 个 ath12k 补丁，
文件名及 SHA-256 均相同。发布源码提交为
`13bcc6ab44120954ade944cc1ec913eddc06eb58`，GitHub 构建运行为 `43476544016`。
本轮没有重新查询 CI；实际启动日志中的 revision 确认了用户刷入的版本。

两颗固件分别报告：

- AHB/IPQ5332：`WLAN.WBE.1.7-01733-QCAHKSWPL_SILICONZ-1`。
- PCI/QCN9274：`WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1`。

## 3. 故障时间线

墙钟存在启动后校时，先后关系以内核单调时间及同一 syslog 的顺序为准。

| uptime / 日志墙钟 | 事件 | 含义 |
| --- | --- | --- |
| 78.150168 秒 | `WSI group 0: MLO disabled by board policy` | 关闭 MLO 的候选确已生效 |
| 约 93.96 秒 / 06:26:54 | phy0 2.4G AP-ENABLED，信道 6，2437 MHz | 板载无线已启动 |
| 06:27:37 | 客户端在 phy0 认证、关联、AP-STA-CONNECTED | 2.4G 有关联成功记录 |
| 144.434529 秒附近 / 06:27:44 | phy1 CAC 成功，5G AP-ENABLED | 5G 信道 36 / 160 MHz 已启用 |
| 149.719542、151.950845 秒 | PCI `sband is NULL ... channel_num 6 center_freq 2437 pdev_id 0` | 崩溃前已有收包频段不匹配，需要另查 |
| 06:27:55 | 同客户端从 phy0 断开 | 发生在 5G 关联前 |
| 06:28:37 | 同客户端在 phy1 认证、关联、AP-STA-CONNECTED | 5G 关联本身已有成功日志 |
| **197.458876 秒 / 06:28:37** | **PCI `firmware crashed: MHI_CB_EE_RDDM`** | **本包中唯一明确 PCI 崩溃** |
| 198.164218 秒 | PCI Uploading coredump | 转储流程启动 |
| 198.381659 秒起 | AHB `invalid pdev_id 1 in mgmt_rx_event` | 在 PCI 崩溃之后才出现 |
| 198.391054 秒起 | PCI WMI/beacon 命令失败，后续返回 `-108` | 已崩溃设备的命令通道不可用 |
| 06:28:43 | coredump 服务确认保存 PCI 转储 | 包内只有保存记录，没有转储本体 |
| 至 499.752961 秒 | AHB 管理帧错误持续，无重新启动成功或第二轮 AP-ENABLED | 崩溃后至少约 302 秒未见恢复完成 |

不能仅凭“关联与崩溃在同一秒”认定某种客户端行为是可重复触发条件。当前证据
支持时间相关性，尚缺转储内部异常点及复现结果。

## 4. 恢复代码中的缺口

`mhi.c:ath12k_mhi_op_status_cb()` 的 RDDM 分支只给**当前 PCI** 设置
CRASH_FLUSH/RECOVERY 并排入其 reset_work，没有在此入口让存活的 AHB 一同
进入复位。

`core.c:ath12k_core_reset()` 的行为则仍以整个 WSI 组为恢复单位：

1. pre_reconfigure_recovery 遍历全组 wiphy，停止发送队列；
2. post_reconfigure_recovery 遍历全组，将 ON 状态的 radio 交给 core_halt；
3. core_halt 清空对应 AHB/PCI 的 `pdevs_active[ar->pdev_idx]`；
4. 只对当前 ab 关闭中断、power_down，并减少该成员的 group 引用；
5. 若 `ag->num_started > 0`，等待其它成员 reset 后直接返回；只有计数归零
   才会为全组重新 power_up。

因此，**存在“PCI 单成员崩溃，清理全组后等待未进入 reset 的 AHB”的恢复
停滞路径**。关闭 MLO 后，本次没有记录先前的 AHB 伙伴崩溃断言，存活的 AHB
未必再被固件主动拉入恢复。现有 ahb.c 的 group recovery helper 覆盖 AHB
userPD fatal/rootPD 恢复入口，不能保证 PCI 单独 RDDM 入口会触发它。

`wmi.c:ath12k_mgmt_rx_event()` 通过当前设备的 active pdev 查找 radio，查找
失败就打印 invalid pdev 并丢帧。这解释了为何 PCI 崩溃后 AHB 仍产出事件，
却开始持续报 invalid pdev。WMI 发送代码在 CRASH_FLUSH 时返回
`-ESHUTDOWN`，也与日志中的 `-108` 一致。

**代码确认此缺口存在，日志现象与其吻合；但实际停在哪个分支仍是推断。**
等待 partner 的消息只有 BOOT debug 级别，本包没有运行时计数/调用栈，不能
声称已通过实机 trace 证明 num_started 停在 1。修复应统一协调组成员进入
reset，并处理重复恢复/注销/生命周期；不能简单删除计数屏障或拆分共享内存
所有权。

## 5. 首次 PCI 崩溃仍需新转储

崩溃前的 sband warning 来自接收描述符的 channel/center_freq 与当前 wiphy
支持频段不符。`dp_rx.c:ath12k_dp_rx_h_ppdu()` 在这种情况下尝试回退到
`ar->rx_channel`。本次 PCI 路径得到 2437 MHz 元数据值得检查，但该条 warning
既不能单独证明固件仍启用了 MLO，也不能证明它是 47 秒后崩溃的原因。

先前 `京东云赵云.zip` 的 PCI 转储明确显示 MLO peer 路径的空指针读取
（PC `0x01967814` / BADVA `0x30`）；本次文本没有 PC、BADVA 或寄存器，
**不能断言还是同一内部异常**。

日志明确记录了设备上这份新文件：

```text
/root/coredumps/20261114-062838-devcd1-0001:01:00.0.gz
```

需要用户从设备取出并补充这一份文件，以确认此次内部异常点并与旧 dump
逐项对照。设备不在本机网络，不尝试连接其它路由器代替获取。

## 6. 其它报错

- `firmware-2.bin` 缺失：fw.c 的 API2 请求失败会回退 API1；AHB 随后已实际
  运行并启用 AP，不能据此认定“缺主固件导致 Wi-Fi 不起”。
- DFS state 警告之后有 CAC success 和 5G AP-ENABLED，本次不是 CAC 未通过。
- gwrt-agent 的 HTTP 401 / unknown device or token 是注册或令牌相关报错；
  NFS instance2 crash loop 6 次也需要另行处理，不能当作无线固件崩溃的证据。
- 启动时一次 PCIe Correctable RxErr 不足以确认硬件损坏。
- 崩溃后仍有有线 DHCP/SSH 记录，没有系统整体死机的证据。

前序记录：[MLO 兼容候选](WORKLOG-20261113-cs06-mlo-workaround.md)、
[旧固件转储分析](WORKLOG-20261113-cs06-coredump.md)。
