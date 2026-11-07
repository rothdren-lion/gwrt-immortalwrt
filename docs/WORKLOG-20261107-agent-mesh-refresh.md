# 2026-11-07 — gwrt-agent、Mesh 添加及 5 秒界面刷新

## 范围与现场

用户要求顺带修复 gwrt-agent，将现有界面刷新改为 5 秒，发现局域网其它 AP 并支持添加。
主 AP `192.168.9.9` 实测 board 为 `jdcloud,re-cs-02-gwrt2`；现有已认证子 AP
`GWRT-CE62` 为 Qihoo 360T7，当前地址 `.9.130`。本轮只更新主 AP 脚本和页面，未刷机、
重启路由器或调整无线/网络配置，也未解绑现有子 AP 来制造发现候选。

使用 systematic-debugging 检查生产代码、现场二进制与协议；按
project-log-sync 记录修改和回滚方法。修改基于脏树，未清理或覆盖其它设备默认策略。

## 根因及修改

- 现场 `/usr/sbin/gwrt-agent` 实际仍是原生 v1712 ELF，SHA-256 与包内 `.bin` 一致，
  没有运行包含 wifiroam 扩展的 shell shim。保留原 ELF 为 `.bin`，启用新的 r7 shim；
  原二进制仍负责 dump、gwrt-pair-v2 和原本地 CGI 校验，原绑定身份保持不变。
- 上报原来只提供发现设备 MAC，且无二进制的架构直接输出 `{}`。新 ucode/fs JSON helper
  保留 MAC 数组，补名称/IP/型号/可添加标记、已认证成员和客户端计数；无 ELF 时仍有
  真实架构、身份及 Mesh 数据。不输出 nonce、Mesh token 和回传密码。
- 用结构化 JSON 序列化替代字符串拼接和 sed 删字段，修复带空格/引号/换行的 SSID、
  `hardware_id` 位于不同位置、漂亮打印 JSON 和嵌套 `payload` 命令。大拓扑经临时文件
  传入 helper，避免传参长度限制。Makefile 增加 `ucode` / `ucode-mod-fs` 依赖。
- 原配对/设角色命令不检查 ubus 返回值就 ACK success。现在拒绝和超时为 failed，
  配对必须在拓扑里看到认证成员；已经入网的添加重试幂等。新增 `mesh.unpair`。
  `mesh.apmode` 严格要求 0/1，并调用统一 off 入口，避免遗漏参数时意外启用 AP。
- 原 SSID 同步会重置 FT、RSSI profile 和阈值。现将当前 roam 对象原样重推。
- 服务端身份报错不再自动重置设备 ID 和绑定密钥；修复要求 48 位随机 token 实际只生成
  32 位的问题；间隔设置及 MAC 输入校验补齐。绑定 token 命令结果通过原 CGI bridge
  保留，危险配置命令继续遵守 remote_exec 开关。
- 首页 Mesh 区加入发现列表、添加按钮和管理入口：去重、排除本机/已认证成员，添加时
  禁用按钮并等待入网，明确显示失败。候选来自已有 wifiroam LAN HELLO 协议，支持
  已开启发现的未组网 GWRT AP；不声称普通第三方 AP 可通过该协议直接加入。
- 首页、活跃 App、四个 wifiroam 页面和独立 Mesh 页面设为 5 秒刷新。首页与独立页按
  请求开始时间计算下次周期，慢请求不会重叠；首页 ubus XHR 增加超时，隐藏时暂停。
  低频静态元数据和日志维持原缓存策略。
- 独立 `/mesh.html` 原来只查旧 mesh11sd，导致当前有线子 AP 无法显示。CGI 现在优先
  wifiroam；字段转义、失败显示和旧后端字段处理一起修正，添加入口使用登录后的 LuCI。
- Mesh 配对页成员客户端数按实际子节点统计；首页转译 SAP 客户端时保留 `conn.rssi`，
  修复子 AP 下无线终端没有信号覆盖文字的遗漏。

## 验证

- `python3 scripts/tests/test-gwrt-agent.py`：16 项生产函数/实际目标 JSON 工具用例通过。
  测试先在原实现或未修正实现上复现失败，覆盖格式化/嵌套 JSON、SSID 转义、无 ELF、
  身份保留、配对拒绝/未完成/完成/幂等、绑定结果、随机长度、MAC 和成员计数。
- `node scripts/tests/test-gwrt-mesh-ui.js`：真实 Chrome 验证发现去重、转义、添加按钮、
  已认证完成、失败可重试和移动宽度；使用生产 `normMac` 函数，避免简化 stub 掩盖
  冒号 MAC 格式差异。该格式问题也在现场隔离 RPC 检查中复现并修正。
