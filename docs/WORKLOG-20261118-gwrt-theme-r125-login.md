# WORKLOG 2026-11-18 — GWRT 登录页直达主题入口

## 1. 任务

用户要求移除单独“登录”按钮，将“GWRT”和“原生”放在登录表单下作为直接登录按钮，避免登录前选择一次、登录后再切换一次。

实机原 `sysauth.ut` 额外注入了一组初始隐藏的“登录 GWRT/登录原生界面”链接；点击只切换地址，之后还要再提交，产生两步操作。源码副本没有这段设备端定制，部署前已对实机文件单独哈希并 diff 检查。

## 2. 实现

两份主题发布版本升至 r125：

- `package/gwrt-theme/luci-theme-gwrt/`
- `gwrt-theme-V3/theme/luci-theme-gwrt/`

登录表单保留用户名和密码输入，把原来的 `Login` submit 改为密码框下两个实际 submit 按钮：

- `GWRT`：提交至当前管理入口，成功后进入原请求路径（80/443）。
- `原生`：提交同一份账号密码到相同 hostname 的原生 LuCI 端口（HTTP 81 / HTTPS 444），成功后由该 LuCI session 直接进入相同管理路径。

提交事件按按钮标记选择目标，不需要登录后再点导航切换。header 与 header_login 中 CSS 缓存号升至 `20261118r125`。两个按钮并排，最小触控高度 48px；密码框按 Enter 默认沿用 GWRT 当前提交目标。

## 3. 验证与部署

证据目录：`/home/godsun/build/gwrt-theme-r125-login-validation-20261118/`。

| 检查 | 结果 |
| --- | --- |
| 表单路由测试 | `scripts/tests/test-gwrt-theme-r125-login.js` 通过：GWRT 当前入口、原生 HTTP 81/HTTPS 444、键盘默认入口及双源码副本 |
| 浏览器预览 | 1440×980 桌面、390×844 手机，两按钮均高 48px 并排、无横向溢出；截图见 `login-browser/` |
| 既有回归 | r121、r122、r123、`test-gwrt-theme-security-ports.js` 通过，`git diff --check` 通过 |
| 实机入口 | `.9.9:81` 与 `:444` 均到达 LuCI 登录门禁 |
| 实机登录页 | 部署后无真实提交地验证两个按钮、r125 CSS 缓存号、旧链接消失和两个最终 form action；桌面/手机通过，截图见 `login-live/`，没有输入或发送凭据 |
| 热更新 | `.9.9` 五文件备份、SHA 基线核对、部署和回读 SHA 完成；只清 LuCI 模板缓存并 reload uhttpd，boot ID 未变 |

设备旧登录模板 SHA-256：`64153ee475ea1301dca329a47d580a96e0e82f3d3c0eee7b63181d5e3ed60c28`。确认它包含的旧预选 UI 未进源树，热更新前已备份以便回滚。

`.8.8` SSH 当前认证失败，本轮没有更新该设备。未构建固件、未推送 GitHub、未刷机或重启路由器。

## 4. 备份与回滚

实机备份 `/root/gwrt-backups/20261118-theme-r125-login-before/`，包含热更新前五文件的 `theme.tgz` 及 `rollback.sh`。执行以下命令恢复设备原主题和两步选择器，并 reload uhttpd：

```sh
sh /root/gwrt-backups/20261118-theme-r125-login-before/rollback.sh
```

源码改前副本与 SHA 在证据目录 `source-before/` 和 `source-before-sha256.json`。源码回滚只撤销本次 r125 登录改动，保留 r124 及并发工作。
