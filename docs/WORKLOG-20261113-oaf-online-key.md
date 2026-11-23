# WORKLOG 2026-11-13 — 保留 OAF 在线更新，GitHub 不带账户 Key

## 最终要求

用户澄清：保留在线更新模块、API、页面和可编辑的 Key 输入框；GitHub 不得包含
用户的 Key，其他使用者可以填写自己的 Key 更新。此前禁用在线更新的处理已被
本要求替代，历史记录见 `WORKLOG-20261113-oaf-offline-feature.md`。

目标仍是 `192.168.9.9` 的 JDCloud RE-CS-02 GWRT2，设备板名已通过
`ubus call system board` 核对。固件编译继续停止，不操作 SS-01，不刷机或重启路由器。

## 源码变更

- 删除 `101-disable-online-feature-updates.patch`，恢复上游在线更新模块初始化及
  5 个 API；保留 `100-fwx-only-configuration.patch`，不恢复旧 appfilter 后台接口。
- appfilter 恢复 libcurl 依赖和链接，appfilter/luci-app-oaf release 均从 4 升到 5。
- 从已验证的在线版恢复 LuCI 在线标签页、Key 保存、列表、切换与进度功能。
  在线说明增加自动换行，修复手机端长说明撑宽页面的问题。
- feed overlay 同步脚本明确清理已撤回的 101 补丁，避免复用旧 feed 时残留禁用逻辑；
  保留其他补丁和本地改动。NAS 脚本存在独立差异，只插入本次清理代码。
- 新安装默认 `fwx.global.feature_token` 为空；已安装设备的配置是 conffile，
  本轮保留其本地 Key。没有把设备 UCI、凭据、数据库或备份纳入源码。

内置特征库保持原样，加载不依赖账户 Key：

| 属性 | 值 |
| --- | --- |
| 路径 | `gwrt-overlays/feeds/packages/net/open-app-filter/files/feature.bin` |
| 版本 / 格式 | 26.11.11 / v4.0 FWXB |
| 应用数 / 大小 | 565 / 31,372 字节 |
| SHA-256 | `e06862803f4fa31a87c96715b845da018e91903ececd59fa4305f1409a12146f` |

## 实机部署与验证

恢复已验证、仅统一 fwx 配置的在线版 oafd，无需重新编译；SHA-256：
`8c7db8e92d5071e5615b71df43cde766b1db50d32145aaa8b5e0becc698a3490`。

四文件 payload 仅含 oafd、init、LuCI 特征控制器和模板，不含配置或特征库。
设备检查 musl 动态依赖、Lua 和 shell 语法后，备份并原子替换，只重启 appfilter。
随后单独更新模板的换行样式，无需服务重启。最终模板 SHA-256：
`b779d937ad0250b6ecfbec7142a2b666f3f82782b1d4d8d7485c5624daa479a6`。

- 8 个 UCI 文件及 feature.bin/custom_feature.cfg，共 10 项部署前后 SHA 一致；
  daed PID、程序 SHA 和 boot ID 未变，未修改内核或加速策略。
- get_feature_online_config、缓存列表 refresh=0、更新状态返回成功。
  保存 Key 的接口用数字 token 验证类型拒绝，启动接口用空 id 验证参数拒绝；
  均确认接口已注册，不修改配置、不启动下载。
- 生产浏览器确认 Key 为密码字段、可编辑且保存/更新按钮可用。用合成 Key 测试
  保存、刷新列表与确认切换，所有写入和 refresh=1 请求均在浏览器拦截并模拟响应，
  未把测试 Key 写入设备，也未用用户 Key 请求更新服务器。
- 桌面 1440px 和手机 390px 的在线页无横向溢出，Key/保存/更新控件均可见；
  浏览器无脚本错误和 HTTP 失败。截图遮挡 Key 输入框，结果只记录 Key 是否配置。
- OAF 概览读取成功，565 应用已加载，应用记录 15 条，实时应用/客户端有数据，
  流量曲线 60 个采样点非零；daed 同时运行。只有 fwx ubus 对象，旧对象不存在。
- 使用包 Makefile 实际安装定义核对：特征 SHA 正确，安装配置和 init 默认 Key
  均为空，5 个在线 API 和 curl 符号存在。feed 复用测试确认撤回补丁被删除，
  当前补丁与用户自定义补丁保留；模板 JS、同步脚本语法及 diff 检查通过。

实际联网下载和库切换未测试，以免改变当前库或使用用户订阅 Key。长期记录持久化、
前序记录的概览手机应用图标行溢出不在本轮验证范围。

## 同步、发布与回滚

主工作树 `/home/godsun/build/gwrt-theme-261113`，NAS 按文件选择性同步，
保留独立的 CS-06 日志条目及同步脚本差异。发布工作树基于 GitHub master
`50e7af85` 选择性合入本次修正，不推送本地 SS-01 候选 `7fecca5b`。
发布目标 `rothdren-lion/gwrt-immortalwrt`，推送不触发固件 workflow；不 dispatch。
最终提交、远端特征 SHA 和任务状态记录在本地 `publication.json`。

本地证据：
`/home/godsun/build/gwrt-daed-oaf-livefix-20261113/oaf-online-restore-20261113/`，
包含四文件 payload、部署脚本、包安装检查、浏览器结果和遮挡输入框的截图。
不保存在线配置 API 的原始 Key 响应，不把此证据目录提交 GitHub。

设备备份 `/root/gwrt-backups/20261113-oaf-online-restore/`，含 `before.tgz`、
配置/特征哈希和 `rollback.sh`。需要恢复本轮开始时的离线程序时，在设备执行：

```sh
sh /root/gwrt-backups/20261113-oaf-online-restore/rollback.sh
```

回滚只恢复四个程序/页面文件并重启 OAF，保留配置和特征库；本轮未执行回滚。
