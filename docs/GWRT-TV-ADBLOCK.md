# GWRT-TV-ADBLOCK — 国内广告拦截（电视 + 国内通用 + 安全软件, dnsmasq 域名层, 纯文本库）

> 数据日期 2026-11-13（库版本 20261113-r2）；来源见文末；规则库为纯文本
> `/etc/gwrt-tv-adblock/ads-library.txt`（固件内模板在 `/usr/share`），
> 分类由 `gwrt-tv-adblock.config.cat_tv / cat_tv_ext / cat_cn / cat_sec`
> 开关控制；`kill` 为固定必拦档（无开关，总开关开即生效）。

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
├── Makefile                              # 主包（init/CLI/规则库/uci-defaults）
├── files/etc/gwrt-tv-adblock/ads-library.txt   # 纯文本规则库（tv/tv-ext/cn/sec/kill）
└── luci-app-gwrt-tvadblock/              # LuCI 开关页（网络 → 电视广告拦截）
```

- **规则库（无数据库/SQLite）**：单文件纯文本，`[分类名]` 行切换分类，
  每行一个域名，`#` 注释。活动库在 `/etc/gwrt-tv-adblock/ads-library.txt`
  （conffile，固件升级保留，可整体替换升级）；固件内模板在
  `/usr/share/gwrt-tv-adblock/`，/etc 缺失时 init 自愈恢复
- init：`/etc/init.d/gwrt-tv-adblock`（START=18，按启用的分类把
  `address=/d/` 以 `# --- gwrt-tv-adblock begin/end ---` 标记块写入
  `/etc/dnsmasq.conf`；该文件被 OpenWrt dnsmasq init 以 `--conf-file=`
  兜底加载，开机无需额外重启 dnsmasq）
- CLI：`/usr/libexec/gwrt-tv-adblock status|on|off <分类>|core|extended|off|update|migrate`
- 配置：`/etc/config/gwrt-tv-adblock` 的 `config.enabled`（总开关）、
  `config.cat_tv` / `config.cat_tv_ext` / `config.cat_cn` / `config.cat_sec`
  （分类开关）、`config.library_url`（库更新地址）、
  `config.custom_block` / `config.custom_allow`（自定义拦截/放行）

```sh
/usr/libexec/gwrt-tv-adblock status      # 库版本/分类计数/开关状态/实测拦截
/usr/libexec/gwrt-tv-adblock on cn       # 打开国内综合档（或 off cn 关闭）
/usr/libexec/gwrt-tv-adblock on sec      # 打开安全软件与更新档（360/微软等）
/usr/libexec/gwrt-tv-adblock off         # 总关（分类配置保留；kill 一并停用）
/usr/libexec/gwrt-tv-adblock core        # 旧三档兼容: = 总开+tv
/usr/libexec/gwrt-tv-adblock extended    # 旧三档兼容: = 总开+tv+tv-ext
/usr/libexec/gwrt-tv-adblock migrate     # 旧 mode 配置一次性迁移为分类开关
```

### 2.1 集成方式：/etc/dnsmasq.conf 标记块（v2）

早期版本尝试过两条 uci 路线，都被设备固件否决，最终以标记块直写：

| 路线 | 为什么不行 |
|---|---|
| uci `dhcp.@dnsmasq[0].conffile` | 部分固件 dnsmasq init 不支持该选项（实测不生成 `conf-file=`） |
| uci `confdir` + 生成 `/tmp/dnsmasq*.d/*.conf` | 目录名随匿名节名变化（`/tmp/dnsmasq.cfg01411c.d`），且位于 /tmp 开机重建，本服务 START=18 先于 dnsmasq 运行时目录尚不存在 |

现行方案：init 每次应用先用 awk 剥掉旧标记块，再按当前模式把
core（+extended）/ 自定义规则重写进 `/etc/dnsmasq.conf`，`stop()` 只剥不写。
该文件是 dnsmasq init 的第 949 行兜底 `--conf-file=` 加载项，不受节名/时序影响。

自定义规则生成在块内：`custom_block` → `address=/d/`（NXDOMAIN），
`custom_allow` → `server=/d/`（转发正常 DNS）。dnsmasq 按最长后缀匹配，
`server=` 放行条目可覆盖更宽的 `address=` 拦截条目，用于救误拦。

> **验证陷阱**：busybox nslookup 对 NXDOMAIN/空应答也可能返回 0，
> 判断是否拦截必须检查应答内容里有没有真实 Address
> （CLI/页面已按此实现），不能只看返回码。

> **uci 陷阱（部分固件）**：`del_list` 对不存在的条目也返回 0（不能当
> 循环条件），且没有 `remove` 命令——所以旧 uci conffile 的清理是
> 「读列表→过滤→delete 整项→重加」，不做循环判断。

## 3. 分类语义

