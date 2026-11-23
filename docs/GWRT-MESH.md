# GWRT Mesh（无线漫游组网）设计与实现

使用本文回传策略需安装 2026-11-19 更新的 GWRT Mesh 源码。已有配对可沿用。
有线与无线回传的普通客户端均由主 AP 分配 IPv4 地址，可从主网段直接访问从 AP。

---

## 1. 角色

| 角色 | 含义 | 行为 |
|---|---|---|
| `unconfigured` | 出厂/重置状态（默认） | 普通路由，使用原 LAN 地址、SSID 和路由服务；广播 HELLO 等待配对 |
| `cap` | 主AP（主路由） | 接受子AP 连接，下发漫游/回传/SSID/密码，可主动发现并配对未配置 AP |
| `sap` | 子AP | 保留配对；优先使用确认通往主 AP 的 WAN 口，断开后尝试无线 |

从 AP 回传建立后停止本地 DHCP。管理地址和客户端 IPv4 地址均由主 AP 的 DHCP 提供。

---

## 2. 组件与文件

| 包 | 关键文件 | 作用 |
|---|---|---|
| `package/gwrt-mesh-apmode` | `/etc/init.d/gwrt-mesh-apmode`<br>`/usr/libexec/gwrt-mesh-apmode`<br>`/etc/uci-defaults/98_gwrt-mesh-apmode` | 状态选择、接入检测、网络、无线、旧配置迁移和 FT 修复分别放在 `/usr/share/gwrt/mesh-apmode/` |
| `package/gwrt-mesh-led` | `/etc/init.d/gwrt-mesh-led`<br>`/usr/libexec/gwrt-mesh-led`<br>`/usr/libexec/gwrt-mesh-pair`<br>`/etc/rc.wps/50-gwrt-mesh`<br>`/etc/uci-defaults/99_gwrt-mesh-led` | mesh 状态灯 + WPS/MESH 键一键配对 |
| `package/gwrt-device-defaults` | `92_gwrt-wifiroam-fw`<br>`94_gwrt-lan-ip`<br>`95_gwrt-wifi-defaults`<br>`97_gwrt-wifiroam-defaults`<br>`98_gwrt-agent-defaults`<br>`gwrt-ssid-name`<br>`gwrt-wifiroam-autopair`<br>`files/wifiroam/wifiroamd.uc` | 首启默认值、SSID 命名、wifiroam 配置、防火墙放行、补丁版守护进程、自动配对；与 v5 共用 `mesh-state.uc`、`mesh-radio.uc`、`mesh-fronthaul.uc` |
| `package/gwrt-agent` | `/usr/sbin/gwrt-agent` | 上报 mesh 状态、接收 APP 下发的 mesh 命令 |
| `package/gwrt-theme/luci-theme-gwrt` | `lib/functions/gwrt-wireless.sh`<br>`etc/hotplug.d/ieee80211/30-gwrt-ssid-name` | SSID 命名保护（主AP 下发的同名 SSID 不会被改回本机后缀） |

---

## 3. 状态机（`gwrt-mesh-apmode`）

控制器每约 2 秒检查回传；保持 `wifiroam.core.role=sap` 和原配对。主 AP 每 5 秒发送发现广播。

| 状态 | 从 AP 的行为 |
|---|---|
| 待命搜索（默认 120 秒） | WAN 口保持隔离并尝试 DHCP；无线 STA 尝试关联隐藏回传。停止本地 DHCP/RA。 |
| 有线接入 | WAN 口收到匹配配对指纹、主 AP 源地址的近期广播并获同网段租约后，先关无线中继并确认 STA 断开，再并入 `br-lan`。从 AP 用 `lan` DHCP 拿管理地址。 |
| 无线接入 | 有线未确认时，用独立 STA 接口 `gwrt_mesh` 获管理地址，启动 IPv4 DHCP/ARP 中继。插错线继续走无线。 |
| 临时路由（默认 60 秒） | 两路都未连上，恢复原 LAN/WAN、SSID、密码及本机 DHCP。窗口到期继续搜索；确认网线已回到主 AP 时可以提前搜索。 |

拔线或检测到 WAN 已重新插过时退出桥接，确认 WAN 已脱桥后才启用 STA。桥接后若 25 秒内
没有在桥上重新收到配对广播并取到主网段 LAN 租约，恢复搜索。已完成组网的有线若 16 秒
没收到配对广播，仅在 WAN 载波、掉线计数、桥成员和主网段租约仍有效时，从 `br-lan` 每
约 4 秒探测主 AP。连续 3 次探测失败才退出；新网线仍须通过配对广播和 DHCP 验证。

