# GWRT Mesh（无线漫游组网）设计与实现

> 适用固件：GWRT 261025-33 及以后
> 适用机型：XINGLOO AX3000 (COMFAST CF-WR630AX)、Qihoo 360T7
> 目标：多台 GWRT AP 组成同一 ESS，支持一键/自动配对、无线/有线回传、
> 组网后自动变真 AP、解绑自动回路由模式，并可通过 APP（gwrt-agent）控制。

---

## 1. 角色

| 角色 | 含义 | 行为 |
|---|---|---|
| `unconfigured` | 出厂/重置状态（默认） | 普通路由，后台 192.168.3.3（360T7 为 .4），所有插件正常；持续广播 HELLO 等待主AP 配对 |
| `cap` | 主AP（主路由） | 接受子AP 连接，下发漫游/回传/SSID/密码，可主动发现并配对未配置 AP |
| `sap` | 子AP | 已配对；有线上行时走网线，无线上行时自动建 WDS STA 回传 |

配对完成后子AP 自动变「真 AP」：关本机 DHCP、LAN 改 DHCP 客户端（IP 由主路由分配）、
有线回传时把 WAN 口并进 br-lan（取消 NAT）、关掉用不上的插件。

---

## 2. 组件与文件

| 包 | 关键文件 | 作用 |
|---|---|---|
| `package/gwrt-mesh-apmode` | `/etc/init.d/gwrt-mesh-apmode`<br>`/usr/libexec/gwrt-mesh-apmode`<br>`/etc/uci-defaults/98_gwrt-mesh-apmode` | 路由 ↔ AP 状态机、服务开关、LAN/WAN 避让、无线回传 STA 自动创建、原 SSID 恢复 |
| `package/gwrt-mesh-led` | `/etc/init.d/gwrt-mesh-led`<br>`/usr/libexec/gwrt-mesh-led`<br>`/usr/libexec/gwrt-mesh-pair`<br>`/etc/rc.wps/50-gwrt-mesh`<br>`/etc/uci-defaults/99_gwrt-mesh-led` | mesh 状态灯 + WPS/MESH 键一键配对 |
| `package/gwrt-device-defaults` | `92_gwrt-wifiroam-fw`<br>`94_gwrt-lan-ip`<br>`95_gwrt-wifi-defaults`<br>`97_gwrt-wifiroam-defaults`<br>`98_gwrt-agent-defaults`<br>`gwrt-ssid-name`<br>`gwrt-wifiroam-autopair`<br>`files/wifiroam/wifiroamd.uc` | 首启默认值、SSID 命名、wifiroam 配置、防火墙放行、补丁版守护进程、自动配对 |
| `package/gwrt-agent` | `/usr/sbin/gwrt-agent` | 上报 mesh 状态、接收 APP 下发的 mesh 命令 |
| `package/gwrt-theme/luci-theme-gwrt` | `lib/functions/gwrt-wireless.sh`<br>`etc/hotplug.d/ieee80211/30-gwrt-ssid-name` | SSID 命名保护（主AP 下发的同名 SSID 不会被改回本机后缀） |

---

## 3. 状态机（`gwrt-mesh-apmode`）

每 10 秒轮询一次 `ubus call wifiroam status`。

```
未组网 / 解绑
  └─ 普通路由：LAN 192.168.3.3，本机 DHCP 开，插件全开
       │ 配对成功（role=sap && cap_ip && (peers_online>0 || 无线 STA up)）
       ▼
  已组网（连续 2 次确认，约 20s）
  └─ 真 AP：
       · 停 dnsmasq/odhcpd/turboacc/eqos/shadowsocksr/microsocks/easytier/bandix-plus/appfilter/ttyd
       · 关 HNAT/PPE（必须先关，否则桥接 WAN 会挂死网卡）
       · 有线回传：eth1 并进 br-lan，wan proto=none
       · LAN 改 DHCP 客户端（IP 由主路由分配），dhcp.lan.ignore=1
       · network reload + ifup lan + dropbear restart
       · 25s 内拿不到地址 → 自动回滚
       │ 断连（连续 2 次，约 20s）
       ▼
  回滚普通路由：
       · 拆 eth1 桥接、恢复 LAN 静态 IP、恢复 DHCP、恢复插件
       · 用 /etc/gwrt-wireless-orig 恢复原 SSID/密码
       · wifiroam.roam.config_ver=0（下次配对重新下发）
       · 删掉 wifiroam_bh STA
```

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

1. 子AP（unconfigured）每 5s 发 UDP HELLO 到 **LAN 广播 + 255.255.255.255**；
   `ip` 字段用**默认路由的源地址**（WAN/回传口），保证主AP 能回连（不能用 192.168.3.3）。
2. 主AP `wifiroam.discover` 列出未配置设备（MAC/IP/名称/型号）。
3. 主AP `wifiroam.pair {mac}` → TCP 50608 发 `join`（token + nonce）。
4. 子AP 变成 `sap`，保存 `cap_ip`；随后连回主AP 并认证。
5. 主AP 在认证时下发：
   - `push_roam_config`：k/v/r + FT 参数 + **SSID/加密/密码**
   - `push_backhaul_config`：回传 SSID/密码
6. 子AP 应用后回执；主AP 汇总状态。

一键配对：WPS/MESH 键 → `/etc/rc.wps/50-gwrt-mesh` → `/usr/libexec/gwrt-mesh-pair`
（主AP 立即配对发现的设备；子AP 没连上则回到 unconfigured 等配对）。

自动配对：`gwrt-wifiroam-autopair` 常驻，主AP 每 60s 发现并配对一次；
运行中从 unconfigured 切成 cap 也会开始工作。

