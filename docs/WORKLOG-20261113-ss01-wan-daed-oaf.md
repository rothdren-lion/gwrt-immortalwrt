# WORKLOG 2026-11-13 — SS-01 WAN 失联、daed 页面与 eMMC 工具

## 本轮范围与构建状态

用户要求停止 GitHub 编译，保留后续插件修改；检查 `.9.9` 的 daed 流量界面和
OAF 冲突，并排查 SS-01 插 WAN 后电脑无法访问的问题，后续 eMMC 固件加入 `sgdisk`。
用户自行给 SS-01 断电、等待后重新通电。本轮没有刷机、主动重启、卸载 NSS 模块，
也没有重新触发 GitHub 固件编译。

SS-01 `261113-03` 运行 `43354566787` 已取消，`261113-02` 运行
`43350331850` 同样已取消。结束前查询仓库的 `in_progress` 和 `queued` 运行均为 `[]`。
这些取消的运行没有本轮可交付成品。所有源码修改都是后续候选，不能当作已刷入修复。

隔离工作树 `/home/godsun/build/gwrt-theme-261113`，起点 `d34c3da9`。
NAS 源码树既有大量改动，只同步本轮文件和小范围补丁；没有 reset/stash/全量覆盖。

## SS-01：已复现与已修源码

设备为 `jdcloud,re-ss-01`，运行 `261113-01 / ce91005 / Linux 6.18.62`，
首页主题已在此前热更新为 r117。用户重新通电后，SSH 短暂恢复，数分钟后有线再次失联。

- LAN2 carrier=1、1000 Mbps，`br-lan` 一直为 `192.168.3.3/24`；未发现网段改变。
- WAN carrier=1、1000 Mbps，但收发计数为 0，DHCP 一直 discover。
- LAN2 接收包继续增加，发送停在 688 包；EDMA TX completion IRQ 停在 792，
  RX IRQ 继续增长。电脑 ARP 失败，CPU 与串口内核日志仍运行。
- WAN 建链时 `gcc_uniphy0_port5_rx_clk/tx_clk status stuck at 'on'`，调用栈来自
  SSDK 的端口时钟调整；启动已有 `ssdk_uniphy_port5_clock_source_set` 和
  `ssdk_uniphy_raw_clock_set: set parent fail`。
- 实机 debugfs 显示 port5 的 RX/TX 源均挂在 `uniphy1-gcc-rx-clk` 固定时钟下，
  与该板 UNIPHY0 PSGMII、UNIPHY1 disabled 配置不符。

检查源码确认：SSDK 用 `clk_register(NULL)` 注册 underscore 名称的动态 UNIPHY
时钟，而 NSS DTS 的旧方案给 GCC 提供另一组独立的 fixed-clock 对象。CCF 缓存这些
对象后，SSDK 传入自己的 raw clock 调用 `clk_set_parent()` 无法匹配，返回失败。
这是已证明的时钟对象不匹配；是否能彻底解决共享 EDMA TX 卡死仍须新固件验证。

修改如下：

1. 新增 `0921-clk-qcom-gcc-ipq6018-use-ssdk-uniphy-clock-fallback.patch`，
   给四组 UNIPHY parent_data 的 12 项增加同名 `.name` 回退，保留 `.fw_name`。
   普通主线 PCS 的 firmware/clkdev 查找顺序保持优先；SSDK 后注册的动态时钟可被查到。
2. `ipq6018-ess-nss.dtsi` 移除四个固定时钟占位，GCC 输入只保留 XO/sleep。
   当前仅 SS-01 引用这个 NSS include；没有变更端口、PHY、分区、无线或校准策略。
3. 新增 `scripts/tests/test-gwrt-ipq6018-uniphy-clocks.py`，直接抽取实际 CCF
   查找/重挂接及 RCG 选频函数和 GCC 表，在主机运行，不复制待修函数逻辑。

验证：

- 取 Linux stable 官方 `v6.18.62` 的 GCC、CCF、RCG 源码；补丁以 `--fuzz=0` 应用成功。
- 原始 6.18.62 负对照在 SSDK 父时钟发现处失败；修后 **68 项通过**，覆盖晚注册、
  未缓存的显式切换、固件优先、probe defer、clkdev 优先及 UNIPHY0/1 的 25/125 MHz 选频。
- SS-01 DTS 经 cpp/dtc 编译成功（存在原有 SSDK 节点 reg/unit-address 警告）。
  检查最终 DTB，GCC 的 clock-names 恰为 `xo sleep_clk`、两个 phandle，
  switch_mac_mode=0（PSGMII），switch_mac_mode1=0xff（disabled）。
- 完整项目 source-preflight 与 SS-01 配置检查通过；未交叉编译新内核、未刷入。

后期串口观察到 WAN link down、无线 STA 重新关联；电脑 `eno0` 已无 IPv4。
上游租约中 SS-01 STA MAC 对应 `.9.158`，但该地址 SSH 也未取得连接。
串口后期仍收到内核消息，shell 命令无新回应；不能据此声称网络已恢复。
没有尝试 devmem/寄存器写入、热改关键时钟或再次卸载 NSS。

## `.9.9`：daed 页面已部署，OAF 诊断结论

