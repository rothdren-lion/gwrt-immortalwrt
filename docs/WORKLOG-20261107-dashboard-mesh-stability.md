# 2026-11-07 — 首页统计、设备回收与 mesh 稳定性修复

## 范围

用户要求调整容器位置、回收重复/长期离线设备、修正主 AP 连接数和设备图标容量、把 WAN 连接时间移到协议之后，并直接修复已通电子 AP 上 Wi-Fi 关联但偶发无网的问题。

现场先核对 `ubus call system board`：主 AP `192.168.9.9` 为 JDCloud RE-CS-02 GWRT2 / qualcommax/ipq60xx；本轮重新接通的子 AP 为 Qihoo 360T7 / mediatek/filogic，管理地址 `192.168.9.213`。旧地址 `.140` 不可达，`.131` 是同 MAC 过渡租约，不能据 IP 推断硬件。未刷机或重启设备。

## 首页与设备数据

- Docker/Podman 运行时存在时才显示独立居中的容器区，折叠独立于概述。
- 设备图标使用可用多行格位，超出容量才用末格 `+N`。
- WAN 当前协议和其实际连接时长一起显示。现场 WAN 是 DHCP，因此显示在 DHCP 后；不能硬编码 PPPoE。
- 原连接统计通过 rpcd `file.read` 读取 conntrack，较大内容被截断。新增 `/usr/libexec/gwrt-conntrack` 在设备端流式统计完整内容，返回 JSON；现场从十几条恢复到完整的一千多条，实际数值会随流量变化。
- 客户端记录规范 MAC、合并同 MAC；相同 IP 的旧离线占用记录由新活跃记录替代；真实同时在线的不同 MAC 不因 IP 相同被静默合并。
- 离线保留 24 小时，以最后真实在线时间回收；DHCP 租约只是元数据，不作为在线证据，也不能不断延长离线记录寿命。10 秒扫描执行回收，旧缓存读取不重置时间。
- 主题源和各安装副本校验一致，主 AP 更新前备份位于 `/root/gwrt-dashboard-fix-20261107-025924`。

验证：`python3 scripts/tests/test-gwrt-clients.py` 12 个行为用例通过；系统 awk 和 BusyBox awk 均已验证。完整 conntrack 大文件 fixture、IPv6/本机端点过滤和现场 JSON 检查通过。真实 Chrome/Playwright 检查 320–1920px、0/1/满容量/溢出/100/500 台设备共 54 个容量场景，图标计数、折叠、键盘操作和页面宽度均通过。现场刷新后 36 条记录，完整 MAC/IP 无重复，浏览器无页面错误。

## mesh 根因与修复

1. 主 AP 旧逻辑对低信号终端发送 `disassociation_imminent=true`、timer=5 的 BTM（约 0.5 秒），且未要求目标 SSID 相同。改为建议式 false/0，并要求同 SSID、已认证、新鲜在线且明确有线回传的邻居；无线 NAT 子 AP 不主动引导，不启用跨网段 FT/K/V。保留用户当前 aggressive/-62 配置。无线 NAT 保持既有同步 SSID 约定，手动跨网段移动仍可能携带旧 DHCP 租约，不能宣称该架构支持无缝漫游。
2. 相同无线配置重复下发也 reload。改为比较实际持久化无线配置，版本变化本身不 reload。
3. daemon 曾把无线 3-addr STA 写到 `lan`，AP helper 则需要 NAT 的 `wwan`，而签名缓存能掩盖实际配置漂移。统一有线/无线回传规则，并保证 `wwan` 不同时属于多个防火墙区域。
4. 临时控制面断连会把仍在正常桥接的有线 AP 恢复成路由，改变客户端网段。增加保留现有有线数据面的窄条件；显式解绑不受影响。
5. 子 AP 在 AP 模式切换时 `br-lan` ifindex 从 10 变为 12，5 GHz hostapd 仍持有旧 RRB socket，另有跨 BSS 共享 OUI socket；现场反复报 `l2_packet_send - send: No such device or address`。单独重建 5 GHz 只修好 RRB，OUI 仍有其他 BSS 引用。全部相关 FT BSS 先停完再一起启动后，两种 socket 均绑定当前 ifindex 12。源码加入检测及同签名一次修复，避免无限周期性重启无线。
6. 360T7 非 UBI DTS 的工厂分区名为 `Factory`，旧脚本用 `factory` 查不到 MAC，进而生成 `network.@device[1].macaddr=':'`。修正大小写并校验完整有效单播 MAC；无有效工厂值时保留驱动地址。增加仅删除 `:` 的一次性迁移，现场运行后实际网卡 MAC、接口列表、管理 IP 均不变。备份 `/root/gwrt-invalid-mac-fix-20261107/network`，未 reload 网络。
7. AP 快照补齐 LAN/WAN 静态地址、掩码、网关、DNS 原生 list、选项存在性和原 WAN 桥成员关系；兼容旧快照未记录字段，避免回退损失配置。
8. CAP 拓扑以前只在 SAP 上报 IP 为空时查本机 lease，因此 wired SAP 客户端可继续显示旧 NAT 子网地址。现在仅对有线桥接 SAP 优先使用 CAP DHCP 租约；无线 NAT SAP 的地址仍来自其子网，避免把不同网段误覆盖。

