# WORKLOG 2026-11-17 — IPQ60xx 无线默认值与启动逻辑复核

## 1. 背景与范围

用户反馈最新 Honk/Mesh 固件 CS-07 红灯，SS-01、CS-02 首启耗时数分钟；进一步确认 CS-02 的 5.2G phy 未出现。用户要求默认 5G 使用 HE80，并希望能直接生成的配置不再依赖启动后改写。本轮按用户“前面的逻辑正常吗”复核此前解释。

本轮读取 NAS 源码，并以实际 Honk 四机型构建 `43704312163` 的提交 `aeb771fea65a210d9f7aaada967b14a07fd48eb0` 对照关键文件。没有连接设备；不以 `192.168.9.9` 为无线对照；未触发编译、刷机、重启。本轮仅新增复核日志和指南索引，未继续修改启动实现。此前源树的 `95_gwrt-wifi-defaults` 已改为 HE80，该更改不等于已发布镜像更新。

## 2. 已确认的逻辑问题

### 2.1 配置和命名有多条写入路径

- `package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc:88` 读取 `board.wlan.defaults`；`:112` 没有默认值时使用 `ImmortalWrt`。生成器只为未配置的 radio 创建配置。
- `package/gwrt-device-defaults/files/95_gwrt-wifi-defaults:98` 调用 `/usr/libexec/gwrt-ssid-name`；SS-01 在 `:103` 显式执行 `wifi reload`，其它机型在 `:105` 使用 helper 的 `--reload`。
- `package/gwrt-theme/luci-theme-gwrt/root/etc/hotplug.d/ieee80211/30-gwrt-ssid-name:61` 使用另一套命名 helper；有改动时在 `:75` 提交并调用 reload。这个 hook 随 phy add 事件执行，不只是首启；SS-01 首启 defaults 尚未完成时会跳过。
- `target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata:117` 再次调用 SSID helper；`:160` 无条件提交后 reload。常规校准已存在的启动也会进入后台 `wifi_setup`，因此不能笼统说整套命名逻辑“仅首启一次”。

此前“全树只有一处调用”结论不成立，检索只覆盖了 device-defaults/Mesh 包，遗漏主题和子目标 base-files。

### 2.2 两套频段判定冲突

- `package/gwrt-device-defaults/files/gwrt-ssid-name:45` 按配置的信道数值命名 5G：低于 149 为 5.2G，否则为 5.8G。
- `package/gwrt-theme/luci-theme-gwrt/root/lib/functions/gwrt-wireless.sh:14` 按硬件路径将 AHB `c000000.wifi` 定义为 5.8G；`:15` 将 PCIe QCN9074 定义为 5.2G。该 PCIe 规则只对有外挂 QCN9074 的 CS-02/CS-07 生效；SS-01 无 QCN9074，两频都在 AHB（实测 `phy0`/`phy1` 均挂 `c000000.wifi`）。
- `95_gwrt-wifi-defaults` 对非 SS-01 的两个 5G radio 都写 ch36。结果是同一个 AHB 射频，按信道的 helper 写 `GWRT_5.2G_<MAC4>`，主题 hook 写 `GWRT_5.8G_<MAC4>`；事件时序不同会覆盖名称。只去掉一个 `--reload` 没有解决这一冲突。

此前建议“AHB ch36 / PCIe ch149”与本项目频段定义相反，应撤回。后续必须按机型、硬件路径和实际支持的频率确认；不能用 radio0/radio1 顺序硬编码。

### 2.3 不能直接删 reload 并承诺提速

`package/base-files/files/etc/init.d/boot:49` 在 S10 阶段先执行 wifi config，随后加载模块并执行 uci-defaults；netifd 的正常启动入口在 `package/network/config/netifd/files/etc/init.d/network:3` 为 S20。与此同时，phy 热插拔可以异步补配置，SS-01 还有延后 worker。

