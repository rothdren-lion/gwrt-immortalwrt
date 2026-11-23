# 2026-11-12 — gwrt-agent IPv6 优先与 Tunnel 回退

## 背景与结果

用户反馈家中服务器经 Cloudflare Tunnel 很慢，曾以 IPv6 直连
`https://op6.gwrt.uk:8443` 获得较好速度，要求下一版 agent 支持双入口、IPv6 优先。
用户确认域名和端口不变，稍后恢复 DNS。

agent 已更新为 `1712-r8`，完成源码及构建树同步、29 项回归、完整 AArch64 APK 构建、
内部签名验证和 14 个安装文件拆包核对。产物仅保存在本机，未安装到路由器、未修改
线上服务/账号/数据库/网络配置，也未触发全量固件构建、刷机或设备重启。

本轮按 systematic-debugging 排查实际调用链，按 project-log-sync 更新记录。
在原脏树上只修改 agent 相关文件，不清理其它机型和既有工作。

## 已确认问题与修改

1. r7 的 shell API 强制 `curl -4`，只有单个入口；daemon 也只看 IPv4 默认路由，
   纯 IPv6 网络会跳过全部上报。现在允许 IPv4 或 IPv6 默认路由，并共用双入口 API。
2. 官方主入口 `https://op.gwrt.uk` 自动对应直连入口
   `https://op6.gwrt.uk:8443`，缺少新选项的旧 conffile 同样生效，避免升级保留配置后
   新功能失效。主入口末尾斜杠会规范化，不再产生双斜杠 API 路径。
3. `prefer_ipv6=0` 可以关闭优先；`endpoint_ipv6` 可指定自建 HTTPS 入口。
   自建主入口没有显式配置时绝不推导出官方 IPv6 地址，避免将其它服务的认证发送给官方服务。
4. 直连使用 `curl -6`，connect/total timeout 为 2/4 秒；失败后使用原主入口，允许
   自动选择 IPv4/IPv6，connect/total timeout 为 3/15 秒。保留证书验证和 `--noproxy '*'`，
   不跟随重定向，不并发发送相同 API 请求。
5. DNS、连接、TLS、超时、上游 5xx、无效 API JSON 等错误触发回退；有效 `ok:false`
   和 HTTP 4xx 拒绝（408/425/429 除外）直接返回，避免认证/参数错误重复投递。
   判断合法 API 响应要求存在布尔 `ok`，防止将反向代理返回的 HTML 误当成功。
6. r7 在 curl 失败时输出错误却返回成功。新的 `api()` 对双路失败返回非零；诊断记录
   curl 类型/HTTP 状态与入口，不输出服务端错误响应正文。
7. IPv6 失败后在 tmpfs 原子保存 60 秒冷却；命令替换的子 shell 之间共享状态，避免
   每次 pull/report/ack 都重复等待。到期由后续请求重试，入口变化或较大的时钟回拨
   不会把旧计时无限沿用。`status` 和日志显示最近成功入口；该字段不是持续健康探针。

修改文件：

- `package/gwrt-agent/files/usr/sbin/gwrt-agent`
- `package/gwrt-agent/files/etc/config/gwrt-agent`
- `package/gwrt-agent/Makefile`（发布号 7 → 8）
- `scripts/tests/test-gwrt-agent.py`
- 根 `AGENTS.md` 与本日志；构建树只同步对应内容。

## 验证

基线 18 项通过，新增后 29 项通过。命令：

```sh
busybox sh -n package/gwrt-agent/files/usr/sbin/gwrt-agent
python3 scripts/tests/test-gwrt-agent.py
```

使用 BusyBox shell 和 QEMU 下的目标 AArch64 ucode/jsonfilter，覆盖旧配置默认直连、
DNS/TLS/超时/502/HTML 回退、60 秒冷却跨子 shell 生效及再次探测、401 和业务拒绝
不重发、IPv4-only/关闭优先、自建入口认证隔离、显式自建 IPv6、双路失败及纯 IPv6 daemon。
原 JSON、Mesh、身份和命令行为回归继续通过。

真实 HTTPS 用例在本机 `::1` 和 `127.0.0.1` 启动两个隔离 TLS 服务，用测试 CA 与
`--resolve` 固定地址；实际调用目标 AArch64 curl（8.22.0，OpenSSL 3.5.8）验证
IPv6 成功 → 503 → 回退 → 冷却跳过直连 → 恢复，同时核对 URL、Bearer 和请求体一致。
测试 CA、token 和请求数据均为临时夹具，不接触生产凭据。
最终输出：`Ran 29 tests in 10.658s / OK`，日志见本机发布目录 `agent-tests.log`。

## 构建与产物

