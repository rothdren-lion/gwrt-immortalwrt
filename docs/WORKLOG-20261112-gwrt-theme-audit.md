# WORKLOG 2026-11-12 — GWRT Theme 安全审计与多网口兼容

## 1. 任务背景

继续审计 `gwrt-theme-V3/theme/luci-theme-gwrt`，重点覆盖 LuCI/rpcd 权限边界、主题 CGI、
临时运行数据、OTA 文件处理，以及不同机型的运行时 WAN/LAN 网口识别。用户当前只要求
源码和包副本修正；本次未编译、未刷机、未重启设备，也没有宣称实机验证。

## 2. 修改内容

- 只读 ACL 增加精确的 `/usr/libexec/gwrt-coremark status`，保留 CoreMark 启动、OTA apply、
  临时 LAN 地址和 conntrack 删除的写权限隔离；移除宽泛 `/bin/cat`、OTA/LAN/conntrack
  变更入口。ACL 仍由 rpcd 按完整命令行参数匹配。
- CoreMark CGI 修正 shell `case` 语法；状态请求只走 read 权限，启动请求要求 POST 和
  write 权限。CoreMark pid/log、客户端状态、DHCP 指纹和 OTA 临时文件统一使用 root 所有、
  非符号链接、`0700` 的 `/tmp/gwrt-theme` 运行目录。
- DHCP 指纹钩子拒绝非标准 6 组 MAC，避免把未经校验的数据拼进 `sed`；IPv6 WAN helper
  只接受不超过 15 个字符的安全网口名，避免将参数当作 `ip` 选项。
- 容器图标降级 SVG 对容器名称首字符进行 HTML 转义，防止运行时数据直接进入 SVG 标记。
- 网口显示改用 netifd 运行时 WAN/LAN 设备、VLAN 父设备和 LAN bridge 成员；WOL 使用实际
  LAN bridge。桥成员为 `lan1`、`lan2`、`lan3`、`lan4` 的 AN7581 类布局可正常显示，旧板级
  WAN 映射不会覆盖当前运行状态。
- 使用 `gwrt-theme-V3/scripts/integrate.sh --no-config --tree .` 同步规范源到
  `package/gwrt-theme/luci-theme-gwrt/` 和其嵌套副本；overlay 与配置未重新生成。

## 3. 验证结果

以下检查在本地 NAS 源码树通过：

```sh
sh gwrt-theme-V3/scripts/integrate.sh --check --no-config --tree .
node scripts/tests/test-gwrt-theme-security-ports.js
python3 scripts/tests/test-gwrt-clients.py
node scripts/tests/test-gwrt-mesh-ui.js
GWRT_TEST_THEME=package/gwrt-theme/luci-theme-gwrt node scripts/tests/test-gwrt-mesh-ui.js
sh scripts/tests/test-gwrt-socinfo.sh
```

结果包括 ACL/运行时 WAN-LAN/AN7581 bridge 回归通过、客户端合并 12 项通过、Mesh UI 两份
主题副本均通过、SoC 识别通过；JSON、独立 JS、7 段模板内联 JS 和主题 shell 语法检查通过。
另用隔离 mock 验证 CoreMark CGI 的 read/status、POST start、403 拒绝和 GET 405 边界。
规范源与嵌套副本 `diff -qr` 一致，integrate `--check` 报 source copies、overlays、config
已同步。

## 4. 文件与回滚

规范源改动位于 `gwrt-theme-V3/theme/luci-theme-gwrt/`，同步副本位于
`package/gwrt-theme/luci-theme-gwrt/`；回滚前备份为
`/tmp/gwrt-theme-review.ohQpHx/theme-before-sync.tar.gz`，备份包含修改前规范源和包副本。
恢复时应先确认目标路径，再从该 tar 包提取对应目录，之后运行：

```sh
sh gwrt-theme-V3/scripts/integrate.sh --check --no-config --tree .
```

## 5. 未完成事项

- 未运行完整 ImmortalWrt 编译，未生成新固件；未刷机、未重启、未做真实 WAN/LAN/WOL/IPv6
  设备验证。需要在各目标机型上确认 netifd 的实际 `device`、bridge 成员和 WOL 行为。
- Codex Security Deep Scan 因环境缺少 managed filesystem permission profile 未启动；本日志
  不把它计为完成的自动化扫描。

## 6. 环境备注

工作目录为 `/mnt/syNAS/Dowloads/Rout/mark/immortalwrt`，日期为 2026-11-12（Asia/Shanghai）。
