# WORKLOG 2026-11-02 · 概览卡片 (v10) + 接入设备信号/上下行

目标：修掉 GWRT 概览页观感与逻辑问题，并在 `root@192.168.8.8`（GWRT 261029-02 /
qualcommax/ipq60xx，AX6600）上实机验证。改动**不重建固件**，只热更新运行时文件。

## 1. 实机环境

- 设备：`192.168.8.8`，root 空密码，LuCI 主题 `luci-theme-gwrt-1.0-r94`
- 运行时文件：
  - `/usr/share/ucode/luci/template/admin_status/index_gwrt.ut`（与本地源 md5 一致）
  - `/www/luci-static/gwrt/css/cascade.css`（设备端为**压缩后**的版本，与本地源
    base 不同：本地 line1 是压缩 base + 追加规则；设备端是另一版压缩 base）
- 结论：**整包替换 cascade.css 有风险**，本次采用「保留设备原 base + 追加 v10 段」的方式。

## 2. 改动内容

### 2.1 接入设备（`renderDhcp`）

- 新增 **信号** 列：无线客户端显示信号格 + dBm（分级着色）+ **协商速率**
  `↓tx/↑rx`（数据来自 `iwinfo assoclist`，单位 kbps → M/G）。
- **速率 / 累计** 列拆成 **下行 ↓ / 上行 ↑** 两行（bandix `t_rx_r/t_tx_r`、
  oaf `down_rate/up_rate` 分别落到 `rate_rx/rate_tx`、`total_rx/total_tx`）。
- 表头中文化：`主机 | IP | MAC | 接入 | 信号 | 速率 ↓/↑ | 累计 ↓/↑ | 在线时长 | 操作`。
- 新增斑马纹 + 悬停高亮，表头 sticky，最小宽度 1080px（横向滚动）。

### 2.2 概览 8 卡（CSS + 少量标记）

- 每张卡按 `data-gwrt` 配识别色：顶部强调条 + 标题色点 + 右上角径向渐隐。
- 布局改 **bento**（≥1001px）：`12` 列网格
  - 第 1 排：系统信息 / CPU·温度 / 运行存储 / 活跃 App（各 3 列）
  - 第 2 排：连接设备(5) / 连接数(4) / 网速-EQoS(3)
  - 第 3 排：日志报错(12)，日志计数行限宽左对齐
  - ≤1000px 回到 2 列 / 1 列，原断点不破坏。

### 2.3 顺带修的逻辑 bug

- `getCPUUsage` 在 IPQ6010 返回 `?`（`/sbin/cpuusage` 为空）：新增 `/proc/stat`
  增量兜底（经 ACL 已放行的 `/bin/cat` exec 读取）。
- CPU 频率只认 `armpll`，IPQ6010 是 `apcs_alias0_core_clk`：补匹配，现能显示 `1.32/1.61 GHz`。
- IPv6 列表出现 `::` / `fe80::` 噪声：`cleanIpv6` 过滤 `::`、`::1`、全零；
  `firstIpv6` 不再回退链路本地。
- `bandix` 把无线客户端 `conn` 报成 `wired`：`devViaKind` 增加
  `gwrt-clients.json` 的 `via` 纠正；网速卡活跃设备列表也改用 `devViaLabel`。

## 3. 本地源同步位置

- 规范源：`gwrt-theme-V3/theme/luci-theme-gwrt/{htdocs,root}`
- `scripts/integrate.sh` 目标（已手工同步这两文件，未跑 defconfig 以免动 `.config`）：
  - `package/gwrt-theme/luci-theme-gwrt/`
  - `package/gwrt-theme/luci-theme-gwrt/luci-theme-gwrt/`
  - `package/gwrt-theme-lite/luci-theme-gwrt-lite/`

## 4. 部署 / 回滚

部署（设备无 sftp-server，用 ssh 重定向，不能用 scp）：

```sh
cd gwrt-theme-V3
UT=theme/luci-theme-gwrt/root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut
ssh root@192.168.8.8 'cat > /tmp/index_gwrt.ut.new' < "$UT"
awk '/\/\* ── v10:/{p=1} p' theme/luci-theme-gwrt/htdocs/luci-static/gwrt/css/cascade.css | \
  ssh root@192.168.8.8 'cat > /tmp/v10.css'
ssh root@192.168.8.8 '
  T=/usr/share/ucode/luci/template/admin_status/index_gwrt.ut
  C=/www/luci-static/gwrt/css/cascade.css
  [ -f $T.bak-v10 ] || cp -a $T $T.bak-v10
  [ -f $C.bak-v10 ] || cp -a $C $C.bak-v10
  cp /tmp/index_gwrt.ut.new $T
  cp $C.bak-v10 $C; cat /tmp/v10.css >> $C
  rm -rf /tmp/luci-modulecache
  /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart'
```

回滚：

```sh
ssh root@192.168.8.8 '
  T=/usr/share/ucode/luci/template/admin_status/index_gwrt.ut
  C=/www/luci-static/gwrt/css/cascade.css
  cp -a $T.bak-v10 $T; cp -a $C.bak-v10 $C
  rm -rf /tmp/luci-modulecache; /etc/init.d/rpcd restart'
```

> 文件位于 overlay（`/overlay` = mmcblk0p18 f2fs），重启保留；`.bak-v10` 同理。

## 5. 验证

- Playwright（headless chrome，root 空密码登录）截图 + `pageerror/console`：
  `rows=23, cols=9, sigCells=2, sigLink=2, rateSplit=23, ERRORS=[]`
- CPU 11%~50% 动态、频率 1.32/1.61 GHz；无线客户端信号 −52/−57 dBm，
  协商速率 ↓72M/144M ↑48M；活跃设备列表显示 WiFi 2.4G。

## 6. 未做 / 建议

- 未 bump `PKG_RELEASE`（仍 r94），未重建固件；下次打包可 +1 并复核
  `cascade.css` base 版本差异。
- 设备端 cascade.css base 与本地源 base 不是同一版，若整树重建会覆盖设备端
  历史差异，需在重建前对齐 base。

---

## 7. v11 补充（设备/连接合并 + 信号重排 + 网速趋势 hover）

- 设备卡与连接数卡合并为 `gwrt-devcon`（左：设备数 + 图标墙；右：连接数 + TCP/UDP + 趋势）。
- 日志报错卡移除；网速卡 IP 右上、下方实时流量趋势（hover 显示时间+速率）。
- 接入设备信号列：无线显示频段（2.4G/5.2G/5.8G/6G）+ 接口（phy0-ap0）+ dBm（分级颜色）+ 协商速率；有线显示 `LAN1/LAN2/...`。
- 接入列：无线显示 `WiFi`，有线显示 `LANx`。
- 设备图标角标显示该 IP 的 conntrack 连接数（前端统计 `/proc/net/nf_conntrack`）。
