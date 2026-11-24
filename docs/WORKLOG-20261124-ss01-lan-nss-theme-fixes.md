# WORKLOG 2026-11-24 — SS-01 LAN 时钟、NSS 固件时序与 LuCI 主题/流量修复

设备：SS-01（JDCloud RE-SS-01，IPQ6018），`192.168.3.3`，起始固件 `261123-01`
（rev `ac2d1243`，Linux 6.18.62），结束时运行 `261123-06`（rev `d80bda24`）。

源码树：`/home/godsun/build/gwrt-ss01-nss-261120`，分支 `build/ss01-nss-261123`。
GitHub：`rothdren-lion/gwrt-immortalwrt`。

## 1. LAN 口拿不到 IP：NSS 端口时钟回落 XO/16

现象：`br-lan` 有地址，无线客户端能拿到租约，有线口 `lan1/lan2` 为 DOWN，
`lan3` 1000 Mbps UP 但 `ethtool -S lan3` 全部 `rx_*` 计数为 0，`tcpdump -i lan3` 零包。

诊断：`/sys/kernel/debug/clk/clk_summary` 中 `nss_port3/4_{rx,tx}_clk_src`
为 `1500000`（应为 `125000000`）；启动日志两次
`ssdk_uniphy_raw_clock_set[1919]:ERROR:set parent fail!`。

根因：`target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-ess-nss.dtsi`
末尾把 `&gcc` 的 clocks 覆盖为 `<&xo>, <&sleep_clk>`，砍掉 0145 补丁引入的 UNIPHY
RX/TX 父时钟；gcc-ipq6018 里 NSS 端口 RCG 的 `parent_data[2..5]` 指向 UNIPHY，
找不到就回落 XO/16，1G MAC 全 0 收发。

修复（`7c72f0f3`）：新增
`target/linux/qualcommax/patches-6.18/0921-clk-qcom-gcc-ipq6018-use-ssdk-uniphy-clock-fallback.patch`，
给四组 UNIPHY `parent_data` 共 12 项加 `.name` 同名回退，CCF 在 SSDK 用
`clk_register(NULL)` 晚注册时按名字重挂 RCG orphan。**不要**再用内核 DTS 里的
125 MHz fixed-clock 占位——11-13 已证实那与 SSDK 动态注册的时钟不匹配，
反而产生 `set parent fail`。

验证（261123-04）：全部 `nss_port*_rx/tx_clk_src = 125000000`，无 `set parent fail`；
`lan2` rx 20,854 / tx 50,581 包，dnsmasq 正常下租约。

## 2. NSS/PPE 卸载不工作：固件是 `qca-nss0-retail.bin`

现象：`qca-nss 39000000.nss: probe with driver qca-nss failed with error -110`
（ETIMEDOUT，约 84.9 s），`/sys/kernel/debug/qca-nss-drv/stats/drv` 全 0。

根因：驱动 probe 时 `request_firmware("qca-nss0.bin")`，但
`package/qca-nss/nss-firmware/Makefile` 只安装 `qca-nss0-retail.bin`；
`qca-nss0.bin` 平名符号链接由 `package/qca-nss/qca-nss-drv/files/qca-nss-drv.hotplug`
的 `select_nss_fw()` 在约 96 s 才创建，晚于 probe。

修复（`63daa811`）：`nss-firmware` 安装阶段直接建
`qca-nss0.bin -> qca-nss0-retail.bin`（HK 芯片同时 `qca-nss1.bin`）。

验证（261123-05）：`NSS core 0 booted successfully`，`drv_tx_buffer_pkt` /
`drv_rx_buffers_pkt` 随流量递增，CPU 97% idle、load 0.37。
iperf3 实测 LAN 下行 ~930 Mbps、上行 ~907 Mbps（千兆线速）。WAN 到公共 iperf3
服务器只有 27–32 Mbps，受限于服务器与外网链路，不代表 LAN 转发。

## 3. LuCI 修复（261123-06 / -07）

