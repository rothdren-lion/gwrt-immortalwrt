# 2026-11-15 wifiroam v5 覆盖层接入 SS-01（测试构建）

## 目标

把新版组网程序（上游 wifiroam 0.1.0-r47 + 我们需要的 GWRT 补丁）做成**新包**接入，
不覆盖原有的预置 apk 目录与旧默认值逻辑，先编一个 SS-01 测试镜像。

## 结论先行

- 不需要动内核配置/设备树，**不需要重编内核**：新增的只有 `kmod-nfnetlink-queue`（模块，不进 vmlinux）
  和用户态包。SS-01 本来没有本地构建缓存，实际还是在 GitHub 上完整跑一次（内核会顺带编一次）。
- 已推送 `845873c`，云端运行 `43708396373` / 版本 `261115-05` / release=false，构建中。

## 实现

新增 `package/gwrt-wifiroam-v5/`，全部装到私有目录 `/usr/share/gwrt/wifiroam-v5/`：

| 内容 | 说明 |
|---|---|
| `wifiroamd.uc` | 上游 0.1.0-r47（5498 行）+ 两处 GWRT 补丁，共 5522 行 |
| `views/*.js` | v5 四个页面：topology / clients / settings / advanced，已去“打赏” |
| `res/` | 页面资源（oui 库、wifiroam.css、机型图、应用图标），不含 donate-qr.png |
| `menu.json` | 中文菜单：无线漫游 → 网络拓扑 / 客户端 / 漫游设置 / 应用与访客 |
| `acl.json` | v5 ubus 方法授权（含 appctl/ban/guest 那批写方法） |
| `wifiroam.zh-cn.lmo` | 上游中文翻译（0.261115.10098） |
| `src/wifiroam-dpi.c` + `/usr/sbin/wifiroam-dpi` | 之前反编译重建的 DPI 旁路，随包编译 |

外加两处改动：

1. `package/gwrt-device-defaults/files/97_gwrt-wifiroam-defaults` 增加 `1b)` 段：
   若 `/usr/share/gwrt/wifiroam-v5/wifiroamd.uc` 存在，就把守护进程、四个页面、`res/`、
   菜单、ACL、翻译整套拷到真实路径，`rpcd reload`、清 LuCI 缓存、重启 wifiroam。
   没有新 uci-defaults 文件，所以 SS-01 首启 worker 的硬编码重试清单和对应测试都不用改。
2. `scripts/gwrt-mk-ipq60xx-config.py`：`ss01` 预设选中 `PACKAGE_gwrt-wifiroam-v5=y`
   和 `PACKAGE_kmod-nfnetlink-queue=y`。

## 已移植的 GWRT 补丁

| 补丁 | 位置 | 作用 |
|---|---|---|
| SSID 下发保护 | `is_backhaul_sec()` + `wifi_ifaces()` + `apply_wifi_local()` | 隐藏回传 AP 不参与前台 SSID 改名；`gwrt.mesh_apmode=0`（强制退出 AP 模式）时忽略主 AP 下发；首次同步前快照 `/etc/config/wireless` 到 `/etc/gwrt-wireless-orig` |
| 子 AP 上报地址 | `detect_self()` | 非 CAP 角色优先用 `ip route get` 的源地址广播，避免 br-lan 地址对主 AP 不可达 |

## 故意没移植

- **回传改 3-addr + `network=wwan`**：v5 用 `wds=1` + `network=lan`，改成 wwan 需要在 netifd
  里建接口、搬防火墙域，单变量测试不混进来。
- **漫游引导只选有线回传 AP**：v5 的候选 BSS 列表不含 AP 归属信息，要按 `info.nr` 过滤，
  属于功能增强，先不动。

## 验证

- `sh -n 97_...`、`python3 -m py_compile`、4 个页面 `node --check`、守护进程 ucode 语法检查（剥离
  ubus/uloop/uci/digest 导入后用 host ucode `-c`）全通过。
- `gwrt-mk-ipq60xx-config.py ss01` 生成的配置里 `CONFIG_PACKAGE_gwrt-wifiroam-v5=y`、
  `CONFIG_PACKAGE_kmod-nfnetlink-queue=y` 都在。
- `wifiroam-dpi.c` 用 aarch64 musl 工具链 `-std=c99 -O2 -Wall -Wextra` 零警告编译通过
  （顺手修掉 `snprintf(ip,...,"%s",p)` 的截断告警，改成 `"%.45s"`）。
- 未验证：真机首启后的实际替换、页面渲染、应用管控/DPI 是否真的下发规则。

## 回滚

