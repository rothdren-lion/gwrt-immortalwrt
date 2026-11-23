# eMMC 存储默认编排（261117）

目标：固件首启后自动使用 eMMC 末尾数据分区，并让 SMB / NFS / Aria2 在“默认关闭、路径已备好、
用户点一下就可用”的状态下交付。本轮只改源码，未编译、未刷机、未连接设备。

## 1. 摘要

- 新增软件包 `gwrt-emmc-storage`，用一个 BusyBox sh 助手统一处理挂载、swap、SMB / NFS / Aria2 路径。
- 旧的 `40/41/42/43_gwrt-*-setup` 与 `90-gwrt-samba-share` 曾各自为政且带破坏性动作，现已全部改为调用该助手。
- 服务仍默认关闭：助手只写路径、目录权限和 UCI 段，不 `enable`、不 `start`。
- NAS 主树已同步 21 个文件并读回校验 SHA；本地测试 18 项（10 + 8）全绿。

## 2. 问题与做法

| 旧行为 | 风险 | 现在 |
|---|---|---|
| 只看“最大的已挂载分区”，不判断磁盘类型 | SD 卡、NVMe 会被误当数据盘 | 仅 `MMC` 且 `removable=0`（eMMC），取磁盘最后一个分区 |
| 写 `gwrt.storage_mount` / `gwrt.downloads_dir` 等无 section 的无效 UCI 键 | 配置永远读不到 | 统一为 `gwrt.storage.{device,mount,downloads}` |
| `42_gwrt-samba-setup` 重置 gwrt 密码并删除所有共享 | 破坏用户配置 | 仅维护 `gwrt_auto=1` 的自有共享，缺失时才创建账号 |
| `43_gwrt-nfs-setup` 写出字段错误的静态 export | 该 export 永远不生效且绕过开关 | 由 `luci-app-nfs` 的 init 按真实字段生成，只导出已启用且已挂载的条目 |
| `90-gwrt-samba-share` 每 5 秒轮询并独立改 UCI | 与首启脚本互相覆盖 | 改为薄封装，统一调用助手（内部持锁） |
| Aria2 默认 `dir=/mnt/sda1/aria2` | 无该目录即启动失败 | 目录落到数据分区 `downloads/aria2`，属主 `aria2`，权限 2775 |

## 3. 关键实现

- `package/gwrt-emmc-storage/files/gwrt-emmc-storage`（239 行）
    - `prepare` 为唯一入口，`flock` 串行化，`init.d`（`START=25` / `STOP=89`）与 block hotplug 都调它。
    - 数据分区：跳过系统分区名，选最后一个分区；已挂载则沿用挂载点，否则 `mount -t <type> -o rw,noatime`。
    - 写 `fstab.gwrt_emmc_data.{target,device,type,uuid,enabled}` 与 `gwrt.storage.*`，建 `downloads`（0775）。
    - swap：只认标签 `swap` / `linux-swap`、GPT 类型 `0657fd6d-a4ab-43c4-84e5-0933c84b4f4f`、MBR `0x82`。
        - 已有签名：直接 `fstab.gwrt_emmc_swap_<dev>.enabled=1` + `swapon`。
        - 无签名且无 `USAGE`、无 holder、未在用时才 `mkswap`，然后同上。探测报错或有其它文件系统一律跳过。
    - Aria2：仅当现有 `dir` 为空、为旧的 `/mnt/sda1/aria2` 或已是目标路径时才接管；`enabled` 保留用户值（缺省写 0）。
    - SMB / NFS：只写路径字段，服务开关留给用户。
- `package/gwrt-emmc-storage/files/89-gwrt-emmc-storage`：`add` 事件 + `mmcblk[0-9]*p[0-9]*` 才触发。
- `gwrt-overlays/feeds/luci/applications/luci-app-nfs/root/etc/init.d/nfs`（新增 75 行）：按 `share.enabled` 生成导出，
    仅导出 `gwrt_auto=1` 且 `uci gwrt.storage.mount/.device` 与 `/proc/mounts` 双匹配的条目；`start/stop` 只管自启的 nfsd。
