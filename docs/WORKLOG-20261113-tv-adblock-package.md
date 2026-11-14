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
   - `files/etc/init.d/gwrt-tv-adblock`（START=18，按模式把规则挂进
     dnsmasq；v2 起改为 /etc/dnsmasq.conf 标记块，见 §7.1；
     boot 期不重启 dnsmasq，reload 才重启）
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

## 7. 部署到 192.168.9.9（RE-CS-02 GWRT2，手工安装，不涉及固件构建）

用户要求在 `192.168.9.9` 直接部署看效果。设备为经典 Lua LuCI（非 client JS），
dnsmasq 2.93、busybox pgrep 无 `-c`、dropbear 无 sftp-server（须 `scp -O`）。

### 7.1 安装与踩坑

1. 9 个文件经 `scp -O` 传至对应路径（规则/init/CLI/config/uci-defaults/
   controller/model/ACL），首次验证即出现两次故障：
   - **uci 陷阱实锤**：该设备 `del_list` 对不存在条目返回 0，原
     `while uci del_list` 写法死循环，超时 SSH 在设备留下卡死进程
     （ash/uci-defaults/rc.common），已杀。清理改为
     「读列表→过滤→delete 整项→重加」。
   - **conffile 方案失败**：`dhcp.@dnsmasq[0].conffile` 挂载成功
     （/etc/config/dhcp 30 行 + uci show 均在），但该固件 dnsmasq init
     不支持 conffile 选项，生成配置里没有 `conf-file=`，拦截无效。
2. **confdir 方案失败**：init 认 `confdir`，默认
   `/tmp/dnsmasq${cfg:+.$cfg}.d`。匿名节名 uci get `@dnsmasq[0]` 推导不出
   （生成 `cfg01411c` 带后缀变体），首次部署生成到错误路径
   `/tmp/dnsmasq.dnsmasq.d/gwrt-tv-ads.conf`；且 /tmp 目录开机重建、
   本服务 START=18 早于 dnsmasq START=19 时目录不存在。弃用。
3. **最终方案（v2，已生效）**：规则以
   `# --- gwrt-tv-adblock begin/end ---` 标记块直写 `/etc/dnsmasq.conf`
   （设备 init 942-949 行：`/etc/dnsmasq.conf` 始终被 `--conf-file=`
   兜底加载，不受节名/时序影响）。init 每次 apply 先 awk 剥旧块再重写，
   `stop()` 只剥；一次性清理旧 uci conffile 与 /tmp 残留。
   部署前原始文件已备份
   `/root/gwrt-backups/20261113-tv-adblock/dnsmasq.conf.pre-block`。
4. **验证逻辑修正**：busybox nslookup 对空应答也可能 rc=0，
   CLI/LuCI 的拦截判定改为检查应答 Address 内容（非 127.0.0.1 行为空）。

### 7.2 生效验证（2026-11-13 14:09）

- `/etc/dnsmasq.conf` 标记块 38–278 行，`grep -c '^address=/'` = 218
- 七个广告域（小米 api.ad.xiaomi.com / sdkconfig.ad.xiaomi.com、
  长虹 ads.huan.tv / ad.hpplay.cn、TCL ads.api.my7v.com、
  创维 active.tc.skysrt.com、GITV t7z.cupid.ptqy.gitv.tv）
  经 127.0.0.1 nslookup 应答均无真实 Address = 已拦截
- 正常 DNS：www.baidu.com / www.qq.com 均正常解析（A+AAAA）
- dnsmasq 重启正常（PID 26938，53 端口监听），logread 显示
  "using 217 more local addresses" 规则加载成功
- **daed PID 10929 / oafd PID 3579 未变**，与部署前基线一致
- LuCI：rpcd 已重启 + 清 /tmp/luci-indexcache*，controller/model
  lua loadfile 通过，`tvadblock` 已注册进 indexcache；
  未登录 curl 返回 403 登录页壳（非 500），等待用户登录实测页面
