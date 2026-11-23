# 2026-11-14 AN7581（an758x）集成 daed + tv-adblock + 主题 r117 并推 GitHub 编译

## 任务

用户要求：“去编译 an7851 序列的固件集成上最新改的 daed 和 tv 广告屏蔽 最新主题推 github 编译”。
即按 `an758x` 预设（AN7581 光猫系列，`DEVICE=all`）出固件，集成最新 daed、`gwrt-tv-adblock`、
主题 r117，并走 GitHub Actions。

## 结论（截至记录时）

- **体积**：不涉及本地全量编译（`/home` 仅剩 21G）；编译全部在 GitHub 私有仓
  `rothdren-lion/gwrt-immortalwrt`。
- **主题与 tv-adblock 无需改动**：出口树 `/home/godsun/build/gwrt-github-export` 的
  `package/gwrt-theme`（`PKG_RELEASE:=117`）、`gwrt-theme-V3/theme`、
  `package/gwrt-tv-adblock` 与最新源码一致（`gwrt-theme-V3/theme` 与打包目录差异仅
  “打包侧多 htdocs/Makefile/root”）。`gwrt-mk-an7581-config.sh` 早已选入
  `gwrt-tv-adblock` + `luci-app-gwrt-tvadblock`。
- **daed 是唯一缺口**：an758x 预设此前没有选 daed，也没有内核 BTF。

## 改动（提交 `c88aae31`，已推送 master）

`gwrt-mk-an7581-config.sh`（an758x 与 an7583 共用）：

1. SSR Plus 循环后新增 daed 选包：
   `daed`、`daed-geoip`、`daed-geosite`、`luci-app-daed`、`luci-i18n-daed-zh-cn`、
   `kmod-sched-bpf`、`kmod-xdp-sockets-diag`（第 249 行起）。
2. 幂等追加内核 BTF（第 261-266 行）：

   ```sh
   CONFIG_KERNEL_DEBUG_INFO_BTF=y
   CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y
   CONFIG_KERNEL_MODULE_ALLOW_BTF_MISMATCH=y
   ```

   原因：`scripts/gwrt-validate-build-config.py:151` 在 `daed` 入包时要求
   `KERNEL_DEBUG_INFO_BTF=y` 或 `vmlinux-btf` 包，否则直接 fail
   （`daed needs kernel BTF or vmlinux-btf`）。本树 `feeds/packages/kernel/vmlinux-btf`
   不存在，`target/linux/airoha` 无 `config-*`，`target/linux/generic/config-6.18:1398`
   默认 `# CONFIG_DEBUG_INFO_BTF is not set`。
3. 头部体积预算注释补 “tv-adblock + daed(含内核 BTF)”。

`.github/workflows/gwrt-build.yml`：依赖安装行补 `dwarves`（pahole），内核 BTF 生成必需。

daed 本体沿用树内定制 overlay `gwrt-overlays/feeds/packages/net/daed`
（`2.1.1-r3`，`DAED_RUNTIME_VERSION:=daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`，
aarch64 源码构建 + `daed-runtime-overview-active-plane.patch` 流量统计修复）。

## 风险与已知限制

- `target/linux/generic/config-6.18` 显式关闭 `NET_CLS_BPF`(4416)、`NET_SCH_INGRESS`(4534)、
  `VETH`(7904)、`XDP_SOCKETS_DIAG`(8323)；由 kmod 包 KCONFIG 在合并时覆盖（与 SS-01 相同路径，
  先例成功）。若本次失败，优先看这几个 kmod。
- arm64 `Image` 不含 `.BTF` 段，因此 BTF 不会明显推高内核镜像；`nokia_xg-040g-md`
  的 `8192k` `KERNEL_SIZE`（`target/linux/airoha/image/an7581.mk:435`）超限风险不大，
  但仍未验证。
- 本地 `make defconfig` 预检不可用：出口树未跑 `scripts/gwrt-apply-feed-overlays.sh`
  与 `feeds install -a`，`feeds/packages/lang/golang` 等缺失导致
  `package/sing-box/Makefile:71` 的 `$(GO_ARCH_DEPENDS)` 展开为空，报
  `tmp/.config-package.in:39432: syntax error` + `toplevel.mk:152：defconfig 错误 1`。
  改为依赖 CI 配置阶段校验。

