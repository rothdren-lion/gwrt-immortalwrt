# WORKLOG 2026-11-11 — AN7581 CPU PLL 超频实机验证

## 1. 任务背景

用户要求在 `192.168.3.3` 的 AN7581 设备上实测 CPU 超频接口。测试只短时修改运行时 PLL；不刷机、不改持久配置。

## 2. 操作过程

- SSH `system board` 核实目标为 FiberHome HG5585F CT，`fiberhome,hg5585f-ct`，固件 GWRT `261110-07`，内核 `6.18.62`，AN7581 / EN7581。
- 设备已有 `luci.airoha_npu` RPC、`/sbin/devmem` 和 `/dev/mem`。原始 cpufreq policy 为 `ondemand`，下限 500 MHz，上限 1200 MHz。
- 使用 `/tmp/gwrt-an7581-oc-check-20261111.sh` 测试。测试先核对具体板型和 boot ID，设置 PLL 后固定四核各运行 4 MiB 数据的 SHA-256 校验循环；每 5 秒直接读回 PCW、PLL 分频、CPU 时钟源和温度。退出时把 PLL 写回 1200 MHz，并恢复原始 governor 和 cpufreq 上下限。
- 四核计算测试期间，连续对路由器 ping 180 次，丢包 0/180。测试前后 boot ID 相同；未观察到测试期间新增的 dmesg 行。

## 3. 结果与验证

| PLL 目标 | 持续时间 | 四核 SHA-256 校验次数（CPU0–3） | 最高采样温度 |
|---|---:|---|---:|
| 1200 MHz 基线 | 30 秒 | 223 / 223 / 223 / 221 | 46.2°C |
| 1300 MHz | 61 秒 | 478 / 485 / 486 / 480 | 47.9°C |
| 1400 MHz | 121 秒 | 1034 / 1044 / 1040 / 1032 | 50.2°C |

三档 RPC 均返回 `result=ok`，直接寄存器读回分别为 1200、1300、1400 MHz；CPU mux 读回均指向 ARMPLL。所有计算校验通过。1400 MHz 的短时负载与 180 次连通性检查未触发 SSH 中断、丢包或新增内核日志。

测试后先由脚本写回 1200 MHz 并恢复原 policy。独立 PLL 回写检查会将 governor 设为 `performance`，因此随后又明确写回 `ondemand`。最后读回 policy 为 `ondemand` / 500000 / 1200000；设备未重启。之后空闲 PLL 按 ondemand 动态变化，这是预期行为。

## 4. 文件与回滚

- 测试脚本和 host 端完整输出：`/home/godsun/build/an7581-oc-20261111/`。
- 设备端临时测试脚本：`/tmp/gwrt-an7581-oc-check-20261111.sh`。
- 恢复 policy 的命令：

```sh
ubus call luci.airoha_npu setOverclock '{"freq_mhz":"1200"}'
echo 500000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
echo 1200000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
echo ondemand > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
```

确认恢复 governor 时，设置 PLL 的 RPC 可能会再次切换到 `performance`；恢复顺序应为先写 PLL，最后设置 governor。

## 5. 结论与待办

- 该实机支持通过 `luci.airoha_npu setOverclock` 写 CPU PLL，且本次在 1400 MHz 短时四核负载下正常。
- 这不是长期稳定性或寿命认证。硬件没有此接口可用的电压控制；1600 MHz 软件上限未测试，不应视为稳定频率。保持默认 1200 MHz policy；更高频率需运行时手动设置，本插件不持久化。
- 本次只完成短时实机验证；未做长时间老化、路由吞吐基准或刷机。
