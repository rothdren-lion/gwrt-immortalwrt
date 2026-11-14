#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# GWRT 广告规则库构建脚本 (可复现)
#
# 产出: package/gwrt-tv-adblock/files/etc/gwrt-tv-adblock/ads-library.txt
# 用法: python3 build-ads-library.py [--refresh-antiad]
#
# 设计: 库文件是唯一权威产物(纯文本, 无数据库)。本脚本保证可重跑、幂等:
#   - 已有分类(tv/tv-ext)从当前库读回, 不会被覆盖或打乱
#   - cn / sec / kill 从来源清单 + 白名单标签重新推导
#   - 存活验证结果缓存到 .cache/liveness.json, 避免每次全量 dig
#
# 依赖: python3, dig (bind-utils)。无第三方库。
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PKG = Path(__file__).resolve().parent
LIB = PKG / "files/etc/gwrt-tv-adblock/ads-library.txt"
CACHE = PKG / ".cache"
LIVE_JSON = CACHE / "liveness.json"
ANTIAD = CACHE / "antiad-dnsmasq.conf"
# 优先 GitHub raw: 官网 anti-ad.net 限流严重(实测只能拉到 1.5万/10万条就断)
# 注意 GitHub 仓库里的文件名是 adblock-for-dnsmasq.conf
ANTIAD_URLS = [
    "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/adblock-for-dnsmasq.conf",
    "https://anti-ad.net/anti-ad-for-dnsmasq.conf",
]

# ---------------------------------------------------------------- 工具

def load_rules(path):
    """读 dnsmasq 规则文件(address=/d/ 或裸域名行), 返回域名列表。

    容错: 下载被截断时尾部可能有半个多字节字符, 用 errors=replace 跳过
    而不是整体失败。
    """
    out = []
    if not Path(path).exists():
        return out
    text = Path(path).read_text(errors="replace")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("address=/") and line.endswith("/"):
            d = line[9:-1]
        elif re.match(r"^[a-z0-9._-]+$", line):
            d = line
        else:
            continue
        # 只接受合法域名(尾部截断的半行会被拒)
        if re.match(r"^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$", d) and "." in d:
            out.append(d)
    return out


def load_library_cats(path):
    """读库文件, 返回 {分类: [域名]}。"""
    cats, cur = {}, None
    if not Path(path).exists():
        return cats
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]
            cats.setdefault(cur, [])
        elif s and not s.startswith("#") and cur:
            cats[cur].append(s.lower())
    return cats


def alive(domain, cache):
    """AliDNS 存活验证, 带缓存。"""
    if domain in cache:
        return cache[domain]
    try:
        r = subprocess.run(
            ["dig", "@223.5.5.5", "+time=2", "+tries=1", "+noall",
             "+comments", "+answer", domain],
            capture_output=True, text=True, timeout=8)
        ok = "status: NXDOMAIN" not in r.stdout
    except Exception:
        ok = True  # 查询异常时不误删
    cache[domain] = ok
    return ok


def check_many(domains, cache, workers=40):
    todo = [d for d in domains if d not in cache]
    if todo:
        print(f"  存活验证: {len(todo)} 个新查询 / {len(domains)-len(todo)} 个复用缓存")
        with ThreadPoolExecutor(max_workers=workers) as ex:
            list(ex.map(lambda d: alive(d, cache), todo))
    return [d for d in domains if cache.get(d, True)]


def dedupe_suffix(domains):
    """父域覆盖子域时丢弃子域。"""
    pool = set(domains)
    out = []
    for d in sorted(pool):
        parts = d.split(".")
        covered = False
        for i in range(1, len(parts) - 1):
            if ".".join(parts[i:]) in pool:
                covered = True
                break
        if not covered:
            out.append(d)
    return out


def covered_by(d, parents):
    """d 是否等于某 parent 或为其子域。"""
    for p in parents:
        if d == p or d.endswith("." + p):
            return True
    return False


# ------------------------------------------------- 危险域 / 白名单标签门禁

