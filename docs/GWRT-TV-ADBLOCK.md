# GWRT-TV-ADBLOCK — 国内智能电视广告拦截（dnsmasq 域名层）

> 数据日期 2026-11-13；来源见文末；数据文件随包安装到
> `/usr/share/gwrt-tv-adblock/`，模式由 `gwrt-tv-adblock.config.mode` 控制。

## 1. 原理与边界

通过 dnsmasq `address=/domain/`（不带 IP）让 A/AAAA 均返回 **NXDOMAIN**，
局域网内所有使用本机 DNS 的设备（电视/盒子/手机）全部生效：

| 广告类型 | 拦截效果 |
|---|---|
| 开机广告（小米/创维/TCL/长虹/海信/索尼） | ✅ 全拦 |
| 桌面推荐位/商店弹窗/会员推广 | ✅ 大部分 |
| 视频 App 广告 SDK（银河奇艺/腾讯TV/优酷TV 等） | ✅ 大部分 |
| 投屏广告（乐播 hpplay 广告子域） | ✅ |
| 视频贴片广告（与正片同 CDN 域名） | ❌ DNS 层无法区分，只能靠会员/换源 |
| 硬编码 IP 直连的广告 | ❌ 需要 IP 层（见 §5） |
| TV 自带 DoH/DoT 绕过路由 DNS | ❌（少数机型） |

**生效关键**：屏蔽启用后电视里已缓存的广告素材还会播，需要到电视端
「电视管家」清理缓存并重启电视（部分品牌要恢复出厂）。

## 2. 包结构与用法

```
package/gwrt-tv-adblock/
├── Makefile                              # 主包（含 conf 数据/init/CLI）
└── luci-app-gwrt-tvadblock/              # LuCI 开关页（网络 → 电视广告拦截）
```

- 规则文件：`/usr/share/gwrt-tv-adblock/tv-ads-core.conf`（核心档）、
  `tv-ads-extended.conf`（激进档）
- init：`/etc/init.d/gwrt-tv-adblock`（START=18，在 dnsmasq 之前把
  `conffile` 写进 `dhcp.@dnsmasq[0]`，开机无需额外重启 dnsmasq）
- CLI：`/usr/libexec/gwrt-tv-adblock status|core|extended|off`
- 配置：`/etc/config/gwrt-tv-adblock` 的 `config.mode` = off/core/extended

```sh
/usr/libexec/gwrt-tv-adblock core        # 核心档（默认，无副作用）
/usr/libexec/gwrt-tv-adblock extended    # 激进档（见下）
/usr/libexec/gwrt-tv-adblock off
/usr/libexec/gwrt-tv-adblock status      # 查看模式/条数/实测拦截结果
```

## 3. 两档语义

| 档 | 条数 | 内容 | 副作用 |
|---|---|---|---|
| core | 218 | 各品牌开机广告域 + 视频 App 广告 SDK + 乐播广告子域 + 广告追踪 | 无 |
| extended | 115 | 各品牌应用商店/系统升级/语音助手/投屏服务/GITV 认证/P2P 节点 | 对应功能失效，默认不启用 |

**刻意排除的危险条目**（野清单常见，直接抄会翻车）：NTP、DNSPod、
connectivitycheck、米家控制域（`api.io.mi.com`）、裸根域（`mi.com`/
`xiaomi.com`）、投屏认证域、手机推送（xmpush/友盟推送）等。

## 4. 已覆盖品牌（用户设备：小米 / 创维酷开 / TCL雷鸟 / 长虹CHiQ）

| 品牌 | 核心档关键域 | 激进档相关 |
|---|---|---|
| 小米电视 | `api.ad.xiaomi.com` `sdkconfig.ad.xiaomi.com` `t7z.cupid.ptqy.gitv.tv`(银河开机广告) `stat.pandora.xiaomi.com` `data.mistat.xiaomi.com` | 应用商店(pandora appstore) `gallery.pandora`(桌面画廊) `milink`(投屏) `assistant`(小爱) DVB `mishop`(商城) |
| 创维/酷开 | `active.tc.skysrt.com`(开机广告) `hoisin.coocaatv.com` `tc.skysrt.com` | `api.upgrade.skysrt.com` 升级 |
| TCL/雷鸟 | `ads.api.my7v.com` `hwads-t.api.my7v.com` `ads-uo.api.leiniao.com` | `my7v.com/leiniao.com` 根域、升级域 |
| 长虹/CHiQ | `ads.huan.tv` `adlink-api.huan.tv` `adservice.chsmarttv.com` | `huan.tv/smart-tv.cn` 根域、云服务、语音 |
| 其余 | 海信聚好看 `*-cmp.hismarttv.com`、索尼 `*.ssm1/2.internet.sony.tv`、GITV/腾讯TV/优酷TV/乐播广告子域 | — |

米家 App 不受影响（`api.io.mi.com` 未拦）；路由器如启用 AdGuardHome 等
其他 DNS，需把规则导入对应工具（本包只作用于 dnsmasq）。

## 5. IP 层补充（可选，未默认启用）

`address=` 只拦域名。对硬编码 IP 的广告，可用 dnsmasq `nftset` 把已拦
域名解析出的 IP 灌进 nft set 再 drop：

```
# dnsmasq 示例（按需逐域开启）
nftset=/ad.hpplay.cn/4#inet#fw4#tvads
# nft 侧建 set 后加 forward drop 规则
```

参考：`/tmp/opencode/tv-adblock/ad-server-ips.txt`（广告域名当前解析的
2222 个 IP）。**不要直接大段封禁**——这些是共享 CDN IP，会把正片一起打死；
并且硬编码 IP 属少数行为，默认不做。

## 6. 数据来源与更新方法

- 合并来源：AWAvenue-Ads-Rule v1.7.8（2026-10-22 更新，活跃维护）、
  GitHub 小米/GITV/TCL/长虹 gists、Kiterepo TV 清单、hkamran80 smart-tv、
  CSDN/ZNDS/阿里云社区实机清单
- 处理：跨源去重 + 阿里 DNS(223.5.5.5) 存活验证（剔除 145 个 NXDOMAIN
  死域）+ 人工安全裁决（分层/排除危险条目）
- 更新流程：重新抓取来源 → 复跑合并脚本
  （`/tmp/opencode/tv-adblock/merge.py` + `classify2.py`）→ 覆盖
  `files/usr/share/gwrt-tv-adblock/*.conf` → `dnsmasq --test` 校验 →
  bump PKG_RELEASE
- 全网通用广告（手机 SDK 等 964 条）不在本包内，需要时可另行订阅
  anti-AD / AWAvenue（adblock-fast 或 AdGuardHome）
