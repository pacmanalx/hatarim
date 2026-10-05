#!/usr/bin/env python3
"""ollama-tap — proxy minimal entre clients e ollama, loga cada request.
Escuta 0.0.0.0:11434, encaminha pra 127.0.0.1:11435 (ollama real).
Saída colorida com ícones por operação e status.
"""
import json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

UPSTREAM = "http://127.0.0.1:11435"
LISTEN = ("0.0.0.0", 11434)
TIMEOUT = 300

HOP = {"transfer-encoding", "content-encoding", "content-length",
       "connection", "keep-alive", "proxy-authenticate",
       "proxy-authorization", "te", "trailers", "upgrade"}

# ANSI
DIM = "\033[2m"; BOLD = "\033[1m"; RESET = "\033[0m"
GRAY = "\033[90m"; RED = "\033[31m"; GREEN = "\033[32m"
YELLOW = "\033[33m"; BLUE = "\033[34m"; MAGENTA = "\033[35m"
CYAN = "\033[36m"; ITAL = "\033[3m"

OP_ICONS = {
    "/api/embed":    "🔍",
    "/api/generate": "💬",
    "/api/chat":     "💬",
    "/api/tags":     "📋",
    "/api/ps":       "📊",
    "/api/show":     "📖",
    "/api/pull":     "⬇️ ",
    "/api/delete":   "🗑️ ",
}

def op_icon(path: str) -> str:
    return OP_ICONS.get(path, "⚙️ ")

def status_icon(status) -> str:
    if isinstance(status, int):
        if 200 <= status < 300: return f"{GREEN}✓{RESET}"
        if 300 <= status < 400: return f"{CYAN}→{RESET}"
        if 400 <= status < 500: return f"{YELLOW}!{RESET}"
        return f"{RED}✗{RESET}"
    return f"{RED}✗{RESET}"

def fmt_latency(ms: int) -> str:
    if ms < 200:  color = GREEN
    elif ms < 1000: color = YELLOW
    else: color = RED
    if ms < 1000:
        s = f"{ms}ms"
    else:
        s = f"{ms/1000:.2f}s"
    return f"{color}{s:>7}{RESET}"

def fmt_status(status) -> str:
    if isinstance(status, int):
        if 200 <= status < 300: c = GREEN
        elif 200 <= status < 400: c = CYAN
        elif 400 <= status < 500: c = YELLOW
        else: c = RED
        return f"{c}{status}{RESET}"
    return f"{RED}{status}{RESET}"

def extract(body: bytes, path: str):
    if path not in ("/api/embed", "/api/generate", "/api/chat"):
        return None, None
    try:
        j = json.loads(body or b"{}")
    except Exception:
        return None, None
    model = j.get("model")
    inp = j.get("input") or j.get("prompt")
    if inp is None:
        msgs = j.get("messages") or []
        inp = msgs[-1].get("content", "") if msgs else ""
    if isinstance(inp, list):
        inp = inp[0] if inp else ""
    return model, str(inp).replace("\n", " ").replace("\r", " ")

def fmt_request(body: bytes) -> str:
    if not body:
        return ""
    try:
        j = json.loads(body)
        return json.dumps(j, indent=2, ensure_ascii=False)
    except Exception:
        return body.decode("utf-8", errors="replace")

def fmt_response(body: bytes, path: str) -> str:
    if not body:
        return f"{DIM}(empty){RESET}"
    try:
        j = json.loads(body)
    except Exception:
        s = body.decode("utf-8", errors="replace")
        return s if len(s) < 400 else s[:400] + f"{DIM}…({len(s)} chars){RESET}"
    # Embed: não dumpa 1024 floats — sumariza
    if path == "/api/embed":
        embs = j.get("embeddings") or j.get("embedding") or []
        if embs and isinstance(embs[0], list):
            dim = len(embs[0])
            n = len(embs)
            preview = ", ".join(f"{v:+.4f}" for v in embs[0][:3])
            dur_ms = (j.get("total_duration") or 0) // 1_000_000
            return (f"{{ embeddings: {n}×{dim}-dim, "
                    f"sample[0][:3]=[{preview}, …], "
                    f"server_total_duration={dur_ms}ms }}")
    # Generate/chat: response inteira (mas truncada se exagerar)
    txt = json.dumps(j, indent=2, ensure_ascii=False)
    if len(txt) < 1500:
        return txt
    return txt[:1500] + f"\n{DIM}…(truncated, {len(txt)} chars total){RESET}"