ROOT_DROP = {
    # 裸根/内容 CDN/功能域: 恰好作为候选本身时才丢弃(子域不受影响)
    "baidu.com", "qq.com", "163.com", "127.net", "sina.com.cn", "weibo.com",
    "weibo.cn", "taobao.com", "tmall.com", "alipay.com", "jd.com",
    "360buyimg.com", "360.cn", "360safe.com", "so.com", "snssdk.com",
    "toutiao.com", "kuaishou.com", "douyin.com", "yximgs.com", "zjcdn.com",
    "xiaomi.com", "mi.com", "miui.com", "uc.cn", "umeng.com", "umengcloud.com",
    "bdstatic.com", "bdimg.com", "qhres.com", "gtimg.com", "idqqimg.com",
    "qpic.cn", "alicdn.com", "hdslb.com", "netease.im", "nos.netease.com",
    "music.126.net", "bilibili.com", "zhihu.com", "kugou.com", "kuwo.cn",
    "vivo.com", "vivo.com.cn", "oppomobile.com", "hicloud.com",
    "dbankcloud.cn", "dbankcloud.com", "baidustatic.com", "kuaishouzt.com",
}

EXCLUDE_LABEL = re.compile(
    r"^(www|mail|api|api\d?|apicdn|api-access|passport|account|auth|sso|login|"
    r"id|pay|captcha|verify|update|upgrade|ota|down|download|push|msg|xmpush|"
    r"connectivity|captive|time|ntp|dns|httpdns|cd|cdn|static|img|image|"
    r"imgcache|pic|video|vod|css|js|res|resource|dl|chat|im|live|search|maps|"
    r"map|sv|browsercfg|grs|hwpub|gecko|ic|p2p|sp2p|open)\b")

# 明确排除的功能域/非广告端点
PER_DOMAIN_DROP = {
    "chat1.jd.com",                  # 京东客服
    "alltbcsp2p.baidu.com",          # 百度网盘 P2P
    "entry.baidu.com",
    "browsercfg-drcn.cloud.dbankcloud.cn",
    "grs.dbankcloud.com", "grs.hicloud.com",
    "hwpub-s01-drcn.cloud.dbankcloud.cn", "dt.dbankcloud.ru",
    "gw5.push.mcp.weibo.cn", "gw6.push.mcp.weibo.cn",
    "appcfg.v.qq.com", "commdata.v.qq.com",   # 腾讯视频遥测(非广告)
}
# video 标签下但确实是广告服务器的豁免
PER_DOMAIN_KEEP = {"adss.video.qq.com"}

# 微软侧刻意不拦(功能域, 拦了会出问题)
MS_NEVER = {
    "crl.microsoft.com",             # 证书吊销列表
    "teredo.ipv6.microsoft.com", "win10.ipv6.microsoft.com",
    "win8.ipv6.microsoft.com", "win1710.ipv6.microsoft.com",
    "corp.sts.microsoft.com", "corpext.msitadfs.glbdns2.microsoft.com",
    "www.msftconnecttest.com", "msftconnecttest.com",  # NCSI 联网检测
}


def excluded(d):
    if d in MS_NEVER:
        return "ms-functional"
    if d in PER_DOMAIN_DROP:
        return "per-domain"
    if d in PER_DOMAIN_KEEP:
        return None
    if d in ROOT_DROP:
        return "root"
    labels = d.split(".")
    firsts = labels[:-2] if len(labels) > 2 else labels[:-1]
    for lb in firsts:
        if EXCLUDE_LABEL.match(lb):
            return f"label:{lb}"
    return None


# ------------------------------------------------------------ cn 品牌规则

