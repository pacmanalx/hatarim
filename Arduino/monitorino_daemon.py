#!/usr/bin/env python3
"""
monitorino_daemon.py — daemon de comunicação serial pro MonitorINO.

Mantém UMA conexão serial aberta com o Mega (sem auto-reset entre comandos)
e processa arquivos escritos em ~/Library/Application Support/MonitorINO2/send_commands/.

Cada arquivo contém uma linha "TOKEN:VALOR". Daemon:
  1. Lista arquivos, ORDENA POR NOME (prefixos 00_ vêm antes de 99_)
  2. Pra cada um: lê, encoda com checksum XOR, manda, espera ACK, deleta
  3. Sleep 50ms quando vazio

Convenção de nomes:
  cmd_00_<ts>_<token>.txt   → atuação (FAN) — alta prioridade
  cmd_99_<ts>_<token>.txt   → telemetria — baixa prioridade

Uso:
    python3 monitorino_daemon.py
    python3 monitorino_daemon.py --baud 115200
"""
from __future__ import annotations
import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path

import serial


HOME = Path.home()
SUPPORT_DIR = HOME / "Library" / "Application Support" / "MonitorINO2"
SEND_DIR = SUPPORT_DIR / "send_commands"
STATUS_FILE = SUPPORT_DIR / "daemon_status.json"
STATUS_TMP = SUPPORT_DIR / "daemon_status.json.tmp"
LOG_DIR = HOME / "Library" / "Logs" / "MonitorINO2"
LOG_FILE = LOG_DIR / "monitorino_daemon.log"

# Stats rolling pra resumo periódico
_stats = {"sent": 0, "ok": 0, "fail": 0}

# Estado pro heartbeat — preenchido pelo loop principal.
_status = {
    "pid": os.getpid(),
    "started_at": time.time(),
    "port": None,
    "baud": 0,
    "connected": False,
    "last_ack_ts": 0.0,
    "last_payload": "",
    "consecutive_fails": 0,
}
_last_status_write = 0.0


def write_status(force: bool = False) -> None:
    """Escreve daemon_status.json atomicamente. Throttled pra ~2 Hz."""
    global _last_status_write
    now = time.time()
    if not force and (now - _last_status_write) < 0.5:
        return
    _last_status_write = now
    try:
        backlog = sum(1 for p in SEND_DIR.iterdir() if p.is_file() and not p.name.startswith("."))
    except OSError:
        backlog = -1
    rate = (_stats["ok"] / _stats["sent"] * 100) if _stats["sent"] > 0 else 100.0
    snap = {
        **_status,
        "now": now,
        "uptime_sec": now - _status["started_at"],
        "ack_ok": _stats["ok"],
        "ack_fail": _stats["fail"],
        "ack_sent": _stats["sent"],
        "ack_rate_pct": rate,
        "backlog_files": backlog,
    }
    try:
        STATUS_TMP.write_text(json.dumps(snap, indent=2))
        STATUS_TMP.replace(STATUS_FILE)
    except OSError:
        pass


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def find_port_or_none() -> str | None:
    """Retorna a primeira porta /dev/cu.usbmodem* ou None se nenhuma existe."""
    candidates = (
        glob.glob("/dev/cu.usbmodem*")
        + glob.glob("/dev/cu.usbserial*")
        + glob.glob("/dev/cu.wchusbserial*")
    )
    return sorted(candidates)[0] if candidates else None


def find_port_blocking() -> str:
    """Espera até uma porta aparecer. Loga periodicamente."""
    waited = 0
    while True:
        port = find_port_or_none()
        if port:
            return port
        if waited % 30 == 0:
            log(f"aguardando Mega aparecer no USB... ({waited}s)")
        time.sleep(2)
        waited += 2


def encode_line(token: str, value: str) -> bytes:
    payload = f"{token}:{value};".encode("ascii")
    cs = 0
    for b in payload:
        cs ^= b
    return payload + f"{cs & 0xFF:02X}".encode() + b"\n"


