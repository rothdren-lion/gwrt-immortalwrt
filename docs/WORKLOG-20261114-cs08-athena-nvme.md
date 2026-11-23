# CS-08 修复：剔除 CS-02 专用 Athena 屏 + 启用 M.2 NVMe（261114-01）

2026-11-14。用户要求检查 CS-08（太乙 2plus，IPQ53xx）的 SFP、M.2 驱动情况，并指出
Athena 点阵屏是 CS-02 专用，不应出现在其它机型。授权“修好重新编译”，随后改为
“推上 github 去编译”。

## 诊断结论（修复前，实机 192.168.3.3）

- SFP：驱动栈齐全（CONFIG_SFP=y，kmod-sfp / kmod-phy-marvell / marvell-10g /
  aquantia / qca83xx / realtek 均在），`sfp-0` 已绑定；未插模块时 gpio45 LOS 为高，
  无 netdev。遗留问题：`sfp` 被桥进 `br-lan`，但其 LED 功能标记为 WAN。
- M.2：`pcie1` 正常但空槽；**未选 CONFIG_BLK_DEV_NVME / kmod-nvme**，NVMe SSD 不会
  出现设备节点；DT 中 USB3 节点 `status = "disabled"`，M.2 WWAN 模组的 USB 侧不可用。
- Athena 屏：`athena-led` + `luci-app-athena-led` 被装进 CS-08（3.6MB + 40KB），
  init 已启用但进程立即退出；其 GPIO 69/70/73/74 在 TLMM（仅 53 线）上不存在，
  即使保留也不可能工作。污染来源为 `gwrt-mk-cs08-config.sh` 继承
  `config.cs06-261026-01`（cs02 → cs06 → cs08 链条）。
- 其它：WAN 仅 IPv6 且有 odhcpd `ra_lifetime=0` 警告；`gwrt-agent` 返回 401
  unknown device；继承的 cs02 插件集（homeproxy/passwall/easytier/microsocks/
  appfilter/bandix/nfsd/avahi/ttyd/gpio_switch）无对应硬件仍在运行；无 UCI LED 策略。

## 改动（提交 76a93fa5，master）

1. `gwrt-mk-cs08-config.sh`
   - 新增 2b：把 `athena-led`、`luci-app-athena-led` 的 `CONFIG_PACKAGE_` /
     `CONFIG_DEFAULT_` 全部改为 `is not set`。
   - 新增 2c：删除 `# CONFIG_PACKAGE_kmod-nvme is not set` 并写入
     `CONFIG_PACKAGE_kmod-nvme=y`。
2. `target/linux/qualcommbe/image/ipq53xx.mk`：`Device/jdcloud_re-cs-08` 的
   `DEVICE_PACKAGES` 增加 `kmod-nvme`。

生成器实跑复核（VER=261114-01）：athena 仅剩 3 行 `is not set`，
`CONFIG_PACKAGE_kmod-nvme=y`，`CONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-08"`，
无 wpad / kmod-ath / kmod-mac80211 / hostapd。

## 云端编译与产物核验

- 运行 `43462319841`（job 132012156208），`-f device=cs08 -f version=261114-01
  -f release=false`，配置/源码预检通过，编译约 2h38m，最终 success。
- 产物拆包核验（squashfs 7081 文件）：
  - athena 相关文件 0 个（`grep -i athena` 无命中）。
  - `lib/modules/6.18.62/nvme.ko`、`nvme-core.ko` 存在，
    `etc/modules.d/30-nvme`、`modules-boot.d/30-nvme` 已生成。
  - `kmod-sfp`、`kmod-phy-marvell`、`kmod-phy-marvell-10g`、`kmod-phy-aquantia`、
    `kmod-phy-qca83xx` 均在。
  - 唯一残留 ath12k 字样为 `etc/hotplug.d/firmware/12-ath12k-caldata`（base-files
    脚本，无 ath12k 驱动，无害）。
- 交付：`/home/godsun/build/gwrt-releases/cs08-261114-01/`，
  sysupgrade sha256 `bbbc9499859a0895c2b292c3b7ea2b0b0170cdf5b5723705c8bc8c1e8305baf3`，
  factory sha256 `5d79c7daa6d4ef6437acab71a8418a52198af31f7f4fd542b3a7e456a5c82ae4`。

## 未做 / 待决

- 未刷机，未重启设备；SFP 实插模块、M.2 NVMe 上盘、USB3（WWAN）均未实机验证。
- Athena 污染面更广：`config.*` / `configs/*` 中另有 22 个文件含 athena
  （cs06、cs07、ss01、an7581、mt7981 等），根因是继承 cs02 基线。本轮只修 CS-08。
  待用户确认后再做一次统一清理，并在
  `scripts/gwrt-validate-build-config.py` 里对非 cs02 机型禁止
  `athena-led` / `luci-app-athena-led`。
- `sfp` 归属 br-lan 与 WAN LED 标记不一致、WAN 仅 IPv6 的 odhcpd 警告、
  gwrt-agent 401、继承插件集取舍，均需用户决策，未改。

## 追加实机诊断（2026-11-14）

用户刷入 `261114-01/76a93fa` 后反馈 NVMe 仍未识别，并提供 `192.168.3.3`。
SSH 采集确认设备 compatible 为 `jdcloud,re-cs-08`，运行 Linux 6.18.62；
`nvme`/`nvme_core` 已加载，但 PCI 总线仅有 `0001:00:00.0` 根端口，
没有端点、`/sys/class/nvme` 为空，`/proc/partitions` 只见系统 `loop0` 和 eMMC。

- 启动日志 `qcom-pcie 18000000.pcie: Device not found` 在 Linux 6.18.62
  DesignWare 驱动中对应 LTSSM 处于 Detect.Quiet/Detect.Active，即没有检测到链路端设备。
- PCIe 根端口 `LnkSta=0x1011`，`DLL Active=0`；一次 PCI bus rescan 后端点仍缺失，
  链路状态也未改变。
- 实际运行 DT 显示 `pcie@18000000` 为 `okay`、控制器和 PHY 均为双 lane；
  子节点 `pcie@0` 的 `reset-gpios` 由驱动支持，GPIO47 被控制器申请且物理为高
  （active-low PERST 已释放）。PCIe PIPE/AXI/AHB 时钟均已启用。故目前证据不支持
  把子节点 reset 属性位置或 NVMe 驱动包缺失判为根因。
- 本轮仅额外写入一次 `/sys/bus/pci/rescan` 触发总线重新扫描；未改 UCI/设备树，
  未刷机、未重启。链路未训练可能来自 SSD 类型/接触/供电、槽位布线或控制器/PHY
  初始化；现有证据尚不能在这些原因间定论。
- 需要用户补充 SSD 品牌型号、槽位，以及原厂固件是否能识别同一块盘。NVMe M.2
  与 M.2 SATA 使用不同协议；若该槽并未提供 PCIe/NVMe，增加 `kmod-nvme` 不会使其出现。

SSH 原始采集、启动 DTB、扫描前后 root-port config 和报告保存在
`/home/godsun/build/gwrt-cs08-nvme-20261114/`。
