# WORKLOG 2026-11-13 — 9.9 daed 流量统计与 OAF 后台修复

后续用户要求把当前565项特征库纳入GitHub并禁用在线更新，最新状态见
`WORKLOG-20261113-oaf-offline-feature.md`；本日志保留前序修复经过。

## 范围和结果

用户提供原 DAED 账号，要求解决只有连接数/UDP 会话、流量始终为零，以及打开
daed 后 OAF 无法使用的问题。目标 `192.168.9.9` 是 JDCloud RE-CS-02 GWRT2
（`jdcloud,re-cs-02-gwrt2`），GWRT `260920-05`、Linux `6.18.52`，不是 SS-01。

已通过 SSH 热修复两项问题，并在生产 LuCI 登录验证。daed 的实时上传/下载、累计量
和曲线恢复；OAF 的页面、fwx API、实时流量、客户端和应用识别均有数据。
两项服务可同时运行，未发现必须互斥的证据。没有刷机、路由器重启、内核模块替换、
GitHub 推送或固件构建；用户要求停止云端固件构建的指令继续有效。

## daed 根因与修复

原二进制版本为 `daed-4d6a433_wing-dc50308_core-5db27a0`。使用用户提供的
账号认证后，GraphQL `runtimeOverview` 的连接数/UDP 会话会变化，但速率、累计和
历史流量均为零；受控下载期间仍为零，证据见 `daed-before-traffic-probe.json`。

Wing 的 `dae/runtime.go` 查询全局 `control.SnapshotRuntimeStats(...)`，
转发路径则向当前 control plane 的实例统计对象记账。改为已初始化时直接调用
`ctl.SnapshotRuntimeStats(windowSec, maxPoints)`；API-only/未初始化模式保留
全局回退，不以 WAN 网卡计数替代代理流量。

固定官方源码版本为 dae-wing `dc50308`、dae `5db27a0`、BPF headers
`56937c66784879fe5e2ff89db5bc05aa061d594c`。旧定制二进制的全部源码改动不能仅由
版本字符串还原，不声称新源码与旧二进制逐字节对应。保留现场匹配的公开前端资源
421 个文件，压缩后 7,099,541 字节；使用 Go 1.27.1、clang 22 生成真实 BPF/trace
对象，构建静态 ARM64 daemon。

新二进制原子替换 `/usr/bin/daed`：

- 版本：`daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`
- SHA-256：`e10d7439eeeaac0cc3feb8d28197868040002637e2f8fbff3bbb4401c01f3756`
- 本地文件：`/home/godsun/build/gwrt-daed-oaf-livefix-20261113/daed-runtime1`

生产 init（含此前 netns 清理与资源路径修复）、UCI 配置、账号/订阅/规则/数据库均保留。
服务停止后另备份数据库，再替换程序并启动。验证时 daemon 无 respawn，br-lan 的
TC ingress 正常挂载 `tproxy_lan_ingr`。

## OAF 根因与修复

新页面和控制器调用 `fwx` API，内核也提供 `/proc/sys/fwx/`；旧
`appfilter-2026.04.20~569f93bf-r1` 用户态仅提供 `appfilter` ubus 对象，读取
`/proc/sys/oaf/`，并依赖已迁移的 `appfilter.global`。现场缺少 rule_manager 和
新格式 feature.bin，feature_count、appfilter_enable、record_enable 均为 0。
这套版本/API 混装可以解释页面失效，不能把时间上的先后直接认定为 daed 冲突。

从本机已有的匹配用户态包提取文件，先验证 musl 动态库 ABI 和 Lua 语法：

`/home/godsun/build/immortalwrt-mt7981/bin/packages/aarch64_cortex-a53/packages/appfilter-2026.09.24~7fcf9e87-r2.apk`

热更新 `/usr/bin/oafd`、`/usr/bin/hnat.sh`、`/usr/bin/rule_manager`、
`/etc/init.d/appfilter`、`/etc/fwxd/feature.bin`、缺失/空的
`/etc/fwxd/custom_feature.cfg`、`/etc/oaf_version`，并只补缺失的配置文件。
安装文件属主设为 root:root，重启 appfilter；没有运行 apk 安装命令，因此包管理器
记录仍是原版本。这是持久文件热修复，不等同于 APK 元数据升级。

原 appfilter/macfilter/fwx 配置及用户规则的 SHA 核对未变，原有 1 条应用过滤规则和
1 条 MAC 过滤规则保留；未替换内核 oaf.ko 或全局库。ECM
`accel_delay_pkts` 保持原值 1，未切换加速策略。

