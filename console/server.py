"""Loopback-only development console. Uses the existing infra.ps1 command boundary."""
from __future__ import annotations

import argparse
import copy
import ctypes
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.parse import parse_qs, quote, urlsplit
from urllib.request import ProxyHandler, build_opener
import webbrowser

ROOT = Path(__file__).resolve().parents[1]
WEB = Path(__file__).parent / "dist"
APP_ID = "dev-infra-local-console-v1"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

# (name, purpose, category, icon, image, port labels/keys/defaults, accounts)
CATALOG = {
    "mysql": ("MySQL", "关系型数据库", "数据库", "MY", "mysql:8.0.44", [("数据库", "MYSQL_PORT", 3306)], [("app", "开发账号", "MYSQL_USER", "MYSQL_PASSWORD"), ("root", "管理员", "=root", "MYSQL_ROOT_PASSWORD")]),
    "redis": ("Redis", "缓存与会话", "缓存", "RE", "redis:7.4.7-alpine", [("数据库", "REDIS_PORT", 6379)], [("default", "默认账号", "=default", "REDIS_PASSWORD")]),
    "rabbitmq": ("RabbitMQ", "消息队列", "消息", "RA", "rabbitmq:3.13.7-management", [("AMQP", "RABBITMQ_PORT", 5672), ("管理页面", "RABBITMQ_MANAGEMENT_PORT", 15672)], [("admin", "管理账号", "RABBITMQ_DEFAULT_USER", "RABBITMQ_DEFAULT_PASS")]),
    "nacos": ("Nacos", "注册中心与配置中心", "配置", "NA", "nacos/nacos-server:v2.4.3", [("控制台 / HTTP", "NACOS_PORT", 8848), ("gRPC", "NACOS_GRPC_PORT", 9848)], []),
    "minio": ("MinIO", "文件与对象存储", "存储", "MI", "dev-infra/minio:RELEASE.2025-04-22T22-12-26Z", [("S3 API", "MINIO_API_PORT", 9000), ("管理页面", "MINIO_CONSOLE_PORT", 9001)], [("root", "Access Key / Secret Key", "MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD")]),
    "elasticsearch": ("Elasticsearch", "全文检索与索引", "搜索", "ES", "elasticsearch:{ELASTIC_VERSION}", [("HTTP API", "ELASTIC_PORT", 9200)], [("elastic", "管理员", "=elastic", "ELASTIC_PASSWORD")]),
    "rocketmq": ("RocketMQ", "NameServer · Broker · Proxy", "消息", "RM", "apache/rocketmq:{ROCKETMQ_VERSION}", [("NameServer", "ROCKETMQ_NAMESRV_PORT", 9876), ("Broker", "ROCKETMQ_BROKER_PORT", 10911), ("快速通道", "ROCKETMQ_FAST_PORT", 10909), ("Proxy Remoting", "ROCKETMQ_PROXY_REMOTING_PORT", 18080), ("Proxy gRPC", "ROCKETMQ_PROXY_GRPC_PORT", 18081)], []),
    "mongodb": ("MongoDB", "文档数据库", "数据库", "MO", "mongo:{MONGO_VERSION}", [("数据库", "MONGO_PORT", 27017)], [("root", "管理员 · 认证库 admin", "MONGO_ROOT_USER", "MONGO_ROOT_PASSWORD")]),
    'nginx': ('Nginx', '前端托管与 API 反向代理', '网关', 'NG', 'nginx:{NGINX_VERSION}-alpine', [('网页', 'NGINX_PORT', 18000)], []),
    'xxl-job': ('XXL-JOB', '任务调度 · 复用现有 MySQL', '调度', 'XX', 'xuxueli/xxl-job-admin:{XXL_JOB_VERSION}', [('管理页面', 'XXL_JOB_PORT', 18082), ('共享 MySQL', 'MYSQL_PORT', 3306)], [('admin', '控制台账号', 'XXL_JOB_USER', 'XXL_JOB_PASSWORD'), ('database', '独立库 devinfra_xxl_job', '=dev_xxl_job', 'XXL_JOB_DB_PASSWORD'), ('token', '执行器 Access Token', '=accessToken', 'XXL_JOB_ACCESS_TOKEN')]),
    'kibana': ('Kibana', 'Elasticsearch 索引与查询管理', '搜索', 'KI', 'kibana:{ELASTIC_VERSION}', [('管理页面', 'KIBANA_PORT', 5601)], [('elastic', '控制台账号', '=elastic', 'ELASTIC_PASSWORD')]),
    'rocketmq-dashboard': ('RocketMQ Dashboard', '消息、Topic 与消费者管理', '消息', 'RD', 'apacherocketmq/rocketmq-dashboard:{ROCKETMQ_DASHBOARD_VERSION}', [('管理页面', 'ROCKETMQ_DASHBOARD_PORT', 19876)], [('admin', '控制台账号', 'ROCKETMQ_DASHBOARD_USER', 'ROCKETMQ_DASHBOARD_PASSWORD')]),
    'postgresql': ('PostgreSQL', '关系型数据库 · PostgreSQL 生态', '数据库', 'PG', 'postgres:{POSTGRES_VERSION}-alpine', [('数据库', 'POSTGRES_PORT', 5432)], [('admin', '本地开发账号', 'POSTGRES_USER', 'POSTGRES_PASSWORD')]),
    'mailpit': ('Mailpit', '本地邮件接收与预览', '开发工具', 'MP', 'axllent/mailpit:v{MAILPIT_VERSION}', [('SMTP', 'MAILPIT_SMTP_PORT', 1025), ('邮件预览', 'MAILPIT_WEB_PORT', 8025)], []),
    'prometheus': ('Prometheus', '应用与服务指标采集', '监控', 'PR', 'prom/prometheus:v{PROMETHEUS_VERSION}', [('管理页面', 'PROMETHEUS_PORT', 19090)], []),
    'grafana': ('Grafana', '指标图表与监控看板', '监控', 'GR', 'grafana/grafana:{GRAFANA_VERSION}', [('管理页面', 'GRAFANA_PORT', 13000)], [('admin', '管理员', 'GRAFANA_USER', 'GRAFANA_PASSWORD')]),
    'sentinel': ('Sentinel', '微服务限流与熔断控制台', '微服务', 'SE', 'dev-infra/sentinel-dashboard:{SENTINEL_VERSION}', [('管理页面', 'SENTINEL_PORT', 18858)], [('admin', '控制台账号', 'SENTINEL_USER', 'SENTINEL_PASSWORD')]),
    'seata': ('Seata', '分布式事务协调与管理', '微服务', 'ST', 'apache/seata-server:{SEATA_VERSION}.jdk17', [('事务服务', 'SEATA_PORT', 18091), ('管理页面', 'SEATA_CONSOLE_PORT', 17091)], [('admin', '控制台账号', 'SEATA_USER', 'SEATA_PASSWORD')]),
    'kafka': ('Kafka', '事件流与消息 · 单节点 KRaft', '消息', 'KA', 'apache/kafka:{KAFKA_VERSION}', [('应用连接', 'KAFKA_PORT', 9092)], []),
}



