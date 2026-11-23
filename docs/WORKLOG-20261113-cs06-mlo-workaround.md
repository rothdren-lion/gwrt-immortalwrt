# WORKLOG 2026-11-13 — CS-06 双频独立运行兼容候选

## 1. 当前结果与边界

用户在补充实际转储后要求修复。已完成本地源码兼容候选：仅 CS-06 的设备树
启用 `qcom,ath12k-disable-mlo`，驱动向两颗固件明确声明 MLO 关闭，按单 radio
分别分配 wiphy，并停止发送 MLO setup、ready、teardown 伙伴命令。保留 WSI
分组、既有保留内存与协调恢复，避免把共享内存拆成两个独立所有者。

**这是绕过已定位固件故障路径的兼容措施，会关闭跨芯片 MLO 聚合；不是对闭源
固件空 peer 原因的根治，也没有实机证明双频已经恢复。** 单链路 EHT 能力没有
由这个改动主动关闭；是否正常发射、关联和长期运行仍须设备验证。

全部固件构建继续停止。本轮没有连接设备、编译固件或模块、推送、刷机、重启。
只运行宿主机 C 函数 harness 和设备树转换检查。

## 2. 判断依据

实际 PCI 转储的 `PC=0x01967814`、`BADVA=0x30`，局部保存的空 peer 指针和
link 2 地址计算相符；AHB 转储是伙伴崩溃断言。完整反汇编证据见
`WORKLOG-20261113-cs06-coredump.md`。异常位于固件内部的 MLO peer / primary
UMAC 伙伴迁移路径，给 Linux 对象添加空值检查无法截住这条固件指令。

已核查的 315–351、906、907 等修复原本就在故障版本里，没有重复当作新增修复。
日志中两颗设备都报告 256 个 ML peer ID，但这一数值也可能来自 legacy fallback；
它不能单独证明两颗固件的 extended READY ABI 完全一致。本轮没有依据猜测去改
336 握手字段，也没有替换或二进制修改固件。

当前 NAS 配置原本为 CMA 16 MiB；故障版 `261111-01` 为 64 MiB，且用户确认
该版不再报内存错误。为避免新镜像退回已知内存症状，本次构建候选将
`target/linux/qualcommbe/config-6.18` 的 CMA 保持为 64 MiB。此举只是复用已知
可启动基线，不证明 CMA 是空 peer 崩溃的因果；MLO opt-out 与配置迁移仍是本次
无线兼容改动。

## 3. 源码改动

| 文件 | 行为 |
| --- | --- |
| `package/kernel/mac80211/patches/ath12k/352-ath12k-allow-board-MLO-disable.patch` | 任一成员有板级 opt-out 就禁止组 MLO；每次固件启动重新判断；QMI 显式传 0；关闭时伙伴链路数返回 0，覆盖 ready/teardown |
| `target/linux/qualcommbe/dts/ipq5322-re-cs-06.dts` | 仅两颗 CS-06 无线节点添加 opt-out，不改 WSI graph、radio 数或内存布局 |
| `target/linux/qualcommbe/config-6.18` | 将 CMA 维持在 `261111-01` 的 64 MiB，避免回退已消失的内存报错；不代表确认其为无线崩溃根因 |
| `package/kernel/mac80211/Makefile` | release 15 → 16 |
| `target/linux/qualcommbe/ipq53xx/base-files/usr/libexec/gwrt-cs06-radio-config` | 将已知旧共享 wiphy 配置迁移到两个独立设备，仅改硬件绑定 |
| `package/network/config/wifi-scripts/files/etc/hotplug.d/ieee80211/10-wifi-detect` | CS-06 加事件在锁内先迁移，再运行原 wifi config；保留既有 SS-01 分支 |
| `package/network/config/wifi-scripts/Makefile` | release 2 → 3 |
| `scripts/tests/test-gwrt-ath12k-mlo-policy.py` | 提取实际驱动函数运行离线回归 |
| `scripts/tests/test-gwrt-cs06-radio-config.py` | 运行实际 hotplug/helper，模拟 UCI 与 sysfs |

