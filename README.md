# dev-infra · 本地开发操作台

面向 Java 全栈与微服务项目的本地 Docker 开发环境。用浏览器按需启动中间件、查看状态和日志、复制端口与账号密码；日常使用只需在操作台点击，不依赖聊天窗口。

**快速导航：** [准备环境](#新电脑准备) · [启动操作台](#第一次启动) · [服务使用说明](SERVICE-GUIDE.md) · [换电脑迁移](docs/MIGRATION.md) · [下载问题排查](docs/NETWORK.md)

## 操作台能做什么

- **按需启停**：单独启动一个服务，或选择项目组合批量启动；自动带起所需依赖。
- **查看连接信息**：本地端口、网页入口、用户名、密码、连接串和项目接入示例集中展示。
- **查看运行情况**：服务状态、操作记录和容器日志直接在页面查看。
- **保留本机数据**：日常停止服务保留数据卷；密码保存在本机，不提交到仓库。
- **跨电脑复用配置**：提供 Windows、Mac 启动入口及数据迁移说明。

## 包含哪些服务

共 19 种服务，按项目需要选择使用：

| 用途 | 服务 |
| --- | --- |
| 关系型与文档数据库 | MySQL、PostgreSQL、MongoDB |
| 缓存 | Redis |
| 消息队列与事件流 | RabbitMQ、RocketMQ、Kafka |
| 注册配置、限流与分布式事务 | Nacos、Sentinel、Seata |
| 搜索与查询管理 | Elasticsearch、Kibana |
| 对象存储与网页代理 | MinIO、Nginx |
| 任务调度 | XXL-JOB |
| 邮件测试与消息管理 | Mailpit、RocketMQ Dashboard |
| 指标采集与看板 | Prometheus、Grafana |

XXL-JOB 复用同一个 MySQL 容器，使用独立数据库与账号，不额外部署 MySQL。

## 新电脑准备

| 依赖 | Windows | macOS |
| --- | --- | --- |
| Git | 安装 Git for Windows | 安装 Git / Xcode Command Line Tools |
| Python | Python 3.10+，建议 3.12；启用 PATH 或 Python Launcher | Python 3.10+，建议 3.12；确保 `python3` 可用 |
| PowerShell | 推荐 PowerShell 7；也支持系统 PowerShell 5.1 | 安装 PowerShell 7，确保 `pwsh` 可用 |
| Docker | Docker Desktop（Linux 容器）或 Rancher Desktop（Moby，关闭不需要的 Kubernetes） | 对应芯片版本的 Docker Desktop，或 Rancher Desktop 的 Moby 引擎 |

安装指引：[Python](https://www.python.org/downloads/)、[PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)、[macOS PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)、[Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/)、[Rancher Desktop](https://docs.rancherdesktop.io/getting-started/installation/)。启动 Docker 后，确认 `docker info` 和 `docker compose version` 正常。

## 第一次启动

仓库已公开，无需登录 GitHub 即可下载。安装好上述依赖并启动 Docker 后，克隆仓库：

```sh
git clone https://github.com/HuWillis/dev-infra.git
cd dev-infra
```

**Windows**：双击 `start.cmd`。如果使用终端，可以运行 `python start.py`。

**macOS**：双击 `start.command`；首次也可在仓库目录运行：

```sh
chmod +x start.command
./start.command
```

启动器首次自动生成本机 `.env` 随机密码，随后在后台启动操作台，并打开 <http://127.0.0.1:17860/>。以后直接双击同一个入口即可。若该端口属于另一份环境，启动器会明确提示；可以用 `python start.py --port 17861`（Mac 用 `python3`）启动另一份页面。不要同时用两份目录控制同一个 `dev-infra` Compose 项目。

中间件首次使用才下载镜像。MinIO 从固定官方源码构建，Sentinel 下载官方 JAR 构建，首次启动较慢；需要能访问 GitHub、Docker 仓库和 Go 模块仓库。8 GB Docker 内存适合按项目启用，不建议一次开齐所有服务。

## Mac 芯片兼容说明

默认 `.env` 为 `DOCKER_PLATFORM=linux/amd64`。Intel/AMD 电脑直接运行；Apple Silicon 使用容器运行时的 AMD64 仿真支持，以兼容这套固定版本中的镜像。仿真会增加启动时间和内存开销，首次启动超时可用 `pwsh -File ./infra.ps1 Up -Stack base -WaitTimeout 600`。

当前默认采用 AMD64 兼容方案。确需原生 ARM 时，先逐个确认所需镜像支持 ARM64，再调整对应服务的平台配置。Windows 已实测部分服务的启动、认证和健康状态；Windows、Mac、Linux 的脚本与控制台测试均已通过自动检查。完整服务及业务项目接入仍需在目标电脑上验证。

## 日常使用与迁移

- [服务端口、账号、依赖和项目接入](SERVICE-GUIDE.md)
- [更换电脑与数据迁移](docs/MIGRATION.md)
- [镜像下载、EOF 与代理排查](docs/NETWORK.md)
- [MinIO 构建来源与第三方组件](docs/THIRD-PARTY.md)

停止服务保留数据卷。`.env`、运行日志、项目登记、数据库备份和二进制不会进入 Git；GitHub 中的仓库用于复现环境，不包含旧电脑的数据。更新代码前先备份重要数据，在仓库目录 `git pull --ff-only`，重新运行启动器补齐缺失配置；已有密码保留。

可选命令行（Windows PowerShell 5.1 可用 `powershell` 代替 `pwsh`）：

```sh
pwsh -File ./infra.ps1 Up -Stack base
pwsh -File ./infra.ps1 Up -Services elasticsearch,rocketmq,mongodb
pwsh -File ./infra.ps1 Doctor
pwsh -File ./infra.ps1 Down
```

## 自动检查与验证范围

[自动检查记录](https://github.com/HuWillis/dev-infra/actions)覆盖 Windows、macOS、Linux 上的脚本与控制台测试，并在 Linux 验证容器编排配置、构建 MinIO。自动检查不启动整套中间件；Mac 上的实际服务运行情况仍需单独验证。

```sh
python -m unittest discover -s console -p 'test_*.py' -v
pwsh -File ./tests/self-check.ps1
```

仓库是个人本地开发配置，不附带第三方服务的许可证授权；各组件遵循其上游许可证。
