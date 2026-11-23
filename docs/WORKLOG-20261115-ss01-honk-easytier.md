# WORKLOG 2026-11-15 — SS-01 Honk + EasyTier dedicated build

## Scope

This is a separate SS-01 project and workflow. It is based on the latest SS-01
NSS/DTS source in this tree and keeps the physical 12 MiB HLOS layout. The
firmware removes the existing proxy engines and their LuCI pages, then embeds
Honk and EasyTier as independent services:

- `honk-core` is installed as `/usr/bin/honk-core` with `/etc/init.d/honk`.
- EasyTier keeps `/usr/bin/easytier-core`, its web console, LuCI page and Chinese
  translation.
- Honk is disabled on a fresh image until the user enables it, so it cannot
  unexpectedly take over the network before a configuration is supplied.
- The ordinary GWRT agent, device defaults, Mesh services, NSS/SSDK and SS-01
  AHB Wi-Fi packages remain from the current SS-01 profile.

The dedicated build is explicitly labelled `SS-01 Honk + EasyTier` in the
workflow, artifact name, build log and release title. It is not part of the
four-profile `ss01/cs02/cs02-gwrt2/cs07` workflow.

## Honk source and UI

Honk is pinned to `v0.1.0-beta.6`; the workflow checks out the tag and verifies
its pinned Rust toolchains and `bpf-linker`. The Doona release is pinned to
`0.1.0-rc.6` with both standard and Lite archive hashes checked by Honk's own
`ci/fetch-doona.sh`.

The `native-ui` build embeds both editions in `honk-core`:

- `ui: 'embedded'` (the default here) is the complete Doona interface with
  activity/observability, diagnostics and configuration editing.
- `ui: 'embedded-lite'` selects Doona Lite, the smaller preview interface
  focused on the lighter node view and basic operation.

Both editions use the same Honk native API and proxy data plane. Switching the
setting in `/etc/honk/config.dae` does not require a firmware rebuild.

## Verification

Configuration and source preflight pass after `make defconfig`; the residual
`luci-app-passwall_INCLUDE_SmartDNS` Kconfig selection is treated as a disabled
parent package's non-package option and does not add a proxy package. Target,
calibration recovery, SS-01 Mesh, first-boot and roaming regressions pass.

The dedicated GitHub workflow subsequently completed the full firmware build
and artifact audit successfully; the final result is recorded below.

## Build result

GitHub Actions run `43620419381` completed successfully at
`2026-11-14T19:02:01Z` (2026-11-15 04:02:01 Asia/Tokyo). Its build job took
1h43m03s and used implementation commit
`19e673775acea9029189ba5ef2d53e7eac3a3f5f` on
`build/ss01-honk-easytier-261115-01`. The run used `release=false`; no GitHub
Release was published. Configuration, source preflight, calibration recovery,
Mesh, first-boot, roaming, Honk Rust/eBPF compilation, image audit, and
artifact upload all passed.

The downloaded artifact was verified at
`/tmp/gwrt-ss01-honk-easytier-261115-01.zip`. Its factory/sysupgrade hashes
matched the generated checksum file. The checksum file also lists the normal
buildinfo and initramfs outputs; those optional files were not included by the
dedicated artifact upload, so the delivery archive contains the two flashable
images plus manifest, profiles, configuration, source pins, and build logs.

## Archived delivery

Final files are archived under
`/home/godsun/build/gwrt-releases/ss01-honk-easytier-261115-01/` with the
verified physical `12M` label. The delivery checksum is
`sha256sums-261115-01` and is copied to `sha256sums`; `sha256sum -c` passes for
every archived file. Image filenames include `12M-honk-easytier`. Delivery
profiles resolve to those filenames; the original cloud profiles and complete
cloud checksum list are preserved in `original-cloud-metadata/`.

