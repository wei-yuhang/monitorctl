#!/usr/bin/env python3
"""Loopback dashboard for the installed monitorctl CLI."""
import fcntl
import hmac
import json
import math
import re
import secrets
import subprocess
import tempfile
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
CLI = "/usr/local/bin/monitorctl"
LAYOUT = ROOT / "layout"
STATE = Path.home() / "Library/Application Support/monitorctl/state"
ADDRESS = "127.0.0.1"
PORT = 41847
HOST = f"{ADDRESS}:{PORT}"
ORIGIN = f"http://{HOST}"
TOKEN = secrets.token_urlsafe(32)
UUID_PATTERN = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/geometry.js": ("geometry.js", "text/javascript; charset=utf-8"),
    "/icon.svg": ("icon.svg", "image/svg+xml"),
}


class DashboardError(Exception):
    pass


def command(args, data=None):
    result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True, timeout=12)
    try:
        parsed = json.loads(result.stdout)
    except ValueError:
        if result.returncode:
            raise DashboardError(result.stderr.strip() or "The display command failed.")
        raise DashboardError("The display command returned an invalid response.")
    if result.returncode or (isinstance(parsed, dict) and parsed.get("ok") is False):
        error = parsed.get("error", {}) if isinstance(parsed, dict) else {}
        raise DashboardError(error.get("message") or result.stderr.strip() or "Display change failed.")
    return parsed


def cli(*args):
    return command([CLI, *args, "--json"])


def get_state():
    state = cli("status")
    layout = command([str(LAYOUT), "list"])
    catalog = {item["uuid"]: item for item in state["displays"]}
    return {
        "displays": [dict(catalog.get(item["uuid"], {}), **item) for item in layout],
        "preview": state.get("preview"),
        "can_undo_layout": (STATE / "layout-last.json").is_file(),
        "token": TOKEN,
    }


def display_uuid(value):
    if not isinstance(value, str) or not UUID_PATTERN.fullmatch(value):
        raise DashboardError("Select a connected display.")
    return value.upper()


def positions(items):
    if not isinstance(items, list) or len(items) > 128:
        raise DashboardError("Invalid arrangement.")
    result = []
    for item in items:
        if not isinstance(item, dict):
            raise DashboardError("Invalid display position.")
        if any(type(item.get(key)) is not int or abs(item[key]) > 100_000 for key in ("x", "y")):
            raise DashboardError("Invalid display coordinates.")
        result.append({"uuid": display_uuid(item.get("uuid")), "x": item["x"], "y": item["y"]})
    return result


def geometry(items):
    return [
        {key: item[key] for key in ("uuid", "x", "y", "width", "height")}
        for item in sorted(items, key=lambda item: item["uuid"])
    ]


@contextmanager
def layout_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "mutation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DashboardError("A display change is already in progress.")
        if (STATE / "preview.json").exists():
            raise DashboardError("Keep or revert the current mode preview first.")
        yield


def arrange(body, undo=False):
    with layout_lock():
        before = command([str(LAYOUT), "list"])
        saved_path = STATE / "layout-last.json"
        if undo:
            if not saved_path.is_file():
                raise DashboardError("There is no saved arrangement to undo.")
            saved = json.loads(saved_path.read_text())
            if geometry(before) != saved["after"]:
                raise DashboardError("The arrangement changed since the last dashboard edit.")
            requested = positions(saved["before"])
        else:
            requested = positions(body.get("positions"))
            if body.get("expected") != geometry(before):
                raise DashboardError("Display positions or sizes changed. Reload the arrangement.")
        if sorted(requested, key=lambda d: d["uuid"]) == sorted(positions(before), key=lambda d: d["uuid"]):
            return {"layout": before, "adjusted": False}
        after = command([str(LAYOUT), "apply"], {"positions": requested, "expected": geometry(before)})
        with tempfile.NamedTemporaryFile(mode="w", dir=STATE, delete=False) as file:
            temp = Path(file.name)
            try:
                json.dump({"before": positions(before), "after": geometry(after)}, file)
                file.flush()
                temp.replace(saved_path)
            finally:
                if temp.exists():
                    temp.unlink()
        adjusted = sorted(positions(after), key=lambda d: d["uuid"]) != sorted(requested, key=lambda d: d["uuid"])
        return {"layout": after, "adjusted": adjusted}


