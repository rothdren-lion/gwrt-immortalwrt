# WORKLOG 2026-11-15 — CS-06 最小插件 TX 封装对照固件

## 授权与范围

用户要求“那就改吧，测试的先用最低插件配置来编译”，沿用本会话 GitHub 编译授权。
基于已刷入并产生新日志的 `0580ee9aa1976b81dc75933c155944b2b51aebb1` 建独立分支
`cs06-auth-minimal-261115`，版本 `261115-01`，仅 CS-06，release=false。
保留 Linux 6.18.62 / CMA64 / 7168k(7M) / 板级 MLO opt-out / 整组恢复。
未连接、刷写或重启路由器。

## 实现

- ath12k r17→r18：新增板级 `qcom,ath12k-disable-tx-encap-offload`，仅 CS-06
  wifi0/wifi1 使用。注册时不向 mac80211 广告 TX encap，既有 VIF 函数选 native
  Wi-Fi TX；RX decap、RAW 模式、其它板卡的能力、PPE-DS 独立 Ethernet bank 均保留。
  启动日志新增 `TX encapsulation offload disabled by board policy`。
- 新增独立最小配置生成器与 CI `cs06_minimal` 参数（默认 false，其它预设拒绝 true）。
  保留 LuCI/bootstrap、SSH、DHCP/DNS/防火墙/IPv6、PPPoE、双频 ath12k/原固件与校准、
  iw/hostapd-utils/tcpdump-mini。正常生产配置生成器不变。
- `gwrt-cs06-diag-defaults` 仅复用现有 LAN / Wi-Fi / SSID 三份脚本，
  不带数据分区、APK 恢复、Mesh、代理、流控、广告等插件。保留配置升级不会主动改写
  用户 SSID/密码；旧保留 overlay 中的用户自行安装插件仍应在实机确认。
- CI 在 defconfig 后及成品 manifest 上双重检查必需/禁用插件，编译前后跑真实
  mac.c TX 策略/VIF 函数测试，并保存 mac.c 哈希。

## 离线验证

证据：`/home/godsun/build/gwrt-cs06-auth-minimal-261115-evidence/`。

- backports SHA-256 核验，113 个 ath12k 补丁零 fuzz 应用。
- 实际 C 函数：TX 策略 12 组合（无 OF / 无属性 / CS-06 属性 × 固件能力 × RAW），
  验证 native/RAW/Ethernet TX、RX decap 保留；关闭策略分支的负对照在行为断言失败。
  这些是主机 mock 测试，不是固件/无线仿真。
- 原有恢复 32 / MLO 15 / 绑定迁移 5 / 内核选择器 15 项通过；最小配置 6 项通过。
- `make defconfig` 返回 0，必需无线及管理/诊断包齐全，插件守卫通过（232 个基础及依赖包）。
  本地复用既有 feeds 有 Kconfig recursive dependency diagnostics，不能称为干净配置解析；
  GitHub 使用新检出/展开配置并再次验证。
- 仓库 `scripts/gwrt-source-preflight.sh`、workflow YAML/内嵌 shell、`git diff --check` 通过。
  旧技能 source-audit 存在与本树不同的布局/插件规则，以 skill-preflight.log 保存原始结果；
  未为使旧审计通过而改动不在镜像内的其它插件。

## 因果与实机边界

本版本用于验证 WBE.1.6 认证期 `wal_tx_de_mgmt.c:338` 断言是否与 CPU TX encap
相关。不能在实机刷入验证前宣称认证已修复。最小插件减少编译开销，但也改变用户态环境；
只有再次取得 EAPOL/认证/崩溃结果才能判断效果，不能直接宣布闭源固件根因解决。

回滚源码：独立分支退回基线 0580ee9a；不影响 NAS 上其它机型和并发工作。
云端运行、实际编译与交付状态随后记录；本记录写入时尚未产生新成品。

## 云端启动与源码同步（2026-11-15 07:40 UTC 起）

实现提交 `1d5d9ba18f36b59d2d088bb99a5e33bf2897df3b` 已推送独立分支，
GitHub 运行 `43690954669`：CS-06 / `261115-01` / `cs06_minimal=true` /
release=false。任务实际已启动，并在 07:44 UTC 前进入 Generate config。
云端并非仅上传源码；后续状态以证据目录 delivery-status.json 为准。