The archived `.local-defconfig` is the local preflight configuration, not an
exact cloud `config.buildinfo`. The cloud checksum references buildinfo and
initramfs files that this workflow did not upload; those omissions are documented
in `README.md`. The two requested firmware hashes match the original cloud
metadata; the original manifest and profile files also passed their source
checksum checks before the delivery profile names were adapted.

Local re-execution of `gwrt-verify-ss01-image.py --variant honk-easytier` passed:
factory rootfs offset is 12 MiB; the kernel and rootfs match sysupgrade; embedded
DTB model, dynamic UNIPHY parents, ports, packaged theme, Mesh and first-boot
files match the source. Honk, EasyTier, LuCI integration and the embedded Doona
payload passed package checks; other proxy engines are absent. The packaged
`v2ray-geoip` and `v2ray-geosite` are Honk's declared data dependencies.

An additional QEMU userspace check printed EasyTier version
`2.6.4-8428a89d`. Honk exited at `prctl(41, 1, 0, 0, 0)` with `EINVAL` under
QEMU before printing its version; Honk runtime behavior and the router's
eBPF/WAN/Wi-Fi behavior remain unverified on hardware.

Flashable image hashes:

```text
factory:    afa3c9a77c2e8aa53eb294c6a0fca8f692c760b26c9b0839ea0e4577d8a763cf
sysupgrade: 3b8eb6add04c4ac6d85b59dc8d87ac40e6a87c7ade9268bc72a9bacf30cc168e
```

The archive has not been flashed and no router has been rebooted.

## GitHub rebuild behavior

The dedicated workflow runs on a fresh `ubuntu-24.04` GitHub-hosted runner. It
caches `dl`, `staging_dir/toolchain-*`, and Cargo registry/Git downloads. It
does not persist `build_dir`, target `staging_dir`, or compiled Cargo `target`
outputs. A cache hit can therefore reuse downloaded sources and the toolchain,
while kernel, packages, Honk and the final images are compiled again for each
new run. This run hit both the source-download and toolchain caches; its Cargo
download cache was initially absent and was saved after success. The actual
cache hit/miss messages are retained in the archived full run log.



## 2026-11-15 后续：实机验证优先，261115-03 仍为隔离候选

用户已说明刷入 `261115-01`，要求先修改 SS-01 验证，再落源码，并补充不能遗漏 IPv6。后续范围为 Honk/Doona 保留、EasyTier 仅 LuCI、不集成核心或 Web Console、加广告拦截和 IPTV/UDPXY/Vlmcsd、修插件弹窗整体缩放及 Mesh LAN 地址显示。

**截至本段记录，未完成本轮实机热更新，也没有把候选实现同步到 NAS。** NAS 的早期状态段误写“完成/已同步源码”，现已更正。候选都保存在 `/home/godsun/build/gwrt-ss01-honk-easytier-261115-01`；未触发 `261115-03` 构建、推送、刷机、设备重启或主 AP 配置变更。

### 实际连接和 DNS 边界