重新连接后，从 AP 同步主 AP 的 SSID 和漫游配置。切换可能取得新的 IPv4 管理地址。
在主 AP 的 Mesh 拓扑点开从 AP，可查看回传方式、无线频段和最近切换原因，并直接打开
其 LuCI 管理页。链接使用当前已认证连接的 IPv4；连接关闭或状态过期后隐藏。

LuCI 的「无线漫游 → 回传切换」可分别修改两段时间（15–3600 秒），并显示
当前模式及管理地址。日常循环只使用 UCI 的运行时变更。路由模式的 LAN 地址、SSID 和
服务启用状态保留；需要保存正式网络或无线配置时，使用临时路由窗口，或先退出从 AP 模式。

### 强制退出 AP（不依赖网络）

| 方式 | 操作 |
|---|---|
| APP | `{"action":"mesh.apmode","enabled":0}` |
| 命令行 | `/usr/libexec/gwrt-mesh-apmode off` |
| 命令行恢复 | `/usr/libexec/gwrt-mesh-apmode on` |
| UCI | `uci set gwrt.mesh_apmode.enabled=0 && uci commit gwrt` |

`off` = 解绑（role=unconfigured）+ 回路由模式 + 停止广播（防止被主AP 自动配对回去）+ 停服务。
`on` = 允许自动切换并恢复广播（设备回到未配置，等主AP 再配对）。

---

## 4. 配对流程

1. 未配置的设备用 WAN 获得主网段地址；无网线时可用预设隐藏回传凭据先连无线。
2. 设备每 5 秒发 HELLO，主 AP 在「Mesh 配对」列出设备。
3. 主 AP 通过 TCP 50608 发 `join`，下发主 AP 地址、配对 token 和回传配置。
4. 从 AP 保存配对。回传就绪后连接主 AP，确认身份并同步前台 SSID 和漫游配置。

一键配对：WPS/MESH 键 → `/etc/rc.wps/50-gwrt-mesh` → `/usr/libexec/gwrt-mesh-pair`
（主AP 立即配对发现的设备；子AP 没连上则回到 unconfigured 等配对）。

自动配对：`gwrt-wifiroam-autopair` 常驻，主AP 每 60s 发现并配对一次；
运行中从 unconfigured 切成 cap 也会开始工作。

---

## 5. 前台 SSID 和漫游

前台 SSID 按频段同步主 AP 的 SSID、密码和加密；隐藏回传和访客 SSID 不参与。
从 AP 只在回传就绪时应用，临时回路由时恢复原值，重连后重新同步。相同配置
不反复重载无线。保留有线 FT bridge socket 修复；无线中继不转发 FT-over-DS 所需
的二层帧，禁用该方式。

## 6. 无线回传

- 主 AP 在可用的 2.4/5 GHz 创建隐藏 AP，出厂回传 SSID 为 `mesh-gwrt`。
  回传使用三地址 STA，避免旧 WDS 在部分设备上的掉线问题。
- 从 AP 的 STA 不加入 `br-lan`，由 `gwrt_mesh` DHCP 获取管理地址。没有成功记录时默认先试
  2.4 GHz，也可用 `wifiroam.backhaul.band=5g` 改首选频段。重连优先尝试同一配对最近一次
  成功的频段，不可用或等不到连接时轮试另一频段。记忆只保留在运行目录，不写入闪存。
- 通过 procd 直接运行 `relayd`，不依赖本树缺失的 netifd `relay` 协议。普通客户端的
  IPv4 DHCP、ARP 和流量经过中继，使用主网段，不经从 AP 的 NAT。
- IPv6 有线透传；无线配置了 odhcpd 的 RA/DHCPv6/NDP 中继，实际效果取决于主网 IPv6 和
  设备配置。无线中继不是完整二层桥，任意以太网协议和实机漫游连续性不作保证。

## 7. mesh 状态灯（`gwrt-mesh-led`）

| 状态 | 灯 |
|---|---|
| 已组网（主AP 有在线成员 / 子AP 已连上主AP） | 常亮 |
| 主AP 发现未配对设备 | 快闪（200ms） |
| 未配置 / 子AP 未连上 | 慢闪（700ms），**2 分钟后熄灭** |
| 已配置但无成员 | 灭 |
| 守护进程未运行 | 灭 |

