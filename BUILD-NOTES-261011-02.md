# ss-01 构建 261011-02 记录（本地树 /home/godsun/gwrt-immortal）

## 背景
261002-01 / 261011-01（NAS 树构建）刷机后红灯循环无法启动。
根因：10月5-6日为修"有线口不通"做的 NSS/PPE 大移植（DTS 换 ess-nss/dp 模型 +
qca_ppe/edma 驱动 ~3700 行改动 + SKB_RECYCLER config）导致内核起不来。

## 261011-02 做了什么（能启动优先）
1. **NSS/PPE 移植整体回退**到上游基线（.git/shallow = immortalwrt master 305089f9）：
   - target/linux/qualcommmax 整目录 = 基线（DTS 回 swport 模型）
   - 被回退的现场已备份：/tmp/nss-port-backup/（7 个驱动 + ess-nss.dtsi），
     DTS 完整 diff 在会话记录中
2. **补丁栈修复**（NAS 树的补丁集在全新 prepare 时必挂，从未被验证过）：
   - 删 backport-6.18/731-01..05（与基线 800-01..06 重复，731-04 先改了 include 区块导致 784-06 打不上）
   - 删 pending-6.18/700a-netfilter-flowtable-unregister-notifier-6.18.54.patch（6.18.55 上游已含该修复）
   - 删 hack-6.18/750-net-phy-realtek-add-rtl8261c-led-support.patch（对着旧树写的，与基线冲突）
   - 备份：/tmp/dup731-backup/
3. **feeds/packages/net/iperf3**：Makefile 被手改 3.22（未验证、补丁还是 3.21 的）→ 回退 git 版 3.21

## 预期行为（与 9月29~10月10 的旧版一致）
- ✅ 能启动：绿灯、WiFi 可用、DHCP 可用
- ❌ lan1-3/wan 四个有线口不通（CPU 口与交换机口不通的老问题，等串口调试再修）

## 交付
openwrt-rom/jdcloud_re-ss-01/gwrt-261011-02-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}
sha256sums-261011-02 校验 OK；config.ss01-261011-02 已存档（NAS + 本地树）

## ⚠️ 后续注意
1. **NAS 树没有同步这些修复**——在 NAS 树全新编译前需应用同样的补丁栈修复，
   否则 kernel prepare 一样会挂。已修好的树在 /home/godsun/gwrt-immortal。
2. **NAS NFS 抽风**（目录 readdir 在、lookup 报不存在，多目录漂移）未解决，
   建议：重启 NAS / 检查 DSM 日志 / 检查 NFS 服务。编译尽量走本地树。
3. **XER5 遗留**：RTL8261N 相关的 pending-6.18/742(5G/10G 支持)、721、743 保留可用，
   但已删的 hack-750(LED) 和更早的 731 系需要按基线 800 系列重做后才能给 XER5 用。
4. manifest 与 261011-01 差异：iperf3/libiperf3 3.21-r2（3.22 未验证过）、
   luci-app-homeproxy feed 新版。

## 261011-03 增量（有线口修复第 1 弹）
- 现象回顾：-02 能启动（WiFi 出 SSID），但有线口获取不到 IP。
- 根因定位：基线 `target/linux/qualcommmax/config-6.18` 里 **`# CONFIG_IPQ_CMN_PLL is not set`**
  —— `ipq6018-ess.dtsi` 的 `cmn_pll`(9b000) 是 uniphy0/PSGMII 的 12GHz 时钟源，
  驱动 `drivers/clk/qcom/ipq-cmn-pll.c` 没编进去 → uniphy 起不来 → 四个 QCA8075 口全死，
  而 WiFi/启动完全不受影响（症状完全吻合）。
- 修复：`CONFIG_IPQ_CMN_PLL=y`（一行）。包清单与 -02 完全一致，纯内核配置变化。
- 上游核查：快照 305089f → master HEAD 仅 16 个提交、零个动过 qualcommmax，
  即上游当前也带着这个 "not set"（上游 ipq60xx PSSGMII 板应该同样有线口挂）。
- 产物：gwrt-261011-03-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}，sha256sums-261011-03 OK
- 若 -03 仍有线口不通 → 下一嫌疑：uniphy 时钟引线/ppe 驱动，需串口日志或 WiFi SSH 进
  `dmesg | grep -iE "cmn|uniphy|ppe|edma|phy"` 定位。

## 261011-04/-05 记录（有线口修复第 2/3 弹 + 环境攻防战）
- -02/-03 复盘：构建时读到的 DTS 是"漂移回 NAS 的 NSS 版"（DTB 实证：ess-uniphy 绑定），
  而驱动是基线版 → 驱动不绑定 → 无网口、不 panic、WiFi 正常。CMN_PLL 补丁本身没白打。
- **环境问题**：本机存储对 "target/linux/qualcommmax" 这个路径名的内容会漂移/还原
  （多文件系统复现，NAS 最重）。改名成 qualcommax2 后 10/10 稳定。
- -04/-05：target 整体重命名为 **qualcommax2**（纯上游基线 287 文件流式抽取重建），
  ss-01 恢复 GWRT 定义（KERNEL_SIZE 12288k + factory.bin），CONFIG_IPQ_CMN_PLL=y。
- 包门禁修复（TARGET_qualcommax → ||qualcommax2）：ipq-wifi、ath11k-firmware-ddwrt、
  gwrt-agent、v2dat、webdav2、kmod-ath11k-ahb、kmod-usb-dwc3-qcom、kmod-qrtr-smd(ath.mk/usb.mk/netsupport.mk + 各包 Makefile)
- NSS kmod 包(qca-nss-*)故意不再选入（与基线 PPE 内核不兼容）。
- **-05 三重验证全过**（首次全程验货）：
  1. DTB 反编译：ess-uniphy=0、ipq6018-uniphy×2、lan1-3+wan 端口齐、cmn_pll 在
  2. manifest：ipq-wifi-jdcloud_re-ss-01 ✓ ath11k-firmware-ipq6018-ddwrt ✓ kmod-ath11k-ahb ✓（rootfs 有 ath11k_ahb.ko）✓ 真 NSS 包=0
  3. CONTROL=jdcloud_re-ss-01、版本 261011-05
- 交付：openwrt-rom/jdcloud_re-ss-01/gwrt-261011-05-亚瑟ss-01-*（sha256sums-261011-05）
- ⚠️ 后续在 qualcommax(旧名)下的一切编译都不可信；NAS 树的补丁栈修复(731/700a/750/iperf3)
  与 qualcommax2 target 的存在都已同步到本地树，NAS 侧仅 notes/config 存档。

## 261011-06 记录（真机验证通过后的首个正式版）
- 真机验证（-05）：启动✅ WiFi✅ 有线口✅（本机 eno0 从 SS-01 LAN 拿到 192.168.1.236，
  iperf3 双向 928~936Mbps 千兆线速，CPU 负载 0.9）
- -06 新增三件套：
  1. 99-lan-ip：默认 LAN IP = 192.168.3.3/24（GWRT 标准）
  2. 34_gwrt-autostart-policy：kixdns 移入默认自启（原在默认关闭清单），
     gwrt-theme-V3 源与 package 两处同步
  3. 38_gwrt-wifi-channel（新增 uci-defaults，两处同步）：
     5.8G(6018内置)→149 起；5.2G(QCN9074 PCIe，SS-02 三频)→36；2.4G 不动。
     实测设备 149 信道 80MHz 正常起 AP。
- 加速结论：本线为 **PPE/EDMA 内置模型**（qca-ppe/edma 编入内核，NSS 栈不编入），
  防火墙 flow_offloading_hw=1，转发 CPU 负载<1，千兆线速。
  gwrt-agent 每 30s "invalid JSON" 报错是 op.gwrt.uk 服务端返回体问题，待后端排查。

## 261011-07 记录（agent 上报修复，正式推荐版）
- gwrt-agent "report FAILED: invalid JSON" 刷屏根因（真机抓包实锤）：
  payload() 的 sed 删除 "hardware_id" 字段时模式 `,?` 两头贪婪，当 hardware_id
  紧跟 device_id（非末字段）时把 device_id 后面的逗号一并删除，产出
  {"device_id":"...""serial":...} 粘连非法 JSON → 服务端正确拒绝 invalid JSON。
- 修复：sed 改为只删「字段+后随逗号」： s/"hardware_id":"[^"]*",//g
  （hardware_id 若为末字段由 dump 保证后随逗号——实测原 dump 该字段非末位）。
- 真机热修验证：report ok: "report_interval":600（服务端下发 600s 间隔，刷屏停止）
- 树内同步：package/gwrt-agent/files/usr/sbin/gwrt-agent
- -07 = -06 全部（99-lan-ip 3.3 / kixdns 默认自启 / 5.8G→149 信道）+ agent 修复
- 终验：4 关键包 ✓ / BOARD ✓ / agent 修复 ✓ / 99-lan-ip ✓ / 38 信道 ✓ / 策略 ✓
- 交付：openwrt-rom/jdcloud_re-ss-01/gwrt-261011-07-亚瑟ss-01-*（sha256 OK）
- 设备已热修（无需等刷 -07 才能消报错；下次刷 -07 时热修会被镜像版本覆盖为同内容）

## 261011-08 记录（首刷 WiFi 兜底 + initramfs 污染事故）
- 真机反馈(-07 刷入无保留后)：WiFi 消失。根因链：
  1) ath11k 首启 QMI 要 cal-ahb-*.bin 早于 hotplug 从 0:ART 提取(sysfs 会话 EBADF)
  2) 提取文件落 overlay 后，第二次加载才可用 → -05 时代"重启后 WiFi 出现"的真因
- 修复：39_gwrt-wifi-firstboot(首启末尾: 无 phy→重载 ath11k_ahb; 无 radio 段→wifi config;
  补跑 38 信道脚本; wifi reload)。真机验证：模块重载后 WiFi 立即恢复(149 信道实扫)。
- 事故：-08b 构建 Image 突变 135MB(正常 12MB) → 普通内核 .config 残留
  INITRAMFS_SOURCE(rootfs cpio 403MB 打进内核) → 磁盘写满 → tar No space。
  根因 = 同内核目录 initramfs 版先构建的 .config 污染 + /home 磁盘 98% 满。
  处理：清空 INITRAMFS_SOURCE + 删旧 build_dir(qualcommax 旧目录 9.8G)。
- -08 终验：kmod-ath11k-ahb✓(rootfs 4 个 ath11k/qrtr 模块) 99-lan-ip✓ 38信道✓
  kixdns策略✓ agent sed✓ BOARD✓

## 2026-10-15 设备端热修轮次（全部已回写本地树）
1. **kixdns "未运行" 真因**：uci `kixdns.main.enabled='0'`（首启时被写 0），start_service
   读到 0 直接 return（无报错）→ procd 空 → LuCI Not running。
   设备修复：enabled=1 + procd 接管（running=true, 5300×5 监听, nslookup 5300 解析正常）。
   注意：脚本 rc.d S95kixdns 存在但 enabled=0 时不 spawn——"启动开关"实际控制的是 uci enabled。
2. **LuCI 编辑器缺失**：按上游 kixdns README 的可视化配置编辑器补齐：
   - 包内新增 root/www/kixdns-config.html（上游 tools/config_editor.html + GWRT 集成：
     "从路由器载入"/"保存到路由器并生效" 按钮，走 CGI）
   - 新增 root/www/cgi-bin/kixdns-config（read: JSON 转义输出；write: jsonfilter 校验后
     写 pipeline.json 并 restart kixdns；emit 函数修复了管道 body 丢失问题）
   - main.js 加 "Config Editor" 按钮跳转；luci-app-kixdns-lite 版本 1.0.0→1.1.0
3. 待办：设备上 enabled='0' 是首启时被写入的，需追查写入方（可能是早期 hotfix/脚本误写），
   在 -07+ 镜像的首次开机里确认 enabled 保持 '1'。

## 2026-10-15 -08 无线全灭根因（真机抓实锤，非猜测）
### 结论：`kmod-ath11k-ahb` 没进刷机后的 /rom
设备上 `/rom/lib/modules/6.18.55/` 只有 ath11k.ko / cfg80211.ko / mac80211.ko，
**唯独没有 ath11k_ahb.ko**；`/etc/modules.d/ath11k-ahb` 也没有；apk 数据库里
kmod-ath11k 存在、kmod-ath11k-ahb 不存在。

故障链（症状与现场完全吻合）：
  ath11k_ahb 从未加载 → 没有 /sys/class/net/phy* →
  /sbin/wifi config 检测不到射频 → /etc/config/wireless 为空 → 一个 SSID 都不出。

### 关键教训：**构建是对的，坏在"刷进去之后"**
- 镜像侧：`gwrt-261011-08-*-sysupgrade.bin` 解包后 ath11k_ahb.ko=121800 B、
  /etc/modules.d/ath11k-ahb 都在。`DEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01 kmod-ath11k-ahb`
  （qualcommax2/image/ipq60xx.mk:141）也是对的。
- 设备侧：与镜像逐个比对 .ko，**只差 ath11k_ahb.ko 这一个**（镜像 246 / 设备 245）。
- 即：之前 BUILD-NOTES 里那句"终验 kmod-ath11k-ahb✓"验的是**编译机上的镜像**，
  缺了"刷完机再验一遍"这一环，正好漏掉本次故障。
  → 已补 `gwrt-verify.sh`（见下），image/device 双模式。

### 39_gwrt-wifi-firstboot 的三个真实缺陷（本次一并暴露）
logread 实锤它一直在跑、也一直在失败：
    daemon.err modprobe: failed to find a module named ath11k_ahb
    daemon.err modinfo:  cannot find module - ath11k_ahb
1. `[ -x /etc/uci-defaults/38_gwrt-wifi-channel ] && sh ...` —— 38 的权限是 **0644**，
   `-x` 恒假，这段"补跑信道"从来没生效过（本次 5G 停在 ch36 而非 149 就是它）。
   已改 `-f`（boot 的 uci_apply_defaults 是用 `. file` **source** 的，不要求可执行位）。
2. 结尾无条件 `exit 0` → 哪怕 WiFi 完全没起来也自删，兜底脚本只活一次。
   已改为"只有 phy 真的在才 exit 0"，否则 exit 1 保留、下次开机重试。
3. `modprobe ... 2>/dev/null` 把失败吞了，39 自己一声不吭。
   已补显式诊断：模块不在时直接打
   `FATAL: ath11k_ahb.ko not present in /lib/modules - kmod-ath11k-ahb missing or flash failed`
   并把等 phy 的时间从固定 sleep 10 改成最多 30s 轮询（caldata 提取+固件加载要时间）。

### 设备端热修（已验证，overlay 内，重启后仍在）
    scp ath11k_ahb.ko → /lib/modules/6.18.55/
    echo ath11k_ahb > /etc/modules.d/ath11k-ahb
    /sbin/kmodloader
结果：phy0-ap0(5G ch149 80M) + phy1-ap0(2.4G ch1) 双 AP 起，fw WLAN.HK.2.12-01460。
**注意 /rom 里仍然没有该文件**，必须重刷才能真正干净。

### 附带发现
- `nss_crypto_clk_src: rcg didn't update its configuration` @ clk-rcg2.c:136，
  开机 0.95s WARNING + 栈回溯。**【更正】** 早先误判为 `-03` 打开 `CONFIG_IPQ_CMN_PLL=y`
  的副作用 —— 不对。`drivers/clk/qcom/ipq-cmn-pll.c` 里根本没有 `nss_crypto` / `0x68144`，
  两者无关。真正触发点是 `arch/arm64/boot/dts/qcom/ipq6018-ess.dtsi:146`，
  **PPE 节点的 `clock-names` 里带了 `gcc_nss_crypto_clk`**，PPE 驱动取这个时钟时
  去设速率，命中 `clk_rcg2_ops` 的 `update_config()`，而 IPQ6018 上这个 RCG2 的
  CMD_UPDATE 位永远不消，于是 WARN。
  也就是说：这是 mainline PPA/PPE 路径在 IPQ6018 上的固有现象，只要 PPE 在用就会打，
  和 CMN_PLL 无关，也不是 -03 引入的。
  **决定不处理**：WARN(1) 非致命（有线口实测线速正常），改 clk 驱动属于动上游代码；
  而把 `gcc_nss_crypto_clk` 从 PPE 的 clock-names 里摘掉更危险 —— PPE 会因为拿不到
  clock 而 -EPROBE_DEFER 根本起不来。为一条开机噪声冒这个险不划算。仅记录。
