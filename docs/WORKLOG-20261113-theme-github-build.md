# WORKLOG 2026-11-13 — 主题修复推送与 SS-01 云端编译

## 范围与基线

用户授权把前两轮主题修复推到 GitHub 并编译。按当前恢复的构建范围先编 SS-01，
版本 `261113-01`、`release=false`、仅 factory/sysupgrade；其它机型没有触发。
远端 master 基线为 `432d03c8e200869cab549e2447e2a4e2e9798fd1`，上一轮
`43162126875` 已成功。隔离工作树 `/home/godsun/build/gwrt-theme-261113`，
保留原 NAS 和导出仓的其它未提交改动。

## 合并内容

- 合入 `WORKLOG-20261112-gwrt-theme-audit.md` 和
  `WORKLOG-20261112-gwrt-theme-dashboard.md` 记录的权限、CGI、临时目录、
  设备持久化、卡片导航、网口、Wi-Fi 与 Mesh 速率修复。
- NAS 主题缺少 GitHub 已有 PON 光口实现：以共同基线做三方合并，保留 PON
  状态卡/设置、AN758x 名称、PPE helper 和样式；运行时 WAN 识别保留 PON 身份。
  PON ACL 只开放固定 `ponctl --device pon0 status --json` 读命令和写组 apply。
- 主题包升为 `1.0-r115`，两个 header 的 CSS 缓存键为 `20261113r115`；
  `gwrt-device-defaults` 升为 `1.0-r3`，以区分包含 Mesh 回程速率的安装包。
- 三份主题源同步；新增纯 Node 安全/设备持久化回归加入 CI source preflight，
  成品审计增加 ACL、安全 helper 与 Mesh daemon 的源文件一致性检查。
- 保留 SS-01 `KERNEL_SIZE=12288k`、IPQ6018 AHB/DD-WRT 无线、校准 READY
  保护及无线/Mesh 首启修复，未带入 CS-02 PCI/QCN9074/Athena 策略。

## 本地验证

隔离树已通过目标 profile guard、`gwrt-check-target.sh`、配置 validator、仓库
`gwrt-source-preflight.sh`（JS/shell/JSON、两份主题安全和持久化、12 项客户端合并、
APK 首启保护等）、SS-01 校准保护/mesh preset/firstboot/autopair 专项测试。
Chrome/Playwright 的卡片菜单、响应式端口/色环与 Mesh UI 回归通过。
`integrate.sh --check --no-config` 通过。隔离树 feeds/luci 是 NAS feed 的只读使用
链接，仅供本地集成和预检；GitHub 会重新安装 feeds 并运行完整 defconfig。
旧技能源码审计使用过时插件路径和全局 debug 扫描，沿用项目已记录的仓库 CI
预检与目标检查；未把旧技能审计当作本次通过项。

## 推送与构建

本次准备推送私有仓 `rothdren-lion/gwrt-immortalwrt` 的 master，再触发
`gwrt-build.yml` 的 SS-01 `261113-01`；实际提交、运行链接与状态随后追加。
仅触发构建，不发布 Release，不刷机或重启。

## 回滚与限制

NAS 同步前备份 `/tmp/gwrt-theme-github-sync-261113-before.tar.gz`，包含主题
规范源/包副本、受影响的 defaults/验证脚本和 AGENTS。GitHub 可通过 revert
本次功能提交恢复代码，保留后续工作。
实机网口、Wi-Fi 协商数据、无线 Mesh 和路由器重启后设备标签仍需实机确认。