BRAND = {
    "baidu": [
        r"^(hm|hmma|pos|cpro|eclick|mobads|mobads-logs|adscdn|dc|dclick|"
        r"sclick|cmpos|cbjs|fclog|feed-image|dxp|als|bgg|fxgate)\.baidu\.com$",
        r"^cpro\.baidustatic\.com$",
    ],
    "tencent-gdt": [
        r"(^|\.)gdt\.qq\.com$", r"(^|\.)ugdtimg\.com$", r"(^|\.)gdtimg\.com$",
        r"^(ad|addata|adfilter|adsfile|adslvfile|adstextview|beacon|beaconcdn|"
        r"bsrv|btrace|adping|adrdir|adsclick|adsgroup|adshmct|adshmmsg|"
        r"adslvseed|adsqqclick|adsrich|adss|adpm|h\.trace|file\.daihuo|"
        r"adpick)\.qq\.com$",
        r"^adpm\.app\.qq\.com$", r"^adss\.video\.qq\.com$",
    ],
    "bytedance": [
        r"^(ad|dm|dm-hl|dsp|d|adshare|log)\.toutiao\.com$",
        r"^(2345api|2345apicode|actlog|dspimg|dsp|ad|log)\.dftoutiao\.com$",
        r"^(is|log|mon|applog|analytics|extlog|abtest-ch|logbag|"
        r"pangolin[a-z-]*)\.snssdk\.com$",
        r"^ctobsnssdk\.com$",
        r"(^|\.)pangolin-sdk-toutiao(-b)?\d?\.com$",
        r"(^|\.)pangolin-dsp-toutiao(-b)?\.com$",
        r"(^|\.)pglstatp-toutiao\d?\.com$",
        r"^analytics\.oceanengine\.com$",
        r"^ads\.weilitoutiao\.net$",
        r"^ali-ad\.a\.yximgs\.com$",
    ],
    "kuaishou": [
        r"^(e|promotion-partner)\.kuaishou\.(com|cn)$",
        r"^open\.kuaishouzt\.com$",
    ],
    "netease": [
        r"^(g|analytics|beacon|apm|deload)\.163\.com$",
        r"(^|\.)adnet\.163\.com$",
        r"(^|\.)(ads|adimg|adx)\.[a-z0-9.]*\.126\.net$",
    ],
    "sina-weibo": [
        r"^(ad4?|adbox|ads|beacon|saxn?s?|alitf|aldsd?)\.sina\.com\.cn$",
        r"(^|\.)(adimg|bootpreload|datacollection|strategy|alitf|ald)"
        r"\.uve\.weibo\.com$",
        r"^adstrategy\.biz\.weibo\.com$",
    ],
    "umeng": [
        r"(^|\.)umeng\.co$",
        r"^umeng(jm)?acs\.m\.taobao\.com$",
    ],
    "ad-nets": [
        r"(^|\.)mediav\.com$", r"(^|\.)tanx\.com$",
        r"(^|\.)domob\.(cn|org)$", r"(^|\.)admaster\.com\.cn$",
        r"(^|\.)miaozhen\.com$", r"(^|\.)adsame\.com$",
        r"(^|\.)allyes\.com$", r"(^|\.)dianru\.com$",
        r"(^|\.)madhouse\.cn$", r"(^|\.)ipinyou\.com$",
        r"(^|\.)aduu\.cn$", r"(^|\.)casee\.cn$",
    ],
    "oppo-vivo-hw": [
        r"(^|\.)ads\.oppomobile\.com$",
        r"^(adsfs|adsfs-in)\.oppomobile\.com$",
        r"^(ad|adh5|adnet|adnetstatic|adsstatic|ad-market|ads-marketing|"
        r"adlog|adreq|adsdk|adxlog|adxstatic|brandadsstatic|adxlog-adnet)"
        r"\.vivo\.com\.cn$",
        r"^(adx-drcn|events-drcn)\.op\.dbankcloud\.cn$",
        r"^(logbak|logservice|data)\.hicloud\.com$",
    ],
    "xiaomi-phone": [
        r"^(ad|tracking)\.(xiaomi\.com|miui\.com)$",
        r"^data\.mistat\.xiaomi\.com$",
    ],
    "kugou-kuwo": [
        r"(^|\.)(ads|adserviceretry|adsfileretry|collect)\.service\.kugou\.com$",
        r"(^|\.)adsfile\.[a-z0-9.-]*kugou\.com$",
        r"(^|\.)collect\.kugou\.com$",
        r"(^|\.)ads\.[a-z0-9.-]*kuwo\.cn$",
    ],
    "jd-ads": [
        r"^(addata|ccc-x)\.jd\.com$",
        r"(^|\.)ads\.[a-z0-9.-]*jd\.com$",
    ],
}

