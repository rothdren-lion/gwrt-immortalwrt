# WORKLOG 2026-11-11 — SS-01 LAN 收发包全 0：NSS 端口 MAC 时钟停在 1.5 MHz

## 现象

用户报告「DHCP 获取不到 IP」。电脑网线直连 SS-01 LAN 口，
`GWRT 261110-02`（`e39c9f3`）上拿不到 `192.168.3.x`。

同时该版本已确认**不再重启**（旧 261109-01 的
`/etc/init.d/gwrt-caldata` 缺 caldata 就 `sleep 8; sync; reboot`
是另一件事，261110-02 已带 caldata，uptime 8 万秒无重启）。

## 排除项（都正常）

| 项 | 结论 |
|---|---|
| dhcp 服务 | `udhcpc -i br-lan` 本地拿不到；改 veth + netns 模拟真实客户端，**拿到了 `192.168.3.227`**，网关/DNS 正确 |
| DHCP 池 | `192.168.3.100-249`，`br-lan` = `192.168.3.3/24`，配置无误 |
| PHY 驱动 | 4 个口都绑 `Qualcomm QCA8075`，`phy_id 0x004dd0b1` |
| SSDK 初始化 | `qca-ssdk module init succeeded`，`uniphy 0 psgmii channel selection` |
| 网桥 | 口都 `isolated=0 learning=1`，STP 关闭 |
| WAN | 曾 `Link detected: no`；WiFi STA 上行正常（`192.168.9.158`，默认路由在） |

## 决定性的三条证据

1. **TX 计数不涨**：在 `lan1` 上 `ping`，`tcpdump -i lan1` 能看到帧，
   但 `ethtool -S lan1` 的 `tx_broadcast / tx_unicast / tx_pkt64` 全是 **0**。
   帧进了内核队列，交换机端口没往线上发。
2. **物理回环不通**：网线一头 LAN1、一头 LAN2（两侧 `carrier=1`），
   从 `lan1` 发 ARP，`lan2` 的 `rx_broadcast / rx_pkt64` 全 0，
   `tcpdump -i lan2` 抓不到任何包。
3. **时钟速率不对**（根因）：
   ```
   nss_port2_rx_clk_src       24000000      ← 24 MHz XO
   nss_port2_rx_div_clk_src    1500000      ← /16
   gcc_nss_port2_rx_clk        1500000      ← 真正进 MAC 的时钟
   ```
   1 Gbps MAC 需要 **125 MHz**，实际只有 **1.5 MHz**。
   port3/4/5 同样 24 MHz；`clk_parent` 全部回落到 `xo`。

## 根因

`target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-ess-nss.dtsi`
末尾有一段自加 override：

```dts
&gcc {
	clocks = <&xo>, <&sleep_clk>;
	clock-names = "xo", "sleep_clk";
};
```

patch `0145` 给 GCC 加了 `uniphy0/1 rx/tx` 四个父时钟，这段 override 把它们
全砍掉了。而 `gcc-ipq6018.c` 里 `nss_port1..5_{rx,tx}_clk_src` 的
`parent_data` 第 2..5 项正是这四个 uniphy 时钟 —— `of_parse_clkspec()`
按 `clock-names` 在 gcc 节点里找，找不到 → 父时钟 NULL →
`__clk_rcg2_select_conf()` 跳过所有 `P_UNIPHY0_RX/TX` 配置 →
回落到 `F(24000000, P_XO, 1, 0, 0)` → 再经 `/16` 分频 = 1.5 MHz。

设备 DT 实测印证：`/proc/device-tree/.../clock-controller@1800000/clock-names`
只有 13 字节 = `"xo\0sleep_clk\0"`，且 DT 里没有任何 uniphy 节点。

`nss_port5_rx_clk_src: can't find a configuration for rate 125000000`
（WAN 口）是同一个根因的另一处表现。

**这是全平台独有的问题**：ipq60xx 里只有 SS-01 用 `ipq6018-ess-nss.dtsi`，
其它板子走主线 `ipq6018-ess.dtsi`。

## 为什么热插拔/ifup 都救不回来

SSDK 只在**速率变化**时调用 `adpt_hppe_gcc_port_speed_clock_set()`
（`adpt_hppe_portctrl.c`，`phy_status.speed != port_old_speed`）。
且 `clk_set_rate` 本身因为找不到 125 MHz 配置直接失败。
设备上 `clk_rate` 是 debugfs 只读（`clk_rate_set = NULL`，内核未开写支持），
所以也无法在运行时改时钟验证。

## 修复

在 `ipq6018-ess-nss.dtsi` 里补 4 个 125 MHz 固定时钟作为 GCC 父时钟。
QSDK 栈用 `qcom,ess-uniphy`（qca_ssdk 自己管 UNIPHY），没有可引用的
`uniphy0` label，所以不能用 patch 0145 的写法。

```dts
&soc {
	uniphy0_gcc_rx_clk: uniphy0-gcc-rx-clk {
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <125000000>;
	};
	/* tx / uniphy1 rx / uniphy1 tx 同理 */
};

&gcc {
	clocks = <&xo>, <&sleep_clk>,
		 <&uniphy0_gcc_rx_clk>, <&uniphy0_gcc_tx_clk>,
		 <&uniphy1_gcc_rx_clk>, <&uniphy1_gcc_tx_clk>;
	clock-names = "xo", "sleep_clk",
		      "uniphy0_gcc_rx_clk", "uniphy0_gcc_tx_clk",
		      "uniphy1_gcc_rx_clk", "uniphy1_gcc_tx_clk";
};
```