- gwrt 主题 menu-gwrt.js 走 `ui.menu.load()` 动态菜单（读 indexcache），
  非静态列表，新菜单项（网络 → 电视广告拦截）会自动出现
- CLI status：mode core / 218 domains / custom 0+0 / 两测试域已拦截

### 7.3 回滚

`/root/gwrt-backups/20261113-tv-adblock/rollback.sh` 已更新：先 awk 剥
`/etc/dnsmasq.conf` 标记块 → 恢复 dhcp.conf.pre → 重启 dnsmasq →
disable 并删除全部服务/页面/规则文件 → 清 indexcache + rpcd 重启。
备份含 dhcp.conf.pre / dhcp.conf.135246 / dnsmasq.conf.pre-block。

## 8. v2：规则库架构（国内通用广告并入, 纯文本库 + 分类开关）

用户要求把 360/百度/腾讯 等国内广告一并收集，做成 txt 库（明确不要
数据库/SQLite），界面支持开关，升级只需换库文件，保留自定义。

### 8.1 库构建（build_cn_library.py）

- 分类结构：`[tv]` 218（原核心档原样保留）+ `[tv-ext]` 115（原激进档）+
  `[cn]` 158（新增国内综合）= 491 域名，跨分类零重复
- cn 来源：anti-AD 20261111073634（10 万条 dnsmasq 格式）按品牌白名单
  标签抽取（baidu: hm/hmma/pos/cpro/eclick/mobads 等 17 标签；
  腾讯: gdt.qq.com/ugdtimg/gdtimg 整域 + ad/beacon/bsrv/btrace 等 24 标签；
  360: ad/stat/commercial 标签; 字节: toutiao/snssdk/pangolin/pglstatp;
  快手 e.kuaishou.com/cn + promotion-partner; 网易 g/analytics.163.com +
  adnet; 新浪 ad/adbox/beacon/sax*; 微博 uve.* 广告子域;
  华为 logbak/logservice.hicloud + adx/events-drcn.op.dbankcloud.cn;
  OPPO ads.oppomobile.com + adsfs; vivo ad*/adx* 全套; 小米手机
  ad.xiaomi.com/tracking.miui.com; 酷狗/京东联盟/mediav/tanx/domob/
  admaster/miaozhen/adsame/allyes/dianru/madhouse/ipinyou/aduu/casee 等联盟整域）
  + 上轮 general 清单国内部分
- 门禁链：品牌正则（白名单标签）→ 危险域过滤（ROOT_DROP 裸根/内容CDN +
  EXCLUDE_LABEL api/pay/update/push/cdn/chat 等 + PER_DOMAIN_DROP：
  chat1.jd.com 客服、alltbcsp2p.baidu.com 网盘P2P、grs/httpdns/gecko/
  browsercfg 功能域、gw*.push 推送、ad.dev.360.cn 开发者平台）→
  **先验活后去重**（否则 ads.oppomobile.com 死域会连带丢掉其活子域）→
  与 tv/tv-ext 排重 → dnsmasq --test（491 条 OK，tv 单独 218 精确对齐）
- anti-AD 边界对齐：umeng 仅 umeng.co + umengacs（友盟推送不拦）；
  tanx.com 根域不解析，按其子域清单收录；is/gecko/ic.snssdk 配置/
  内容域不收；c.gj.qq.com 无 anti-AD 背书剔除

### 8.2 包代码 v2（PKG_VERSION 2.0）

- init v3：`use_library()` 活动库 `/etc/gwrt-tv-adblock/ads-library.txt`
  优先（conffile，可整体替换升级、固件升级保留），缺失自愈自
  `/usr/share` 模板恢复；`gen_rules` busybox awk 按启用分类抽取
  （tolower/去重/畸形行过滤）；总开关 `enabled` + 分类
  `cat_tv`(缺省开, 对齐旧 core)/`cat_tv_ext`/`cat_cn`(缺省关)；
  cleanup_legacy 增删 v2 旧分档 conf 文件