1. `scripts/gwrt-mk-ipq60xx-config.py` 去掉两行 `set_value('PACKAGE_gwrt-wifiroam-v5'...)`、
   `set_value('PACKAGE_kmod-nfnetlink-queue'...)`；
2. 删除 `package/gwrt-wifiroam-v5/`；
3. 删掉 97 里的 `1b)` 段。
   预置 apk 与旧页面文件从未被覆盖，回滚后与改动前完全一致。

## 待办

- 云端 `43708396373` 结果与产物归档。
- 实机首启后核对：`/usr/share/wifiroam/wifiroamd.uc` 是 5522 行版本、LuCI 四个页面可打开、
  `ubus call wifiroam status` 正常、断开/重连 AP 后隐藏回传 SSID 未被改名。
- 通过后再评估移植回传/引导两项。

## 2026-11-16 实机跟查：组网后 SSID 不同步

### 现场事实（CP-02 `192.168.9.170`，镜像 `261115-07` / `727340c`）

- `wifiroam.core.role=sap`、`cap_ip=192.168.9.9`，`gwrt.mesh_apmode.enabled=1`，
  `network.lan.proto=dhcp`、`br-lan=192.168.9.170`、`dhcp.lan.ignore=1`
  —— 有线组网下 AP 模式（关本机 DHCP、LAN 拿主路由地址）本身是好的。
- 主AP `.9.9`（GWRT-8413，RE-CS-02 GWRT2，固件 `260920-05`）跑的是老 2114 行
  `wifiroamd.uc`，它的 `push_roam_config` 带 `wifi: wifi_export()`。
- 子AP 无线仍是自己的 `GWRT_2.4G_BFE9` / `GWRT_5.2G_BFE9`。

### 两个独立原因

1. v5 的 `push_roam_config` 只处理 `roam`/`members`，把 `args.wifi` 丢掉，
   而 `push_wifi_config` 只有「无线设置」点保存时才发 → 老主AP 配新子AP 永远不同步。
2. 补上兼容后崩溃：`apply_wifi_from_cap()` 定义在 `wifi_summary()` **之前**，
   ucode 按编译期作用域解析变量，运行时报
   `Reference error: access to undeclared variable wifi_summary`
   （`line 1499, byte 17`，栈 `sap_rx → main`）。子AP 一收到推送就退出，
   procd 重启，主AP 侧结果永远是 `pending`。`ucode -c` 语法检查**查不出**这类前向引用。

### 修复（提交 `1549543`、`9705428`）

- `push_roam_config` 收到 `args.wifi` 数组时按频段落地 SSID/密码；
  与 `push_wifi_config` 共用 `apply_wifi_from_cap()`。
- 该函数移到 `roam_rename_ssids()` 之后，依赖（`wifi_summary`、`apply_wifi_local`、
  `roam_rename_ssids`）全部先声明。
- 保留 `roam push recv` / `wifi from cap` 两行日志，现场可直接看出是否收到、落地几条。
- `wifi_push_spec()` + 认证后推送 + 漂移补发（提交 `6574bde`）：只在
  `role=cap` 时执行，`unconfigured`/`sap` 不会误推。

### 实机验证

热替换子AP `/usr/share/wifiroam/wifiroamd.uc`（`201564` → `203555` 字节）后重启服务，
主AP 侧 `set_roam` 触发一次下发（配置值不变，仅版本 +1）：

- 日志：`roam push recv: wifi=2`、`wifi from cap: 2 entries, applied=2 ok=yes`
- `uci`：`default_radio0=Rodren`、`default_radio1=AX6600_Gaming`，密码分别为
  `Abc123abc!!` / `Abc123abc???`
- `iwinfo`：`phy0-ap0 "Rodren"`、`phy1-ap0 "AX6600_Gaming"`
- 频段对得上：主AP `radio0=5g(AX6600_Gaming)`、`radio1=2g(Rodren)`

### 注意与遗留

- CP-02 overlay 只有 1.4 M（`/overlay` 已用 89%）。第一次热替换时空间不足，
  文件被写成 143360 字节截断版，procd 进 crash loop；删掉 `/root` 里的备份副本后
  才腾出空间。**新文件必须整份写入**，否则会崩溃重启。
- 已修代码只在 `/tmp/gwrt-push` + NAS 源码里，`261115-05`/`261115-07` 两个成品镜像
  都不含这些提交，要出新镜像才落到固件。
- 无线回传（拔网线）下的 LAN 取址没有复测；有线回传已验证正常。

## 2026-11-16 SS-01 实机刷入 + 第二类前向引用崩溃

### 刷入

