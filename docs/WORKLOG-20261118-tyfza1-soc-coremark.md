# WORKLOG 2026-11-18 — TYFZA1 型号简称、SoC/主频识别与 CoreMark

## 方向修正（用户后续明确，以此为准）

用户补充："这个不要写死，显示要能读取获取的；这个主题只接口，不要和其路由的一起；这个是猫。"

即：**不要把猫的信息塞进路由器共用的 GWRT 主题**（`gwrt-socinfo` 与仪表盘模板是所有机型共享的），
猫是独立设备，信息要在猫自己的接口里动态读取显示。

因此本文件下面"改动/实现要点"章节中有关**共享主题的两处改动已全部回滚**：

- `gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-socinfo` —— 已还原，
  三份副本哈希回到改动前的 `af2812519d79f2037197d03f6771cbbf`
- `gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut`
  —— 已还原（含三份产物副本）
- `scripts/tests/test-gwrt-socinfo.sh` —— 已移除新增的 TYFZA1 用例

**最终方案**：SoC/核数/主频的读取与显示全部放进猫专用的
`luci-app-pon-info` 插件（它本来就是猫独立页面、独立 ubus 接口），
且所有值均从系统实时读取，不写死：

| 文件 | 最终改动 |
| --- | --- |
| `package/gwrt-luci-app-pon-info/luci-app-pon-info/root/usr/sbin/pon-info` | 新增 `cpu_info()`：从 `/proc/device-tree/compatible` 读 SoC、从 `/proc/cpuinfo` 数核数、从 cpufreq 或 OPP 表读主频；挂到 `device.cpu`，并在 `show` 输出 |
| `htdocs/luci-static/resources/view/poninfo/log.js` | 概览卡片新增「CPU」行，显示 `SoC*核数` 与主频，数据全部来自 `status.device.cpu` |
| `target/linux/rtl9617c/dts/rtl9617c-tyfza1.dts` | `model` 改为 `"TYFZA1"`（保留） |
| `gwrt-mk-tyfza1-config.sh` | `coremark` 改为启用（保留） |

保留理由：DTS `model` 是设备型号定义（LuCI 从 `/tmp/sysinfo/model` 读取显示），
PON 页面「设备」行已经是动态读取它；coremark 是编译期包选择，不是显示写死。

### 动态读取实测（宿主 ucode）

| 场景 | 结果 |
| --- | --- |
| TYFZA1 compatible | `{soc:"rtl9617c", threads:4, freq_khz:1200000}` |
| 换成 `qcom,ipq5332` | `{soc:"ipq5332", ...}` —— 证明 SoC 名非写死 |
| 有 cpufreq 时 | 优先用 `cpuinfo_max_freq`（实测 1800000 覆盖 OPP 的 1200000） |
| 宿主机（x86，无匹配 compatible） | `show` 输出 `CPU ?*8  4900.00 GHz` —— 读的是宿主真实值，进一步证明无写死；猫上会显示 `rtl9617c*4  1.20 GHz` |

### 实现踩坑（已修正）

1. ucode 的 `split(s, /\0/)` 会把字符串按**单字符**拆开（不是按 NUL），
   改用逐字节 `ord()` 判断 0 来拆分 compatible。
2. 正则 `rtl[0-9]+` 匹配不了 `rtl9617c`（数字后还有字母 c），
   改为 `rtl[0-9][a-z0-9]*`（mt/ipq/en 同样处理）。
3. ucode **不支持函数提升**，被调用函数必须先定义；`cpu_info()` 依赖的
   `integer()` 定义在第 54 行、调用在第 142 行，顺序正确。

## 需求（原始）

用户："直接去修改一下 TYFZA1 这个机的 dts，把它的型号简称 TYFZA1，不要前面的 tianyi，也不要后面的 rtlxxx；
这个单独在这个机器的主题上加入识别它的 soc 型号，就是现在 dts 后面 RTL9617C*核数，主频正常显示它的主频，加入 coremark。
这个修改只针对这款机型。"

只针对 `tianyi,tyfza1`（Realtek RTL9617C 光猫），不影响其它机型。

## 改动