DEPENDENCIES = {"xxl-job": ["mysql"], "kibana": ["elasticsearch"], "rocketmq-dashboard": ["rocketmq"], "grafana": ["prometheus"]}
NOTES = {
    "mysql": "开发账号连接 dev 数据库；root 为本机管理员账号。XXL-JOB 使用此实例中的独立数据库和专用账号。",
    "redis": "默认数据库 0。项目可以按需选择数据库编号。",
    "rabbitmq": "应用连接 AMQP 端口；管理页面用于查看队列和消息。",
    "nacos": "本机 standalone，未启用认证。项目需配置 Nacos SDK；不同项目建议使用独立 namespace。",
    "minio": "Access Key 即用户名，Secret Key 即密码；应用使用 S3 API 端口。",
    "elasticsearch": "HTTP 单节点，启用账号密码认证。Kibana 可在单独卡片中启动。",
    "mongodb": "认证库为 admin；当前为 standalone 单节点，未配置副本集事务。",
    "rocketmq": "未启用 ACL。传统客户端连接 NameServer；5.x gRPC 客户端连接 Proxy gRPC。管理网页请启动 RocketMQ Dashboard。",
    "nginx": "nginx/html 放前端构建产物；/api/ 保留原路径转发至本机的 JAVA_APP_PORT（默认 8080）。后端需监听容器可访问的地址。",
    "xxl-job": "复用已有 MySQL 容器，独立库 devinfra_xxl_job、专用账号 dev_xxl_job。首次启动自动导入版本匹配的表结构；已有表和任务保留。业务项目还需接入 XXL-JOB 执行器并配置 Access Token。",
    "kibana": "启动时自动带起 Elasticsearch，并初始化内部 kibana_system 账号。网页使用上方 elastic 账号登录。",
    "rocketmq-dashboard": "自动启动 RocketMQ；与 Broker 共享网络，使 Windows / macOS 本机客户端与管理台都能访问 Broker。管理台端口由 Broker 发布。",
    "postgresql": "独立 PostgreSQL 实例，使用 POSTGRES_DB 指定的开发库。与 MySQL 并存，按项目选用。",
    "mailpit": "本地测试邮箱，无需账号密码；SMTP 无需认证或 TLS。邮件保留在本机，不向真实收件人发送。",
    "prometheus": "已采集自身指标。Spring Boot 需引入 Actuator 和 Micrometer Prometheus，并将容器可访问的地址写入 prometheus/targets/spring.json。",
    "grafana": "已自动配置 Prometheus 数据源和 Local development 看板。JVM、HTTP 图表需要业务应用先接入指标采集。",
    "sentinel": "首次从官方发布的 JAR 构建镜像。业务应用需接入 Sentinel SDK；容器还需反向访问应用的 transport 端口（通常 8719）。规则持久化需项目接入数据源。",
    "seata": "单机 file 存储，2.3.0 保留集成控制台。项目需接入 Seata SDK、配置事务组；AT 模式还需在业务库建立 undo_log。",
    "kafka": "单节点 KRaft，无需 ZooKeeper。当前未启用 SASL，无账号密码；Kafka 自身不提供管理网页。容器内应用使用 kafka:19092。",
}
WEB_LINKS = {
    "rabbitmq": (1, "", "打开管理页面"), "minio": (1, "", "打开管理页面"),
    "nacos": (0, "/nacos", "打开管理页面"), "elasticsearch": (0, "", "打开 API"),
    "nginx": (0, "", "打开网页"), "xxl-job": (0, "/xxl-job-admin/", "打开管理页面"),
    "kibana": (0, "", "打开管理页面"), "rocketmq-dashboard": (0, "", "打开管理页面"),
    "mailpit": (1, "", "查看邮件"), "prometheus": (0, "", "打开管理页面"),
    "grafana": (0, "/d/dev-infra-overview", "打开监控看板"), "sentinel": (0, "", "打开管理页面"),
    "seata": (1, "", "打开管理页面"),
}