`package/network/config/wifi-scripts/files/sbin/wifi:54` 的 `wifi_reload()` 仅执行 `ubus call network reload`。这是请求 netifd 重读配置，不能直接等同完整射频重启。实际配置变化可能触发接口重配；需结合当时 netifd 状态判断。此前“省 2–4 秒”和“首启时 radio 必然未 up”的说法没有测量依据。

### 2.4 校准等待才是需要单独检查的分钟级路径

`gwrt-caldata` 从 ART 补出校准文件后，可以等待 overlay READY（`2 × 180 = 360` 秒上限），满足持久化条件后触发一次重启；常规 bootstrap 等待 phy 上限 `2 × 60 = 120` 秒。SS-01 worker 每轮间隔 5 秒、上限 72 次，分别等待 S10 结束以及 defaults 完成。这些是后台路径的条件上限，不等于本次实机实际耗时，也不能相加宣称为整机启动耗时。

`gwrt-caldata` 位于子目标 base-files。`package/base-files/Makefile:181` 至 `:183` 会将子目标 base-files 安装到系统中。因此 manifest 无独立 `gwrt-caldata` 包不表示脚本缺失。此前据此判断 CS-02 没带该脚本是错误的。

该 init 脚本没有按 CS-07 无无线机型直接跳过的总入口条件，这属于需要后续确认的范围；目前没有实机证据证明它导致 CS-07 红灯。红灯和相同 DTB 都不足以判断卡在内核/rootfs 哪一步，更不能据此排除全部软件原因。

## 3. 验证与证据

- 对照 Honk 固定提交的 `95_gwrt-wifi-defaults`、`mac80211.uc`、`gwrt-caldata`、主题 hotplug/helper、S10 boot、base-files 安装规则。关键旧逻辑在实际 Honk 分支中也存在。
- 临时工具 `/tmp/honk-startup-review/reproduce_ssid_conflict.py` 在隔离临时目录模拟 UCI/sysfs，运行现有 SSID helper，再调用固定提交的主题角色判定函数；没有访问路由器、没有执行真实 wifi/uci 操作。
- 沙盒结果：AHB/ch36 → helper `GWRT_5.2G_ABCD`，theme `GWRT_5.8G_ABCD`；PCIe/ch36 → 两者 `GWRT_5.2G_ABCD`；两条断言通过，证明命名规则冲突。沙盒不能证明实机实际事件顺序、启动耗时或 phy 缺失原因。
- 临时证据目录 `/tmp/honk-startup-review/` 以及 `/tmp/honk-{95-defaults-reviewed.sh,mac80211-reviewed.uc,caldata-reviewed.sh}` 为本机会话取证副本；/tmp 不作永久交付。

## 4. 后续实现方向与边界

建议将新 radio 的默认 SSID、加密、国家码和机型信道/HE80 在配置生成阶段一次写入。MAC 后四位在设备端生成配置时可读取，不要求刷机后再另启改名服务。现有 `board.json` 默认值已支持 SSID/加密/密钥/国家码，但还需扩展按 radio/path 选择的信道与宽度策略，不能宣称已有一个静态键即可全部实现。

保留用户自定义与 Mesh 下发配置；不要固化跨机器通用的 MAC/path 或依赖不稳定的 radio 编号。需要校准的步骤独立处理，不能因合并命名逻辑就删除校准提取、overlay 持久化保护及必需重载。

本轮没有实施这一重构。待解决：CS-02 5.2G phy 未注册、CS-07 红灯根因、两机实际慢启动路径；缺少有效启动日志时必须保留未确认状态。SSID/HE80 调整不会使未注册的 phy 出现。

## 5. 变更与回滚

本轮仅新增本文和更新 `AGENTS.md` 状态/索引。没有设备变更，不需要设备回滚。此前 HE80 变更在源树中保留；不要使用全文件替换 `HE80 -> HE160` 回滚，那会连原先 SS-01 正确的 HE80 分支一并改坏。