| 文件 | 改动 |
| --- | --- |
| `target/linux/rtl9617c/dts/rtl9617c-tyfza1.dts` | `model` 由 `"Tianyi TYFZA1 (RTL9617C serial bring-up)"` 改为 `"TYFZA1"` |
| `gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-socinfo` | 新增 `realtek,rtl*` 识别；无 cpufreq 时回退读 device-tree OPP 取最高频 |
| `gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut` | SoC 显示保留芯片原名大写（`RTL9617C*4`）；频率为空时用 socinfo 第 3 行兜底 |
| `gwrt-mk-tyfza1-config.sh` | `coremark` 从「清除」列表移出，改为显式 `add_pkg` |
| `scripts/tests/test-gwrt-socinfo.sh` | 新增 TYFZA1 用例（SoC 识别 + OPP 频率兜底） |

主题产物两处副本已同步，三份 `gwrt-socinfo` 哈希一致：

- `package/gwrt-theme/luci-theme-gwrt/root/usr/libexec/gwrt-socinfo`
- `package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt/root/usr/libexec/gwrt-socinfo`

`gwrt-theme-V3/theme/` 是唯一真源，产物由 `gwrt-theme-V3/scripts/integrate.sh` 同步；本次手工同步后
`integrate.sh --check --no-config` 返回 0。

## 实现要点

### 型号

DTS `model` 即 LuCI 显示的机型名，改为纯 `TYFZA1`。
`DEVICE_MODEL := TYFZA1`（`target/linux/rtl9617c/image/Makefile`）本来就是纯简称，无需改。
`compatible` 保持 `tianyi,tyfza1` 不变——它是设备匹配键（`SUPPORTED_DEVICES`），
改了会导致 sysupgrade 认机失败。

### SoC 显示

`gwrt-socinfo` 输出三行：SoC 代号 / CPU 线程数 / 最高频率 kHz。
原实现只认 `mt*`、`ipq*`、`en*`；RTL9617C 既没有 `soc0` machine 节点，compatible 又是
`tianyi,tyfza1` + `realtek,rtl9617c`，因此原先取不到任何值。现补 `realtek,rtl[0-9]*`。

模板侧原先无条件 `.toLowerCase()`，会显示成 `rtl9617c*4`。改为：仅对 `rtl*` 保留原名大小写，
其余机型行为不变 → 实际显示 `RTL9617C*4`。

### 主频

`target/linux/rtl9617c/config-6.18` 已开 `CONFIG_CPU_FREQ=y`、`CONFIG_CPUFREQ_DT=y`、
`CONFIG_PM_OPP=y`、`CONFIG_CLK_RTL9617C_CPU=y`，正常情况下 `/sys/.../cpuinfo_max_freq` 存在，
模板既有的 cpufreq 路径即可显示。

但为覆盖 cpufreq 未注册的情况，socinfo 增加 OPP 兜底：读
`/proc/device-tree/cpu@0/operating-points-v2/opp-hz`，取最高频点。
该表是大端 64-bit，频率均 < 2^32，故每个条目的低 4 字节是有效值、高 4 字节恒为 0。
用 `od -An -tu1` 取原始字节十进制后由 awk 按大端重组，不依赖 BusyBox awk 的 `strtonum()` 扩展。

> 实测踩坑：先用 `od -An -tu4` 结果不对（本机 od 按小端解释）；
> `od -tx1 | fold -w16` 的末段无换行会被 `read` 丢掉；
> `${var:8:8}` 是 bash 专有语法，BusyBox ash 不支持；`16#` 算术在 dash 下也不支持。
> 最终采用逐字节十进制 + awk 大端重组，BusyBox ash 与 GNU sh 均可。

### CoreMark

`feeds/packages/utils/coremark` 提供 `/etc/coremark.sh`，主题通过 `/usr/libexec/gwrt-coremark`
调用、页面点击触发。

原先 `gwrt-mk-tyfza1-config.sh` 的「清除（后期设备自行安装，固件不带）」列表里含 `coremark`，
而 `gwrt-theme-V3/manifest/config.fragment` 又写着 `CONFIG_PACKAGE_coremark=y`，两者相抵后
TYFZA1 固件里其实不带 coremark。现把它移出清除列表并显式 `add_pkg coremark`。
`CONFIG_COREMARK_OPTIMIZE_O3=y` 与 `CONFIG_COREMARK_ENABLE_MULTITHREADING=y` 保持 fragment 原样。

