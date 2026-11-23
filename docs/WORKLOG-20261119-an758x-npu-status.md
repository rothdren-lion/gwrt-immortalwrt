# WORKLOG 2026-11-19/20 — AN758x NPU 状态数据链路修复 + 固件加回 bandix-plus

## 1. 范围

用户反馈两件事：① AN758x 系列 SoC 读取 / NPU 加速显示好像不正常（主题首页加速卡）；
② `luci-app-airoha-npu` 状态详情页刷机后看不到数据；③ 追问主题流量监控取样能否正常。
排查后按用户指示"没有就加入，然后推到 ihu"实施修复并把改动推到
`rothdren-lion/gwrt-immortalwrt` master。未编译成品、未刷机、未操作设备。

## 2. 排查结论

### 2.1 主题首页 SoC 读取（gwrt-socinfo）
- helper 用 machine/compatible 匹配 `mt/ipq/en` 前缀；AN7581/AN7583 板级 compatible
  以 `airoha,en7581`/`airoha,en7583` 兜底，显示 `en7581*4`/`en7583*4` 属设计内
  （AN758x 即 Airoha EN758x 系列的板级命名，同一芯片）。本机模拟 4 种输入均正确。
- 判定：**无功能性 bug，不改**。

### 2.2 主题首页 NPU 行（gwrt-accelinfo）——真 bug
- 探测列表只有高通命名（`qca_npu`/`npu`/`qca_nss_npu`、`debug/qca-npu|npu`）+
  `/sys/devices/platform/*npu*` 单层 glob。
- AN758x 用内置驱动 `airoha-npu`（`airoha_npu.c` `.name="airoha-npu"`，
  `CONFIG_NET_AIROHA_NPU=y` 内建），platform device 在 `soc/` simple-bus 下：
  `/sys/devices/platform/soc/1e900000.npu`。现有节点一条都匹配不上 → `npu:false`
  → 首页 NPU 行被隐藏。HG5585F/HG5382A/XG-040G/H3C HM2004 等 DTS 均
  `&npu { status="okay" }`，硬件侧正常。

### 2.3 luci-app-airoha-npu 状态详情页无数据
对照内核源码（build_dir linux-6.18.55）逐条核对插件数据源：

| 区块 | 数据源 | 261022-01 实际 | 根因 |
|---|---|---|---|
| Frame Engine | busybox `devmem` + `/dev/mem` | **整段无数据** | `# CONFIG_KERNEL_DEVMEM is not set` 且 busybox DEVMEM 关 |
| CPU PLL / 超频 | 同上 | 0 / 不可用 | 同上 |
| NPU 版本 | DTS `firmware-name` → strings | "Unknown" | 纯 ONT 板不含 `an7581-npu-mt7992/7996.dtsi`，无 `firmware-name` 属性，脚本只从 DTS 读 |
| NPU 时钟 | `/sys/kernel/debug/clk/npu/clk_rate` | 0 | 树里无 airoha clk 驱动，节点不存在（边界，未修） |
| NPU 核心 | `/proc/interrupts` `airoha-npu-wdt` | 正常 | — |
| 内存区域 | dmesg `OF: reserved mem:` 行 | 正常 | pr_fmt 前缀 + `0x..0x (KiB) nomap non-reusable <name>` 格式核对一致 |
| Offload/PPE 表 | `/sys/kernel/debug/ppe/{bind,entries}` | 正常 | 驱动 `debugfs_create_dir("ppe")` 命名一致；fw4 默认 `flow_offloading 1` |
| WiFi 队列 | mt76 token_info | 空 | 本固件无 mt76/WiFi 包（纯 PON ONT 边界） |
| NPU 状态卡 | `/sys/bus/platform/drivers/airoha-npu` | 正常 | 驱动名核对一致 |

另发现插件健壮性 bug：`npu_cores=$(grep -c ... || echo 0)` 在无匹配时产生
`"0\n0"`（grep -c 已输出 0），printf 报 "not completely converted" 且脚本非零退出。

### 2.4 主题流量监控取样链在 AN758x 不可用

- 今天/周期/总量 + 首页速率曲线：`gwrt-traffic-daily` 5 秒后台守护唯一取样源是
  Bandix（`luci.bandix_plus getSnapshot`，rpcd 直调回退仍是 Bandix），无 Bandix
  快照时防伪造逻辑直接 return null → 全部无数据。261022-01 按 50MB 预算刻意
  不带 bandix-plus（manifest 已核对无该包）。
- WAN 卡 IPv4/IPv6 双栈独立曲线：读高通 NSS debugfs，AN758x 无 → "暂无统计"。
- PPE 行正常：renderPpe 用 `network.device status` 的 WAN 口 rx/tx 算利用率。
- `gwrt-ppe-stats`（Airoha PPE 流表汇总）首页 0 引用未接线；其包字节需
  `CONFIG_NET_AIROHA_FLOW_STATS`（当前关）。