| 问题 | 根因 | 修复 |
|---|---|---|
| 概览页 `ReferenceError: renderBadge is not defined` | luci feed 固定 commit `ad75cde88e69` 的 `ui.js` 无该函数，`luci-mod-status` 的 `30_network.js`/`60_wifi.js` 仍在调用（上游回归） | 新增 `render-badge.js`，由 `/etc/init.d/gwrt-theme` 追加到两个 stock 视图末尾（函数声明在模块体内提升） |
| 81/444 端口软件包页看不到「安装…」 | bootstrap `#packages` 无响应式规则，780px 时动作列 x=822–891 出视口 | 新增 `bootstrap-package-manager.css`，追加到 `bootstrap*/cascade.css`，≤1200px 行卡片化 |
| 80 端口（GWRT 主题）安装按钮被压成 20px / 溢出右边缘 | 主题 `.cbi-section-actions .btn{min-width:0;white-space:normal}` 加 `table-layout:fixed` | `cascade.css` 固定动作列 `width:7.5em` + `nowrap`，按钮 `min-width:4.5em`，≤1200px 卡片化 |
| 81/444 无返回 GWRT 主题入口 | 端口映射把 81/444 定为 bootstrap 主题，原生 header 无主题切换，且 header 模板是 ucode 字节码 | 新增 `native-return-link.js`，由 init 脚本追加到 `/www/luci-static/resources/cbi.js`，注入按钮并映射 81→80、444→443 |
| 首页流量曲线无数据 | `traffic-daily.uc` 只走 ubus `luci.bandix_plus getSnapshot`（不存在），且只挑 WAN，而 Bandix 只监控 `br-lan` | 增加 `http://127.0.0.1:8787/api/snapshot` 回退与 LAN 接口兜底 |
| 拓扑图不显示 | `topologyBackhaul.js` 返回普通对象，luci.js 工厂要求 `Class.extend` 子类 | 改为 `baseclass.extend({address,transport,details})` |
| 插件页出现「好用请赞助」 | `luci-app-gecoosac` 页面 | 删除 `gecoosac.js` |
| Podman 市场无安装入口 | rpcd `podmanmarket` 无 install 方法 | 增 `install_app()`（`apk update && apk add -y podman`）+ 前端按钮 |

两处踩坑，避免重复：

- 注释里写 `bootstrap*/cascade.css` 的 `*/` 会提前结束注释，整段 CSS 被浏览器丢弃
  （`cssRules.length` 仍显示原数量，容易误判「已生效」）。
- 往 `60_wifi.js` 第 1 行后插代码会切断 `if/else`，报
  `In strict mode code, functions can only be declared at top level or inside a block`；
  必须追加到文件末尾。

验证环境：Playwright（`/tmp/pwtest`，`playwright-core` + `/usr/bin/google-chrome`，
必须加 `--no-proxy-server`，否则被本机 7890 代理拦截）。登录用
`page.evaluate(() => document.querySelector('form').submit())`（root/空密码）。

实测结果：概览页 0 个 pageerror、4 个 `.gwrt-render-badge`；
软件包筛选 docker 后安装按钮 1440/1024/780 三档 9/9 在视口内（GWRT 58px、
bootstrap 69px）；81 端口出现「返回 GWRT」按钮（99×28），点击落到
`http://192.168.3.3/cgi-bin/luci/...`（80 端口）且主题为 GWRT。

## 4. 未解决

- **Podman 一键安装仍失败**：设备 `apk update` 报
  `ERROR: wget: exited with error 8`，`downloads.immortalwrt.org` 不可达；
  属网络/代理问题，固件层改不了。
- 主题修复通过 init 脚本在运行时给 feed 资产打补丁（`30_network.js`、`60_wifi.js`、
  `cbi.js`、`bootstrap/cascade.css`）。上游 feed 升级会重置这些文件，
  但 `/etc/init.d/gwrt-theme` 每次 start/reload 都会按标记字符串重新追加。
- 81 端口控制台仍有既有噪音：`protocol/relay.js 404`（无 relay 协议）、
  `X-Frame-Options may only be set via an HTTP header` 警告，与本轮改动无关。

## 5. 回滚

```sh
cd /home/godsun/build/gwrt-ss01-nss-261120
git revert --no-edit 10dfa31e b186b038 d80bda24 8dab0544 0a1f5b54 63daa811 7c72f0f3
```

设备侧临时回滚：删除 `/usr/share/gwrt/render-badge.js`、
`bootstrap-package-manager.css`、`native-return-link.js`，从已安装的 apk 中恢复
`30_network.js`、`60_wifi.js`、`cbi.js`、`bootstrap/cascade.css`，
或直接刷回 `261123-06`/`261123-01`。

## 6. 版本

- `261123-04`：LAN 时钟修复，LAN 可用
- `261123-05`：NSS 固件符号链接修复，NSS/PPE 卸载生效
- `261123-06`：流量曲线、拓扑图、赞助页、Podman 入口、renderBadge、bootstrap 软件包
- `261123-07`：GWRT 主题软件包动作列 + 原生主题「返回 GWRT」，run `45345721753`