def change_mode(body):
    target = display_uuid(body.get("display"))
    width, height = body.get("width"), body.get("height")
    refresh = body.get("hz")
    if any(type(value) is not int or not 10 <= value <= 32768 for value in (width, height)):
        raise DashboardError("Select an available resolution.")
    if type(refresh) not in (int, float) or not math.isfinite(refresh) or not 0 <= refresh <= 1000:
        raise DashboardError("Select an available refresh rate.")
    if type(body.get("hidpi")) is not bool:
        raise DashboardError("Select an available rendering mode.")
    args = ["resolution", f"{width}x{height}", "--display", target]
    if not body["hidpi"]:
        args.append("--standard")
    if refresh:
        args += ["--refresh", str(refresh)]
    if body.get("preview", True) is True:
        args += ["--preview", "20"]
    if body.get("permanent", True) is True:
        args.append("--permanent")
    return cli(*args)


def mutate(path, body):
    if path == "/api/layout":
        return arrange(body)
    if path == "/api/layout/undo":
        return arrange(body, undo=True)
    if path == "/api/mode":
        return change_mode(body)
    if path in ("/api/confirm", "/api/revert"):
        token = body.get("token")
        if not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{16}", token):
            raise DashboardError("This preview has expired.")
        return cli(path.rsplit("/", 1)[-1], token)
    if path == "/api/mode/undo":
        return cli("undo", "--permanent")
    raise DashboardError("Unknown dashboard action.")


class Handler(BaseHTTPRequestHandler):
    server_version = "MonitorDeck"
    timeout = 10

    def send(self, status, content, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self'; style-src 'self'; "
                         "img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(content)

    def json(self, status, value):
        self.send(status, json.dumps(value).encode(), "application/json; charset=utf-8")

    def allowed_host(self):
        if self.headers.get("Host") != HOST:
            self.json(403, {"error": "Open the dashboard from its local address."})
            return False
        return True

    def handle_error(self, error):
        if isinstance(error, DashboardError):
            self.json(409, {"error": str(error)})
        elif isinstance(error, (TypeError, ValueError, KeyError)):
            self.json(400, {"error": "Invalid dashboard request."})
        else:
            self.log_error("%s", error)
            self.json(503, {"error": "The display service could not complete the request."})

    def do_GET(self):
        if not self.allowed_host():
            return
        url = urlsplit(self.path)
        if url.path.startswith("/api/") and self.headers.get("Sec-Fetch-Site") in ("cross-site", "same-site"):
            self.json(403, {"error": "Open the dashboard from its local address."})
            return
        try:
            if url.path in STATIC:
                file, mime = STATIC[url.path]
                self.send(200, (ROOT / "static" / file).read_bytes(), mime)
            elif url.path == "/api/state":
                self.json(200, get_state())
            elif url.path == "/api/modes":
                selector = display_uuid(parse_qs(url.query).get("display", [None])[0])
                self.json(200, cli("modes", "--display", selector))
            else:
                self.json(404, {"error": "Page not found."})
        except Exception as error:
            self.handle_error(error)

    def do_POST(self):
        if not self.allowed_host():
            return
        if (self.headers.get("Origin") != ORIGIN
                or not hmac.compare_digest(self.headers.get("X-Monitor-Token", ""), TOKEN)
                or self.headers.get_content_type() != "application/json"):
            self.json(403, {"error": "Reload the dashboard before applying changes."})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 65536:
                raise ValueError("Invalid body size")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("Invalid body")
            self.json(200, mutate(urlsplit(self.path).path, body))
        except Exception as error:
            self.handle_error(error)

    def log_request(self, code="-", size="-"):
        if str(code).startswith(("4", "5")):
            super().log_request(code, size)


if __name__ == "__main__":
    server = ThreadingHTTPServer((ADDRESS, PORT), Handler)
    print(f"Monitor Deck is listening at {ORIGIN}", flush=True)
    server.serve_forever()