原日志的 5G 配置使用 AHB path 加 `radio=1`。拆分后 PCI 自己的 radio 不能继续用
该绑定。helper 从 `/sys/class/ieee80211/*/device` 的真实链接获得 PCI path，仅
迁移仍指向 AHB 的已知旧 `5g:1` 组合，清除旧 radio/phy 选择器；2G 清除旧
`radio=0` 选择器。SSID、密码、接口、频宽等选项不改，用户自定义的其他 path
不迁移。PCI 尚未注册时保留旧 5G 绑定，后续 add 事件重试。

设备当前使用 UCODE Wi-Fi 脚本，其 iwinfo 包装器不支持原生 `nl80211 path`
命令，因此 helper 直接使用 sysfs/readlink。CS-06 预设的
`CONFIG_BUSYBOX_DEFAULT_FLOCK=y` 支持 hotplug 的锁操作。

## 4. 离线验证与可复现命令

证据目录：`/home/godsun/build/gwrt-cs06-fix-20261113/`。

从本地 backports 7.2 归档提取 ath12k，按名称顺序应用现有全部 ath12k 补丁，
包括本次 352，共 **110 个补丁，零 fuzz，无失败**；没有运行 make。
最终投影的 core.c、qmi.c、mac.c 与隔离候选逐字节一致。

```sh
python3 /home/godsun/build/gwrt-cs06-fix-20261113/prepare.py \
  /mnt/syNAS/Dowloads/Rout/mark/immortalwrt \
  /home/godsun/build/immortalwrt-mt7981/dl/backports-7.2.tar.zst \
  /tmp/cs06-ath12k-review-new

python3 scripts/tests/test-gwrt-ath12k-mlo-policy.py \
  /tmp/cs06-ath12k-review-new/backports-7.2/drivers/net/wireless/ath/ath12k
python3 scripts/tests/test-gwrt-cs06-radio-config.py
```

- 15 项实际 C 函数回归通过，开启 UBSan；覆盖首/末成员 opt-out、单芯片、恢复、
  三芯片、既有正常 MLO、无 OF node、固件不支持 MLO 与 FTM。关闭时验证显式
  QMI 0、伙伴命令不发送、两颗设备分别分配 wiphy；保留组成员数量。
- 修改前相同测试有 9/15 项失败，记录 `negative-control.txt`。
- 5 项配置回归通过，覆盖保留配置、AHB 先于 PCI 注册及后续重试、其他机型、
  remove 事件、自定义绑定；每项验证幂等与其他选项完全一致。
  修改前记录 `negative-radio-config.txt` 复现旧绑定保留的问题。
- 当前 CS-06 DTS 转换为 DTB 成功，对比迁移前只增加两个 opt-out；所有原有属性
  包括内存与 WSI graph 一致。共用 include 的 GL/Xiaomi BE6500 没有 opt-out。
  该检查使用本地现成 **Linux 6.18.55** 的已准备 DTS 依赖；原有 3 项重复地址
  warning 仍在，不能替代目标 **6.18.62** 的完整编译或绑定校验。
- shell 语法检查、改动差异检查通过。没有做整模块交叉编译和实机验证。

输出：`source-verified/patch-application.json`、`positive-control.txt`、
`positive-radio-config.txt`、`test-results.json`、`dtb-validation.json`、
DTB 前后副本与 DTC stderr。原用户配置和转储未加入仓库。

## 5. 回滚与后续验证

既有文件的本轮前副本在证据目录的 `before-files/`，含 mac80211/wifi-scripts
两个 Makefile、CS-06 DTS、10-wifi-detect 与 AGENTS.md。回滚只还原上述源码文件
并移除本次 352、helper；其他并行工作和原有 dirty 改动不得覆盖。记录与测试可留档。

用户现已要求开始构建。本次应以 Linux 6.18.62 和 CMA 64 MiB 为基线；之前误选
6.18.55 的尝试已中断，未生成固件。实机验收要确认 board-policy 日志、
两个独立 PHY 正确对应 2.4G/5G、保留配置无额外重复 radio、分别关联上网，并
观察首次启动和无线 reload 后是否还出现 MLO 断言。关闭 MLO 后如果固件仍发生
同一路径异常，须继续检查固件是否遵守 QMI 0 及独立运行时的内存请求，不继续
堆叠猜测补丁。
