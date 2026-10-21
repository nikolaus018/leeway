#!/usr/bin/env python3
"""Deploys seadata to a Venvy instance and publishes it through the Cloudflare tunnel.

    python3 server/deploy/ship.py login     # once; stores a 30-day session in ~/.config/venvy/
    python3 server/deploy/ship.py           # upload, configure, restart, publish, wait until live

Uploads the server code, styles and chart packs, removes files that no longer exist locally, sets
the port and environment, restarts the app and waits until the new process answers /health.
Standard library only.

Environment (all optional): VENVY_URL (default https://venvy.ringtwo.win), SEADATA_HOSTNAME
(default seadata.ringtwo.win), SEADATA_PORT (8790), APP_NAME (seadata), and values passed on to the
app: AISSTREAM_API_KEY, OPEN_METEO_API_KEY, AIS_BBOX, CACHE_MAX_GB, REQUIRE_CLIENT_HEADER.
"""
import getpass
import hashlib
import http.cookiejar
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

VENVY_URL = os.environ.get("VENVY_URL", "https://venvy.ringtwo.win").rstrip("/")
PUBLIC_HOST = os.environ.get("SEADATA_HOSTNAME", "seadata.ringtwo.win")
PORT = int(os.environ.get("SEADATA_PORT", "8790"))
APP_NAME = os.environ.get("APP_NAME", "seadata")
PASS_THROUGH = ("AISSTREAM_API_KEY", "OPEN_METEO_API_KEY", "AIS_BBOX", "CACHE_MAX_GB", "REQUIRE_CLIENT_HEADER")

SERVER = Path(__file__).resolve().parent.parent
REPO = SERVER.parent
SESSION_FILE = Path.home() / ".config" / "venvy" / f"{urllib.parse.urlparse(VENVY_URL).hostname}.json"
# Folders this script owns on the server: files there that aren't local any more are deleted.
MANAGED = ("src", "styles", "charts", ".cargo")
CHUNK = 8 * 1024 * 1024
# What was uploaded last time, by content hash: the server only lists sizes, and a rebuilt chart pack can keep its size.
MANIFEST = Path.home() / ".config" / "venvy" / f"{APP_NAME}-uploaded.json"
# Cloudflare turns away Python's default User-Agent (error 1010).
USER_AGENT = "seadata-deploy/1.0 (+https://github.com/nikolaus018/leeway)"


def say(message):
    print(f"\033[1m▸ {message}\033[0m", flush=True)


def die(message):
    print(f"\033[31m✗ {message}\033[0m", file=sys.stderr)
    sys.exit(1)


class VenvyError(Exception):
    def __init__(self, code, detail):
        super().__init__(f"{code}: {detail}")
        self.code, self.detail = code, detail