def with_dependencies(selected):
    result = []
    for service in selected:
        for part in with_dependencies(DEPENDENCIES.get(service, [])) + [service]:
            if part not in result:
                result.append(part)
    return result

def integration_hint(service, values):
    if service == "xxl-job":
        return f"xxl.job.admin.addresses=http://127.0.0.1:{values['XXL_JOB_PORT']}/xxl-job-admin\nxxl.job.accessToken=<复制上方执行器 Access Token>\n# 执行器 IP 和端口需能从 Docker 容器访问；使用你项目的属性绑定方式。"
    if service == "seata":
        return f"seata.tx-service-group=dev_tx_group\nseata.registry.type=file\nseata.config.type=file\nseata.service.vgroup-mapping.dev_tx_group=default\nseata.service.grouplist.default=127.0.0.1:{values['SEATA_PORT']}\n# 本机项目：Seata 2.3 SDK，保持单一静态 endpoint；容器用 seata:8091。"
    if service == "sentinel":
        return f"spring.cloud.sentinel.transport.dashboard=127.0.0.1:{values['SENTINEL_PORT']}\nspring.cloud.sentinel.transport.port=8719\nspring.cloud.sentinel.transport.client-ip=<Docker 可访问的 本机 IPv4 地址>\n# 多个本机应用使用不同 transport 端口；该 IP 不能写 localhost 或域名。"
    if service == "mailpit":
        return f"spring.mail.host=127.0.0.1\nspring.mail.port={values['MAILPIT_SMTP_PORT']}\nspring.mail.properties.mail.smtp.auth=false\nspring.mail.properties.mail.smtp.starttls.enable=false"
    if service == "kafka":
        return f"spring.kafka.bootstrap-servers=127.0.0.1:{values['KAFKA_PORT']}\n# Docker 内应用改用 kafka:19092"
    if service in ("prometheus", "grafana"):
        return '业务应用：management.endpoints.web.exposure.include=health,info,prometheus\nprometheus/targets/spring.json：\n[{"targets":["host.docker.internal:8080"],"labels":{"application":"my-app"}}]'
    return ""