- 此前读取 SS-01 的记录显示它作为 Mesh 子 AP，LAN 地址为 `192.168.9.152`，dnsmasq 停止，客户端使用主 AP `192.168.9.9`。此前临时回环 DNS 查询曾得到 360 A/AAAA NXDOMAIN，已清理；这不足以证明客户端整网拦截。
- 本轮 `.9.152/.153` 均无路由可达；从主 AP 只读检查，两者邻居为 FAILED，拓扑中没有 SS-01。旧 DHCP 租约不是在线证据。
- Netcatty external MCP discovery 文件当前不存在，不能使用该桥接；`/dev/ttyACM0` 可独占打开，但 115200 波特率下回车及只读命令都没有收到回显。没有执行任何重置/重启指令。已异步询问用户设备电源、串口和当前 IP。
- 主 AP 已确认是另一台 `jdcloud,re-cs-02-gwrt2`，只做读取，没有部署候选。向它查询 `www.360.cn A` 得 NOERROR 和真实 IPv4 地址；AAAA 得 NOERROR/空答案，**空 AAAA 不是已拦截**。IPv6 link-local DNS 查询超时，也不是拦截成功证据。
- 工作站 `resolvectl dns wlp0s20f3` 显示 `192.168.9.9 2408:8888::8 2408:8899::8`；主 AP 的 LAN/WAN6 为 RA/DHCPv6/NDP relay，未显式指定 LAN DNS。运营商 IPv6 DNS 会给客户端提供绕过本机 DNS 规则的入口。 实际用 `dig -6 @2408:8888::8 www.360.cn A` 成功得到 NOERROR 和 `101.199.254.116/123.6.48.25`，确认该 IPv6 DNS 直连入口可用；同服务器 AAAA 是 NOERROR/空答案，也不能误报为已拦截。
- 因此，规则本身支持 IPv6 不等于当前全网已阻断。透明子 AP 应在真正承担 DNS/IPv6 通告的主 AP 处理规则和 DNS 路径；本轮授权设备仍仅为 SS-01，不自动改 `.9.9`，也不把外部 DNS 超时或域名无 AAAA 当作成功。

### 隔离候选实现

- 广告库 `20261115-r3`，包 `2.2-r2`，六分类计数 `tv=218 tv-ext=115 cn=148 360=7 sec=30 kill=4`，总计 522。独立默认开启的 `[360]` 使用七个根域：`360.cn/360safe.com/360safe.cn/qhupdate.com/mayi360.cn/ads360.cn/360os.com`；`address=/domain/` 同时覆盖根域/子域和 A/AAAA。
- 保留旧 conffile 时，init 备份为 `ads-library.txt.before-360`，仅追加缺失根域，保留其它分类/用户内容；重复应用不重复追加。旧 sec 内的 360 子域不会自动删除，完整更新为新版库后才完成拆分。无效库加载失败会返回非零并保留有效规则。
- CLI/LuCI 共用 `gwrt-tv-adblock-query`，兼容 BusyBox `Address 1:` 的 IPv6 输出，区分 NXDOMAIN、有地址、无该类型记录、DNS 错误和未知。放行域必须覆盖实际拦截规则域或父域；窄子域不能覆盖更宽根域规则。
- 专用 SS-01 配置明确关闭 `easytier/easytier-noweb` 与 Web Console，仅启用 EasyTier LuCI/中文；选入 `gwrt-tv-adblock/luci-app-gwrt-tvadblock/luci-app-iptv/udpxy/luci-app-udpxy/vlmcsd/luci-app-vlmcsd`。继续排除其他代理及 dns2socks/geoview/ipt2socks/v2dat；Honk 声明的数据依赖保留。
- 主题候选 r118：iframe 整体缩放、反向扩大布局宽高后精确填满弹窗，避免内外双重缩放；resize/maximize/restore 更新尺寸并清理 observer。源主题与两个包副本在隔离树内一致。
- Mesh 每次状态/拓扑/hello/概览读取前刷新 netifd LAN IPv4、掩码和广播地址；地址丢失时清除旧 IP。修复仅针对上报陈旧地址；没有将现有 3-addr STA+NAT 无线回传改为 WDS/透明桥接，不能声称新增无线无缝漫游。
- Workflow 标题和产物说明明确 EasyTier LuCI-only；加入真实 DNS 回归与 `dnsmasq-base/dnsutils` 测试依赖。物理 SS-01 12M 布局不变。

### 已通过的本地检查

