#!/usr/bin/env python3
"""HaTarim Linux — daemon de telemetria + health checks por serviço.

Lê ~/.config/hatarim/services.json, roda os checks de cada serviço no seu
intervalo próprio, coleta vitals do host, grava ~/.local/share/hatarim/snapshot.json
no tick principal (default 5s) e history.jsonl em mudanças de estado.

Zero deps fora da stdlib. Roda em qualquer Python 3.9+.
"""
from __future__ import annotations
import json
import os
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CONFIG = Path(os.environ.get("HATARIM_CONFIG", "~/.config/hatarim/services.json")).expanduser()
STATE_DIR = Path(os.environ.get("HATARIM_STATE", "~/.local/share/hatarim")).expanduser()
SNAPSHOT = STATE_DIR / "snapshot.json"
HISTORY = STATE_DIR / "history.jsonl"
DEFAULT_TICK_SEC = 5
DEFAULT_SERVICE_INTERVAL_SEC = 30


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# Vitals do host (CPU/mem/disk/net) — leitura direta do /proc e /sys.
# ---------------------------------------------------------------------------
def read_cpu() -> dict[str, Any]:
    try:
        load1 = float(Path("/proc/loadavg").read_text().split()[0])
    except Exception:
        load1 = 0.0
    threads = os.cpu_count() or 1
    return {"load1": load1, "loadPct": round(load1 / threads * 100, 1), "threads": threads}


def read_mem() -> dict[str, Any]:
    try:
        info: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            info[k] = int(v.strip().split()[0]) * 1024
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        used = total - avail
        return {"totalBytes": total, "usedBytes": used, "usedPct": round(used / total * 100, 1) if total else 0.0}
    except Exception:
        return {"totalBytes": 0, "usedBytes": 0, "usedPct": 0.0}


def read_disk(mountpoint: str = "/") -> dict[str, Any]:
    try:
        s = os.statvfs(mountpoint)
        total = s.f_blocks * s.f_frsize
        free = s.f_bavail * s.f_frsize
        used = total - free
        return {"totalBytes": total, "usedBytes": used, "usedPct": round(used / total * 100, 1) if total else 0.0}
    except Exception:
        return {"totalBytes": 0, "usedBytes": 0, "usedPct": 0.0}


# ---------------------------------------------------------------------------
# Checks — cada tipo é uma função pura (devolve dict com `ok` e `detail`).
# ---------------------------------------------------------------------------
def check_systemd(cfg: dict[str, Any]) -> dict[str, Any]:
    unit = cfg["unit"]
    scope = cfg.get("scope", "system")
    args = ["systemctl"]
    if scope == "user":
        args.append("--user")
    args += ["is-active", unit]
    r = subprocess.run(args, capture_output=True, text=True, timeout=5)
    out = r.stdout.strip() or r.stderr.strip()
    return {"type": "systemd", "unit": unit, "ok": out == "active", "detail": out}


def check_port(cfg: dict[str, Any]) -> dict[str, Any]:
    host = cfg.get("host", "127.0.0.1")
    port = int(cfg["port"])
    try:
        with socket.create_connection((host, port), timeout=cfg.get("timeoutSec", 2)):
            return {"type": "port", "host": host, "port": port, "ok": True, "detail": "connect ok"}
    except Exception as e:
        return {"type": "port", "host": host, "port": port, "ok": False, "detail": str(e)}


def check_http(cfg: dict[str, Any]) -> dict[str, Any]:
    url = cfg["url"]
    expected_status = int(cfg.get("expectedStatus", 200))
    expected_sub = cfg.get("expectedSubstring", "")
    try:
        req = Request(url, headers={"User-Agent": "HaTarim-Linux/0.1"})
        with urlopen(req, timeout=cfg.get("timeoutSec", 5)) as r:
            body = r.read(2048).decode("utf-8", errors="replace")
            ok = r.status == expected_status and (expected_sub in body if expected_sub else True)
            return {"type": "http", "url": url, "ok": ok, "detail": f"HTTP {r.status}"}
    except HTTPError as e:
        return {"type": "http", "url": url, "ok": False, "detail": f"HTTP {e.code}"}
    except (URLError, TimeoutError, Exception) as e:
        return {"type": "http", "url": url, "ok": False, "detail": str(e)[:120]}


