# WORKLOG 2026-11-13 — gwrt-tv-adblock 国内电视广告拦截包

记录日期 2026-11-13 / 操作人 GLM (OpenCode) / 项目 GWRT ImmortalWrt

## 1. 任务背景

用户要求收集国内电视广告的域名/IP，评估 OpenWrt hosts 拦截能否解决广告问题。
结论：域名层（dnsmasq `address=`）可拦开机广告/独立广告 SDK/投屏广告；
贴片广告与正片同 CDN 域名、硬编码 IP 广告拦不住。用户确认做独立包 +
LuCI 开关，家里设备为小米/创维/TCL/长虹。**本轮仅源码，未触发固件构建
（AGENTS.md 要求固件构建继续停止）**。

## 2. 操作过程

1. 收集来源并下载原始规则（`/tmp/opencode/tv-adblock/src/`）：
   - AWAvenue-Ads-Rule v1.7.8 hosts + adguard 两种格式（2026-10-22 仍在更新）
   - GitHub gists：Jesn(小米TV hosts)、loerise(小米TV dnsmasq)
   - Kiterepo dnsmasq adblacklist（长虹/腾讯TV 节）、hkamran80 smart-tv
   - 博客实测清单（TCL xuconnery、创维 Alliot、小米 miuiver/ZNDS 等）作为种子
2. `merge.py`：三种格式解析合并（hosts/dnsmasq address/adguard `||d^`），
   1413 域名去重，DROP 安全黑名单（NTP/DNSPod/米家/裸根域/内容CDN等），
   按升级域模式自动分档。
3. `classify2.py`：人工裁决分层（system/apps/general/extended），
   阿里 DNS 存活验证剔除 145 个 NXDOMAIN 死域，生成最终文件。
4. 副作用隔离：TCL/长虹裸根域、乐播认证子域、小米 appstore/语音/投屏/
   DVB/商城、GITV 认证/P2P、腾讯TV直播域 → 全部移入 extended 并注释副作用。
5. 创建 `package/gwrt-tv-adblock/`：
   - 主包 Makefile（conffiles 含 /etc/config/gwrt-tv-adblock）
   - `files/usr/share/gwrt-tv-adblock/tv-ads-core.conf`（218 域名，去重后）
     与 `tv-ads-extended.conf`（115 域名）
   - `files/etc/init.d/gwrt-tv-adblock`（START=18，按模式挂 dnsmasq
     conffile，boot 期不重启 dnsmasq；reload 才重启）
   - `files/usr/libexec/gwrt-tv-adblock`（status|core|extended|off，
     status 含 nslookup 实测两条广告域）
   - `files/etc/uci-defaults/90_gwrt-tv-adblock`（建配置/enable/start）
   - `luci-app-gwrt-tvadblock/`（luci.mk 经典 cbi 风格：controller +
     model + rpcd ACL；页面显示模式/规则数/nslookup 验证；
     on_after_commit 调 init reload）
6. `docs/GWRT-TV-ADBLOCK.md` 设计文档（原理/边界/用法/品牌核对/IP 层/
   来源与更新方法）。

## 3. 结果与验证

- `dnsmasq --test -C` 两份 conf 均 `syntax check OK`（主机 dnsmasq 2.92）
- `sh -n` init/CLI/uci-defaults 全通过；Makefile recipe tab 检查通过
- 域名质量门（python）：core 218 / ext 115 无重复、无跨档重叠、格式合法、
  无 DROP 危险域、用户四品牌开机广告域齐全
  （api.ad.xiaomi.com / active.tc.skysrt.com / ads.api.my7v.com /
  ads.huan.tv / t7z.cupid.ptqy.gitv.tv / ad.hpplay.cn 均在 core）；
  milink/assistant/io.mi/sdkauth 确认不在 core
- ACL JSON `json.load` 通过；主机无 lua 解释器，lua 仅做结构自查
- 中途发现索尼广告域在 core 重复 2 条，已去重为 218
- 未编译固件、未刷机、未重启设备；产物数据备份在 `/tmp/opencode/tv-adblock/`

## 4. 文件清单与回滚

新增（未推送 GitHub；本地提交见 git log）：

| 文件 | 说明 |
|---|---|
| `package/gwrt-tv-adblock/Makefile` | 主包 |
| `package/gwrt-tv-adblock/files/...` | init/CLI/uci-defaults/config/两份 conf |
| `package/gwrt-tv-adblock/luci-app-gwrt-tvadblock/` | LuCI 开关页 |
| `docs/GWRT-TV-ADBLOCK.md` | 设计文档 |

回滚：删除上述新增文件即可（均为新增，未改任何现有文件）。
AGENTS.md 仅加代码地图行与日志索引行（该文件另有用户在途修改，
未纳入本次提交）。

## 5. 待办/未完成

- 实机验证：刷入含该包固件后按品牌核对开机广告（本轮未刷机）
- 激进档是否默认对某品牌放开（如创维升级拦截）待用户决定
- 贴片广告如需拦截，走 OAF/DPI 或内容源侧方案（另行评估）
- 数据可定期重跑合并脚本更新（来源活跃：AWAvenue 月更）
- LuCI 页面为经典 cbi 风格，若后续主题 r118 需要首页卡片入口可再加

## 6. 环境备注

- 主机 dnsmasq 2.92 可用 `--test`；无 lua 解释器
- 数据工作目录 `/tmp/opencode/tv-adblock/`（merge.py/classify2.py/
  liveness.json/清理前后清单/hosts 版/ad-server-ips.txt/dead-domains.txt）
- 构建树仍禁止 `make`/云端编译
