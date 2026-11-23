# WORKLOG 2026-11-14 — CS-06 新 PCI 转储：管理帧发送断言

## 1. 结论与范围

用户补充 `/home/godsun/Downloads/RE-CS-06 log-11.14-1.rar`，其中有完整
PCI 固件转储，并且三份文本/快照日志也已更新。它对应同版本固件的**另一轮
开机复现**，07:41:34 崩溃，不是上一包 06:28:37 那次的转储。

从 RDDM 结构中的实际 `Q6-SFR` 段读到：

```text
wal_tx_de_mgmt.c:338 Assertion 0 failedparam0 :zero, param1 :zero, param2 :zero.
Thread ID : 0x0000001a
Thread name : WLAN_TX_DE
PC : 0x0122fe5c
LR : 0x0122ff04
```

**此次是 QCN9274 固件在管理帧发送相关模块主动断言，和旧 dump 的 MLO peer
空指针不是同一个异常点。** 文件名/线程指向发送路径，但尚未确定第 338 行
的具体检查条件，也没有证据确定是哪一种管理帧触发。

新日志再次出现 5G 客户端关联与 PCI 崩溃在同一秒，随后 AHB 管理帧持续
`invalid pdev`，至日志结束约 178 秒未见恢复完成。未见内存分配失败、OOM
或内核 panic；不能将这次崩溃直接归为内存不足，也不能根据关联时间单独
认定某个客户端、EHT 或 160 MHz 就是原因。

本轮仅离线分析与记录，未改固件实现、触发新编译、连接设备、刷机或重启。
不再需要以“包内缺转储”为由索取上一轮 062838 文件来继续当前分析。

## 2. 输入及可重跑证据

- RAR SHA-256：`b71f0532a2e6e7ace1e9f3e2dae9549cb3f1ac437ffda18bd8ec50690ecc8f04`。
- 解包及证据：`/home/godsun/build/gwrt-cs06-coredump-20261114-9qyo7em4/`。
- 转储文件：`20261114-074135-devcd1-0001_01_00.0.gz`，压缩后 17,467,852 字节，
  SHA-256 `f6a01e049f215835014c519257826f78c2b13916a557dbd3cef553ece90f7a9c`。
- 解压后 43,524,764 字节，SHA-256
  `067e11a76ebe66a8f2e922b784d2978ea8a0ae7c27d1d40a72b6b7e354d4e238`。
- ATH12K-FW-DUMP v2，chip `0x1109`，qrtr 24，bus 1，头长 196 字节。
- 头时间 `2026-11-14T07:41:34+00:00`，纳秒 905426513，与本次日志及设备保存
  路径对应；这里保留日志/转储时钟，不擅自换算成用户所在地时间。
- `analyze.py` 校验 dump/TLV/RDDM 边界，按结构提取 SFR、可执行段及日志统计；
  已对本次输入实际运行。输出为 `evidence/evidence.json`、`evidence/pci-sfr.txt`。
- plog.tgz 包含 310 个文件。原始内核记录去重得到 `kernel-raw-union.txt`，
  812 行，末尾 uptime 385.077188 秒；独立统计另存 `evidence/log-statistics.json`。

可重跑：

```sh
python3 /home/godsun/build/gwrt-cs06-coredump-20261114-9qyo7em4/analyze.py \
  /home/godsun/build/gwrt-cs06-coredump-20261114-9qyo7em4
```

## 3. 新日志时间线

实际运行 `261114-01/13bcc6a`，Linux **6.18.62**，CMA **64 MiB**。

| 时间 / uptime | 新 syslog 行 | 事件 |
| --- | --- | --- |
| 78.133526 秒 | 368 | `MLO disabled by board policy` |
| 07:39:41 | 637 | phy0 2.4G AP-ENABLED |
| 07:39:56、07:40:15、07:40:55 | 683、702、748 | 2.4G 客户端关联 |
| 07:41:31 | 766 | phy1 5G AP-ENABLED，之前 CAC 已成功 |
| **07:41:34** | **770** | **phy1 客户端 AP-STA-CONNECTED** |
| **206.647986 秒 / 07:41:34** | **773** | **PCI `MHI_CB_EE_RDDM` 崩溃** |
| 207.333661 秒 | 774 | 上传 coredump |
| 207.514213 秒起 | 775 | AHB 开始 `invalid pdev_id 1 in mgmt_rx_event` |
| 207.811602 秒 | 778 | AHB `invalid vdev 0 in bcn tx status` |
| 07:41:45 | 804 | 保存 `20261114-074135-devcd1-0001:01:00.0.gz` |
| 至 385.077188 秒 | 1216 | AHB 报错仍持续，没有后续 AP 恢复成功记录 |

