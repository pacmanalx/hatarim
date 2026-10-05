# HaTarim Linux — host coletor pros Linux da frota

Daemon Python stdlib que monitora serviços locais e grava um snapshot JSON que
o HaMachaneh consome via SSH. Preenche o papel que o `Python/README.md` original
listava: *"Host coletor rodando em paralelo (reaproveitando `monitor.py` do
HaTarim v1) e enviando dados pro Swift via socket Unix ou JSON em arquivo"*.

Diferença consciente vs. o Swift (macOS):

| | Swift (macOS) | Python (Linux) |
|---|---|---|
| Foco | Dev cockpit com GUI | Daemon headless, só snapshot |
| Serviços | 3 níveis (L1/L2/L3) — pra testar LLMs | 1 nível por check — serviços comuns (daemon, port, http) |
| Consumidor | GUI própria | HaMachaneh via `cat snapshot.json` |

## Instalação

```bash
# Em qualquer Linux da frota (como user alexandre):
mkdir -p ~/.config/hatarim ~/.local/share/hatarim
cp services.example.json ~/.config/hatarim/services.json
# Ajusta services.json pra máquina em questão
nano ~/.config/hatarim/services.json

# Systemd user service (sobe no login + reinicia se cair):
mkdir -p ~/.config/systemd/user
cp systemd/hatarim.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now hatarim
systemctl --user status hatarim
```

Para rodar como service sem login gráfico, habilitar lingering uma vez:
`sudo loginctl enable-linger alexandre`.

## Formato do `services.json`

```json
{
  "intervalSec": 5,
  "services": [
    {
      "id": "ragd",
      "name": "RAGnaRock",
      "checks": [
        { "type": "systemd", "unit": "ragd" },
        { "type": "http", "url": "http://localhost:11499/health" }
      ],
      "intervalSec": 30
    }
  ]
}
```

Tipos de check:

| type | campos | passa quando |
|---|---|---|
| `systemd` | `unit` | `systemctl is-active <unit>` retorna `active` |
| `port` | `port`, `host?` (default localhost) | TCP connect bem-sucedido |
| `http` | `url`, `expectedStatus?` (default 200), `expectedSubstring?` | request OK e substring presente |
| `command` | `cmd`, `expectedSubstring?` | exit code 0 e substring presente |

Um serviço é `noAr` se **todos** os checks passam, `fora` se qualquer falha.

## Saídas

- **`~/.local/share/hatarim/snapshot.json`** — reescrito a cada tick (5s). Shape:
  ```json
  {
    "ts": "2026-10-05T07:20:00Z",
    "host": "aron",
    "cpu": { "load1": 2.5, "loadPct": 8.9, "threads": 28 },
    "mem": { "totalBytes": ..., "usedBytes": ..., "usedPct": 61.0 },
    "disk": { "root": { "usedPct": 32.1 } },
    "services": [
      { "id": "ragd", "name": "RAGnaRock", "state": "noAr", "lastCheck": "...", "checks": [...] }
    ]
  }
  ```

- **`~/.local/share/hatarim/history.jsonl`** — append-only, uma linha por **mudança de estado** de serviço.

Zero dependências fora da stdlib — roda em qualquer Linux com Python 3.9+.
