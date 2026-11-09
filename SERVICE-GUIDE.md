# 服务使用说明

安装与启动见 [README](README.md)，数据迁移见 [迁移说明](docs/MIGRATION.md)。

## 服务与端口

下表是默认配置；操作台展示 `.env` 中实际生效的端口和账号。所有地址均为 Windows / macOS 本机 `127.0.0.1`，密码请在操作台查看。

| 服务 | 版本 | 本地端口 / 页面 | 账号与用途 |
| --- | --- | --- | --- |
| MySQL | 8.0.44 | 3306 | `dev` / `root`；开发库 `dev` |
| Redis | 7.4.7 | 6379 | `default` + 密码 |
| RabbitMQ | 3.13.7 | AMQP 5672；[管理页面](http://127.0.0.1:15672/) | `dev` |
| Nacos | 2.4.3 | [控制台](http://127.0.0.1:8848/nacos) 8848；gRPC 9848 | 本地 standalone，未启用认证 |
| MinIO | RELEASE.2025-04-22 | S3 9000；[控制台](http://127.0.0.1:9001/) | `devminio`；Access Key / Secret Key |
| Elasticsearch | 8.19.8 | HTTP 9200 | `elastic`；单节点密码认证 |
| MongoDB | 8.0.17 | 27017 | `devmongo`；认证库 `admin` |
| RocketMQ | 5.3.2 | NameServer 9876；Broker 10911 / 10909；Proxy 18080 / 18081 | 未启用 ACL；Proxy 端口不是网页 |
| Nginx | 1.28.0 | [网页](http://127.0.0.1:18000/) 18000 | 前端静态文件、`/api/` 转发 |
| XXL-JOB | 3.2.0 | [控制台](http://127.0.0.1:18082/xxl-job-admin/) 18082；共享 MySQL 3306 | `admin`；专用数据库账号 `dev_xxl_job` |
| Kibana | 8.19.8 | [控制台](http://127.0.0.1:5601/) 5601 | 使用 Elasticsearch 的 `elastic` 账号 |
| RocketMQ Dashboard | 2.1.0 | [控制台](http://127.0.0.1:19876/) 19876 | `admin`；已启用登录 |
| PostgreSQL | 17.7 | 5432 | `devpg`；开发库 `dev` |
| Mailpit | 1.27.4 | SMTP 1025；[邮件预览](http://127.0.0.1:8025/) 8025 | 无认证、无 TLS；仅接收测试邮件 |
| Prometheus | 3.5.0 | [控制台](http://127.0.0.1:19090/) 19090 | 无认证；指标采集 |
| Grafana | 12.2.0 | [看板](http://127.0.0.1:13000/d/dev-infra-overview) 13000 | `admin`；已配置 Prometheus 数据源 |
| Sentinel | 1.8.10 | [控制台](http://127.0.0.1:18858/) 18858 | `admin`；首次使用构建官方 JAR 镜像 |
| Seata | 2.3.0 | RPC 18091；[控制台](http://127.0.0.1:17091/) 17091 | `admin`；单机 file 存储 |
| Kafka | 4.1.2 | Windows / macOS 9092；同网络容器 `kafka:19092` | 单节点 KRaft；无需 ZooKeeper，未启用 SASL |

## 依赖与共享数据库

启动 XXL-JOB 自动启动 MySQL；Kibana 自动启动 Elasticsearch；RocketMQ Dashboard 自动启动 RocketMQ；Grafana 自动启动 Prometheus。只停止上层服务不会连带停止它的依赖。若依赖仍被运行中的服务使用，操作台会提示先停止相关服务。

**整套配置只有一个 MySQL 容器。** XXL-JOB 在现有 MySQL 中使用独立库 `devinfra_xxl_job` 和专用账号 `dev_xxl_job`，权限仅限该库。首次启动自动导入 3.2.0 对应的 8 张表、调度锁及随机密码管理员；重复启动保留已有任务、账号和表。若发现非空但不完整的表结构，会停止并报错，不自动覆盖。

项目组合只选择服务，不自动创建业务数据库、Topic 或索引；XXL-JOB 内部库、Kibana 内部账号和 Grafana 数据源由对应服务初始化。原有 `New-Project.ps1` 和 `projects/` 登记仍可使用。

## 项目组合

| 组合 | 中间件 |
| --- | --- |
| base | MySQL、Redis |
| search | MySQL、Redis、Elasticsearch |
| mongo | MongoDB、Redis |
| microservice | MySQL、Redis、Nacos、RocketMQ |
| storage | MySQL、Redis、MinIO |
| java-web | MySQL、Redis、Nginx、Mailpit |
| jobs | MySQL、XXL-JOB |
| search-console | Elasticsearch、Kibana |
| rocketmq-console | RocketMQ、RocketMQ Dashboard |
| observability | Prometheus、Grafana |
| microservice-governance | Nacos、Sentinel、Seata |
| streaming | Kafka |
| postgres-app | PostgreSQL、Redis |

这些是可修改的起点；可在操作台添加自己的项目组合。当前 Docker 分配 8 GB 内存，适合按项目启用，全部服务同时运行可能超过可用内存。

## Java 项目接入

每个服务的“连接信息”包含对应示例。服务启动成功后，应用仍需添加相应 SDK 和项目配置。

- **Nginx**：前端构建产物放 `nginx/html/`；`/api/` 保留路径转发到 Windows / macOS 的 `JAVA_APP_PORT`（默认 8080）。后端需监听 Docker 可访问的地址。模板在 `nginx/templates/default.conf.template`。
- **XXL-JOB**：业务项目需配置执行器、调度中心地址和 Access Token。执行器地址必须可从 Docker 容器访问，不能向调度中心注册 Windows / macOS 自身的 `localhost`。
- **Nacos**：不同项目建议分别创建 namespace。Nacos gRPC 端口必须是 HTTP 端口加 1000。
- **Sentinel**：项目需接入 SDK，并提供容器可访问的 transport IP 与端口（默认 8719）；多个本机应用使用不同端口。规则持久化需要项目另外接入数据源。
- **Seata**：固定 2.3.0 以保留集成控制台。Windows / macOS 项目使用兼容 SDK、file 注册和单一静态 endpoint `127.0.0.1:18091`；同网络容器使用 `seata:8091`。AT 模式的业务库还需建 `undo_log`。
- **Prometheus / Grafana**：已采集 Prometheus 自身指标，并预置看板。Spring Boot 需引入 Actuator 和 Micrometer Prometheus，将 `host.docker.internal:<应用端口>` 等容器可访问地址写入 `prometheus/targets/spring.json`。默认目标为空，不会凭空出现业务指标。
- **RocketMQ**：传统客户端连接 NameServer；5.x gRPC 客户端连接 Proxy 18081。默认 Broker 公布 `127.0.0.1`，适合 Windows / macOS 项目；Dashboard 与 Broker 共享网络。业务应用也进 Docker 时，加入 `dev-infra_default`，把 `ROCKETMQ_BROKER_IP` 改为 `172.18.0.18`，使用 `rocketmq-namesrv:9876` / `rocketmq-broker:8081` 并重新启动 RocketMQ。此时 Windows / macOS 传统客户端通常不能直接使用公布的容器地址。
- **MongoDB**：URI 的认证库为 `admin`，业务库可自选；当前是 standalone，未提供副本集事务。
- **Kafka**：Windows / macOS 使用 `127.0.0.1:9092`，同网络容器用 `kafka:19092`；Kafka 本身没有管理网页。
- **Mailpit**：应用 SMTP 指向 `127.0.0.1:1025`，关闭认证和 TLS；网页查看测试邮件，不会投递给真实收件人。