## 验证

| 项目 | 结果 |
| --- | --- |
| socinfo TYFZA1 场景 | `rtl9617c` / `4` / `1200000`（与期望一致） |
| socinfo 既有机型回归 | CS-06 `ipq5332`/2/1300000、MT7981 `mt7981`/2/1300000、EN7581 `en7581`/2/1300000、SS-01 `ipq6018`/2/1300000、machine 优先 `ipq6010`/2/1300000 —— 全部与改前一致 |
| `scripts/tests/test-gwrt-socinfo.sh` | PASS（新增用例；反向验证：故意破坏 rtl 匹配后该用例立即失败，确认覆盖真实生效） |
| `test-gwrt-theme-r121/r122/r123.js` | 全部 PASS |
| `integrate.sh --check --no-config` | exit 0，源与产物一致 |
| 仪表盘模板 ucode 编译 | `-T` 模板模式 + `uci` stub 下 exit 0（我改的 SoC 区块 JS 片段另用 `node --check` 校验通过） |
| 生成器语法 | `bash -n` 通过；`luci-app-pon-info` 处于 PON 用户态 add_pkg 列表，`coremark` 为显式 add_pkg |

### 未通过项（如实记录）

- `scripts/gwrt-source-preflight.sh` 两次运行分别 240s、900s 超时且无任何诊断输出，
  与 AGENTS.md 记录的历史情况一致（SMB 树上过慢），**不计为通过**。
  该脚本内含 `integrate.sh --check`，该部分已单独执行并通过。
- 未在实机验证（`192.168.1.1` 当前离线，ping 100% 丢包）。
- 未编译固件、未 commit、未 push。

## 边界

- 改动仅作用于 TYFZA1：DTS 是该机型专属文件；socinfo 的 `rtl*` 分支只匹配 realtek SoC，
  其它机型识别路径未变；coremark 调整只发生在 `gwrt-mk-tyfza1-config.sh`，
  an7581 生成器不受影响。
- 主题里 TYFZA1 无产品图片映射（光猫非路由器），仪表盘回退到通用 SVG 图标，符合设计。

## 补充：改 model 是否需要动 U-Boot（用户提问）

**结论：不需要。** 查证依据：

| U-Boot 侧识别依据 | 位置 | 受 DTS `model` 影响 |
| --- | --- | --- |
| FIT 配置 `compatible = "realtek,taurus"` | `target/linux/rtl9617c/python/make_ubi_fit.py:86,102` | 否，硬编码，原厂 U-Boot 期望值 |
| FIT 里选 fdt-dts / fdt-2p5g | 同上，按槽位/变体选 | 否，不读 model |
| boot.cmd 环境变量 `tyfza1_slot` / `tyfza1_root` / `tyfza1_block` | 同上 | 否，环境变量名 |
| 机型匹配键 `tianyi,tyfza1` | DTS `compatible` | 否，我没改 compatible（改了才会影响认机/sysupgrade） |

`model` 只进 `/tmp/sysinfo/model`（LuCI 显示名），U-Boot 完全不读它。

### 但发现一个先前改错的地方（待用户确认）

主 DTS `rtl9617c-tyfza1.dts` 的 `model` 我改成了 `TYFZA1`，
但**实际烧录的 FIT 用的是 `rtl9617c-tyfza1-ubi.dtb`**（见 image/Makefile:16），
它经 `ubi.dts → pcie.dts → pon-status.dts` 包含链，最末层各自覆盖了 `model`：

```
rtl9617c-tyfza1.dts          model = "TYFZA1"                              ← 我改的（被覆盖，不生效）
  └ pon-status.dts           model = "Tianyi TYFZA1 (native NI/PON ...)"   ← 覆盖
      └ pcie.dts             model = "Tianyi TYFZA1 (native PON/PCIe ...)" ← 覆盖
          └ ubi.dts          model = "Tianyi TYFZA1 (RTL9617C UBI)"         ← FIT 实际用这个
              └ ubi-2p5g.dts → + 2p5g.dtsi: model = "Tianyi TYFZA1 (RTL9617C, 2.5G LAN)"
```

