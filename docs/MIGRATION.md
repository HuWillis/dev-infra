# 更换电脑与数据迁移

## 只需重新搭建环境

1. 按 README 安装 Git、Python、PowerShell、Docker；Mac 按 Intel / Apple Silicon 选择安装包。
2. 登录自己的 GitHub 账号，克隆私有仓库。
3. 启动 Docker，再双击 `start.cmd`（Windows）或 `start.command`（Mac）。
4. 在操作台选择当前项目所需的服务。新的 `.env` 会生成新密码，业务项目也要更新连接配置。

无需复制旧电脑的 Docker/WSL 虚拟磁盘、Windows 路径、快捷方式或代理入口 IP。

## 需要保留账号和原有数据

先停业务写入并完成备份，再操作新电脑。代码与数据分开迁移：

| 内容 | 迁移方式 |
| --- | --- |
| `.env` | 通过可信的本地介质或加密方式转移到新仓库目录；不要提交 Git |
| 自定义 `stacks.json`、服务配置 | 提交 Git 前检查是否含个人凭据；新电脑 `git pull` |
| `projects/`、`.runtime/projects/` | 按需私下转移；后者包含项目密码和 SQL |
| MySQL / XXL-JOB | 导出业务库和 `devinfra_xxl_job`，按同版本恢复；同时保留专用用户授权与匹配密码 |
| PostgreSQL | 用 `pg_dump` / `pg_dumpall` 逻辑导出，再在同版本恢复 |
| MongoDB | 用 `mongodump` / `mongorestore`；认证库与账号一起规划 |
| MinIO | 用 S3 客户端或 `mc mirror` 迁移对象，并单独备份用户、策略与桶配置 |
| Elasticsearch | 用 snapshot / restore；仅可重建数据也可从业务源重新索引 |
| Redis | 按需要迁移 RDB / AOF；缓存数据通常可重新生成 |
| Kafka / RocketMQ / RabbitMQ | 优先重建开发 Topic、队列和测试消息；需要保留时遵循对应版本备份流程 |
| Grafana、Seata、Nacos 等 | 先导出必要配置/规则，再按各服务的存储方式迁移；不要假设这些都是无状态的 |

Compose 使用 `dev-infra_*` 命名数据卷，迁移时以 `docker volume ls` 和容器挂载为准。容器内的路径属于 Linux VM，与 Windows/macOS 的源码目录不是一回事。

不要将 Windows 的 WSL VHDX 直接拷到 Mac。跨架构优先使用服务官方的逻辑导出/恢复。裸数据卷备份只适用于已停服务且满足版本/格式兼容的情况；不要在数据库运行时直接复制文件。

## 恢复顺序

1. 在新电脑放好原 `.env`，保持服务版本与旧电脑一致。
2. 先启动数据库和存储，恢复业务数据及必要账号。
3. XXL-JOB 先在共享 MySQL 中恢复完整的 `devinfra_xxl_job` 库，再启动调度中心。脚本遇到已有完整表会保留数据；非空但不完整的结构会报错，不覆盖。
4. 恢复自定义中间件配置，再启动上层控制台和业务项目。
5. 对照操作台检查端口、账号密码，完成实际读写和任务测试后，再处理旧电脑。

`localhost` 是客户端所在机器。容器反向访问本机 Java 服务时，通常使用 `host.docker.internal`；应用需监听可从 Docker 访问的地址。RocketMQ 公布地址、XXL-JOB 执行器、Sentinel transport IP 需要按新电脑重新确认。

`stop` / 本项目的 `Down` 保留数据；不要把 `docker compose down -v` 当作日常停止命令，它会删除数据卷。