## 云端运行

- 运行 `43597112397`（master / `c88aae31` / an758x / `261114-02` / release=false），
  触发于 2026-11-14T12:54:44Z。
- “Generate config” 已通过（含 `make defconfig`、`gwrt-check-target.sh an758x`、
  `gwrt-validate-build-config.py`、`gwrt-source-preflight.sh`）。
- 记录时正在 “Build firmware”，尚无成品，未刷机、未操作设备。

## 相关

- daed 实机经验见 `docs/WORKLOG-20261113-daed-oaf-livefix.md`、
  `docs/WORKLOG-20261113-ss01-daed-build.md`。
- AN7581 基线见 `BUILD-NOTES-an7581-261022-01.md`、`docs/WORKLOG-20261111-an7581-overclock.md`。
## 追加（2026-11-15）：261114-03 实际缺 daed，两轮根因修复

### 261114-03 实测结果

- 运行 `43665324627` 成功（21 profile），artifact `14148215337`，1,738,851,803 字节，
  zip sha256 `6c447ba05969a81e98617a0e4913920153590217af5a0bc3d4cf0d9c26753a3d`；
  已下载解压到 `/home/godsun/build/gwrt-releases/an758x-261114-03/out/`。
- 拆包 `gwrt-airoha-an7581-fiberhome_hg5585f-ct-squashfs-sysupgrade.itb`
  （squashfs 偏移 5955584）：
  - 在：`usr/share/gwrt-tv-adblock/ads-library.txt`(14195B)、`lib/modules/6.18.62/act_bpf.ko`、
    `cls_bpf.ko`、`usr/share/rpcd/acl.d/luci-theme-gwrt.json`。
  - 缺：`usr/bin/daed`、`luci-app-daed` 视图/ACL；`lib/apk/db/installed` 无 `P:daed` 条目。
- 因此 “Generate config 通过” 不代表 daed 真的进包：`scripts/gwrt-validate-build-config.py`
  的 daed 校验只在 `.config` 出现 daed 时才触发。

### 根因一：`KERNEL_XDP_SOCKETS` 关闭导致 daed 被静默丢弃（修复提交 `3d5ef936`）

- 本地实验树 `/home/godsun/build/immortalwrt-an7581` 复现：追加 `CONFIG_PACKAGE_daed=y`
  后 `make defconfig`，`.config` 中 daed 相关行**整段消失**（连 `# ... is not set` 都不留），
  同时 `# CONFIG_PACKAGE_kmod-sched-bpf is not set`、`# CONFIG_PACKAGE_kmod-veth is not set`。
- 原因：`tmp/.config-package.in` 中 `config PACKAGE_daed` 有 `depends on KERNEL_XDP_SOCKETS`，
  `daed-geoip`、`daed-geosite`、`luci-app-daed` 同样依赖；`target/linux/generic/config-6.18`
  默认 `# CONFIG_XDP_SOCKETS is not set`，符号不可见即被 defconfig 丢弃。
- 验证：把 `# CONFIG_KERNEL_XDP_SOCKETS is not set` 改为 `=y`（或在文件末尾追加
  `CONFIG_KERNEL_XDP_SOCKETS=y`，kconfig 以后者为准）后，`make defconfig` 保留
  `CONFIG_PACKAGE_daed=y`、`luci-app-daed=y`、`kmod-xdp-sockets-diag=y`。
- 修复：`gwrt-mk-an7581-config.sh` 的 BTF 循环加入 `CONFIG_KERNEL_XDP_SOCKETS`；
  末尾第二个 `make defconfig` 之后新增硬复检，缺 `daed`/`daed-geoip`/`daed-geosite`/
  `luci-app-daed`/`kmod-sched-bpf`/`kmod-xdp-sockets-diag`/`gwrt-tv-adblock`/`luci-theme-gwrt`
  任一或 `CONFIG_KERNEL_XDP_SOCKETS` 非 y 即 `exit 1`。