| 检查 | 实际结果 |
|---|---|
| `test-gwrt-tv-adblock-runtime.py` | 使用实际 init 生成规则，在临时 dnsmasq 随机高端口完成 176 次查询：七根域 × 根域/www/多级子域 × A/AAAA × IPv4/IPv6 × UDP/TCP = 168 次 NXDOMAIN；8 次正常 A/AAAA 对照通过；旧库备份/迁移/幂等、白名单、错误保留通过 |
| `test-gwrt-tv-adblock-query.py` | 分类计数/七根域/默认值与 BusyBox IPv4/IPv6 回答分类通过 |
| `test-gwrt-wifiroam.py` | 9 identity、14 steering/NAT/FT、10 backhaul 及新增 LAN IP/掩码/广播/地址丢失用例通过，使用目标 ucode + QEMU |
| `test-gwrt-modal-package-ui.js` | 1440×900、1280×600、768×540、390×640、844×390、320×480；缩放边缘、无横溢出、最大化/还原和实际按钮点击通过 |
| Mesh UI / theme security ports / integrate | 浏览器与三份主题副本同步检查通过 |
| 专用配置 / source preflight | 先前 `make defconfig` 返回 0，专用 validator 和仓库源码预检通过；但有多项 feeds Kconfig recursive dependency **错误**，不能表述为无警告/干净配置解析，正式构建前仍需处理 |
| Workflow | YAML 与每个 shell step 语法通过；未触发 workflow |

临时 DNS 只监听 `127.0.0.1/::1`，没有 DHCP/RA，不占系统 53 端口；测试结束终止进程并删除临时目录。以上均为本地测试，不能替代 SS-01 上的真实服务、LuCI、实际终端 DNS 和组网验证。

### 体积实测及候选文件

旧 `261115-01` sysupgrade 为 102,041,864 字节。按原 squashfs 实际文件压缩块/共享碎片分摊估算（不含元数据），Honk 包原始 32,343,062 字节、镜像约 12.13 MiB；完整 EasyTier 原始 14,728,636 字节、镜像约 14.05 MiB；v2dat/geoview 合计约 4.73 MiB。新配置会移除这些选中的运行程序，但最终镜像体积必须等后续授权编译后再确认，不能把估算当成新成品大小。

证据与候选目录：`/home/godsun/build/gwrt-ss01-honk-fixes-20261115/`。

- `serial-reconnect.log`：本轮无回显的串口尝试，不能当作已执行查询。
- `size-raw.json/size-squashfs.json`：旧镜像体积测量。
- `ss01-hotfix-candidate-not-deployed.tar.gz`：10 个主题/Mesh/广告拦截热更新文件，默认配置/库单独放置，不覆盖现有内容；附 SHA256 清单和备份/恢复说明。**尚未部署；不包含 IPTV/UDPXY/Vlmcsd 的运行 APK，也未卸载 EasyTier 核心。**
- NAS 实现尚未改动，因此没有新的 NAS 实现提交或设备回滚目录可引用；日志/AGENTS 更新用于准确记录待办。

下一步须恢复 SS-01 连接并核对硬件身份，持久备份后热更新，检查真实页面、netifd/Mesh 地址、IPv4/IPv6 DNS 路径、EasyTier UI/核心与小插件依赖；通过后再按文件选择性合入 NAS。不得覆盖脏 feeds 或其它并行改动。主 AP 的整网 DNS/IPv6 修正需要单独纳入设备范围；当前不可把这一项算作完成。


### 后续授权：在主 AP 验证广告拦截

用户随后明确“这个广告可以直接在 192.168.9.9 上改”。此授权覆盖了前述仅只读边界；本轮已在主 AP 保留原配置/旧库并补齐 360 根域，修正 daed 提前接管 DNS 造成的绕过，另加持久双栈普通 DNS 转发。400 项广告拦截 NXDOMAIN、16 项正常地址对照、48 项终测和真实 LuCI 页面通过。只将广告包/test/文档共 15 文件选择性同步 NAS；本段此前的“未修改主 AP / 未同步广告源码”是授权前的历史状态。完整证据、缓存/新增域名手工同步限制与双步骤回滚见 [主 AP 工作日志](WORKLOG-20261115-mainap-adblock-ipv6.md)。

SS-01 的 Honk/EasyTier/IPTV/主题/Mesh 本轮仍未热更新、构建或刷机，保持待设备恢复连接。
