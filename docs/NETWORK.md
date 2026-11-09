# 镜像下载与 EOF

`EOF` 可能来自仓库连接被中断、错误 DNS、代理入口超时。先查看操作台日志，确认是下载失败还是容器启动失败。启动脚本只对识别到的临时仓库错误最多尝试三次，认证、镜像不存在和不健康容器会直接报告。

## 新电脑

1. 确认 `docker info` 可用，先测试 `docker pull nginx:1.28.0-alpine`。
2. 网络需要代理时，在容器运行时设置代理。Windows 的 WSL 地址和旧电脑代理端口不能照搬到 Mac。
3. 可按需配置公共镜像缓存：`https://docker.m.daocloud.io`，备用 `https://mirror.gcr.io`。公共缓存不保证包含每个镜像，也会改变下载链路；按自己网络情况使用。
4. 如果国内镜像经代理反而失败，在运行时代理绕过名单中添加 `.daocloud.io`。保留原有排除项。
5. 重启运行时后用 `docker info` 确认 Mirrors / No Proxy，再实际下载验证。

Docker Desktop 的代理使用 Desktop 设置页面；不要假定 daemon.json 的代理配置在 Docker Desktop 上生效。镜像源可合并到 Docker Engine 设置中的 `registry-mirrors`，不要覆盖其他已有字段。

## 原 Windows Rancher Desktop 环境的可选配置

`rancher-provisioning/dev-infra-registry.start` 是本环境的 Rancher 启动脚本副本。它保留已有镜像列表，并对已有 `no-proxy` 字段追加国内镜像排除项。只在需要相同设置时复制到 `%LOCALAPPDATA%\rancher-desktop\provisioning\`，重启 Rancher 并验证。

`dev-infra-healthcheck.start` 针对原 Windows Rancher 1.24 的具体健康检查问题；不作为 Mac 的必装项。仓库不会自动修改系统代理、DNS 或 Rancher 配置。Clash 节点及订阅凭据属于各电脑自己的设置，不包含在仓库中。

MinIO 源码构建需要 GitHub 与 Go 模块网络；Sentinel JAR 来自 GitHub。这些下载不会自动经过 Docker Hub 镜像缓存。

参考：[Docker 代理](https://docs.docker.com/engine/daemon/proxy/)、[DaoCloud 镜像](https://github.com/DaoCloud/public-image-mirror)、[Google 缓存](https://docs.cloud.google.com/artifact-registry/docs/pull-cached-dockerhub-images)、[Rancher provisioning](https://docs.rancherdesktop.io/how-to-guides/provisioning-scripts/)。