- CLI v2：`status`（库版本/分类计数/开关/实测含 hm.baidu.com 反映 cn）、
  `on|off <tv|tv-ext|cn>`、旧 `core|extended|off` 兼容映射、
  `update [noreload]`（wget → ≥1分类头+≥10域名校验 → dnsmasq --test →
  备份 .bak → 替换）、`migrate`（旧 mode → 分类一次性迁移）
- LuCI v2：总开关 + 电视核心/电视激进/国内综合三开关 + 库信息
  （活动路径/版本/分类条数）+ 库更新地址 + 更新按钮（Button 类
  cbi.lua:1887 存在，write() 调 CLI update noreload，on_after_commit reload）
  + 自定义拦截/放行保留；on/off 循环选择修复（无参 off=总关,
  带参=分类关）
- uci-defaults v2：新装默认 enabled=1/cat_tv=1/其余关 + 旧 mode 迁移

### 8.3 部署 .9.9 与验证（2026-11-13）

- scp 库（/etc + /usr/share 双份）、init、CLI、uci-defaults、model；
  `migrate` 完成 mode=core → enabled=1 + cat_tv=1，mode 已删
- busybox awk 设备端解析分类计数 218/115/158 与主机一致；
  多分类解析 491 一致
- reload 后标记块 218 条（tv on / cn off）；电视域拦截正常，
  hm.baidu.com/pos.baidu.com/g.163.com/www.baidu.com/www.qq.com 放行
  （首查瞬态误报"已拦截"，复测正常——dnsmasq 重启后上游查询竞态，
  与 §7.1 nslookup rc 陷阱同源，判定必须看 Address 内容且避开重启瞬间）
- daed 10929 / oafd 3579 未变；rpcd + indexcache 已清；页面 403 登录壳
  正常；model lua loadfile 通过
- cn 档默认关，用户在 LuCI 一键打开即可（或 CLI `on cn`）

### 8.4 文件变化

- 新增 `files/etc/gwrt-tv-adblock/ads-library.txt`（三分类 491 条）
- 删除 `files/usr/share/gwrt-tv-adblock/tv-ads-core.conf`、
  `tv-ads-extended.conf`（git rm，旧设备上的副本由 init cleanup 清理）
- Makefile：双路径安装库（/etc conffile + /usr/share 模板）+ conffiles 补充
- 数据工作目录 `/tmp/opencode/tv-adblock/`：build_cn_library.py、
  antiad-dnsmasq.conf、cn-final.txt、cn-candidates.txt、liveness.json

## 9. 编译集成（12 个生成器）与 GitHub 同步

用户要求把 tv-adblock 写入本地与 GitHub 编译集成，固件构建继续停止。

### 9.1 生成器接入（按各自风格，12 个文件）

| 风格 | 生成器 | 插入方式 |
|---|---|---|
| add_pkg 独立 section | xingloo-ax3000 / mt7986 / wr632ax / an7581 | `gwrt-tv-adblock` + `luci-app-gwrt-tvadblock` 循环 |
| 扁平 `CONFIG_PACKAGE_*` | cp02 / pzl8 / nezha | `gwrt-mesh-led=y` 后补两行 |
| set_pkg（sed 原地） | cs02 | mesh 循环后新增 3c 循环 |
| 内联去重循环 | cs06 / cs08 | 复用同款 `grep&&continue + sed 删 not-set + 追加` |
| 只减不增 | cs07 | defconfig 前显式追加 |
| CI seed sed 派生 | cs02-standard | seed 未含时补两行 |

-be6500 经 cs06 生成器派生（OUT 传参），自动获得；wr630ax 是 4 行
 stub（exec xingloo），自动获得。