- 下载 `261115-05` 产物（GitHub artifact `14164067841`，zip 245 M）：
  这台机器 `api.github.com` 走 wifi 正常，blob 域名 DNS 只回 `fe80::1`，
  用 `--resolve productionresultssa11.blob.core.windows.net:443:20.209.75.97`
  + `-C -` 续传拿到完整包。归档 `/home/godsun/build/gwrt-releases/ss01-261115-05/`：
  sysupgrade `15dca047...c84bb4`、factory `e7faa543...8d634b`。
- 刷入 `-n`：`192.168.3.3`（有线 eno0，MAC `dc:d8:7c:48:7c:c8`），约 225 秒后回来，
  revision `845873c`。首启 apk 安装 + 97 覆盖都完成：`gwrt-wifiroam-v5`、
  `luci-app-wifiroam`、`wifiroam`、i18n 四个包都在，`/usr/share/wifiroam/wifiroamd.uc`
  5522 行（这一版还没有 SSID 修复），v5 的 `res/`、`views/`、`menu.json`、`acl.json`、
  `wifiroam.zh-cn.lmo` 已覆盖到位，`/luci-static/...` 三个路径都 200。
- 该镜像里的 v5 守护进程是 5522 行版本，不含 `apply_wifi_from_cap`。

### 新 bug：设为主AP 时守护进程崩溃

`ubus call wifiroam set_role {"role":"cap"}` 返回 `Unknown error`，日志：

```
Reference error: access to undeclared variable roam_default_init
In [anonymous function](), file /usr/share/wifiroam/wifiroamd.uc, line 4582, byte 20
  `            if (r == "cap") roam_default_init();`
```

`roam_default_init` 定义在 5416 行，调用在其之前。同一类隐患还有 3 处：
`local_clients`（2383）、`sap_disconnect`（3727）、`find_client`（4243）。
`set_role` 崩后 procd 重启，配置已是 cap，所以现象是“报错但看起来生效”。

### 修复（提交 `a3d731c`）

ucode 不做函数提升；而“`let x;` 之后再用 `function x()`”会报
`Variable 'x' redeclared`，所以只能沿用文件里既有的写法：
顶部 `let` 前向声明 + 函数体保持 `function` 形式即可（已用两条最小用例验证）。
改动只在顶部加一行 `let local_clients, sap_disconnect, find_client, roam_default_init;`。
整文件扫描后无剩余前向引用。

### 热替换后的功能验证

把修好的 203746 字节守护进程推到 SS-01 `/usr/share/wifiroam/wifiroamd.uc` 并重启：

- `set_role cap` 正常返回，日志 `started role=cap`，无异常；
- `set_appctl enabled` 正常，`wifiroam-dpi` 进程起来，`nft list table inet wifiroam`
  有 `wechat_v4` 等带 `timeout 12h` 的集合，forward 链上有
  `wr:00e04c00c0b0:wechat:allow` 这类规则（预置策略来自 `/etc/gwrt/clients.json`）；
- `set_ban enabled` 建出 `inet wifiroam_ban` 表（无设备时 forward 链为空）；
- 之后恢复 `role=unconfigured`、关掉 appctl/ban，`nft list tables` 里已无 wifiroam。

### 下一步

- 重编 SS-01（提交 `a3d731c`，run `43749196232`，版本 `261116-01`，release=false）。
- CP-02 要同样重编才带上三处提交：`5dbf772`（自动推 SSID）、`a2f0a5c`（兼容老主AP 的 wifi 字段）、
  `3a9d884`（前向引用崩溃）、`a3d731c`（4 处前向引用）。
- 无线回传下的 LAN 取址仍未验证。

## 2026-11-16 主AP 看不到 SS-01：上报地址在开机时定型

现象：SS-01 刷 `261115-05` 后自己通过 `wifiroam_bh`（`mode sta`、`ssid mesh-gwrt`、`network wwan`）连上主AP 的隐藏回传 SSID，拿到 `192.168.9.156` 并能上网，但 `wifiroam.core.role` 仍是 `unconfigured`，主AP 拓扑里没有它，`discover` 为空。

原因：`detect_self()` 只在守护进程启动时跑一次。开机时 `wwan` 还没 DHCP 地址，`ip -4 route get 1.1.1.1` 取不到 src，`state.self.ip` 固化成 `192.168.3.3`，`state.bcast` 随之变成 `192.168.3.255`，`send_hello()` 的广播根本没进主AP 网段，主AP 自然发现不到。

证据：不动配置、仅 `/etc/init.d/wifiroam restart`（此时默认路由已存在），`status` 的 `ip` 变成 `192.168.9.156`，主AP `discover` 立刻列出 `DC:D8:7C:48:7C:C8 / 192.168.9.156 / GWRT-7CC9`。