所以**当前固件里 LuCI 仍会显示旧的长型号**。若要真正生效，需把 `ubi.dts`
与 `2p5g.dtsi`（以及链上各层）的 `model` 一并改为 `TYFZA1`。
本次未擅自改动这些文件，等用户确认后再做——因为用户强调"只针对这款机型"，
而 2p5g.dtsi 同时被其它实验 DTB 包含，需确认改动范围。

### 后续（用户确认：只改显示的，其他不动）

按用户"只要改显示的那个，其他可以不动就不动"，只改了两处**实际生效**的 model：

| 文件 | 改动 | 影响 |
| --- | --- | --- |
| `target/linux/rtl9617c/dts/rtl9617c-tyfza1-ubi.dts` | model → `"TYFZA1"` | FIT conf-1（fdt-dts，普通槽位） |
| `target/linux/rtl9617c/dts/rtl9617c-tyfza1-2p5g.dtsi` | model → `"TYFZA1"` | FIT conf-0（fdt-2p5g，2.5G 槽位） |

`compatible` 完全未动（认机/sysupgrade 键保持原样）。

链上中间层 `pon-status.dts` / `pcie.dts` 及 8 个实验 DTB 的 model 保留旧名——它们在
包含链里被后续覆盖，或根本不进正式固件，按"其他不动"不改。

验证：用 Python 展开两个变体的 `#include` 链，按出现顺序取最后一个 model：

- `rtl9617c-tyfza1-ubi.dts` → 最终 model = `TYFZA1`
- `rtl9617c-tyfza1-ubi-2p5g.dts` → 最终 model = `TYFZA1`

两个槽位启动后 LuCI 都会显示 `TYFZA1`。

### 再确认（用户在实机看到的型号）

用户反馈：实机系统里显示的是 `Tianyi TYFZA1 (RTL9617C UBI)`，即 `ubi.dts` 的 model。
两处生效点已改为 `TYFZA1`（同上），符合"精简 TYFZA1"。

"ubi soc 识别就是识别这个 RTL9617C"：SoC 代号从 `compatible` 的
`realtek,rtl9617c` 动态读取，采集器新增 `uc()` 转大写，输出 `RTL9617C`
（此前是小写 `rtl9617c`）。仍是动态读取——实测换 `qcom,ipq5332` 输出 `IPQ5332`，
证明非写死。PON 页面 CPU 行与 `show` 命令均随之显示 `RTL9617C*4  1.20 GHz`。

### 最终：SoC 不做大小写转换

用户："就识别出来的可以了，不用转大写，多此一举。"
已移除 `uc()`，SoC 代号按 compatible 原样输出 `rtl9617c`（小写）。
编译 exit=0，实测 `{soc:"rtl9617c", threads:4, freq_khz:1200000}`。

## 实机部署与验证（192.168.1.1，2026-11-19 凌晨）

设备恢复在线（ping 0% 丢包，SSH 免密可登）。SSH 客户端需 `-F /dev/null` 绕过本机
`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` 权限错误。设备无 sftp-server，
scp 失败，改用 `ssh 'cat > file' < local` 传输。

### 实机初始状态

- `/tmp/sysinfo/model` = `Tianyi TYFZA1 (RTL9617C UBI)`（旧，DTS model 改动需重编固件才生效）
- compatible = `tianyi,tyfza1` + `realtek,rtl9617c`；4 核；`cpuinfo_max_freq` = 1200000 kHz
- pon-info 为旧版（采集器 13980 / 页面 11979）

### 部署

备份到设备 `/root/gwrt-backups/20261119-pon-info-soc-before/`（pon-info、log.js、latest.json）。
部署新版采集器与页面（采集器 16225、页面 12355），chmod 755。

### 实机验证结果

| 项 | 结果 |
| --- | --- |
| `pon-info show` | `CPU  rtl9617c*4   1.20 GHz` ✅（SoC 原样小写、4 核、1.2GHz） |
| `pon-info json` | `{soc:"rtl9617c", threads:4, freq_khz:1200000}` ✅ |
| `record` 判重 | 连续两次 `appended:false`，records=60 不变 ✅ |
| `history 3` / `ubus status` / `ubus history` | 均正常，rc=0 ✅ |

