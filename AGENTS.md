# AGENTS.md — GWRT MT7981 固件项目

本仓库是 **GWRT** 定制 ImmortalWrt 源码树，目标机型：

- **XINGLOO AX3000**（COMFAST CF-WR630AX，MT7981B + MT7531AE + MT7976CN）
- **Qihoo 360T7**（MT7981B，原厂分区 / UBI 两个 profile）
- **H3C Magic NX30 Pro**（MT7981B，OpenWrt U-Boot 布局）
- **Xiaomi Mi Router AX3000T**（原厂 / OpenWrt U-Boot 布局）
- **CMCC RAX3000M**（MT7981B，NAND/eMMC/UBI）
> 以上 MT7981 NAND 机型共用同一套 GWRT 插件/默认值/ mesh，配置生成器一次全编。

> 详细 mesh 设计见 `docs/GWRT-MESH.md`；完整构建/调试记录见
> `BUILD-NOTES-cf-wr630ax-261025-01.md`。

---

## 1. 构建与刷机

本地树就是源码树；实际编译在 `/home/godsun/build/immortalwrt-mt7981`
（通过 rsync 同步 `package/` 等目录）。

```sh
# 生成配置（同时启用 wr630ax + 360T7，一次编出 4 个 profile）
VER=<版本> sh gwrt-mk-wr630ax-config.sh

# 编译（build 树）
cd /home/godsun/build/immortalwrt-mt7981
sh gwrt-build-wr630ax.sh 6 <版本>

# 产物
bin/targets/mediatek/filogic/gwrt-mediatek-filogic-*
```

刷机（设备 LAN 默认 `192.168.3.3`，root 空密码）：

```sh
scp <sysupgrade.bin> root@192.168.3.3:/tmp/su.bin
ssh root@192.168.3.3 'sysupgrade -n /tmp/su.bin'
```

注意：build 树没有 `.git`，必须给 `REVISION`（`gwrt-build-wr630ax.sh` 已处理）。

### MT7621（京东云鲁班 RE-CP-02）— 走 GitHub Actions 云端编译

本地磁盘不足（剩 ~40G，全量树需 ~25G），MT7621 编译在私有仓
`rothdren-lion/gwrt-immortalwrt`（含同名源码快照 + CI）：

```sh
# 触发云端编译（可加 -f version=261026-01 -f release=true）
gh workflow run gwrt-build.yml -R rothdren-lion/gwrt-immortalwrt -f device=cp02
gh run list -R rothdren-lion/gwrt-immortalwrt --limit 3
gh run download <run-id> -R rothdren-lion/gwrt-immortalwrt -D /tmp/cp02-out
```

改 cp02 相关文件后需同步到该仓（导出副本在 `/home/godsun/build/gwrt-github-export`，
rsync + commit + push）。本地备份编译步骤见 `docs/WORKLOG-20261026-jdcloud-cp02-mt7621.md`。

---

## 2. 代码地图

| 路径 | 内容 |
|---|---|
| `gwrt-mk-wr630ax-config.sh` | 配置生成器（设备 profile、插件集、turboacc/coremark 选项） |
| `gwrt-mk-cp02-config.sh` / `gwrt-build-cp02.sh` | MT7621 鲁班 RE-CP-02 最低 mesh 配置生成器 + 本地编译脚本（主走 GitHub CI） |
| `target/linux/mediatek/dts/mt7981b-comfast-cf-wr630ax*.dts` | XINGLOO 设备树（含 512M 变体） |
| `target/linux/mediatek/image/filogic.mk` | 设备定义（`comfast_cf-wr630ax*`、`qihoo_360t7*`） |
| `package/gwrt-device-defaults/` | 首启默认值（LAN IP、SSID、wifiroam、防火墙、APK 预置） |
| `package/gwrt-mesh-led/` | mesh 状态灯 + WPS/MESH 一键配对 |
| `package/gwrt-mesh-apmode/` | 路由 ↔ 真 AP 状态机（服务开关、桥接、SSID 快照恢复） |
| `package/gwrt-agent/` | gwrt-agent shim（遥测 + APP 命令，含 mesh.*） |
| `package/gwrt-theme/luci-theme-gwrt/` | gwrt 主题（首页/温度/拓扑/mesh 行） |
| `gwrt-theme-V3/` | 主题源码（同步到 `package/gwrt-theme/`） |
| `docs/GWRT-MESH.md` | mesh 设计、协议、APP 命令契约、验证清单 |
| `bin-wr630ax-<ver>/`、`bin-360t7-<ver>/` | 每版归档镜像（只保留最新） |