- `gwrt-overlays/feeds/luci/applications/luci-app-aria2/htdocs/.../view/aria2/config.js`：状态轮询加“启动”按钮，
    点按先 `uci set aria2.main.enabled=1` 再 `rc.init restart`；未启用时提示先启用。
- `gwrt-overlays/feeds/packages/net/aria2/files/aria2.init`：`enabled=1` 且目录存在才启动。
- `scripts/gwrt-apply-feed-overlays.sh`：前置检查加入 `luci-app-nfs`。

## 4. 变更清单（`8be3cbc`，基线 `7774945`，快照 `69c17ff`）

主题两份副本同步改动：`gwrt-theme-V3/theme/luci-theme-gwrt/root/` 与 `package/gwrt-theme/luci-theme-gwrt/root/`
（`40_gwrt-storage-setup`、`41_gwrt-aria2-setup`、`42_gwrt-samba-setup`、`43_gwrt-nfs-setup`、
`hotplug.d/block/90-gwrt-samba-share`）。

新增：`package/gwrt-emmc-storage/`（Makefile + 3 文件）、
`gwrt-overlays/feeds/luci/applications/luci-app-nfs/root/etc/init.d/nfs`、
`scripts/tests/test-gwrt-emmc-storage.py`、`scripts/tests/test-gwrt-nfs-init.py`。

依赖：`package/gwrt-device-defaults/Makefile` → `PKG_RELEASE:=8`，
`DEPENDS:=+jshn +gwrt-wifi-defaults +gwrt-emmc-storage +EMMC_SUPPORT:sgdisk`。

## 5. 验证

- `test-gwrt-emmc-storage.py` 10/10 OK（约 44 s）：真实 BusyBox sh，mock `blkid/mkswap/mount/swapon/uci`，
    覆盖首启单次执行、已有 swap 保留、探测报错不格式化、末尾分区选择、跳过系统分区、跳过 SD 卡、
    有 holder 不动、挂载失败不阻塞、已挂载但服务仍关、自定义设置保留。
- `test-gwrt-nfs-init.py` 8/8 OK（约 1.7 s）：真实 init 脚本 + 内联 `rc.common` stub，
    覆盖关闭不出导出、启用生成 `path clients(options)` 并 `exportfs -r`、`gwrt_auto` 需双匹配、
    未挂载保持私有、拒绝相对/`..`/空格路径、stop 清理、存在外部 `/etc/exports` 时不停服务。
- `sh -n` 三个存储文件 + NFS init + overlay 脚本通过；`node --check` aria2 `config.js` 通过；
  两个测试 `py_compile` 通过。
- NAS 同步：`sync_verified.py` preflight 报 `21 files; no concurrent differences`，
    apply 报 `Synchronized and readback verified: 21 files`。
- `scripts/gwrt-source-preflight.sh` 在本树不可用（缺 `gwrt-theme-V3/scripts/integrate.sh`），改用逐文件检查。

## 6. 未验证

- 未 `make` 编译，未确认 `block-mount` / `swap-utils` / `flock` 在目标机型配置里可解析并进镜像。
- 未上机：真实 eMMC 分区表、已有 ext4 数据是否被正确识别挂载、swap 是否真的启用、
  LuCI 页面按钮与 AriaNg 连接未做浏览器验证。
- `gwrt.storage` 只有助手写、暂无页面读取；旧键（`gwrt.storage_mount` 等）不再写也不再迁移。

## 7. 回滚

- 源码：`git revert 8be3cbc`（或 `git checkout 69c17ff -- <文件>`）。
- NAS：证据目录 `sync-manifest.json` + `originals/` 保留写前副本，可 `python3 sync_verified.py rollback`。

## 8. 后续

1. 目标机型实测：`uci show gwrt.storage`、`/proc/mounts`、`swapon --show`。
2. 需要时在 LuCI 存储页读取 `gwrt.storage.*`，替换旧的无效键读取。
3. 编译验证依赖解析后再决定是否进默认固件。
