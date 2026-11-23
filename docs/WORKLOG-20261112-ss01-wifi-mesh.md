# WORKLOG 2026-11-12 — SS-01 无线与 Mesh 首启修复

## 背景与边界

继续检查 SS-01 的 `261112-01` 固件及无线/Mesh；最初只修改和验证本地源码，
后续按用户要求推送并触发 SS-01 测试构建，详见下方记录。未刷机或主动重启设备，
也没有触发其他机型。
实机当前运行的固件未确认：此前串口被动监听 30 秒没有收到数据，不能据此判断启动状态。

GitHub Actions 运行 `43058011609` 的 attempt 2 已以成功状态完成，提交为
`5f2947e010c0167e0c63cce43fe1f519f0eb8aa3`；它早于本次无线/Mesh 修改。
该运行产物的 factory/sysupgrade SHA-256、12 MiB HLOS 布局、DTB 和主题文件检查通过，
但新增镜像门禁拒绝了该旧镜像：缺少 `etc/uci-defaults/95_gwrt-wifi-defaults`。
因此旧镜像不能作为本次修复的交付或实机验证依据。

## 源码修改

- SS-01 NSS seed 加入 `gwrt-device-defaults`、`gwrt-mesh-apmode` 和
  `gwrt-mesh-led`，保留 `gwrt-agent`；板级默认配置删除不存在的
  `ucidef_set_wireless_channel` 调用。SS-01 首启的 5 GHz 使用 CN、ch149、HE80。
- SS-01 的 95/96/97 首启脚本在 S10 阶段保留，由 `gwrt-caldata` 启动的
  `gwrt-ss01-firstboot` 等 S10 结束后按顺序执行；失败时最多重试 360 秒，
  未完成的脚本保留到下次启动。原有的校准数据持久化及单次重启保护继续保留。
- 95 等待两个 phy 和双频 radio；与 `10-wifi-detect` 共用 `flock`，
  热插拔先确保锁目录存在。主题的 SSID hook 在 95 执行前不并发修改无线配置。
  不论 SSID 是否已命名，SS-01 写入无线默认值后都重载无线；重载失败会重试。
- 96 在 SS-01 上要求 wifiroam、LuCI 和中文语言包都安装成功后才标记完成并清理 APK。
  97 校验安装内容和双频 AP，逐项写入 SSID；复制、UCI 或服务操作失败会保留脚本重试。
- `gwrt-wifiroam-autopair` 改用 UCI 列表接口和 `jshn` 生成 JSON，保留空格、引号、
  反斜杠等 SSID 字符；`gwrt-device-defaults` 声明 `jshn` 依赖。此项会影响所有使用
  该包的机型；SS-01 专用的延后、锁和无线重载逻辑按 board name 限定。
- SS-01 配置校验要求 Mesh 包和 `flock`；镜像门禁检查 Mesh 文件、离线 APK、
  manifest 及首启脚本与源码一致。workflow 的 SS-01 构建前步骤加入回归测试。

## 验证

在 NAS 源码树和隔离工作树均完成目标文件一致性检查；以下命令在 NAS 通过：

```sh
python3 scripts/tests/test-ss01-firstboot.py
GWRT_SS01_TEST_BUSYBOX=/usr/bin/busybox python3 scripts/tests/test-ss01-firstboot.py
python3 scripts/tests/test-gwrt-wifiroam-autopair.py
GWRT_SS01_TEST_BUSYBOX=/usr/bin/busybox python3 scripts/tests/test-gwrt-wifiroam-autopair.py
PATH=/home/godsun/build/gwrt-ss01-261109-01/staging_dir/host/bin:$PATH \
  GWRT_TEST_JSHN_SH=/home/godsun/build/gwrt-ss01-261109-01/staging_dir/host/share/libubox/jshn.sh \
  GWRT_SS01_TEST_BUSYBOX=/usr/bin/busybox python3 scripts/tests/test-gwrt-wifiroam-autopair.py
sh scripts/tests/test-ss01-mesh-preset.sh
sh scripts/tests/test-gwrt-caldata-reboot.sh
bash scripts/tests/test-gwrt-apk-autoinstall.sh \
  gwrt-theme-V3/theme/luci-theme-gwrt/root/usr/libexec/gwrt-apk-autoinstall
python3 scripts/gwrt-validate-build-config.py config.ss01-261101-01-nss ss01 \
  --models jdcloud_re-ss-01
```

另外通过 `sh -n`、BusyBox `ash -n`、Python 编译和相关文件的 `git diff --check`。
首启模拟涵盖 S10、提前热插拔、锁竞争、射频分批出现、无线重载失败、APK/中文包失败、
补丁复制失败、UCI 失败和服务失败；六种临时缺陷注入均被相应测试捕获。
三个离线 APK 使用 host apk-tools 3.0.3 解包，确认守护进程、LuCI 视图、菜单和中文包
的名称及安装路径与首启检查一致。

