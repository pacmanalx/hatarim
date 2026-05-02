#!/usr/bin/env python3
"""
fan_diag.py — manda FAN:1 e mostra TODOS os bytes que chegam pelos próximos 3s.
"""
from __future__ import annotations
import sys
import time
import glob
import serial


def find_port():
    candidates = (
        glob.glob("/dev/cu.usbmodem*")
        + glob.glob("/dev/cu.usbserial*")
        + glob.glob("/dev/cu.wchusbserial*")
    )
    if not candidates:
        sys.exit("nenhuma porta")
    return sorted(candidates)[0]


def main():
    port = find_port()
    print(f"Porta: {port}")
    ser = serial.Serial(port, 115200, timeout=0.1)
    print("aguardando boot 5s...")
    time.sleep(5)
    ser.reset_input_buffer()

    # Monta FAN:1;79\n
    payload = b"FAN:1;"
    cs = 0
    for b in payload:
        cs ^= b
    line = payload + f"{cs:02X}".encode() + b"\n"
    print(f"TX: {line!r}")

    t0 = time.perf_counter()
    ser.write(line)
    ser.flush()

    print("Lendo resposta por 3s...")
    end = t0 + 3.0
    received = b""
    while time.perf_counter() < end:
        chunk = ser.read(256)
        if chunk:
            dt_ms = (time.perf_counter() - t0) * 1000
            print(f"  +{dt_ms:6.1f}ms  raw={chunk!r}  ({len(chunk)} bytes)")
            received += chunk
    print(f"\nTotal recebido: {len(received)} bytes")
    print(f"Como string: {received!r}")
    ser.close()


if __name__ == "__main__":
    main()
