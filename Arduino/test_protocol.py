#!/usr/bin/env python3
"""
test_protocol.py — Test harness pro protocolo MonitorIno v2.

Spec: TOKEN:VALOR;XX\n
  - XX = XOR cumulativo de TOKEN:VALOR; em hex 2 chars uppercase
  - ACK = mesma msg com checksum invertido (XX ^ 0xFF)

Modos:
    --quick        Rápido: HOST + INFO + dados básicos, ~5s
    --full         Suite completa: todos os tokens, com asserts
    --simulate    Workload contínuo simulando o que o app Swift mandaria
    --interactive  REPL pra mandar comando arbitrário

Uso:
    python3 test_protocol.py --quick
    python3 test_protocol.py --interactive
    python3 test_protocol.py --simulate --duration 60
"""
from __future__ import annotations
import argparse
import glob
import sys
import time
import random
from dataclasses import dataclass
from typing import Optional, Tuple

try:
    import serial
except ImportError:
    print("ERRO: instale pyserial — pip install pyserial", file=sys.stderr)
    sys.exit(1)


def find_port() -> str:
    candidates = (
        glob.glob("/dev/cu.usbmodem*")
        + glob.glob("/dev/cu.usbserial*")
        + glob.glob("/dev/cu.wchusbserial*")
    )
    if not candidates:
        print("ERRO: nenhuma porta /dev/cu.usbmodem* — Arduino conectado?", file=sys.stderr)
        sys.exit(1)
    return sorted(candidates)[0]


def xor_checksum(payload: bytes) -> int:
    """XOR cumulativo de TODOS os bytes em payload (incluindo o ';' final)."""
    cs = 0
    for b in payload:
        cs ^= b
    return cs & 0xFF


def encode_line(token: str, value: str = "") -> bytes:
    """Monta linha 'TOKEN:VALOR;XX\\n' com checksum."""
    payload = f"{token}:{value};".encode("ascii")
    cs = xor_checksum(payload)
    return payload + f"{cs:02X}".encode("ascii") + b"\n"


def parse_ack(line: bytes) -> Optional[Tuple[str, str, int]]:
    """
    Decodifica ACK: 'TOKEN:VALOR;XX\\n'.
    Retorna (token, value, cs_hex) ou None se mal-formado.
    """
    line = line.rstrip(b"\r\n")
    if len(line) < 5 or line[-3:-2] != b";":
        return None
    try:
        cs = int(line[-2:].decode(), 16)
    except ValueError:
        return None
    payload = line[:-2]  # inclui o ';'
    colon_idx = payload.find(b":")
    if colon_idx < 0:
        return None
    token = payload[:colon_idx].decode("ascii", errors="replace")
    value = payload[colon_idx + 1:-1].decode("ascii", errors="replace")  # tira ';'
    return token, value, cs


@dataclass
class Stats:
    sent: int = 0
    ack_ok: int = 0
    ack_bad_checksum: int = 0
    ack_wrong_token: int = 0
    timeouts: int = 0