- 默认 LED：有 `blue:status` 用蓝灯（XINGLOO）；否则 `red:status + green:status`（360T7，双亮=琥珀色）
- 配置：`uci set gwrt.mesh_led.leds='green:status'`（单灯）或 `'red:status green:status'`
- 闪烁用内核 `timer` trigger（busybox sleep 不支持小数秒）

---

## 8. 防火墙

`92_gwrt-wifiroam-fw` 放行（IPv4，不限来源网段，主路由可以是任意网段）：

| 规则 | 协议/端口 | 用途 |
|---|---|---|
| `Allow-wifiroam-udp` | udp/50607 | 发现（HELLO 广播） |
| `Allow-wifiroam-tcp` | tcp/50608 | 配对 + 配置同步 |

安全性由 wifiroam 自己的 nonce + token 校验保证。

---

## 9. APP / gwrt-agent 接口

### 上报字段（report payload 里的 `gwrt_mesh`）

```json
"gwrt_mesh": {
  "available": true,
  "role": "cap|sap|unconfigured",
  "cap_ip": "192.168.9.9",
  "peers_online": 1,
  "apmode": 1,
  "ssids": ["AX6600_Gaming-jdc", "Rodren"],
  "discover": ["40:A5:EF:69:25:69"],
  "discovered_devices": [{
    "mac": "40:A5:EF:69:25:69", "ip": "192.168.9.200",
    "name": "GWRT AP", "model": "Qihoo 360T7",
    "role": "unconfigured", "pairable": true, "last_seen": 1794024000
  }],
  "members": [],
  "refresh_interval": 5,
  "firmware": "GWRT 261025-33 cb793d3"
}
```

`discover` 保留 MAC 数组以兼容旧 APP；`discovered_devices` 提供可直接显示的名称、
地址、型号和添加状态，`members` 只包含已认证成员及其客户端数量，不暴露配对 nonce、
网络 token 或回传密码。`gwrt-agent mesh` 可单独读取上述状态。

发现对象为同一局域网内启用 GWRT/wifiroam 发现、角色为 `unconfigured` 的 AP；
已加入其它网络的 AP、禁用 Mesh 发现的设备和普通第三方 AP 不会被强行接管。
设备 HELLO 每 5 秒发送，180 秒未再出现即由守护进程清理发现记录。

主题首页显示待添加 AP 并通过已登录 LuCI 的 ubus 会话执行添加；也可进入
“无线漫游 → Mesh 配对”。首页、Mesh 页面及活跃 App 按 5 秒周期刷新，隐藏页面暂停，
请求未完成时不叠加刷新。`/mesh.html` 优先显示 wifiroam 数据，添加链接进入需要登录的
LuCI 配对页面；只在没有 wifiroam 时兼容旧 mesh11sd 数据。

### 命令（云端 pull → commands[]）

| action | 参数 | 作用 |
|---|---|---|
| `mesh.pair` | `mac`（可选；不填=全部发现的未配置 AP） | 配对 |
| `mesh.unpair` | `mac`（必填） | 移除指定成员 AP |
| `mesh.role` | `role` = `cap` / `sap` / `unconfigured` | 设角色（sap 只能由配对产生） |
| `mesh.apmode` | `enabled` = 0/1 | 0=强制退出 AP+解绑；1=允许自动切换 |
| `mesh.ssid_sync` | 无 | 主AP 立即重推 SSID/密码+k/v/r；子AP 重启 wifiroam 接收 |
| `system.reboot` | 无 | 重启（需 `remote_exec=1`） |
| `system.hostname.set` | `hostname` | 改主机名（需 `remote_exec=1`） |

`mesh.*` 默认允许（`gwrt-agent.main.mesh_control=1`）；角色及 AP 模式切换会按照状态机
修改网络配置。非 Mesh 的重启、主机名及原二进制配置命令仍需
`gwrt-agent.main.remote_exec=1`。设备绑定 token 命令保留原二进制的校验和结果回传。

命令兼容顶层 `action` / `kind` 及 `params` / `data` / `payload` 参数对象。
添加先检查是否已经入网；新请求只有在拓扑观察到已认证成员后才 ACK success，
无候选、拒绝、连接失败或未入网均 ACK failed。重复下发已完成的添加保持幂等。
SSID 同步沿用完整的当前 roam 配置，不覆盖用户的 FT、RSSI profile 和阈值。

`refresh_interval: 5` 描述本地界面周期；云端上报仍尊重服务端 `report_interval`，
无有效值时使用本机设置（默认 30 秒），限制在 5–3600 秒。网络超时保留错误日志，
不会自动更换已有 device_id / pair_token / local_token 或丢弃用户绑定。