- **所有镜像（260929-02 起）都缺 modules.dep/alias/order/symbols**。procd kmodloader
  自己按 modinfo 解析 depends，不依赖这些，所以开机正常；但独立调用
  `modprobe`/`modinfo` 一直是坏的（39 就是这么静默失败的）。
- `luci-app-lan-wake` 也有 `[ -x /etc/uci-defaults/...]` 写法，但它的 postinst
  先 `chmod 755` 再判断，**是有意为之，不是 bug**。

### 新增：gwrt-verify.sh（交付自检，image / device 双模式）
    ./gwrt-verify.sh image  <sysupgrade.bin>
    ./gwrt-verify.sh device 192.168.3.3
检查项：ath11k/mac80211/cfg80211 模块与登记、ath11k 固件、38/39 脚本存在且无 -x 死代码、
99-lan-ip、gwrt-agent sed、CONTROL/BOARD、DTB(PPA 节点 / uniphy×2 / cmn_pll / 无 NSS 残留 /
lan1-3+wan)；device 模式另加运行态(phy 数、wireless 段数、信道、LAN IP、offload、
历史 modfail 计数、clk 告警)。
踩过的坑已写进注释：unsquashfs 成功也返回 2（别拿退出码判定）、DTB 是二进制不能进 $(...)、
默认 /tmp 常是容量小的 tmpfs 会 "Disk quota exceeded"（用 GWRT_WORKDIR 指到大盘）。

### 同轮清掉的树内不一致（package/ 与 gwrt-theme-V3/ 两份主题漂移）
- 34_gwrt-autostart-policy：V3 侧停在 10-06 版（samba4 还在关的清单里、aof 注释缺失）
- 36_gwrt-clients-init：V3 侧缺"不再 drop_caches"那行
- 38/39：补 0755，并同步到 V3 侧
一律以 package/（实际进镜像的那份）为准同步到 V3。

## 2026-10-15 261011-09（无线根因修复 + 构建链清理）
### 1. 交付
gwrt-261011-09-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest} + sha256sums-261011-09（校验 OK）
`gwrt-verify.sh image` 全绿：FAIL=0。含 39 的修复（无 -x 死代码 / 有缺模块诊断）、
ath11k_ahb.ko(121800B)+modules.d 登记齐全、DTB 全对、gwrt-agent sed 在位。

### 2. 【重要更正】-08b "initramfs 污染" 是误判
笔记里写的"同内核目录 .config 污染 → Image 135MB"**不成立**。
实际机制在 `include/kernel-defaults.mk:Kernel/SetInitramfs`：本线
`CONFIG_TARGET_ROOTFS_INITRAMFS=y` 的本意就是**把整个 rootfs 嵌进内核**做
boot-to-RAM 救援镜像，所以它本来就该是 100MB 量级。
实测 `usr/initramfs_data.cpio` = 385MB，zstd 压完 = 109MB；本机内存 **928MB**，装得下。
反而是 -08 那个 6.6MB 的 initramfs 才是异常（kernel 变体构建时 staging rootfs
还没填满就嵌进去了，等于空救援镜像）。gwrt-verify.sh 的判据已改成"太小才算错"。

### 3. 【重要发现】-08 交付物里混进了 -08b 的产物
比对 sha256 发现，交付目录里的 `gwrt-261011-08-亚瑟ss-01-{sysupgrade,initramfs}`
与 `bin/targets` 里 **-08b** 那份逐字节相同，而不是 -08 那份。
即坏的那次构建被改名成 "-08" 发了出去。
（sysupgrade 本身内容没问题，rootfs 是对的；受影响的是 initramfs.itb。）
**教训：交付必须按 sha256 对账，不能只看文件名。**

### 4. 构建链清理：干掉两个拖 13GB Rust 工具链的僵尸包
每次 `make world` 都在重编 rustc（stage1 bootstrap，13GB、数小时），
而且**已经吃掉了 /home → 这正是 -08b 磁盘满事故的帮凶**。
顺藤摸瓜查到两个 `.config` 里被设成 `=m`（只编不装）的僵尸包：
  - `CONFIG_PACKAGE_aardvark-dns=m` → `PKG_BUILD_DEPENDS:=rust/host`
  - `CONFIG_PACKAGE_netavark=m`      → `PKG_BUILD_DEPENDS:=rust/host`
两个都是 Docker 网络栈，本机用 `dnsmasq-full` 不用 networkd，
而且 **-08 manifest 里一个都没有**（根本没进镜像）——纯浪费。
已全部置为 not set，rust 工具链不再被触发，构建时间与磁盘占用大幅下降。
（`ruby` 也声明了 `RUBY_ENABLE_YJIT:rust/host`，但那个开关在 .config 里根本不存在，
  条件不成立，不影响。ruby 4.0.2-r2 确实在镜像里，保留。）

### 5. 修掉 libxml2 Host/Install 不幂等（world 构建硬挂）
```
mv: 'staging_dir/hostpkg/bin/xml2-config' and '.../x86_64-pc-linux-gnu-xml2-config'
    are the same file   →   .libxml2_installed 建不出来 → make world Error 1
```
原因是上一轮 install 已把 xml2-config 变成指向目标的符号链接，重装时 mv 跟随链接
发现源==目标就失败。改成"先删干净 → 从 ipkg-install 重新装实体文件 → 建链接"，
幂等了。见 `package/libs/libxml2/Makefile:Host/Install`。

### 6. 磁盘
/home(btrfs 231G) 之前 99% 满、仅剩 3.7G。已回收：
废弃的 rustc 构建树(只编到 stage1、从未安装成二进制)、旧 target 的
`root-qualcommax`/`root.orig-qualcommax`、无关 target 的 u-boot 产物。
现剩 7.7G，且不再有 rust 重建，够用了。
`/run/media/godsun/DATA` 还有 341G（NTFS/fuseblk），真不够时可把 dl 挪过去。

### 7. 仍未处理 / 待办
- **必须重刷**：设备 /rom 里依然没有 kmod-ath11k-ahb，现在靠 overlay 热修撑着。
  -09 镜像里是齐的（verify 已确认），重刷后跑 `gwrt-verify.sh device` 复验即可闭环。
- **刷机丢文件的原因还没查清**（f2fs 写入 / NAS 读取？），-09 刷完重点看这项。
- 旧 `target/linux/qualcommax/` 目录仍在（7.4M，.config 里 not set 所以不构建）。
  20+ 个 NSS 包门禁是 TARGET_qualcommax，一次 defconfig 有可能被拉回来。没删是因为
  它是用户多周工作的现场备份，删不删请自己定。
- modules.dep/alias/order/symbols 自 260929-02 起所有镜像都缺（kmodloader 不依赖，
  但独立调 modprobe/modinfo 会失败）。要补得动构建系统，暂记。

## 261011-09 记录（救砖→u-boot failsafe→initramfs→正式安装 全流程）
- 状况：-08 镜像缺 kmod-ath11k-ahb（defconfig 吃掉 PACKAGE 行）→ ath11k QMI
  卡死在 19.9s（内核 hang 非重启，watchdog 无效）→ 网络永不起来 = "假砖"。
- 救援链（全程无人值守）：
  1. ESP 继电器(192.168.9.147 Relay) 断电重启 ×N
  2. 串口 /dev/ttyACM0 抓日志定位 hang 点
  3. 上电 2 秒窗口串口发 \n 打断 autoboot → IPQ6018# u-boot
  4. u-boot httpd → Web failsafe UI（192.168.3.3）
  5. POST /upload initramfs itb(-09 的) + /result auto_reboot → initramfs 系统起 WiFi
  6. initramfs 里 SSH → sysupgrade -n 刷 -09 正式包
- 结果：-09 squashfs 正式系统首启 WiFi 通（caldata 落 overlay 后首载成功），
  5G=149 / 2.4G=1 / kixdns 运行 / LAN 3.3 / agent 上报正常。
- 39 脚本改"只加不减"版（rmmod ath11k 会内核崩溃死循环，教训入档）；38 补跑已入新版 39。
- 教训：每次构建后必须 grep manifest 确认 kmod-ath11k-ahb 在列（defconfig 会吞行）。

## 2026-10-17 261011-10（-09 变砖根因 + feeds 更新 + kixdns 三修）
### 1. -09 变砖真因：是我写的 39 里的 `rmmod`（串口实锤，不是猜）
设备刷 -09 后红灯闪→灭→闪 循环。TTL 串口 `/dev/ttyACM0` 抓到：
    ath11k c000000.wifi: qmi failed to load CAL data file:cal-ahb-c000000.wifi.bin
    ath11k c000000.wifi: failed to load board data file: -110   (ETIMEDOUT)
    ath11k c000000.wifi: qmi failed to send wlan mode off: -22 (EINVAL)
    Internal error: Oops: 0000000096000005 [#1] SMP
    CPU: 1 PID: 9272 Comm: rmmod
      ath11k_hal_srng_access_begin / ath11k_ce_cleanup_pipes
      ath11k_ahb_stop / ath11k_ahb_remove / cleanup_module
    Modules linked in: ... ath11k_ahb(O-) ...     ← (O-) 正在卸载，refcnt 归零

链条：首启时 ath11k 还没拿到 cal-ahb，QMI 超时、CE ring 已分配而 firmware 没起来
（半死态）→ `39` 判定"没有 phy"→ 执行 `rmmod ath11k_ahb` → 卸载路径读空指针
→ kernel Oops → 重启 → 脚本再跑 → 再 rmmod → 死循环。

**讽刺点**：-08 里那个 `[ -x 38... ]` 死代码反而"安全"，因为它压根走不到 rmmod。
我上一轮把它"修活"，等于放出了一条必崩路径。而 `gwrt-verify.sh image` 全绿也照样变砖
——静态检查看不见 rmmod 配 oops。**教训：交付前的静态检查有天花板，关键路径必须真机验。**

修复：39 重写为**只加不减**——删掉所有 rmmod；模块没加载才 modprobe；
已加载但没 phy 就干等 40s；任何情况不碰模块。文件头写了大段警告防止再加回来。
镜像内已验证 `grep -E "^\s*rmmod"` = 0。

### 2. feeds 一直不更新的真正原因：全局 gitconfig 的代理已死
`~/.gitconfig` 里 `url.https://ghproxy.net/https://github.com/.insteadof = https://github.com/`
把所有 GitHub 流量劫持到 ghproxy.net，而该镜像已失效（TLS unexpected eof）。
表现：`./scripts/feeds update` 全源 failed，feeds 停在 2026-09-21。
绕过：`env GIT_CONFIG_GLOBAL=/dev/null ./scripts/feeds update -a` → 全部成功。
**这是全局问题，不只影响这个树**，建议把那条 insteadOf 删掉。

feeds 更新后：packages 09-21 → **10-16**，luci 09-18 → **10-16**。
连带升级：luci-base/homeproxy/passwall/zoneinfo(2026d→2026e)/sing-box(1.12→1.14)
/v2ray-geoip/nfs/iperf3(3.21→3.22)/miniupnpd(2.3.9→2.3.11) 等数十个包。

### 3. 更新 feeds 踩到的三个补丁失效（都已处理）
- `miniupnpd/020-descr-filter-fix.patch`：上游 2.3.11 Changelog 2026/02/05
  "Rewrite permission line parser" 已含此修复（函数已重命名为 read_permission_line
  并拆出 get_sep/get_range/get_addr_or_mask）→ 冗余，删除。
- `miniupnpd/030-allow-private-fix.patch`：上游 2.3.11 的 upnpsoap.c 已是修复后的
  `if (GETFLAG(ALLOWPRIVATEIPV4MASK))` → 冗余，删除。
- `miniupnpd/040-improve-logging.patch`：纯日志降级，12 hunk 有 4 个上下文漂移。
  已按 2.3.11 重新生成等价补丁（6 处 LOG_INFO→LOG_DEBUG）。

### 4. 我 reset feeds 时误伤的本地改动（已恢复）
feeds 目录本来有大量本地手工改动（packages 250 / luci 560 / video 64 个文件），
`git reset --hard` 把它们清掉了，导致 daed 与 appfilter 版本回退。已从备份
`.gwrt-logs/feeds-local-mods/{packages,luci,video}.patch` 全部恢复：
- `daed`：1.27.0 → **2.1.1 预编译二进制**。理由是 1.27.0 的 eBPF 与内核 6.18
  不兼容（SOCK_OPS 不能用 bpf_get_current_task）。同时恢复 daed.init 的
  端口假活看门狗（45s 健康检查 + 120s 时间戳冷却重启）。
- `open-app-filter`：04-20 → **09-24 (7fcf9e87)**。恢复时还发现两处必须补的：
  * 09-24 的 fwx_user.c 开始调用 sqlite3，但其自带 Makefile 的 LIBS 不继承
    PKG_BUILD_DEPENDS → 必须在 `MAKE_VARS` 里显式加 `-lsqlite3 -lcurl`，
    否则链接期 undefined reference to `sqlite3_open`。
  * install 段要跟着改（移除 09-24 已不存在的 gen_class.sh/oaf_rule/
    feature_cn.cfg/feature_en.cfg，新增 rule_manager.lua 与 8 个配置文件），
    conffiles 也要补全，否则用户改过的配置会在升级时被覆盖。

### 5. openclash 升到官方最新版 0.48.002
immortalwrt/luci feed 里长期停在 0.47.156，而官方 vernesong/OpenClash 已到
**v0.48.002**（2026-10-12）。feed 的 luci-app-openclash 是内联复制版，
已整包替换为官方 v0.48.002（luasrc/po/root/tools/Makefile，232 个文件）。
新版 Makefile 多了一步 `sed -i 's|@OPENCLASH_VERSION@|$(PKG_VERSION)|g'`
用于浏览器资源缓存键，必须用上游 Makefile 才行。

### 6. kixdns：默认关 + 补 web 配置 + 堵安全洞
- **默认关闭**（用户要求）：从 34 的"必须开"清单移到显式关闭段，同时
  `uci set kixdns.main.enabled=0`。两处都要改的原因：kixdns.init 的 start_service
  读到 enabled=0 就 return，procd 里没有实例，LuCI 会显示 "Not running"，
  看起来像坏了。包内 kixdns.config 默认值也改成 0。
- **web 配置编辑器**：之前 -08 镜像里 `/www/kixdns-config.html` **不存在**
  （那是 -09 才加的未编译改动），所以 LuCI 页面上的 "Config Editor" 按钮点了 404，
  用户只看到 状态/监听地址/启动/监听端口 四个字段。-10 里该文件已正常打包。
- **安全洞**：原实现用 `/www/cgi-bin/kixdns-config` 这个 CGI 读写配置，但
  uhttpd 的 `cgi_prefix=/cgi-bin` 只有 `/cgi-bin/luci` 映射到认证处理，
  其余 `/cgi-bin/*` **免认证执行** —— 任何能访问 80 端口的设备都能改
  `/etc/kixdns/pipeline.json` 并重启 kixdns。已删除该 CGI，HTML 改走
  ubus HTTP RPC（自带 sysauth cookie，由已有的
  `acl.d/luci-app-kixdns-lite.json` 判权），luci-app-kixdns-lite 升到 1.2.0。

### 交付
gwrt-261011-10-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest} + sha256sums-261011-10（校验 OK）
`gwrt-verify.sh image` → FAIL=0 / WARN=3（3 个 WARN 均为已知历史遗留，见下）
镜像内逐项确认：39 无 rmmod、免认证 CGI 已删、html 走 ubus、kixdns 默认关。

---

## 261011-10 真机刷机 + 261011-11 修复首启无线

### 1. -10 刷机结果（首次不保留配置）
`sysupgrade -n` 全新安装。`/rom/lib/modules/*/ath11k_ahb.ko` **存在** —— -08 丢模块
的老问题彻底消失，验证脚本新增了这一项断言。整场 **零 Oops**。

但首次启动无线没起来，查日志定位到真正的时序问题：

```
 26s  ath11k c000000.wifi: ipq6018 hw1.0        ← 驱动加载，request_firmware(cal-ahb-*)
 90s  remoteproc remoteproc0: remote processor wcnss is now up
139s  (首次) / 132s (二次) phy0-ap0 / phy1-ap0
181s  ath11k: qmi failed to load CAL data file:cal-ahb-c000000.wifi.bin
      ath11k: failed to load board data file: -12
```

**根因不是代码 bug，是硬件时序**：
- `cal-ahb-c000000.wifi.bin` 不在镜像里，靠 `/etc/hotplug.d/firmware/11-ath11k-caldata`
  在 ath11k 请求固件时从 `0:ART` 提取