先确认 board 为 **JDCloud RE-CS-02 GWRT2**，内核 6.18.52；这是另一台路由器。
daed PID 为 27272，oafd PID 为 6836，前后保持不变。

现场旧 daed JS 只有开关/服务状态/打开 dashboard，没有源码中已完成的流量面板。
已备份并热更新以下三个文件：

- `/www/luci-static/resources/view/daed/config.js`
- `/usr/share/rpcd/acl.d/luci-app-daed.json`
- `/usr/lib/lua/luci/i18n/daed.zh-cn.lmo`

没有覆盖现场带额外修复的 daed init，没有修改订阅、代理配置或账号数据库。
真实页面 HTTP 200，显示流量登录面板和 `daed 运行中`，中文资源正常；桌面和
390 px 手机视口均无页面横向溢出，JS pageerror 为 0。验证用 LuCI session 已销毁。
手机截图中原主题侧栏打开时会遮挡正文，这是已有侧栏状态。

另用真实官方 ARM64 daed 二进制的隔离环境通过了登录/CORS/GraphQL、六个流量指标、
5 秒轮询、自定义实例、手机布局及凭据不落盘测试。现场 API introspection 确认
`General.runtimeOverview` 及各字段存在，无 JWT 返回 access denied。
**尚未使用生产 DAED 账号登录读取现场流量数值**，用户可在新面板使用原账号登录。

现场新文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| config.js | `690443f946c7bce51d92faee0cde6ae443d35c00127e70eec51f3a0c987b3db6` |
| ACL | `cf9564a6197a985a5dbf6df9ffb516bc6eefc3e04bacffb384ca4d3d999e22a3` |
| 中文 LMO | `73a1320331ea0254add08b490bab4e24785b2f49e598c708642f1b21acb37cc5` |

OAF 确定存在版本/API 混装：网页控制器调用 `ubus fwx common`，现场旧
`appfilter-2026.04.20~569f93bf-r1` 后台只导出 `appfilter`，没有 `fwx`。
网页调用失败后返回空默认值，足以解释空白数据。旧后台需要 appfilter.global，
现场配置已迁到 fwx；global 缺失时旧 API 返回 -1，lan_ifname 也有异常值。
内核 `appfilter_enable/record_enable/feature_init/feature_count` 均为 0。
内核接口 version=6.0.1 不能单独证明模块版本过旧，新源码也使用同一版本宏。

daed 的 TC ingress 在 br-lan，OAF 在 netfilter PRE_ROUTING/FORWARD；代理和硬件
加速可能导致统计盲区，但本轮没有切换代理/过滤开关做 A/B，**未证明两者实际互斥**。
未安装候选 OAF APK，未替换 daemon、feature 数据、内核模块或启用过滤规则。
后续若迁移 OAF，须整套匹配 userspace/init/rule_manager/config/feature/API，
不能只换一个 oafd 或把页面错误解释为 daed 冲突。

## eMMC 固件加入 sgdisk

- `gwrt-device-defaults` release 3→4，加 `+EMMC_SUPPORT:sgdisk` 条件依赖。
- SS-01 保存配置显式启用 `CONFIG_PACKAGE_sgdisk=y`。
- Airoha 没有统一 EMMC_SUPPORT，AN7581 两个 eMMC profile 的公共存储包加入 sgdisk，
  AN7583 EVB eMMC 的 DEVICE_PACKAGES 单独补上。
- 配置与最终 manifest 校验器要求上述 eMMC 场景带 sgdisk；去掉 SS-01 的选择后
  负对照正确失败，原配置通过。GNU make 实际展开三个 Airoha eMMC 设备包均包含 sgdisk。

注意 `gdisk` 和 `sgdisk` 在本树为两个包；本轮没有改 route-tool 的旧按需安装逻辑，
后者仍有优先尝试 gdisk 的代码，后续改该插件时应一并处理。
没有对实机分区表、eMMC 数据或已安装软件做此项改动。

NAS Airoha Makefile 和 an7583.mk 与隔离树存在此前的 DTS/镜像/包差异，本轮只合入
sgdisk 小改动，保留其它内容；NAS 与隔离树没有被强行统一。

## 证据、同步与回滚

证据根目录：`/home/godsun/build/gwrt-daed-oaf-20261113/`（0700）。
包含串口日志、断电后诊断、真实浏览器截图/结果、隔离 DAED 测试、补丁负对照/68 项
测试日志、DTS/DTB 与解析检查、GNU make 包展开、完整预检等。私密诊断数据库备份只在
本地受限目录，未输出或提交。

路由页面原文件备份 `daed-luci-before.tgz` 位于该目录，必要时传回 `.9.9`，
核对 tar 路径后解到 `/`，浏览器强制刷新即可回滚本轮三个页面/ACL/翻译文件。
NAS 被改源码的原件在 `source-before/`，按相对路径恢复本轮文件即可，勿全树覆盖。
源码补丁可从本轮提交按文件 revert，**不要对脏 NAS 树执行 reset --hard**。

待完成的实机验证：未来用户恢复编译后，核验新镜像的时钟父级、WAN DHCP、LAN/WAN
并发传输与多次插拔；DAED 生产账号登录后的真实流量；OAF 完整版本迁移及代理/加速 A/B。
当前所有 GitHub 固件构建继续停止。
