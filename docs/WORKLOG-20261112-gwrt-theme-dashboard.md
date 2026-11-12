# WORKLOG 2026-11-12 — GWRT 主题仪表盘与设备标注

## 1. 任务背景

按用户要求在上一轮安全/多网口修复基础上继续改主题：概览卡片点击可打开对应菜单、端口图适配不同屏幕并展示 PHY 能力、Wi-Fi/Mesh 显示协商指标，以及修复手工设备信息刷新丢失。

## 2. 修改内容

- 规范主题模板和 CSS：系统/CPU 卡片打开概述菜单，存储卡片打开存储，活跃应用打开服务，连接设备打开网络；支持 Enter/空格和鼠标，卡片内按钮、链接、设备别名、CoreMark 和应用图标仍执行原动作。
- 端口卡改用响应式均匀网格，WAN 轻微放大；运行时 `link-supported` 能力生成 inset 装饰圈：2.5G 蓝色一圈、5G 红色一圈、10G 红色两圈。能力标签仍按 netifd/PHY 状态计算，未知能力不猜测。
- Wi-Fi 卡按本射频已关联终端的收发协商速率最大值显示 Mbps；修复 iwinfo `bitrate_raw`（100 bit/s 单位换算）解析。2.4G/5G/6G 频段来自原有 radio 识别。
- Mesh wireless uplink 在已组网 AP 下显示 TX/RX 回程协商速率和 RSSI；`wifiroamd.uc` 从 `iw dev <sta> link` 采集两个方向速率并带入拓扑。
- 手工标签按 MAC 或有效 IPv4 写入并提交路由器 `gwrt` UCI，重新读取验证落盘；空字段会覆盖旧值，恢复自动会删除所有匹配段。启动迁移和保存串行化，避免 UCI 读取与保存并发覆盖；读取失败会提示失败而不伪报保存成功。无 MAC 的 IPv4 标签会提示地址变化/复用风险；无 MAC、无有效 IPv4 时才留在当前浏览器。
- 通过 `gwrt-theme-V3/scripts/integrate.sh --no-config --tree .` 同步主题包及嵌套副本，没有改配置片段、运行 defconfig 或构建。

## 3. 验证结果

通过：

```sh
sh gwrt-theme-V3/scripts/integrate.sh --check --no-config --tree .
node scripts/tests/test-gwrt-theme-security-ports.js
GWRT_TEST_THEME=package/gwrt-theme/luci-theme-gwrt node scripts/tests/test-gwrt-theme-security-ports.js
node scripts/tests/test-gwrt-device-label-persistence.js
node scripts/tests/test-gwrt-dashboard-menu-click.js
node scripts/tests/test-gwrt-port-responsive-ui.js
node scripts/tests/test-gwrt-mesh-ui.js
GWRT_TEST_THEME=package/gwrt-theme/luci-theme-gwrt node scripts/tests/test-gwrt-mesh-ui.js
python3 scripts/tests/test-gwrt-clients.py
sh scripts/tests/test-gwrt-socinfo.sh
```

另外通过宿主机 ucode 编译 `wifiroamd.uc`（剔除设备端 import 后做语法编译）、验证 1.2 Gbit/s 与 866.7 Mbit/s 速率单位解析，以及模板内联 JS 语法检查。浏览器 mock 验证了 390px 移动视口端口宽度、WAN 尺寸、不同能力色环、卡片菜单键盘/鼠标操作和嵌套控件动作。规范主题、flat 包副本、nested 包副本的安全端口、标签持久化、菜单入口、端口视觉和 Mesh UI 测试均通过，`integrate --check` 确认主题副本及 overlays/config 状态同步。主题未完整编译，未刷机、未重启、未做实机无线/网口验证。

## 4. 文件与回滚

主题源码：

- `gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut`
- `gwrt-theme-V3/theme/luci-theme-gwrt/htdocs/luci-static/gwrt/css/cascade.css`

运行时 Mesh 回程速率：`package/gwrt-device-defaults/files/wifiroam/wifiroamd.uc`。
回归脚本：`scripts/tests/test-gwrt-theme-security-ports.js`、
`scripts/tests/test-gwrt-device-label-persistence.js`、
`scripts/tests/test-gwrt-dashboard-menu-click.js`、
`scripts/tests/test-gwrt-port-responsive-ui.js`。

同步前的主题包副本备份：`/tmp/gwrt-theme-ui-before-sync-20261112.tar.gz`，SHA-256：
`1a41afd23611b8985ebfff6072d8b9103b3f926668869927a22fb5e416481aad`。如需回滚主题模板/CSS，备份中的 flat 或 nested 版本一致，可恢复到规范源后再运行 integrate 同步。该归档不包含 `wifiroamd.uc`。

## 5. 待办

- 完整固件构建、实机核对 2.5G/5G/10G DTS/PHY 速率状态和 2.4G/5G 多终端显示。
- 在无线 Mesh 实机核对 `iw link` 驱动是否提供 RX/TX bitrate；缺少字段时 UI 会只显示现有速率/信号，不捏造数值。
- 用户确认设备 IP 变化时是否需要专门的别名迁移界面；目前 MAC 是稳定主键，IP 仅作为无 MAC 设备的降级主键。