### 实机发现并修复的 bug

show 里频率换算两次错误：
1. 原为 `freq_khz / 1000` 却标 GHz → 显示 `1200.00 GHz`。改为 ≥1000000 时 `/1000000` 标 GHz，否则 MHz。
2. ucode 整数除法 `1200000/1000000` 先取整成 1 → 显示 `1.00 GHz`。改用浮点常量 `/1000000.0` → `1.20 GHz`。
（页面 JS 是真浮点，不受影响。）

### 未能验证

- **系统型号仍是旧的长名**：DTS model 改动必须重编固件并刷机才生效，热更新改不了
  `/tmp/sysinfo/model`。要看到 `TYFZA1` 需走编译/刷机流程。
- **页面渲染**：LuCI 登录返回 403（root 口令策略与旧记录不同），未用浏览器实际渲染验证；
  但页面文件、JS 语法、ubus 数据均已确认正确。

### 页面渲染复核（用户指出"没有密码"）

用户纠正：设备 root 无密码。之前 403 是登录字段名错了——
LuCI 要 `luci_username` / `luci_password`，不是 `username` / `password`。
改用正确字段后登录成功（302 + `sysauth_http` cookie）。

| 验证 | 结果 |
| --- | --- |
| 登录 POST `/cgi-bin/luci` (luci_username=root&luci_password=) | 302，拿到 sysauth_http ✅ |
| 页面 `/cgi-bin/luci/admin/onu/pon-info` | HTTP 200，含"PON 信息记录"与 `poninfo/log` ✅ |
| 静态 JS `/luci-static/resources/view/poninfo/log.js` | HTTP 200 ✅ |
| 会话 ACL (`ubus call session list`) | 含 `luci-app-pon-info:[read]` 与 `luci.pon-info:[status,history,record,clear]` ✅ |
| ubus 直调 `luci.pon-info status` | 正常，含 device.cpu ✅ |

页面访问、ACL 授权、数据链路均已确认。浏览器内 JS 最终渲染未用真实浏览器截图验证；
curl 直接打 `/admin/ubus` 的 JSON-RPC 返回 Access denied 属调用方式问题
（LuCI 的 ubus 代理需额外会话参数），不影响页面正常加载后的取数。

## 2026-11-19 TYFZA1 插件集整理（gwrt-mk-tyfza1-config.sh）

用户需求："honk + iptv、aof、easytier 的 luci（不要主程序）、+ smartDNS、电视广告拦截"。

### 改动

| 段 | 包 | 效果 |
| --- | --- | --- |
| 插件面板（新增 add 段） | `luci-app-easytier`、`luci-app-iptv`、`smartdns`、`luci-app-smartdns` | 启用 |
| OAF 应用过滤（新增 add 段） | `appfilter`、`kmod-oaf`、`luci-app-oaf` | 启用（原在清除段，已移出） |
| 广告拦截（原有） | `gwrt-tv-adblock`、`luci-app-gwrt-tvadblock` | 保留 |
| 清除段 | `easytier`、`easytier-noweb` | 主程序仍不进固件 ✅ |
| 清除段 | `kmod-tun` | 已移出——`luci-app-easytier` 依赖它（不是 easytier 主程序） |

`bash -n` 通过；各包所在段与净效果已逐项核对；依赖包均在源码树中存在
（smartdns / luci-app-smartdns 在 feeds，iptv 在 pon_userspace，easytier/oaf/tv-adblock 在 package）。

### honk 未加（需用户确认）

`honk` / `honk-core` 不在当前源码树的 `package/` 或任何 feed 中。
它此前只在 SS-01 的独立构建里（`honk-core` v0.1.0-beta.6，Rust/eBPF，
见 `docs/WORKLOG-20261115-ss01-honk-easytier.md`），那棵隔离树已不存在。
因此本轮无法为 TYFZA1 配置 honk，需确认其来源（是否有可拉取的 feed/源码）后再加。

### 细节说明

- easytier 中文包 `luci-i18n-easytier-zh-cn` 在本树不存在（an7581 生成器里写了但无对应包），
  为避免无效配置，本轮未加入。
