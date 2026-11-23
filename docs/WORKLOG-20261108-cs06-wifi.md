# WORKLOG 2026-11-08 — CS-06 无无线日志与修复候选

> 2026-11-09 后续：SS-01 已通过串口定位有线故障为 DT/驱动不匹配，
> 首页 CSS 缺失已热修复。以下早期 mesh 推断已被新证据更新，详见
> [SS-01 主题与网口记录](WORKLOG-20261109-ss01-theme-ethernet.md)。全部构建仍停止。

## 用户范围

本轮只构建：RE-CS-06、360T7 原厂 DTS（不选 UBI）、
RE-CS-02、RE-CS-02-GWRT2、RE-CS-07、S20P。S20P 必须带 PCI/NVMe。
用户随后确认 TR3000 当前版本 Wi-Fi 正常，本轮停止排查并取消其编译。
CS-01 尚无对应 profile，不用其它设备代替。CS-07 为无无线硬件，不加入无线驱动。
交付只收 factory（设备支持时）和 sysupgrade 镜像。

## 日志证据

用户提供 `/home/godsun/Downloads/log-11.7.rar` 和 `log-11.8.rar`。
两份日志在同一步失败：

```text
Booting fw image ath12k/IPQ5332/hw1.0/q6_fw0.mdt, size 11812
error -5 initializing firmware ath12k/IPQ5332/hw1.0/q6_fw0.mdt
Failed to load program segments: -5
RootPD boot failed
failed to boot the remote processor Q6
probe with driver ath12k_wifi7_ahb failed with error -5
```

后续 PCI QCN9274 HW2.0 被识别，选择 board ID 0x2，但未见无线注册成功。
现有 WSI 设备组包含 AHB 和 PCI 两个成员，不能把 PCI 枚举成功等同于 AP 可用。

`firmware-2.bin` 缺失不是本次确认的漏包：IPQ5332 使用 split MDT/API-1，
`ath12k_fw_map()` 在 API-2 请求失败后回退 API-1；所固定的专用固件仓库本来
没有这个文件。不能创建空文件或把其它芯片固件改名替代。

## 源码遗漏与候选修复

逐步追到 `qcom_mdt_pas_init()`：日志中的 `initializing firmware` 错误由
`qcom_scm_pas_init_image()` 返回，发生在程序段拷贝和 Q6 启动之前。
因此不能先归因为 SSID、hostapd 或板级校准数据。

当前补丁集已引入 WCSS secure PIL 驱动，却缺少同系列的 SCM 元数据长度补丁。
高通上游明确说明 IPQ5332 TrustZone 需要这个长度：

<https://lore.kernel.org/r/20260803-rproc-v14-1-a1f87b0b0ad2@oss.qualcomm.com>

新增 `2010-00-firmware-qcom-scm-pass-IPQ5332-PAS-metadata-size.patch`，
适配本树 Linux 6.18 的 SCM 实现：探测 PAS INIT_IMAGE_V2（0x1a），支持时
使用三个参数传递 metadata size；不支持时保留旧命令。没有绕过固件认证，
没有改动 DTS、校准偏移、固件字节或专用固件策略。

固件源归档中 q6_fw0.mdt 恰为 b00 + b01，长度 11812；SHA-256 为
`cbeaccd7f7dae3a751594c9640e47f9b2a892c7e92b40398ed38c297fbbed79e`。
上游 2026-11-07 刷新未改变这套 IPQ5332 的 MDT/分段文件，故本次不盲升固件。

这是一项已确认的源码遗漏，也是当前有依据的修复候选；仍需实机验证它是否
解释本机全部故障。不能在新日志确认前宣称 Wi-Fi 已恢复。

## 验证与编译

- 新补丁以 `patch --fuzz=0` 应用到现有 qualcommbe/ipq53xx Linux 6.18.55 内核，
  两个文件均无 reject。
- 使用现有 aarch64 GCC 14.4 工具链、J6、CPU 0–5 重新交叉编译
  `drivers/firmware/qcom/qcom_scm.o`，退出码 0。
- 用户日志为 Linux 6.18.60 / 源码 c2afcb3；另从官方 stable v6.18.60
  获取 SCM 两个文件，验证新补丁同样可用 `--fuzz=0` 精确应用。
