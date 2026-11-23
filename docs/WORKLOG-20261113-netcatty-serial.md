# WORKLOG 2026-11-13 — Netcatty MCP 与刷机后串口观察

## 连接与授权

用户说明已刷入固件，要求通过正在运行的 Netcatty 桌面应用查看串口。
已在 `/home/godsun/.codex/config.toml` 注册 `netcatty-external`：

- transport：local stdio。
- command：`/opt/Netcatty/resources/app.asar.unpacked/electron/cli/netcatty-external-mcp`。
- env：`NETCATTY_EXTERNAL_MCP_DISCOVERY_FILE=/home/godsun/.config/netcatty/external-mcp/discovery.json`。

修改前备份：`/home/godsun/.codex/config.toml.before-netcatty-20261113-085110.bak`。
可使用 `codex mcp remove netcatty-external` 撤销此次注册，保留其它服务。
discovery 内认证 token 没有复制到配置或日志。

使用 mcporter 客户端实际列出 15 项 MCP 工具，并调用 `get_environment` 验证成功。
已连接的目标为 `Serial: ttyACM0`、`/dev/ttyACM0`，sessionId
`345ae52d-976e-4f90-a084-18696d424f71`；其它已保存 SSH 会话未连接，也未操作。
通过 `terminal_read_context` 读取 live scrollback，没有另开或抢占串口设备。

## 已观察到的固件与启动状态

- 串口 banner：`GWRT 261113-01 + Theme 1.0-r115`，
  `Model JDCloud RE-SS-01`，`Source ce91005`，Linux `6.18.62`。
- GitHub 运行 `43262429011` 现为 `completed/success`，构建 head 为
  `ce91005eed1dd92a411e69fecbaf6934996e97a6`。
- 当前启动记录显示内核和设备树 FIT 校验通过，f2fs overlay 已挂载；
  进入 `root@GWRT` shell。不能仅凭挂载日志证明 overlay READY guard 的最终状态。
- `lan1`/`lan2`/`lan3`/`wan` 已创建；LAN1 在约 87 秒以 1000 Mbps 建链，
  `br-lan` 进入 forwarding；用户原有 `ip a` 输出显示 `192.168.3.3/24`。
  LAN2、LAN3、WAN 为 NO-CARRIER；未验证这些端口的真实收发或 DHCP。
- ath11k IPQ6018 固件已启动；约 133 秒 `phy0-ap0` 和 `phy1-ap0` 进入
  forwarding；约 147 秒 `phy1-sta0` 收到成功 AssocResp 并关联。
  这只证明无线 STA 关联，尚未证明 Mesh 应用层认证、网络连通或速率。
- 两次回读末尾均为同一启动的约 147 秒和 shell prompt；回读期间没有新增重启日志。
  这不等于长时间运行稳定性验证。

## 仍需跟进的错误和限制

- SSDK 启动仍有 `ssdk_uniphy_port5_clock_source_set` 和
  `ssdk_uniphy_raw_clock_set` 的 `ERROR:set parent fail!`，之后 SSDK init 成功。
  LAN1 建链不能排除其它端口、时钟父节点或实际吞吐问题。
- 无线接口重建时出现一次 `No VIF found for vdev 1` / `invalid vdev id 1 in
  bcn_tx_status`；之后 AP forwarding 和 STA association 成功。未据此判定驱动崩溃。
- preinit 还有 `/etc/fw_env.config` 缺失和 `Failed to find NVMEM device`；
  系统随后继续启动。未在本轮修改该路径。
- 尝试通过 MCP `terminal_execute` 发送只读状态查询，工具返回
  `Network device session has no writable PTY stream for command execution`，
  串口屏幕未出现所请求命令。没有执行成功的当前 uptime、`iw link` 或 ubus 查询，
  因此没有实测当前无线速率、Mesh 认证状态或标签持久化。

## 证据位置

- `/tmp/gwrt-netcatty-tools-20261113.json`：工具列表及 schema。
- `/tmp/gwrt-netcatty-serial-tail-20261113.json`：末尾 240 行。
- `/tmp/gwrt-netcatty-serial-675-20261113.json`：当前启动内核/驱动段 300 行。
- `/tmp/gwrt-netcatty-serial-current-20261113.json`：第二次末尾回读。
- `/tmp/gwrt-netcatty-runtime-20261113.json`：执行接口的错误结果。

本轮仅配置本地 MCP 并读取用户正在监控的串口；未刷机、重启、重载服务或修改路由器配置。