- 用户写的 "aof" 按 `oaf`（appfilter/kmod-oaf/luci-app-oaf）理解。
- iptv 只加 `luci-app-iptv`，未加 udpxy/vlmcsd（用户只说 iptv，保持最小）。

## honk 来源调查（用户提示：与 dae 同作者）

在 GitHub 找到（用户提示正确）：

- **主程序**：`https://github.com/daeuniverse/honk`（main，tag `v0.1.0-beta.6`）
- **OpenWrt 包源**：`https://github.com/daeuniverse/openwrt-packages`
  含 `honk/`、`luci-app-honk/`、`luci-lib-daeuniverse/`、`dae/`、`luci-app-dae/`、
  `vmlinux-btf/` 等包。README 说明接法：`src-link local <workspace>` 加入 feed，
  并在 `honk/src` 克隆 `git clone --branch v0.1.0-beta.6 https://github.com/daeuniverse/honk honk/src`。

### 依赖与前置条件（为何不能直接加一行配置）

| 项 | 要求 | TYFZA1 现状 |
| --- | --- | --- |
| 包源 | 需新增 feed `daeuniverse/openwrt-packages` | 未接入 |
| 源码 | `honk/src` 需 clone（约较大，含 Rust/eBPF） | 无 |
| 内核 BTF | honk 依赖 `vmlinux-btf`，CO-RE 重定位需要内核 `CONFIG_DEBUG_INFO_BTF` | SS-01 config 显式 `CONFIG_KERNEL_DEBUG_INFO_BTF=y`；TYFZA1 的 `target/linux/rtl9617c/config-6.18` 未开 |
| 工具链 | nightly Rust + eBPF + BoringSSL/SQLite 交叉编译 | 需验证 aarch64 可用 |
| Lua 依赖 | `luci-app-honk` → `luci-lib-daeuniverse + honk` | 均由新 feed 提供 |

honk Makefile 的 DEPENDS 含 `+vmlinux-btf +v2ray-geoip +v2ray-geosite +kmod-veth
+kmod-sched-core +kmod-sched-bpf ...`，是一套完整依赖链。

### 结论

honk 属"内核配置 + 新 feed + 源码拉取 + 复杂工具链"的完整移植工程，
与 smartdns/iptv 这类现成包不同，不能只改生成器一行。
已向用户说明，等待决定是否现在完整接入（含改 TYFZA1 内核 BTF 配置）。

## 2026-11-19 honk 整合进 TYFZA1 猫序列（Doona Lite 界面）

用户："整合，到这个猫序列去，然后他那个界面用 lte 的。"（lte = Lite，Doona Lite）

### 来源（用户提示与 dae 同作者，正确）

- `https://github.com/daeuniverse/honk`（tag `v0.1.0-beta.6`）
- `https://github.com/daeuniverse/openwrt-packages`（OpenWrt feed：honk、luci-app-honk、
  luci-lib-daeuniverse、dae、luci-app-dae、vmlinux-btf 等）

### 落地的改动

1. **新增 feed 包**：`feeds/daeuniverse/` 拷入 7 个包（honk/luci-app-honk/luci-lib-daeuniverse/
   dae/luci-app-dae/vmlinux-btf/vmlinux-btf-builtin），28 文件 MD5 与上游一致。
   注：SMB 树不能 git clone（chmod 不支持），改为本地 /home/godsun/build 克隆后
   用 zipfile 解压拷入；feed 目录结构与现有 feeds/ 一致（本树无 feeds.conf，feeds/ 是实体包源）。
2. **honk 源码**：`feeds/daeuniverse/honk/src/` 从 `v0.1.0-beta.6` tag 拷入（1943 文件，排除 .git）。
3. **内核 BTF**：`target/linux/rtl9617c/config-6.18` 追加（参照 SS-01 config）：
   `CONFIG_KERNEL_KALLSYMS=y`、`CONFIG_KERNEL_DEBUG_INFO=y`、
   `CONFIG_KERNEL_DEBUG_INFO_BTF=y`、`CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y`、
   `CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y`。
4. **生成器**：`gwrt-mk-tyfza1-config.sh` 加 honk 段
   （honk / luci-app-honk / luci-lib-daeuniverse / vmlinux-btf / v2ray-geoip / v2ray-geosite），
   尾部加 `==> honk:` 汇总与 BTF blob 构建提示。`bash -n` 通过。
