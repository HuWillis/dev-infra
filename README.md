# 全栈开发本地环境

供个人 Java 全栈项目按需使用的 Docker 中间件环境，带独立浏览器操作台。点击启动、停止、查看日志、复制端口/链接/账号密码；关闭聊天窗口不影响使用。

包含 19 种中间件：MySQL、Redis、RabbitMQ、Nacos、MinIO、Elasticsearch、MongoDB、RocketMQ、Nginx、XXL-JOB、Kibana、RocketMQ Dashboard、PostgreSQL、Mailpit、Prometheus、Grafana、Sentinel、Seata、Kafka。XXL-JOB 复用同一个 MySQL 容器，使用独立数据库与账号。

## 新电脑准备

| 依赖 | Windows | macOS |
| --- | --- | --- |
| Git | 安装 Git for Windows | 安装 Git / Xcode Command Line Tools |
| Python | Python 3.10+，建议 3.12；启用 PATH 或 Python Launcher | Python 3.10+，建议 3.12；确保 `python3` 可用 |
| PowerShell | 推荐 PowerShell 7；也支持系统 PowerShell 5.1 | 安装 PowerShell 7，确保 `pwsh` 可用 |
| Docker | Docker Desktop（Linux 容器）或 Rancher Desktop（Moby，关闭不需要的 Kubernetes） | 对应芯片版本的 Docker Desktop，或 Rancher Desktop 的 Moby 引擎 |

安装指引：[Python](https://www.python.org/downloads/)、[PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)、[macOS PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)、[Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/)、[Rancher Desktop](https://docs.rancherdesktop.io/getting-started/installation/)。启动 Docker 后，确认 `docker info` 和 `docker compose version` 正常。

## 第一次启动

先用自己的 GitHub 账号登录 Git，再克隆这个私有仓库：

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

## Intel 与 Apple Silicon

默认 `.env` 为 `DOCKER_PLATFORM=linux/amd64`。Intel/AMD 电脑直接运行；Apple Silicon 使用容器运行时的 AMD64 仿真支持，以兼容这套固定版本中的镜像。仿真会增加启动时间和内存开销，首次启动超时可用 `pwsh -File ./infra.ps1 Up -Stack base -WaitTimeout 600`。

这不是“19 个镜像全部原生 ARM”的承诺。确需原生 ARM 时，先逐个验证所需镜像的 ARM64 manifest，再改平台或单独覆盖服务；不要直接把整套平台改成 ARM64。Windows 的服务运行验证已完成；Mac 的脚本检查由 CI 覆盖，实际 Docker Desktop、芯片和业务 SDK 联调仍需在目标 Mac 上验证。

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

## 验证

GitHub Actions 对 Windows、macOS、Linux 执行脚本与控制台测试，并在 Linux 验证 Compose、构建 MinIO。工作流不启动整套中间件，也不代表全部服务都在 Mac 上通过运行验证。

```sh
python -m unittest discover -s console -p 'test_*.py' -v
pwsh -File ./tests/self-check.ps1
```

仓库是个人本地开发配置，不附带第三方服务的许可证授权；各组件遵循其上游许可证。