- 而这个提取要靠 rootfs 挂载后才能做，于是提取发生在 **~90s**
- ath11k 在 **26s** 就发起了固件请求，等不到文件 → QMI 侧 `-12`
- 第二次开机会正常，是因为 caldata 已经躺在 overlay 里，26s 就能读到

所以 -10 及之前所有版本的实际行为一直是「**首次启动无 WiFi，重启一次才有**」。
老 `39_gwrt-wifi-firstboot` 只同步等 40s，而 phy 要 130s 才出现，等不到 →
`exit 1` 把自己留在 `/etc/uci-defaults` 里赖到下次开机。
更糟的是 `38_gwrt-wifi-channel` 在 wireless 配置还没生成时空跑一轮、**执行成功
就自删**，导致 5G 停在 36 而不是约定的 149。

### 2. -11 的修法：把等待挪进后台 subshell
改 `39_gwrt-wifi-firstboot`：
- 没有 phy 时，把「modprobe(只加不减) → 等 180s → 生成 wireless 配置 →
  补跑 38 设信道 → wifi reload」整段放进后台 subshell
- 主脚本**立刻 `exit 0`**，让 uci-defaults 把它删掉，不再长期占位
- 全程仍然**没有任何 rmmod**（-09 变砖根因，不能碰）
- 删掉 `no phy can appear` 这句死文案，换成 `FATAL: ath11k_ahb.ko not present
  in /lib/modules`（这段现在在后台路径里，验证脚本的 grep 关键字要同步改）

`38` 不再抢跑 —— `39` 后台等出 phy 后会自己按 `gwrt_wifi_role()` 设 149/36。

`gwrt-verify.sh image` 模式也加了两条新断言：
- `39` 里出现任何 `rmmod` 直接 **FAIL**（-09 变砖根因的回归防线）
- `39` 没把等待挪后台则 WARN（时序问题的回归防线）

### 3. -11 真机结果
| 项 | 结果 |
|---|---|
| 首次启动无线 | **139s 两个 phy 进 forwarding** ✅ 历史首次不用重启 |
| `qmi failed to load CAL` | **不再出现** ✅ |
| 5G 信道 | 149（后台补设）✅ |
| `39` 残留 | 无，`/etc/uci-defaults` 空 ✅ |
| Oops | 0 ✅ |
| 重启后 | 90s 无线起（caldata 已在 overlay，比首启更快），零 Oops ✅ |
| kixdns | enabled=0，进程未跑（默认关，符合要求）✅ |
| `gwrt-verify.sh device` | **FAIL=0 / WARN=1** |

剩下的 WARN 只有 `nss_crypto_clk_src: rcg didn't update`，PPE 取
`gcc_nss_crypto_clk` 命中 IPQ6018 RCG2 固有行为，已知不处理。

### 4. 传输方式变更（踩坑）
`scp -O` 传 128MB 镜像到路由器**连续 3 次 `lost connection`**（-10 那次同样的
命令却成功，设备负载/内存状态不同）。改成本机 `python3 -m http.server`
+ 路由器 `wget`，一次成功，sha256 一致。**以后传大镜像一律走 HTTP，不走 scp。**

另外串口捕获脚本 `ttycap.sh` 单独成文件的原因：直接在 `bash -c` 里写
`cat /dev/ttyACM0`，`pkill -f "cat /dev/ttyACM0"` 会匹配到自己的命令行、
把自己 SIGTERM 掉。

### 交付
`gwrt-261011-11-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}`
sysupgrade sha256 = `e00c4ae4967e080798d28d02bb8dfc12495667bf9a0763f62a98d73f03632da8`
factory  sha256 = `4fd447c2ab2d2316032e188b0f5cbe6278dcd05d140ea8f607c1f6ce9aebecb9`

---

## 261011-12 ~ -16 首启无线根治 + 首页网速框修复

### 1. 「网速-EQoS」框不显示实时网速和 IP —— 两条数据路全是死的

真机核对后确认这是**两个独立的 bug 同时存在**，且都在
`root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut`：

**(a) 主路径 `luci.getRealtimeStats` 调用契约写错**
```js
rpc('luci','getRealtimeStats',{device:dev})      // 没传 mode
```
- rpcd 的 ucode 插件**不填默认值**（`ucode.c` 只解析调用方实际传来的键），
  真机实测 `ubus call luci getRealtimeStats '{"device":"eth0"}'`
  → `{"error":"Invalid mode"}`
- 就算补上 `mode:'interface'`，返回也是 `{"result":[[t,rxb,rxp,txb,txp],...]}`
  （`luci-bwc` 的输出格式），**根本没有 `rx_speed`/`tx_speed` 字段** ——
  代码里 `if(st.rx_speed!==undefined)` 恒假

**(b) 兜底路径被 rpcd 的 symlink 二次鉴权拦死**
```js
rpc('file','read',{path:'/sys/class/net/'+dev+'/statistics/rx_bytes'})
```
- rpcd 2026.07.19 的 `file.c` 在 ACL 通过后会 `realpath()` 再按解析出的路径
  重新鉴权（`rpc_check_symlink_access`）
- `/sys/class/net/wan` 解析成 `/sys/devices/platform/soc@0/3a000000.ppe/net/wan`，
  跟主题 ACL 里的 `/sys/class/net/*/statistics/*` 对不上 → Permission denied
- 这是全主题**唯一**读 `/sys/class/...` 的地方（别的 file read 目标都不是软链）

**(c) 顺带修掉的隐患**
- 变量冲突：`for(var wi=0;...)`（温度解析）和 `var wi=ifs.find(...)`（WAN）
  同属 `refresh()` 函数作用域，靠执行顺序侥幸没出错，已改名 `wix`
- WAN 段是 `refresh()` 的**最后一段**，前面任何一处抛错都会被末尾的
  `.catch` 静默吞掉，结果恰好只打掉这一个框。已整段包 `try/catch` 隔离
- 接口名硬编码 `'wan'`，改名后整个框全空。已加「第一个非 lan/loopback 且有
  IPv4 的接口」兜底

**改法**：改用 `network.device status {name:<dev>}` 的
`.statistics.rx_bytes/tx_bytes` 按时间差算速率 —— 同文件 `renderPortStrip()`
走的就是这条，真机实测可用且计数在涨（3 秒 +4070 字节）。

### 2. 首次启动无 WiFi —— 总算根治了（前面 -11/-12/-14/-15 全是错路）

**真实时序（TTL 串口 + dmesg 实测）**
```
 ~22s  （修复后）caldata 已提前就位
 ~25s  ath11k 探测 -> QMI 取 CAL -> request_firmware(cal-ahb-*.bin)
       这请求**失败后不重试**
 ~85s  wcnss 才起来，11-ath11k-caldata 的 hotplug 此时才从 0:ART 落盘
~148s  ath11k 报 "qmi failed to load CAL data file" /
       "failed to load board data file: -12"（-12 = ENOMEM，request_firmware 返回）
```
结论：hotplug 提取**永远晚于** ath11k 的请求，输赢纯看运气 ——
-11 首启侥幸成功，-12/-14/-15 首启都失败。所谓「重启一次就好」是因为
caldata 已经缓存进 overlay。

**走过并推翻的两条错路（重要，别改回去）**
1. `/lib/preinit/70_gwrt-ath11k-caldata` —— 无效。
   本固件 `CONFIG_TARGET_ROOTFS_INITRAMFS=y`（boot-to-RAM），
   `/rom` 是 flash 上的 `/dev/mmcblk0p18` squashfs（只读），**不是**内核
   initramfs 的那份 RAM 拷贝。preinit 写进 RAM 拷贝的 `/usr/lib/firmware`
   在 `mount_root` 切换后整个丢弃。-14 实测：hook 注册对了、脚本也跑了，
   但 `/rom/lib/firmware` 里始终没有 caldata。
   （另外 preinit 里光定义 `do_xxx` 不会被调用 —— `/etc/preinit` 只是
   `. /lib/preinit/*` 然后 `boot_run_hook`，必须 `boot_hook_add`）
2. `/etc/uci-defaults/01_gwrt-ath11k-caldata` —— 无效。
   `/etc/init.d/boot`（START=10）里顺序是
   ```sh
   /sbin/kmodloader        # ath11k 在这里探测
   uci_apply_defaults      # uci-defaults 在这之后
   ```
   结构上必然晚。-15 实测：脚本跑了、caldata 抽出来了、md5 也对，
   但 ath11k 早已探测完，照样 -12。

**正确位置：`START=09` 的 init.d**
`/etc/init.d/gwrt-ath11k-caldata`（START=09，配
`/etc/rc.d/S09gwrt-ath11k-caldata` 符号链接），排在 `S10boot` 的
`kmodloader` 之前。只做 `mkdir + dd`，**全程不 rmmod**
（-09 变砖根因）。提取参数与 hotplug 的 `jdcloud,re-ss-01` 分支逐字节一致。

调试时踩到的两个小坑：
- `PARTNAME` 是 `0:ART` 带前缀，写 `ART` 匹配不上
- 此时 `syslogd` 还没起（S12log），`logger` 会丢消息；改写 `/dev/kmsg`，
  这样能带内核时间戳落进 dmesg，便于核对是否真的抢在 ath11k 之前

### 3. `modules.dep` 那个 WARN 是误报，已降为 INFO
真机实测：镜像里根本没装 `kmod` 工具包（只有 `kmod-*` 子包即 `.ko` 本体），
`/sbin/modprobe -> /sbin/kmodloader`，`/sbin/kmod` 和 `/sbin/depmod` 都不存在。
kmodloader 遍历 `/etc/modules.d/*` 逐个 insmod，**不读 modules.dep**。
这是 OpenWrt 的设计，不是缺陷。验证脚本反过来新增了一条断言：
`/sbin/modprobe` 必须指向 `/sbin/kmodloader`。

### 4. 真机结果（261011-16，sysupgrade -n 全新 overlay）
| 项 | 首次启动 | 重启 |
|---|---|---|
| caldata 预提取 | `[22.0s] pre-extracted 65536 bytes` ✅ | `[18.6s] already present, skip` ✅ |
| `qmi failed` | **0 次** ✅（-12/-14/-15 每次都有） | 0 次 ✅ |
| phy | 2，150s 起来 ✅ | 2 ✅ |
| 信道 | 2.4G ch1 / 5.8G ch149 ✅ | 同 ✅ |
| Oops | 0 ✅ | 0 ✅ |
| `gwrt-verify.sh device` | **FAIL=0 / WARN=1**（仅已知 PPE 时钟噪声） | 同 |

### 交付
`gwrt-261011-16-亚瑟ss-01-{factory,sysupgrade,initramfs,manifest}` + `sha256sums-261011-16`
- sysupgrade sha256 = `cfa5a34c60ed21e7422cdb8a62d9d339e878b6d0118ada303cfd423dbba4ac22`
- factory  sha256 = `d3633bb598f873ea82194c4173a17324149ecb9b57151f67052465fed6906191`
主题版本 1.0-r99。

## 2026-10-17 gwrt-agent 身份碰撞事故 + gecoosac 踢设备恢复
- gwrt-agent 包模板硬编码了主路由真实凭据(device_id/pair_token/local_token/hardware_id)
  → 所有新设备与主路由同身份上报 → 后台只显示一台、SS-01 "消失"。
  修复: 模板删凭据(保留平台级 pair_token); 原 bin 自带 ART 派生身份生成器, 释放即生效;
  shim daemon 补自动注册(新设备先 register 再 report, 否则永远 unknown device)。
  SS-01 新身份: GWRT-e9e1a68057c3b04c4965d40c(已注册+绑定)。
- 踢设备场景消失根因: gecoosac(格物AC, 60650 端口, 含"踢下线")被 34 策略默认关闭。
  修复: gecoosac 移入默认开启清单(两处主题源已同步), 设备已 enable+start。
  下版镜像首刷即有踢设备面板。

## 2026-10-17 晚 agent 架构回归原版 bin（全面体检结论）
- 体检发现：shim daemon 不会处理平台命令(它解析 "action" 而平台发 "kind")
  → issue_local_token/rotate_local_token 永远 "unparsable"、不 ack、平台每次重发。
- 决定性对照：主路由(老树 GWRT 260920-11)一直跑【原版二进制】，后台在线一切正常
  → shim 头注释声称的"契约错配"不成立(或平台已兼容)。
- bin 实测会自行处理 issue_local_token（生成 local_token 存 uci、ack 平台），
  SS-01 的 local_token 已由 bin 生成：a488e4c1...（App 直连 CGI 的凭证就位）。
- 最终架构（与主路由一致）：init.d → /usr/sbin/gwrt-agent.bin 作为 daemon；
  shim(/usr/sbin/gwrt-agent) 保留作 CLI（status/pair/dump），不再做 daemon。
  init.d 改动已回写树（package/gwrt-agent/files/etc/init.d/gwrt-agent）。
- 其余体检结果：内核零错误；内存 291MB/928MB；温度 54.7°C；overlay 8%。
  遗留小项：nfsd instance2 crash loop（未用 NFS，待下版禁用 nfsd 默认自启或修复）。

## 2026-10-18 podman 市场恢复 + 弹窗瘦身（r95）

### 1. 恢复 luci-app-podman-market（源码丢失，从 192.168.9.9 路由器实机完整捞回）
- 新包：`package/gwrt-theme/luci-app-podman-market/`（`1.0-r1`，编译通过）
  - rpcd 后端 `podmanmarket`（list/deploy/update/action/autostart/logs）+ `lib.sh` + `catalog.json`（24 个插件部署指令）+ `catalog.tsv`（源）
  - 视图 `podman-market.js`、25 个插件图标 `/luci-static/podman-market/icons/`
  - `menu.d` / `acl.d` / 空 UCI 配置 `/etc/config/podman-market`
- **故意不强依赖 podman**：未装 podman 时 rpcd 返回 `podman_present=false`，主题 `gwrt.js initPodmanMarketVisibility()` 自动隐藏菜单入口；装了 podman 自动出现。仪表盘容器区图标（`/luci-static/podman-market/icons/`）一并恢复。
- `.config`：`CONFIG_PACKAGE_luci-app-podman-market=y`（podman 本身仍按需选装）

### 2. 弹窗卡顿修复（打开插件显示不全 + 卡）
根源（代码诊断）：`.gwrt-modal` 双层 `backdrop-filter`（overlay blur(3px) 全屏 + box blur(10px)），而仪表盘在弹窗打开时仍每 3s 全量刷新重建 DOM → 每次背后重绘都强制整屏模糊重合成，弱客户端直接卡死感；1120px×88vh 默认窗口在部分屏幕上超出可视区。
修复：
- `cascade.css`：弹窗默认尺寸 1120×88vh → **880px×76vh**；去掉两处 backdrop-filter，遮罩加深至 rgba(5,8,16,.74)；最大化按钮保留，手机 ≤720px 仍全屏
- `index_gwrt.ut`：新增 `window.dashboardPaused` 标志——`gwrtOpenModal` 时暂停 3s 仪表盘轮询并清挂起定时器，`gwrtCloseModal` 时经 `resumeDashboard()` 恢复

主题 `PKG_RELEASE` 94 → 95。产物：`bin/packages/aarch64_cortex-a53/base/luci-app-podman-market-1.0-r1.apk`、`luci-theme-gwrt-1.0-r95.apk`（本树为 APK 格式）。

## 2026-10-18（晚）ss-01 261018-01 v3：三次失败复盘 + 终版交付

### 事故链
1. **v1（刷 9.9 雅典娜，挂机）**：cs-02-gwrt2 配置用标准 ath11k 固件（规范要求 ddwrt）→ radio 全死。用户手动救回（刷回 260920-05）。教训：刷前板卡核实救了命（没刷错变体），但没跑完整交付清单。
2. **v2（ss-01 DTB 7 项 FAIL）**：树根 .config 是 10-11 实验遗留（luci-app-ecm 拖进 21 个 kmod-qca-nss =y）→ NSS/SSDK 模型 DTB → 有线+无线全死。**万幸 gwrt-verify.sh 在交付前拦住，没进真机。**
3. **v3（FAIL=0）✅**：修两处——
   - `ipq6000-re-ss-01.dts` 原来硬编码 `#include "ipq6018-ess-nss.dtsi"`（NSS 模型）→ 用 261011-16 好 DTB 反编译重写为 mainline PPE-DSA 模型（ppe/edma/uniphy×2/cmn_pll 齐，旧版备份 /tmp/dtb-surgery/old-ess-nss-version.dts.bak）
   - 配置回退 261011-08 基线血统 + 去 luci-app-ecm（本树它依赖拖 NSS 栈，与 PPE-DSA 冲突；好固件有 ecm UI 但那是另一棵树的包依赖不同）
   - 补回 38_gwrt-wifi-channel / 39_gwrt-wifi-firstboot（从 261011-16 提取，机型无关，归属主题包）→ 主题 r95→96