- 依赖核对：主包 `DEPENDS:=+dnsmasq`，各机型用 dnsmasq-full（Makefile
  `PROVIDES:=dnsmasq`）满足；luci-app 依赖 `+luci-compat`，所有 seed
  （ss01-261018-01 / cs02-gwrt2-261021-04 / cs06-261026-01 /
  ci-cs02-gwrt2-261030-01）均已含。`PKGARCH:=all` 不限架构。
- 只改生成器源码：12 个文件 `sh -n` 全通过；**未运行生成器**（不动 build
  树 .config），未触发 `gwrt-build.yml`（该 workflow 仅 workflow_dispatch）。

### 9.2 GitHub 同步（导出副本 → 私有仓 master）

- 本地仓库此前只有 immortalwrt 上游 remote，无私有仓；沿用导出副本
  `/home/godsun/build/gwrt-github-export`（origin=rothdren-lion/gwrt-immortalwrt）。
- 导出副本原本停在 `4e20145b`，远端 master 已到 `48c54a2b`（30+ 提交）。
  直接整文件覆盖会回退远端新改动：an7581（-77 行：WiFi/IPTV/Podman/SSR 等）、
  cs02/cs07（configs/ 路径 + mkdir）、wr632ax（configs/ OUT 路径）。
  处理：`reset --hard FETCH_HEAD` 对齐远端后，这 4 个文件**先恢复远端版，
  再只插入 tv-adblock 块**；其余 8 个生成器本地版=远端版+新增，直接覆盖。
  最终 12 个文件差异全部为纯新增（+2～+8 行，0 删除）。
- 提交 `e740babd`：23 文件 +1523 行（packages 10 + 文档 1 + 生成器 12），
  推送 `48c54a2b..e740babd`，远端回读库版本 r2 一致。
- **教训**：导出副本索引里常有预先暂存的大量无关文件（.config.bak、
  bin-*、.gwrt-logs、旧删除等，约 800 项）；第一次 `git commit -m` 未带
  路径限定，把 820 个文件/86 万行卷进提交，push 被远端拒绝后
  `reset --soft HEAD~1` 撤销。**必须用 `git commit -m MSG -- <paths>`
  路径限定提交**，且推送前核对 `git diff-tree --name-only` 文件数。

## 10. r2：新增 sec（安全软件与更新）与 kill（必拦）

用户补充：360 卫士全家桶、腾讯安全、微软安全、微软更新「做一个开关」；
hao123、2345.cc「直接拉入枪毙」。

### 10.1 规则库 r2（20261113-r2，564 域名）

| 分类 | 条数 | 变化 |
|---|---|---|
| tv | 218 | 不变 |
| tv-ext | 115 | 不变 |
| cn | 148 | 158→148：360 品牌 9 条 + aegis.qq.com 移入 sec，语义归位 |
| sec | 79 | 新增（默认关） |
| kill | 4 | 新增（无开关，随总开关） |

- sec-360（53 条存活）：anti-AD 中 `360.cn/360safe.com/360safe.cn/qhupdate.com/
  mayi360.cn/ads360.cn/360os.com` 根域下全量（卫士/杀毒/手机助手广告 API、
  `cm.dmp.360.cn`、`fenxi.360.cn`、`lianmeng.360.cn`、`down/softdl4`、
  `qhupdate.com` 更新器、`stat.*` 遥测等）。明确纳入 `ad.dev.360.cn`；
  死域 7 条（shake/cpull/gamebox/leak/s.so/sdkrec.tf 等）按存活验证剔除。
- sec-腾讯（4 条）：`guanjia.qq.com`（管家主域，覆盖子域）`pcmgr.qq.com`
  `sec.qq.com` `aegis.qq.com`（原 cn 风控域移入）。均 AliDNS 存活验证。