## 3. 修复内容

1. `package/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu`
   - NPU 版本回退：DTS 无 `firmware-name` 时按 SoC 取默认固件
     （en7581 → `airoha/en7581_npu_rv32.bin`，an7583 → `airoha/an7583_npu_rv32.bin`），
     与驱动 request_firmware 回退一致。
   - `npu_cores` 改为 `npu_cores=$(grep -c ...) || npu_cores=0`，消除 `"0\n0"`。
   - `Makefile` PKG_RELEASE 2 → 3。
2. `gwrt-mk-an7581-config.sh`：新增「NPU 插件数据源」段，固化
   `CONFIG_KERNEL_DEVMEM=y` + `CONFIG_BUSYBOX_DEFAULT_DEVMEM=y`（defconfig 后
   sed/append，随后的 defconfig 复检会保留）。
3. `config.an7581-261022-01`：两行 devmem 原位翻转。
4. `gwrt-accelinfo` 双副本（gwrt-theme-V3 + package/gwrt-theme，SHA 一致）：
   NPU 探测补 Airoha 节点 —— `/sys/module/airoha_npu|airoha-npu`、
   `/sys/kernel/debug/airoha-npu|airoha_npu`、
   `/sys/devices/platform/{soc,soc@0}/*npu*`、
   `/sys/bus/platform/drivers/airoha-npu|airoha_npu/*.npu`（绑定设备，最精确）。
5. **固件加回 bandix-plus（261120，用户指示"没有就加入"）**：
   - `gwrt-mk-an7581-config.sh`：`bandix-plus` / `luci-app-bandix-plus` /
     `luci-i18n-bandix-plus-zh-cn` 移入「插件面板」安装清单，并从第 3 步
     unset 清单和第 4 步 defconfig 复检 unset 清单两处移除；头部体积预算注释更新。
   - `config.an7581-261022-01`（NAS 本地产物，不入库）：bandix 两行翻转 =y。
   - bandix-plus 是按架构下载的预编译 Rust 二进制（aarch64 压缩包 2.6MB），
     依赖 `zoneinfo-all +conntrack +iw`（非 CS-07 目标）由构建自动解析；
     `package/gwrt-{,luci-app-}bandix-plus` 远端仓库已存在，无需新增。
   - 主题流量监控取样链恢复：Bandix 在固件内即取样源可用；双栈独立曲线
     仍受 NSS 限制（"暂无统计"），PPE 行不受影响。

## 4. 测试

新增 `scripts/tests/test-gwrt-an758x-npu-status.sh`：accelinfo 双副本 SHA/内容断言 +
主机 JSON 合法性；rpcd 去掉 `/lib/functions.sh` 后 list/getStatus 直跑 JSON 校验 +
固件回退断言；mk 脚本与种子 config 的 devmem 固化断言；bandix 加回断言
（add 清单唯一出现 + 种子 config =y）。

```sh
sh scripts/tests/test-gwrt-an758x-npu-status.sh   # PASS（含 bandix 断言）
sh scripts/tests/test-gwrt-socinfo.sh             # PASS（回归）
```

## 5. 推送到 rothdren-lion/gwrt-immortalwrt（ihu）

- 远端 master（c68fa5fb0d…，TYFZA1 系列）与 NAS 本地工作逐文件三方比对：
  `gwrt-mk-an7581-config.sh`/`AGENTS.md`/`package/luci-app-airoha-npu/Makefile`
  远端内容均等于本地改动前基线（唯一差异即本轮新增），accelinfo 远端 blob SHA
  `ffedbbae…` 与本地改前一致；`config.an7581-261022-01` 远端不存在（NAS 本地
  构建产物，不入库），无覆盖风险。
- 2026-11-13 先例：普通 HTTPS 推送曾卡死，走 GitHub Git Data API（blobs →
  base_tree 树 → commit → update ref force=false）。

## 6. 边界与待办

- **需要重新编译**才能让 devmem 修复进固件（Frame Engine、PLL、超频段）；
  rpcd 脚本修复可用 apk/ipk 单包更新或刷入新固件。
- NPU 时钟恒 0：树里没有 airoha clk 驱动（`drivers/clk/airoha` 不存在），无数据源可接。
- WiFi 队列段在本固件（无 mt76）恒空，属预期边界。
- 内存区域依赖 dmesg 环形缓冲，久跑后启动日志被挤出会显示空；如需持久可在首启把
  该行落盘，本轮未做。
- 未实机验证：需要用户刷入新固件或在设备上手动替换 rpcd 脚本后核对页面。
