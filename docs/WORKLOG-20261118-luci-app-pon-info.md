# WORKLOG 2026-11-18 — luci-app-pon-info（PON 全量信息采集与记录插件）

## 需求

用户："帮我写一个pon专门记录所有信息的插件"，用于换猫前核对参数、留下光路变化的证据。

目标设备 `192.168.1.1` = `tianyi,tyfza1`（RTL9617C UBI，OpenWrt 0.8.5-beta r0-79bc56c，Linux 6.18.55），
`mode=xgpon`，出厂身份 `TYFZA1` / `TYZDD01F3DCD`。采集与写入全程只读设备 PON 状态，仅新增插件自身的文件。

## 实现

包位置（当前源码树）：`package/gwrt-luci-app-pon-info/luci-app-pon-info/`

| 文件 | 作用 |
| --- | --- |
| `root/usr/sbin/pon-info` | ucode 采集器，`json`/`record`/`history [N]`/`clear`/`show` |
| `root/usr/libexec/pon-info-recorder` | 采样循环，`interval` 秒调用一次 `record` |
| `root/etc/init.d/poninfo` | procd 服务（START=95），开机自启 |
| `root/etc/config/poninfo` | `enabled` / `interval` / `keepalive` / `max_lines` |
| `root/usr/share/rpcd/ucode/luci.pon-info` | ubus 对象 `luci.pon-info`：`status`/`history`/`record`/`clear` |
| `root/usr/share/rpcd/acl.d/luci-app-pon-info.json` | 读 `status`/`history`，写 `record`/`clear` |
| `root/usr/share/luci/menu.d/luci-app-pon-info.json` | 菜单 `admin/onu/pon-info`（order 30），alias `admin/network/pon-info` |
| `htdocs/.../view/poninfo/log.js` | 页面：概览/身份/光口/OMCI/接口统计/历史/配置/原始参数/日志 + 导出/清空/立即采样 |

采集范围：`/sys/bus/platform/devices/4f5500000.pon/{state,optical,transceiver,ploam,fec,pm_counters,data_path,serdes,llid_table,itu_paths,omci_msk,...}`、
`/var/run/pon-omci`、`/var/run/pon-service(-error)`、`/etc/config/pon{,_wan}`、
出厂 `/var/run/tyfza1-factory/pon_factory`、`pon0`/`pon-omci` 统计、`logread` 中 PON/OMCI 行。

记录策略：`/etc/poninfo/history.jsonl` 每行一条快照，签名变化即追加，无变化时每 `keepalive` 秒追加一次，
超过 `max_lines` 从头部裁剪；`/etc/poninfo/latest.json` 每次采样覆盖。

## 该 ucode / rpcd 构建的三处坑（实测）

1. 正则不支持非捕获组 `(?:...)` → `Syntax error: Repetition not preceded by valid expression`；改为两条 `match()` 分别取 section 类型与名字。
2. `json(obj)` 只支持解码（字符串），编码对象报 `Input object does not implement read() method` → 用 `sprintf('%J', obj)`。
3. `upper()` 不存在，用 `uc()`；且 rpcd 拒绝对未声明 schema 的方法传参（`ubus -S call ... history '{"limit":3}'` 返回 rc=2），
   故 `history` 改为无参方法，条数上限写在插件内（500），CLI 仍可取任意条数；ubus 返回值必须是对象，不能直接返回数组（改 `{ records: [...] }`）。

## 实机验证（192.168.1.1）

- `pon-info show` / `json` / `record` / `history` 全部 rc=0；`record` 第二次正确判重（`appended:false`）。
- `ubus -S call luci.pon-info {status,history,record}` 返回码 0；`acl` 文件与 `menu.d` 文件 `jsonfilter` 校验通过。
- 用 `root` 空口令登录 LuCI（302 + `sysauth_http`）后，经 `/cgi-bin/luci/admin/ubus` JSON-RPC 调用
  `status`、`history`、`record` 均 `result:[0,...]` → ACL 读写正确；页面 `/cgi-bin/luci/admin/onu/pon-info` HTTP 200，
  静态 JS HTTP 200。