| 分类 | uci 选项 | 条数 | 内容 | 默认 | 副作用 |
|---|---|---|---|---|---|
| tv（电视核心） | `cat_tv` | 218 | 各品牌开机广告域 + 视频 App 广告 SDK + 乐播广告子域 + 广告追踪 | 开 | 无 |
| tv-ext（电视激进） | `cat_tv_ext` | 115 | 各品牌应用商店/系统升级/语音助手/投屏服务/GITV 认证/P2P 节点 | 关 | 对应功能失效 |
| cn（国内综合） | `cat_cn` | 148 | 百度/腾讯(广点通GDT/优量汇)/字节(穿山甲)/快手/网易/新浪微博/友盟/华为/OPPO/vivo/小米手机等广告SDK与统计；主流广告联盟（mediav/tanx/domob/admaster/miaozhen 等整域） | 关 | 统计类拦截可能触发个别 App 风控提示，可白名单救回 |
| sec（安全软件与更新） | `cat_sec` | 79 | 360 全家桶 53 条（卫士/杀毒/手机助手/驱动/更新器/推广/遥测，anti-AD 全量）；腾讯管家与风控 4 条（`guanjia.qq.com` `pcmgr.qq.com` `sec.qq.com` `aegis.qq.com`）；微软 Defender 云（`wdcp/wdcpalt/spynet2/spynetalt`）与遥测根域（`data.microsoft.com` `telemetry.microsoft.com` `watson.microsoft.com`，含 akadns 回退）；Windows Update 6 条（`windowsupdate.com` `update.microsoft.com` `delivery.mp.microsoft.com` 等） | 关 | **按设计**导致 360 组件、Windows/Office 更新失效 |
| kill（固定必拦） | 无 | 4 | `hao123.com` `2345.com` `2345.cc` `2345.cn` 导航劫持全家桶 | 恒开（随总开关） | 相关站点打不开（正是不想让它开） |

cn 档刻意排除：搜/内容/云存储 CDN（bdstatic/qhres/gtimg/alipay 等）、
GRS/HTTPDNS 等功能域（`grs.*.hicloud.com`、`httpdns.ocloud`）、
推送（gw*.push.mcp.weibo.cn）、裸根域、`api.*` 标签域；
umeng 仅收 `umeng.co` 与 umengacs（对齐 anti-AD 的保守边界），
`is/gecko/ic.snssdk.com` 这类字节配置/内容域不收。
360 与腾讯风控域已从 cn 移入 sec（避免两类重复，语义归位）。

sec 档刻意排除的微软功能域：`crl.microsoft.com`（证书吊销列表）、
`teredo/win*.ipv6.microsoft.com`（IPv6 隧道）、`corp.sts/corpext.msitadfs`
（企业认证）、`msftconnecttest.com`（NCSI 联网检测，会导致 Windows
误判无网）——只拦 Defender 云/遥测/更新通道。

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

- 电视分类（tv/tv-ext）：AWAvenue-Ads-Rule v1.7.8（2026-10-22 更新，
  活跃维护）、GitHub 小米/GITV/TCL/长虹 gists、Kiterepo TV 清单、
  hkamran80 smart-tv、CSDN/ZNDS/阿里云社区实机清单
- 国内综合分类（cn）：anti-AD 20261111073634（privacy-protection-tools，
  10 万条 dnsmasq 格式）按品牌白名单标签抽取 + 上轮通用清单国内部分
- 安全软件与更新（sec）：360 全家桶取 anti-AD 全量（`360.cn/360safe.com/
  360safe.cn/qhupdate.com/mayi360.cn/ads360.cn/360os.com` 根域下全部条目）；
  腾讯管家/风控为人工验证清单（guanjia/pcmgr/sec/aegis 存活验证）；
  微软 Defender/遥测取 anti-AD curated 条目 + 人工根域收敛（data/telemetry/
  watson 根域覆盖全部子域，保留 akadns 回退目标）；Windows Update 为人工
  清单（anti-AD 不含，按微软官方更新端点整理）
- kill 必拦：hao123.com + 2345.com/cc/cn（导航劫持全家桶，人工指定）
- 处理门禁：品牌正则（白名单标签，只收广告/统计端点）→ 危险域过滤
  （裸根/CDN/功能域/推送）→ 后缀去重（父域覆盖子域）→ 与 tv 排重 →
  阿里 DNS(223.5.5.5) 存活验证（复用缓存）
- 构建脚本：`/tmp/opencode/tv-adblock/build_cn_library.py`（含全部门禁；
  tv/tv-ext 从当前库文件读回保证幂等，输出 ads-library.txt + cn-final.txt）

**升级规则库（三种方式，均不需改代码/刷固件）**：

1. LuCI 页面：填「库更新地址」→ 点「更新规则库」按钮（下载 → 内容
   （≥1 分类头 + ≥10 域名）与 dnsmasq 语法双重校验 → 备份 .bak → 替换）
2. 命令：`uci set gwrt-tv-adblock.config.library_url='https://…/ads-library.txt'`
   然后 `/usr/libexec/gwrt-tv-adblock update`
3. 手工替换 `/etc/gwrt-tv-adblock/ads-library.txt` 后执行
   `/etc/init.d/gwrt-tv-adblock reload`

库文件在 /etc（conffile），固件升级后仍保留；init 启动时若缺失会从
固件模板自愈恢复。重新打包发版时复跑构建脚本覆盖
`files/etc/gwrt-tv-adblock/ads-library.txt` 并 bump PKG_RELEASE。
