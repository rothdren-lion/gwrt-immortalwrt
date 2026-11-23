# WORKLOG 2026-11-13 — CS-06 / 京东云赵云实际固件转储分析

## 1. 结论与范围

用户提供的 `/home/godsun/Downloads/京东云赵云.zip` 这次包含实际固件转储。
PCI QCN9274 固件在 `WLAN RT0` 线程发生 `PC=0x01967814`、`BADVA=0x30`
的无效读取。故障指令、局部保存寄存器和对象地址计算相互吻合：peer 对象为空，
link index 为 2，仍尝试读取 `peer + 16 * link_index + 0x10`，得到地址 `0x30`。
代码属于与板载固件 MLO peer / primary UMAC 迁移伙伴链路处理函数高度同源的路径。

三份板载转储包含已展开参数的 `platform_mlo.c:2038` 伙伴芯片崩溃断言，PCI
转储则记录实际读取异常。两者说明整组无线崩溃恢复，能解释 Wi-Fi 无法稳定启动。
这不等于证明 PCI 是本次开机第一次崩溃的最初触发者，也未证明空对象由 CMA 引起。

本轮仅离线读取用户文件、历史镜像和源码，保存分析脚本与项目记录。
**没有连接设备、修改固件实现、触发构建、刷机或重启。全部固件构建继续停止。**

## 2. 输入与时间边界

ZIP SHA-256：
`3744bbf325e682555ddab7c9f3ffa0c7b37f1c6a82d240a944f0b17939eddccf`。

| 内层文件 | SHA-256 |
| --- | --- |
| `coredumps.tar.gz` | `396d59e750e9f643b58a847dce1124d85aeaa2641aadb5611db69a7e4f0cef2b` |
| `diag_logs.tar.gz` | `3d32673454961267c54297ae32fd5364facc8e9576b1a979ee271d9087b16c5e` |

实际转储文件：

```text
20261113-104229-devcd39-remoteproc0.gz
20261113-104241-devcd40-remoteproc0.gz
20261113-104247-devcd41-0001:01:00.0.gz
20261113-104255-devcd42-remoteproc0.gz
```

文本日志另包含 `dmesg.txt`、`logread.txt`、`system_info.json`、
`proc_cmdline.txt` 和 `wireless_config.txt`。dmesg 窗口为 uptime
`1053.980799–1149.636484` 秒、crash #71–#78；logread 的内核窗口为
`1080.066855–1149.636484` 秒、crash #73–#78。

转储 devcd39–42 早于日志里提到的 devcd109–116；不能把这个 PCI 转储直接配到
文本的第 73 次崩溃。新包第 73 次是伙伴断言；前一份 ZIP 中板载
`PC=0xb00c8ca8/BADVA=0x10` 来自另一次启动，不混为同一事件。

## 3. PCI 转储解析与实际异常

依照本地 ath12k `coredump.h`、`pci.c` 解析，文件头为 `ATH12K-FW-DUMP`，
version 2，chip ID `0x1109`，qrtr 24，bus 1。解压后共 55,583,396 字节，SHA-256：
`f9715aaaadfc10469362cc50cc7fd7d775cd45b26865151e6b3fb30bf25b49d9`。

| TLV type | 内容 | 字节 |
| --- | --- | ---: |
| 0 | paging / 下载固件 | 7,864,560 |
| 1 | RDDM | 6,291,648 |
| 2 | host DDR | 20,979,712 |
| 3 | pageable | 7,340,032 |
| 4 | M3 | 1,048,576 |
| 6 | MLO global memory | 12,058,624 |

RDDM header version 1、header size 392；每项 64 字节，包括 physical、virtual、
size、description 和 filename。第一项 `Q6-SFR` 是格式化的实际故障记录，
不能与其他区域中含 `%s/%x` 的静态格式字符串混淆：

```text
WLAN.WBE.1.6-01270-QCAHKSWPL_SILICONZ-1
IMAGE_VARIANT_STRING=9224.wlanfw.eval_v2Q
Exception detected
Thread ID 0x1e, WLAN RT0, Process ID 255
SP    0x01623d98
FP    0x01623e10
PC    0x01967814
SSR   0x00007003
BADVA 0x00000030
LR    0x019677cc
```

这里是 PCI 固件自己的异常格式；未把它的 SSR 位布局照搬成前一份板载异常的解释。

## 4. 指令、保存区和空对象读取

paging offset `0x93000` 是 Hexagon ELF，machine 164；包含 PC 的段 virtual base
`0x017fa000`，file offset `0x105000`。把原字节包装为仅供分析的 ELF sections，
使用本机 `llvm-objdump` 反汇编，没有重编译或更改固件 payload。

关键代码：

```text
019677c4  call 0x1549668          ; peer lookup，输入取自消息 +4 的半字
019677cc  r18 = r0
019677d4  r21 = extractu(r2,4,20) ; link index
019677d8  r2 = r21 << 4
019677dc  r22 = r0 + r2 + 0x0c
019677e4  非 0x37 消息分支跳到 0x1967814
019677e8  此处才检查 r18 == 0，仅覆盖另一分支
01967814  { call 0x1557280;
01967818    r0 = memuh(r22 + 4);
0196781c    r1 = memub(r16 + 0x85); }
```

Hexagon 的 PC 指向整个执行 packet，因此 PC 为 `0x1967814` 时，无效读位于
同 packet 的 `0x1967818`，并不表示已经进入 call 的被调函数。