- sec-微软安全（18 条）：Defender 云 `wdcp/wdcpalt/spynet2/spynetalt`；
  遥测根域 `data.microsoft.com`（覆盖 vortex/settings/events 全部子域）、
  `telemetry.microsoft.com`（覆盖 sqm/watson.telemetry）、
  `watson.microsoft.com`、`diagnostics.support.microsoft.com`、
  `oca.telemetry.microsoft.us`、`umwatsonc.telemetry.microsoft.us`、
  `check.smartscreen.net`、akadns/glbdns 回退目标（cy2/db5/geo/hk2/
  asimov-win/modern.watson/v10-win）。
  **刻意排除**：`crl.microsoft.com`（证书吊销列表）、teredo/win*.ipv6
  （IPv6 隧道）、corp.sts/corpext.msitadfs（企业认证）、
  msftconnecttest.com（NCSI 联网检测，拦了 Windows 会误判无网）。
- sec-微软更新（6 条）：`windowsupdate.com`（根域覆盖 download/ctldl/fe*/
  tlu 全部子域）、`update.microsoft.com`（含 fe2cr/catalog）、
  `delivery.mp.microsoft.com`、`dl.delivery.mp.microsoft.com`、
  `do.dsp.mp.microsoft.com`、`windowsupdate.edgesuite.net`、
  `officecdn.microsoft.com.edgesuite.net`。
- kill（4 条）：`hao123.com` `2345.com` `2345.cc` `2345.cn` —— 用户明确
  「直接枪毙」，做成无开关固定档，总开关开启即始终生成。

### 10.2 代码 v2.1

- init：`gen_rules(lib, cats)` 增加分类参数；apply_mode 传
  `"$(enabled_cats) kill"`，kill 无条件追加；`enabled_cats` 增 sec；
  cat_sec 缺省关（cat_on 的 `*)` 分支天然覆盖）
- CLI：norm_cat 增 sec；status 计数/开关行增 sec/kill；实测增
  `s.360.cn`（sec）与 `hao123.com`（kill）；usage 更新
- LuCI：新增「安全软件与更新档（sec）」开关（描述明确 360/Windows 更新
  会失效）；库信息行增 sec/必拦条数；状态行增 sec；实测增 360/hao123
- uci-defaults / 默认配置：`cat_sec=0`；Makefile 2.0→2.1（描述同步）
- 库头注释更新为 5 分类 + kill 语义

### 10.3 验证

- 本地：`sh -n` init/CLI/uci-defaults 通过，`luac5.1 -p` model 通过；
  awk 模拟默认态 `tv+kill`=222 条（218+4），全开=564；dnsmasq --test OK
- `.9.9` 部署：busybox awk 分类计数 218/115/148/79/4 与主机一致；
  默认态标记块 222 条，`hao123.com`/`2345.com`/`2345.cc` 拦截，
  `s.360.cn` 放行（sec 关）、`api.ad.xiaomi.com` 拦截、`hm.baidu.com`
  放行（cn 关）；正常站点 baidu/qq/microsoft 不受影响
- `on sec`：标记块 301 条（222+79），`s.360.cn`/`windowsupdate.com`/
  `guanjia.qq.com`/`wdcp.microsoft.com` 全部拦截，复测确认（避开
  dnsmasq 重启瞬态）；CLI status 计数/实测全对
- daed PID 10929 / oafd 3579 全程未变；LuCI model loadfile 通过、页面
  403 登录壳正常（rpcd/indexcache 已清）
- 设备状态：`.9.9` 按用户「最关键」定位**保持 cat_sec=1**（新装固件默认
  仍为 0，界面可随时关）；cat_cn 仍 0

### 10.4 文件

- 修改：`files/etc/gwrt-tv-adblock/ads-library.txt`（r2 564 条）、
  init、CLI、uci-defaults、`files/etc/config/gwrt-tv-adblock`、
  LuCI model、Makefile
- 数据：build_cn_library.py 重构为幂等（tv/tv-ext 从当前库读回），
  新增 sec/kill 流水线与 liveness 缓存