### 根因二：BTF 依赖 `!KERNEL_DEBUG_INFO_REDUCED`（修复提交 `baee92f1`）

- 修复一推后运行 `43723115049`（`261115-01`）在 “Generate config” 失败，
  日志结尾 `FAIL: daed needs kernel BTF or vmlinux-btf`；新增的核心插件复检与 XDP 检查均已通过。
- 原因：`config/Config-kernel.in:566-575` 的 `KERNEL_DEBUG_INFO_BTF`
  `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED`；airoha 不在
  `KERNEL_DEBUG_INFO_REDUCED` 的 default-n 名单，默认 `=y`，故单独追加 BTF=y 被 kconfig 丢弃。
- 验证：追加 `# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set` + `CONFIG_KERNEL_DEBUG_INFO_BTF=y`，
  `make defconfig` 后得到 `KERNEL_DEBUG_INFO=y`、`KERNEL_DEBUG_INFO_BTF=y`、
  `KERNEL_DEBUG_INFO_BTF_MODULES=y`、`DWARVES=y`、`CONFIG_PACKAGE_daed=y`。
- 代价：关闭 reduced debug info，编译时间与 build_dir 体积略增；最终内核镜像不含 `.BTF` 之外的调试数据。

### 云端运行 `43725738501`（`261115-02`）

- 触发：`device=an758x`、`version=261115-02`、`release=false`，master `baee92f1`。
- “Generate config” 已通过（XDP + BTF + 核心插件复检全过），记录时 “Build firmware” 进行中。
- 监控与后续下载/拆包脚本：`/home/godsun/build/gwrt-releases/an758x-261115-02/monitor.py`
  （等 run 完成 → 取 artifact → 断点续传下载 → 解压 → quick unsquashfs 校验
  `daed_bin`/`daed_ucl`/`daed_init`/`daed_config`/`luci_daed`/`tvadblock_lib`/`theme_acl`/`act_bpf_ko`）。
  状态写入同目录 `monitor-state.json`、`monitor.log`。

### 教训

- OpenWrt 里“配置生成通过 + 跑完编译”不能证明包进了镜像；hidden symbol 被 defconfig 丢弃时
  不留任何痕迹。生成器必须对关键包做 defconfig 后硬校验，交付必须拆包核对
  `lib/apk/db/installed` 与 `/usr/bin/*`。

## 追加（2026-11-16）：BTF 撞磁盘墙 → 拆两组编译，第一组已通过拆包核验

### 运行 `43725738501` 失败真因：运行器磁盘耗尽

- 失败时间线：14:41Z 启动 → 17:53:11Z `##[warning]You are running out of disk space...
  Free space left: 0 MB` → 17:53:42 `ERROR: target/linux failed to build`
  （随后 `-j1` 重试内核编译成功，18:46 产出带 BTF 的 `vmlinux`）→ 19:34 job 失败。
- 对照：不带 BTF 的 `43665324627` 同样 145G 盘、`Avail 104G`，全程无磁盘告警。
  故 `KERNEL_DEBUG_INFO_REDUCED` 关闭（BTF 的硬依赖）带来的内核 DWARF 是新增开销。
- 结论：daed 的 `KERNEL_XDP_SOCKETS` 与 BTF 两处配置本身已正确，卡的是磁盘容量。

### 处置

1. 提交 `a2c71037`（`.github/workflows/gwrt-build.yml`）：`Free disk space` 步骤追加清理
   `/usr/share/swift`、`/usr/lib/jvm`、`/usr/local/share/powershell`、`/opt/az`、
   `/usr/local/.ghcup`、`/usr/local/aws-sam-cli`、`/opt/pipx`、`/usr/share/miniconda`、
   `~/.cache/pip`、`~/.npm`（约 10–15G）。
2. 把 21 个 profile 拆成两组编译，降低单次 build_dir/rootfs 峰值：
   - A 组 11 个（EVB 3、FiberHome 6、gemtek 2）→ 运行 `43754362387`，版本 `261115-02`；
   - B 组 10 个（h3c/nokia/quantum/unionman/znxt）→ 运行 `43771997024`，版本 `261115-03`。
   - 两次都用工作流 `models` 输入限定（`scripts/gwrt-select-models.py`）。

