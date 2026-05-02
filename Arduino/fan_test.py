#!/usr/bin/env python3
"""
fan_test.py — Teste interativo do relé FAN via protocolo v2.

Aperta L pra ligar, D pra desligar, Q pra sair. Mede e mostra o tempo
de cada comando (envio → ack) pra comparar com o app Swift.

Uso:
    python3 fan_test.py
    python3 fan_test.py --port /dev/cu.usbmodem2201

IMPORTANTE: feche o MonitorINO2.app antes (ele segura a serial).
"""
from __future__ import annotations
import argparse
import sys
import termios
import time
import tty

# Reusa toda a lógica do test_protocol.py
from test_protocol import ProtocolClient, find_port


def read_one_key() -> str:
    """Lê 1 tecla do stdin sem precisar de Enter (modo raw temporário)."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return ch


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="ex: /dev/cu.usbmodem2201")
    p.add_argument("--no-boot-wait", action="store_true")
    args = p.parse_args()

    port = args.port or find_port()
    print(f"=== Fan Test ===")
    print(f"Porta: {port}")
    print(f"Comandos: [L]igar  [D]esligar  [Q]uit")

    client = ProtocolClient(port)
    try:
        if not args.no_boot_wait:
            client.wait_boot()

        print("\nPronto. Aperta tecla:")
        while True:
            ch = read_one_key().lower()
            if ch == "q" or ch == "\x03":  # q ou Ctrl-C
                break
            if ch == "l":
                t0 = time.perf_counter()
                ok = client.send_with_ack("FAN", "1", verbose=False)
                dt_ms = (time.perf_counter() - t0) * 1000
                mark = "✅" if ok else "❌"
                print(f"  L → FAN:1   {mark}  {dt_ms:6.1f} ms")
            elif ch == "d":
                t0 = time.perf_counter()
                ok = client.send_with_ack("FAN", "0", verbose=False)
                dt_ms = (time.perf_counter() - t0) * 1000
                mark = "✅" if ok else "❌"
                print(f"  D → FAN:0   {mark}  {dt_ms:6.1f} ms")
            else:
                # tecla desconhecida — silencioso pra não poluir
                pass
    finally:
        print()
        client.print_stats()
        client.close()


if __name__ == "__main__":
    main()
