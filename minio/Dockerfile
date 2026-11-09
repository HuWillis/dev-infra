FROM golang:1.24.2-bookworm AS builder
WORKDIR /src
# Official RELEASE.2025-04-22T22-12-26Z source commit. No local binary required.
ADD https://github.com/minio/minio/archive/0d7408fc9969caf07de6a8c3a84f9fbb10a6739e.tar.gz /tmp/minio.tar.gz
RUN tar -xzf /tmp/minio.tar.gz --strip-components=1 -C /src
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags='-s -w -X github.com/minio/minio/cmd.Version=2025-04-22T22:12:26Z -X github.com/minio/minio/cmd.ReleaseTag=RELEASE.2025-04-22T22-12-26Z -X github.com/minio/minio/cmd.CommitID=0d7408fc9969caf07de6a8c3a84f9fbb10a6739e -X github.com/minio/minio/cmd.CopyrightYear=2025' -o /minio .

FROM alpine:3.21.3@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c
RUN apk add --no-cache ca-certificates
COPY --from=builder /minio /usr/local/bin/minio
COPY --from=builder /src/LICENSE /usr/share/licenses/minio/LICENSE
ENTRYPOINT ["/usr/local/bin/minio"]