旧镜像负向检查可复现：

```sh
cd /home/godsun/build/gwrt-ss01-caldata-261112-01
python3 scripts/gwrt-verify-ss01-image.py /home/godsun/gwrt-verify-scratch.KiE1TT/bad-target
```

其预期退出码为 1，最后一行提示缺少 `95_gwrt-wifi-defaults`。
sysupgrade SHA-256 为 `96b8868ea0f84c65e9b8d1035ea5db2ede9a04988e9235dc3f91dee07a5a8085`；
factory SHA-256 为 `dceb95475f778e5d517e055942b9dcf53fa756e3025fb642cd93effc01ba3163`。

## 同步与回滚

CI 隔离工作树为 `/home/godsun/build/gwrt-ss01-caldata-261112-01`；本次改动已提交并推送，详见下方构建记录。
NAS 和隔离工作树的 21 个相关文件已逐项对比一致。最后一次同步前的 17 个 NAS 目标文件
及 `AGENTS.md` 备份在 `/home/godsun/build/gwrt-backups/20261112-ss01-wifi-mesh-w8b5t2fx/`；
`manifest.json` 记录原始和同步后的 SHA-256，其中三个文件原先不存在。
该快照不包含更早已同步的 seed 和 `04_defaults` 修改。

如需撤销这 17 个文件的最后一次同步，可先确认当前文件仍与同步后哈希一致，再运行：

```sh
python3 - <<'PY'
from pathlib import Path
import hashlib, json, shutil
backup = Path('/home/godsun/build/gwrt-backups/20261112-ss01-wifi-mesh-w8b5t2fx')
nas = Path('/mnt/syNAS/Dowloads/Rout/mark/immortalwrt')
manifest = json.loads((backup / 'manifest.json').read_text())
items = [(p, v) for p, v in manifest.items() if 'source_sha256' in v]
for path, entry in items:
    current = nas / path
    assert hashlib.sha256(current.read_bytes()).hexdigest() == entry['source_sha256'], path
for path, entry in items:
    current = nas / path
    if entry['before_sha256'] is None:
        current.unlink()
    else:
        shutil.copy2(backup / 'nas-before' / path, current)
PY
```

Seed、`04_defaults`、日志和 `AGENTS.md` 需另行审阅后恢复，避免覆盖已有无关改动。

## 待验证

新镜像仍在 GitHub Actions 构建；尚未在实机验证校准 guard 跨重启保留、NSS 时钟、
LAN 收发/DHCP、双频 Wi-Fi 或真实 Mesh 发现/配对，未刷机或主动重启设备。


## 2026-11-12 GitHub 测试构建

用户授权直接推送并构建 SS-01。提交 `92ad8fa25d4829f87c8ee2fae8978a60a6ab706a`
已推送私有仓 `rothdren-lion/gwrt-immortalwrt` 的 `master`，父提交为
`8fe8969f6c3a839f5cca4b61839af141e116442f`；保留远端 Ubuntu 24.04 固定、apt 重试和
工具链缓存隔离，NAS workflow 已同步。此次只触发 SS-01，version=`261112-02`，
`release=false`，`images=flashable`，运行 `43160479256` 后因测试 shell 环境失败：

https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43160479256

提交前在模拟 CI 主题同步后的隔离投影运行 `scripts/gwrt-source-preflight.sh` 和
`check-target-profile.sh ss01` 均通过；SS-01 seed 校验、首启/配对/校准 guard 等回归
以及差异空白检查通过。构建技能附带的旧 `preflight-source-audit.sh` 未通过：它引用
当前源码已不存在的旧插件路径及旧式 LAN 配置字面量，同时暴露 OAF、mini-diskmanager
既有调试输出和未引用 mock 函数；这些与本次 Mesh 修改无关，未宣称该旧审计通过。
这些既有插件代码保留原状，实际 CI 将重新执行仓库预检和 SS-01 专项测试。

本次同步前的 NAS workflow、本文和 AGENTS 备份：
`/home/godsun/build/gwrt-backups/20261112-ss01-wifi-mesh-github-92ad8fa2/`。
新固件未完成、未交付，未执行刷机或设备重启。

## 2026-11-12 云端测试 shell 修复与重跑

运行 `43160479256` 的配置生成、源码预检、校准重启 guard 和 SS-01 首启测试通过，
但 `test-gwrt-wifiroam-autopair.py` 在 Ubuntu 的 `/bin/sh`（Dash）执行了 OpenWrt
`/lib/functions.sh`，因该库使用 Dash 不支持的 `export -n` 而失败；固件编译未开始，
该运行没有生成成品。在本机提取的 Dash 中复现了相同错误；BusyBox `ash` 和真实 host
`jshn` 下的特殊字符 SSID 配对测试通过。

