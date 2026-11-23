# WORKLOG 2026-11-18 — SS-01 首页 WAN 曲线恢复

用户报告 `192.168.3.3` 的 GWRT 首页停在“等待流量采集”。实机为 `jdcloud,re-ss-01`，固件 `261118-04/671b86b`，主题 `1.0-r123`。`wan` 和 `wan6` 已连接，实际接口都是 `wan`；Bandix Plus 及主题统计进程均在运行。设备配置和镜像内的默认接口列表都只包含 `br-lan`，两种 Bandix 读取路径也只返回 LAN。主题只使用匹配 WAN 的数据，所以读接口返回 `ok:false`、`sampled:0`、`history:[]`，不是 CSS 隐藏了曲线。

在 `.3.3` 将 `wan` 追加到 `bandix_plus.general.iface`，保留 `br-lan` 和原有 Bandix 设置，提交该配置并重启 Bandix Plus。主题统计进程和路由器 boot ID 保持不变；未改 LuCI 文件、挂载、无线或网络配置。`.9.9` 只读对照原已监控 `br-lan wan`，曲线正常；其它设备未调整。

确认 Bandix 接口列表为 `br-lan wan`，主题采样来源为 `bandix:wan`。两次实机读取间采样点由 21 增至 22，IPv4/IPv6 均可用，累计从 20,141,015 增至 20,430,157 字节。桌面（1440px）和手机（390px）均画出两条曲线，无横向溢出；手机页收到下一次样本，双栈速率和曲线继续更新。第一笔有效基线自动生成了 810 字节的 `/etc/gwrt/traffic-daily.json`，后续仍按原有半小时间隔写盘；开始采样前的 WAN 用量无法补记。记录和截图见 `/home/godsun/build/gwrt-theme-wan-curve-20261118/`。

改前配置和回滚脚本在 `.3.3` 的 `/root/gwrt-backups/20261118-ss01-wan-curve-before/`。执行 `sh /root/gwrt-backups/20261118-ss01-wan-curve-before/rollback.sh` 仅移除本次追加的 WAN 项并重启 Bandix，不回滚累计值。未调整固件默认接口列表，未编译、推送、刷机或重启路由器；若恢复为无配置的同版固件，需重新将实际 WAN 接口加入 Bandix。