def check_command(cfg: dict[str, Any]) -> dict[str, Any]:
    cmd = cfg["cmd"]
    expected_sub = cfg.get("expectedSubstring", "")
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=cfg.get("timeoutSec", 5))
        out = (r.stdout + r.stderr).strip()[:200]
        ok = r.returncode == 0 and (expected_sub in out if expected_sub else True)
        return {"type": "command", "cmd": cmd, "ok": ok, "detail": out or f"exit {r.returncode}"}
    except Exception as e:
        return {"type": "command", "cmd": cmd, "ok": False, "detail": str(e)}


CHECK_FNS = {
    "systemd": check_systemd,
    "port": check_port,
    "http": check_http,
    "command": check_command,
}


def run_check(cfg: dict[str, Any]) -> dict[str, Any]:
    fn = CHECK_FNS.get(cfg["type"])
    if fn is None:
        return {"type": cfg["type"], "ok": False, "detail": f"unknown check type"}
    try:
        return fn(cfg)
    except subprocess.TimeoutExpired:
        return {"type": cfg["type"], "ok": False, "detail": "timeout"}
    except Exception as e:
        return {"type": cfg["type"], "ok": False, "detail": f"check error: {e}"[:120]}


# ---------------------------------------------------------------------------
# Estado por serviço — mantém últimos resultados e cadência própria.
# ---------------------------------------------------------------------------
class ServiceState:
    def __init__(self, cfg: dict[str, Any], default_interval: int):
        self.id = cfg["id"]
        self.name = cfg.get("name", cfg["id"])
        self.interval = int(cfg.get("intervalSec", default_interval))
        self.checks_cfg = cfg["checks"]
        self.last_run = 0.0
        self.last_results: list[dict[str, Any]] = []
        self.state = "unknown"
        self.last_change: str | None = None

    def due(self, now_ts: float) -> bool:
        return (now_ts - self.last_run) >= self.interval

    def run(self) -> bool:
        """Roda os checks; devolve True se o estado mudou."""
        self.last_run = time.time()
        self.last_results = [run_check(c) for c in self.checks_cfg]
        new_state = "noAr" if all(r["ok"] for r in self.last_results) else "fora"
        changed = new_state != self.state
        if changed:
            self.last_change = now_iso()
            self.state = new_state
        return changed

    def snapshot(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "state": self.state,
            "lastCheck": now_iso() if self.last_run else None,
            "intervalSec": self.interval,
            "checks": self.last_results,
            "lastChange": self.last_change,
        }


# ---------------------------------------------------------------------------
# Loop principal.
# ---------------------------------------------------------------------------
def write_snapshot(services: list[ServiceState]) -> None:
    snap = {
        "ts": now_iso(),
        "host": socket.gethostname(),
        "cpu": read_cpu(),
        "mem": read_mem(),
        "disk": {"root": read_disk("/")},
        "services": [s.snapshot() for s in services],
    }
    tmp = SNAPSHOT.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(snap, indent=2))
    tmp.replace(SNAPSHOT)


def append_history(service: ServiceState) -> None:
    event = {
        "ts": now_iso(),
        "sid": service.id,
        "sn": service.name,
        "state": service.state,
        "checks": [{"type": c["type"], "ok": c["ok"], "detail": c.get("detail")} for c in service.last_results],
    }
    with HISTORY.open("a") as f:
        f.write(json.dumps(event) + "\n")


def load_config() -> tuple[int, list[ServiceState]]:
    cfg = json.loads(CONFIG.read_text())
    tick = int(cfg.get("intervalSec", DEFAULT_TICK_SEC))
    services = [ServiceState(s, DEFAULT_SERVICE_INTERVAL_SEC) for s in cfg.get("services", [])]
    return tick, services


def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG.exists():
        print(f"HaTarim: config não encontrado em {CONFIG}", file=sys.stderr)
        return 2
    tick, services = load_config()
    print(f"HaTarim Linux iniciado · tick={tick}s · {len(services)} serviços · snapshot={SNAPSHOT}", flush=True)

    while True:
        now = time.time()
        for s in services:
            if s.due(now):
                try:
                    changed = s.run()
                    if changed:
                        append_history(s)
                        print(f"[{now_iso()}] {s.id} → {s.state}", flush=True)
                except Exception as e:
                    print(f"HaTarim: erro ao rodar {s.id}: {e}", file=sys.stderr, flush=True)
        try:
            write_snapshot(services)
        except Exception as e:
            print(f"HaTarim: erro ao gravar snapshot: {e}", file=sys.stderr, flush=True)
        time.sleep(tick)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