### A 组结果：`43754362387` success（11 profile）

- 步骤：Generate config 通过（XDP + BTF + 核心插件复检）、Build firmware success、
  Verify packages and image hashes success；无磁盘告警。
- artifact `14182171510`，1,168,859,376 字节；已下载解压到
  `/home/godsun/build/gwrt-releases/an758x-261115-02/out/`（11 镜像 + `sha256sums.txt`）。
- 拆包 `gwrt-airoha-an7581-fiberhome_hg5585f-ct-squashfs-sysupgrade.itb`：
  **squashfs 偏移变为 7077888**（带 BTF 后内核变大，旧的 5955584 不再适用；
  用 `python3 -c` 搜 `hsqs` 定位，不要只看前 4MiB），`unsquashfs -o 7077888` 成功：
  - `usr/bin/daed`、`etc/init.d/daed`、`etc/config/daed`、`usr/share/daed/gwrt-runtime-version` 全部存在；
  - marker 内容 `daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`；
  - apk db：`P:daed V:2.1.1-r3 A:aarch64_cortex-a53`、`P:luci-app-daed`、
    `P:kmod-sched-bpf`、`P:kmod-xdp-sockets-diag`、`P:luci-theme-gwrt V:1.0-r117`；
  - `usr/share/gwrt-tv-adblock/ads-library.txt` 14195 字节；
  - `usr/share/rpcd/acl.d/luci-theme-gwrt.json` 存在；
  - `lib/modules/6.18.62/act_bpf.ko` 存在且含 `.BTF` 段（`readelf -S` 命中 BTF）。

### 待办

- B 组 `43771997024`（`261115-03`）编译与下载核验。
- 合并两组 21 个 sysupgrade 到交付目录，按机型重命名并生成 sha256sums。
- 未刷机、未操作设备。

### B 组结果：`43771997024` success（10 profile）与交付

- Generate config / Build firmware / Verify packages and image hashes 全 success，无磁盘告警。
- artifact `14189451546`，1,063,989,283 字节；已下载解压。
- 拆包 `gwrt-airoha-an7581-nokia_xg-040g-md-squashfs-sysupgrade.bin`（squashfs 偏移 **5151744**）：
  `usr/bin/daed`、`etc/init.d/daed`、`etc/config/daed`、`usr/share/daed/gwrt-runtime-version`
  （`daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`）、
  `usr/share/gwrt-tv-adblock/ads-library.txt`、`usr/share/rpcd/acl.d/luci-theme-gwrt.json`、
  `lib/modules/6.18.62/act_bpf.ko` 全部存在；apk db `P:daed`、`P:luci-theme-gwrt V:1.0-r117`。
- 规则库实抽核对：库头 `版本: 20261113-r2 分类条目: tv=218 tv-ext=115 cn=148 sec=79 kill=4`（共 564 条），
  599 行，14195 字节 —— 与仓库 `package/gwrt-tv-adblock/build-ads-library.py` 生成结果一致
  （仓库内 `files/etc/gwrt-tv-adblock/ads-library.txt` 是 13545 字节的签入副本，构建时按分类重新生成）。
- **交付**：`/home/godsun/build/gwrt-releases/an758x-261115/sysupgrade/`
  - 21 个文件，命名 `gwrt-261115-an7581-<device>-sysupgrade.{bin|itb}`（16 个 `.itb` + 5 个 `.bin`）；
  - `sha256sums.txt` 已生成并 `sha256sum -c` 21/21 通过；
  - 按用户策略：an758x 本就没有 factory 镜像，只交付 sysupgrade。
- 镜像体积参考：`fiberhome_hg5585f-ct` 106.8 MB（带 BTF 后比 261114-03 的 82.5 MB 大，squashfs 偏移
  从 5955584 增到 7077888）。
- 清理：分组下载用的 zip 与临时 out/verify 目录已删除，仅保留交付镜像与脚本。
- 仍未刷机、未操作设备。
