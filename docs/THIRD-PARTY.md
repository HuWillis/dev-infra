# 构建来源

## MinIO

原电脑使用已有的 Linux AMD64 二进制；它不随本仓库上传。2026-11-09 检查时，官方归档的该版本校验文件返回 HTTP 410，因此新电脑采用固定源码构建。

- 发布标签：`RELEASE.2025-04-22T22-12-26Z`
- 官方源码提交：`0d7408fc9969caf07de6a8c3a84f9fbb10a6739e`
- 来源：<https://github.com/minio/minio/tree/0d7408fc9969caf07de6a8c3a84f9fbb10a6739e>
- Go 工具链：1.24.2，与该版本 `go.mod` 对应。
- 构建配置：`minio/Dockerfile`。最终镜像含上游 AGPLv3 许可证文件。

此为本地源码构建镜像，不是上游发布的官方预编译镜像。首次构建需要下载编译器和模块；后续复用 Docker 构建缓存。请保留上游许可信息。

## 其他组件

Sentinel 使用官方 GitHub Release JAR；XXL-JOB schema 来自固定 3.2.0 标签。其余镜像版本固定在 Compose 或 `.env.example` 中，升级时应阅读上游迁移说明，特别是数据库数据格式。

参考：[MinIO go.mod](https://github.com/minio/minio/blob/0d7408fc9969caf07de6a8c3a84f9fbb10a6739e/go.mod)、[Sentinel Releases](https://github.com/alibaba/Sentinel/releases)、[XXL-JOB schema](https://github.com/xuxueli/xxl-job/blob/3.2.0/doc/db/tables_xxl_job.sql)。