初次修复后，新后台提供 fwx common/debug；appfilter_enable、macfilter_enable、record_enable
均为 1，lan_ifname 为 br-lan。feature_count=48，API 报告 loaded=1、版本26.01.01、
app_count=48。该模块旧 `feature_init` 值仍为 0，但实际特征加载和应用识别已有数据，
不能仅据此旧字段判定未加载。后台版本7.0.1，模块 engine6.0.1。

旧明文 feature.cfg 原件仍保留，包含215个应用条目；本次新包自带免费二进制特征库为
48个应用。没有把旧格式直接写入有不同校验规则的 custom_feature.cfg，也没有声称
完成全部旧特征迁移。

## 后续要求：统一新版后台接口

用户继续要求去掉旧版后台接口；将“全部用最小的”按统一当前新版fwx接口处理，
已发起澄清并留出回复时间，未收到不同解释。没有以此为由更新全部feeds或恢复固件构建。

实机旧 `appfilter` ubus对象已被新daemon替换，不再注册。继续清理源码遗留：

- 删除LuCI旧appfilter方法权限表及旧特征目录写权限，仅通过fwx common操作；
  common可包含修改操作，因此只列在write权限，不授权debug方法。
- 删除 `94_feature_3.0`、`95_time_daily_limit` 两个旧首启脚本，避免再写旧
  appfilter.global/time/feature设置。
- 新增 `100-fwx-only-configuration.patch`：后台LAN接口、应用开关、工作模式分别
  统一读取fwx.global.lan_ifname、fwx.appfilter.enable、fwx.network.work_mode。
  移除init把 `/etc/custom_feature.cfg` 自动搬到新版目录的旧格式兼容路径。
- LuCI release2→3；appfilter release3同时包含前述依赖/配置保护及本补丁。
  appfilter仍是有效的包名、服务名和应用规则存储名称，保留这些名称并不代表旧ubus接口。

在隔离目录重编OAF用户态程序，ARM64 musl依赖加载检查通过，随后原子替换oafd、
更新init/ACL并重启appfilter、reload rpcd。未替换内核模块，也未再次重启daed。
新版oafd SHA-256：
`8c7db8e92d5071e5615b71df43cde766b1db50d32145aaa8b5e0becc698a3490`。

清理前复查时，现场特征库已变为版本26.11.11、565个应用；本次清理没有覆盖它。
替换前后8个UCI配置、feature.bin、custom_feature.cfg共10项SHA全部一致。

## 验证证据与边界

- dae/control 的 `TestGlobalRuntimeStats`、`TestControlPlaneRuntimeStats`、
  `TestRelayTCPRecordsRuntimeTraffic` 定向测试通过。
- 新二进制通过 `scripts/tests/test-gwrt-daed-browser.js`：认证、CORS/GraphQL、
  六项指标、轮询、手机布局和临时凭据处理。该隔离 API 测试外，另做了生产流量验证。
- 生产 LuCI 登录后显示下载22.9 KiB/s、上传4.4 KiB/s，已下载388.6 KiB、
  已上传356.7 KiB、连接19、UDP会话2，曲线正常。密码框登录后清空；桌面/手机
  无横向溢出，pageerror为空；截图已人工查看。
- 四次小文件下载均HTTP200。观测期间上传累计增加167674字节、下载增加92202字节，
  历史采样12点；包含背景流量，不能声称与测试文件字节量精确对应。另一个6 MB
  Cloudflare地址在用户规则中明确走直连，不用它推断代理累计应增加6 MB。
- daed重启完成后再次验证OAF：页面/API均HTTP200；客户端20、活跃应用2、
  活跃主机10、接口流量非零采样60点，可识别Github/Alibaba；桌面/手机无横向溢出，
  pageerror及API失败均为空。两个服务同时工作。
- 统一fwx后的再次回归：概览及应用过滤、访问控制、用户列表、特征库、应用记录共6个
  页面HTTP200；6个读取API均返回成功，pageerror/API失败为空；newObject=true、
  legacyObject=false。特征库loaded=1/app_count=565，客户端21、活跃应用10、
  非零流量采样36点，应用记录从初验0增加到1，已开始产生记录。
- 后一次桌面无横向溢出；390px手机复查发现已有活跃应用图标行在应用较多时横向溢出，
  截图已保留，不能继续声称全部手机布局通过。本次后台清理未改该页面样式。
- 未完整验证所有过滤路径、加速代理流覆盖、跨重启长期统计和数据库持久积累，
  本次结论限于上述实测行为。

## 源码与复现

