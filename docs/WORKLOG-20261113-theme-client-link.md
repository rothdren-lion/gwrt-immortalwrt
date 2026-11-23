# WORKLOG 2026-11-13 — 接入设备端口与实时协商速率

## 1. 任务背景

用户要求首页“接入设备”直接显示实际接入位置（LAN1/LAN2 或 WiFi 2.4G、5.2G、5.8G、6G），并在“信号”列显示当前有线握手速率或无线实际协商速率及 dBm 信号。此前实机 `gwrt-clients` 服务持续退出，导致端口/频段数据缺失。

## 2. 根因与修改

- 固件 BusyBox 未编译 `stat`，`gwrt-runtime-dir` 因 `stat -c '%u'` 失败退出，`gwrt-clients` 随后进入 procd crash loop。保留目录必须是 root、拒绝符号链接、强制 0700 的校验，改为解析 `ls -nd` 的数字 UID。
- WiFi 采集继续使用 `ubus iwinfo`，并把当前 hostapd 接口名作为第 5 个字段传给合并器；合并器优先当前 WiFi 关联接口，避免沿用旧 bridge FDB/历史端口。
- 首页模板按实时端口和关联站点映射输出：
  - “接入”：LAN1/LAN2…或 WiFi 2.4G/5.2G/5.8G/6G；当前无线接口频段优先，旧 tracker 数据只作回退。
  - “信号”：有线读取当前 `network.device status` 的 carrier/speed，显示如 `1000 Mbps`；无线取当前 `iwinfo assoclist` 的 rx/tx 协商速率较大值，下面显示 `-48 dBm`，不使用理论能力或流量速率；离线设备不显示过期速率。
- 保留之前的 WAN/LAN/WIFI 分组、少口居中、DTS/PHY 2.5G/5G/10G 内圈、弹窗和软件包页面紧凑布局。
- NSS 驱动保留补丁 `021-fix-symbol-only-module-cleanup.patch`：没有 `nss-common` 时仅导出符号的模块不创建 workqueue，卸载直接返回，避免 `destroy_workqueue(NULL)` panic。补丁对上游源码 dry-run 通过；提取实际 init/cleanup 函数的宿主 C harness 覆盖普通与 point-offload 配置的 9 种生命周期，补丁前可复现空工作队列清理断言，补丁后全部通过。驱动包 release 18→19，尚未随本轮镜像刷入。

## 3. 实机部署与验证

设备：SS-01，`192.168.3.3`，`261113-01`，Linux 6.18.62。部署前备份：

- 实机 `/tmp/gwrt-theme-r116-before-client-link.tgz`；本地副本 `/tmp/gwrt-ss01-r116-before-client-link.tgz`（更新前 r116 文件）
- `/tmp/gwrt-theme-r116-client-link-live.tgz`（本轮热更新包）

执行 `gwrt-runtime-dir` 和 `/etc/init.d/gwrt-clients restart` 后：

- `ubus service list` 显示 `gwrt-clients` running=true，`gwrt-clients-dump` 返回更新中的 clients JSON。
- 浏览器实际刷新首页通过：PC `192.168.3.179` 显示 `LAN1`，信号列显示 `1000 Mbps`；刷新后仍保持，页面无 JavaScript 错误。
- 当前实机没有在线 WiFi 终端，因此没有无线速率的现场样本；`iwinfo` 频率识别与 UI 测试覆盖 2.4/5.2/5.8/6G、`2401 Mbps`/`1201 Mbps`、dBm、离线和缺失数据。
- 此前同一轮串口诊断确认网口 TX 卡死：ARP 请求进入 lan1，内核生成应答，但 TX 计数和 EDMA TX 完成中断不再增长。接口 down/up 无效。在尝试通过卸载 NSS 模块恢复时，`qca_nss_drv` 的 `nss_data_plane_destroy_delay_work` → `destroy_workqueue(NULL)` 触发 panic 并自动重启。重启后网络恢复，短时 iperf（上传约 932 Mbps、下载约 841 Mbps）和 5 次 ping 无丢包；触发 TX 卡死的根因尚未查明，不能宣称永久修复。此后没有再次卸载驱动、主动重启或刷机。

