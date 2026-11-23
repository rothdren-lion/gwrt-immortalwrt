# WORKLOG 2026-11-09 — SS-01 首页主题与有线网口诊断

## 当前结果与范围

用户要求继续串口排查 SS-01 LAN 无法取得 IP，并比较已落入固件的主题与主 AP
192.168.9.9。全部固件构建继续停止；没有刷机、重启或重新启动云端任务。

- SS-01 的首页 CSS/模板已热修复并用实际浏览器验证。
- 有线故障已定位到设备树与以太网驱动不匹配，源码已准备修复候选；
  当前设备仍运行原内核/DTB，有线网口尚未恢复，不能宣称 DHCP 直连已经修好。
- TR3000 当前 Wi-Fi 正常，本轮没有修改或编译。SS-01 继续使用专用 DD-WRT AHB 固件。

## 设备身份与串口证据

串口 `/dev/ttyACM0`、115200 8N1，无流控。设备报告：

- model：JDCloud RE-SS-01；compatible：jdcloud,re-ss-01 / qcom,ipq6018。
- `/sys/devices/soc0/machine`：IPQ6010，4 个 CPU 线程。
- 固件 261107-02，源码 c2afcb3，Linux 6.18.60；主题 APK 1.0-r113。
- `br-lan` 为 192.168.3.3/24，桥中只有 phy0-ap0、phy1-ap0。
- 无线回传接口 phy1-sta0 获得 192.168.9.159；主 AP 是 192.168.9.9。

`/sys/class/net` 没有 eth0、lan1、lan2、lan3 或 wan；串口 dmesg 明确报告：

```text
ssdk_dt_get_switch_node[1514]:WARN:cannot find ess-switch node
regi_init[2049]:INFO:qca-ssdk module init, no device found!
```

运行中的 DT 使用 `qualcomm,ipq6018-ppe` / `qualcomm,ipq6018-edma`，但固件加载
的是需要 ESS 节点的 qca_ssdk；没有 qca-nss-dp 模块。CI 保存配置
`config.ci-ss01-261030-01` 还明确禁用了 kmod-qca-nss-dp。
dnsmasq 对 Wi-Fi 客户端有正常 DHCPACK，故这次有线取不到 IP 有更直接的底层原因。
此前工作记录中的 mesh/AP 模式解释是取得串口前的假设，不再作为本机有线故障结论。

## 主题根因：构建压缩器删掉现代 CSS

主 AP 身份已核实为 JDCloud RE-CS-02 GWRT2，固件 260920-05、Linux 6.18.52，
主题 APK 1.0-r111，另有此前热更新。两机修复前首页模板同为 298976 字节，
SHA256 `4847e7e7a78b57836ea564c728940c9e664897a8df46b889f8a398a00385d610`。

| CSS | 字节 | SHA256 |
|---|---:|---|
| 源码 / 主 AP / 修复后的 SS-01 | 216892 | f6fa8c3612ce4271f888ae42e206d0ef7253fdfab518b3e50df386a88d560260 |
| SS-01 修复前 | 182044 | a256e36c958d76381b1aab49af16e615de3a3dc53047b60705c6725fe0bd10f4 |

用现有 host CSSTidy 1.3 和 LuCI 配方原参数，精确复现了错误文件的字节数和 SHA256：

```sh
staging_dir/hostpkg/bin/csstidy \
  gwrt-theme-V3/theme/luci-theme-gwrt/htdocs/luci-static/gwrt/css/cascade.css \
  --template=highest --remove_last_semicolon=true /tmp/reproduced.css
```

缺失规则包含 `.gwrt-netspeed-head`、`.gwrt-devpair`、`.gwrt-wan-trend-popup`、
`.gwrt-home-menu-tabs`；这会使网速明细常驻、设备计数挤在一起、卡片异常拉长。

额外比较了两机 `/www/luci-static/gwrt` 各 719 个静态文件：

- 修复后公共文件除 gwrt.js 外均同 SHA256。
- gwrt.js 的差异可由现有 jsmin 精确复现，SS-01 SHA256 为
  `c0553df24a80cb96c0aa361978c6f702021af392335c5ea718d5e671b3864c79`，没有发现源码不同。
- 主 AP 多出的 app-domain-map.json 与两机已有 oaf-app-map.json 同 SHA256
  `89b8ada95d9c6f87ae0a0d405f0b2a45695267480b4488ece18ddf897c301c94`；
  JS 优先加载 oaf-app-map.json，因此不需要补一个重复别名。
- SS-01 另有 pon.css，不影响本次首页。

## 源码与设备上的主题修改

修改源为 `gwrt-theme-V3/theme/luci-theme-gwrt`，通过 integrate 同步到 package 平铺
和嵌套副本，最终 `--check --no-config` 通过：

- Makefile：`LUCI_MINIFY_CSS:=0`，PKG_RELEASE 114；保留完整 CSS。
- header/header_login 与 footer/footer_login：资源缓存版本 20261109r114。
- index_gwrt.ut：明细标题改为每 5 秒采样；历史值为上下行总量，去掉错误的下行箭头；
  SoC 显示为型号 × 线程数，SS-01 实测 IPQ6010 × 4。