修复（提交 `96ebd30`）：新增 `refresh_self_addr()`，非 CAP 角色每 5 秒通过 `network.interface.wwan` 状态（回退到 `ip route get 1.1.1.1` 的 src）校正 `state.self.ip` 与 `state.bcast`，地址变化时打日志 `self ip -> x (bcast y)`。

实机结果：热更新守护进程（204595 B）重启后主AP 发现该设备，用主AP 的 `ubus call wifiroam pair {"mac":"DC:D8:7C:48:7C:C8"}` 配对成功——SS-01 `role=sap`、`cap_ip=192.168.9.9`，SSID 收成 `AX6600_Gaming` / `Rodren`，主AP 拓扑显示 3 个成员（`360T7-3F .214`、`CS-01 .156`、`Luban-AP-1F .170`）。

遗留：无线回传下 `network.lan.proto` 仍是 `static`（`192.168.3.3`），没切成 DHCP，所以这台等于双 NAT、不能和无缝漫游合并；只有有线回传会自动改 DHCP。这块尚未移植。

重建：`43775053144`（ss01 `261116-02`）、`43775097701`（cp02），旧的 `43774157301` 已取消。

## 2026-11-16 无线回传改 relayd 伪桥（去掉双 NAT）

问题：`gwrt-mesh-apmode` 的无线回传分支一直是「STA 当 WAN + NAT」，子AP 的 `br-lan` 保持 `192.168.3.3/24`，等于双 NAT，客户端和主AP 不同网段，漫游/踢客都用不上。

为什么不用 4addr WDS：主AP 的 `wifiroam_bh`/`wifiroam_bh2` 现在是 `wds=0` 普通 AP；SS-01 是 ath11k，4-addr STA 支持不可靠，硬切会把现有回传直接打断。

改动（提交 `5d7a0b4`，`package/gwrt-mesh-apmode`）：
- 无线回传分支优先走 relayd：`network.relay`（`proto relay`，`network 'lan wwan'`）、`network.lan.proto=relay`、`dhcp.lan.ignore=1`，`wwan` 留在 DHCP、加进 lan 防火墙区域（不 NAT）；同时打开 `dhcp.lan.ra/dhcpv6/ndp=relay` 并重新启用 odhcpd 做 IPv6 中继。
- 固件里没有 `/etc/init.d/relayd` 时退回原来的 NAT 分支，行为与上一版一致。
- `save_state` 记录 `dhcp.lan.ra/dhcpv6/ndp`，`restore_network_only` 和 `restore_routermode` 都会还原，回滚不留 relay 配置。
- `Makefile` 依赖加 `+relayd`（relayd 自身只依赖 libubox）；`odhcpd` 在 SS-01 seed 里本来就是 `=y`。
- `sh -n` 通过。

重建：`43780044541`（ss01 `261116-03`）、`43780065561`（cp02）；此前 `43775053144`/`43775097701` 已取消。

待验证（需刷 `261116-03`）：无线回传配对后 `br-lan` 应拿到 `192.168.9.x`、客户端地址段与主AP 一致、`relayd` 在跑、`opkg`/IPv6 RA 正常；25 秒内拿不到地址仍会自动回滚到路由模式。relayd 的 IPv6 中继依赖主AP RA，未验证。

### 追加：relay 改为显式开关（默认关闭）

把无线回传切 relay 属于动所有子AP 网络路径的改动，默认不改行为：只有 `uci set gwrt.mesh_apmode.relay=1` 时 `apply_apmode()` 才走 relay 分支，未设置时仍旧走 NAT（上一版行为，已实机跑通）。

保护逻辑：
- relay 模式下以 `br-lan` 拿到非 `192.168.3.3` 的地址为成功标准，25 秒内拿不到就 `restore_routermode`；
- 回滚时清掉 `gwrt.mesh_apmode.relay`，避免「每 5 分钟重试一次、反复断网」，要再试必须重新置 1；
- `gwrt-mesh-apmode` 依赖补 `+relayd +kmod-nfnetlink-queue +libnetfilter-queue`（relayd 走 nfqueue，缺模块它起不来）。

提交 `d1fc11b`。重建 `43781417766`（ss01 `261116-05`）、`43781437688`（cp02）。

未实测（刷机后必须验证，不能算已验证）：
- relayd 伪桥在 ath11k STA 上行时 `br-lan` 是否真能拿到主AP 的 DHCP 地址；
- `dhcp.lan.ra/dhcpv6/ndp=relay` 配合 odhcpd 的 IPv6 中继；
- relayd 的 ARP 代理对「主AP 网段已有同名 IP」的处理。

另外更正一处措辞：relayd 只解决「同网段/客户端地址由主AP 分配」，不等于 802.11r 那种无缝漫游，漫游仍靠 BTM 或客户端自己切。