def process_file(ser: serial.Serial, path: Path) -> tuple[bool, float, str, str] | None:
    """Lê conteúdo (TOKEN:VALOR), manda, espera ACK. Retorna (ok, dt_ms, info, payload).
    Retorna None se o arquivo já não existe."""
    try:
        content = path.read_text().strip()
    except FileNotFoundError:
        return None
    except OSError as e:
        return False, 0.0, f"read fail: {e}", "?"

    if ":" not in content:
        return False, 0.0, f"formato inválido: {content!r}", content

    token, value = content.split(":", 1)
    line = encode_line(token, value)

    t0 = time.perf_counter()
    try:
        ser.reset_input_buffer()
        n = ser.write(line)
        ser.flush()
        deadline = time.perf_counter() + 2.0
        ack = b""
        while time.perf_counter() < deadline:
            chunk = ser.read(64)
            if chunk:
                ack += chunk
                if b"\n" in ack:
                    break
        dt_ms = (time.perf_counter() - t0) * 1000
    except serial.SerialException as e:
        return False, 0.0, f"serial: {e}"

    expected = f"{token}:{value};".encode()
    if expected in ack:
        return True, dt_ms, "ack ok", content
    return False, dt_ms, f"ack inválido: {ack!r}", content


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--no-boot-wait", action="store_true")
    p.add_argument("--quiet", action="store_true",
                   help="suprime log de cada comando (só falhas e resumos)")
    args = p.parse_args()

    SEND_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    log(f"=== monitorino_daemon START ===")
    _status["baud"] = args.baud
    write_status(force=True)
    port = args.port or find_port_blocking()
    _status["port"] = port
    log(f"porta: {port} @ {args.baud}")
    log(f"watching: {SEND_DIR}")
    write_status(force=True)

    ser: serial.Serial | None = None
    while ser is None:
        try:
            ser = serial.Serial(port, args.baud, timeout=0.05)
        except serial.SerialException as e:
            log(f"WARN: não consegui abrir {port}: {e} — retry em 3s")
            time.sleep(3)
            port = args.port or find_port_blocking()

    if not args.no_boot_wait:
        log("aguardando boot do Mega (5s)...")
        time.sleep(5.0)
        ser.reset_input_buffer()

    _status["connected"] = True
    write_status(force=True)
    log("daemon pronto, polling 50ms")

    last_summary = time.time()
    try:
        consecutive_fails = 0
        while True:
          try:
            files = sorted(p for p in SEND_DIR.iterdir() if p.is_file() and not p.name.startswith("."))
            for f in files:
                result = process_file(ser, f)
                if result is None:
                    continue
                ok, dt_ms, info, payload = result
                _stats["sent"] += 1
                if ok:
                    _stats["ok"] += 1
                    consecutive_fails = 0
                    _status["last_ack_ts"] = time.time()
                    _status["last_payload"] = payload
                else:
                    _stats["fail"] += 1
                    consecutive_fails += 1
                _status["consecutive_fails"] = consecutive_fails
                write_status()
                # FAN sempre loga (mesmo em --quiet) pra debugar atuação
                is_fan = payload.startswith("FAN:")
                if (not args.quiet) or not ok or is_fan:
                    tag = "OK " if ok else "FAIL"
                    log(f"{tag} sent={payload!r} dt={dt_ms:.1f}ms {info}")
                try:
                    f.unlink()
                except FileNotFoundError:
                    pass  # já deletado em outro lugar, OK
                except OSError as e:
                    log(f"WARN: não deletei {f.name}: {e}")
                # Auto-reconnect: 3 falhas consecutivas geralmente significam
                # que ATmega16U2 (USB bridge) entrou em estado weird após EMI
                # do relé chaveando AC. Fechar/reabrir o fd ressincroniza.
                if consecutive_fails >= 3:
                    log(f"!!! {consecutive_fails} falhas consecutivas — RECONNECT")
                    _status["connected"] = False
                    write_status(force=True)
                    try:
                        ser.close()
                    except Exception:
                        pass
                    ser = None
                    time.sleep(1.0)
                    for stale in SEND_DIR.iterdir():
                        if stale.is_file() and stale.name.startswith("cmd_99_"):
                            try:
                                stale.unlink()
                            except OSError:
                                pass
                    # Reconnect com retry forever — Mega pode ter desaparecido do
                    # USB (CDC crash), reenumerado com nome novo (cu.usbmodem11101
                    # vs cu.usbmodem2201), ou estar mortinho. find_port_blocking
                    # espera ele aparecer; qualquer exception (não só SerialException)
                    # vira retry — daemon NÃO morre.
                    while ser is None:
                        try:
                            new_port = args.port or find_port_blocking()
                            ser = serial.Serial(new_port, args.baud, timeout=0.05)
                            time.sleep(2.0)
                            ser.reset_input_buffer()
                            _status["port"] = new_port
                            _status["connected"] = True
                            write_status(force=True)
                            log(f"RECONNECT ok em {new_port}")
                        except Exception as e:
                            log(f"RECONNECT falhou ({type(e).__name__}: {e}) — retry em 3s")
                            ser = None
                            time.sleep(3)
                    consecutive_fails = 0
                    _status["consecutive_fails"] = 0

            # Resumo a cada 30s
            now = time.time()
            if now - last_summary >= 30:
                if _stats["sent"] > 0:
                    rate = _stats["ok"] / _stats["sent"] * 100
                    log(f"--- {_stats['sent']} msgs · ACK {rate:.1f}% (ok={_stats['ok']} fail={_stats['fail']}) ---")
                last_summary = now

            if not files:
                write_status()
                time.sleep(0.05)
          except KeyboardInterrupt:
            raise
          except Exception as e:
            # Catch-all: qualquer exceção que não veio de KeyboardInterrupt vira
            # log + reconnect. Daemon NUNCA morre por bug imprevisto.
            log(f"!!! exceção não tratada: {type(e).__name__}: {e}")
            _status["connected"] = False
            write_status(force=True)
            try: ser.close()
            except Exception: pass
            ser = None
            while ser is None:
                try:
                    new_port = args.port or find_port_blocking()
                    ser = serial.Serial(new_port, args.baud, timeout=0.05)
                    time.sleep(2.0)
                    ser.reset_input_buffer()
                    _status["port"] = new_port
                    _status["connected"] = True
                    write_status(force=True)
                    log(f"RECOVER ok em {new_port}")
                except Exception as e2:
                    log(f"RECOVER falhou ({type(e2).__name__}: {e2}) — retry em 3s")
                    ser = None
                    time.sleep(3)
            consecutive_fails = 0
            _status["consecutive_fails"] = 0
    except KeyboardInterrupt:
        log("daemon parado (Ctrl-C)")
    finally:
        ser.close()
        if _stats["sent"] > 0:
            rate = _stats["ok"] / _stats["sent"] * 100
            log(f"=== final: {_stats['sent']} msgs · ACK {rate:.1f}% ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