SRAM `0x01372bc0` 附近的保存区同时包含与 SFR 相符的 PC/FP/LR/SP。对其中
callee-saved 寄存器簇作局部推导，未宣称已取得完整厂商 QuRT context ABI：

| 寄存器 | 保存地址 | 值 | 交叉核对 |
| --- | --- | --- | --- |
| r18 | `0x01372c28` | `0` | lookup 返回对象 |
| r20 | `0x01372c20` | `0x01305068` | 与本函数常量赋值完全一致 |
| r21 | `0x01372c24` | `2` | 与共享消息位域吻合 |
| r22 | `0x01372c18` | `0x2c` | `0 + 2 * 16 + 12` |
| r16 | `0x01372c30` | `0x016a7a40` | 本函数保留的首个参数 |
| r17 | `0x01372c34` | `0x33746534` | 消息地址 |

8 项交叉核对（PC/FP/LR/SP、r20 常量、消息 link、对象地址、BADVA）均通过。
据此可把异常定位为：空 peer 对象上计算链路字段，随后读到 `0x30`。
尚未定位对象为空的上游原因。

MLO dump 以推导的 PCI virtual base `0x33000000` 读取，消息前两字为
`0x00000233 / 0x142d8518`：type `0x33`、link 2、待查 ID `0x8518`。
host DDR 推导 base `0x04000000`，lookup global 指向 `0x040f4740`，相应表上限为 256。
这些与对象查找失败相符，是共享消息内容/生命周期的进一步线索。
**这两个虚拟映射由内容交叉推导，且共享区可能在 PCI 停止后、收集转储前被伙伴修改；
不能把消息快照直接当成首次触发时的数据，不能据此断言 DMA 越界或版本 ABI 不匹配。**

## 5. 与板载固件的对应关系

三份 remoteproc 转储均为单 PT_LOAD ELF core，physical/virtual base `0x4a900000`，
payload 43 MiB。实际已格式化的断言可在文件 offset `0x13dcb4` 等位置找到：
`platform_mlo.c:2038 Assertion !partner_chip_crash_ind failedparam0 :zero,...`。

历史镜像的板载 `q6_fw1.b02` 中，前一份日志的 `0xb00c8ca8` 所在函数与 PCI
`0x01967814` 函数结构高度一致。板载函数的 debug descriptor `0xb04f36c0`
指向以下真实字符串与源文件名：

```text
wal_ml_peer_pri_umac_mig_notify_partner_link_handler
wal_ml_peer_umac_migration.c
```

两者均先 peer lookup、计算 link slot，在非特定消息分支中未经该对象的空值检查
就读取 `slot + 4`。PCI 308 字节故障代码片段也与实际镜像的 QCN9274
`firmware-2.bin` IE 2 AMSS 中对应片段逐字节一致；没有声称整个 paging TLV 与
AMSS 相同。PCI 固件没有直接可用的函数符号，完整函数名由板载同源实现佐证。

这支持 MLO peer / 伙伴消息处理是具体故障路径，不能由此证明所有恢复轮次具有
完全相同的触发者或先后关系。

## 6. 内存、配置及回归判断

系统快照 uptime 1152 秒，free 211,492,864 字节（约 201.7 MiB），available
508,022,784 字节（约 484.5 MiB）。新文本窗口没有 CMA allocation failure、OOM
或 ENOMEM。两路 radio 与 AP 都为 disabled=0，配置为 2.4 GHz EHT40 / 5 GHz
EHT160。此证据不支持把当前现象简单解释为系统总内存耗尽或配置关闭无线；
仍不能排除固件内部对象、特定 DMA 分配或共享内存生命周期问题。

此前真实镜像比对仍成立：261110-01/d9e8632 与 261111-01/486d85c 的无线固件、
模块、DTB、wpad、netifd 和无线脚本相同；归一化元数据后，内核唯一行为差异是
CMA 16 MiB → 64 MiB。因此 CMA 仍是首要回归变量，**本次 dump 未建立它与空 peer
的因果链**。后续诊断应追 MLO 消息/peer 生命周期，以及首次启动与恢复状态的差异；
如恢复实机验证，应一次只改变 CMA，并保留第一次异常的日志和转储。

修正先前判断：`limiting service ready radios to 1` 只表示 PCI 单设备限制到一个
radio，不能据此断定两芯片 MLO 未形成；也没有证据把前一包第 73 次板载非法读
预先归为“次生错误”。

## 7. 可复核文件与命令

持久证据目录：`/home/godsun/build/gwrt-cs06-coredump-20261113/`。

```sh
python3 /home/godsun/build/gwrt-cs06-coredump-20261113/analyze.py \
  '/home/godsun/Downloads/京东云赵云.zip' \
  /home/godsun/build/gwrt-cs06-coredump-20261113/evidence
```

输出包括 `evidence.json`、`pci-sfr.txt`、`pci-fault.asm`、`pci-lookup.asm`、
`pci-code-analysis.elf`。另存 `firmware-binding.json` 和
`ahb-homologous-function.asm`，记录镜像字节对应和板载同源函数。
分析输出不含无线密码等配置秘密；原 ZIP 与内存转储不加入仓库。

临时完整解包目录：`/tmp/gwrt-cs06-dumps-20261113-lwxdfjwa/`；历史镜像拆包：
`/tmp/gwrt-cs06-version-compare-Eox688WQ/`。NAS 本轮只新增本记录并修正旧诊断文档、
更新 AGENTS 索引，不触碰已有固件源码改动。
