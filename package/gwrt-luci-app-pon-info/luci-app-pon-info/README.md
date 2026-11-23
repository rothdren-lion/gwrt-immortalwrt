# luci-app-pon-info

只读采集光口 PON 参数并记录状态变化，用于换猫前核对参数、排查光路问题。

## 组成

| 文件 | 作用 |
| --- | --- |
| `/usr/sbin/pon-info` | 采集器（ucode）。`json` 全量、`record` 采样落盘、`history [N]` 读历史、`clear` 清空、`show` 终端查看 |
| `/usr/libexec/pon-info-recorder` | 采样循环，每 `interval` 秒调用一次 `record` |
| `/etc/init.d/poninfo` | procd 服务，开机自启并守护采样循环 |
| `/usr/share/rpcd/ucode/luci.pon-info` | ubus 对象 `luci.pon-info`，方法 `status`/`history`/`record`/`clear` |
| `/www/luci-static/resources/view/poninfo/log.js` | 页面：身份、光口、OMCI、接口统计、历史、UCI 配置、原始参数、日志 |

## 支持的后端

PON 平台设备目录按名字发现：先试 `/sys/bus/platform/devices/*.pon`，再试 `/sys/devices/platform/*.pon`，
选中同时有 `state` 或 `optical` 的那个。RTL9617C（TYFZA1）落在 `4f5500000.pon`；Airoha EN7581 等只要驱动
导出同名平台设备即可采集，缺失的 sysfs 文件按"不可读"处理，不会报错。

若存在厂商 PON 用户态工具（`airoha-ponctl`、`ponctl`、`airoha-pond`），会把 `status` 的原始文本一并记进
`backend.vendor`，作为 sysfs 之外的补充证据。

## 采集内容

- 身份：`mode`、SN（配置值/生效值/hex）、`equipment_id`、硬件/软件版本、运营商 ID、OMCC 版本、ONU MAC、数据 MAC，以及认证字段是否已配置（LOID/LOID 密码/PLoAM 密码/Registration ID/OMCI PSK）
- 光口：`optical`（rx_los/tx_fault/module_absent 等）、`transceiver` 原始寄存器值（接收/发射光功率、温度、电压、偏置电流，原始值与换算值都保留）
- 链路：`state`、`ploam`、`fec`、`pm_counters`、`data_path`、`serdes`、`llid_table`、`itu_paths` 等
- OMCI：`/var/run/pon-omci` 运行计数、`/var/run/pon-service` 状态、错误原因
- 接口：`pon0`、`pon-omci` 收发与错误统计
- 配置：`/etc/config/pon`、`/etc/config/pon_wan`（密码类字段只显示"已配置"）
- 日志：`logread` 中最近的 PON/OMCI 行

## 记录策略

`/etc/poninfo/history.jsonl` 每行一条快照。签名只包含 `sn`、`mode`、`family`、`los`、`tx_fault`、`module_absent`、
OMCI 的 `session`/`auth`/`paths`/`error`、`pon0`/`pon-omci` 的 operstate、`service_error`：这些变化时立即追加，
无变化时每 `keepalive` 秒追加一次。光功率、温度、电压寄存器本身有量化抖动，收发字节与报文数持续增长，
都不参与签名（仍逐条保存）。文件超过 `max_lines` 后从头部裁剪。

`/etc/poninfo/latest.json` 每次采样整体覆盖，用于页面"立即采样"与排障。

`/etc/poninfo` 由采集器在写入前自行创建（`mkdir`），因此即使采样服务未启用，页面「立即采样」
和命令行 `pon-info record` 也能正常落盘，不依赖 init.d 先建目录。

## 配置 `/etc/config/poninfo`

```
config settings 'settings'
	option enabled '1'      # 采样服务开关
	option interval '60'    # 采样间隔（秒，最小 5）
	option keepalive '600'  # 无变化时的最长记录间隔（秒）
	option max_lines '4000' # 历史保留条数
```

改完 `reload_config` 或 `/etc/init.d/poninfo restart`。可用 `uci set poninfo.settings.enabled=0` 关闭采样（页面仍能实时查看）。

## 命令行

```sh
pon-info show            # 人读摘要
pon-info json            # 全量 JSON
pon-info record          # 手动采样一次
pon-info history 20      # 最近 20 条
pon-info clear           # 清空历史
```

未暴露的 `xgpon_identity`、`gpon_identity`、`omci_msk`、`itu_paths`、`ploam_default` 读取会返回 `Permission denied`；`ploam`/`fec`/`pm_counters` 在链路未建立时读到 `I/O error`。页面按"不可读"显示，不视为故障。

## 与既有页面的关系

`network/tyfza1-pon` 负责写（配置身份与认证），本页只读并留痕，二者不共享写路径。
