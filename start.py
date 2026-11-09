"""Initialize this checkout and open its detached loopback-only console."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener
import webbrowser

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "console"))
from server import APP_ID, NO_WINDOW, powershell_executable


def probe(url):
    try:
        with build_opener(ProxyHandler({})).open(url + "/api/ping", timeout=1) as response:
            return json.load(response)
    except (URLError, OSError, ValueError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=17860)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("Use a console port between 1024 and 65535.")
    url = f"http://127.0.0.1:{args.port}"
    existing = probe(url)
    if existing is not None:
        if existing.get("app") != APP_ID or existing.get("root") != str(ROOT):
            raise SystemExit("Port belongs to another checkout/app. Stop that console or use --port 17861.")
    else:
        shell = powershell_executable()
        subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "infra.ps1"), "Init"], cwd=ROOT, check=True, creationflags=NO_WINDOW)
        runtime = ROOT / ".runtime" / "console"
        runtime.mkdir(parents=True, exist_ok=True)
        options = {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | NO_WINDOW} if os.name == "nt" else {"start_new_session": True}
        with (runtime / "server.log").open("ab") as log:
            child = subprocess.Popen([sys.executable, str(ROOT / "console/server.py"), "--port", str(args.port)], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, **options)
        for _ in range(40):
            status = probe(url)
            if status and status.get("app") == APP_ID and status.get("root") == str(ROOT):
                break
            if child.poll() is not None:
                raise SystemExit(f"Console could not start. See {runtime / 'server.log'}")
            time.sleep(0.25)
        else:
            raise SystemExit(f"Console not ready. See {runtime / 'server.log'}")
    print(f"Console: {url}")
    if not args.no_open:
        webbrowser.open(url)


if __name__ == "__main__":
    main()