现有 `/home/godsun/build/immortalwrt-mt7981` 配置仍为 BE9300，架构为
`aarch64_cortex-a53`；本次只打用户态 agent 包，没有更换 profile 或运行 defconfig。
该树没有 `.git`，构建使用既有基线 `REVISION=581e8531b147`。本轮源码含未提交修改，
以 `build-inputs.json` 的逐文件 SHA-256 为准，不能仅用该 revision 重现。

```sh
cd /home/godsun/build/immortalwrt-mt7981
taskset -c 0-5 make -j6 package/gwrt-agent/compile V=s REVISION=581e8531b147
```

- 构建退出码 0；日志 `/home/godsun/build/gwrt-releases/agent-1712-r8/build.log`。
- 原 APK 位于 `bin/packages/aarch64_cortex-a53/base/gwrt-agent-1712-r8.apk`，61512 字节。
- 构建前后 `.config` SHA-256 均为
  `4ea0b752178b13415bde7162edf44152fb2da043bf7f80d8eb6457bc24892bad`。
- `apk verify` 用既有构建公钥验证成功；拆包 14/14 文件 SHA-256 与源码一致。
  唯一 conffile 为 `/etc/config/gwrt-agent`；依赖为
  libc、libgcc1、curl、jsonfilter、ucode、ucode-mod-fs，不强制新版 libubox。
- APK SHA-256：`3379bf483c8961e516f273025bd0dd6c2395996d867d102016e17aea0513d81d`。
- 原生 `.bin` 未修改，SHA-256 仍为
  `d21d4a71b9ce3c1866b3d0f8c627e6e1e7fd971662cb138516a9824d214e2b32`。
- 本次只提供 APK 内部签名及公钥，没有生成旧 OTA 的 detached usign 签名，没有复制私钥。

交付根目录：`/home/godsun/build/gwrt-releases/agent-1712-r8/delivery/`。
内含 APK、公钥、中文 README、源码归档、r7→r8 差异、release.json 和 SHA256SUMS。
构建输入、日志、APK 元数据、拆包验证明细保留在上一层。按用户要求，7 个交付文件已
直传至 `\\192.168.9.9\gwrt\gwrt-agent\` 根目录；从 SMB 重新下载后的七项 SHA-256
均与本地一致。旧版文件和 r7 子目录保留，未部署或更新在线服务。

安装、配置和程序回滚见交付目录 `README-1712-r8.md`，应安装完整 APK，保留原身份。
旧 r7 完整包仍在 `/home/godsun/build/gwrt-releases/agent-1712-r7/delivery/`。

## 源码备份与回滚

备份根目录 `/home/godsun/build/gwrt-backups/20261112-agent-ipv6/`：

- `source/package/gwrt-agent/`：修改前的 NAS 包目录。
- `source/scripts/tests/test-gwrt-agent.py`、`source/AGENTS.md`。
- `build/package/gwrt-agent/`、`build/.config`、`build/AGENTS.md`、
  `build/scripts/tests/test-gwrt-agent.py`：构建树对应修改前副本。

只回滚本轮源码修改时，在 NAS 源码根目录执行：

```sh
AGENT_BACKUP=/home/godsun/build/gwrt-backups/20261112-agent-ipv6
for rel in Makefile files/etc/config/gwrt-agent files/usr/sbin/gwrt-agent; do
    cp -p "$AGENT_BACKUP/source/package/gwrt-agent/$rel" "package/gwrt-agent/$rel"
done
cp -p "$AGENT_BACKUP/source/scripts/tests/test-gwrt-agent.py" scripts/tests/test-gwrt-agent.py
```

构建树按其 `build/` 备份恢复对应文件；没有需要恢复的 profile 变更。日志和其它设备
状态应保留，`AGENTS.md` 只撤销本轮新增段落，不覆盖未来的无关工作。

## 在线验证与仍存限制

本轮 Cloudflare/Google DoH 查询 `op6.gwrt.uk` AAAA 返回 NXDOMAIN；Tunnel 健康
请求也出现超时。这支持先完善客户端回退，但不足以定位 Tunnel 慢的服务端根因。
用户将恢复 DNS；尚未验证家庭服务器在线 TLS、8443 端口及实际速度，不能宣称线上已提速。
恢复 AAAA 和 IPv6 可达性后，r8 的后续请求会自动重试直连，无须改配置。

排查还确认：

1. `pair` 和本地 CGI 仍交给预编译原生二进制，其内部联网逻辑没有纳入新的 shell 路由。
2. daemon 的命令拉取目标周期是 5 秒，空闲遥测不会睡眠阻塞，但两者仍在同一同步循环。
   慢 dump、Mesh RPC、上报及命令处理会推迟下一次 pull，尚非严格 5 秒保证。
3. 自动 OTA 未接通完整 APK 升级。shell 未处理 `agent.update`，Control 17.17 manifest
   的 `artifacts` 为空，手动包仍为 r7。r8 需要完整 APK，不能将脚本冒充原二进制 OTA。
   本轮未修改服务端镜像和更新清单。