---

## 3. mesh 关键实现（改动前必读）

1. **配对发现**：`wifiroamd.uc` 的 `send_hello()` 同时发 LAN 广播和
   `255.255.255.255`，`ip` 用默认路由源地址（WAN IP），否则主AP 发现不了/连不上。
2. **SSID/密码同步**：主AP `wifi_export()` 随 `push_roam_config` 下发；
   子AP `apply_wifi_from_cap()` 按频段套用；`gwrt.mesh_apmode.enabled=0` 时忽略。
3. **原 SSID 快照**：`/etc/gwrt-wireless-orig`，回滚路由模式时恢复，
   否则子AP 一直广播主路由 SSID，回退后连不上。
4. **桥接 WAN 必须先关 HNAT**：`echo 0 > /sys/kernel/debug/hnat/hook_toggle`
   （路径存在时），并先停 turboacc/eqos；否则 MTK 网卡 TX 队列挂死。
5. **dropbear 用 `-l br-lan` 绑定**：切 AP/回路由/开机 AP 模式后必须 restart，
   否则 22 端口消失。
6. **AP 模式停用服务**：dnsmasq/odhcpd/turboacc/eqos/shadowsocksr/microsocks/
   easytier/bandix-plus/appfilter/ttyd；回路由时按原启用状态恢复。
7. **强制退出 AP**：`/usr/libexec/gwrt-mesh-apmode off` 或 APP
   `mesh.apmode {"enabled":0}` → 解绑 + 回 192.168.3.3 + 恢复原 SSID + 停止广播。
8. **回传策略**：有线 = 真 AP（无缝）；无线 = 3-addr STA + NAT（保证有网，无漫游）。
   4-addr WDS 在 JDCloud 主AP 上不稳定；relayd 在本树缺 proto handler。
9. **跨架构（MT7621/mipsel）**：`gwrt-agent` 的 aarch64 预编译二进制仅随 aarch64 目标安装
   （PKGARCH:=all + Makefile 架构条件），mipsel 上 shim 自动退回最小遥测载荷；
   `ucode-mod-socket`/`ucode-mod-digest` 必须编入固件（cp02 配置已选）；
   预置 apk（含 aarch64 ucode-mod-socket）在 mipsel 不安装。

---

## 4. APP 命令契约

上报字段：`gwrt_mesh`（role/cap_ip/peers_online/apmode/ssids/discover/firmware）。

命令（pull → commands[]）：

| action | 参数 |
|---|---|
| `mesh.pair` | `mac`（可选） |
| `mesh.role` | `role` = cap/sap/unconfigured |
| `mesh.apmode` | `enabled` = 0/1 |
| `mesh.ssid_sync` | 无 |
| `system.reboot` / `system.hostname.set` | 需 `remote_exec=1` |

---

## 5. 验证清单

```sh
# 未组网
uci get wifiroam.core.role          # unconfigured
ip -4 addr show br-lan | grep inet  # 192.168.3.3
uci show wireless | grep ssid=      # GWRT_2.4G_xxxx / GWRT_5.2G_xxxx

# 配对后
uci get wifiroam.core.role          # sap
ip -4 addr show br-lan | grep inet  # 主路由分配
uci show wireless | grep ssid=      # 与主AP 相同
logread | grep -E "wifi sync|state .*-> ok|AP mode ok"

# 强制退出
/usr/libexec/gwrt-mesh-apmode off
# → unconfigured / 192.168.3.3 / GWRT_* / 插件恢复 / discover 为空
```

---

## 6. 同步 mesh 到其它源码树

```sh
sh scripts/gwrt-sync-mesh.sh /path/to/openwrt
```

复制 `gwrt-mesh-led`、`gwrt-mesh-apmode`、`gwrt-device-defaults`、
`gwrt-agent`、`gwrt-theme` 以及 `docs/GWRT-MESH.md`。

---

## 7. 操作日志索引

- `docs/WORKLOG-20261026-jdcloud-cp02-mt7621.md` — cp02 最低 mesh 集成、
  gwrt-agent/device-defaults 跨架构改造、GitHub Actions 云端编译（ipq5018 待确认机型后移植）