隔离树 `/home/godsun/build/gwrt-theme-261113`，分支
`fix/theme-dashboard-261113`，修改选择性同步回 NAS：

- `scripts/patches/daed-runtime-overview-active-plane.patch`：当前实例统计查询修复。
- `scripts/gwrt-build-daed-runtime.sh`：从已准备源码、headers和匹配前端重建，
  可重复应用补丁；生成真实BPF/trace/schema、运行定向测试并输出ARM64程序。
- `gwrt-overlays/feeds/packages/net/open-app-filter/Makefile`：release2→3；
  补rule_manager需要的lua/libuci-lua依赖，保护全部8个已安装UCI配置及2个特征文件。
- 同目录 `patches/100-fwx-only-configuration.patch` 以及LuCI Makefile/ACL和两个
  旧首启脚本的删除；当前源码和实机均使用新版fwx接口。
- 本日志及AGENTS当前状态/索引。

实际构建命令（仅插件程序，不是固件）：

```sh
cd /home/godsun/build/gwrt-theme-261113
env PATH=/home/godsun/build/immortalwrt-mt7981/build_dir/hostpkg/go-1.27.1/bin:$PATH \
  GOTOOLCHAIN=local \
  GOMODCACHE=/home/godsun/build/immortalwrt-mt7981/dl/go-mod-cache \
  GOCACHE=/home/godsun/build/gwrt-daed-oaf-livefix-20261113/go-cache \
  sh scripts/gwrt-build-daed-runtime.sh \
  /home/godsun/build/gwrt-daed-oaf-livefix-20261113/source/dae-wing-dc50308 \
  /home/godsun/build/gwrt-daed-oaf-livefix-20261113/daed-runtime1
```

固件默认daed包仍使用官方v2.1.1；上述helper专门重建 `.9.9` 的定制runtime版本，
默认固件包没有自动接入这份源码补丁。未来恢复固件构建并选择DAED版本时须单独处理，
不能声称当前热修复已进入默认固件。OAF包改动已做依赖名及conffiles清单核对；本轮
没有重编OAF APK或固件。脚本语法与 `git diff --check` 通过。

## 备份和回滚

本地证据根目录 `/home/godsun/build/gwrt-daed-oaf-livefix-20261113/`（0700）：
原daed、完整配置资源备份、OAF独立备份、构建源码/日志、前后API结果、浏览器结果和
桌面/手机截图。旧诊断保留在 `/home/godsun/build/gwrt-daed-oaf-20261113/`。
数据库和配置备份含私密数据，不提交或输出；凭据/JWT不写入源码日志。

远端备份目录 `/root/gwrt-backups/20261113-daed-oaf/` 内有：

- `before.tgz`、`oaf-before.tgz`、`introduced-files.txt`、配置哈希；
- 原 `daed-before` 和一致性数据库备份 `daed-db-stopped-before.tgz`；
- 可执行 `rollback-oaf.sh`、`rollback-daed.sh`，只在需回退时使用。

OAF回滚脚本停止服务、移除本次新增的限定路径、恢复旧文件/配置并启动旧服务。
DAED回滚脚本停止服务、原子恢复旧程序及停机数据库快照、启动服务；会回退快照之后的
数据库变化。两脚本已准备，未执行。源码回退应按本次文件恢复，勿重置脏NAS树。

新版接口清理的独立目录：本地证据子目录 `oaf-fwx-only/` 包含干净用户态源码副本、
补丁、编译日志、新oafd、三文件payload、部署脚本及新增页面/API浏览器结果。
远端 `/root/gwrt-backups/20261113-oaf-fwx-only/` 含替换前程序/init/ACL备份、
10项配置/特征哈希和 `rollback.sh`，可恢复到本次清理之前已修好的fwx版本；
未执行回滚。旧版接口不会因该独立回滚重新运行。各备份均留在root受限目录。

官方源码快照SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| dae-wing-dc50308.tar.gz | `97474d801d1626b8d38c1abd6d99a182c306b6c4357bc83c50da5e501e32fb3f` |
| dae-core-5db27a0.tar.gz | `2f108404adf9c68d52bb3d836ce6f5cbef9b149b3425945d26b74066fc2e61b7` |
| dae-bpf-headers.tar.gz | `af66714e5a192aca39d736e7c9024cde42f1d7471ad31f9577c27dd74eebf6f0` |
| runtime修复patch | `a0acf6c4b7e9cda1eacb6fdf593d796e08915e182ca2688c184a2f828703215b` |

SS-01此前的UNIPHY/eMMC修改保持候选状态，实机WAN/LAN修复仍待未来固件验证。