def read_env(root=ROOT):
    values = {}
    for line in (root / ".env").read_text(encoding="utf-8-sig").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            raise ValueError("本地 .env 配置格式不正确，请检查键名或重复项。")
        values[key] = value
    return values


def redact(text, values):
    for key, value in values.items():
        if value and re.search(r"PASSWORD|PASS$|TOKEN|SECRET|KEY$", key):
            text = text.replace(value, "[已隐藏]")
    return text


def validate_services(value):
    if not isinstance(value, list) or not value or any(not isinstance(s, str) or s not in CATALOG for s in value):
        raise ValueError("请选择有效的中间件。")
    return list(dict.fromkeys(value))


def expanded(services):
    return [part for s in services for part in (["rocketmq-namesrv", "rocketmq-broker"] if s == "rocketmq" else [s])]


def executable(name, candidates=()):
    found = shutil.which(name)
    if found:
        return found
    for candidate in candidates:
        if Path(candidate).is_file():
            return str(candidate)
    raise RuntimeError(f"找不到 {name}，请检查本机安装。")


def powershell_executable():
    try:
        return executable("pwsh", [Path("/opt/homebrew/bin/pwsh"), Path("/usr/local/bin/pwsh")])
    except RuntimeError:
        if os.name != "nt":
            raise RuntimeError("请先安装 PowerShell 7（pwsh），再启动操作台。") from None
        return executable("powershell.exe", [Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"])


class Console:
    def __init__(self, root=ROOT):
        self.root = root
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.RLock()
        self.status_lock = threading.Lock()
        self.cached = None
        self.cached_at = 0.0
        self.runtime = root / ".runtime" / "console"
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.history_path = self.runtime / "jobs.json"
        try:
            self.jobs = json.loads(self.history_path.read_text(encoding="utf-8"))[-20:]
        except (FileNotFoundError, ValueError):
            self.jobs = []
        for job in self.jobs:
            if job["status"] == "running":
                job.update(status="interrupted", output="操作台已重启，请刷新查看实际服务状态。")
        program_files = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
        self.docker = executable("docker", [program_files / "Rancher Desktop/resources/resources/win32/bin/docker.exe", program_files / "Docker/Docker/resources/bin/docker.exe", Path.home() / ".docker/bin/docker", Path.home() / ".rd/bin/docker", Path("/usr/local/bin/docker"), Path("/opt/homebrew/bin/docker"), Path("/Applications/Docker.app/Contents/Resources/bin/docker")])
        self.powershell = powershell_executable()

    def run(self, args, timeout=20):
        result = subprocess.run(args, cwd=self.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout, creationflags=NO_WINDOW)
        if result.returncode:
            raise RuntimeError(redact((result.stderr or result.stdout)[-3000:], read_env(self.root)))
        return result.stdout

    def assert_local(self):
        context = os.environ.get("DOCKER_CONTEXT")
        endpoint = os.environ.get("DOCKER_HOST") if not context else None
        if not endpoint:
            args = [self.docker, "context", "inspect"]
            if context:
                args.append(context)
            args += ["--format", "{{.Endpoints.docker.Host}}"]
            endpoint = self.run(args).strip()
        parsed = urlsplit(endpoint)
        if re.fullmatch(r"npipe:////\./pipe/[A-Za-z0-9_.-]+", endpoint) or endpoint.startswith("unix:///"):
            return
        if parsed.scheme in ("tcp", "http", "https") and parsed.hostname in ("localhost", "127.0.0.1", "::1"):
            return
        raise ValueError("当前 Docker 上下文不是本机；操作台只管理本机环境。")

    def stacks(self):
        data = json.loads((self.root / "stacks.json").read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError("stacks.json 必须是项目名称到服务列表的映射。")
        return {name: validate_services(items) for name, items in data.items()}

    def save_stack(self, name, items):
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name):
            raise ValueError("组合名称请使用 1–40 个英文字母、数字、短横线或下划线。")
        services = validate_services(items)
        with self.lock:
            stacks = self.stacks()
            stacks[name] = services
            temporary = self.root / "stacks.json.console-tmp"
            temporary.write_text(json.dumps(stacks, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            temporary.replace(self.root / "stacks.json")
        return stacks

    def connection(self, service, account=None, uri=False):
        validate_services([service])
        values = read_env(self.root)
        definition = CATALOG[service]
        accounts = definition[6]
        entry = next((a for a in accounts if a[0] == account), None) if account else (accounts[0] if accounts else None)
        if account and entry is None:
            raise ValueError("无效的账号。")
        username = (entry[2][1:] if entry[2].startswith("=") else values.get(entry[2], "")) if entry else ""
        password = values.get(entry[3], "") if entry else ""
        port = int(values.get(definition[5][0][1], definition[5][0][2]))
        if not uri:
            return {"username": username, "password": password}
        user = quote(username, safe="")
        secret = quote(password, safe="")
        strings = {
            "mysql": f"mysql://{user}:{secret}@127.0.0.1:{port}/dev",
            "redis": f"redis://{user}:{secret}@127.0.0.1:{port}/0",
            "rabbitmq": f"amqp://{user}:{secret}@127.0.0.1:{port}/%2F",
            "mongodb": f"mongodb://{user}:{secret}@127.0.0.1:{port}/dev?authSource=admin",
            "elasticsearch": f"http://{user}:{secret}@127.0.0.1:{port}",
            "minio": f"http://127.0.0.1:{port}",
            "nacos": f"http://127.0.0.1:{port}/nacos",
            "rocketmq": f"127.0.0.1:{port}",
        }
        strings.update({
            "postgresql": f"postgresql://{user}:{secret}@127.0.0.1:{port}/{quote(values['POSTGRES_DB'], safe='')}",
            "mailpit": f"smtp://127.0.0.1:{port}",
            "kafka": f"127.0.0.1:{port}",
            "seata": f"127.0.0.1:{port}",
        })
        if service not in strings:
            index, suffix, _ = WEB_LINKS[service]
            key = definition[5][index][1]
            strings[service] = f"http://127.0.0.1:{values[key]}{suffix}"
        return {"value": strings[service]}

    def snapshot(self):
        with self.status_lock:
            if self.cached is not None and time.monotonic() - self.cached_at < 3:
                snapshot = copy.deepcopy(self.cached)
            else:
                values = read_env(self.root)
                containers, images, error = {}, set(), None
                try:
                    self.assert_local()
                    raw = self.run([self.docker, "ps", "-a", "--filter", "label=com.docker.compose.project=dev-infra", "--format", "{{json .}}"])
                    for line in raw.splitlines():
                        item = json.loads(line)
                        labels = dict(part.split("=", 1) for part in item.get("Labels", "").split(",") if "=" in part)
                        name = labels.get("com.docker.compose.service")
                        if name:
                            containers[name] = item
                    images = set(self.run([self.docker, "image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]).splitlines())
                except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
                    error = str(exc)[:1600]
                services = []
                for key, definition in CATALOG.items():
                    name, purpose, category, icon, image_template, port_specs, account_specs = definition
                    image = image_template.format_map(values)
                    parts = expanded([key])
                    found = [containers[p] for p in parts if p in containers]
                    running = [c for c in found if c.get("State") == "running"]
                    if error:
                        state = "offline"
                    elif len(running) == len(parts):
                        health = [c.get("HealthStatus", "") for c in running]
                        state = "unhealthy" if "unhealthy" in health else "starting" if "starting" in health else "running"
                    elif running:
                        state = "partial"
                    elif any(c.get("State") in ("restarting", "dead") for c in found):
                        state = "unhealthy"
                    elif found:
                        state = "stopped"
                    else:
                        state = "ready" if image in images else "missing"
                    ports = [{"label": label, "port": int(values.get(envkey, default)), "address": f"127.0.0.1:{values.get(envkey, default)}"} for label, envkey, default in port_specs]
                    links = []
                    if key in WEB_LINKS:
                        index, suffix, label = WEB_LINKS[key]
                        links.append({"label": label, "url": f"http://127.0.0.1:{ports[index]['port']}{suffix}"})
                    accounts = [{"id": a[0], "label": a[1], "username": a[2][1:] if a[2].startswith("=") else values.get(a[2], ""), "configured": bool(values.get(a[3]))} for a in account_specs]
                    services.append({"id": key, "name": name, "purpose": purpose, "category": category, "icon": icon, "image": image, "version": image.rsplit(":", 1)[1], "notes": NOTES.get(key, ""), "integration": integration_hint(key, values), "dependencies": DEPENDENCIES.get(key, []), "connectionHasPassword": key in ("mysql","redis","rabbitmq","mongodb","elasticsearch","postgresql"), "ports": ports, "accounts": accounts, "links": links, "state": state, "imagePresent": image in images, "containers": [{"name": c["Names"], "state": c["State"], "status": c["Status"]} for c in found]})
                snapshot = {"engine": {"online": error is None, "error": error}, "services": services, "root": str(self.root), "updatedAt": time.time()}
                self.cached, self.cached_at = copy.deepcopy(snapshot), time.monotonic()
        with self.lock:
            snapshot["jobs"] = copy.deepcopy(self.jobs[-12:][::-1])
            snapshot["stacks"] = self.stacks()
        return snapshot

    def _save_jobs(self):
        temporary = self.history_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.jobs[-20:], ensure_ascii=False, indent=2), encoding="utf-8")
        temporary.replace(self.history_path)

    def start_job(self, action, services):
        if action not in ("start", "stop"):
            raise ValueError("只支持启动或停止。")
        requested = validate_services(services)
        selected = with_dependencies(requested) if action == "start" else requested
        self.assert_local()
        if action == "stop":
            snapshot = self.snapshot()
            running = {s["id"] for s in snapshot["services"] if s["state"] in ("running", "starting", "partial", "unhealthy")}
            for dependent, dependencies in DEPENDENCIES.items():
                if dependent in running and dependent not in selected and any(d in selected for d in dependencies):
                    raise ValueError(f"{CATALOG[dependent][0]} 正在使用所选服务，请同时勾选它一起停止。")
        with self.lock:
            if any(j["status"] == "running" for j in self.jobs):
                raise BlockingIOError("已有操作进行中，请等它完成后再操作。")
            job = {"id": secrets.token_hex(8), "action": action, "services": selected, "status": "running", "startedAt": time.time(), "finishedAt": None, "output": "正在连接本机 Docker…"}
            self.jobs.append(job)
            self.jobs = self.jobs[-20:]
            self._save_jobs()
            threading.Thread(target=self._execute_job, args=(job,), daemon=True).start()
            return copy.deepcopy(job)

    def _execute_job(self, job):
        values = read_env(self.root)
        args = [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "infra.ps1"), "Up" if job["action"] == "start" else "Stop", "-Services", ",".join(job["services"])]
        output = []
        process = None
        timer = None
        timed_out = threading.Event()
        try:
            process = subprocess.Popen(args, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", creationflags=NO_WINDOW)

            def terminate():
                if process.poll() is None:
                    timed_out.set()
                    subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], capture_output=True, creationflags=NO_WINDOW)

            timer = threading.Timer(1200, terminate)
            timer.daemon = True
            timer.start()
            for line in process.stdout:
                output.append(redact(line.rstrip(), values))
                output = output[-300:]
                with self.lock:
                    job["output"] = "\n".join(output)[-16000:]
            code = process.wait()
            if timed_out.is_set():
                output.append("操作等待超过 20 分钟，已结束命令；请刷新查看实际容器状态。")
            with self.lock:
                job["status"] = "success" if code == 0 and not timed_out.is_set() else "failed"
                job["output"] = "\n".join(output)[-16000:]
        except Exception as exc:
            with self.lock:
                job.update(status="failed", output=redact(str(exc), values))
        finally:
            if timer:
                timer.cancel()
            with self.lock:
                job["finishedAt"] = time.time()
                self.cached_at = 0
                self._save_jobs()

    def logs(self, service):
        validate_services([service])
        self.assert_local()
        args = [self.powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "infra.ps1"), "Logs", "-Services", service, "-Tail", "120"]
        return {"text": redact(self.run(args, timeout=30), read_env(self.root))[-40000:]}


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalConsole"

    def log_message(self, *_):
        pass  # Never write HTTP requests or secrets to console logs.

    @property
    def app(self):
        return self.server.app

    def allowed_request(self, api=False):
        port = self.server.server_port
        allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if self.headers.get("Host") not in allowed_hosts:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {"http://" + host for host in allowed_hosts}:
            return False
        if self.headers.get("Sec-Fetch-Site") == "cross-site":
            return False
        return not api or hmac.compare_digest(self.headers.get("X-Console-Token", ""), self.app.token)

    def send(self, value, status=200, content_type="application/json; charset=utf-8"):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path = urlsplit(self.path).path
        if not self.allowed_request(api=path.startswith("/api/") and path != "/api/ping"):
            return self.send({"error": "此请求不是来自本机操作台。"}, 403)
        try:
            if path == "/api/ping":
                return self.send({"app": APP_ID, "root": str(self.app.root)})
            if path == "/api/state":
                return self.send(self.app.snapshot())
            if path == "/api/logs":
                service = parse_qs(urlsplit(self.path).query).get("service", [""])[0]
                return self.send(self.app.logs(service))
            files = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8"), "/favicon.svg": ("favicon.svg", "image/svg+xml")}
            if path not in files:
                return self.send({"error": "未找到页面。"}, 404)
            filename, mime = files[path]
            data = (WEB / filename).read_bytes()
            if path == "/":
                data = data.replace(b"__SESSION_TOKEN__", self.app.token.encode())
            return self.send(data, content_type=mime)
        except (ValueError, KeyError) as exc:
            return self.send({"error": str(exc)}, 400)
        except Exception as exc:
            return self.send({"error": redact(str(exc), read_env(self.app.root))}, 503)

    def do_POST(self):
        if not self.allowed_request(api=True):
            return self.send({"error": "此请求不是来自本机操作台。"}, 403)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16384 or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                return self.send({"error": "请求格式不正确。"}, 400)
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError("请求必须为 JSON 对象。")
            if self.path == "/api/jobs":
                return self.send(self.app.start_job(data.get("action"), data.get("services")), 202)
            if self.path == "/api/credentials":
                return self.send(self.app.connection(data.get("service"), data.get("account")))
            if self.path == "/api/connection-string":
                return self.send(self.app.connection(data.get("service"), uri=True))
            if self.path == "/api/stacks":
                return self.send(self.app.save_stack(data.get("name"), data.get("services")))
            return self.send({"error": "未找到操作。"}, 404)
        except BlockingIOError as exc:
            return self.send({"error": str(exc)}, 409)
        except (ValueError, KeyError, TypeError) as exc:
            return self.send({"error": str(exc)}, 400)
        except Exception as exc:
            return self.send({"error": redact(str(exc), read_env(self.app.root))}, 503)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=17860)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    url = f"http://127.0.0.1:{args.port}"
    try:
        opener = build_opener(ProxyHandler({}))
        with opener.open(url + "/api/ping", timeout=2) as response:
            if json.load(response).get("app") == APP_ID:
                if args.open:
                    webbrowser.open(url)
                return
    except (URLError, ValueError, TimeoutError, OSError):
        pass
    try:
        app = Console()
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        server.daemon_threads = True
        server.app = app
        if args.open:
            webbrowser.open(url)
        server.serve_forever()
    except Exception as exc:
        if args.open and os.name == "nt":
            ctypes.windll.user32.MessageBoxW(0, f"操作台未能启动：{exc}", "本地开发操作台", 16)
        else:
            raise


if __name__ == "__main__":
    main()
