#!/usr/bin/env python3
"""fan_on.py — manda FAN:1 pro Mega via protocolo v2. Standalone."""
import sys
import glob
import serial


def main() -> int:
    candidates = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not candidates:
        print("ERRO: nenhuma porta /dev/cu.usbmodem*", file=sys.stderr)
        return 1
    port = candidates[0]

    payload = b"FAN:1;"
    cs = 0
    for b in payload:
        cs ^= b
    line = payload + f"{cs:02X}".encode() + b"\n"

    try:
        ser = serial.Serial(port, 115200, timeout=2.0)
        ser.write(line)
        ser.flush()
        ack = ser.read_until(b"\n", size=64)
        ser.close()
    except serial.SerialException as e:
        print(f"ERRO serial: {e}", file=sys.stderr)
        return 2

    if ack and b"FAN:1;" in ack:
        print(f"OK: {ack.decode(errors='replace').strip()}")
        return 0
    print(f"FAIL: ack={ack!r}", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