class ProtocolClient:
    def __init__(self, port: str, baud: int = 115200, ack_timeout_ms: int = 1500):
        # timeout pequeno por chamada de read() — montamos read_line_robust em cima.
        # readline() do pyserial em macOS USB CDC às vezes dá timeout mesmo com \n
        # já no buffer; lendo em chunks de 64 bytes resolve.
        self.ser = serial.Serial(port, baud, timeout=0.05)
        self.ack_timeout = ack_timeout_ms / 1000.0
        self.stats = Stats()

    def wait_boot(self, seconds: float = 5.0):
        """Aguarda Mega bootar após open (auto-reset on serial open)."""
        print(f"  aguardando boot {seconds}s...")
        time.sleep(seconds)
        self.ser.reset_input_buffer()

    def _read_line_robust(self) -> bytes:
        """Lê até \\n ou timeout total `ack_timeout`. Mais confiável que
        ser.readline() em macOS USB CDC."""
        deadline = time.perf_counter() + self.ack_timeout
        out = b""
        while time.perf_counter() < deadline:
            chunk = self.ser.read(64)
            if chunk:
                out += chunk
                nl = out.find(b'\n')
                if nl >= 0:
                    return out[:nl + 1]
        return out

    def send_with_ack(self, token: str, value: str = "", verbose: bool = True) -> bool:
        """
        Envia comando + espera ACK.
        Retorna True se ack válido recebeu (token+value bate, checksum invertido).
        """
        line = encode_line(token, value)
        sent_payload = line[:-3]  # TOKEN:VALOR; (sem XX\n)
        sent_cs = xor_checksum(sent_payload)
        expected_ack_cs = sent_cs ^ 0xFF

        # Drena qualquer ack atrasado/órfão antes de enviar novo
        self.ser.reset_input_buffer()
        self.ser.write(line)
        self.ser.flush()
        self.stats.sent += 1

        if verbose:
            print(f"  TX: {line.decode().rstrip()}  (cs={sent_cs:02X}, expect ack={expected_ack_cs:02X})")

        # Lê resposta
        ack_line = self._read_line_robust()
        if not ack_line:
            self.stats.timeouts += 1
            if verbose:
                print(f"  ❌ TIMEOUT — sem resposta em {self.ack_timeout*1000:.0f}ms")
            return False

        parsed = parse_ack(ack_line)
        if not parsed:
            self.stats.ack_bad_checksum += 1
            if verbose:
                print(f"  ❌ ACK MAL-FORMADO: {ack_line!r}")
            return False

        ack_token, ack_value, ack_cs = parsed
        if ack_token != token or ack_value != value:
            self.stats.ack_wrong_token += 1
            if verbose:
                print(f"  ❌ ACK token/value diferente: esperado {token}:{value}, "
                      f"veio {ack_token}:{ack_value}")
            return False
        if ack_cs != expected_ack_cs:
            self.stats.ack_bad_checksum += 1
            if verbose:
                print(f"  ❌ ACK checksum errado: esperado {expected_ack_cs:02X}, veio {ack_cs:02X}")
            return False

        self.stats.ack_ok += 1
        if verbose:
            print(f"  ✅ ACK ok: {ack_line.decode().rstrip()}")
        return True

    def close(self):
        self.ser.close()

    def print_stats(self):
        s = self.stats
        total = s.sent
        if total == 0:
            print("Nenhuma msg enviada.")
            return
        rate = s.ack_ok / total * 100
        print(f"\n=== Estatísticas ===")
        print(f"  Enviadas:        {s.sent}")
        print(f"  ACK OK:          {s.ack_ok}  ({rate:.1f}%)")
        print(f"  Timeouts:        {s.timeouts}")
        print(f"  Checksum bad:    {s.ack_bad_checksum}")
        print(f"  Token/val diff:  {s.ack_wrong_token}")


# ─────────────── Suítes ───────────────

def quick_suite(client: ProtocolClient):
    print("\n=== QUICK ===")
    cmds = [
        ("HOST",   "Mac-mini-de-Alexandre"),
        ("INFO",   "User: alexandrepereira"),
        ("TEMP",   "55.06"),
        ("CPU",    "20,15,10,5,80,75,60,45"),
        ("ECORES", "4"),
        ("GPU",    "42"),
        ("MEM",    "76"),
        ("DSK",    "54"),
        ("NET_UP", "0.5"),
        ("NET_DN", "12.3"),
        ("FAN",    "1"),
    ]
    for token, value in cmds:
        client.send_with_ack(token, value)
        time.sleep(0.05)


def full_suite(client: ProtocolClient):
    print("\n=== FULL ===")

    # 1. Setup básico
    quick_suite(client)

    print("\n--- Stress: 50 updates rápidos de TEMP ---")
    for i in range(50):
        t = 30 + random.random() * 50
        client.send_with_ack("TEMP", f"{t:.2f}", verbose=False)
    print(f"  50 envios; OK={client.stats.ack_ok}")

    print("\n--- Toggle FAN 10× ---")
    for i in range(10):
        client.send_with_ack("FAN", "1" if i % 2 == 0 else "0", verbose=False)
        time.sleep(0.1)
    print(f"  10 toggles concluídos")

    print("\n--- INFO rotativo (5 strings diferentes) ---")
    infos = [
        "Apple M1 (8 cores)",
        "macOS 26.3.0",
        "IP: 192.168.15.87",
        "RAM 6.1 / 8 GB",
        "Up 14h 40m"
    ]
    for s in infos:
        client.send_with_ack("INFO", s)
        time.sleep(0.5)

    print("\n--- Comando especial: CLEAR ---")
    client.send_with_ack("CLEAR", "")

    print("\n--- Restaurando estado pra deixar bonito no display ---")
    quick_suite(client)