# 曾收录但 anti-AD 新版源已删、实测仍活跃的域(人工确认保留, 重建时不丢)
EXTRA_CN = [
    # OPPO 广告投放(111.206.136.x, 父域 ads.oppomobile.com 已 NXDOMAIN)
    "adx.ads.oppomobile.com", "bdapi.ads.oppomobile.com",
    "ck.ads.oppomobile.com", "data.ads.oppomobile.com",
    "sms.ads.oppomobile.com",
    # 百度联盟广告素材
    "cpro.baidustatic.com",
    # 腾讯广点通链路追踪
    "h.trace.qq.com",
    # 微博广告策略
    "adstrategy.biz.weibo.com",
    # 小米手机广告(当前 NXDOMAIN, 保留以防复活)
    "ad.xiaomi.com",
]

# ------------------------------------------------------- sec 白名单清单

# 360 全家桶: 按注册域全量收(anti-AD curated)
SEC360_ROOTS = ("360.cn", "360safe.com", "360safe.cn", "qhupdate.com",
                "mayi360.cn", "ads360.cn", "360os.com")

SEC_TENCENT = ["guanjia.qq.com", "pcmgr.qq.com", "sec.qq.com", "aegis.qq.com"]

# 微软 Defender 云 + 遥测(根域收敛 + akadns/glbdns 回退目标)
SEC_MS_SEC = [
    "wdcp.microsoft.com", "wdcpalt.microsoft.com",
    "spynet2.microsoft.com", "spynetalt.microsoft.com",
    "check.smartscreen.net",
    "data.microsoft.com", "telemetry.microsoft.com", "watson.microsoft.com",
    "diagnostics.support.microsoft.com",
    "oca.telemetry.microsoft.us", "umwatsonc.telemetry.microsoft.us",
    "asimov-win.settings.data.microsoft.com.akadns.net",
    "cy2.vortex.data.microsoft.com.akadns.net",
    "db5.settings.data.microsoft.com.akadns.net",
    "db5.vortex.data.microsoft.com.akadns.net",
    "geo.settings.data.microsoft.com.akadns.net",
    "geo.vortex.data.microsoft.com.akadns.net",
    "hk2.settings.data.microsoft.com.akadns.net",
    "modern.watson.data.microsoft.com.akadns.net",
    "v10-win.vortex.data.microsoft.com.akadns.net",
]

# Windows / Office 更新通道(不含 crl.microsoft.com)
SEC_MS_UPD = [
    "windowsupdate.com", "update.microsoft.com",
    "delivery.mp.microsoft.com", "dl.delivery.mp.microsoft.com",
    "do.dsp.mp.microsoft.com", "windowsupdate.edgesuite.net",
    "officecdn.microsoft.com.edgesuite.net",
]

# kill: 无开关必拦(hao123 / 2345 导航劫持全家桶)
KILL = ["hao123.com", "2345.com", "2345.cc", "2345.cn"]


# ------------------------------------------------------------------ 主流程