class Venvy:
    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.opener.addheaders = [("User-Agent", USER_AGENT)]
        self.key = ""

    def _cookie(self, name):
        return next((c.value for c in self.jar if c.name == name), "")

    def _set_cookie(self, name, value):
        host = urllib.parse.urlparse(VENVY_URL).hostname
        self.jar.set_cookie(http.cookiejar.Cookie(
            0, name, value, None, False, host, False, False, "/", True, VENVY_URL.startswith("https"),
            None, False, None, None, {}))

    def call(self, method, path, body=None, headers=None, raw=False):
        data = None
        headers = dict(headers or {})
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif isinstance(body, bytes):
            data = body
        headers["X-Venvy-Key"] = self.key
        if method not in ("GET", "HEAD"):
            headers["X-CSRF-Token"] = self._cookie("csrf_token")
        request = urllib.request.Request(f"{VENVY_URL}/api{path}", data=data, method=method, headers=headers)
        if os.environ.get("VENVY_DEBUG"):
            print(f"  {method} {path}", flush=True)
        for attempt in range(5):
            try:
                with self.opener.open(request, timeout=120) as response:
                    payload = response.read()
                    return payload if raw else (json.loads(payload) if payload else None)
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")[:500]
                if error.code == 429 and attempt < 4:
                    wait = int(error.headers.get("Retry-After", "10"))
                    print(f"  rate-limited, waiting {wait} s", flush=True)
                    time.sleep(wait)
                    continue
                raise VenvyError(error.code, f"{method} {path}: {detail}") from None
            except urllib.error.URLError as error:
                if attempt < 4:
                    time.sleep(3)
                    continue
                die(f"{method} {path}: {error}")

    def multipart(self, method, path, fields, files=()):
        boundary = secrets.token_hex(16)
        parts = []
        for name, value in fields:
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        for name, filename, data in files:
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                f"Content-Type: application/octet-stream\r\n\r\n".encode() + data + b"\r\n")
        body = b"".join(parts) + f"--{boundary}--\r\n".encode()
        return self.call(method, path, body, {"Content-Type": f"multipart/form-data; boundary={boundary}"})

    def resume(self):
        if not SESSION_FILE.exists():
            die(f"No Venvy session. Run: python3 {Path(__file__).relative_to(REPO)} login")
        saved = json.loads(SESSION_FILE.read_text())
        self._set_cookie("session", saved["session"])
        self.key = saved["auth_key"]
        self.call("GET", "/auth/status")  # issues the CSRF cookie
        self.call("GET", "/apps")  # proves the session works, and slides it forward

    def login(self):
        self.call("GET", "/auth/status")
        user = input("Venvy user: ")
        body = {"username": user, "password": getpass.getpass("Password: ")}
        try:
            result = self.call("POST", "/auth/login", body)
        except VenvyError as error:
            if error.code != 403 or "totp" not in error.detail:
                raise
            body["totp_code"] = input("2FA code: ")
            result = self.call("POST", "/auth/login", body)
        SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
        SESSION_FILE.write_text(json.dumps({"session": self._cookie("session"), "auth_key": result["auth_key"]}))
        SESSION_FILE.chmod(0o600)
        say(f"Signed in as {result['username']}; session saved to {SESSION_FILE}")

    def wait_job(self, job):
        for _ in range(300):
            status = self.call("GET", f"/jobs/{job}")
            if status["status"] == "done":
                return status.get("result")
            if status["status"] == "error":
                die(f"job {job} failed: {status.get('error')}")
            time.sleep(2)
        die(f"job {job} did not finish")

    def app(self):
        return next((a for a in self.call("GET", "/apps") if a["name"] == APP_NAME), None)

    def remote_files(self, app_id, path="", recursive=True):
        """Files under `path` on the server: {relative path: size}. A missing folder is empty."""
        found = {}
        try:
            entries = self.call("GET", f"/apps/{app_id}/files/tree?path={urllib.parse.quote(path)}") or []
        except VenvyError as error:
            if error.code == 404:
                return found
            raise
        for entry in entries:
            if entry["is_dir"]:
                if recursive:
                    found.update(self.remote_files(app_id, entry["path"]))
            else:
                found[entry["path"]] = entry.get("size")
        return found

    def upload(self, app_id, remote, local):
        data = local.read_bytes()
        upload_id = secrets.token_hex(16)
        offset = 0
        while True:
            chunk = data[offset:offset + CHUNK]
            result = self.multipart("POST", f"/apps/{app_id}/files/upload/chunk", [
                ("upload_id", upload_id), ("path", ""), ("rel_path", remote),
                ("offset", str(offset)), ("total", str(len(data))),
            ], [("chunk", "blob", chunk)])
            offset = result["received"]
            if result["done"]:
                return


def local_files():
    """Remote path → local file, for everything the server needs."""
    files = {name: SERVER / name for name in ("Cargo.toml", "Cargo.lock", "rustfmt.toml") if (SERVER / name).exists()}
    for folder in ("src", "styles", ".cargo"):
        for path in sorted((SERVER / folder).rglob("*")):
            if path.is_file() and not path.name.startswith(".DS_Store"):
                files[str(path.relative_to(SERVER))] = path
    for path in sorted((REPO / "Leeway" / "Charts").iterdir()):
        if path.is_file() and not path.name.startswith("."):
            if path.suffix == ".json" and json.loads(path.read_text()).get("enc"):
                sys.exit(f"{path.name} was built with licensed ENC data (build_vector.py --aquamap): it can't be "
                         "published. Rebuild it without --aquamap first.")
            files[f"charts/{path.name}"] = path
    return files