## 4. 自动化验证

通过：

- `sh scripts/gwrt-source-preflight.sh`
- `python3 scripts/tests/test-gwrt-clients.py`（18 项）
- `python3 scripts/tests/test-gwrt-runtime-dir.py`（6 项）
- `node scripts/tests/test-gwrt-client-link-ui.js`
- 端口响应式/色圈/点击、弹窗软件包、卡片菜单、Mesh UI 浏览器回归
- 本地 Chrome 实机页面检查与刷新
- `git diff --check`
- NSS cleanup 补丁对上游 `nss_init.c` 的 `patch --dry-run`、实际 init/cleanup 的 9 个宿主 C harness 场景及补丁前失败复现

## 5. 回滚

主题热更新可在设备执行：

```sh
tar -xzf /tmp/gwrt-theme-r116-before-client-link.tgz -C /
/etc/init.d/gwrt-clients restart
```

源码提交可通过 Git revert 回滚；NSS 修改可单独 revert。持久证据与备份保存在 `/home/godsun/build/gwrt-theme-r116-validation-20261113/`（0700），包含原主题备份、热更新包、串口日志、iperf JSON 和浏览器截图，SHA-256 清单在该目录 `sha256sums`。

## 6. 推送与构建状态

提交 `eda276cb6a74835ef9658b34a038263414289870` 已按原提交 SHA 推送到私有仓 `rothdren-lion/gwrt-immortalwrt` master。GitHub Actions SS-01 `261113-02`（`release=false`）运行 `43350331850` 已启动，链接：https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43350331850。截至 UTC 2026-11-13 02:15:22，配置生成/源码预检、校准保护和 Mesh 专项检查均通过，已进入 Build firmware；尚无本轮成品。完成后还需确认镜像内包含 `gwrt-runtime-dir`/clients collector/NSS cleanup 修改及 `KERNEL_SIZE=12288k`。无线实际速率仍待有在线 WiFi 终端时复核。


## 7. 用户追加：信号在上、速率在下（r117）

- 接入设备的协商速率使用短单位，例如 `100Mbps`、`1Gbps`、`2.5Gbps`、`10Gbps`；无线 `2401Mbps` 显示为 `2.4Gbps`、`1201Mbps` 显示为 `1.2Gbps`。悬停提示保留精确的收发 Mbps。
- 恢复四格无线信号图，上方显示信号格和 `-48dBm`，下方显示紧凑协商速率；信号格跟随当前信号变化。
- 主题包及 CSS 缓存键更新为 r117，规范源和两个包副本一致。实际页面已核对 PC 显示 `LAN1 / 1Gbps`。信号/速率数据缺失及离线逻辑继续保留。
- `test-gwrt-client-link-ui.js` 和完整 source preflight 通过；浏览器用模拟 WiFi 数据核对桌面与手机宽度下的信号格、文字顺序和精确速率提示，模拟只影响临时浏览器 DOM，不写路由器状态。
- 更新前实机备份 `/tmp/gwrt-theme-r116-before-compact-signal.tgz`；持久副本在上述验证目录的 `backups/`，新热更新包为 `gwrt-theme-r117-compact-signal-live.tgz`。
- 修改已推送 GitHub，提交 `dc78eab21224b598261ec94a4bcdfd743cc75e33`。SS-01 `261113-03`、`release=false` 运行 `43354566787` 已在 UTC 2026-11-13 02:53:12 进入 Build firmware，前置检查通过：https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43354566787。旧 r116 运行 `43350331850` 已取消，让 runner 优先构建 r117；最终应以 `43354566787` 镜像为准。
- 再次通过完整 `scripts/gwrt-source-preflight.sh` 和 `test-gwrt-client-link-ui.js`。实机浏览器确认 PC 为 `LAN1 / 1Gbps`；桌面 1440 和手机 390 宽度的临时无线数据确认 `-48dBm` + 四格信号在上、`2.4Gbps` 在下且无重叠，RX/TX tooltip 为 `2401Mbps / 1201Mbps`，刷新无 JS 错误。实际 SS-01 当前没有在线 WiFi 终端，无线显示仍通过临时浏览器数据验证。
