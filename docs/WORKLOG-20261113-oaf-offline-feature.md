# WORKLOG 2026-11-13 — 固定 OAF 特征库并禁用在线更新

## 请求与范围

用户要求把当前固件的OAF特征库同步到GitHub，禁止复制Key，禁止在线更新。
目标仍是 `192.168.9.9` 的RE-CS-02 GWRT2；前序daed流量和OAF接口修复见
`WORKLOG-20261113-daed-oaf-livefix.md`。

仅提取 `/etc/fwxd/feature.bin`，没有把路由器UCI配置、数据库、备份或凭据加入源码。
在设备本地检查账户Key未以明文存在于该文件，检查只输出通过/失败，不输出Key。
FWXB文件格式检查、长度及SHA一致；加载过程独立于账户Key，未复制账户Key。

| 属性 | 值 |
| --- | --- |
| 特征库版本 | 26.11.11 |
| 格式 | v4.0 / FWXB |
| 应用数 | 565 |
| 文件大小 | 31,372字节 |
| SHA-256 | `e06862803f4fa31a87c96715b845da018e91903ececd59fa4305f1409a12146f` |
| 源码路径 | `gwrt-overlays/feeds/packages/net/open-app-filter/files/feature.bin` |

## 源码变更

appfilter及luci-app-oaf包release3→4。包准备阶段验证上述固定SHA，安装时直接使用
仓库内的feature.bin，文件变化纳入包依赖；不再回退安装上游自带48项库。

新增 `101-disable-online-feature-updates.patch`，从oafd链接清单去掉
fwx_feature_online.o，移除在线模块初始化/清理及5个API注册；依赖和链接参数去掉
libcurl。默认fwx配置和init模板不再声明feature_token。

LuCI控制器移除在线配置、保存Key、列表、启动更新和状态的5个路由；页面删除
在线更新标签页、Key输入框、事件/请求/轮询和对应样式。保留特征信息、应用列表、
自定义应用和过滤/流量记录功能。实机现有Key及用户配置保持原样，程序不再读取其
在线更新Key，未把它复制到仓库。

`scripts/gwrt-apply-feed-overlays.sh` 本就递归同步overlay下的文件，因此新增特征库和
补丁将随下一次明确授权的固件构建进入feed；本轮不运行固件构建。

## 本地与实机验证

- 在独立用户态源码副本应用补丁，`patch --fuzz=0`通过；ARM64 musl交叉编译成功。
  检查未strip符号，在线更新入口/初始化与curl符号均未链接。
- 使用包Makefile的实际Prepare/Install定义测试：最终安装的feature.bin SHA正确，
  默认fwx没有token字段；故意指定错误SHA时准备阶段拒绝，负对照通过。
- LuCI模板脚本经替换模板标签后通过 `node --check`，Lua控制器在设备用loadfile
  校验通过。实机musl loader检查依赖完整，`git diff --check`通过。
- 原子替换oafd、init、特征库页面/控制器，清理LuCI索引缓存并只重启appfilter。
  daemon SHA-256：`a548b2f5cfbb49d4b4618deb32f35812a668bad0d96a98f9c36f531a3fae392c`。
- 替换前后8个UCI文件及feature.bin/custom_feature.cfg共10项SHA一致，565应用加载正常。
  没有替换内核、修改ECM加速策略、重启daed或路由器。
- 直接调用get/set_feature_online_config、get_feature_online_list、
  start_feature_online_update、get_feature_online_update_status均返回4000（无该API）。
  没有调用远端更新服务器或测试实际下载。
- 生产浏览器核验：特征页面无在线控件，显示565应用，自定义应用标签可读取；
  概览及5个配置页面、6个正常读取API成功；页面不再请求在线更新API。
  旧在线网址由LuCI回退到普通特征页面（HTTP200/HTML），不会返回在线接口数据。
  OAF客户端、实时应用/流量与应用记录继续有数据，daed同时运行。

此前已发现的手机活跃应用图标行溢出仍保留记录，本轮不改布局，也不声称全部手机
页面无溢出。长期跨重启记录持久化及所有过滤/加速路径未在本轮重新验证。

## 同步与GitHub

工作树 `/home/godsun/build/gwrt-theme-261113`。NAS只选择性同步本轮文件，保留
AGENTS中另一项CS-06日志复核记录，不全量覆盖。

GitHub目标为 `rothdren-lion/gwrt-immortalwrt` 的master。发布基于远端当前master，
只合入前序daed/OAF修复和本次离线特征库变更，不把本地SS-01时钟候选提交一并推送。
发布前审查精确文件清单，不上传设备配置/备份/运行数据库/二进制daemon。

仓库固件workflow只通过显式dispatch/call触发，推送源码不触发固件编译；本轮没有
dispatch、发布固件、刷机或路由器重启。最终远端提交和文件哈希在本地证据目录记录。

## 证据和回滚

本地证据 `/home/godsun/build/gwrt-daed-oaf-livefix-20261113/oaf-offline-20261113/`：
源码副本、构建命令/日志、新daemon、包安装与错误SHA测试、三层禁用检查、浏览器结果、
四文件payload及部署脚本。父目录另存仅特征库文件副本。

远端 `/root/gwrt-backups/20261113-oaf-offline/`：替换前四个程序/页面文件、配置和
特征哈希、API失败检查及 `restore-stopped.sh`。该脚本恢复旧文件后保持OAF停止，
避免回退时自动重新启用旧在线更新能力；如需启动旧版，须另行处理在线更新限制。
未执行回滚。前序备份不变，含Key的路由配置仍只在设备/本地受限目录，未进入GitHub。
