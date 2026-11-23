# WORKLOG 2026-11-17 — GWRT 主题 r121 存储与双栈流量卡片

## 1. 范围

用户要求恢复主题的紧凑卡片样式，并继续完善首页监控：运行存储及下方容量值统一显示“已用 / 总容量”，WAN 流量必须分别显示 IPv4 和 IPv6。此前已加入路由、DNS、外网、真实在线设备数、进程数和高负载进程导航监控，以及按设备识别 SoC/加速能力；本轮对这些内容做一致性复核。

主题源码的两个副本均已同步：

- `gwrt-theme-V3/theme/luci-theme-gwrt/`
- `package/gwrt-theme/luci-theme-gwrt/`

首页模板、CSS 和 SoC helper 的 SHA-256 在两个副本间一致。`gwrt-socinfo` 保持 0755，模板/CSS 保持 0644。

## 2. 实现

- MEM、SWAP、ROOTFS、DISK 四项现在都使用“已用 X / 总容量”。没有 swap 或没有可识别数据盘时继续显示 `-`。
- WAN 卡拆成独立的 IPv4、IPv6 两栏。每栏有下载速率、上传速率、累计 RX/TX 和独立趋势曲线。
- IPv4/IPv6 读取 `/sys/kernel/debug/qca-nss-drv/stats/ipv4` 与 `stats/ipv6` 的独立计数器；某一协议没有独立计数器时显示“暂无统计”，不会把另一协议或接口聚合值复制过去。
- SoC 由 `/usr/libexec/gwrt-socinfo` 从设备实际 machine/compatible 和 CPU 信息读取，首页显示例如 `ipq6010*4`，不再拼接“× 4核”。NSS、PPE、NPU 只在 helper 实际识别到时显示。
- WAN 卡和连接设备卡均固定为 196px，保留原来的紧凑布局；IPv4/IPv6 在桌面和手机宽度下保持两栏和独立曲线。

## 3. 回归测试

新增 `scripts/tests/test-gwrt-theme-r121.js`，使用真实模板函数夹具验证存储格式、双栈 DOM、NSS IPv4/IPv6 计数器增量、SoC helper、缓存版本和卡片 CSS；默认主题副本和包副本均通过：

```sh
PATH=/home/godsun/.local/share/pi-node/node-v22.23.5-linux-x64/bin:$PATH \
  node scripts/tests/test-gwrt-theme-r121.js
PATH=/home/godsun/.local/share/pi-node/node-v22.23.5-linux-x64/bin:$PATH \
  GWRT_TEST_THEME=package/gwrt-theme/luci-theme-gwrt \
  node scripts/tests/test-gwrt-theme-r121.js
sh scripts/tests/test-gwrt-socinfo.sh
PATH=/home/godsun/.local/share/pi-node/node-v22.23.5-linux-x64/bin:$PATH \
  node scripts/tests/test-gwrt-theme-security-ports.js
PATH=/home/godsun/.local/share/pi-node/node-v22.23.5-linux-x64/bin:$PATH \
  node scripts/tests/test-gwrt-client-link-ui.js
git diff --check -- scripts/tests/test-gwrt-theme-r121.js gwrt-theme-V3 package/gwrt-theme
```

上述命令均通过。

全量 `scripts/gwrt-source-preflight.sh` 在首个 integrate 检查阶段以返回码 143 退出，且没有诊断输出，
因此本轮不把它计为通过；以上主题专项及既有回归测试结果独立有效。

浏览器证据保存在 `/tmp/gwrt-theme-r121-evidence/`。桌面 1440px 和手机 390px 均通过：SoC `ipq6010*4`、IPv4/IPv6 两栏、两条趋势曲线、四项“已用 / 总容量”、WAN/设备卡 196px、导航栏高度和无横向溢出检查，页面没有 JavaScript 错误。

## 4. 实机热更新

主题已通过 SSH 热更新到 `192.168.9.9` 和 `192.168.8.8`，随后执行 uhttpd reload；没有刷机、重启路由器或修改网络配置。

- `192.168.9.9`：识别到 NSS，IPv4/IPv6 累计计数器均可读，页面分别显示对应累计值和采样曲线。
- `192.168.8.8`：识别到 PPE；设备没有独立 NSS IPv4/IPv6 统计，两个协议栏正确显示“暂无统计”，没有伪造数值。
- 两台设备均显示真实在线设备数、进程数和高负载进程；桌面/手机页面均保持紧凑高度。

更新前备份：

- 设备远端：`/root/gwrt-backups/20261117-theme-r121-before/theme.tgz`
- 本地：`/home/godsun/build/gwrt-theme-r121-validation-20261117/192.168.9.9/theme-before-r121.tgz`
- 本地：`/home/godsun/build/gwrt-theme-r121-validation-20261117/192.168.8.8/theme-before-r121.tgz`

回滚只需恢复对应 `theme.tgz` 后 reload uhttpd；本轮没有触碰固件镜像和设备重启流程。

## 5. 边界

双栈累计和速率依赖设备实际提供的 NSS 协议计数器。没有该计数器的硬件会明确显示“暂无统计”；这表示数据源不存在，不代表该协议断网。趋势曲线在页面采样后逐步填充，浏览器首次打开时可能短暂显示“采样中”。