- GitHub：`e740babd` 已推送；docs/GWRT-TV-ADBLOCK.md 同步更新

## 6. 环境备注

- 主机 dnsmasq 2.92 可用 `--test`；无 lua 解释器
- 数据工作目录 `/tmp/opencode/tv-adblock/`（merge.py/classify2.py/
  liveness.json/清理前后清单/hosts 版/ad-server-ips.txt/dead-domains.txt）
- 构建树仍禁止 `make`/云端编译

## 11. 误杀审计与白名单失效修复（包 2.2, 2026-11-14）

用户问：「开关会不会被误杀导致 LAN 下无法上网」。做了静态审计 + `.9.9`
五档全开实测。

### 11.1 静态审计（564 条全量）

- 危险关键词扫描（connectivitycheck/captive/msftconnecttest/ntp/pool/
  dnspod/ocsp/crl/pki/dhcp/pppoe/cloudflare 等）：**零命中**
- 裸根域：只有 `windowsupdate.com` 一条（用户有意选择的更新档，可关）
- 其他"疑似"条目复核：`imdns.hpplay.cn`（乐播投屏广告 DNS）、
  `ykad-gateway.youku.com`（优酷广告网关）、`*.akadns.net`（微软遥测
  CNAME 目标）——均非基础设施
- 与路由器自身服务（gwrt/daed/oaf/agent/openwrt）无交集；畸形行 0
- 90 个常用域（百度/QQ/微信/淘宝/支付宝/微博/B站/爱奇艺/GitHub/
  Docker/PyPI/OpenWrt/Steam/NTP/OCSP 等）比对：**只有 4 个命中**，
  且全部是有意拦截（hao123 + 3 个 Windows 更新域）

### 11.2 实证（`.9.9`，五档全开 564 条）

- 路由器自身解析 + HTTP(S) 200 正常
- LAN 客户端（查 `192.168.9.9:53`）：常用域全部正常，hao123/2345/
  api.ad.xiaomi.com/s.360.cn/windowsupdate.com/hm.baidu.com 全拦
- 证书链/OCSP（digicert/pki.goog/sectigo/crl.microsoft.com）、
  时间同步（time.windows.com/cloudflare/pool.ntp.org）、
  联网检测（gstatic/msftconnecttest/captive.apple/detectportal）全部正常
- dnsmasq 监听 `192.168.9.9:53` + `:67`(DHCP)；10 条租约正常；
  上游 `192.168.254.25` 直连正常；无 dnsmasq 报错
- 结论：**不会导致 LAN 无法上网**

### 11.3 发现并修复的真实缺陷：白名单失效

用户担心的场景其实是成立的，但不是"库里的域误杀"，而是**白名单救不回来**：

- 现象：`custom_allow` 加 `hao123.com` 后仍 NXDOMAIN
- dnsmasq 2.92 实测根因（本地 dnsmasq 实例复现）：
  1. `address=/X/` 优先级**高于** `server=/X/` 与 `server=/sub.X/`
     → 早期文档"server 可覆盖更宽 address"是错的，同域/子域都救不回
  2. 裸 `server=/X/`（不带目标）是**本地权威**语义，只查 /etc/hosts 与
     DHCP 租约、**不转发上游** → 用它放行等于继续拦死
- 修复（init v2.2）：
  1. `gen_rules` 增加 `$3=放行清单`，用 `allowed()` 判断域名等于或
     属于某个放行项时**不生成 address 规则**（从源头排除，含裸根与其
     全部子域）
  2. `gen_custom` 放行改写 `server=/d/#`（`#`=按标准上游解析，不写死
     上游 IP，换网络不失效）
- 设备实测：放行 `hao123.com` 与 `www.hao123.com` 均恢复解析；
  放行 `qq.com` 后所有 `*.qq.com` 规则清零；撤销放行后重新拦截
