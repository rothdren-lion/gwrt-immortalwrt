# WORKLOG 2026-11-07 — 插件修复与指定机型云端编译

## 范围与配置

用户最终收窄为以下 8 个串行任务，沿用原有配置和驱动，保留这些机型已有的存储/RAM 变体：

| 顺序 | 预设 | 设备 profile |
| --- | --- | --- |
| 1 | an758x / AN7581 | HG5585F CT/CU 及 USB/SFP 变体；XG-040G-MD 原版、UBI、UBI USB/SFP，共 7 个 |
| 2 | mt7981 | 360T7 原版/UBI、TR3000 256MB v1、GL-MT3000、XINGLOO AX3000 256/512MB，共 6 个 |
| 3 | ss01 | RE-SS-01 |
| 4 | cs02 | 标准 RE-CS-02；不包含 GWRT2 |
| 5 | cs07 | RE-CS-07，无无线 |
| 6 | cs06 | RE-CS-06 |
| 7 | cs08 | RE-CS-08，无无线 |
| 8 | mt7986 | S20P/L/M、Redmi AX6000 原厂/U-Boot、N60 Pro、RE-CP-03，共 7 个 |

用户确认：RE-CP-03 与 RE-CS-05 为同一款 MT7986 设备的新旧名称，使用现有 `jdcloud_re-cp-03` 配置。S20M 按用户实物说明禁用无线和外部 2.5G MAC，保留内部交换机 CPU 链路。

BE6500、CS-02 GWRT2、AN7583、XER5、PZ-L8、哪吒、CP02、G98 不进入本轮队列。

SS-01 已选择 `ath11k-firmware-ipq6018-ddwrt`；上游固件的禁用项是原有专用固件策略，不能据此添加上游包。配置检查只计算实际 `CONFIG_PACKAGE_` 选择，排除 `CONFIG_DEFAULT_` 的误判。

## 修改

- `.github/workflows/gwrt-soc-queue.yml` 串行调用原构建 workflow；前项失败仍推进下一项，取消队列则停止。
- `gwrt-build.yml` 支持 `models` 列表；`gwrt-select-models.py` 只从原预设删除未请求的设备，不改变插件集；defconfig 后校验设备集合、驱动/板级固件，构建后检查每台设备 manifest 和 SHA-256。
- `gwrt-mk-cs02-standard-config.sh` 从原 GWRT2 seed 派生标准 CS-02，只切换板型，保留已有 12 MiB 配置。
- BE6500 本地 board 数据已存在，云端快照遗漏了包注册和数据复制。本次补 `ipq-wifi-xiaomi_be6500` 定义及 Build/Prepare 复制；此项仅同步源码，不加入本轮编译。
- 用 `gwrt-overlays/feeds/` 保存 daed、aria2、OpenAppFilter 的 feed 修改，并在 feeds 更新后应用，避免 CI 更新覆盖修复。
- daed LuCI 增加实际 GraphQL 统计与每 5 秒刷新；登录信息仅保存在当前页面内存。aria2 按实际挂载和 UCI 设置启动/重载，保留用户目录、认证及启停配置。
- 同步已完成的主题、Mesh、agent 1712-r7 和 Control 17.17 源码；服务端发布包的交付记录见 `WORKLOG-20261107-agent-mesh-refresh.md`。

## 验证

- 原全部 17 个预设均经过生成、`make defconfig` 和配置校验；最终指定的 8 个任务再次筛选并校验，含用户确认的 RE-CP-03，共 25 个 profile。
- 记录目录：`/home/godsun/build/gwrt-releases/261107-batch-review/selected-configs/`；每个预设保存展开配置和日志，`validation.json` 保存结果。
- `sh scripts/gwrt-source-preflight.sh` 通过：主题副本一致，JS/shell/JSON 语法、aria2 挂载和默认值、APK 首次自动恢复回归通过。
- APK 测试修正重复调用场景：生产脚本再次执行 `init disable` 是正常的幂等行为；检查其余配置/安装操作没有重复，手动 force 不增加 disable 调用。
- agent、Mesh 状态回滚、AP 切换、终端合并、wifiroam、Control HTTP 契约、Mesh 浏览器界面、Control 界面的已有测试均通过。
- daed 浏览器测试使用独立官方 v2.1.1 API，通过登录、CORS、6 个统计数值、5 秒轮询、移动布局和临时凭据检查。

技能附带的旧 source audit 对 LAN Makefile 使用固定字面量匹配，与本树已有 `$(if ...)` 配置回退写法不兼容；本树检查实际确认默认值仍为 192.168.3.3/24。不能为满足静态误报更改原配置。SS-01/CS-07 的布局也以本树既有设备定义为准，当前云端源码定义为 12288k，不套用历史 6M 假设。

## 提交、构建与回滚

工作树：`/home/godsun/build/gwrt-ci-261107`；远端：`rothdren-lion/gwrt-immortalwrt` 默认分支 `master`。本轮版本为 `261107-02`，云端启动记录在启动后补入。

未进行刷机、重启或容器存储清理。Podman 的旧设备 overlay 挂载失败仅记录，未破坏容器数据。云端固件在构建和 manifest/hash 检查通过前不能视为可交付成品。

回滚源码使用对应提交的 `git revert`；停止云端队列使用 `gh run cancel <run-id> -R rothdren-lion/gwrt-immortalwrt`。本地 NAS 源码的其它历史改动不在本次清理范围。
