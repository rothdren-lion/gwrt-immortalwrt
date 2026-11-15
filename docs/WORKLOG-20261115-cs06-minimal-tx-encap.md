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
