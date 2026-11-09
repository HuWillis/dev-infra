"""Regression checks for the local control and credential boundaries; uses fake secrets."""
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from server import CATALOG, DEPENDENCIES, Console, Handler, ThreadingHTTPServer, expanded, validate_services, with_dependencies


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dev-console-check-")
        self.root = Path(self.temporary.name).resolve()
        if self.root.parent != Path(tempfile.gettempdir()).resolve() or not self.root.name.startswith("dev-console-check-"):
            raise RuntimeError("Unsafe temporary test directory.")
        self.addCleanup(self.temporary.cleanup)
        template = (Path(__file__).resolve().parents[1] / ".env.example").read_text(encoding="utf-8")
        self.secrets = []
        lines = []
        for line in template.splitlines():
            if line.endswith("=GENERATE"):
                key = line.partition("=")[0]
                secret = "fake-test-secret-" + key
                self.secrets.append(secret)
                line = key + "=" + secret
            lines.append(line)
        (self.root / ".env").write_text("\n".join(lines), encoding="utf-8")
        (self.root / "stacks.json").write_text('{"test": ["redis"]}', encoding="utf-8")
        with patch("server.executable", side_effect=lambda name, candidates=(): name):
            self.app = Console(self.root)
        self.app.assert_local = Mock()
        self.app.run = Mock(side_effect=self.fake_command)

    def fake_command(self, args, timeout=20):
        if "ps" in args:
            return json.dumps({"Labels":"com.docker.compose.service=redis", "Names":"dev-infra-redis-1", "State":"exited", "Status":"Exited (0)", "HealthStatus":"unhealthy"})
        if "image" in args:
            return "redis:7.4.7-alpine\n"
        return ""

    def test_state_never_contains_passwords(self):
        state = self.app.snapshot()
        body = json.dumps(state)
        for secret in self.secrets:
            self.assertNotIn(secret, body)
        self.assertEqual(next(s for s in state["services"] if s["id"] == "redis")["state"], "stopped")
        self.assertEqual(next(s for s in state["services"] if s["id"] == "mongodb")["state"], "missing")

    def test_connections_use_actual_values(self):
        path = self.root / ".env"
        path.write_text(path.read_text().replace("MONGO_PORT=27017", "MONGO_PORT=27018"), encoding="utf-8")
        self.assertIn(":27018/dev?authSource=admin", self.app.connection("mongodb", uri=True)["value"])
        self.assertEqual(self.app.connection("mysql", "root")["username"], "root")
        self.assertEqual(self.app.connection("mysql", "root")["password"], "fake-test-secret-MYSQL_ROOT_PASSWORD")
        with self.assertRaises(ValueError):
            self.app.connection("mysql", "REDIS_PASSWORD")

    def test_all_services_have_valid_links_and_connections(self):
        self.assertEqual(len(CATALOG), 19)
        state = self.app.snapshot()
        for service in state["services"]:
            with self.subTest(service=service["id"]):
                self.assertTrue(self.app.connection(service["id"], uri=True)["value"])
                self.assertTrue(service["notes"])
                for link in service["links"]:
                    self.assertTrue(link["url"].startswith("http://127.0.0.1:"))
        self.assertEqual(self.app.connection("xxl-job", "database")["username"], "dev_xxl_job")
        self.assertEqual(self.app.connection("xxl-job", "token")["password"], "fake-test-secret-XXL_JOB_ACCESS_TOKEN")
        self.assertEqual(self.app.connection("kibana", "elastic")["password"], "fake-test-secret-ELASTIC_PASSWORD")

    def test_start_dependencies_and_stop_guard(self):
        self.assertEqual(with_dependencies(["xxl-job", "mysql", "grafana"]), ["mysql", "xxl-job", "prometheus", "grafana"])
        with patch("server.threading.Thread"):
            job = self.app.start_job("start", ["xxl-job"])
        self.assertEqual(job["services"], ["mysql", "xxl-job"])
        self.app.jobs = []
        self.app.snapshot = Mock(return_value={"services":[{"id":"xxl-job", "state":"running"}]})
        with self.assertRaisesRegex(ValueError, "XXL-JOB"):
            self.app.start_job("stop", ["mysql"])
        with patch("server.threading.Thread"):
            job = self.app.start_job("stop", ["xxl-job"])
        self.assertEqual(job["services"], ["xxl-job"])

    def test_invalid_commands_and_empty_selection_rejected(self):
        for value in ([], None, ["redis;whoami"], ["--all"], "redis", ["rocketmq-broker"]):
            with self.assertRaises(ValueError):
                validate_services(value)
        self.assertEqual(expanded(["rocketmq"]), ["rocketmq-namesrv", "rocketmq-broker"])
        with self.assertRaises(ValueError):
            self.app.start_job("delete", ["redis"])

    def test_selective_command_and_log_redaction(self):
        job = {"id":"test", "status":"running", "action":"stop", "services":["redis"], "output":""}
        self.app.jobs = [job]
        fake = Mock(stdout=io.StringIO("fake-test-secret-REDIS_PASSWORD\nStopped.\n"))
        fake.wait.return_value = 0
        with patch("server.subprocess.Popen", return_value=fake) as launch:
            self.app._execute_job(job)
        args = launch.call_args.args[0]
        self.assertEqual(args[-3:], ["Stop", "-Services", "redis"])
        self.assertNotIn("-All", args)
        self.assertEqual(job["status"], "success")
        self.assertNotIn("fake-test-secret-REDIS_PASSWORD", self.app.history_path.read_text(encoding="utf-8"))
        self.assertIn("[已隐藏]", job["output"])

    def test_parallel_mutations_rejected(self):
        self.app.jobs = [{"status":"running"}]
        with self.assertRaises(BlockingIOError):
            self.app.start_job("start", ["redis"])

    def test_stack_changes_validate_and_preserve_others(self):
        self.app.save_stack("shop", ["mysql", "rocketmq", "mysql"])
        self.assertEqual(self.app.stacks(), {"test":["redis"], "shop":["mysql", "rocketmq"]})
        before = (self.root / "stacks.json").read_bytes()
        for name, services in (("../escape", ["redis"]), ("bad", []), ("bad", ["unknown"])):
            with self.assertRaises(ValueError):
                self.app.save_stack(name, services)
        self.assertEqual(before, (self.root / "stacks.json").read_bytes())

    def test_http_host_origin_session_and_static_boundaries(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.app = self.app
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        opener = build_opener(ProxyHandler({}))
        base = f"http://127.0.0.1:{server.server_port}"

        def request(path, headers=None, payload=None):
            final_headers = headers or {}
            if payload is not None:
                final_headers = {**final_headers, "Content-Type":"application/json"}
            req = Request(base + path, headers=final_headers, data=json.dumps(payload).encode() if payload is not None else None)
            try:
                with opener.open(req, timeout=5) as response:
                    return response.status, response.read(), dict(response.headers)
            except HTTPError as exc:
                return exc.code, exc.read(), dict(exc.headers)
        try:
            authenticated = {"X-Console-Token":self.app.token}
            self.assertEqual(request("/api/state")[0], 403)
            self.assertEqual(request("/", {"Host":"evil.example"})[0], 403)
            self.assertEqual(request("/api/state", {**authenticated, "Origin":"https://evil.example"})[0], 403)
            self.assertEqual(request("/.env")[0], 404)
            self.assertEqual(request("/../.env")[0], 404)
            code, body, headers = request("/api/state", authenticated)
            self.assertEqual(code, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertNotIn("Access-Control-Allow-Origin", headers)
            for secret in self.secrets:
                self.assertNotIn(secret.encode(), body)
            payload = {"service":"mysql", "account":"root"}
            self.assertEqual(request("/api/credentials", payload=payload)[0], 403)
            code, body, _ = request("/api/credentials", authenticated, payload)
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["password"], "fake-test-secret-MYSQL_ROOT_PASSWORD")
            self.assertEqual(request("/api/jobs", authenticated, {"action":"start", "services":["redis & whoami"]})[0], 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
