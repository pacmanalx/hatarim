#!/usr/bin/env python3
"""
fan_daemon.py — daemon que mantém a serial aberta e processa comandos
escritos como arquivos em ~/Library/Application Support/HaTarim/send_commands/.

Cada arquivo contém uma linha "TOKEN:VALOR" (ex: "FAN:1"). O daemon:
  1. Abre serial UMA VEZ (5s pra Mega bootar; subsequente sem reset)
  2. Loop: lista arquivos, ordena por nome, lê, encoda com checksum, manda,
     espera ACK, apaga o arquivo
  3. Logs em ~/Library/Logs/HaTarim/fan_daemon.log

Uso:
    python3 fan_daemon.py
    python3 fan_daemon.py --port /dev/cu.usbmodem2201
"""
from __future__ import annotations
import argparse
import glob
import os
import sys
import time
from pathlib import Path

import serial


HOME = Path.home()
SEND_DIR = HOME / "Library" / "Application Support" / "HaTarim" / "send_commands"
LOG_DIR = HOME / "Library" / "Logs" / "HaTarim"
LOG_FILE = LOG_DIR / "fan_daemon.log"


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def find_port() -> str:
    candidates = (
        glob.glob("/dev/cu.usbmodem*")
        + glob.glob("/dev/cu.usbserial*")
        + glob.glob("/dev/cu.wchusbserial*")
    )
    if not candidates:
        log("ERRO: nenhuma porta /dev/cu.usbmodem*")
        sys.exit(1)
    return sorted(candidates)[0]


def encode_line(token: str, value: str) -> bytes:
    payload = f"{token}:{value};".encode("ascii")
    cs = 0
    for b in payload:
        cs ^= b
    return payload + f"{cs & 0xFF:02X}".encode() + b"\n"


def process_file(ser: serial.Serial, path: Path) -> tuple[bool, float, str]:
    """Lê conteúdo, parseia TOKEN:VALOR, manda, espera ACK. Retorna (ok, dt_ms, info)."""
    try:
        content = path.read_text().strip()
    except OSError as e:
        return False, 0.0, f"read_text fail: {e}"

    if ":" not in content:
        return False, 0.0, f"formato inválido: {content!r}"

    token, value = content.split(":", 1)
    line = encode_line(token, value)

    t0 = time.perf_counter()
    try:
        ser.reset_input_buffer()
        ser.write(line)
        ser.flush()
        # Lê ACK em chunks (mais robusto que readline em USB CDC)
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
        return True, dt_ms, ack.decode(errors="replace").strip()
    return False, dt_ms, f"ack inválido: {ack!r}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port")
    p.add_argument("--baud", type=int, default=9600)
    p.add_argument("--no-boot-wait", action="store_true")
    args = p.parse_args()

    SEND_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    port = args.port or find_port()
    log(f"=== fan_daemon START ===")
    log(f"porta: {port} @ {args.baud}")
    log(f"watching: {SEND_DIR}")

    try:
        ser = serial.Serial(port, args.baud, timeout=0.05)
    except serial.SerialException as e:
        log(f"FATAL: não consegui abrir {port}: {e}")
        return 1

    if not args.no_boot_wait:
        log("aguardando boot do Mega (5s)...")
        time.sleep(5.0)
        ser.reset_input_buffer()

    log("daemon pronto, polling 50ms")

    try:
        while True:
            files = sorted(p for p in SEND_DIR.iterdir() if p.is_file() and not p.name.startswith("."))
            for f in files:
                ok, dt_ms, info = process_file(ser, f)
                tag = "OK " if ok else "FAIL"
                log(f"{tag} {f.name} dt={dt_ms:.1f}ms {info}")
                try:
                    f.unlink()
                except OSError as e:
                    log(f"WARN: não consegui deletar {f.name}: {e}")
            if not files:
                time.sleep(0.05)
    except KeyboardInterrupt:
        log("daemon parado (Ctrl-C)")
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