本机调试：`gwrt-agent cmd '{"action":"mesh.pair","command_id":"t1"}'`

---

## 10. UCI 开关

| 键 | 默认 | 说明 |
|---|---|---|
| `gwrt.mesh_apmode.enabled` | 1 | 1=配对后自动切换回传；0=保持原路由模式 |
| `gwrt.mesh_apmode.search_seconds` | 120 | 待命搜索时长 |
| `gwrt.mesh_apmode.router_seconds` | 60 | 临时恢复路由的时长 |
| `gwrt.mesh_led.leds` | auto | `auto` / `blue:status` / `"red:status green:status"` |
| `gwrt.mesh_led.enabled` | 1 | 0=关闭状态灯服务 |
| `gwrt-agent.main.mesh_control` | 1 | 0=拒绝 mesh.* 命令 |
| `gwrt-agent.main.remote_exec` | 0 | 1=允许重启/改主机名等危险命令 |
| `wifiroam.core.role` | unconfigured | 当前角色 |
| `wifiroam.backhaul.ssid/key` | 固件预设 | 回传凭据，可在主 AP 修改 |

---

## 11. 已知限制

- 有线回传监控设备配置的 WAN 口。首次配对时，客户机需先从主网获取 WAN 或无线地址；
  把两台未组网设备的普通 LAN 口相连且地址不在同一网段，无法自动配对。
- 自定义隐藏 SSID/密码的主 AP，首次纯无线配对需要在从 AP 预先配置匹配回传凭据，或先插 WAN 配对。
  已配对主 AP 更换管理 IP 时，需要更新配对信息。
- v5 访客网是独立 DHCP/NAT 子网。自动切换模式中不在从 AP 启用该访客网；主 AP 的设置不受影响。
- 切换会重配网口或无线。现有会话可能短暂中断；两次 DHCP 获得的管理地址不一定相同。
- MT7981 桥接 WAN 前必须先关 HNAT。控制器按此顺序执行。

---

## 12. 构建 / 刷机 / 同步

### 构建（本地树 = ImmortalWrt 源码树）

```sh
VER=261025-33 sh gwrt-mk-wr630ax-config.sh     # 生成 config（同时启用 wr630ax + 360T7）
sh gwrt-build-wr630ax.sh 6 261025-33           # 编译
ls bin/targets/mediatek/filogic/*wr630ax*      # 产物
```

### 刷机

```sh
scp gwrt-mediatek-filogic-comfast_cf-wr630ax-squashfs-sysupgrade.bin root@192.168.3.3:/tmp/su.bin
ssh root@192.168.3.3 'sysupgrade -n /tmp/su.bin'
```

### 同步 mesh 到其它 OpenWrt 源码树

```sh
sh scripts/gwrt-sync-mesh.sh /path/to/openwrt
```

该脚本会同步所有 `package/gwrt-*` 自定义包以及项目文档、配置生成器和构建脚本。
只移植本轮回传修改时，用工作日志中的文件清单选择性同步。

---

## 13. 验证清单

```sh
/usr/libexec/gwrt-mesh-apmode status       # 模式、IPv4、切换原因、频段、两段等待时间
ubus call wifiroam mesh_policy            # 当前回传和剩余时间计算所需字段
uci get wifiroam.core.role                # 自动回退期间仍为 sap
ubus call network.interface.lan status    # 有线时的主网段管理地址
ubus call network.interface.gwrt_mesh status  # 无线时的主网段管理地址
```

实机测试：先无线配对，从主网和从 AP 的客户端访问管理页；插接其他网络的网线，
确认无线不掉；移动网线到主 AP 的 LAN，验证有线接管；拔线验证无线接替；关闭两条
回传，观察 120 秒搜索、60 秒原路由再搜索。检查客户端都从主 AP 收到 IPv4 租约，
以及主 AP 拓扑上的管理链接、回传方式和切换原因是否随回传更新。
显式退出可用 `/usr/libexec/gwrt-mesh-apmode off`，设备解绑并恢复原路由设置。

研发测试：`scripts/tests/test-gwrt-backhaul.py` 驱动 UCI/切换状态，
`test-gwrt-wifiroam.py` 在目标 ucode 检查两版插件及实际 UDP 入接口，
`test-gwrt-relay-netns.sh` 检查隔离环境的 DHCP、管理与数据面，
`test-gwrt-mesh-topology.cjs` 用 Chrome 检查两个版本的拓扑详情和管理链接。