- 注意：跨注册域的条目需单独放行（如放行 `microsoft.com` 不会解除
  `*.akadns.net` / `*.microsoft.us` / `*.edgesuite.net`），这是预期行为

### 11.4 顺带发现的运维风险

`.9.9` 在 2026-11-14 01:36 左右重启过一次，重启后
`/etc/dnsmasq.conf` 被还原为默认 37 行、`enabled` 变 `0`（标记块 0 条）。
手动恢复五档后 564 条正常。根因未定位（可能是固件升级/overlay 重置/
他人操作），**已记入待查**；本包自身不会把自己关掉（uci 默认缺省视为开）。

### 11.5 提交

- 包版本 2.2：init `gen_rules` 放行排除 + `server=/d/#`；
  文档修正 dnsmasq 优先级与裸 server 语义；WORKLOG §11
- 未编固件，未触发 CI

## 12. 规则库可复现性验证（2026-11-14）

用户指出 anti-AD 有 GitHub 仓库。补回构建脚本后做完整复现验证。

### 12.1 下载源修正

- 官网 `anti-ad.net/anti-ad-for-dnsmasq.conf` **限流严重**：实测反复只能拉到
  15752 / 102656 条（822 KB）就断，`curl -C -` 与 `wget -c` 续传均无效
  （服务器不支持 Range）
- GitHub 仓库可用，但**文件名不同**：仓库内是
  `adblock-for-dnsmasq.conf`（`anti-ad-for-dnsmasq.conf` 返回 404）
- 正确地址：
  `https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/adblock-for-dnsmasq.conf`
  → 2.99 MB / 102656 条 / `#VER=20261114074459`，与 `#TOTAL_LINES` 一致
- 脚本改为按序尝试 GitHub → 官网，任一源 ≥5 万条即用

### 12.2 修复三个导致库缩水的 bug

用全量源首跑得到 cn 139 / sec 73 / kill 0 / 合计 545（原 564），逐个定位：

| 现象 | 根因 | 修复 |
|---|---|---|
| kill 4→0 | kill 走了存活验证；`hao123.com`/`2345.*` 在本机网络下公共 DNS 返回 NXDOMAIN（换 `getent` 能解析） | kill 为用户强制项，**不过存活验证** |
| sec 79→73 | sec 用 cn 的 `EXCLUDE_LABEL` 门禁，把 `down.360.cn`/`qstore.inner.api.sj.360.cn`/`u.api.look.360.cn`/`msg.shouji.360.cn`/`update.microsoft.com`/`ad.dev.360.cn` 全滤掉——这些正是要拦的目标 | sec 只做 `MS_NEVER`+`PER_DOMAIN_DROP` 排除，去掉 `ad.dev.360.cn` 的 per-domain 排除 |
| cn 148→139 | ① 5 个 `*.ads.oppomobile.com` 子域在 anti-AD 新版源已删，但实测活（111.206.136.x）；② `cpro.baidustatic.com`/`h.trace.qq.com`/`adstrategy.biz.weibo.com`/`ad.xiaomi.com` 同样已从源删除 | 新增 `EXTRA_CN` 人工保留清单（10 条），不受存活验证影响 |

### 12.3 复现结果

修完重跑：**tv 218 / tv-ext 115 / cn 148 / sec 79 / kill 4 = 564**，与原库
**逐条 diff 零差异**。`dnsmasq --test` OK，跨分类零重复，域名格式合法。

结论：库现在完全可复现——下载全量源 + 跑脚本即可得到当前 564 条。

### 12.4 脚本健壮性

- `load_rules` 用 `errors=replace`，截断下载的半个多字节字符不再崩溃
- 安全闸：源 <5 万条、或 cn/sec 跌幅 >30% 时**拒绝写入**（实测触发时库字节未变）
- `tv`/`tv-ext` 从当前库读回，重跑不打乱电视档
- `.cache/`（anti-AD + 存活缓存）已 gitignore；脚本不进固件