- `/etc/init.d/poninfo enable` + `start` 成功，`pon-info-recorder 60` 常驻；当前采到 `los=1`（未接光纤），
  `rx_los=1`、`rx/tx_power_raw=0`、`pon0=down`、OMCI `session=1 auth=0`。

## 边界与副作用

- 为加载 rpcd ucode 插件执行了 `/etc/init.d/rpcd restart`，原有 LuCI 登录会话失效，需重新登录；未重启设备、未刷机。
- `/etc/poninfo` 位于 overlay，长期采样会写 flash（稳定态约每 10 分钟一行，文件超限自动裁剪）；不需要时 `uci set poninfo.settings.enabled=0`。
- 浏览器端 JS 只用 `node --check` 做了语法校验，未在真实浏览器里跑过渲染。
- 当前源码树 `target/linux/realtek` 只有 `rtl838x`/`rtl839x`，没有 rtl9617c target；要进固件需把包同步到 TYFZA1 的 ONT 源码树，并在配置里选 `PACKAGE_luci-app-pon-info=y`。
- 未编译固件、未改设备既有 PON 配置与认证参数。

## 后续：平台无关化与 an7581 接入（同日）

- 采集器不再硬编码 `4f5500000.pon`：按 `glob('/sys/bus/platform/devices/*.pon')` → `/sys/devices/platform/*.pon`
  发现同时存在 `state` 或 `optical` 的 PON 平台设备；缺失文件一律按"不可读"处理。
  已存在的厂商工具（`airoha-ponctl`、`ponctl`、`airoha-pond`）`status` 原文记入 `backend.vendor`。
- 历史签名收窄为 `sn/mode/family/los/tx_fault/module_absent/omci_session/omci_auth/omci_paths/omci_error/pon_operstate/omci_operstate/service_error`，
  此前电压寄存器抖动（33281↔33359）会被判为状态变化而多记一条，已修正；清空测试记录后重新采样，`record` 连续调用判重正确。
- `gwrt-mk-an7581-config.sh` 的「PON 驱动与用户态」包列表加入 `luci-app-pon-info`；该生成器只产 AN7581/AN7583 光猫配置（全为 PON 机型），
  MT7981 等无 PON 的机型不加。
- 部署更新的 `/usr/sbin/pon-info` 到 `192.168.1.1` 并复测 `show/json/record/history` 全部正常。

## 待办：无法推送 GitHub

- 本机到 GitHub 全部通路超时：`ping github.com` 100% 丢包，`curl https://github.com` 000，
  `api.github.com` 超时，`ssh -p 443 git@ssh.github.com` 超时，`gh auth status` 报 `dial tcp 140.82.113.6:443: i/o timeout`；
  仅 `raw.githubusercontent.com` 返回 301。LAN 内 `192.168.9.9/.242/.222` 的 7890/7891/1080/10808/10809/20171/8889/8118 均未监听。
- 因此未执行 `git push`，也未新建 remote；本地已就绪：`package/gwrt-luci-app-pon-info/`（新增）、`gwrt-mk-an7581-config.sh`（+1 行）、
  `AGENTS.md`、本工作日志。网络恢复后直接：
  `git remote add gwrt https://rothdren-lion@github.com/rothdren-lion/gwrt-immortalwrt.git`（或复用已有导出树）→ commit → `git push gwrt master`。

## 2026-11-18 下午复核与修正

以只读方式复核凌晨成果，结论：插件本体完整可用，补两处缺口、修一处缺陷。

### 复核通过项

| 检查 | 结果 |
| --- | --- |
| 包文件齐全 | `package/gwrt-luci-app-pon-info/luci-app-pon-info/` 共 10 个文件（含 README），35K，无缺件 |
| ucode 语法 | 用宿主解释器 `/home/godsun/build/gwrt-startup-opt-261117-evidence/host-ucode/ucode` 实编译：`pon-info` 与 `luci.pon-info` 均 exit=0 无告警 |
| JS 语法 | `node --check` 通过（319 行） |
| JSON 合法性 | `menu.d` 与 `acl.d` 两个 JSON 均解析通过（`/etc/config/poninfo` 是 UCI 格式，非 JSON） |
| shell 语法 | `init.d/poninfo` 与 `libexec/pon-info-recorder` 均 `bash -n` 通过 |
| 包名冲突 | `feeds/luci/applications` 无 `pon-info` 同名包，不冲突 |
| 依赖可得 | `feeds/luci/luci.mk` 存在；`LUCI_DEPENDS` 的 ucode/rpcd/rpcd-mod-ucode/ucode-mod-fs 为系统包 |
| fs 模块能力 | `fs.so` 确实导出 `glob`、`popen`、`mkdir`（`nm -D` 核对） |