- gwrt-socinfo：优先读取内核报告的 machine，避免把 IPQ6010 识别成 DT 家族 IPQ6018；
  使用显式字母表转小写，兼容设备 BusyBox tr 不支持字符类的情况。
- source-preflight：检查三份包的 CSS 压缩开关和必要规则；SoC 测试覆盖硬件字段优先
  和无效字段回退，并使用 BusyBox tr 再测一遍。

SS-01 热更新了 CSS、首页模板、四个主题头尾模板及 gwrt-socinfo，共 7 个文件。
没有伪造 APK 数据库版本；设备 theme-version 仍为 1.0-r113，
`/usr/share/gwrt/theme-hotfix` 单独记录 r114 热修复。

实机更新后模板 SHA256：
`e1b0b6f64e37cb5427e2eddbfd9037a23b88bc006266ae4548a6120417a8db61`；
helper SHA256：`5346f2c13dff878611f3d4f192a83730bf4c0d8e68cc45ed04037d94a47971e6`，
均与最终源码相同。

## 有线修复候选

- SS-01 DTS 从现有本地 NSS 移植恢复 `ipq6018-ess-nss.dtsi`、ESS/EDMA、dp2–dp5，
  对应 lan1/lan2/lan3/wan；保留现有 GPIO、mesh 按键、USB host、eMMC、DD-WRT
  AHB 校准和 0x3700000 Q6 保留区。
- 直接包含 ipq6018.dtsi 并设置 Q6 保留区，避免使用引用不存在 ramoops_region 标签的
  旧 ipq6018-512m.dtsi；未修改共用 DTSI。
- 设备 DEVICE_PACKAGES 加 kmod-qca-nss-dp；保存的 CI 配置启用该包。
- 配置/最终 manifest 检查要求 qca-nss-dp + qca-ssdk，并核对 NSS DTS 与四个端口。
  修改前的配置被检查器明确拒绝；修正后通过。
- 保留当前工作树既有 KERNEL_SIZE=12288k，没有根据旧技能中的 6M 描述擅自回退布局。

只用现有 Linux 6.18.55 源码加仓库 qualcommax DT 补丁在临时目录做 CPP/DTC 检查，
没有编译固件或内核。DTC 返回 0，DTB 31155 字节；共享 NSS DTSI 有 62 条 warning，
日志完整保留。解析输出确认 ESS、EDMA、NSS DP、四个端口和 SS-01 校准项。
DTS SHA256：`27b89ce390b805a920aaff18848d25c8e24dc1b9905d688da56dc5e2cc467311`。
这些检查只能证明候选可解析，仍需后续新固件实机验证网口、端口对应及 DHCP。

## 验证、备份与清理

- 全套 `sh scripts/gwrt-source-preflight.sh` 通过，含主题副本、JS/shell/JSON、
  机型筛选、SoC、固件仅 factory/sysupgrade 和 APK 首次恢复检查。
- SS-01 浏览器验证：1440 与 390 宽度、深浅两种主题；设备/TCP/UDP 计数正常，
  网络卡片高 196px，明细默认隐藏、hover 展开、移出隐藏，无横向溢出，
  无 pageerror 或失败请求。另以浏览器本地模拟 60 个样本验证明细不会撑大卡片；
  final 截图与 browser-final 记录使用真实页面采样，不含模拟流量。
- 本机临时 HTTP 服务 18081、到 SS-01 的 SSH 隧道 18080 已撤除；
  SS-01 仅允许主 AP 临时访问 HTTP 的 nft 调试规则 handle 257 已删除。
  未写入路由器 UCI/firewall 持久配置，未更改本机网络配置。
- GitHub 最新相关任务均 completed，用户要求取消的四个运行仍为 cancelled；未推送
  本轮源码、触发新构建或发布固件。

完整备份与证据目录：
`/home/godsun/build/gwrt-backups/20261109-ss01-theme/`。
含原主题、最终 7 文件热修复包、深浅/手机截图、对比清单、串口证据、测试输出、
DTS 验证材料及改网口前源码备份 source-before-ethernet。

| 归档 | SHA256 |
|---|---|
| ss01-before-r114-complete.tgz | 39c77da65b2f5b90f82b11a1baf2564e14ed4a3bc59f6596a8d332bdbe643030 |
| ss01-theme-r114-final.tgz | dc027c0518398e235ac391224b5282c26f8825ba3e5ab7c0ee53cb23fc8642ac |

设备上原主题备份为 `/root/gwrt-theme-before-r114-20261109.tgz`，包含 7 个原文件。
若需回滚主题，在 SS-01 执行（不需要重启）：

```sh
tar -xzf /root/gwrt-theme-before-r114-20261109.tgz -C /
rm -f /usr/share/gwrt/theme-hotfix /tmp/luci-indexcache /tmp/luci-modulecache/*
```

## 后续边界

当前首页修复已在 SS-01 生效。当前有线网口仍需未来新固件，用户停编指令继续有效；
恢复构建时必须先核对 SS-01 分区布局，并使用修复后的保存配置、DTS 和主题 r114。