### 关键认知
- **树根 .config 不可信**：10-11 后是 NSS 实验版。真基线在 config.ss01-261011-08（但那是另一棵树 qualcommax2 的，本树用会解析成 openwrt_one！）
- **两棵树并存**：本树（mark/immortalwrt，qualcommax）与工作机树（qualcommax2，未挂载）。261011-16 好固件出自后者；ss-01 板 DTS 两树模型不同，本树已修为 PPE-DSA
- 本树 luci-app-ecm 的 DEPENDS 会拖 NSS 栈——要么改包依赖，要么永远不开

### 交付
- `openwrt-rom/jdcloud_re-ss-01/gwrt-261018-01-亚瑟ss-01-{sysupgrade,factory,initramfs,manifest}` + sha256sums ✅
- 内容：podman-market 1.0-r1、luci-theme-gwrt 1.0-r96（弹窗 880×76vh、无毛玻璃、弹窗时暂停轮询、38/39 脚本回归）
- 待办：3.3 真机刷入测试（NAS 网络不可达 3.3，需用户侧刷）
- 9.9 恢复建议：当前 260920-05 是救砖版；podman 5.8.4 二进制已备份 /tmp/podman-keep/podman；若要重刷雅典娜，cs-02-gwrt2 存档已修 ddwrt 固件项，重编后可刷

## 2026-10-20 261018-01 v14 终版交付（亚瑟 ss-01）

### 本轮修复（三连坑）
1. **rust 无底洞**：`ruby` 的 YJIT（Kconfig `depends on BROKEN` + `default y` 隐形生效）→ 拉 rust 从零 bootstrap（1-3h）。另 `CONFIG_PACKAGE_aardvark-dns=m`（podman 残留 =m）也触发 rust/host。
   修复：ruby Makefile 去条件 rust 依赖 + 关 YJIT；aardvark-dns 置 unset。
2. **open-app-filter 下载死锁**：git 源包无 PKG_HASH → download.pl 遇 "x" 直接 die（永不复用已有 tarball）→ 每次重下 GitHub 直到失败。
   修复：`PKG_HASH:<实际 sha256>` 写入 Makefile（dl/open-app-filter-2026.09.24~*.tar.zst = 2f03988a...）。
3. **内核 Image desync（镜像生成失败）**：v13 强制重编 kmod 后，initramfs 内核构建把树内 Image 留成 136MB（含内嵌 rootfs）；Default 的 CopyImage 因 `cmp -s vmlinux` 判定未变而跳过复制 → KDIR/Image 保持 initramfs 版 → FIT 119MB > KERNEL_SIZE 12MB → check-size 删文件 → 构建失败。
   修复：手工恢复普通内核配置（`CONFIG_INITRAMFS_SOURCE=""`）→ 重编 Image（18MB）→ 同步 KDIR/Image → 清 .image_install。FIT 恢复 7MB ✓

### 终版特征（615 包，超基准 261011-16 的 613）
- podman 市场 1.0-r1 + luci-theme-gwrt 1.0-r96（弹窗 880×76vh/去毛玻璃/弹窗暂停轮询/38+39 首启脚本回归）
- **GWRT 艺术字 banner 烤进 ROM**（base-files 模板替换）→ SSH 登录 + failsafe 显示设计版；首启 30_gwrt-banner 再生成动态版
- 用户全量包保留（passwall/openclash/store/bandix/daed/harbor/python3/shadow/tar/xz/htop/lsof/netcat...）
- kmod 一致性核验：nat46.ko（v13 重编 → 08:18 剥离打包 → 镜像）hash 逐一比对 ✅
- gwrt-verify.sh image 模式：**FAIL=0**（WARN=4 与已知好固件同类）
- 模块 ABI 说明：树内核 MODVERSIONS 关闭 → 陈旧模块不会被拒载、会直接崩溃（v3 panic 机理）；本轮全部外部 kmod 重编+核验

### 交付
- `openwrt-rom/jdcloud_re-ss-01/gwrt-261018-01-亚瑟ss-01-{sysupgrade,factory,initramfs,manifest}` + sha256sums-261018-01 ✅
- v3 旧文件已被 v14 同名覆盖（同版本号修复版）

### 真机验收（192.168.3.3 亚瑟，2026-10-20 13:22）
- 串口全程监控：零 panic/Oops（nat46 加载正常=修复验证）；ath11k 固件加载成功
- 网口：lan1-3/wan 全部 PPE-DSA 就绪，lan1 1Gbps link up
- WiFi：GWRT_5.8G_87CC (ch149 HE80，38_gwrt-wifi-channel 生效) + GWRT_2.4G_87CC
- SSH banner：GWRT 设计版动态生成（"GWRT 261018-01 + Theme 1.0-r96 / Model / Source"）
- podmanmarket ubus 检测：podman_present=false → 入口自动隐藏（符合设计）
- 服务全绿：network/dnsmasq/dropbear/uhttpd；overlay 正常
- **结论：261018-01 v14 全功能通过**

## 2026-10-20 真机性能测试（亚瑟 ss-01 @192.168.3.3，261018-01）

### 有线（iperf3）
| 场景 | 结果 |
|---|---|
| NAS↔3.3 同网段直连（上行） | **940 Mbps** |
| NAS↔3.3 直连（下行 -R） | **937 Mbps** |
| 3.3→9.9 穿路由 NAT（正向） | **913 Mbps** |
| 3.3→9.9 穿路由 NAT（反向） | **941 Mbps** |

### 无线（纯 WLAN，独立子网 192.168.88.0/24 + 永久 ARP 绑定，排除同网段双网卡歧义）
| 频段 | 配置 | 协商速率 | 实测吞吐 |
|---|---|---|---|
| 5G | HE80 ch149 | rx 648 / tx 245 Mbit/s | **565 Mbps** |
| 2.4G | **HE20（初版）** | 3.6 Mbit/s (HE-MCS 0) | **437 Kbps** ❌ |
| 2.4G | **HT20（修复后）** | 144.4 Mbit/s (MCS15) | **87.8 Mbps** ✅ |

**2.4G 病根**：HE20 在部分客户端（Intel AX 网卡）速率协商退化到 MCS0，吞吐差 200 倍。
**修复**：`40b_gwrt-wifi-htmode` 首启脚本 —— 仅当 2g 频段为 HE20/HE40 时下调 HT20（不覆盖用户显式 HT*）；5G 保持 HE80。已在真机验证生效。

