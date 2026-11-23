# WORKLOG 2026-11-17 — GWRT 主题 r122 双栈流量与刷新修复

## 1. 任务背景

用户反馈首页刷新后流量统计消失，并明确要求保留原单卡紧凑布局、在同一张图用两种颜色表示 IPv4/IPv6，分别显示协议上下行和累计量；页头显示路由运行时间、在线设备、进程数和 CPU 最高进程。还要求显示总量、今天、本周、本月、本年，覆盖时间不足的周期不显示，日统计持久保存在路由器中且避免实时写闪存。

## 2. 实现

- 页面刷新通过 gwrt-traffic-daily read 读取运行时状态，不触发采样或持久写入；后台服务每 5 秒采样一次，实时状态放在 /tmp/gwrt-theme/traffic-state.json。
- Bandix 的 luci.bandix_plus ubus 对象未注册或返回无效结果时，改用固定命令 /usr/libexec/rpcd/luci.bandix_plus call getSnapshot 读取统计；系统提供 timeout 时限制为 5 秒，且不拼接浏览器输入。按 netifd 主 WAN 设备选择 Bandix 接口，避免把 LAN 流量重复计入。
- 双栈上下行速率、累计量及同一张 IPv4/IPv6 彩色曲线保留原来的紧凑卡片。周期统计基于有效采样增量；覆盖时间不足的周、月、年不显示。
- /etc/gwrt/traffic-daily.json 保存日检查点及汇总，首次有效采样和跨入新日期时原子写入；正常停止服务时额外检查点。历史日数据保留 400 天，旧于 400 天的日明细会清理，累计总量仍保留。
- 页头显示 uptime、按去重 MAC 统计的真实在线设备数、进程数和最高 CPU 进程。最高进程改为 awk 数值排序，兼容设备 BusyBox sort 不支持可靠数值列排序的情况。

两个源码副本均已同步，SHA-256 清单为 /home/godsun/build/gwrt-theme-r122-validation-20261117/source-synced.json：

- gwrt-theme-V3/theme/luci-theme-gwrt/
- package/gwrt-theme/luci-theme-gwrt/

## 3. 验证结果

- Ucode 统计逻辑测试：PASS traffic accounting: 30 checks，覆盖接口选择、失败采样保留、计数器重置、跨日拆分、周期覆盖门槛及检查点。
- r122 页面行为测试通过：同卡双栈、彩色曲线、刷新/读取失败后保留累计量、SoC/加速器显示及紧凑布局。
- 两台实机桌面 1440px 和手机 390px 页面测试通过；各有 IPv4、IPv6 实际上下行、累计值及曲线，无水平溢出或页面 JS 错误。页面刷新及模拟统计 API 暂时失败后，累计值保持不变。
- 进程排序用短时 CPU 负载验证：192.168.9.9 测得 sha256sum 24%，192.168.8.8 测得 25%，测试进程均排第一。
- 两台设备均从 /usr/libexec/gwrt-socinfo 识别为 ipq6010*4；双栈采样恢复。修复部署前后主题文件哈希、root 所有权和权限均核对通过；两台 boot ID 均未改变。
- 部署证据及浏览器结果：/home/godsun/build/gwrt-theme-r122-validation-20261117/。首次主题热更新执行 rpcd/uhttpd reload 并启动 gwrt-traffic-daily；采样修复阶段只重启 gwrt-traffic-daily。没有刷机或重启路由器。

## 4. 文件清单与回滚

本次仅在两份主题源码中修改 r122 所列文件，并将修复热更新到两台路由器。修复前的两个文件备份在证据目录 source-before-fix/；设备完整主题备份在 /root/gwrt-backups/20261117-theme-r122-fix/theme.tgz。

- 只回滚本轮采样/进程排序修复：在对应设备运行 sh /root/gwrt-backups/20261117-theme-r122-fix/rollback.sh。
- 回滚整个 r122 主题到更新前版本：在对应设备运行 sh /root/gwrt-backups/20261117-theme-r122-before/rollback.sh。

设备回滚脚本停止流量服务、恢复文件并重新启动服务。原始日统计和运行状态在操作前后均有独立副本；不要删除 /etc/gwrt/traffic-daily.json。

## 5. 未完成与边界

- 统计数据源依赖 Bandix 服务可运行，且 Bandix 配置必须监控主 WAN。两台已测路由满足此条件；主题 Makefile 未强制安装 Bandix，因此缺少服务或 WAN 接口未纳入监控的设备不会产生双栈统计。
- /etc/gwrt/traffic-daily.json 按日保存检查点，不进行实时闪存写入。突然断电时可能丢失上一次持久检查点后的当天增量；服务正常停止时会先做最终检查点。
- 日明细保留 400 天；更久的周/月/年明细不用于当前周期统计并会被清理，累计总量不会因此清零。
- 跨真实日界和服务停止路径由统计单元测试及实机检查点验证；本轮没有进行真实断电或路由器重启测试。

## 6. 环境备注

目标设备为 192.168.9.9 与 192.168.8.8。认证通过本机 askpass 脚本提供；密码未写入日志、命令记录或源码。未编译固件、未推送、未刷机、未重启设备。
