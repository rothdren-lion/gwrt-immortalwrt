# GWRT Control

本目录维护 17.17 服务端更新，基线来自本机已归档 17.16 容器镜像。
不得改动在线服务、账号、数据库或路由器配置；用户自行部署共享目录中的产物。

- `server.py`：Python 标准库 HTTP / SQLite 服务，保留原认证、CSRF 和所有权校验。
- `static/`：原版界面；本轮只改刷新和 Mesh 入口。
- `Containerfile`：继承已归档 17.16；使用 `--pull=never`，不刷新外部依赖。
- `tests/`：临时数据库中的契约测试及隔离浏览器测试，不访问真实云端账号。
- 交付：`\\192.168.9.9\gwrt\gwrt-agent\release-17.17-agent-1712-r7\`。

校验：`python3 -m unittest discover -s gwrt-control/tests -p 'test_*.py' -v`、
`node gwrt-control/tests/test-ui.js`，然后分别构建 amd64 / arm64，再执行 `python3 gwrt-control/tests/smoke-images.py`。
镜像应保留 `/app/data` 卷和既有环境变量；不得烘焙生产密码、会话密钥或数据库。

发布日志见仓库 `docs/WORKLOG-20261107-agent-mesh-refresh.md`。
