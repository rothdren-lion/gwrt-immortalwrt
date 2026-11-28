# 2026-11-28 活跃 App 卡片接入 DNS 域名与图标映射

## 目标

首页「活跃 APP」卡片不再只依赖 OAF/bandix 的用户态统计，改为读取 dnsmasq 查询日志，
把真实访问域名映射到应用图标，避免设备离线或 OAF 未记录时卡片空白。

## 数据链

1. dnsmasq 写查询日志到 `/tmp/dnsq.log`（`dhcp.@dnsmasq[0].logqueries=1`，
   `logfacility=/tmp/dnsq.log`），由 `/etc/init.d/gwrt-dns-urls` 在未设置时补写。
2. `gwrt-dns-urls`（ucode）增量解析日志，900 秒滑动窗口，每设备最多 80 个域名，
   输出 `/tmp/gwrt-theme/dns-urls.json`。
3. rpcd 对象 `gwrt-dns`（`/usr/libexec/rpcd/gwrt-dns`）暴露 `urls` 方法，
   ACL 位于 `luci-theme-gwrt` 的 `read.ubus`。
4. 主题 `gwrt.js` 的 `getActiveAppsFromGwrtDns()` 聚合站点并按品牌图标渲染；
   `refreshActiveApps()` 顺序回退：DNS 域名 → bandix `getDnsStats` → OAF URL → OAF 设备列表。

## 关键修正

- **回环查询**：daed 等 DNS 转发方案会让所有客户端查询显示为 `127.0.0.1`。
  旧逻辑直接丢弃导致卡片为空；现改为记入 `local` 桶，仍统计域名但不归属设备。
- **卡片裁切**：渲染后按卡片实际可用高度移除尾部图标并显示 `+N`，
  五个宽度（1440/1280/1024/780/430）实测无裁切。
- **域名映射**：`DNS_APP_RULES` 新增腾讯视频、高德地图、快手、今日头条、抖音、钉钉、
  阿里云、小米、华为、OPPO、vivo、荣耀、NVIDIA、携程、搜狐、夸克、360、迅雷、Zoom；
  `matchDnsApp()` 未命中时按后缀回退到 `oaf-app-map.json` 的 id。
  已识别的域名聚合为品牌（避免 qq.com 与 v.qq.com 混淆），未识别的保留站点名并用 🌐。
- **重复定义**：`gwrt.js` 内 `refreshActiveApps` 存在三份、`renderActiveApps` 两份，
  运行时最后一份生效；修改时必须改最后一处。该重复属历史遗留，尚未清理。

## 验证

- 9.9（192.168.9.9）部署并实测：31 个活跃域名，24 个图标 + `+8` 收纳；
  GitHub/Baidu/QQ/华为/携程/夸克/360/迅雷等品牌图标正常。
- 规则单测：38 个域名断言全部通过（含 mi.com→小米、v.qq.com→腾讯视频、
  qq.com→Tencent/QQ、weixin.qq.com→WeChat）。
- 9.9 备份：`/root/gwrt-backups/20261128-dnstest-theme/`。

## 回滚（9.9 测试环境）

```sh
cp /root/gwrt-backups/20261128-dnstest-theme/gwrt.js /www/luci-static/gwrt/resources/gwrt.js
cp /root/gwrt-backups/20261128-dnstest-theme/cascade.css /www/luci-static/gwrt/css/cascade.css
cp /root/gwrt-backups/20261128-dnstest-theme/luci-theme-gwrt.json /usr/share/rpcd/acl.d/
uci delete dhcp.@dnsmasq[0].logqueries; uci delete dhcp.@dnsmasq[0].logfacility; uci commit dhcp
/etc/init.d/gwrt-dns-urls disable; /etc/init.d/dnsmasq restart; /etc/init.d/rpcd restart
```

## 提交

- `3c728356` feat(theme): active-app card uses dnsmasq query log with brand icons
- `7e1c5d65` fix(theme): keep active-app chips inside the card and count forwarded DNS
- 本轮：DNS_APP_RULES 扩充 + `oaf-app-map.json` 回退 + 品牌聚合（待提交）