- `sh scripts/gwrt-source-preflight.sh` 通过：主题副本、JS/shell/JSON、
  aria2、机型筛选、SoC 线程显示、固件收集和 APK 首次恢复检查通过。
- 技能旧 audit 仍假定已不存在的包目录，并误要求 LAN Makefile 使用字面量；
  本树采用已有 `$(if CONFIG_TARGET_PREINIT_IP,...)` 回退配置，实际默认地址仍为
  192.168.3.3/24。该历史差异见 2026-11-07 工作记录，不为旧检查器重写原配置。
- 未连接、刷写或重启用户设备。

旧 CS-06 单独编译 run `42479128610` 已取消，防止未修复镜像自动发布。
选定队列 run `42478183710` 的旧 CS-06 配置筛选失败已另行修复，MT7981
仍在运行；此记录不表示新固件已完成或通过实机验收。

### 修复候选已推送

- 原子提交 `317e7ad8f8ebd6b53090a2586ac451821a39724c` 只新增 SCM 补丁和本记录。
- CS-06 验证版 `261108-02` 的单独编译：
  <https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/42481730924>。
  创建时间为 2026-11-08 20:45:30（Asia/Shanghai），已开始运行。
- 参数为 `device=cs06`、`models=jdcloud_re-cs-06`、`images=flashable`、
  `release=false`。成功后只产生 factory/sysupgrade 下载 artifact，
  实机验证前不自动发布正式 release。
- 重新验证已展开配置 `/tmp/gwrt-ipq-selector.bYh4LK/cs06.config`：
  qualcommbe/ipq53xx、单一 RE-CS-06 profile、ath12k、IPQ5332/QCN9274
  专用固件、RE-CS-06 板级包和 wpad-openssl 检查通过。
- TR3000 当前版本的 Wi-Fi 已由用户确认正常，不再排查或重新编译。

### TR3000 移出当前队列

- 旧队列 `42478183710` 原本正在合并编译 TR3000 和 360T7；已确认整条旧队列取消完成，
  避免继续消耗资源编译 TR3000。没有取消单独运行的 CS-06 修复候选任务。
- `gwrt-soc-queue.yml` 的 MT7981 任务只保留 `qihoo_360t7`，未改动原预设文件
  或设备定义。队列增加 `skip_cs06` 参数，以便恢复其余机型时跳过已单独运行的 CS-06。
- 后续顺序：360T7 → CS-02 → CS-02-GWRT2 → CS-07 → S20P。
- 本次只调整本轮构建范围；TR3000 已有正常固件和机型源码保留。
- 调整提交为 `99fec13ce4d41e352cc178ee4747c8027d545b34`。新队列
  <https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/42483117795>
  于 2026-11-08 21:03:31（Asia/Shanghai）创建，版本 `261108-02`，
  `release=true`、`skip_cs06=true`。已核对云端使用该提交，CS-06 job 正确跳过，
  MT7981 job 已运行，模型列表只有 `qihoo_360t7`。单独的 CS-06 修复构建仍在运行。

### 本轮停编与 SS-01 串口/有线诊断（2026-11-08）

- 用户要求停止全部构建。GitHub Actions 当前相关运行均已结束：
  - `42483117795`、`42481730924` 已取消。
  - `42478183710` 已取消；CS-06 的 `Generate config` 失败、MT7981 编译被取消，
    其余机型跳过，因此该运行没有固件产物。
  - `gh run list` 未见进行中的任务；较早已成功的运行未改动。
- 串口 `/dev/ttyACM0` 用 115200 8N1、无流控、`--noreset` 被动监听；20 秒十六进制
  监听记录为 0 字节。未向设备发按键/命令，也未复位。历史记录曾记载此适配器读到连续
  `0xFF`，当前结果只能说明监听期间没有收到字节，不能据此判定设备启动状态。
- 本机有线口 `eno0` 曾协商到 1 Gbps，但 NetworkManager 的 `dhcp-probe` 45 秒未取得租约，
  接口没有 IPv4；通过 `eno0` 对 `192.168.3.3` 的 ARP 请求无响应。之后载波变为 off，
  当前 `NO-CARRIER`。本机 Wi-Fi 是 `192.168.9.210/24`，所以在有线口无地址时，
  `ip route get 192.168.3.3` 走的是 Wi-Fi 网关 `192.168.9.9`，不是直连 SS-01。
  未取得 sudo 权限，因此没有写入本机网络配置或添加临时静态地址。