- 原回归再次通过：clients 12 项，wifiroam 9 身份 + 14 steering/NAT/FT + 10 backhaul，
  state/MAC 11 组。shell、四个 LuCI JS 和目标 ucode/template 编译检查通过。
- 现场新 payload 保留 23 个客户端、1 个已认证有线 SAP，`hardware_id` 根字段不存在。
  现有身份的 report probe 收到 `ok=true, report_interval=5`；切换后也多次 report ok。
- 真实页面 1440px / 390px 无横向溢出、无 pageerror；两次读取 App 图标 5–6 个、RSSI
  标记 7 个。最终请求起点间隔为 4995 / 5001 / 5001ms；不是在完成请求后再额外等待 5 秒。
  独立 Mesh 页显示 GWRT-CE62 在线/有线；管理对话框成功打开。添加按钮的实机浏览器
  验证使用隔离 RPC 回复，仅模拟发现和失败，不向现有 AP 发真实配置命令。
- 热更新前后 `/etc/config/gwrt-agent`、`/etc/config/wireless` SHA-256 一致，hostapd
  PID 均为 `2843 2792`。主 AP 到子 AP 3 次 ping 无丢包。
- 云端 `op.gwrt.uk` 仍可出现连接重置和 20 秒 HTTP 超时；独立无认证 curl 对比也可
  复现超时，不能将其宣称为已修复或精确定位为服务端故障。本地页面 5 秒刷新独立工作。

浏览器结果、截图、原始失败测试和部署 hash 位于 `/tmp/gwrt-agent-review/`，是临时证据，
不是固件产物。没有将新固件标记为已构建或已刷入。

## 部署与回滚

主 AP 更新 13 个文件，备份：`/root/gwrt-agent-ui-backup-20261107-120307`。
原 ELF 与当前 `.bin` 均为 `d21d4a71b9ce3c1866b3d0f8c627e6e1e7fd971662cb138516a9824d214e2b32`。
每个线上文件与本地逐一核对 SHA-256；后续首页 MAC 格式及周期修正也重新编译并核对。

如需回滚，在主 AP 上执行（备份目录仅包含本次相关文件）：

```sh
/etc/init.d/gwrt-agent stop
B=/root/gwrt-agent-ui-backup-20261107-120307
for d in usr www; do [ ! -d "$B/$d" ] || cp -rp "$B/$d/." "/$d/"; done
/etc/init.d/gwrt-agent start
```

该命令恢复原 agent 可执行文件及页面，不覆盖现有配置；新增的 helper 和 `.bin` 可留存，
原 ELF 不调用它们。初始不存在的文件清单在备份 `previously-absent.txt` 中。

## 构建树

主题经 `gwrt-theme-V3/scripts/integrate.sh --no-defconfig` 同步并执行 `--check`。
agent、四个 wifiroam 页面及新测试按文件同步至
`/home/godsun/build/immortalwrt-mt7981`，保留该树其它默认值/配置分歧。
源码树和 build 树的 agent 16 项测试及 Mesh 浏览器用例均通过。build 树测试显式设置
`GWRT_TEST_THEME=/home/godsun/build/immortalwrt-mt7981/package/gwrt-theme/luci-theme-gwrt`，
核验实际打包目录；不读取该树遗留的旧 `gwrt-theme-V3` 开发副本。测试对缺少 Mesh
渲染器的输入明确报错，不再以空脚本继续运行。
包发布号更新为 agent `1712-r7`、theme `1.0-r113`、device-defaults `1.0-r2`，
对应本次实际代码修改；现场采用脚本热更新，未将 APK 数据库伪记为这些新发布号。
build 树原文件备份位于 `/home/godsun/build/gwrt-backups/20261107-agent-mesh-refresh/`。
本次未执行全量固件编译。后续构建仍须遵守 REVISION、profile 和机型保护规则。


## 同日追加：本地 APK 与 GWRT Control 容器交付

用户要求将安装包放入 `.9.9` SMB 的 `gwrt-agent` 目录，自行部署；并明确同意按需更新
服务端容器。现场确认 SMB 共享 `gwrt` 对应 `/mnt/mmcblk0p27`，原 `gwrt-agent/` 存放
17.13 的服务端容器归档及旧 agent。交付采用独立 `release-17.17-agent-1712-r7/` 子目录。
这阶段不替换 `.9.9` 运行中的脚本、不安装 APK、不更换在线服务或重启设备。

### 安装包

- 使用现有 build 树的 AArch64 配置，仅执行
  `taskset -c 0-5 make -j6 package/gwrt-agent/compile V=s REVISION=581e8531b147`；
  build 树当前固件 profile 为 BE9300，但本次只打相同 `aarch64_cortex-a53` 架构的用户态包，
  不生成该机型或 CS-02 的固件，不切换配置。构建前后 `.config` SHA-256 保持一致。
