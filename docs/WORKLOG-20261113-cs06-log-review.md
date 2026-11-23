# WORKLOG 2026-11-13 - CS-06 261111-01 新日志复核

后续用户补充了含真实转储的 `京东云赵云.zip`，分析见
[CS-06 coredump](WORKLOG-20261113-cs06-coredump.md)。下文“ZIP 不含转储”仅指
本记录原始输入；后续已定位 PCI 固件 MLO peer 路径的 `0x30` 无效读取。

## 1. 任务背景

复核用户提供的 `/home/godsun/Downloads/gwrt-261111-01-re-cs-06.zip`，并与
261110-01（CMA 16 MiB）和 261111-01（CMA 64 MiB）的已有镜像、日志对照。
本次只读分析，不编译、不刷机、不重启设备。

## 2. 输入与范围

ZIP 只有三个文本文件：

```text
.../dmesg.txt       1237 行
.../syslog.txt       958 行
.../wifi_debug.txt   998 行
```

没有 PCI 或 remoteproc 的 `.gz` 固件转储。日志不是从开机开始采集：

- `dmesg.txt` 首行 uptime 为 `1082.688953` 秒；
- `syslog.txt` 首行 uptime 为 `1124.558793` 秒；
- `wifi_debug.txt` 首行 uptime 为 `1109.948409` 秒。

所以本 ZIP 不能证明本次启动的第一次崩溃触发点。

## 3. 直接证据

### 3.1 64 MiB 版本仍在无线固件恢复循环

`dmesg.txt` 可见 remoteproc crash `#70` 至 `#77`，`syslog.txt` 可见 `#73` 至
`#78`。每轮基本顺序相同：

1. PCI 单设备限制到 `1` 个 service-ready radio（不能由此判断两芯片 MLO 是否成立）；
2. AHB/PCI 都报告 `256 ML peer IDs`；
3. `ieee80211 phy0: Hardware restart was requested`；
4. IPQ5332 AHB 固件报告 `platform_mlo.c:2038 Assertion !partner_chip_crash_ind failed`；
5. PCI 报 `firmware crashed: MHI_CB_EE_RDDM`；
6. remoteproc 恢复，约 `1.22` 秒后再次进入同一序列。

可见的 PCI 崩溃时间为 `1086.444604` 至 `1210.729563` 秒，连续间隔约
`12.5-14.9` 秒。恢复后反复出现 `WSI group 0: MLO enabled for 2 devices`，
但没有稳定的 AP/无线接口启动记录。

### 3.2 新增的第 73 次异常

在 uptime `1128.565766` 秒（`remoteproc` crash `#73`）出现：

```text
Exception detected PName:wlan0 TName:WLAN RT0
PC    0xb00c8ca8
LR    0xb00c8bf4
SSR   0x01b70170
BADVA 0x00000010
```

Hexagon V73 参考手册把异常码 `0x70` 定义为读侧 TLB miss；这里 `SSR` 的低字节为
`0x70`，`BADVA=0x10` 与固件执行了一次接近空地址的无效读相符。这个现象能说明
固件在恢复/MLO 路径中发生了非法内存访问，但没有源代码、寄存器快照或转储内容，
不能据此确定具体的悬空对象或最初触发者。

### 3.3 内存问题在这份窗口中没有出现

三个文件中没有 `cma_alloc`、`ENOMEM`、`Out of memory` 或 `page allocation failure`。
这只说明本次采集窗口没有记录 CMA 分配失败，不能证明整次启动从未发生过内存压力。
它与前一份 261111-01 全量日志中“64 MiB CMA、无 CMA 分配失败”一致。

### 3.4 转储确实曾被保存，但 ZIP 没带本体

`syslog.txt` 记录了以下保存路径：

```text
20261113-043328-devcd109-remoteproc0.gz
20261113-043335-devcd110-0001:01:00.0.gz
20261113-043343-devcd111-remoteproc0.gz
20261113-043355-devcd112-remoteproc0.gz
20261113-043402-devcd113-0001:01:00.0.gz
20261113-043410-devcd114-remoteproc0.gz
20261113-043423-devcd115-remoteproc0.gz
20261113-043429-devcd116-0001:01:00.0.gz
```

按当前设备的保留脚本，通常只保留最后四个压缩转储；但本次压缩包只含文本，无法做
固件寄存器、线程栈或故障地址的进一步符号化分析。

## 4. 与两版固件的结论

已完成的实际镜像比较仍然成立：两版的 ath12k 固件文件、ath12k/mac80211/cfg80211
模块、CS-06 DTB、wpad、netifd、无线脚本均逐字节相同。归一化构建元数据后，内核
唯一有行为意义的差异是 `CONFIG_CMA_SIZE_MBYTES` 对应的指令从 `16 MiB` 改为
`64 MiB`。

因此，这份新日志没有发现“漏装无线驱动、换错固件或设备树不匹配”的新证据；它反而
把 261111-01 的症状确认得更完整：无线固件在 MLO 初始化/恢复路径中反复崩溃，内核
和 hostapd 没有得到稳定的无线服务，故用户看到 Wi-Fi 不出来。

当前最可疑的回归变量仍是 CMA 从 16 MiB 增至 64 MiB；它可能影响 DMA/内存布局或
时序，但这仍是相关性判断，不是已证实的根因。没有足够证据将第 73 次非法读认定为
恢复后的次生损坏，也不能单独证明 CMA 就是第一触发点。后续 PCI 转储在同源 MLO
peer 处理路径发现了相似的空对象读取，详见后续记录。

## 5. 后续判别力最高的证据

1. 同一源码和配置下，仅对照 CMA 16 MiB 与 64 MiB，并保留从 uptime 0 秒开始的日志。
2. 在设备上直接导出最后四个 `/root/coredumps/*.gz`，尤其是
   `0001:01:00.0` PCI 转储和与第 73 次异常相邻的 `remoteproc0` 转储。
3. 保留第一次 `MLO enabled`、第一次 `Hardware restart`、第一次断言之间的完整顺序，
   不要只收集恢复后的 ring 诊断。

## 6. 结果边界

本轮没有修改源码、没有触发任何构建、没有刷机或重启。新日志只能把故障确认到
“64 MiB 版本的 ath12k/MLO 固件恢复循环”，不能在没有首启日志和 `.gz` 转储的情况下
进一步声称第一现场的具体 DMA 地址或固件对象。