def fetch_antiad():
    """确保 anti-AD 缓存完整可用。

    安全闸: anti-AD 完整清单约 10 万条, 官网限流严重常被截断。来源不足时
    绝不能覆盖现有库(cn/sec 会大量缩水), 这里直接拒绝继续。
    """
    def count(p):
        return sum(1 for line in p.read_text(errors="replace").splitlines()
                   if line.startswith("address=/")) if p.exists() else 0

    if ANTIAD.exists():
        n = count(ANTIAD)
        if n >= 50000:
            print(f"anti-AD 缓存可用: {n} 条")
            return ANTIAD
        print(f"anti-AD 缓存不完整({n} 条), 重新下载")
        ANTIAD.unlink()

    CACHE.mkdir(parents=True, exist_ok=True)
    for url in ANTIAD_URLS:
        print(f"下载 anti-AD: {url}")
        subprocess.run(["curl", "-sSL", "--retry", "3", "-m", "600",
                        "-o", str(ANTIAD), url], check=False)
        n = count(ANTIAD)
        if n >= 50000:
            print(f"  成功: {n} 条")
            return ANTIAD
        print(f"  不完整({n} 条), 换下一个源")
        ANTIAD.unlink(missing_ok=True)

    sys.exit(
        "所有源都不完整(需要 >=50000 条), 拒绝覆盖现有库。\n"
        f"手动下载后重跑:\n"
        f"  curl -L -o {ANTIAD} {ANTIAD_URLS[0]}")


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    if not LIB.exists():
        sys.exit(f"库文件不存在: {LIB}\n请先 checkout 一个已有版本作为基线")

    cur = load_library_cats(LIB)
    tv, tvext = cur.get("tv", []), cur.get("tv-ext", [])
    if not tv:
        sys.exit("库文件缺少 [tv] 分类, 拒绝重建(避免把电视档丢掉)")

    cache = json.loads(LIVE_JSON.read_text()) if LIVE_JSON.exists() else {}

    # ---- cn: 品牌白名单标签抽取
    antiad = load_rules(fetch_antiad())
    print(f"来源: anti-AD {len(antiad)} 条, 当前库 tv={len(tv)} tv-ext={len(tvext)}")

    cand = set()
    for brand, pats in BRAND.items():
        rx = [re.compile(p) for p in pats]
        n = 0
        for d in antiad:
            if any(r.search(d) for r in rx):
                if not excluded(d):
                    cand.add(d)
                    n += 1
        print(f"  {brand}: {n}")

    cn = check_many(sorted(cand), cache)
    # 人工确认保留的额外域(不受存活验证影响: 当前 NXDOMAIN 不代表永久废弃)
    cn += [d for d in EXTRA_CN if d not in cn]
    # 先验活再后缀去重: 父域死了不能连带丢掉活着的子域
    cn = dedupe_suffix(cn)
    others = set(tv) | set(tvext)
    cn = [d for d in cn if d not in others]
    print(f"  cn 最终: {len(cn)}")

    # 安全闸: cn 是最大分类, 数量骤降说明来源不全或门禁写错
    prev_cn = len(cur.get("cn", []))
    if prev_cn and len(cn) < prev_cn * 0.7:
        sys.exit(f"cn 从 {prev_cn} 降到 {len(cn)} (跌幅 >30%), 拒绝覆盖。"
                 f"\n检查 anti-AD 来源完整性或 BRAND/excluded 规则。")

    # ---- sec
    # 注意: sec 是人工白名单清单(360 全家桶/腾讯管家/微软 Defender 与更新),
    # 不能用 cn 的通用 EXCLUDE_LABEL 门禁——360 的 down./api./update. 等
    # 正是要拦的域, 微软 update.microsoft.com 也是目标而非功能域。
    # 只做 MS_NEVER 与 PER_DOMAIN_DROP 级排除。
    def sec_ok(d):
        if d in MS_NEVER:
            return False
        if d in PER_DOMAIN_DROP:
            return False
        return True

    sec = [d for d in antiad if covered_by(d, SEC360_ROOTS) and sec_ok(d)]
    sec += [d for d in SEC_TENCENT + SEC_MS_SEC + SEC_MS_UPD if sec_ok(d)]
    sec = check_many(sorted(set(sec)), cache)
    sec = dedupe_suffix(sec)
    sec = [d for d in sec if d not in others and d not in set(cn)]
    print(f"  sec 最终: {len(sec)}")

    prev_sec = len(cur.get("sec", []))
    if prev_sec and len(sec) < prev_sec * 0.7:
        sys.exit(f"sec 从 {prev_sec} 降到 {len(sec)}, 拒绝覆盖。")

    # ---- kill
    # 先验活再后缀去重（见主流程注释）。
    # kill 是用户强制指定的必拦项, 不受存活验证影响——域名 NXDOMAIN 也照样
    # 拦(可能是当前网络下不解析, 换环境就活; 且拦一条 NXDOMAIN 无副作用)。
    kill = list(KILL)
    taken = others | set(cn) | set(sec)
    kill = [d for d in kill if d not in taken]
    print(f"  kill 最终: {len(kill)}")

    LIVE_JSON.write_text(json.dumps(cache))

    # ---- 组装
    def block(name, domains, comment):
        return [f"[{name}]", comment] + sorted(domains)

    hdr = f'''# =====================================================================
# GWRT 国内广告域名库 (纯文本规则库 — 无数据库/SQLite)
# 版本: 20261113-r2    分类条目: tv={len(tv)} tv-ext={len(tvext)} cn={len(cn)} sec={len(sec)} kill={len(kill)}
# 生成: package/gwrt-tv-adblock/build-ads-library.py (可重跑, tv/tv-ext 保留原样)
# 来源: 六源合并(电视档) + anti-AD 品牌白名单标签抽取 + 人工验证清单
#       阿里DNS存活验证剔除死域; 覆盖 360/百度/腾讯/字节/快手/网易/新浪微博/
#       友盟/华为/OPPO/vivo/小米手机/酷狗/京东联盟/主流广告联盟
# ---------------------------------------------------------------------
# 用途: /etc/init.d/gwrt-tv-adblock 按 LuCI 启用的分类生成 dnsmasq
#       address=/domain/ 规则 (NXDOMAIN 拦截, A/AAAA 双栈)
# 格式: [分类名] 行切换分类; 域名每行一个(小写); # 开头为注释; 空行忽略;
#       首个 [分类] 之前的行被忽略
# 分类: tv     电视核心(开机广告/视频App广告SDK, 无副作用, 默认开)
#       tv-ext 电视激进(商店/升级/语音/投屏, 有副作用, 默认关)
#       cn     国内综合(百度/腾讯/字节等Web与APP广告、统计, 默认关)
#       sec    安全软件与更新(360全家桶/腾讯管家/微软Defender与遥测/
#              WindowsUpdate, 默认关, 有副作用: 360与Windows更新会失效)
#       kill   必拦(无分类开关): hao123/2345 导航劫持全家桶, 总开关开即生效
# ---------------------------------------------------------------------
# 升级: LuCI 页面"更新规则库"按钮, 或 /usr/libexec/gwrt-tv-adblock update
#       (需先在 LuCI 填库地址), 或直接替换本文件后执行
#       /etc/init.d/gwrt-tv-adblock reload
# 注意: 不要往里加裸根域(qq.com/baidu.com 等)或搜/pay/api 域, 会误伤;
#       误拦用 LuCI 自定义放行(custom_allow)救回, 裸根和子域都有效
# =====================================================================
'''
    body = []
    body += block("tv", tv, "# 各品牌开机广告域 + 视频App广告SDK + 乐播广告子域 + 广告追踪")
    body += block("tv-ext", tvext, "# 应用商店/系统升级/语音助手/投屏服务/GITV认证/P2P节点(有副作用)")
    body += block("cn", cn, "# 国内综合广告: 百度/腾讯/字节等广告SDK/统计/广告联盟/手机厂商广告")
    body += block("sec", sec, "# 安全软件与更新: 360全家桶/腾讯管家风控/微软Defender云与遥测/WindowsUpdate(有副作用)")
    body += block("kill", kill, "# 必拦(无分类开关): hao123/2345 导航劫持全家桶")

    LIB.write_text(hdr + "\n".join(body) + "\n")
    total = len(tv) + len(tvext) + len(cn) + len(sec) + len(kill)
    print(f"\n写出: {LIB}  合计 {total} 域名")
    print("校验: dnsmasq --test 请另跑 (见 WORKLOG)")


if __name__ == "__main__":
    main()