修复提交 `f7948498` 已推送 GitHub：工作流安装 BusyBox 并显式以其 `ash` 运行 SS-01
首启和 Mesh 配对测试，使测试 shell 与设备一致。工作流 YAML、三个 SS-01 Mesh 回归及
真实 `jshn` 复验通过。NAS workflow 已同步；同步前文件和本文、AGENTS 备份在
`/home/godsun/build/gwrt-backups/20261112-ss01-ci-ash-f7948498/`。

已重新触发同一测试版本 `261112-02`，仅 `device=ss01`、`release=false`、
`images=flashable`：

https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43161129582

此运行后来在首启测试失败，详见下一节；尚未验证或交付镜像。旧技能源码审计的限制仍如上所述。

## 2026-11-12 云端 flock 兼容修复与重跑

运行 `43161129582` 已完成配置生成、源码预检、校准保护和 Mesh preset 检查，
但 Ubuntu 24.04 的 BusyBox 1.36.1 不包含 `flock` 小程序，而测试强制把 `flock`
链接到 BusyBox，导致首启测试失败；该运行未进入编译、没有生成固件。
固件 seed 本身启用 `CONFIG_BUSYBOX_DEFAULT_FLOCK=y`。

提交 `432d03c8e200869cab549e2447e2a4e2e9798fd1` 已推送 GitHub：测试检测 BusyBox
是否包含 `flock`，缺失时使用系统 `flock`，workflow 显式安装 util-linux。
在本机复现失败后，使用从 Ubuntu 仓库提取的云端同版本 BusyBox 和 util-linux，
首启并发/失败重试及 Mesh 特殊字符 SSID 测试均通过；使用含 flock 的本机 BusyBox
重跑也通过，真实 host `jshn` 的 Mesh 测试通过。校准 guard、preset 测试、workflow YAML
解析和 Python 语法检查通过。

新的 SS-01 `261112-02` 测试运行，`release=false`、`images=flashable`：
https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43162126875

测试脚本及 workflow 已同步 NAS；同步前版本和文档备份位于
`/home/godsun/build/gwrt-backups/20261112-ss01-ci-flock-432d03c8/`。
2026-11-12 13:38（北京时间）查询：新运行已通过配置生成、仓库源码预检、校准 guard
和 Mesh 专项测试（含首启和配对脚本），正在执行固件编译；尚无经验证成品，未刷机或重启设备。

## 2026-11-12 构建完成与串口复核

运行 `43162126875` 已成功完成（`release=false`，`images=flashable`）。配置生成、源码预检、
校准重启 guard、SS-01 首启/Mesh 配对回归、固件编译、最终 manifest/哈希、主题与以太网审计
全部通过。artifact `gwrt-ss01-261112-02` 已下载到 `/tmp/gwrt-ss01-261112-02/`，产物为：

- sysupgrade：`gwrt-261112-02-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin`
  SHA-256 `68f0021fb24c033482ea9269bb9c3c274a274d0be0bd2d2eb91f9b63869c0e80`
- factory：`gwrt-261112-02-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-factory.bin`
  SHA-256 `98e0999c76768bf806157a6060abbb893456e4b1b621442ada19d514eb2461ae`

镜像审计确认 `KERNEL_SIZE=12288k`、内核 6953024 字节、SS-01 DTB 的 ESS/EDMA 和
`dp2=lan1 dp3=lan2 dp4=lan3 dp5=wan` 正确，NSS 模块、主题 r114、首启脚本和 Mesh 栈均在包内。
rootfs `/etc/os-release` 为 `GWRT 261112-02`；artifact 的 `config.buildinfo` 仍保留 seed
中的 `CONFIG_VERSION_NUMBER="261021-02"`，这是构建元数据不一致，未影响固件实际版本显示，
建议后续修正 workflow/seed 后再做正式发布。

本机 `/dev/ttyACM0`（QinHeng USB Single Serial）无其他进程占用，已设置 115200 8N1 并只读
监听 45 秒，收到 0 字节。因未收到设备启动输出，无法从本轮串口判断校准 guard 是否跨重启、
NSS 时钟、LAN/DHCP、双频 Wi-Fi 或真实 Mesh 配对；没有向串口发送字符，也未刷机或主动重启。

本版没有去掉无线组网：最终 manifest 包含 `gwrt-agent`、`gwrt-device-defaults`、
`gwrt-mesh-apmode`、`gwrt-mesh-led`、`wpad-openssl` 和 `ath11k-firmware-ipq6018-ddwrt`；
rootfs 包含 `wifiroam`、`luci-app-wifiroam`、中文包、`95/96/97` 首启脚本、Mesh 服务/工具及
离线 APK。也就是说保留的是 GWRT 的 wifiroam 无线/有线回传组网，是否能在实机配对仍需刷入后验证。