- SS-01 既有 mesh 联调记录确认 AP 模式会将 `br-lan` 设为 `192.168.9.156/24`，并设置
  `dhcp.lan.ignore=1`。本次从 Wi-Fi 侧对 `192.168.9.156` 的 ICMP 与 TCP/22 可达，
  但 SSH 凭据未通过；HTTP 80、HTTPS 443 及 HTTP 81 未能连接，故未读到这台设备的
  主题文件或运行日志。`192.168.9.159` 本次 ping 无响应。结合既有状态，mesh/AP 模式
  导致管理地址离开 `.3.3` 且不再由 SS-01 提供 DHCP，是当前最符合证据的解释；串口和
  有线载波异常仍需实机复测。
- 首页主题静态检查：`gwrt-theme-V3/theme`、实际 `package/gwrt-theme` 和 CI 工作树中的
  `index_gwrt.ut` / `cascade.css` SHA-256 一致，`integrate.sh --check --no-config` 通过，
  构建 workflow 会从 `gwrt-theme-V3/theme` 同步到打包目录。未发现编译输入中的模板/CSS
  副本错位。首页设备卡片由模板提供并由 JS 写入计数；网速历史由 JS 每 5 秒采样，保留
  最近 60 个点，明细弹层在 CSS 中仅对图表 hover 显示，标题标注“每分钟”与实际采样
  粒度不一致。尚无 SS-01 页面运行时证据，不能把设备卡片缺失归因于 CSS。
- 本轮未修改固件、主题代码或本机网络配置，也未重启/刷写 SS-01；全部相关构建保持停止。

### 追加：SS-01 重置后直连与 mesh 复核（2026-11-09）

- 用户截图显示设备已运行约 18 分钟，页面识别为 `GWRT-0000` / IPQ6010，固件
  `gwrt 261107-02`，WAN 显示 DHCP 已连接；截图没有显示管理地址或 mesh 角色。
- `/dev/ttyACM0` 以 115200 8N1 被动监听 18 秒，没有收到字节；没有发送按键或命令。
- `eno0` 检查时一度有载波并协商 1Gbps。本轮用临时 `192.168.3.2/24` 地址直连探测
  `192.168.3.3`，ARP、ICMP、HTTP、HTTPS、SSH 均无响应；之后 `eno0` 载波变为 0。
  当前有线口无链路，主机已恢复连接 AX6600 Wi-Fi，移除了本轮创建的两个临时 Wi-Fi 配置。
- 无线扫描短暂看到 `GWRT_2.4G_7CCA` / `GWRT_5.2G_7CCA`，对应 SS-01 的 BSSID；发起
  关联时网络已不可见，后续扫描也未再出现。
- 主 AP `192.168.9.9` 可访问，但拓扑当前只有已配对的 `360T7-F3`；`wifiroam.discover`
  为空。按 SS-01 MAC `DC:D8:7C:48:7C:CC` 发起配对返回 `not_found`，没有写入配对状态。
- 主 AP 历史日志确认 SS-01 曾以 `.CC` / `.CB` 无线接口关联隐藏 `mesh-gwrt`。`.CB` 于
  23:30 获得 `192.168.9.157` DHCP 租约，主机名 `GWRT-0000`；23:48 因
  `excessive missing ACKs` 断开，23:53 离开。到 2026-11-09 00:06，主 AP 邻居表中
  `.157`、`.158`、`.159` 均为 `FAILED`，主机也无法访问这些地址。
- 当前结论：截图时 SS-01 已启动，并曾短暂接入主 AP 的无线回传，但没有完成 mesh 配对；
  之后回传掉线。`.9.156` 当前是主 AP 识别为 `iptv-cups` 的客户端，不是 SS-01。
  下一步需等无线回传恢复，或让 SS-01 WAN 临时有线接入主 AP LAN，再从发现列表配对。
- 本轮没有重启、刷写或更改任何路由器配置；编译任务继续保持停止。