def simulate(client: ProtocolClient, duration_s: int = 60):
    """Loop realista; pequeno delay entre comandos do mesmo tick pra Arduino processar."""
    print(f"\n=== SIMULATE ({duration_s}s) ===")
    end = time.time() + duration_s
    last_info_at = 0
    info_idx = 0
    infos = [
        "Mac-mini-de-Alexandre",
        "User: alexandrepereira",
        "Apple M1 (8 cores)",
        "macOS 26.3.0",
        "IP: 192.168.15.87",
        "RAM 6.1 / 8 GB",
        "Up 14h 40m",
        "463 processos",
    ]
    # estados iniciais
    client.send_with_ack("HOST", "Mac-mini-de-Alexandre", verbose=False)
    client.send_with_ack("ECORES", "4", verbose=False)
    client.send_with_ack("FAN", "1", verbose=False)

    tick = 0
    while time.time() < end:
        # Telemetria a cada 2s
        temp = 45 + random.random() * 25
        cpu = ",".join(str(random.randint(5, 90)) for _ in range(8))
        gpu = random.randint(0, 100)
        mem = random.randint(60, 90)
        dsk = random.randint(50, 60)

        # 20ms entre comandos pra Arduino processar e mandar ack sem fila acumulada
        for tk, vl in [
            ("TEMP", f"{temp:.2f}"),
            ("CPU", cpu),
            ("GPU", str(gpu)),
            ("MEM", str(mem)),
            ("DSK", str(dsk)),
            ("NET_UP", f"{random.random():.2f}"),
            ("NET_DN", f"{random.random()*15:.2f}"),
        ]:
            client.send_with_ack(tk, vl, verbose=False)
            time.sleep(0.03)

        # INFO rotativa a cada 3s
        now = time.time()
        if now - last_info_at >= 3:
            client.send_with_ack("INFO", infos[info_idx], verbose=False)
            info_idx = (info_idx + 1) % len(infos)
            last_info_at = now

        tick += 1
        if tick % 5 == 0:
            print(f"  tick {tick}: ack_ok={client.stats.ack_ok}/{client.stats.sent} "
                  f"({client.stats.ack_ok/client.stats.sent*100:.1f}%)")

        time.sleep(2.0)


def interactive(client: ProtocolClient):
    print("\n=== INTERACTIVE ===")
    print("Digite TOKEN VALOR (ex: TEMP 55.06)")
    print("Comandos: q (sair), s (stats)")
    while True:
        try:
            line = input("> ").strip()
        except EOFError:
            break
        if not line or line == "q":
            break
        if line == "s":
            client.print_stats()
            continue
        parts = line.split(maxsplit=1)
        token = parts[0]
        value = parts[1] if len(parts) > 1 else ""
        client.send_with_ack(token, value)


# ─────────────── Main ───────────────

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--quick", action="store_true")
    g.add_argument("--full", action="store_true")
    g.add_argument("--simulate", action="store_true")
    g.add_argument("--interactive", action="store_true")
    p.add_argument("--port", help="ex: /dev/cu.usbmodem2201")
    p.add_argument("--duration", type=int, default=30, help="segundos pro modo simulate")
    p.add_argument("--no-boot-wait", action="store_true", help="pula espera do boot")
    args = p.parse_args()

    port = args.port or find_port()
    print(f"=== MonitorINO Protocol Tester v2 ===")
    print(f"Porta: {port}")

    client = ProtocolClient(port)
    try:
        if not args.no_boot_wait:
            client.wait_boot()
        if args.quick:
            quick_suite(client)
        elif args.full:
            full_suite(client)
        elif args.simulate:
            simulate(client, args.duration)
        elif args.interactive:
            interactive(client)
    finally:
        client.print_stats()
        client.close()


if __name__ == "__main__":
    main()