### 修正一：TYFZA1 配置生成器漏选本包（真实阻断）

插件的实机目标是 TYFZA1（`tianyi,tyfza1`，192.168.1.1），但凌晨只把 `luci-app-pon-info` 加进了
`gwrt-mk-an7581-config.sh`，`gwrt-mk-tyfza1-config.sh` 的「PON 用户态」列表里没有它
（`grep -c luci-app-pon-info` = 0）。结果：即使编译成功，TYFZA1 固件里也不会有这个包，
设备上"手动部署可用、固件内不可用"。
已在 `gwrt-mk-tyfza1-config.sh` 的 PON 用户态列表补入 `luci-app-pon-info`；脚本末尾 `PON:` 汇总
的正则前缀 `luci-app-pon` 已能覆盖，无需再改。两个生成器 `bash -n` 均通过。

### 修正二：状态目录不自建（运行时静默失败）

`/etc/poninfo` 原先只由 `init.d/poninfo` 的 `mkdir -p` 创建。若用户禁用采样服务（`enabled=0`），
却仍在页面点「立即采样」，`record` 写 `/etc/poninfo/history.jsonl.new` 会因目录不存在而失败，
且脚本不检查 `writefile` 返回值 → 静默无响应。
已改由采集器自建：新增 `ensure_state_dir()`（`mkdir(STATE)`，目录已存在时返回 null 且不报错，
故无需先探测——实测 `exists()` 对路径恒返回 false，不可用），在 `record()`、`write_history()`、
`clear_history()` 三处写盘前调用。

### 修正三：清理空目录残留

`package/luci-app-pon-info/` 是凌晨的废弃空壳（仅含空的 `files/` 子目录，0 文件、无任何引用），
与真正的 `package/gwrt-luci-app-pon-info/` 名字相近易混，已删除。

### 冒烟测试（宿主 ucode，非实机）

把 `STATE`/`CONFIG` 改写到本地目录后实跑：

| 用例 | 期望 | 实测 |
| --- | --- | --- |
| 目录不存在时 `record` | 自建目录并写入 | `{"appended":true,...}`，目录已生成 |
| 紧接着第二次 `record` | 判重不追加 | `{"appended":false,...}`，记录数不变 |
| `clear` | 清空 | `{"cleared":true}` |
| `history 3` | 返回数组 | `[]`（清空后正确） |
| `json` | 输出全量 JSON | 正常，含 backend/device 等顶层键 |
| `history.jsonl` | 每行独立 JSON | 1 行，`json.loads` 通过 |
| `latest.json` | 合法 JSON | `json.load` 通过 |

### 本轮未做 / 待办

- **未在实机复测**：`192.168.1.1` 当前 ping 100% 丢包（离线），`record/clear` 的目录自建逻辑
  只在宿主环境验证过，需设备恢复后按上表复测。
- **未编译固件、未推送 GitHub**：本次只改工作树，未 commit、未 push。GitHub 通路本轮
  时通时不通（`gh api` 曾返回 Bad Gateway），推送待网络稳定后按上文命令执行。
- **本地无法 defconfig**：本 NAS 树的 `scripts/config/conf` 未预编译（只有 `.c` 源码），
  且工作目录路径含 `:`（gvfs SMB 挂载 `smb-share:server=...`）会让 make 的 `include` 解析异常，
  `make defconfig` 直接报「没有规则可制作目标 defconfig」。该树不是完整可编译树，
  固件编译需走云端/无冒号路径的导出树。
- **未补 i18n**：页面与菜单标题为中文硬编码，与树内同类 `luci-app-pon-wan` 做法一致，不单独拆 po。