- 首包自动带入 build 树 `libubox20260721`，现场为 `libubox20260523`。原生 ELF 的
  DT_NEEDED 实际只有 libc/libgcc；将直接依赖从 libubox 改为 libgcc，jsonfilter 等工具
  继续由各自依赖解析，避免为安装脚本而被迫替换系统库。
- APK 内部签名和原 GWRT usign detached 签名均验证成功；签名公钥指纹
  `9eab7b61e31a9b70`。未复制私钥。拆包逐一核对 Makefile 安装的 14 个文件。
- 最终 APK SHA-256：`9347bcf3a6ba2779c08b8f3cd474b316d36d399814a28916e46d79bcda8387dc`。
- 现场只模拟安装解析为单个 agent 升级，但返回 3 个历史错误；原系统只模拟 `apk fix`
  也返回同样的 daed-geoip / daed-geosite / luci-app-smartdns 三项缺包状态。原安装数据库
  仍为 gwrt-agent 1712，未实际安装，也没有使用 force-broken-world 或替换系统库。

### 配套 Control 17.17

- 旧服务端只接收 `mesh`，丢弃新 agent 的 `gwrt_mesh`，且命令白名单没有 mesh.pair。
  因此需要配套容器更新。基线从本机归档 17.16 两个镜像提取；新可维护源码放在
  `gwrt-control/`。保留原认证、CSRF、设备所有权、SQLite 模式和反向代理部署约定。
- 新增 Mesh 页、5 秒轮询、请求去重/超时/隐藏暂停；支持成员与发现列表，过滤重复、
  本机和成员，只允许所属主 AP 添加新候选。数据超过 60 秒时拒绝配对，等待新上报。
- 新增 mesh.pair/unpair/role/apmode/ssid_sync 命令校验；实际仍走原设备命令队列。
- 补充 pull 响应中的 report_interval。agent 的命令轮询独立每 5 秒进行，空闲完整遥测
  仍保持低频；界面打开后及时恢复实时上报，避免直接 sleep 600 秒导致添加/刷新延迟。
  新增两个先复现失败的 agent 调度用例；共 18 项 agent 测试通过。
- 浏览器巡检实际触发旧版速度曲线的数组展开/除法顺序错误，导致系统页 JS 异常；修复
  后再检查完整页面。缺失天气温度有明确空值处理，页面不再显示 undefined。
- 17.16 已记录 manifest 宣称 1713、实际 .bin 仍 1712 的重复 OTA 缺陷。r7 又需要
  shell + JSON helper，不能伪装成单文件二进制更新。本镜像保留手动 APK 下载与签名，
  manifest artifacts 为空，manual 字段给出完整包，停止旧版重复自动二进制更新提示。
  未宣称已实现完整包的自动 OTA。

### 验证与构建

- 7 项真实 HTTP / SQLite 契约测试通过：新旧上报、缺省保留、非法输入、队列/pull/ACK、
  过期候选、认证/CSRF/所有权；相同测试针对旧服务端复现 4 项失败和 1 项错误。
- 真实 Chrome 完整页面测试通过：5 秒边界、慢请求不重叠、发现去重与 HTML 转义、
  带 CSRF 的添加、失败重试/成功、只读和过期禁用，390/1440px 无横向溢出、无 pageerror。
- 两个镜像均以 gwrt 用户实际启动本地隔离 HTTP 服务，健康接口为 17.17，源码与 APK
  下载 hash 一致；ARM64 在本机通过 qemu/binfmt 执行。未挂载生产数据库。
- 构建仅复用本地 17.16，`--pull=never --network=none`；COPY 显式 0644，修复本机 NAS
  文件权限继承导致非 root 服务无法读取 server.py 的打包问题。未拉取或升级外部基础镜像。

本机工作、日志、基线 hash 与交付目录位于
`/home/godsun/build/gwrt-releases/agent-1712-r7/`。最终文件列表、镜像 ID、架构、校验结果
以交付目录 `release.json` 和 `SHA256SUMS` 为准。正式云端部署仍由用户进行。

### SMB 交付完成

交付目录为 `\\192.168.9.9\gwrt\gwrt-agent\release-17.17-agent-1712-r7\`，
物理路径 `/mnt/mmcblk0p27/gwrt-agent/release-17.17-agent-1712-r7/`。
先上传到临时目录，远端 12 项 SHA-256 全部通过后原子改名；共 13 个文件，旧发布保留。
随后通过实际 SMB3 匿名会话列目录，并下载 SHA256SUMS 和 APK；与本机产物逐字节一致。
镜像分别约 72.1 MiB（AMD64）/ 76.0 MiB（ARM64），安装、保留配置及回滚说明见
`README-17.17.md`。本阶段仅交付文件，没有安装、重启或替换运行中的服务。
