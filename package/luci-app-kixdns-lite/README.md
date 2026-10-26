# luci-app-kixdns-lite

给 `kixdns` 配的**极简 LuCI 页面**——只有「启动 / 停止 / 改监听端口」这三件事，
不上第三方 luci-app 那套统计、劫持、远程拉配置。

## 页面内容

LuCI → **服务 → KixDNS**

| 区块 | 字段 | 数据来源 |
|---|---|---|
| 状态 | 运行中 / 未运行（每 5 秒刷新） | ubus `service list` |
| 状态 | 监听地址 | `pipeline.json` 的 `bind_udp` / `bind_tcp` |
| 设置 | 开机自启 | uci `kixdns.main.enabled` |
| 设置 | 监听端口 | `pipeline.json` 的 `bind_udp` / `bind_tcp` 的端口部分 |
| 按钮 | 保存并应用 / 启动 / 停止 | 写文件 + uci + `/etc/init.d/kixdns` |

**保存并应用**做的事：改写 `/etc/kixdns/pipeline.json`（保留 `bind_*` 的主机地址，只换端口）
→ `uci commit kixdns` → `/etc/init.d/kixdns restart`。
端口属于监听器参数，**改了必须重启**，kixdns 自己的热加载救不了这一项。

## 文件

```
package/luci-app-kixdns-lite/
├── Makefile                                   luci.mk 打包
├── htdocs/luci-static/resources/view/kixdns-lite/main.js
├── root/usr/share/luci/menu.d/luci-app-kixdns-lite.json      菜单：服务 → KixDNS
├── root/usr/share/rpcd/acl.d/luci-app-kixdns-lite.json       权限
├── po/zh_Hans/kixdns-lite.po                               中文（21 条，与 JS 的 _() 一一对应）
└── README.md
```

> 翻译域是 `kixdns-lite`（= `view/` 下的目录名），`.lmo` 落在
> `/usr/lib/lua/luci/i18n/kixdns-lite.zh-cn.lmo`。**第三方 `luci-app-kixdns` 用的域是
> `kixdns`，两者不会互相覆盖**，但没必要同时装。

## 构建

`.config` 已置好：

```
CONFIG_PACKAGE_luci-app-kixdns-lite=y
CONFIG_PACKAGE_luci-i18n-kixdns-lite-zh-cn=y
```

```sh
make package/luci-app-kixdns-lite/compile
# → bin/packages/<arch>/base/luci-app-kixdns-lite-1.0.0-r1.apk        (3.4 KB)
# → bin/packages/<arch>/base/luci-i18n-kixdns-lite-zh-cn-0.apk        (1.6 KB)
```

依赖只有 `luci-base` + `kixdns`，不引入 rpcd 插件、不引入 drill/curl 之类。

## 权限范围（acl）

- **read**：`service list`、读 `/etc/kixdns/pipeline.json`、读 `/etc/config/kixdns`、uci `kixdns`
- **write**：写 `/etc/kixdns/pipeline.json`、`exec /etc/init.d/kixdns`、uci `kixdns`

没有给任意路径的 `read`/`write`/`exec`，也没有 `cgi-io` 上传权限。

## 已知边界

- 只暴露了「端口 + 自启 + 启停」。上游/分流域名等高级配置仍然手改 `pipeline.json`
  （或用上游自带的 `tools/config_editor.html` 网页编辑器生成后 scp 覆盖）。
- `bind_udp` / `bind_tcp` 的**主机部分不会被修改**（`0.0.0.0`、`192.168.1.1`、`[::]` 都保留）。
- 配置文件缺失或不是合法 JSON 时，端口输入框禁用并给出警告，不会写入半截文件。
- 保存会用 2 空格缩进重写整个 JSON（字段顺序保留）。kixdns 的配置是严格 JSON，没有注释可丢。