要点：
- 索引 0/1 保持 `xo` / `sleep_clk`（这两个 gcc-ipq6018 是按名字取的）。
- 索引 2..5 顺序必须与 `gcc-ipq6018.c` 的 `parent_data` 一致。
- 固定时钟**不带** `clock-output-names`，避免与 `qca_ssdk` 注册的同名时钟冲突。

已用本地 `cpp` + `dtc` 编译真实板级 DTS 验证：生成的 DTB 里
`clocks = <6 个 phandle>`，索引 2..5 全部指向 `freq=125000000` 的固定时钟。

## CI

`ss01` preset 原来用 `config.ci-ss01-261030-01`，那份**没有 NSS 包**
（`kmod-qca-nss-dp` 等全缺），编出来不是设备实际跑的东西，修复也无从验证。
已改为仓库里已有的 `config.ss01-261101-01-nss`（有全部 NSS 包）。

另外两处 CI 阻塞（AGENTS.md 里记过，本仓也已修）：
- `target/linux/generic/config-6.18` 需补
  `# CONFIG_NET_DSA_TAG_RTL837X_8021AD is not set` 和
  `# CONFIG_NET_DSA_TAG_RTL9303_8021AD is not set`，否则内核
  `syncconfig` 报 `(NEW)` 直接 Error 2。

## 构建

本地磁盘只剩 ~6 GB，全量编不下（会触发整核重编 + 镜像生成），
改走 GitHub Actions 云端：

```sh
gh workflow run gwrt-build.yml -R rothdren-lion/gwrt-immortalwrt \
   -f device=ss01 -f version=261111-01
```

提交 `4e20145b`，run `42937429176` —— **已成功**，产物
`gwrt-261111-01`（内核 6.18.62，与设备现网一致）。

## 产物核验（已做，未刷机）

直接从 `factory.bin` 的 FIT 里剥出板级 DTB 检查，修复确实编进去了：

```
idx0 xo                  -> xo                  freq=24000000      OK
idx1 sleep_clk           -> sleep-clk           freq=32000         OK
idx2 uniphy0_gcc_rx_clk  -> uniphy0-gcc-rx-clk  freq=125000000     OK
idx3 uniphy0_gcc_tx_clk  -> uniphy0-gcc-tx-clk  freq=125000000     OK
idx4 uniphy1_gcc_rx_clk  -> uniphy1-gcc-rx-clk  freq=125000000     OK
idx5 uniphy1_gcc_tx_clk  -> uniphy1-gcc-tx-clk  freq=125000000     OK
```

对照：旧 `261110-02` 的 DT 只有 `"xo\0sleep_clk\0"`（13 字节），
新固件是 6 项且顺序与 `gcc-ipq6018.c` 的 `parent_data` 一致。

镜像 SHA256：
- factory `a0fe8bff7dd5133508aed4f85206c8f1f4e9868b819ebb0efb8e415ff95cd441`
- sysupgrade `b56157a334f534a0f999bee7f91b4b008d9b21e4766c7f0e4fd4631453888f2b`

交付归档：`/home/godsun/build/gwrt-releases/ss01-261111-01/`

## 待实机验证（刷入后逐条确认）

```sh
# 1. 时钟应为 125 MHz（关键判据）
grep -E 'nss_port[2-5]_(rx|tx)_clk_src' /sys/kernel/debug/clk/clk_summary
cat /sys/kernel/debug/clk/nss_port2_rx_clk_src/clk_parent   # 应为 uniphy0_gcc_rx_clk

# 2. TX 计数随发包增长
ethtool -S lan1 | grep -E 'tx_broadcast|tx_pkt64'
ping -c 3 -I br-lan 192.168.3.254
ethtool -S lan1 | grep -E 'tx_broadcast|tx_pkt64'   # 应 > 0

# 3. 回环与 DHCP
#    LAN1<->LAN2 回环：lan2 rx_packets 应增长
#    电脑接 LAN 口应拿到 192.168.3.100-249

# 4. dmesg 不应再有
dmesg | grep -iE "can't find a configuration for rate 125000000|rcg didn't update"
```

## 清理项

261110-02 上做过诊断留下的东西（新固件会自然消失，旧设备如回刷需手清）：
- `/tmp/dhcp.leases` 里的 veth 测试租约 `192.168.3.227`（`8a:f3:99:7b:5e:26`）
- `uci set dhcp.@dnsmasq[0].logdhcp='1'`（已 commit，诊断用）
- 诊断时给 `lan1/lan2` 加过的 `10.9.9.1/10.9.9.2`、`nomaster` —— 已恢复
  （重新入 `br-lan`，`ip -br addr show br-lan` 确认 `192.168.3.3/24`）

## 附：261110-02 上 LAN DHCP 服务本身正常的证明

用 veth + netns 模拟真实客户端，dnsmasq 正常应答：

```
udhcpc: broadcasting select for 192.168.3.227, server 192.168.3.3
udhcpc: lease of 192.168.3.227 obtained from 192.168.3.3, lease time 43200
```

所以「DHCP 拿不到 IP」不是 dnsmasq 的问题，是物理口根本不收发。