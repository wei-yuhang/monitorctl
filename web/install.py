#!/usr/bin/env python3
"""Install Monitor Deck as a user LaunchAgent in the graphical login session."""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.request import ProxyHandler, build_opener

SOURCE = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/monitorctl"
APP = SUPPORT / "dashboard"
AGENTS = Path.home() / "Library/LaunchAgents"
LABEL = "local.monitorctl.dashboard"
PLIST = AGENTS / f"{LABEL}.plist"
DOMAIN = f"gui/{os.getuid()}"
JOB = f"{DOMAIN}/{LABEL}"
URL = "http://127.0.0.1:41847"


def launchctl(*args, check=True):
    return subprocess.run(["/bin/launchctl", *args], check=check, capture_output=True, text=True)


def wait_ready():
    opener = build_opener(ProxyHandler({}))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with opener.open(f"{URL}/api/state", timeout=2) as response:
                data = json.load(response)
            if isinstance(data.get("displays"), list) and launchctl("print", JOB, check=False).returncode == 0:
                return data["displays"]
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    raise RuntimeError(f"The dashboard did not become ready. See {SUPPORT / 'dashboard.log'}.")


def install():
    if not Path("/usr/local/bin/monitorctl").is_file():
        raise SystemExit("Install monitorctl before installing its dashboard.")
    launchctl("print", DOMAIN)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    AGENTS.mkdir(parents=True, exist_ok=True)
    config = {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", str(APP / "server.py")],
        "RunAtLoad": True,
        "KeepAlive": True,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Background",
        "StandardOutPath": str(SUPPORT / "dashboard.log"),
        "StandardErrorPath": str(SUPPORT / "dashboard.log"),
    }
    original = PLIST.read_bytes() if PLIST.is_file() else None
    was_loaded = launchctl("print", JOB, check=False).returncode == 0
    with tempfile.TemporaryDirectory(prefix=".dashboard-install-", dir=SUPPORT) as tmp:
        stage = Path(tmp) / "app"
        backup = Path(tmp) / "previous"
        stage.mkdir()
        for file in ("server.py", "layout.swift", "install.py", "README.md"):
            shutil.copy2(SOURCE / file, stage / file)
        shutil.copytree(SOURCE / "static", stage / "static")
        subprocess.run([
            "/usr/bin/swiftc", "-O", "-module-cache-path", str(Path(tmp) / "module-cache"),
            str(stage / "layout.swift"), "-o", str(stage / "layout"),
        ], check=True)
        new_plist = AGENTS / f".{LABEL}.{os.getpid()}.plist"
        new_plist.write_bytes(plistlib.dumps(config))
        moved_original = False
        installed_new = False
        try:
            if was_loaded:
                launchctl("bootout", JOB)
            if APP.exists():
                APP.rename(backup)
                moved_original = True
            stage.rename(APP)
            installed_new = True
            new_plist.replace(PLIST)
            launchctl("bootstrap", DOMAIN, str(PLIST))
            displays = wait_ready()
        except BaseException:
            launchctl("bootout", JOB, check=False)
            if installed_new:
                shutil.rmtree(APP)
            if moved_original:
                backup.rename(APP)
            if original is None:
                PLIST.unlink(missing_ok=True)
            else:
                PLIST.write_bytes(original)
            if was_loaded:
                launchctl("bootstrap", DOMAIN, str(PLIST), check=False)
            raise
        finally:
            new_plist.unlink(missing_ok=True)
    print(f"Monitor Deck is running at {URL} ({len(displays)} active displays).")


if __name__ == "__main__":
    install()