去重内核记录中 PCI 崩溃 1 次，AHB invalid pdev 289 条，`sband is NULL`
为 **0**。共享限流 suppressed callbacks 合计 2106 次，不能当作崩溃次数。
上包的 sband warning 在这次没有出现，因此不是两次复现共同具备的必要前兆。

## 4. 转储与旧版本比较

PCI 固件仍报告：

```text
QC_IMAGE_VERSION_STRING=WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1
IMAGE_VARIANT_STRING=9224.wlanfw.eval_v2Q
OEM_IMAGE_UUID_STRING=Q_SENTINEL_{11150E3D-6D8A-45D7-99A9-8899D3623019}_20260116_122630
```

| 项目 | 旧 `京东云赵云.zip` | 本次 11.14-1 |
| --- | --- | --- |
| 异常线程 | `WLAN RT0` | `WLAN_TX_DE` |
| 异常记录 | MLO peer 空指针读取，PC `0x01967814` | `wal_tx_de_mgmt.c:338 Assertion 0`，PC `0x0122fe5c` |
| BADVA | `0x30`，与实际 load 地址算式交叉验证吻合 | `0x018d045c`，断言报告中不能独立解释为非法读取 |
| MLO global TLV 6 | 存在，12,058,624 字节 | 不存在 |
| paging 提取的可执行代码 | 与本次逐字节相同 | 与旧版逐字节相同 |

两次提取的分析 ELF SHA-256 均为
`5bab32555b95d403c1ed136bf7ad28630f44b6df32c095370816d536f6f4ce45`。
这只证明所提取的可执行段一致，不等于整个固件、运行状态或 dump 全部一致。

新 TLV 长度：paging 7,864,560，RDDM 6,291,648，host DDR 20,979,712，
pageable 7,340,032，M3 1,048,576 字节。MLO global 段消失与板级关闭策略
一致，但不能单凭这一条证明闭源固件所有 MLO 内部路径都不再执行。

RDDM 中 Q6-SFR 来自结构化段表，不是扫描到的静态格式字符串。
Q6-SRAM 从 `0x01300000` 开始；可提取的两个执行段分别从 `0x014fa000`
和 `0x017fa000` 开始，长 913,408 / 2,899,968 字节，均不覆盖当前
PC `0x0122fe5c` 与 LR `0x0122ff04`。当前可映射代码不足以恢复第 338 行
的完整判断。没有将候选 FP 链当作已验证 ABI 回溯，也没有把 BADVA 附近
反汇编冒充故障指令。

## 5. 两层故障与修复边界

第一层是 **PCI 固件内部管理帧发送断言**。现已定位文件、行号和线程；
实际触发条件尚未证实。关闭 MLO 后仍能发生其它固件异常，不能宣称此前
兼容措施已经根治闭源固件。

第二层是 **崩溃后宿主驱动整组恢复未完成**。此前已核对的源码路径仍适用：
PCI RDDM 入口仅排入当前 PCI 的 reset_work，但 core_reset 会停止并清理整个
WSI 组的 active pdev；仅减少当前成员引用后，还要等待未必已进入复位的
AHB 成员。两份新日志均显示 PCI 先崩溃、AHB 后报 invalid pdev 且无法恢复，
与这一缺口吻合；没有运行时计数/trace，仍不能断言实机精确停在 num_started=1。

修复整组恢复可以针对宿主源码推进，但它处理的是崩溃后的自恢复，不能代替
首次固件崩溃的修复，也不能简单删除同步屏障。当前 dump 不支持直接归因于
内核版本、CMA 大小、160 MHz 或 EHT 后盲目改配置重编。

前序记录：[首次 11.14 日志](WORKLOG-20261114-cs06-wifi-regression.md)、
[旧转储分析](WORKLOG-20261113-cs06-coredump.md)。
