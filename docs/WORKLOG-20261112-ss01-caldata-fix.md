# WORKLOG 2026-11-12 — SS-01 校准重启循环修复与 GitHub 编译

## 任务与依据

用户要求修复 SS-01 无法稳定进入系统的问题，并推送 GitHub 编译。
原串口证据见 `WORKLOG-20261111-ss01-boot-loop.md`：固件 `261111-01`
可以启动内核及 shell，`S18gwrt-caldata` 提取 ART 校准后延迟 8 秒请求重启。
重启早于 S95done 的 `mount_root done`，overlay 尚未 READY，下一次启动
fstools 清理 UNKNOWN/PENDING overlay，校准文件与重启 guard 一起丢失，形成循环。

## 修复内容

在隔离工作树 `/home/godsun/build/gwrt-ss01-caldata-261112-01` 延续已开始的修复，
没有提交 NAS 大量无关改动或旧导出树的已暂存文件。

- `target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata`：
  后台等待 `/overlay/.fs_state` 的 readlink 结果为 `2`，再写入
  `/etc/gwrt-caldata-rebooted`、执行 `sync`，最后请求重启。
  每 2 秒检查、最多 180 次；超时、guard 写入失败或 sync 失败均跳过重启。
  保留已有 caldata 和已有重启 guard 的启动分支。
- `scripts/tests/test-gwrt-caldata-reboot.sh`：模拟 overlay 延迟 READY 和始终未 READY，
  检查等待上限、guard 在 sync 前存在、sync 在 reboot 前发生，以及超时不写 guard/不重启。
- `.github/workflows/gwrt-build.yml`：只对 `inputs.device == 'ss01'` 在编译前运行上述测试。

从本地缓存 `fstools-2026.07.25~2aa16407.tar.zst` 读取 `libfstools/overlay.c`
确认 fstools 用符号链接保存数字状态；`mount_root.c` 的 done 分支对 F2FS 设置 READY。
没有依赖网上旧版代码推断状态格式。

## 本地验证与推送

以下检查通过：

```sh
sh scripts/tests/test-gwrt-caldata-reboot.sh
sh -n target/linux/qualcommax/ipq60xx/base-files/etc/init.d/gwrt-caldata scripts/tests/test-gwrt-caldata-reboot.sh
git diff --check origin/master...HEAD
```

本地完整 `sh scripts/gwrt-source-preflight.sh` 在新工作树中因缺少
`feeds/luci/luci.mk` 停止；未通过更新其它脏 feed 来绕过。CI 随后先安装 feeds，
其 `Generate config` 步骤（含 source-preflight）已成功。

修复提交基于远端最新 master `1c417071`，仅包含上述 3 个文件：

```text
5f2947e010c0167e0c63cce43fe1f519f0eb8aa3
fix(ss01): wait for overlay readiness before caldata reboot
```

已推送 `rothdren-lion/gwrt-immortalwrt` 的 master，未强推。
保留 SS-01 现有 NSS 配置 seed、DD-WRT AHB 无线方案与主 HLOS 12 MiB 定义。

## GitHub 编译状态

```sh
gh workflow run gwrt-build.yml -R rothdren-lion/gwrt-immortalwrt --ref master \
  -f device=ss01 -f version=261112-01 -f release=false -f images=flashable
```

- Run：`43058011609`，创建于北京时间 2026-11-12 00:24:27。
- Attempt 1，job `130652597989`：APT 无法解析 azure.archive.ubuntu.com、
  archive.ubuntu.com、security.ubuntu.com，依赖安装 exit 100；未编译固件。
- 原提交通过 `gh run rerun 43058011609 -R rothdren-lion/gwrt-immortalwrt --failed`
  重跑，attempt 2，job `130668654460`，北京时间 00:52:12 开始。
- Attempt 2：依赖、feeds、Generate config、calibration reboot guard 测试均成功；
  北京时间 00:56:53 进入 Build firmware，最后核对仍在编译。
- 镜像哈希、拆包校验、artifact 上传均未完成，不能报告成品成功或实机修复已验证。

后续只需核对本次 run：

```sh
gh run view 43058011609 -R rothdren-lion/gwrt-immortalwrt
gh run view 43058011609 -R rothdren-lion/gwrt-immortalwrt --log-failed
```

## 同步、备份与回滚

NAS 源码已同步启动脚本、回归用例和 workflow 测试步骤；NAS 的其它 workflow 配置
差异保留，实际远端编译以提交 `5f2947e0` 为准。操作前的 NAS 启动脚本、workflow
和 AGENTS.md 保存在 `/home/godsun/build/gwrt-backups/20261112-ss01-caldata/nas-before/`。

若确有需要回退远端，使用 `git revert 5f2947e010c0167e0c63cce43fe1f519f0eb8aa3`
再审查提交；这会恢复已确认有重启循环的逻辑，不应作为设备恢复办法。

未刷机、未主动重启物理 SS-01、未触发其它机型编译。待构建全部检查通过后，
再验收 12M factory/sysupgrade、校准与 guard 跨重启保留、稳定启动、LAN/DHCP 和 Wi-Fi。