5. **Doona Lite 界面**：`feeds/daeuniverse/honk/files/config.dae` 把
   `ui: 'embedded'` 改为 `ui: 'embedded-lite'`。因该 feed 目前只被 TYFZA1 使用，
   等效于只改这个猫；SS-01 说明 Lite/standard 切换无需重编固件。

### 必须知道的构建前置（未执行编译）

- `vmlinux-btf` 编译时**必须显式传** `VMLINUX_BTF_SRC=<带 BTF 的 vmlinux>`
  和 `VMLINUX_BTF_VERSION=6.18.55`，否则 Build/Prepare 直接 fail。
  该 blob 需先编译 TYFZA1 内核（已开 DEBUG_INFO_BTF）后从内核产物取。
- 官方 feed 只列 aarch64_generic/cortex-a53/a72/a76 的支持；TYFZA1 的 RTL9617C
  是定制 aarch64，不在官方预编译列表，必须靠本树内核现场生成 BTF。
- honk 构建用 nightly Rust + eBPF + BoringSSL/SQLite 交叉编译，aarch64 实编未验证。

### 本轮未做

未编译固件、未刷机、未推送。需先编译内核产出 BTF blob，再编 vmlinux-btf 与完整镜像验证。

## 2026-11-19 主题网络接口 PON 适配光猫

用户："现在整理一些 主题上网络接口的 PON"。

### 问题

主题仪表盘 PON 卡片/面板（`admin_status/index_gwrt.ut`）硬编码调用
`/usr/sbin/ponctl --device pon0 status --json`（为 AN7581 路由器写）。
TYFZA1 光猫**没有 ponctl**（实机确认 command not found，RPC 返回 result:[4]），
故 PON 端口显示"光模块状态读取失败"。但猫上有 `luci.pon-info` ubus 插件能读 PON 数据。

### 改动（只动 source，同步两份产物，三份哈希一致）

`gwrt-theme-V3/.../admin_status/index_gwrt.ut`：

1. 新增 `ponFromPonInfo(src)`：把 luci.pon-info 的 `link/identity` 字段映射成主题
   期望的 ponctl `schema_version=1` 形状（line/frontend/registration）。
   换算口径复用 PON 插件页面公式：dBm=10·log10(raw/10000)、温度=raw/256 °C、
   电压=raw/10000 V；rx_los=1 → wait-optical-signal；gearbox_ready=1 且无 los → operational。
2. 新增 `fetchPonInfoFallback(force)`：调 `rpcD('luci.pon-info','status',{})`。
3. 改 `fetchPonStatus(force)`：ponctl 无有效 stdout（或报错）时回退到上面。
   路由器仍有 ponctl → 走原路径，**零影响**。

### 验证

- ucode `-T` 模板编译 exit=0；三份模板哈希一致 `cab3b405...`。
- 用实机真实 `pon-info json` 喂映射函数：schema_version=1、mode=xgpon、
  lifecycle=wait-optical-signal、温度 36.8°C、电压 3.33V、无光时 rx/tx=null —— 全部正确。
- 部署新模板到设备 `/usr/share/ucode/luci/template/admin_status/index_gwrt.ut`
  （备份在 `/root/gwrt-backups/20261119-pon-theme-before/`），清 LuCI 缓存后
  仪表盘 `/admin/status/overview` HTTP 200，含 gwrtPortStrip/网络接口状态图。

未用真实浏览器截图确认 PON 卡片最终数值；取数链路与页面加载均已验证。

### GitHub 推送（未完成，需用户决策）

目标仓 `rothdren-lion/gwrt-immortalwrt`。克隆到本地 `/home/godsun/build/gwrt-github-sync`
检查历史：本地 HEAD `00ffe63444`（11-14 tv-adblock 系列）**不在远端历史**；
远端 HEAD `bcfe209d`（11-18 sgdisk/wifi-scripts/gwrt-theme r123 系列）本地也没有。
两条线真分叉，无 merge-base。SMB 树上 git 无法写 config.lock（chmod 不支持），
加不了 remote。强推会覆盖远端 11-18 工作，故未推送，等用户定夺合并策略。