class Tap(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a, **k): pass
    def _proxy(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        t0 = time.monotonic()
        model, inp = extract(body, self.path)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "content-length")}
        req = Request(UPSTREAM + self.path, data=body if body else None,
                      headers=headers, method=method)
        err_reason = None
        try:
            with urlopen(req, timeout=TIMEOUT) as r:
                data = r.read(); status = r.status; rh = dict(r.headers)
        except HTTPError as e:
            data = e.read(); status = e.code; rh = dict(e.headers)
        except URLError as e:
            data = b""; status = "ERR"; rh = {}; err_reason = str(e.reason)
        ms = int((time.monotonic() - t0) * 1000)
        self._log(method, status, ms, model, inp, err_reason, body, data)
        if err_reason is not None:
            self.send_error(502, err_reason); return
        self.send_response(status)
        for k, v in rh.items():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
    def _log(self, method, status, ms, model, inp, err, req_body, resp_body):
        ts = time.strftime("%H:%M:%S")
        icon = op_icon(self.path)
        sicon = status_icon(status)
        sstr = fmt_status(status)
        lat = fmt_latency(ms)
        m = f"{BOLD}{CYAN}{method:<4}{RESET}"
        p = f"{BLUE}{self.path:<14}{RESET}"
        # ── cabeçalho (linha resumo) ─────────────────────────────
        header = f"{GRAY}┌─{RESET} {GRAY}{ts}{RESET}  {icon} {sicon}  {m} {p} {sstr:<3}  {lat}"
        if model:
            header += f"  {MAGENTA}{model}{RESET}"
        if inp:
            snippet = inp[:80].replace("\n"," ")
            header += f"  {DIM}▸{RESET} {ITAL}{snippet}{RESET}"
            if len(inp) > 80:
                header += f"{DIM}…({len(inp)} chars){RESET}"
        if err:
            header += f"  {RED}[{err}]{RESET}"
        print(header, flush=True)
        # ── request body (ipsis literis) ────────────────────────
        if req_body and method in ("POST", "PUT", "PATCH"):
            print(f"{GRAY}│{RESET} {DIM}request:{RESET}", flush=True)
            for ln in fmt_request(req_body).splitlines():
                print(f"{GRAY}│{RESET}   {ln}", flush=True)
        # ── response (resumido pra embed, completo pra outros) ──
        if not err:
            print(f"{GRAY}│{RESET} {DIM}response ({len(resp_body)} bytes):{RESET}", flush=True)
            for ln in fmt_response(resp_body, self.path).splitlines():
                print(f"{GRAY}│{RESET}   {ln}", flush=True)
        print(f"{GRAY}└{'─'*60}{RESET}", flush=True)
    do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = lambda self: self._proxy(self.command)
    do_HEAD = do_PATCH = lambda self: self._proxy(self.command)

if __name__ == "__main__":
    banner = f"{BOLD}{GREEN}┌─ ollama-tap ─{RESET} {LISTEN[0]}:{LISTEN[1]} {DIM}→{RESET} {UPSTREAM}"
    print(banner, flush=True)
    print(f"{DIM}│ icons: 🔍 embed  💬 chat/generate  📋 tags  📊 ps  ⚙️  outros{RESET}", flush=True)
    print(f"{DIM}└─ latency: {GREEN}<200ms{RESET}{DIM}  {YELLOW}<1s{RESET}{DIM}  {RED}>1s{RESET}", flush=True)
    ThreadingHTTPServer(LISTEN, Tap).serve_forever()