物理层也记录到主 AP lan1 在 02:55:19 down、02:55:22 以 1 Gbps up。这是链路抖动证据，不能说一定由漫游逻辑引起。子 AP 的旧 `.3.107` DHCP 文件记录不代表客户端当前地址：主 AP 02:57:32 已给同一 iPhone MAC 发 `.9.108`，子 AP dnsmasq 已停，当前有线桥接客户端地址由主 AP 分配。

## 验证与复测

- `python3 scripts/tests/test-gwrt-mesh-state.py` 使用实际 aarch64 UCI + qemu 的隔离配置，11 组通过：两类恢复路径的静态配置/DNS list、原桥成员、旧快照、原选项缺失，以及 shell 引号、MAC 输入校验和迁移幂等。
- `busybox sh -n`：apmode、MAC 迁移、02_network、Wi-Fi MAC hotplug 均通过。
- `python3 scripts/tests/test-gwrt-wifiroam.py` 动态抽取 production 函数，使用实际 ucode/UCI 隔离 fixture：重复配置/SSID/FT、BTM、回传模式/幂等、无线 NAT 隔离和 wired SAP 租约身份共 33 项通过；另有 10 项 AP 控制/数据面临时 fixture 通过。旧逻辑 replay 可重现无谓 reload 和不同 SSID 候选引导。
- 主 AP 当前 `ubus call wifiroam topology` 中子 AP iPhone MAC `06:8E:E3:34:FC:56` 显示 `.9.108`，与主 AP DHCPACK 匹配，不再沿用子 AP 缓存 `.3.107`。
- 子 AP 到主 AP、公网 IP、DNS 现场连通；定向修复后 child→CAP、公网及 CAP→child 各 30 次 ping 均无丢包。两端 wifiroamd 源哈希一致，CAP topology 里 iPhone 租约为 `.9.108`；主 AP 的无线配置哈希、接口索引和 hostapd PID 部署前后不变。无线终端重新关联与握手状态已查看，但路由器侧探测不能替代每台终端的长时间实际使用体验。
- 浏览器截图、部署差异及 fixture 临时材料位于 `/tmp/gwrt-20261107-review/`；该目录是临时证据，不是固件交付目录。

## 部署与构建树同步

- 主 AP `.9.9` 和子 AP `.213` 的 `/usr/share/wifiroam/wifiroamd.uc` 均为 `0ee38e679142fda21935a3efe35789879defc825d90aedbc27070080e2ac7d1f`，子 AP `/usr/libexec/gwrt-mesh-apmode` 为 `df0d7dca4144003e33ef20f60677451d133386d5a5e58e2b87838d6c1d8f611b`。
- mesh 更新备份两台均在 `/root/gwrt-20261107-mesh-backup-0328`；更新前后校验 source hash，两台设备均能 `ucode -c` 编译守护源码。仅重启 wifiroam 管理进程及子 AP apmode helper，主 AP 无线保持运行；子 AP 的 FT BSS 修复操作已单独记录。
- 有界同步本轮 mesh/MAC/主题修复到 `/home/godsun/build/immortalwrt-mt7981`。源与 build 树原有 Wi-Fi 默认值、SSID 命名、离线 APK 策略存在先前分歧，本轮保留 build 树这些策略，不整体覆盖包目录；保留 build 树无效无线快照的清理行为。
- build 树备份和同步清单：`/home/godsun/build/gwrt-backups/20261107-dashboard-mesh/`。build 树三套回归再次通过：wifiroam 33、state/MAC 11 组、clients 12。clients runner 支持只有 package 安装源码、没有 gwrt-theme-V3 开发目录的构建树。
- 本轮未重新编译整包固件；现网通过脚本热更新修复，未执行 sysupgrade 或 reboot。
