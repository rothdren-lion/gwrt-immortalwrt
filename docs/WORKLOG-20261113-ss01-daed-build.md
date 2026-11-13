# WORKLOG 2026-11-13 — SS-01 替换 HomeProxy、接入 daed 流量修复并恢复云端编译

## 范围与授权

用户在停止旧固件任务后明确要求“把 homepoxy 替换成 daed 然后重新编译”，并确认
使用 GitHub。此次只恢复 SS-01 构建，版本 `261113-04`、`release=false`；其它机型的
任务与路由器不在操作范围。未刷机、重启或修改实机。

隔离树 `/home/godsun/build/gwrt-ss01-daed-github-261113-04`，起点远端 master
`a1ebeec3e6e98f3129fdf046ab6c8b192236b1d9`。物理 SS-01 为 `jdcloud,re-ss-01`，
沿用已核实的 `KERNEL_SIZE=12288k`，成品须标记 **12M**。

## 固件变更

- SS-01 禁用 HomeProxy 及其中文包，启用 daed/LuCI/中文包；保留 PassWall 使用的 sing-box。
- daed `2.1.1-r3` 从固定 wing `dc50308`、core `5db27a0`、BPF headers 提交构建，
  应用 `.9.9` 已验证的当前 control plane 统计读取修复；不再使用未修复的预编译可执行文件。
  所有下载均固定 SHA-256，官方 v2.1.1 前端以确定性 gzip 嵌入。安装版本标记为
  `daed-4d6a433_wing-dc50308_core-5db27a0-gwrt-runtime1`，不包含账号数据库或用户配置。
- 合入此前 SS-01 WAN 时钟候选：GCC 通过名称回退找到 SSDK 的动态 UNIPHY 时钟，
  DTS 删除固定占位；保留 dp2/3/4/5 端口、无线校准和 Mesh 首启策略。
  该修复尚未刷入实机，不能宣称 WAN 卡死已解决。
- 后续 eMMC 固件加入 sgdisk，包括 AN7581/AN7583；此次只编 SS-01。
- 镜像审计增加 daed 修复版本、ARM64 ELF、无 HomeProxy、sgdisk、12M 和 GCC 输入检查；
  CI 在真实内核源码运行 68 项 UNIPHY 回归。
- OAF 规范 overlay 的包 release 与现有安装源对齐为 5，避免 integrate 回退元数据。
  保留 565 项特征库和在线更新，默认 Key 为空；不上传设备私钥、Key 或备份。

## 已完成验证

- 配置、硬件 profile、源码预检、SS-01 校准重启保护、Mesh preset/firstboot/autopair 通过。
  负对照分别重选 HomeProxy、移除 daed、移除 sgdisk，均被配置校验器拒绝。
- 实际 Linux 6.18.62 CCF/GCC/RCG 函数的 68 项回归通过；此前 DTS 编译验证已确认
  GCC 仅保留 XO/sleep 两个输入。完整固件的最终 DTB 仍须云端镜像审计确认。
- 本地仅验证 daed 软件包，未本地编整套固件。直接调用包目标避开本地不完整内核导致的
  无关 GPIO modpost 失败；最终 `daed-2.1.1-r3.apk` 成功生成，core 真实流量单元回归通过。
- 新 ARM64 程序经 qemu 运行，版本、嵌入前端/入口脚本、真实登录/CORS/GraphQL、六项指标、
  5 秒轮询、自定义实例、390px 布局、凭据不落盘通过。
- 本地测试 APK SHA-256：`8855dba6da79fafff87673917111dc4daac40641aa80453c6bc54bddae0a8ddd`。
  这只是本地包验证，不是固件成品；GitHub 构建会独立生成并验证其包与镜像。

技能的旧 preflight 与当前仓库布局不兼容，报告既有 OAF 调试内容及旧路径缺项；未扩改
无关插件。当前仓库 CI 所用 `scripts/gwrt-source-preflight.sh`、硬件 guard 及专项测试
已通过。技能旧 SS-01 6M 记录由用户已核实的物理 12M 布局与仓库设备定义覆盖。

## 交付与验证边界

证据位于 `/home/godsun/build/gwrt-ss01-261113-04/`。源码 `8584a2c1` 已推送 GitHub
master，首次 [运行 43445745283](https://github.com/rothdren-lion/gwrt-immortalwrt/actions/runs/43445745283)
在配置检查失败，未进入编译、未产生固件。原因是 LuCI daed/Aria2 的覆盖 Makefile
遗漏 `call BuildPackage` 扫描标记，冷扫描时 daed 页面和中文包被漏掉；旧本地 feed
已有标记，因此原本地检查未复现。已补齐两个覆盖文件，并将覆盖 Makefile 的扫描
签名纳入 source preflight。使用独立 metadata 目标冷扫描，daed/Aria2 页面和中文
包四项均被真实 `include/scan.mk` 识别；仓库 source preflight 再次通过。
修正后仍只重跑 SS-01 `261113-04`、release=false；当前尚无成品。
等待构建和镜像审计成功，下载并核验哈希后
归档到 `/home/godsun/build/gwrt-releases/` 对应 SS-01 目录，使用带 12M 的交付文件名。
WAN DHCP、LAN/WAN 并发及反复插拔仍需用户刷入后验证，不以源码回归代替实机结论。
