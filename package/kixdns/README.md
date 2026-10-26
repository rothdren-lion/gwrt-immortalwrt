# kixdns（本树内预编译包）

把上游 [olicesx/kixdns](https://github.com/olicesx/kixdns) 的 **GitHub Release 预编译静态二进制**
落成 OpenWrt/apk 包。不引入 Rust 工具链，出包耗时秒级。

| | |
|---|---|
| 上游版本 | v0.2.0（二进制内 `--version` 打印 `kixdns 0.1.0`，上游 Cargo.toml 没跟着 bump） |
| 包版本 | `kixdns-0.2.0-r1.apk` |
| 支持架构 | `aarch64_cortex-a53`（asset `kixdns-linux-arm64-musl`）、`x86_64`（asset `kixdns-linux-x86_64-musl`） |
| 二进制 | 静态链接 musl，无任何动态依赖，aarch64 7.8 MB / x86_64 9.9 MB（解压后） |

## 文件

```
package/kixdns/
├── Makefile            在树内出包（当前 target = qualcommax/ipq60xx → aarch64_cortex-a53）
├── mkapk.sh            不切 target 单独出别的架构的 .apk（默认 x86_64）
├── files/
│   ├── kixdns.init     procd 启动脚本 → /etc/init.d/kixdns
│   ├── kixdns.config   uci → /etc/config/kixdns
│   └── pipeline.json   默认配置 → /etc/kixdns/pipeline.json（conffile）
└── README.md
```

## 默认行为

- 监听 **`0.0.0.0:5300`**（UDP + TCP），默认上游 **`223.5.5.5:53`**
- `uci set kixdns.main.enabled=0 && uci commit kixdns` 可整体关掉
- 开启内存缓存 + 后台刷新 + serve-stale
- 装上即启用（`CONFIG_PACKAGE_kixdns=y`，与 `sing-box` / `gwrt-agent` 一致）

**端口为什么不是 5353 / 53**：本树已经启用了 `avahi-dbus-daemon`（占 5353/mDNS）和
`dnsmasq-full`（占 53），所以默认值避开这两个，装上不会跟现有服务打架。

## 出包

### 1）当前 target（aarch64_cortex-a53）

```sh
# 首次需要把 asset 放进 dl/（见下方“已知坑”）
cp kixdns-linux-arm64-musl dl/          # sha256 37f1bba4…484ad5
make package/kixdns/compile
# → bin/packages/aarch64_cortex-a53/base/kixdns-0.2.0-r1.apk
```

`.config` 里 `CONFIG_PACKAGE_kixdns=y` 已置好；改 `=m` 可以只出包、不打进固件（省 3.8 MB 镜像体积）。

### 2）别的架构（x86_64 等，不切 .config、不重建工具链）

```sh
./package/kixdns/mkapk.sh                 # 默认 x86_64
./package/kixdns/mkapk.sh x86_64 aarch64_cortex-a53
./package/kixdns/mkapk.sh --no-index x86_64
# → bin/packages/x86_64/base/kixdns-0.2.0-r1.apk  + packages.adb + index.json
```

脚本会自己下载 asset、校验 sha256、组包、**解包自检二进制架构**、重建同目录索引。
元数据与树内出的包逐字段一致（仅 `arch` / `installed-size` / 内容 hash 不同）。

如果目标机有独立的 x86 构建树，也可以直接把 `package/kixdns/` 整个拷过去 `make package/kixdns/compile`。

## 装到路由器

```sh
# 方式 A：本地文件
apk add --allow-untrusted /tmp/kixdns-0.2.0-r1.apk     # 非本机出的包要 --allow-untrusted

# 方式 B：把 bin/packages/<arch>/base 当仓库
#   路由器上： apk add kixdns （已配置对应 repositories 的前提下）

# 装完验证
kixdns --version
netstat -ulnp | grep 5300
dig @127.0.0.1 -p 5300 www.baidu.com
```

维护脚本里带了 `default_postinst` / `default_prerm`，所以 `apk add` 会自动
`enable` 并启动服务，`apk del` 会自动停止并取消自启。

## 接入现有 DNS 链路

两种用法，按需要二选一：

**① 当旁路解析器（默认，不改动现有 dnsmasq）**

```sh
dig @<router-ip> -p 5300 example.com
```

**② 让 dnsmasq 把查询交给 kixdns 分流**

```sh
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5300'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

**③ 让 kixdns 直接管 53**

改 `files/pipeline.json` 的 `bind_udp` / `bind_tcp` 为 `0.0.0.0:53`，
再 `uci set dhcp.@dnsmasq[0].port=0`（或停掉 dnsmasq 的 DNS 部分）。改完 `restart kixdns`。

> 配置改动由 kixdns 自己的 file watcher 热加载，不必重启进程；
> uci 改动（enabled/debug）由 `procd_add_reload_trigger` 触发 reload。

## LuCI 前端

上游**没有**官方 LuCI，只有自带的 `tools/config_editor.html`（独立 Vue 网页编辑器，依赖公网 CDN）。

**本树已落地极简版：`package/luci-app-kixdns-lite`**（服务 → KixDNS）——
只有 启动/停止/改监听端口/开机自启 四项，带中文翻译，依赖仅 `luci-base + kixdns`，
与本包零文件冲突。详见 `../luci-app-kixdns-lite/README.md`。

第三方完整版（未采用，仅备忘）：

- `JohnsonRan/luci-app-kixdns` —— 功能最全（服务控制 + nft 53 劫持 + 管线编辑 + 日志 + 24h 统计 + 中文）
  **但会和本包抢同一批文件**，且自带的 `pipeline.json` 默认绑 5353（本树 avahi 占用），需替换本包后再调端口。
- `Accelerator6666/luci-app-kixdns-ui` —— 只碰 `pipeline.json` / init / 二进制，**与本包不冲突**；
  依赖 `drill`（`feeds/packages/libs/ldns`，开 `CONFIG_PACKAGE_drill=y` 即可）；**无中文翻译**；
  可视化编辑器要在路由器侧拉 GitHub raw，网络不通则该页不可用（Raw JSON 页不受影响）。

## 已知坑

1. **GitHub 直连可能超时**：构建树的 `download.pl` 用 `--connect-timeout 5`，
   从国内连 `github.com` 经常 5 秒握手超时，然后回落到 openwrt/immortalwrt 镜像（那里没有这个文件，必 404）。
   解决办法：手动把 asset 下载到 `dl/`，哈希对得上就直接跳过下载。`mkapk.sh` 用的是 30 秒超时，一般能自己下。
2. **开放解析器风险**：默认绑 `0.0.0.0:5300`。默认防火墙会丢弃 WAN 侧入站，没问题；
   但如果设备上有放行 5300 的规则，它就是一个可被用于放大攻击的开放解析器，注意收敛。
3. **升版本**：改 `PKG_VERSION` / `PKG_RELEASE`，更新 `Makefile` 里两个 `KIXDNS_ASSET_HASH`
   和 `mkapk.sh` 里 `asset_spec()` 的两行（**两处必须同步改**）。
4. **GeoIP / GeoSite**：默认配置没配 `.dat`。实测：`geoip_dat_path` 指向不存在的文件**不会**导致启动失败
   （`src/engine/core.rs` 只在 pipeline 里真用到 geoip matcher 时才去加载），但只要用了 geoip matcher
   就必须自备文件。建议放绝对路径，数据可从 `v2dat` 或上游 `convert-geo-ip` 子命令转换。