---

## 5. SSID/密码同步（wifiroamd.uc 补丁）

原版 wifiroam 只下发 k/v/r，不下发 SSID/PSK。补丁内容：

- 主AP：`wifi_export()` 导出每个 AP 频段的 `{ssid,key,encryption,band,isolate}`
  （排除回传 `wifiroam_bh`），随 `push_roam_config` 一起发送。
- 子AP：`apply_wifi_from_cap()` 按频段套用 SSID/加密/密码；
  `gwrt.mesh_apmode.enabled=0` 时忽略（强制路由模式保持自己的 SSID）。
- 第一次同步前保存 `/etc/gwrt-wireless-orig`（路由模式无线快照）；
  回滚时恢复原 SSID/密码并删除回传 STA。
- 路由模式下 `gwrt-mesh-apmode` 持续刷新快照（用户改 SSID 也能记住）。

效果：子AP 与主AP 广播同一个 SSID、同一个密码、同一套 k/v/r → 真正的无缝漫游。

---

## 6. 无线回传（WDS）

- 子AP 的 STA 配置段：`wireless.wifiroam_bh`
  （mode=sta, ssid=mesh-gwrt, psk2+ccmp, wds=1, network=lan, 5G radio）
- 主AP：隐藏 AP `wifiroam_bh`（mode=ap, hidden=1, wds=1）
- 有线在位时 STA `disabled=1`（避免二层环路）；拔线后自动启用。
- `gwrt-mesh-apmode` 的 `ensure_backhaul()` 会在配置段缺失时自动创建
  （不依赖主AP 是否推送成功）。
- `sta_up()` 把「无线 STA 已连上」也算作已组网，避免拔线瞬间误回滚。

---

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
  "firmware": "GWRT 261025-33 cb793d3"
}
```

### 命令（云端 pull → commands[]）

| action | 参数 | 作用 |
|---|---|---|
| `mesh.pair` | `mac`（可选；不填=全部发现的未配置 AP） | 配对 |
| `mesh.role` | `role` = `cap` / `sap` / `unconfigured` | 设角色（sap 只能由配对产生） |
| `mesh.apmode` | `enabled` = 0/1 | 0=强制退出 AP+解绑；1=允许自动切换 |
| `mesh.ssid_sync` | 无 | 主AP 立即重推 SSID/密码+k/v/r；子AP 重启 wifiroam 接收 |
| `system.reboot` | 无 | 重启（需 `remote_exec=1`） |
| `system.hostname.set` | `hostname` | 改主机名（需 `remote_exec=1`） |

`mesh.*` 默认允许（`gwrt-agent.main.mesh_control=1`），不碰系统配置；
危险命令仍需 `gwrt-agent.main.remote_exec=1`。

本机调试：`gwrt-agent cmd '{"action":"mesh.pair","command_id":"t1"}'`

---

## 10. UCI 开关

| 键 | 默认 | 说明 |
|---|---|---|
| `gwrt.mesh_apmode.enabled` | 1 | 1=配对后自动变 AP；0=永远保持路由 |
| `gwrt.mesh_led.leds` | auto | `auto` / `blue:status` / `"red:status green:status"` |
| `gwrt.mesh_led.enabled` | 1 | 0=关闭状态灯服务 |
| `gwrt-agent.main.mesh_control` | 1 | 0=拒绝 mesh.* 命令 |
| `gwrt-agent.main.remote_exec` | 0 | 1=允许重启/改主机名等危险命令 |
| `wifiroam.core.role` | unconfigured | 当前角色 |
| `wifiroam.backhaul.ssid/key` | mesh-gwrt / Abc123abc8888 | 回传凭据 |

---

## 11. 已知限制

1. **首次配对需要 WAN 侧可达**：子AP 用 WAN（或已配对后的无线回传）拿主路由网段的 IP，
   主AP 才能 TCP 连上它。纯 LAN 口直连且不同网段时无法配对。
2. **只同步每个频段的主 SSID**：访客 WiFi / 多 SSID 暂不同步。
3. **主路由改 WiFi 密码后**：下一次漫游配置变化或 APP 执行 `mesh.ssid_sync` 才会重推。
4. **LED 颜色**：默认蓝灯；如果面板 MESH 图标是绿灯，用 UCI 切换。
5. **AP 模式停用 10 个插件**（见第 3 节），页面仍可见但显示 Stopped。
6. **MT7981 桥接 WAN 必须先关 HNAT**，脚本已按顺序处理；手动操作时不要跳过。

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

脚本会复制：
`package/gwrt-mesh-led`、`package/gwrt-mesh-apmode`、`package/gwrt-device-defaults`、
`package/gwrt-agent`、`package/gwrt-theme`，以及本文档。

---

## 13. 快速验证清单

```sh
# 未组网
uci get wifiroam.core.role                 # unconfigured
ip -4 addr show br-lan | grep inet         # 192.168.3.3
uci show wireless | grep ssid=             # GWRT_2.4G_xxxx / GWRT_5.2G_xxxx

# 配对后（主AP 点配对 / 按 MESH 键）
uci get wifiroam.core.role                 # sap
ip -4 addr show br-lan | grep inet         # 192.168.x.y（主路由分配）
uci show wireless | grep ssid=             # 与主AP 相同
logread | grep -E "wifi sync|state .*-> ok|AP mode ok"

# 强制退出
/usr/libexec/gwrt-mesh-apmode off
# → unconfigured / 192.168.3.3 / GWRT_* SSID / 插件恢复 / discover 为空
```