def ship():
    venvy = Venvy()
    venvy.resume()
    app = venvy.app()
    if app is None:
        say(f"Creating Rust app '{APP_NAME}'")
        created = venvy.multipart("POST", "/apps/upload", [
            ("name", APP_NAME), ("runtime", "rust"), ("start_on_boot", "true"), ("restart_policy", "always"),
        ])
        venvy.wait_job(created["job_id"])
        app = venvy.app()
    app_id = app["id"]
    say(f"App {APP_NAME} (id {app_id}, {app['status']})")

    local = local_files()
    remote = {}
    for folder in MANAGED:
        remote.update(venvy.remote_files(app_id, folder))
    # The app's root, one level only: it also holds the server's cache, which isn't ours to list.
    remote.update(venvy.remote_files(app_id, recursive=False))

    try:
        uploaded = json.loads(MANIFEST.read_text())
    except (OSError, ValueError):
        uploaded = {}
    digest = {p: hashlib.sha256(f.read_bytes()).hexdigest() for p, f in local.items()}
    changed = [p for p, f in local.items()
               if remote.get(p) != f.stat().st_size or uploaded.get(p) != digest[p]]
    gone = [p for p in remote if p.split("/")[0] in MANAGED and p not in local]
    say(f"Uploading {len(changed)} file(s), removing {len(gone)}")
    for path in changed:
        venvy.upload(app_id, path, local[path])
        uploaded[path] = digest[path]
        MANIFEST.parent.mkdir(parents=True, exist_ok=True)
        MANIFEST.write_text(json.dumps(uploaded))
    for path in gone:
        venvy.call("POST", f"/apps/{app_id}/files/op", {"operation": "delete", "path": path})

    say(f"Configuring port {PORT} and environment")
    app = venvy.app()
    env = json.loads(app.get("env_json") or "{}")
    env.setdefault("CACHE_DIR", "cache")
    env.setdefault("RUST_LOG", "seadata=info,tower_http=warn")
    env["PUBLIC_URL"] = f"https://{PUBLIC_HOST}"
    for key in PASS_THROUGH:
        if os.environ.get(key):
            env[key] = os.environ[key]
    venvy.call("PUT", f"/apps/{app_id}", {
        "port": PORT, "manual_ports": [PORT], "env_vars": env, "start_on_boot": True, "restart_policy": "always",
    })

    action = "restart" if app["status"] == "running" else "start"
    say(f"Sending {action}")
    sent = time.time()
    venvy.call("POST", f"/apps/{app_id}/control?action={action}")

    tunnel = venvy.call("GET", f"/apps/{app_id}/tunnel")
    if PUBLIC_HOST not in json.dumps(tunnel):
        say(f"Publishing https://{PUBLIC_HOST}")
        venvy.call("POST", f"/apps/{app_id}/tunnel/publish", {"hostname": PUBLIC_HOST, "local_port": PORT})

    health = f"https://{PUBLIC_HOST}/health"
    say(f"Waiting for {health} (the first build after a dependency change takes a few minutes)")
    down = 0
    for _ in range(150):
        try:
            with urllib.request.urlopen(urllib.request.Request(health, headers={"User-Agent": USER_AGENT}), timeout=5) as response:
                uptime = json.loads(response.read()).get("uptimeSeconds", 1e9)
            # Only the new process counts: it must have started after the restart was sent.
            if uptime <= time.time() - sent + 1:
                say(f"Live: https://{PUBLIC_HOST}/v1/info")
                info = urllib.request.Request(f"https://{PUBLIC_HOST}/v1/info", headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(info, timeout=10) as response:
                    print(response.read().decode())
                return
        except (urllib.error.URLError, TimeoutError, ValueError):
            pass
        status = venvy.app()["status"]
        down = down + 1 if status in ("error", "stopped") else 0
        if down >= 3:
            print(venvy.call("GET", f"/apps/{app_id}/logs?lines=60")["content"])
            die(f"app is {status}; log above")
        time.sleep(10)
    print(venvy.call("GET", f"/apps/{app_id}/logs?lines=40")["content"])
    die(f"{health} did not come up within 25 minutes; log above")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["login"]:
            Venvy().login()
        elif sys.argv[1:]:
            die("usage: ship.py [login]")
        else:
            ship()
    except VenvyError as error:
        if error.code == 401:
            die(f"Venvy session expired or missing. Run: python3 {Path(__file__).relative_to(REPO)} login")
        die(str(error))