本轮实现已选择性同步 NAS；保留 NAS-only R68S 预设及 python3-pyelftools 依赖，
未覆盖 SS-01、其它机型、未提交插件和日志。同步后 6 项最小配置测试通过。
旧版 261114-02 已被用户日志确认认证故障，核对旧 audit 的 0580ee9a/43619639969 后，
将该交付 bundle 移入系统废纸篓，移出可交付固件目录；诊断日志/转储/源码仍保留。

本轮只针对此运行的下载/审计/归档进程已启动：watch-cloud.py、finish-delivery.py。
下载采用临时目录及完整来源标记，拒绝部分包复用/覆盖。审计将核对 mac.c 等 5 份
编译源码哈希、两路 DTB 的 MLO/TX opt-out、ARM64/6.18.62 模块、两个芯片固件、
7M 镜像布局、最小 manifest 与无 APK 恢复入口。通过后交付至
`/home/godsun/build/gwrt-releases/cs06-7M-minimal/`；失败不会自动交付或刷机。
启动时 finisher 先于 collector 状态文件产生而退出，已加等待保护并重新启动，
状态确认 waiting_for_verified_download。无构建代码/云端失败由此发生。

## 正式编译阶段确认

再次通过 GitHub API 回读确认：Generate config 与 Test CS-06 ath12k recovery before compilation
均 success；Build firmware 于 **2026-11-15T07:43:55Z** 启动，当前 in_progress。
源码 SHA 与推送的 1d5d9ba1 完全一致，尚未宣称构建/镜像或实机认证成功。
证据：cloud-build-start-confirmed.json。

## 2026-11-16 成品恢复审计与交付

云端 `43690954669` 正式 Build firmware **成功**，但整个运行结论仍是 failure：
末尾最小包检查要求名称 `dnsmasq`，而 qualcommbe 默认安装的实际提供者是
`dnsmasq-full`；这是校验脚本的提供者误判。后续编译源码专项/哈希步骤因该失败被跳过，
原自动交付正确停止，未将失败状态当作成功。

本次补认精确的 `dnsmasq-full` 提供者，并增加完整包接受/相似名称拒绝测试，8 项
最小包测试通过。使用原 run 的 inspection artifact，来源标记、commit、版本和
所有原始 sha256sums 回读核对后进行本地恢复审计，没有重编/改写已有镜像：

- 实际 manifest 222 个包，配置 232 个选择，必需无线/管理包与无大型插件检查通过。
- 原始目标内核配置及 kernel.release 验证 Linux 6.18.62、ARM64、CMA64；
  FIT 里的真实内核 banner 同样为 6.18.62，没有降级。
- factory/sysupgrade 7 MiB 边界和 padding 一致；实际嵌入 DTB 的 AHB/PCI 及父节点启用，
  两路均有 MLO 与 TX encap opt-out。
- rootfs 版本 261115-01 / revision 1d5d9ba、绑定迁移/hotplug 与最小 defaults
  内容匹配；不带 APK 恢复载荷/入口或 Mesh/代理插件。
- 实际 ARM64 ath12k/ath12k_wifi7 模块及 6.18.62 vermagic 通过，
  主驱动包含 TX offload 关闭策略和整组恢复标记；两个芯片的固件载荷齐全。
- 云端编译前 32 恢复/15 MLO/5 绑定/12 TX 与 113 补丁应用记录核对通过。
  **没有编译后源文件哈希，不声称这些哈希或编译后专项在云端已通过**；
  本次以保存的原始内核配置和实际打包 FIT/DTB/驱动/文件内容补做成品审计。

已归档 `/home/godsun/build/gwrt-releases/cs06-7M-minimal/`，原始云端 failure 与
本地恢复检查边界保存在 README、audit.json、cloud-status.json 和 verification 中。
最终交付文件：

- `gwrt-261115-01-赵云cs-06-7M-minimal-sysupgrade.bin`
  SHA-256 `108cff21fecf3f918c1365a49ed818fd618fb53a41509a0b63e66fb014a39df6`
- `gwrt-261115-01-赵云cs-06-7M-minimal-factory.bin`
  SHA-256 `53d859d791b3c4096e2fc2b45fbedf97b224e702e667477a653b30a7c38bacff`

校验修复与本记录已选择性同步 NAS；固件实现仍为原编译提交 1d5d9ba1。
本轮只修源码检查/离线审计和归档，未连接/刷入/重启路由器。
此为认证故障的最小插件 **测试固件**，实机认证是否恢复尚未确认。