### NSS / PPE 完整性
- **PPE 硬件加速：完整工作**
  - nftables flowtable `flags offload`，devices = lan1/lan2/lan3/wan/**phy0-ap0/phy1-ap0**（含两个无线口）
  - PPE debugfs：egress port0 2.03M 包/2.8GB、port2 1.07M 包/1.3GB，**drop=0**
  - drop_code：port0/2/5 三端口 "none"（未进 CPU）合计 4.4M 包/5.6GB；仅 937 包/56KB 走 CPU（0.04%）
  - bm（缓冲管理）零丢弃；acl hit 688K / miss 3.7M（硬件 ACL 匹配工作）
- **NSS 加速核心：未启用（有意为之）**
  - 仅 `qca_ssdk` 框架加载；nss_core/nss_dp 无 —— NSS 加速核心与 PPE-DSA 板级模型冲突
    （树内 `ipq6000-re-ss-01.dts` 原硬编码 `ipq6018-ess-nss.dtsi`，已改为 mainline PPE-DSA 模型）
  - 结论：NSS 加速未启用，但 PPE 硬件转发 + nft offload + 硬件 ACL 完整可用，实测满千兆

## 2026-10-20 下午 三连项收尾（主题 r97 / openclash 回升 / br-lan 百兆定位）

### 1. 主题 PPE 修复包 r97 —— 编译 + 真机验证通过
- `make package/gwrt-theme/luci-theme-gwrt/compile` → `bin/packages/aarch64_cortex-a53/base/luci-theme-gwrt-1.0-r97.apk`（3.1MB，12:37）
- scp -O 推 3.3（设备无 sftp-server，必须 scp -O 老协议）→ `apk add --allow-untrusted --no-network` 升级 r96→r97
- 真机 playwright 复验（/tmp/gwrt-live-check.mjs + gwrt-mem.mjs）：
  - 网速-EQoS 卡：gwrtSpeed 13.4KB/s、↓5.7KB/s ↑7.6KB/s ✅（原上下行不显示已修）
  - CPU 负载 9% / 1608MHz ✅（原不显示已修）
  - 概述进度改"使用/总数"：mem 314.8MB/906.2MB(35%)、rootfs 76.7MB/910.4MB(8%)、disk 351.3MB/5.07GB(7%) ✅
  - JS 错误 0 ✅
- 坑：设备 apk 库被挂起的 `apk add`（在拉 downloads.immortalwrt.org 索引，do_sys_poll 卡住）锁死 → 第二次安装报 "Unable to lock database"。杀掉挂起进程后加 `--no-network` 即可（本机包安装不需要远端索引）。

### 2. openclash 版本回升 0.47.156 → 0.48.002
- 根因：本树 feeds/luci 停在 10-02 检出（openclash 最后改动 09-18 = 0.47.156）；上游 master 已到 0.48.002
  （261011-16 好固件出自工作机树，那棵树 feed 是新的，所以它 manifest 是 0.48.002 —— 本树"回退"实为 feed 未更新）
- 修复（最小爆炸半径，不动 feed 里其它本地改动）：
  ```
  git -C feeds/luci fetch origin master
  git -C feeds/luci checkout FETCH_HEAD -- applications/luci-app-openclash
  ```
  → PKG_VERSION=0.48.002，121 文件变更；DEPENDS 与旧版完全一致（无新增依赖）
- 编译：`make package/feeds/luci/luci-app-openclash/compile` → `bin/packages/aarch64_cortex-a53/luci/luci-app-openclash-0.48.002.apk`（8.37MB，13:09，77s）
  - 元数据重扫带起依赖链重打包（luci-base/compat/一堆 kmod 只是重 mkpkg，未碰内核 Image，配置无 out-of-sync）
- 真机：备份 /tmp/openclash.cfg.bak-047156 → apk 升级（db V:0.48.002）→ LuCI openclash 页显示 **v0.48.002、JS 错误 0** ✅
- 注意：bin/packages/luci/ 下仍留 0.47.156 旧 apk，下次全量构建会重生成索引

### 3. br-lan 显示 100Mbit/s —— 物理层问题（本机↔lan1 网线），非固件/桥问题
- br-lan 速率 = 桥内有 link 成员口的最低速率；lan1 当前协商 100M → 桥显示 100M
- 拓扑实锤：`brctl showmacs br-lan` → 本机 eno0 MAC 00:e0:4c:00:c0:b0 学习在 port1 = lan1（直连，非经交换机）
- 双方日志完全对齐（同一次事件）：
  - 本机 journalctl：10:57:27–10:59:08 r8169 连续 7 次 down/up，末次落 **100Mbps/Full** 后至今稳定
  - 路由 dmesg：uptime 4194–4294s（=09:47 启动 + 同窗口）同样 7 次 flap，末次 100Mbps/Full
  - 两端 ethtool 互读对方"仅支持 10/100"（本机明明 advertise 1000、路由也 advertise 1000）→ 协商页交换不完整
- 计数佐证：本机 eno0 rx_missed=467、tx_errors=8；路由侧 rx FCS/align 全 0（错误集中在物理层协商）
- 结论：**网线/水晶头接触不良（千兆需 4 对全通，100M 只用 2 对）** —— 重插或换线后应恢复 1G；
  与 NSS/PPE、DSA、桥配置无关（wan 口一直 1G 正常）。iperf 早间 940Mbps 是 10:57 故障前的 NAS 路径数据。

## 2026-10-20 傍晚 主页"网络接口状态图"按接口数自动均分（r97→r100）+ daed 复查

### 1. 端口条自动适配（用户报：不按设备接口划分网口大小）
改前（1600px 视口实测）：WAN 156 / LAN1-3 各 155（LAN 组内留白 ~190px）/ WiFi 卡 278 —— 宽屏下 LAN 固定 155px 组内剩空、WiFi 翻倍，完全不均分。
- **根因**：≥901px 媒体查询把 `.gwrt-port-group.group-lan .gwrt-port` 写死 `flex:0 0 155px`，组宽却 `flex:1` 拉伸；WiFi 走 `flex:1` → 两组卡片宽度 155 vs 278。
- **修复（index_gwrt.ut + cascade.css）**：
  - 组标签带 `--grp-grow:<组内口数>`（lanOnly.length / wifiOnly.length / wanPorts.length）
  - 新增 `@media(min-width:1241px)`：组 `flex:var(--grp-grow,1) 1 0`、组内卡 `flex:1 1 0;min-width:150px;max-width:none`、wrap `overflow-x:auto`（口多时滚动不裁切）；≤1240px 保留原固定宽+横向滚动不动
  - **r100 结构修正**：WAN 卡原本是条的直接子项，padding/边框(30px) 计在自己份额外 → 比别人宽 30px。改为包进无边框 `.gwrt-port-group.group-wan`（--grp-grow=wan数），和 LAN/WiFi 同规则均分，蓝框样式由 `.gwrt-port-group.group-wan .gwrt-port` 还原
- **真机验证（1600px，wrap 1280）**：r100 = WAN209 / LAN1 209 / LAN2 209 / LAN3 208 / WiFi5G 210 / WiFi2.4G 209 px，全卡均分、顺序 LAN1→3 正确、JS 错误 0
- 迭代记录：r97(原样) → r98(组内均分，WAN 仍 234) → r99(box-sizing 补丁，无效，证明是 flex-basis:0 的 content 语义) → r100(WAN 包组，终版)。产物 `bin/packages/.../base/luci-theme-gwrt-1.0-r100.apk`，3.3 已装
- 遗留观察：首屏 board model 未就绪时端口顺序会短暂按默认倒序渲染（LAN3 在前），board.model 到位后下一刷新自愈；与本修复无关，属既有瞬时态

### 2. daed 复查（用户问：关掉还劫持 DNS 是否已修 + 现在打不开）
- **"关掉仍劫持 DNS"bug：当前 261018-01 已不存在**。历史根因 = corevie fork 的 luci_daed mount 劫持（每次重启往 resolv 叠一层挂载，判重按软链源路径永不命中）；实测本机：
  - `/etc/init.d/` 只有 `daed`（无 luci_daed/corevie 劫持 init）
  - `mount | grep resolv` = 空（无劫持挂载）；`/etc/resolv.conf` 正常 127.0.0.1
  - `/etc/init.d/daed stop` 后连等 60s 进程保持死（看门狗只在 start_service 内触发，stop 不复活）；dnsmasq `server/noresolv` 不被改写；53 端口全程是 dnsmasq
- **"打不开"复查**：`/etc/init.d/daed start` 正常 → Ready、:2023 监听；LuCI `/admin/services/daed` 页面 200（显示 RUNNING，JS 错误 0）；面板 `http://3.3:2023/` 与 `/api/version` 均 200。
  - 注意：`/etc/init.d/daed enabled` = **DISABLED**（34_gwrt-autostart-policy 默认关策略，rc.d 无链接）→ **开机不会自启**；LuCI 里点"启用"才会加 rc.d。当前为手动拉起的 RUNNING 状态

## 2026-10-20 晚 r101：端口条"还是不一样"根因 = CSS 缓存版本号卡在 r97（用户反馈复盘）

### 用户反馈（15:48）与真相
用户报："网络接口状态图 大小还是不一样呀 Wan长过头 lan后面还有个空的 wan不需要搞那么长 主要在 lan里面口多就lan平分大小 如果很多就全部平均"
- 对照历史截图测量：该描述 = **r98/r99 旧布局**（WAN 比 LAN 宽 30px / LAN 组尾空档），r100 早已修复（真机实测 6 卡全部 209px）
- **根因：`header.ut` / `header_login.ut` 里 `cascade.css?v=20261018r97` 从 r97 之后一直没升级** → 浏览器按旧 URL 缓存旧 CSS，r98/r99/r100 三次修复全部加载不到（用户"还是不一样"的直接原因）
- 本地多分辨率复现测试（真实 cascade.css + 模拟 6 口，视口 400→2560px 共 12 档，脚本 /tmp/gwrt-strip-local.{html,mjs}）：
  - ≥1241px：6 卡完全均分（±2px 取整误差），无 LAN 后空档
  - ≤1240px：固定宽滚动布局，WAN 仅比其它宽 1-6px（视觉无差）
  - 结论：任何宽度都不会出现"WAN 长过头 / LAN 后空档"

### r101 修复与产物
- `?v=` → `20261020r101`（header.ut + header_login.ut），PKG_RELEASE 100→101
- 产物：`bin/packages/aarch64_cortex-a53/base/luci-theme-gwrt-1.0-r101.apk`（21:02，3142382B）；已核验包内 header.ut 为新串
- 部署受阻：本机（ChromBox）eno0 = NO-CARRIER（连 3.3 lan1 的网线从 100M 半死 → 彻底断），3.3 不可达；9.x 网段扫描无 GWRT WAN 入口
- 用户侧立即验证：3.3 页面强刷（Ctrl+Shift+R / 手机清缓存或隐私窗口）即可见 r100 均分布局，无需装包
- 后续：网线恢复后 scp r101 到 3.3 安装（apk add --allow-untrusted --no-network），此后普通刷新也能拿到新 CSS

### r101 部署 + 真机验证（21:05 网线恢复后）
- 3.3 恢复可达，scp + `apk add --allow-untrusted --no-network` 安装 r101 ✅（Upgrading 1.0-r100 -> 1.0-r101）
- 设备确认：theme-version=1.0-r101；header/header_login 均 `?v=20261020r101`；HTTP 页面引用新串
- playwright 真机 6 档宽度实测：1600/1440 → 6 卡 209 均分（diff≤2px 取整）；1280 → 198/199；1100 → 固定宽 156/155/150；900/480 → 滚动正常
- 全量文件对比（设备 758 文件 vs 本地包）：除 theme-version（源码占位 1.0-r92，Makefile 构建时重写）外 **0 差异** → 设备上没有"直接改未回落"的内容

### 主题架构（回答用户提问"单独的gwrt还是gwrt+原生"）
- `luci-theme-gwrt` 是**完整独立主题**（依赖仅 luci-base，非 bootstrap 皮肤）：自带 6 个主题模板 + 全量 cascade.css（192KB）接管全部原生 LuCI 页面外观；另捆 GWRT 功能脚本（clients/ota/samba/nfs 等 uci-defaults + hotplug + libexec）
- 固件**同时保留原生 bootstrap**，但只在 **81/444 端口**提供（主端口 80/443 = GWRT）；机制 = `feeds/luci/modules/luci-base/ucode/runtime.uc` 的 GWRT 补丁，按 HTTP_HOST 端口查 `gwrt.theme.port_<port>`（33_gwrt-dual-theme-port 设置 port_81/port_444=/luci-static/bootstrap）
- 首页 dispatcher：`admin_status-index.ut`（33_gwrt-dashboard 安装）—— theme==bootstrap 时渲染原生状态页，否则渲染 GWRT 仪表盘

### 双主题隔离机制核验（回答"两个主题是否隔开"）
- 端口覆盖仅在 HTTP_HOST 带 `:端口` 时触发（runtime.uc 补丁）；80 端口 Host 不带端口 → 永远走全局默认 GWRT
- 81/444 → 查 `gwrt.theme.port_81/444` → 原生 bootstrap ✅（实测 80=gwrt资源、81=bootstrap资源）
- 主题下拉里的 BootstrapDark/BootstrapLight 是**死选项**：bootstrap 包只有 `ucode/template/themes/bootstrap/`，没有 bootstrap-dark/light 模板目录 → trycompile 失败 → runtime 回退链（按 luci.themes 顺序）落到 Gwrt → 主端口视觉不变。**不存在"误切把 GWRT 切走"的口子**
- 对比结论（GL 风格"单入口登录选择" vs 本方案"端口隔离"）：
  - 端口隔离优势：零误切、81/444 天然救援通道（GWRT 改坏可进原生救）、实现简单、缓存隔离、可双开对照
  - 端口隔离劣势：原生入口需记端口、产品感弱、多 2 个监听（可防火墙限内网）
  - 单入口切换优势：体验直觉、高级模式概念清晰、不增端口
  - 单入口切换劣势：切换逻辑是新单点（自锁风险）、救援依赖切换 UI 本身、会话/缓存/dispatcher 复杂度高
  - 建议：保留端口隔离做底座，在 GWRT 界面加"高级模式/原生 LuCI"显眼入口（指向 :81）= GL 实际做法；不建议把唯一切换入口放进 GWRT 页面内部

## 2026-10-20 深夜 原生界面加"双按钮切换"（GWRT 界面 / 原生界面）

### 需求
用户：在原生界面（81/444）上放两个按钮——一个去 GWRT、一个留在原生；登录页 + 顶栏都要。

### 实现（feed 本地修改：luci-theme-bootstrap）
- `header.ut`：原"GWRT"单按钮升级为两按钮组 `[GWRT 界面][原生界面]`（当前侧置灰），仅 81/444 显示；链接保留 path/query/hash
- `sysauth.ut`：登录弹窗顶部加 `[登录 GWRT 界面][登录原生界面]`（当前侧置灰），仅 81/444 显示
- 端口判定/URL 生成用内联脚本（http→80/81，https→443/444）；非 GWRT 构建不受影响（端口守卫）
- 重编 `luci-theme-bootstrap`（版本号不变 26.261.08411~adc898b）→ `apk add --force-overwrite` 装 3.3 + uhttpd 重启

### 真机验证（3.3）
- 登录页 :81：两按钮可见、在登录弹窗内、href 正确 ✅
- 顶栏 :81：两按钮可见、href 保留当前路径 ✅
- 主端口 :80：无按钮、GWRT 不受影响 ✅
- 端到端：:81 登录后点"GWRT 界面" → 落到 :80 GWRT 仪表盘，登录态保持（cookie 跨端口共享）✅

### feed 补丁存档（防 feed 更新覆盖）
- `gwrt-feed-patches/luci-theme-bootstrap-gwrt.patch`（含早期 GWRT 返回按钮 + 本次双按钮）
- `gwrt-feed-patches/luci-base-gwrt.patch`（双主题端口机制 runtime.uc）
- 用法：feed 更新后 `git -C feeds/luci apply ../../gwrt-feed-patches/xxx.patch` 重放

### 备注
- GWRT 侧（80）是否也加"原生界面"入口——用户未要求，可随时加

## 2026-10-20 深夜2 GWRT 登录页也加"双按钮切换"（r102）+ 两侧按钮均可点

### 需求（用户澄清）
上一轮只加了原生侧（81/444）；用户要的是**两边登录页都能选**：80 端口 GWRT 登录位置也要加一个"登录原生界面"按钮，"点那个都可以"（当前侧按钮也要可点）。

### 实现
- `package/gwrt-theme/luci-theme-gwrt/.../themes/gwrt/sysauth.ut`（r101→r102）：
  - 登录卡片 body 顶部加两按钮 `[登录 GWRT 界面][登录原生界面]`（GWRT 侧灰显为当前）
  - 内联脚本：仅 80/443 显示；GWRT 链接=当前页，原生链接=同 host `:81`（https 时 `:444`），保留 path/query/hash
- bootstrap 侧（81/444）：`pointer-events:none` 去掉——当前侧按钮也可点（点自己=刷新），满足"点那个都可以"
- 产物：`luci-theme-gwrt-1.0-r102.apk` + 重编 `luci-theme-bootstrap`；均 `--force-overwrite` 装 3.3 + uhttpd 重启

### 真机验证（3.3）
- GWRT 登录页 :80：两按钮可见、href 正确、两侧 pointer-events=auto（都可点）✅
- 点"登录原生界面" → 落 :81 原生登录页（bootstrap 资源）✅
- 原生登录页点"登录 GWRT 界面" → 回 :80 GWRT 登录页 ✅
- 截图：/tmp/gwrt-live-shots/gwrt-login-switch.png、native-login.png

### feed 补丁已更新
- `gwrt-feed-patches/luci-theme-bootstrap-gwrt.patch`（重新生成，含 pointer-events 变更）

## 2026-10-20 深夜3 按用户要求收窄：原生顶栏恢复原样，只保留"登录时选择"

### 调整
- 用户："原生主题那里显示一个 GWRT 原来已经有了，不需要改动；只是要登陆的时候加入登陆选择即可"
- 还原：bootstrap `header.ut` 恢复原版单按钮 `GWRT`（gwrt-back-link），撤掉双按钮组
- 保留：两边登录页的"登录选择"（GWRT 登录页 r102 + 原生登录页，各两按钮）
- **新发现：源码 .ut 可直接落设备**——ucode 运行时能现场编译源码模板（scp 源文件 + uhttpd 重启即生效），无需等整包编译；本次已用此法即时验证（随后仍重编包保持 apk 库一致）
- 真机验证：原生登录页选择仍在（href 正确）；原生顶栏恢复单"GWRT"按钮；GWRT 登录页选择仍在
- feed 补丁已更新：`gwrt-feed-patches/luci-theme-bootstrap-gwrt.patch`（现仅含：原版返回按钮 + 登录选择）

## 2026-10-21 派生 JDCloud RE-CS-07 配置（config.cs07-261021-01）

### 需求
按 CS 系列的配置风格（参照 `config.cs02-gwrt2-261018-01`）派生一份 cs-07 配置：
插件与 ss-01 保持一致，但去掉 ss-01 的 wifi 驱动，且**按 DTS 判定**（cs-07 本机无射频）。
另按要求去掉 KixDNS。

### 产物
- `config.cs07-261021-01`（8.8k 行 / 332KB）— 新配置
- `gwrt-mk-cs07-config.sh` — 由 `config.ss01-261018-01` 派生该配置的脚本（可重复执行，输出逐字节一致）
- 树根 `.config` 当前 = cs-07 配置（已 `make defconfig` 收敛，二次跑 defconfig 报 "No change"）

### 按 DTS 判定的依据
`target/linux/qualcommax/dts/ipq6010-re-cs-07.dts`：
- **无 `&wifi` 节点** —— ipq6018.dtsi 里 `wifi@c000000` 默认 `status = "disabled"`，cs-07 从不打开
- **无 `&pcie0`** —— 也没有 PCIe 无线（对比 cs-02 有 `pci17cb,1104` = QCN9074）
- 只有 `&switch`（swport1=wan, swport2..4=lan1..3）+ `&edma` + `&usb3` + eMMC(`&sdhc`) + 3 色 LED + reset 键
⇒ 内核里不存在 wifi 平台设备，整套 ath11k/mac80211 栈都不该进固件。

树里 `ipq60xx.mk` 的 cs-07 设备定义已经用 '-' 语法剔除三项默认包：
```
DEVICE_PACKAGES := -ath11k-firmware-ipq6018 -kmod-ath11k-ahb -wpad-openssl
```
defconfig 之后 `tmp/.config-target.in` 里 cs-07 的 select 列表确实**不再含**
`DEFAULT_ath11k-firmware-ipq6018` / `DEFAULT_kmod-ath11k-ahb` / `DEFAULT_wpad-openssl` /
`DEFAULT_ipq-wifi-*`（ss-01 的设备块四个全有）——与 DTS 判定一致。

### 配置差异（相对 config.ss01-261018-01，共 47 行）
**目标板**
- `DEVICE_jdcloud_re-ss-01` → `DEVICE_jdcloud_re-cs-07`
- 掉 4 个 `CONFIG_DEFAULT_*`：`ath11k-firmware-ipq6018` / `ipq-wifi-jdcloud_re-ss-01` / `kmod-ath11k-ahb` / `wpad-openssl`

**去掉的包（25 个）**
- 无线：`ipq-wifi-jdcloud_re-ss-01`、`ath11k-firmware-ipq6018-ddwrt`、`kmod-ath11k`、
  `kmod-ath11k-ahb`、`kmod-ath`、`kmod-cfg80211`、`kmod-mac80211`、`kmod-crypto-ccm/cmac/gcm`、
  `kmod-crypto-michael-mic`、`kmod-qrtr`/`-smd`/`-mhi`、`hostapd-common`、`wpad-openssl`、
  `wifi-scripts`、`wireless-regdb`、`libiwinfo(-data)`、`rpcd-mod-iwinfo`、
  `MAC80211_DEBUGFS`、`MAC80211_MESH`
- KixDNS：`kixdns`、`luci-app-kixdns-lite`、`luci-i18n-kixdns-lite-zh-cn`
- 连带掉：`kmod-thermal`、`kmod-qcom-qmi-helpers`、`ATH_DFS`、`ATH_USER_REGD`、`ATH11K_THERMAL`、
  `CONFIG_DRIVER_11AC_SUPPORT`、`CONFIG_DRIVER_11AX_SUPPORT`

**新增包：0 个** —— 插件（openclash / passwall / homeproxy / store / bandix / daed / samba4 /
nfs / turboacc / podman-market / eqos / upnp / smartdns / aria2 / mini-diskmanager /
route-tool / easytier / harbor-file / oaf / luci-theme-gwrt / luci-theme-bootstrap /
sing-box / xray-core / htop / btop / aria2 等）全部原样继承。

### ⚠ 关键坑：kmod-ath 是 wifi 栈的"根节点"
`kmod-ath11k` 的 `DEPENDS += +kmod-ath`，`kmod-ath` 又 `select PACKAGE_kmod-mac80211`，
于是 mac80211 → hostapd-common / cfg80211 / crypto-ccm|cmac|gcm / wifi-scripts /
wireless-regdb / libiwinfo 全被 `select` 回来。
**只去掉 `kmod-ath11k` 是去不干净的**，必须连 `kmod-ath` 一起去（脚本里已一并处理）。
`libiwinfo` + `rpcd-mod-iwinfo` 仍会被 `luci-mod-dashboard` / `luci-mod-network` /
`luci-mod-status` 强制 select 回来 —— 这两个是纯 ubus/共享库，**不依赖 mac80211**，保留无害。

### 主题包在无 wifi 机器上的行为（已核查，无需改包）
- `38_gwrt-wifi-channel` / `39_gwrt-wifi-firstboot` 首行都是 `[ -x /sbin/wifi ] || exit 0`
  —— cs-07 没有 wifi-scripts，脚本直接退出，不会误操作
- `40b_gwrt-wifi-htmode` 无 radio 时循环体为空，no-op
- `34_gwrt-autostart-policy` 里 `kixdns` 是 `[ -x /etc/init.d/kixdns ]` 判断，不在也不报错

### 内核侧无需改动（已核查）
cs-07 与 ss-01 同属 ipq60xx subtarget，共用 `target/linux/qualcommax/ipq60xx/config-default`：
- `CONFIG_IPQ_CMN_PLL=y`（uniphy0/PSGMII 12GHz 时钟，cs-07 四个 QCA8075 口必需）
- `CONFIG_QCOM_80211AX_PPE=y` + `CONFIG_QCOM_EDMA=y`（本树 GWRT 版 qca_ppe/qca_edma 驱动）
- `CONFIG_QCA807X_PHY=y`（cs-07 的 QCA8075 PHY）、`CONFIG_PINCTRL_IPQ6018=y`
- 升级路径 `platform.sh` 已有 `jdcloud,re-cs-07` → `emmc_do_upgrade`；`02_network` 已有
  `jdcloud,re-cs-07` → lan1/lan2/lan3 + wan（与 DTS 的 swport 标签一致）

### 待办
- 本次只出配置，**未编译**。编译前建议先 `make defconfig` 确认无 out-of-sync
- 刷机前注意：cs-07 的 `DEVICE_PACKAGES` 只出 `sysupgrade.bin`（**无 factory.bin**），
  与 ss-01 不同，升级走 emmc_do_upgrade 的双分区（HLOS / rootfs）

## 2026-10-21 凌晨 daed "退出后是否还劫持 DNS" 回归测试（结论：不存在）

### 背景
用户再问历史 bug（关掉 daed 后 DNS 仍被劫持/断网）。daed 此前处于"Enable 勾选但进程未跑"状态（Enable=UCI 配置项，非开机自启；GWRT 首刷策略默认关 daed 自启）→ 已手动启动。

### 测试方法（3.3 真机 A/B）
- A=daed 运行中 / B=daed 停止，采集：nft 全量 ruleset、mount、/etc/resolv.conf、dnsmasq 上游文件、`uci show dhcp`
- 另测：停止后 60s 复检、kill -9 崩溃场景（procd 重启）

### 结果
- nft：A/B **规则结构完全一致**（去计数器 diff 为空；唯一规则是系统自带的 `DNSMASQ HIJACK` redirect→:53，属 OpenWrt dns_redirect=1，与 daed 无关）
- mount / resolv.conf / dnsmasq 上游 / dhcp uci：A/B 全部一致，无任何挂载或配置改写
- 53 端口全程 dnsmasq；daed 只监听 :2023
- 停止后 60s daed 保持死（不复活）；kill -9 后 procd 自动重启（预期行为）
- 各状态下解析均正常（nslookup 127.0.0.1、ping 域名）
- `/etc/init.d/` 只有 `daed`（无 corevie fork 的 luci_daed mount hijack init）；luci-app-daed JS 无 resolv/mount 操作

**结论：历史"关掉仍劫持 DNS"bug 在当前固件（261018-01）不存在** —— 停/崩 daed 都不影响 DNS（dnsmasq 继续服务）。

### 附：daed 自启说明
- LuCI daed 页的 Enable 勾选 = `daed.config.enabled`（配置项），**不等于开机自启**
- 开机自启 = `/etc/rc.d/S99daed`（`/etc/init.d/daed enable` 或 LuCI「系统→启动项」）；GWRT 默认策略关闭（多代理按需开）

## 2026-10-21 凌晨 DNS 急救按钮（一键清理插件退出后的 DNS 残留，r102→r103）

### 需求
用户：DNS/代理插件退出后常打不开网页；要一个"清理恢复 DNS"的一键按钮。

### 实现（主题包新增）
- `root/usr/libexec/gwrt-dns-rescue`（核心脚本）：
  1. 卸载 /etc/resolv.conf、/tmp/resolv.conf 上的劫持挂载（corevie 类老 bug）
  2. 恢复 /etc/resolv.conf → /tmp/resolv.conf 符号链接（被换成普通文件也能修）
  3. 清理 dnsmasq 插件残留：`server=127.0.0.1#非53` 删除 / `noresolv=1` 且无上游时关闭 / `resolvfile` 失效时恢复默认 / dnsmasq port≠53 且 53 无监听时恢复 53
  4. 清理 nft 中"53 → 本地死端口"的 redirect/dnat 规则（按 handle 删；系统 DNSMASQ HIJACK → :53 保留）
  5. 重启 dnsmasq + 自检解析，输出 JSON（ok/actions/warnings/test）
- `htdocs/cgi-bin/gwrt-dns-rescue`：CGI，sid（ubus session）鉴权后 exec 脚本（照 gwrt-podman 模式）
- `index_gwrt.ut`：网络区网格新增 "DNS 急救" 图标项（shield-check 图标）→ 确认 → 调 CGI → 结果弹窗（✅动作/⚠️警告/自检）

### 真机验证（3.3；先源码直落快速验证，再重编包装）
- 健康态：无需修复，自检解析正常 ✅
- 故障A（`server=127.0.0.1#7874` + `noresolv=1` → 解析超时）：急救后移除残留、关 noresolv、解析恢复 ✅
- 故障B1（bind-mount 劫持 /etc/resolv.conf）：卸载 1 层挂载 + 恢复内容，解析正常 ✅
- 故障B2（符号链接被换成普通文件）：恢复符号链接，解析正常 ✅
- 故障C（伪造 nft 规则 53→:7999 死端口）：规则被清除，系统 HIJACK→:53 保留 ✅
- UI：playwright 真机点击 → confirm → 结果弹窗"修复完成，DNS 正常 / dnsmasq 已运行 / 自检：解析正常" ✅
- 截图：/tmp/gwrt-live-shots/dns-rescue-ui.png

### 使用方式
- GWRT 仪表盘 → 网络区块 → "DNS 急救"
- SSH：`/usr/libexec/gwrt-dns-rescue`（直接输出 JSON，可脚本化）

## 2026-10-21 凌晨2 修复"daed 反复消失"根因：uci-defaults 在包升级时重跑（r103→r104）

### 现象
用户：daed 又被停了（"刚添加的web点开的又没了"）。实测 daed 未运行、日志被删（stop 流程）、:2023 无监听。

### 根因（实锤）
- `default_postinst`（/lib/functions.sh:382）在**每次包安装/升级**时会把包内 `/etc/uci-defaults/*` 全部 source 执行一遍（执行后删除）
- 主题包 `34_gwrt-autostart-policy` 每次被重跑 → `stop` daed/openclash/passwall/podman/samba4/aria2/nfs/... 并 disable 自启
- 证据：/etc/uci-defaults 目录 mtime = 各次主题包安装时刻（r101/r102/r103），每次装完 daed 就没了
- 同类问题：38/40/40a/40b/41/42/43 重跑会覆盖用户手改（wifi 信道、存储、swap、aria2、samba 共享、nfs 导出）

### 修复（r104）
- 8 个一次性脚本加持久化 once-marker（沿用 35 号脚本的 `/etc/gwrt/*.once` 惯例）：
  34=autostart-policy / 38=wifi-channel / 40=storage-setup / 40a=swap-setup / 40b=wifi-htmode / 41=aria2-setup / 42=samba-setup / 43=nfs-setup
- 首刷（恢复出厂）：marker 不在 → 正常跑一次并落 marker；升级重装：marker 在 → 跳过
- 设备侧已补建对应 marker，daed 已重启恢复运行

### 验证
- 装 r104 后 daed 保持运行（回归验证）
- /etc/gwrt/*.once 保持；wifi 等一次性脚本不再覆盖用户设置

### r104 回归验证（实锤）
- 装 r104 前 daed RUNNING（pid 28577）→ 安装（uci-defaults 重跑，但 34 被 once-marker 拦下）→ 装后 daed **仍是同一进程 28577**，:2023 正常 ✅
- /etc/gwrt/*.once 9 个标记保持；/etc/uci-defaults 已按机制清空
- DNS 正常、主题版本 1.0-r104

## 2026-10-21 cs-07 factory/sysupgrade + cs-02 设备定义修正（含一个实锤 bug）

### 需求
1. cs-07 也要出 factory + sysupgrade（配置写好，编译晚点做）
2. cs-02 的设备定义该怎么写 —— 它有"几个独特的驱动"

### cs-07：补 factory.bin
`target/linux/qualcommax/image/ipq60xx.mk`：
```make
define Device/jdcloud_re-cs-07
	...
	DEVICE_PACKAGES := -ath11k-firmware-ipq6018 -kmod-ath11k-ahb -wpad-openssl
	IMAGES += factory.bin
	IMAGE/factory.bin := append-kernel | pad-to $$$$(KERNEL_SIZE) | append-rootfs | append-metadata
endef
```
与 ss-01 完全同构（FIT 镜像 + 12MB pad + squashfs rootfs + metadata）。
`sysupgrade.bin` 本来就有（`Device/Default` 的 `IMAGES := sysupgrade.bin` + `Device/FitImage`）。

**已验证**（`make -C target/linux/qualcommax/image DUMP=0 -p -n` 展开的规则表）：
```
gwrt-261021-01-qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-sysupgrade.bin
gwrt-261021-01-qualcommax-ipq60xx-jdcloud_re-cs-07-squashfs-factory.bin
gwrt-261021-01-qualcommax-ipq60xx-jdcloud_re-cs-07-initramfs-uImage.itb
KERNEL := kernel-bin | libdeflate-gzip | fit gzip .../image-ipq6010-re-cs-07.dtb   ← CS-07 的 DTS
```
cs-02 / cs-02-gwrt2 也一视同仁补上了 factory.bin（原来只有 sysupgrade）。

### cs-02 的"独特驱动"—— 3 射频 2 套总线
`ipq6010-re-cs-02.dts`：
| 射频 | 总线 | 固件 | 驱动 | board-2.bin | caldata 提取 |
|---|---|---|---|---|---|
| IPQ6018 集成 2.4G+5G | AHB | `ath11k-firmware-ipq6018-ddwrt` | `kmod-ath11k-ahb` | `board-jdcloud_re-cs-02.ipq6018` | 0:ART 0x1000/0x10000 |
| QCN9074 5.2G | PCIe | `ath11k-firmware-qcn9074` | `kmod-ath11k-pci` | `board-jdcloud_re-cs-02.qcn9074` | 0:ART 0x26800/0x20000 |

一个 `ipq-wifi-jdcloud_re-cs-02` 包同时提供**两个** board-2.bin
（`package/firmware/ipq-wifi/Makefile` 的 `ipq-wifi-install-one` 按后缀分派到
`ath11k/IPQ6018/hw1.0/` 和 `ath11k/QCN9074/hw1.0/`）。
另有 2.5G WAN：QCA8081 PHY 走 `&uniphy1`（`CONFIG_QCA808X_PHY=y` 已在 target config 里）。
PCIe 侧内核配置齐备：`PCIE_QCOM` / `PCIE_DW` / `PCI_MSI` / `PCI_QUIRKS` 全部 =y。

### 🔴 实锤 bug：cs-02-gwrt2 的 ddwrt 固件被静默关掉（radio 全死的真因）
`config.cs02-gwrt2-261018-01` 里同一个符号出现了**两次**：
```
2121: CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=y
2346: # CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt is not set
```
`.config` 解析时**最后一条生效** → ddwrt 固件被关 → 设备退回 subtarget 默认的
上游 `ath11k-firmware-ipq6018` → **radio 全死**。
`make defconfig` 不报错、menuconfig 里也看不出，只能靠扫重复符号发现。

**10-18 那份 cs-02-gwrt2 固件的 manifest 实锤**：
```
ath11k-firmware-ipq6018 - 2024.10.14~15f05012-r1     ← 上游，不是 ddwrt
ath11k-firmware-qcn9074 - 20260910-r1
ipq-wifi-jdcloud_re-cs-02 / kmod-ath11k / -ahb / -pci / wpad-openssl ✓
```
对照 10-20 的 ss-01 固件 manifest：`ath11k-firmware-ipq6018-ddwrt - 2026.03.21~e853ab3f-r1` ✓
（ss-01 的配置没这个重复符号，所以是对的 —— 这也解释了为什么只有 cs-02 中招）。

**双保险修复**：
1. **设备定义层**（根治）：cs-02 / cs-02-gwrt2 的 DEVICE_PACKAGES 改成
   ```
   -ath11k-firmware-ipq6018 ath11k-firmware-ipq6018-ddwrt ath11k-firmware-qcn9074 ipq-wifi-jdcloud_re-cs-02 kmod-ath11k-pci
   ```
   `-` 语法会把 subtarget 默认的上游固件剔除，再把 ddwrt 固件 select 进
   `DEFAULT_*`，配置层再也关不掉它。
   defconfig 后 `tmp/.config-target.in` 实测：
   ```
   cs-02      : select DEFAULT_ath11k-firmware-ipq6018-ddwrt / -qcn9074 / ipq-wifi-... / kmod-ath11k-ahb / -pci / wpad-openssl
   cs-02-gwrt2: 同上
   cs-07      : （无线相关一个都没有）
   ss-01      : select DEFAULT_ath11k-firmware-ipq6018 / ipq-wifi-jdcloud_re-ss-01 / kmod-ath11k-ahb / wpad-openssl（未动）
   ```
2. **配置层**：把 `config.cs02-gwrt2-261018-01` 里的重复行删掉（保留 Kernel 段里的 `=y`）。

### 🔴 cs-02-gwrt2 另两个洞（base-files 漏了 gwrt2 变体）
`board_name` 返回 compatible 链的**第一个**，gwrt2 变体是 `jdcloud,re-cs-02-gwrt2`，
所以凡是按 `jdcloud,re-cs-02` 精确匹配的 case 都匹配不上：

1. **`11-ath11k-caldata`**（漏 `jdcloud,re-cs-02-gwrt2`）→ 两套射频的 caldata
   都不提取 → ath11k 首启拿不到 CAL → QMI 超时 → 走 261011-08 那个"半死"路径。
   已补：AHB 段和 QCN9074 段都加上 `jdcloud,re-cs-02-gwrt2`。
2. **`platform.sh` 的 `platform_do_upgrade`**（漏 `jdcloud,re-cs-02-gwrt2`）→ 落到
   `*)` 分支的 `default_do_upgrade`，那是 `mtd write - image`（MTD 路径），
   而 jdcloud 是 **eMMC + BOOTCONFIG/HLOS/rootfs 双分区** → sysupgrade 直接失败。
   已补进 jdcloud 的 `emmc_do_upgrade` 分支。

### 产物
| 文件 | 说明 |
|---|---|
| `config.cs07-261021-01` | cs-07 配置（.config 当前 = 它） |
| `config.cs02-gwrt2-261021-01` | cs-02-gwrt2 配置（固件项已修正，可直接编） |
| `config.cs02-gwrt2-261018-01` | 历史存档，**已修重复符号**（只删/改了那 2 行，feed 漂移未动，保持与已出固件的对应关系） |
| `gwrt-mk-cs07-config.sh` | 由 ss-01 配置派生 cs-07 配置的脚本（末尾自动跑重复符号自检） |
| `gwrt-cfg-dupcheck.sh` | **新增**：.config 重复符号检查器（能提前抓到这类静默关包的坑） |
| `target/linux/qualcommax/image/ipq60xx.mk` | cs-02 / cs-02-gwrt2 / cs-07 的 DEVICE_PACKAGES + factory.bin |
| `.../base-files/etc/hotplug.d/firmware/11-ath11k-caldata` | 补 `jdcloud,re-cs-02-gwrt2`（两处） |
| `.../base-files/lib/upgrade/platform.sh` | 补 `jdcloud,re-cs-02-gwrt2` 到 eMMC 升级分支 |

### 遗留 / 待办
- **ss-01 的设备定义没动**（还是上游 `ath11k-firmware-ipq6018` 默认 + 配置层手动换 ddwrt）。
  ss-01 的配置里没有重复符号，固件是对的（manifest 实锤 ddwrt），但这层依赖配置手动维护，
  建议后续同样在 DEVICE_PACKAGES 里做 `-上游 +ddwrt` 替换；本轮没动是怕影响已验证的 261018-01 产物。
- cs-07 / cs-02-gwrt2 都没编译（用户说晚点编）。编译前建议：
  `sh gwrt-cfg-dupcheck.sh .config` → `make defconfig` → 确认 "No change"。
- cs-07 出的是 `sysupgrade.bin` + `factory.bin` + `initramfs-uImage.itb`，
  升级走 emmc_do_upgrade 双分区（HLOS / rootfs），**factory.bin 是给刷机工具/救砖用的裸镜像**。

## 2026-10-21 cs-02 独特驱动补齐（LED 点阵屏 + QCN9074 ddwrt 固件）

### 需求
cs-02 除了 SS-01 那套 IPQ6018 集成射频，还有**两个 CS-02 独有的东西**：
1. **PCIe QCN9074 5.2G 射频** —— 树里原本只有上游 `ath11k-firmware-qcn9074`，
   真机上用的是 **ddwrt 版**，上游那份在 CS-02 上 radio 全死。
2. **LED 点阵屏**（JDCloud AX6600 "Athena" 前面板）—— **树里完全没有**，
   真机 192.168.9.9 上跑着 `luci-app-athena-led`。

### 从 192.168.9.9 挖出来的信息
设备：`jdcloud,re-cs-02-gwrt2`，GWRT 260920-05，570 个包。
```
ath11k-firmware-ipq6018-ddwrt   2026.03.21~e853ab3f-r1
ath11k-firmware-qcn9074-ddwrt   2026.03.21~e853ab3f-r1   ← 树里没有
ipq-wifi-jdcloud_re-cs-02
kmod-ath11k / -ahb / -pci
luci-app-athena-led             2.2.4-r1                 ← 树里没有
hostapd-common / wpad-openssl
```
`apk info -a` 直接给出了固件来源：
- QCN9074 ddwrt → `https://github.com/VIKINGYFY/ath11k-firmware-ddwrt.git`
- athena-led → `apk info -a` 的 webpage 是空的，但设备上有
  `/usr/bin/athena-led`（Rust 静态 ELF）+ `/etc/init.d/athena_led` +
  `/usr/lib/lua/luci/view/athena_led/`（**Lua 界面**，2.2.x 时代）。
  从二进制里的 `http://app.zichen.zone/api/geoip/api.php` 和
  `Mozilla/5.0 (Athena-LED Router)` 追到上游：
  **`https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller`**
  （= AX6600 固件的作者 ones20250/Openwrt-AX6600 在 Packages.sh 里引的那个仓库）。

### 落到树里的两个新包

**A. `package/ath11k-firmware-qcn9074-ddwrt/`**
```
files/lib/firmware/ath11k/QCN9074/hw1.0/{amss.bin,board-2.bin,fw_version.txt,m3.bin,regdb.bin}
```
- 来源：`VIKINGYFY/ath11k-firmware-ddwrt` commit
  **e853ab3fedec869ca666e871ef4bab41237b09e6**（"Update QCN9074 FW" 2026-03-21），
  和树里已有的 `ath11k-firmware-ipq6018-ddwrt` 同一批 commit（版本串都是
  `2026.03.21~e853ab3f`）。
- **逐字节校验过**：amss.bin / fw_version.txt / m3.bin / regdb.bin 四个文件与
  192.168.9.9 上 `/lib/firmware/ath11k/QCN9074/hw1.0/` 的 sha256 **完全一致**。
- board-2.bin 例外：设备上那个是 `c5d00690…`（131176 字节），
  正好等于树里 `ipq-wifi` 的 `board-jdcloud_re-cs-02.qcn9074` —— 说明运行时
  用的是 ipq-wifi 覆盖后的那份，固件包自带的通用 board-2.bin 被盖掉了。
  这与包里的说明一致（"the per-device calibration comes from ipq-wifi-*"）。
- 注意路径：QCN9074 走 `ath11k/QCN9074/hw1.0/`，和 IPQ6018 的
  `ath11k-firmware-ipq6018-ddwrt` 用的 `IPQ6018/` **不是同一个目录**，
  两个包不会互相覆盖。

**B. `package/gwrt-athena-led/`**（上游仓库 vendor 进来）
```
athena-led/            核心守护进程（Rust, aarch64-musl 静态 ELF）
  files/athena-led     上游 Release v2.4.0 预编译二进制（vendor 进树）
  files/athena_led.init / athena_led.config / find_button.sh
  files/anim/bad-apple.bin
luci-app-athena-led/   LuCI 界面（JS 架构）
  htdocs/.../athena_led/settings.js
  root/usr/share/luci/menu.d/*.json + root/usr/share/rpcd/acl.d/*.json
  po/zh_Hans/athena_led.po
LICENSE
```
两处本地化改动：
1. **不编 Rust**。上游用 Docker 交叉编译产出二进制；本树不引入 Rust 工具链
   （bootstrap 要 1~3 小时，见上面 "rust 无底洞" 那条），直接把上游
   Release v2.4.0 的预编译 tarball（sha256 `243560a5e6bb52e5a…`）解开
   vendor 进 `files/athena-led`。
2. **i18n 目录按本树约定**。本树 LuCI 是 **ucode + JS** 架构，
   翻译目录是 `/usr/lib/lua/luci/i18n`，文件名规则 `<domain>.<lang>.lmo`
   （lang 用 BCP47 别名 `zh-cn`，见 feeds/luci/luci.mk 的
   `LUCI_LC_ALIAS.zh_Hans=zh-cn`）。上游那个包把 .lmo 装成
   `athena_led.zh-cn.lmo` 与 `athena_led.zh_Hans.lmo` **两个后缀**，
   本树照此保留（两种都兼容）。
3. `po2lmo` 来自 `luci-base/host`，必须显式写
   `PKG_BUILD_DEPENDS:=luci-base/host`，否则编译期找不到该命令。

### 硬件对应关系（核对过 DTS）
`athena-led/src/led_screen.rs`：
```
PIN_STB_LEFT = 69   PIN_STB_RIGHT = 70
PIN_CLK      = 73   PIN_DIO      = 74
button gpio  = 71   (--button-gpio 默认值)
```
`ipq6010-re-cs-02.dts` 里的 keys：
```dts
screen { label = "screen"; linux,code = <BTN_1>; gpios = <&tlmm 71 GPIO_ACTIVE_LOW>; };
```
**gpio71 的 "screen" 按键就是 athena-led 的默认按键脚**，两套完全对得上。
CS-07 的 DTS 里**没有** screen 按键、没有 &pcie、也没有 &wifi ——
所以 CS-07 既不该带 athena-led，也不该带任何 ath11k 固件。

### 设备定义改动（target/linux/qualcommax/image/ipq60xx.mk）
```make
# cs-02 / cs-02-gwrt2
DEVICE_PACKAGES := -ath11k-firmware-ipq6018 ath11k-firmware-ipq6018-ddwrt \
                   -ath11k-firmware-qcn9074 ath11k-firmware-qcn9074-ddwrt \
                   ipq-wifi-jdcloud_re-cs-02 kmod-ath11k-pci luci-app-athena-led
```
（上游 QCN9074 固件用 `-` 剔掉换 ddwrt；athena-led 只进 CS-02 两个变体）

### 产物
| 文件 | 说明 |
|---|---|
| `package/gwrt-athena-led/` | athena-led + luci-app-athena-led 两个新包 |
| `package/ath11k-firmware-qcn9074-ddwrt/` | QCN9074 ddwrt 固件包（5 个 blob） |
| `config.cs02-gwrt2-261021-01` | cs-02 配置，9 个无线/屏幕包与真机基准一致 |
| `config.cs07-261021-01` | cs-07 配置（**不含**任何 ath11k/athena 包） |
| `gwrt-mk-cs02-config.sh` | cs-02 配置生成脚本 |

### 待办
- 本轮**只做配置与插件落地，没有编译**（隔壁 pi agent 正在编 ss-01）。
- 编译 cs-02 时注意：上游 `athena-led` 仓库最新 tag 是 **v2.5.0**，
  但 **v2.5.0 没有 Release**（GitHub releases 里最新是 v2.4.0），
  所以 vendor 的是 v2.4.0 的二进制。等 v2.5.0 Release 出了再换。
- 上游 AX6600 固件的 `Config/GENERAL_AX6600.txt` 里写的是
  `CONFIG_PACKAGE_athena-led-control=y` —— 那是 **v2.0.x 的旧包名**，
  v2.3.0 起已拆成 `athena-led` + `luci-app-athena-led`，别照抄那个名字。

## 2026-10-21 上午 ss-01 261021-01 整包编译与交付（含今夜全部修复）

### 编译
- `.config`：ss-01 / 261021-01（存档 `config.ss01-261021-01`；cs-07/cs-02-gwrt2 配置存档保留未动）
- 编译前：`gwrt-cfg-dupcheck.sh` OK（无重复符号）；`make defconfig` = No change
- 命令：`make -j6 V=s`（07:41 启动 → 09:44 完成，约 2 小时；02:30/07:37 两次被终止的编译已作废）
- 日志：`.gwrt-logs/build-ss01-261021-01.log`（零真实错误）

### 自检
- `gwrt-verify.sh image`：**FAIL=0 WARN=4**（与已知好固件同类）
- manifest：`luci-theme-gwrt 1.0-r104` / `luci-theme-bootstrap`（含登录切换）/ `luci-app-openclash 0.48.002` / `ath11k-firmware-ipq6018-ddwrt`（上游已剔除）/ `ipq-wifi-jdcloud_re-ss-01`；共 615 包
- 拆包核对本次改动全部在镜像内：
  - `theme-version=1.0-r104`
  - `/usr/libexec/gwrt-dns-rescue` + `/www/cgi-bin/gwrt-dns-rescue`（DNS 急救）
  - 仪表盘字节码含 "DNS 急救"；GWRT 登录页/原生登录页双按钮都在；原生顶栏恢复原版 `gwrt-back-link`
  - 8 个一次性脚本均含 `.once` 保护（34/38/40/40a/40b/41/42/43）
  - luci-base `runtime.uc` 双主题端口补丁在（`port_` 字符串在）

### 交付
- `openwrt-rom/jdcloud_re-ss-01/gwrt-261021-01-亚瑟ss-01-{sysupgrade,factory,initramfs,manifest}`
- `sha256sums-261021-01` + `sha256sums`，`sha256sum -c` 全 OK

### 本版相对 261018-01 v14 的增量
1. 主题 r104：DNS 急救按钮（挂载/dnsmasq/nft 清理）+ 8 个一次性脚本 once 保护（修 daed 反复被停）
2. 双登录选择：GWRT/原生登录页各两个按钮；原生顶栏保持原版
3. r97-r103 期间：PPE 修复、端口条按接口均分、CSS 缓存串修复
4. openclash 0.48.002
5. （继承 v14）PPE-DSA、2.4G HT20、GWRT banner 等

### 待办
- 真机刷入验证（用户侧或我远程；3.3 当前跑 261018-01 v14）
- cs-07 / cs-02-gwrt2 后续编译（配置已备好；同子目标共享内核，增量编译）

## 2026-10-21 中午 261021-01 真机查 bug（ss-01 @3.3 已刷）+ 三处修复

用户已通过串口刷入 261021-01（3.3；SSH 主机密钥变化属正常）。全面查 bug 结果：

### ① [已修] gwrt-agent payload 非法 JSON —— report 刷屏 "invalid JSON"
- 根因：`payload()` 的 sed `,\?"hardware_id":"[^"]*",\?` 在 hardware_id 位于**中间**时
  把前后两个逗号都吃掉 → `{"device_id":"...""serial":"",...}` 非法 JSON
- 真机实测：jsonfilter + ucode 双验证非法；改为两次替换（各只吃一个逗号）后合法
- 修复：`feeds/base/gwrt-agent/files/usr/sbin/gwrt-agent`（1712-r2 → **r3**）
- 附带：设备上 agent 未在服务端注册（unknown device or token）；跑 `gwrt-agent pair`
  注册后 report 恢复 ok（report_interval=600）✅
- `gwrt-verify.sh` 的 agent 检查改为**行为测试**（抽 sed 表达式，对中间/末尾/开头三种位置
  验证输出），不再依赖字面量 grep（旧检查把新版实现误判为 FAIL）

### ② [已修] 首启 2.4G 停在 HE20（HT20 兼容修复没生效）
- 根因：uci-defaults 在 ~20s 跑，此时 wireless 配置还没生成（phy ~130s 才出现，
  由 39 后台等 phy 后 `/sbin/wifi config` 生成）→ 40b 空跑**却落了 once 标记**
  → 之后再也不会修 → 2.4G HE20（部分网卡协商退化 MCS0）
- 修复（三处）：
  - `39_gwrt-wifi-firstboot`：新增 `fix_htmode_2g()`，在"生成配置后"的两个路径 + 后台等待路径补跑
  - `38/40b`：`seen` 逻辑——只有真的看到目标 radio 才落 once 标记（空跑不落，留给晚到补跑）
- 设备侧已手动修好：2.4G = **HT20** ✅（5G 保持 ch149 HE80）

### ③ [状态问题] gwrt-agent 未注册（unknown device or token）
- 跑 `gwrt-agent pair` 注册成功（bound:false，等用户在服务端绑定）后 report ok

### 版本
- luci-theme-gwrt 1.0-r104 → **r105**（39/38/40b 修复）
- gwrt-agent 1712-r2 → **r3**（JSON 修复）
- 真机复验：`gwrt-verify.sh device` = **FAIL=0 WARN=1**（仅已知 nss_crypto_clk_src）

### 补充：athena-led 界面/翻译的三处修正（2026-10-21 复核）

初版 vendor 的是 v2.4.0 的界面。复核时发现上游自己的 `.po` 与 JS 不同步，
逐条比对后改用 **v2.5.0 的界面（settings.js + .po + menu.d + acl.d）**
配 v2.4.0 的二进制（参数全部兼容，已逐个核对）。

**发现并修掉的上游问题（3 个）**

1. **v2.4.0 的 .po 缺 80 条**。v2.4.0 改了 settings.js 文案但没同步 .po，
   这 80 条在中文界面下全部漏译。v2.5.0 的 .po 已修好（168 条，JS 匹配率 100%），
   所以直接换 v2.5.0 的界面。

2. **po2lmo 会跳过 msgid==msgstr 的条目**（`po2lmo.c:178` `if (key_id != val_id)`）。
   即"未翻译"的条目根本不写进 .lmo —— 这是**设计如此**（运行时回退显示原文），
   不是 bug。v2.5.0 的 .po 里有 6 条这种条目（🌡️ CPU / 🌡️ NSS-Top /
   🌡️ NSS / 🌡️ Wi-Fi PHY0 / 🌡️ Wi-Fi PHY1 / 🌡️ LPASS），已补上中文
   （"🌡️ NSS 温度"之类，硬件专名保留英文）。

3. **⚠ 真 bug：带尾随空格的 msgid 永远查不到译文**。
   运行时查表用 `lmo_canon_hash()`，它会**去掉首尾空白**再算 hash：
   ```
   canon_hash("Channel ")  == sfh_hash("Channel", 7, 7)   ← 尾空格被丢
   ```
   而 po2lmo 写索引用 msgid 的**原始长度**：
   ```
   sfh_hash("Channel ", 8, 8)                             ← 尾空格还在
   ```
   两个 hash 对不上 → 这类词条运行时**永远查不到译文**。
   本次命中 1 条（`"Channel "`），已把 msgid/msgstr 的尾空格去掉，
   并同步改 JS 里 `_('Channel ') + c` → `_('Channel') + c`。

**验证方法**（可复现）：编译树里真实的 `feeds/luci/modules/luci-base/src/lib/lmo.c`，
用 `lmo_open()` + `lmo_canon_hash()` 逐条查表：
```
lmo 条目 167；JS 字面量 169 条 → 命中 169，未命中 0
```
（改造前是 156/169，漏 13 条）

**改动文件**
- `package/gwrt-athena-led/luci-app-athena-led/htdocs/.../settings.js` ← v2.5.0
- `package/gwrt-athena-led/luci-app-athena-led/po/zh_Hans/athena_led.po` ← v2.5.0 + 上述修正
- `package/gwrt-athena-led/luci-app-athena-led/root/usr/share/luci/menu.d/*.json` ← v2.5.0
- `package/gwrt-athena-led/luci-app-athena-led/root/usr/share/rpcd/acl.d/*.json` ← v2.5.0
- `gwrt-fix-athena-po.py` ← 修尾随空格 hash 不一致的工具脚本

**仍未改的**：`athena-led` 核心包仍是 v2.4.0（v2.5.0 没 Release，只有源码，
编 Rust 要 1~3 小时）。界面已是 v2.5.0，两边参数已核对兼容。

## 2026-10-21 下午 ss-01 261021-02 重打包（去 kixdns + GECOOS AC 显示修复 + 上轮修复入包）

### 用户三项要求
1. 重新打包固件（带上 agent JSON / 2.4G HT20 等修复）
2. 去掉 kixdns
3. 查 GECOOS AC 不显示

### GECOOS AC 不显示 —— 根因与修复
- 根因：菜单在 `admin/control` 下（`luci-app-gecoosac` 注册 `admin/control/gecoosac`），
  而仪表盘 `gwrtGridDefs` 只处理 network/services/nas/system/vpn/status/store 等根，
  **control 根被丢**（真机菜单 JSON 实锤有 `admin.control.gecoosac` = "Gecoos AC"，网格里没有）
- 修复（index_gwrt.ut）：
  - `control` 根的子项归入「网络」网格
  - 补 `gecoosac` 图标（AP + 信号波）
- 真机验证：netGrid 出现 "Gecoos AC" ✅（源码热替换验证）

### kixdns 移除
- `.config` 删除：`CONFIG_PACKAGE_kixdns` / `CONFIG_PACKAGE_luci-app-kixdns-lite` / i18n
- defconfig 后确认无 `=y` 的 kixdns（`luci-app-kixdns-lite` 依赖 kixdns，两个一起移除）

### 版本
- 固件：261021-01 → **261021-02**（存档 `config.ss01-261021-02`）
- 主题：r104 → **r106**（r105=once/htmode 修复，r106=control 根 + gecoosac 图标）
- gwrt-agent：r2 → **r3**（JSON 修复）

### daed 显示修复（用户反馈：Enable 勾着但不 RUNNING、无 Web 入口）
- 现象（261021-01 首启后）：daed 未运行、无 rc.d 链接，但 `daed.config.enabled=1`（页面 Enable 勾着）
  → daed 页面显示 NOT RUNNING、没有 "Open Web Interface" 按钮
- 设备侧：`/etc/init.d/daed enable && /etc/init.d/daed start` → **RUNNING + Web 入口恢复** ✅
  （playwright 实测页面："daed RUNNING Open Web Interface"）
- 固件侧（261021-02 起）：`34_gwrt-autostart-policy` 把 daed **移入默认开启名单**（enable + 立即 start），
  首启即 RUNNING + 有 Web 入口；同时从"默认关"名单移除（2026-10-21 用户要求，覆盖 10-03 的默认关决定）

## 2026-10-21 编译速度分析（用户要求"最直接的原因"）

### 实测数据
| 指标 | 数值 |
|---|---|
| 261021-02 全量墙钟 | 11:43 → 14:06 ≈ **2h23m** |
| 其中包编译（260 条 time: 合计） | **90.2 分钟** |
| 其中内核阶段 | **34.3 分钟**（普通 + initramfs 两遍） |
| 最慢包 | samba4 **1196s(20min)** / 主题 320s / uboot-tools 271s / kmod 269s / shadow 200s / ruby 149s |
| 主机 CPU | i7-10610U（4C/8T 低压 U），编译期负载 ~16 |
| 源码树位置 | **NFS**（192.168.9.242，且走 WiFi：1.5ms RTT，864Mbit/s） |
| 小文件 I/O | NFS 写 300 个=1.27s vs 本地 tmpfs=0.01s → **慢 ~127 倍**（4ms/个 vs 0.03ms/个） |
| 同编译对比 | 小文件编译 50 次：NFS 3.25s vs 本地 2.96s（+10%） |
| 大块吞吐 | NFS 写 76MB/s（读 686MB/s 为缓存） |

### 结论：最直接的两条原因
1. **主机 CPU 弱**：编译占全部时间的 ~87%（内核 34min + 包 90min），CPU 全程跑满（-j6，负载 16）；
   同等工作量在现代桌面/服务器约快 2-3 倍。
2. **树在 NAS（NFS）上**：编译中间产物/rootfs/镜像全走网络，小文件操作慢 127 倍 →
   文件密集阶段被显著拖长：612 包安装 + rootfs 两次 400MB 拷贝 + initramfs 打包 7513 文件 +
   squashfs，从"rootfs 收尾"到出镜像约 70 分钟。
3. 放大因素：内核编两遍（普通 + initramfs 内嵌 400MB rootfs）；每次 make 重扫包元数据（几分钟）；
   配置一改触发大范围重编（samba4 20 分钟这种）。

### 建议（按性价比）
1. **在 NAS 本机编译**（树就在本地盘，零 NFS 延迟）——需 NAS 有 SSH 且 CPU 够强。
2. 或**把树挪到本地 SSD**（本机 /home 只剩 11G；DATA 为 NTFS 不适合编译；需加盘/清空间）。
3. NFS 链路**改有线**（现走 WiFi）。
4. 减少全量重编：固定 .config、多机型共享内核批量出。

## 2026-10-21 gwrt-agent 绑定修复（"获取不到信息绑定"）

### 根因
- 原二进制 `/usr/sbin/gwrt-agent.bin` 自带完整的 **gwrt-pair-v2 配对协议**：
  `pair [--qr]` → claim_token + `gwrt://bind?v=2&device_id=...&claim_token=...` + 二维码
- 但 shim（重写版 `/usr/sbin/gwrt-agent`）的 `pair` 分支把它**覆盖**了，只调用 `/api/agent/register`
  并打印配置里的旧 pair_token → **没有 claim_token、没有绑定 URI** → 用户拿不到绑定信息

### 修复
- shim 的 `pair` 改为转发原二进制：`pair) shift; exec "$ORIG" pair "$@" ;;`
- 真机验证：`gwrt-agent pair` 输出 claim_token + pair_uri ✅；`pair --qr` 输出绑定二维码
- 设备已热更新；gwrt-agent 版本 r3 → **r4**（下次固件带上）

### 绑定方法
- 设备上运行 `/usr/sbin/gwrt-agent pair --qr`，用 GWRT Control App 扫二维码
- 或使用输出的 `gwrt://bind?v=2&device_id=...&claim_token=...` 链接

## 2026-10-21 下午 SS-01 OTA 发布（build 57，小包 patch）

### 背景
- 用户要求推到 GitHub 做 OTA + 清掉旧包（设备提示的旧包 260824-56）
- 全量固件 121MB 上传失败（fake-IP 代理下 uploads.github.com 连接重置 / 408 超时）
- 改用**小包 OTA**（patch 类型，199KB）

### 发布内容
- Release：`gwrt-v261021.57`（标题 GWRT 261021-02，已设 Latest）
- Asset：`gwrt-ota-ss01-57.tar.gz`（199,296 B，sha256 `92a046a150d7e4e283d67eaa78dccab3561918bfaca3767a6e4ee49bf50f78b3`）
- 包内容（全部通过设备端白名单校验）：
  - `etc/uci-defaults/{34,38,39,40b}_gwrt-*`（once 保护 + 39 fix_htmode_2g + 38/40b seen 逻辑）
  - `usr/libexec/gwrt-ota`（白名单扩展 `www/cgi-bin/*` + `usr/sbin/gwrt-agent`，供后续 OTA 带 agent/cgi）
  - `usr/libexec/gwrt-dns-rescue`
  - `usr/share/ucode/luci/template/admin_status/index_gwrt.ut`（DNS 急救 + Gecoos AC）
  - `usr/share/ucode/luci/template/themes/gwrt/*.ut`（含双登录按钮）
  - `usr/share/ucode/luci/template/themes/bootstrap/{sysauth,header}.ut`（原生登录切换）
  - `www/luci-static/gwrt/css/cascade.css` + `resources/*`
- 设备清单 `gwrt-ota/stable/devices/jdcloud_re-ss-01.json`：替换旧 260824-56 → **build 57**
- 提交方式：`git push` 被 gitconfig 的 ghproxy.net `insteadOf` 劫持 → 改用 **GitHub Contents API** 提交（commit fc1ece1a）

### 验证
- 线上 raw 清单 = build 57 ✅
- 设备 `/usr/libexec/gwrt-ota check` → 显示新包，旧包不再出现 ✅
- 设备 `/usr/libexec/gwrt-ota apply` → 应用成功 → `update:false up_to_date`、`applied_build=57` ✅

### 备注
- agent 的 pair 修复（`usr/sbin/gwrt-agent`）本次不在旧白名单内未随包；白名单已扩展，**下一次 OTA** 可带
- 旧 release `gwrt-v260824.56` 保留（清单不再引用）；GitHub Latest 已是 `gwrt-v261021.57`

## 2026-10-21 下午 OTA build 58（DNS CGI + agent 修复）+ cs-07 编译启动

### OTA 58
- Release：`gwrt-v261021.58`，Asset：`gwrt-ota-ss01-58.tar.gz`（7,887 B，sha256 `9f3f370d...`）
- 内容（3 个文件，全部通过设备端白名单）：
  - `www/cgi-bin/gwrt-dns-rescue`（DNS 急救 CGI —— 上一版漏了它，按钮点了没反应）
  - `usr/sbin/gwrt-agent`（pair 修复：转发原二进制恢复 gwrt-pair-v2）
  - `usr/libexec/gwrt-ota`（白名单目录扩展 www/cgi-bin、usr/sbin）
- 清单 build 57 → **58**（API 提交 cd20ff45）
- 设备验证：check 显示 58 → apply 成功 → **DNS CGI ✅ + agent pair 修复 ✅** → up_to_date（applied_build=58）
  - 备份：/etc/gwrt-ota/backups/20261021-081626

### daed 默认不启动（用户再次确认）
- 树里 `34_gwrt-autostart-policy`：daed 在"必须关"名单（disable + stop），enable 名单不含 daed ✅
- 设备：未运行、enabled=0、无 rc.d 链接 ✅
- cs-07 编译使用同一棵树 → 同样默认不启动 ✅

### cs-07 编译启动
- `.config` 切到 cs-07（版本 261021-01，存档 config.cs07-261021-01；ss-01 的 261021-02 存档已更新）
- `gwrt-cfg-dupcheck.sh` 无重复符号；`make defconfig` 通过
- 日志：`.gwrt-logs/build-cs07-261021-01.log`（内核阶段）

## 2026-10-21 傍晚 cs-07（太乙er1）261021-01 编译与首次交付

### 编译
- `.config` 切到 cs-07（261021-01，存档 `config.cs07-261021-01`；ss-01 存档更新为 defconfig 后版本）
- dupcheck OK、defconfig 通过
- `make -j6 V=s`：**16:10 → 17:00（50 分钟）**——比 ss-01 快得多：只有内核+设备相关部分重编，软件包全有缓存
- 日志 `.gwrt-logs/build-cs07-261021-01.log`，零错误

### 内核差异说明（回答"能不能直接用 ss-01 内核"）
- cs-07 配置剥掉无线 kmod（`kmod-ath11k`/`-ahb` 均 not set）→ 内核 `.config` 里 **0 条 ath11k** → 内核二进制与 ss-01 不同 → **不能复用，必须重编**
- 机制：kmod 包选择经 `package-metadata.pl kconfig` 注入 `.config.override`
- 内核构建目录"一子目标一份"：cs-07 编译已覆盖 ss-01 的内核中间产物（vmlinux/Image 16:58；ath11k .o 已清）
- **已交付的 ss-01 固件不受影响**（FIT 镜像自带内核，独立文件）
- 想避免来回切重编：两机型 kmod 选择统一（cs-07 保留无线 kmod=y，镜像层用 DEVICE_PACKAGES `-` 剔除）

### 验证（拆包）
- CONTROL：`BOARD=jdcloud_re-cs-07` ✅；DISTRIB：`GWRT 261021-01 r0-cb793d3` ✅
- 主题 **r107** / agent **r4**（pair 修复在）/ DNS 急救 libexec+cgi / **kixdns 已移除** / 无 ath11k 模块（符合 cs-07 设计）✅
- manifest：luci-theme-gwrt 1.0-r107、gwrt-agent 1712-r4、luci-app-gecoosac，无 kixdns、无无线包 ✅

### 交付（首次建目录）
- `openwrt-rom/jdcloud_re-cs-07/`：`gwrt-261021-01-太乙er1-{sysupgrade,factory,initramfs,manifest}`
  + `sha256sums-261021-01` + `sha256sums`（`sha256sum -c` 全 OK）

## 2026-10-21 晚 cs-07 挂载/swap/storage 三修（主题 r108）+ 261021-02 编译

### 用户规则（2026-10-21）
- 自动挂载：**只挂"整盘的最后分区"，且必须是 ext4；其它格式一律不挂**
- swap 要能自动启用
- （扩展）storage 不能挑到系统/rootfs 分区

### 真机根因（cs-07 @3.3）
1. `anon_mount=1` 把 p17（`HLOS_1` 内核槽, squashfs）当数据盘挂 → `mount failed (22)` 刷日志
2. p26（GPT 名 `swap`, 512MB）**从未 mkswap**（全零）→ TYPE=swap 探测不到 → swap 没启用
3. `40_gwrt-storage-setup` 的"最大分区"逻辑挑中 **p18（当前 rootfs 槽 2GB）** → storage 指到系统盘
4. 附带发现：`40a` 的 `uci set fstab.@swap[0]=swap` **不会创建新段**（静默失败）→ 即使 swapon 成功也不持久

### 修复（主题 r107 → r108）
- **新增** `etc/hotplug.d/block/14-gwrt-automount`：只挂"整盘最后分区 + ext4"，其余跳过
- **新增** `etc/uci-defaults/45_gwrt-mount-policy`：`anon_mount/anon_swap=0`；停用 stock `15-automount`；
  清理指向非 ext4 的自动挂载条目；once-marker
- **40a_gwrt-swap-setup**：加"GPT 分区名含 swap"探测 + 空白分区 `mkswap`（仅当 blkid 认不出文件系统）；
  fstab 段改用 `uci add fstab swap` + `@swap[-1]`（修复静默失败）
- **40_gwrt-storage-setup**：只认 ext4 + 排除已挂载/系统分区；无 ext4 时 storage 退回 `/mnt/storage`

### 真机验证（cs-07，两次重启）
- swap：p26 mkswap 后**开机自动启用** ✅（swapon -s 512MB）
- p17 报错：**0 条** ✅；挂载只剩 rootfs ✅
- 服务全绿、automount 规则生效（无 ext4 不乱挂）✅

### 编译
- cs-07 版本 261021-01 → **261021-02**（存档 config.cs07-261021-02）
- dupcheck OK、defconfig No change
- `make -j6 V=s` 日志 `.gwrt-logs/build-cs07-261021-02.log`

## 2026-10-21 晚 apk 数据库锁死 bug（真机发现）+ 超时修复

### 现象（用户真机）
```
apk update / apk add podman
ERROR: Unable to lock database: Resource temporarily unavailable
```

### 根因
- 挂起的 `apk add podman`（PID，卡在 `do_sys_poll`）一直占着 apk 数据库锁
- **apk-tools 3.0.5 默认没有网络超时** → 网络慢/不通时 apk 的索引/包下载会无限等待 → 锁永不释放 → 后续所有 apk 命令报 lock 失败
- 侧发现：distfeeds 里 `pon_drivers`/`pon_userspace` 两个仓库在快照服务器上是 **404**（第三方 feed，官方快照不托管）→ 每次索引更新刷 warning

### 修复
- `/etc/apk/config`：`timeout 30`（**语法是空格、无 --、无 =**；带 # 注释可用）
- 主题包新增 `root/etc/apk/config` + `root/lib/upgrade/keep.d/gwrt-apk`（sysupgrade 保留）
- 主题版本 r108 → **r109**
- 3.3 已热更新（杀掉挂起进程 + scp 两个文件）→ `apk update --no-network` / `apk version` 正常

### 待办
- pon_* 404 仓库清理（需改 distfeeds 生成，或首启脚本过滤）
- 下个固件版本带上 r109

## 2026-10-21 深夜 【严重】gwrt-agent 所有设备共享同一身份 + 修复

### 用户发现（"刷机上线是不是随机显示在帐号上还是全部都显示"）
**答案：全部合并成同一台** ✗

### 证据链
- 固件默认配置（`feeds/base/gwrt-agent/files/etc/config/gwrt-agent`）**写死**：
  - `device_id 'GWRT-9219ad6f5d11b7046aaa942d'`（所有设备相同 ✗）
  - `pair_token '99ec5d8f1c980bfe1ef131d6'`（共享）
  - `local_token '13258689...'`（所有设备相同 ✗）
- 实测两台（ss-01 与 cs-07）device_id 完全相同；device_id 与 hardware_id/MAC 无派生关系（纯写死）
- 影响：服务端只有一条设备记录 → 所有刷机设备数据混合；**谁的账号绑定 claim_token，就"拥有"全部设备**
- 另测：随机 pair_token 注册被服务端拒绝（"无法注册一次性绑定码"）→ **pair_token 是服务端强校验的车队钥匙**（设计上共享，保留）

### 修复（gwrt-agent r4 → r5）
- shim 新增 `ensure_device_id()`（daemon 启动时执行）：
  - device_id 为空/等于出厂共享值 → 用 hardware_id（回退 br-lan MAC）派生 `GWRT-<sha256[:24]>`
  - local_token 同步随机化
  - 改完自动 `$ORIG pair` 重新注册（拿新一次性绑定码）
- 固件默认配置：去掉写死的 device_id/local_token（保留 pair_token 共享 + hardware_id 占位）
- 真机验证（cs-07）：`GWRT-9219ad...` → **`GWRT-0af01fb4f298d859d5cbe8a1`**（本机独有）✅；local_token 随机 ✅；重注册 claim_token ✅；`report ok` ✅

### 待办（用户侧）
- 其他已刷机设备（ss-01 等）：更新 gwrt-agent 脚本 + 重启（或等下个固件）；每台会得到自己的 device_id
- 服务端：清理旧的共享设备记录（GWRT-9219ad...），各设备用新 claim_token 重新绑定

### 附：一机一码最终验证（用户确认"应该一机一码"后）
- 决定性测试：自制全新 `device_id` + 全新 `pair_token` 注册 → **服务端接受**（TOFU 首次登记）✅
- 终版逻辑：`ensure_device_id()`（启动时）——为空/共享值 → 生成唯一身份；**换 token 时必须同时换 device_id**（服务端按首次 register 绑定两者，只换 token 会被拒）
- 自愈：`do_report` 遇到 `unknown device or token` → 自动重生身份 + 重注册 + 重试（每次运行一次）
- cs-07 最终身份：`GWRT-0af01fb4f298d859d5cbe8a1` + 唯一 pair_token `560e0593...`；report ok ✅
- 固件默认配置：device_id/pair_token/local_token 全部不内置（仅保留 hardware_id 占位）
