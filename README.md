# HaTarim

> **A dev cockpit for macOS developers building Web + AI**
>
> Stop hopping between 6 terminal tabs. See it all in one window.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE.md)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)]()
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange.svg)]()
[![Status: beta](https://img.shields.io/badge/status-beta-yellow.svg)]()

---

## What is this?

**HaTarim** is a single-window system dashboard for macOS developers who run their stack locally —
backends, databases, vector stores, local LLMs, all on the same machine. Instead of opening five terminal
tabs to run `lsof`, `top`, `df`, `ifconfig`, and `curl http://localhost:11434`, you get one cockpit.

Built specifically for the **Web + local AI** workflow that exploded in 2024–2025: Ollama, llama.cpp,
MLX, Weaviate, MySQL, Docker — all running on the same Mac.

### What it answers in one glance

- **Which process owns port 5000?** — `lsof` made readable, with friendly process names (Google→Chrome, ControlCe→Control Center, sharingd→Apple Sharing)
- **Is Ollama answering? Weaviate up? MySQL alive?** — configurable health checks for HTTP, local processes, SSH-reachable hosts, and Ollama-specific endpoints
- **What's outbound from my Mac right now?** — recent connections list with reverse DNS, persistent across short-lived sessions, with a 20-minute history
- **How hot is the M-chip during inference?** — real-time CPU/GPU temp + Pkg/P/E/GPU watts, with sparkline history
- **Why is my external SSD slow?** — full USB topology (controllers → hubs → storage devices) walked from IORegistry, with port numbers and connection types
- **What Wi-Fi am I on, with what signal strength?** — SSID, RSSI, channel, band (2.4/5/6 GHz), TX rate via CoreWLAN

### Optional companion: Arduino + TFT + active cooling

For fanless Mac users running heavy local LLMs (we see you, MacBook Air owners running bge-m3 at 80 °C):

- Arduino Mega 2560 + 240×320 TFT display showing live telemetry on your desk
- Optional **active cooling** — relay or SSR driving an external fan, with PID/hysteresis controller running on macOS
- Validated end-to-end: blast 8-worker bge-m3 inference → temperature crosses 76 °C → relay clicks → fan spins. Mac drops 16 °C in 5 seconds.

The Arduino bridge is **opt-in**. The dashboard works fine without any external hardware.

---

## Screenshots

> Screenshots will be added before public release. Planned shots:
> - 5-tier dashboard at full window
> - Recent Sites card with active connections
> - Storage Tree with USB hubs
> - About window with GPLv3 + credits
> - Arduino TFT showing live telemetry
> - Demo GIF: blast bge-m3 → fan triggers

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  HaTarim.app  (Swift + SwiftUI + AppKit)         │
│                                                      │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │
│  │ Tier 1   │ │ Tier 2   │ │ Tier 3   │ │ Tier    │ │
│  │ System   │ │ Memory & │ │ Outside  │ │ 4-5     │ │
│  │          │ │ Storage  │ │ Connect. │ │         │ │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬────┘ │
│       └───────────┴──────────────┴───────────┘     │
│                       │                              │
│              SystemStats (Combine)                   │
│       ┌───────────┬───┴────┬───────────┐            │
│       ▼           ▼        ▼           ▼            │
│   Collectors   IORegistry  CoreWLAN   lsof          │
└────────────────────┬─────────────────────────────────┘
                     │
                     ▼ optional spool dir
┌──────────────────────────────────────────────────────┐
│  Python daemon  (cross-platform stub)                │
│  - reads spool, writes line-protocol over USB serial │
│  - bidirectional ACK + heartbeat JSON                │
└────────────────────┬─────────────────────────────────┘
                     │
                     ▼ /dev/cu.usbmodemXXXX
┌──────────────────────────────────────────────────────┐
│  Arduino Mega 2560                                   │
│  + MCUFRIEND TFT 240×320 (ILI9341)                  │
│  + Relay or SSR for external fan                     │
└──────────────────────────────────────────────────────┘
```

The Swift app and the Arduino are **decoupled by a file spool** so neither stalls the other if the serial
or hardware is missing.

---

## Requirements

- **macOS 13.0+ (Ventura or later)**
- **Apple Silicon** (M1, M2, M3, M4 — `arm64`). Intel Macs are not supported and likely never will be.
- Xcode Command Line Tools (`xcode-select --install`) for building from source
- *(Optional)* Arduino IDE or PlatformIO for the companion firmware
- *(Optional)* Python 3.11+ with `pyserial` for the spool daemon

### Optional integrations the app expects but doesn't require

- **Ollama** at `http://localhost:11434`
- **Weaviate** in Docker
- **MySQL/PostgreSQL** local
- Any HTTPS service you want to monitor — configurable in the LLM Stack section

---

## Install

### Quick install (recommended — build from source)

```bash
git clone https://github.com/<your-username>/HaTarim.git
cd HaTarim/Swift
./install.sh
```

The installer:
1. Verifies you're on Apple Silicon and have `swift` available
2. Builds the release binary (`swift build -c release`)
3. Packages `HaTarim.app` with `Info.plist`, ad-hoc codesigns it
4. Installs into `~/Applications/HaTarim.app`
5. Creates a `LaunchAgent` so it starts on login

### Drag-to-Applications DMG (planned)

A traditional macOS `.dmg` that opens, shows a window with the app icon and an `Applications` shortcut,
and lets you drag the app across — is on the roadmap for v1.0. See [docs/build-dmg.md](docs/build-dmg.md) (TBD)
for status.

### Logs

- Activity log: `~/Library/Logs/HaTarim/activity.log`
- LaunchAgent stdout/stderr: `/tmp/hatarim.{log,err}`

### Uninstall

```bash
cd HaTarim/Swift
./uninstall.sh
```

---

## Permissions

On first launch the app will request:

- **Location** — required by Apple to read the connected Wi-Fi SSID via CoreWLAN. We never collect or transmit your coordinates; the permission is used only to decode the SSID string. Decline if you don't want SSID/RSSI displayed; everything else still works.

The app does **not** request:
- Full Disk Access
- Accessibility
- Screen Recording
- Microphone / Camera
- Network filter / VPN entitlements

Network connection data is read via the standard `lsof` tool on the user's behalf — no kernel extensions or system extensions involved.

### Gatekeeper note

The app is **ad-hoc signed** (not notarized with an Apple Developer ID). On first launch macOS Gatekeeper may
warn that the app is from an unidentified developer. To allow it, right-click the app and choose **Open**, or
go to **System Settings → Privacy & Security** and click **Open Anyway**.

If you'd rather not deal with Gatekeeper, build from source with `./install.sh` and macOS will trust your
locally-built binary.

---

## Configuration

All settings persist in `UserDefaults` (`~/Library/Preferences/com.pacman.hatarim.plist`):

- **Refresh rate**: configurable from 0.25 s to 60 s (10 presets in the toolbar timer menu)
- **Window opacity** (0–100 %, slider in toolbar)
- **Cards opacity** (0–100 %, independent slider) — see desktop through individual cards
- **Always on top** — toggle in toolbar (uses `NSWindow.level = .floating`)
- **Show local addresses** — checkbox in Connections cards. Off by default to hide LAN/loopback noise.
- **LLM Stack services** — JSON file at `~/Library/Application Support/HaTarim/services.json`. Edit in the bundled `Settings` window.

---

## The 5-tier dashboard

### Tier 1 — System
- **Power & Heat**: CPU/GPU temperature, package/P-cluster/E-cluster/GPU power draw with sparkline history
- **CPU**: per-core utilization (E-cores + P-cores) for all M-series chips
- **Overall Performance**: combined CPU/GPU/MEM busy percentage

### Tier 2 — Memory & Storage
- **Memory**: top processes by RSS (dynamic — number of rows adapts to available height)
- **Volumes**: APFS / exFAT / HFS+ / SMB — collapsible sections by (location, filesystem). Volumes annotated with `(diskN, USB, exFAT)` showing physical device, interconnect, filesystem
- **Storage Tree**: USB topology walked from IORegistry — controllers → hubs → storage devices, with port numbers extracted from `locationID`

### Tier 3 — Outside Connections
- **Network**: all interfaces with friendly names, IPv4, MAC, primary detection. Wi-Fi shows SSID + RSSI (with color coding) + channel + band + TX rate
- **Connections**: live `lsof -iTCP` parsed and grouped — listening ports (services running on this Mac) and outbound connections (where this Mac is calling out). Service names mapped (`5432 → PostgreSQL`, `11434 → Ollama`, `5000/7000 → AirPlay`, etc.)
- **Recent Sites**: 20-minute rolling history of every (process, host, port) tuple seen, with reverse DNS, indicator for active vs closed sessions

### Tier 4 — LLM Stack
- Configurable health checks for any HTTP endpoint, local process, or SSH-reachable host
- Specialized check types for **Ollama** (model list, version)
- 7-day availability heatmap (open with `⌘H`)
- Built-in editor for adding/removing services

### Tier 5 — Specialized Hardware
- Arduino bridge status (connection, ACK rate, last command)
- FAN controller mode (PID / hysteresis / off)
- Send-channel statistics

---

## Companion: Arduino setup

If you want the physical TFT display + active cooling, you'll need:

| Component | Notes |
|---|---|
| Arduino Mega 2560 R3 | Mega specifically — Uno doesn't have enough RAM for the TFT library |
| MCUFRIEND 240×320 TFT shield | ILI9341, plugs directly on top of the Mega |
| 5 V relay module **or** AC SSR (e.g. Fotek SSR-25 DA) | For driving an external fan |
| External 12 V or AC fan | Whatever cooling you actually need |
| Decent USB cable | We've seen cheap-looking blue USB cables outperform "premium" ones for EMI rejection. YMMV. |

The firmware lives in `Arduino/` and builds with PlatformIO. Wiring guide and protocol details are in
`Arduino/README.md` (TBD).

> ⚠️ **Working with mains AC voltage is dangerous.** If you use the SSR/relay path with 110/220 V mains, do
> it inside a properly enclosed project box and please know what you're doing. The author takes no
> responsibility for fried hardware or worse. The hysteresis controller has been validated in production
> but you are responsible for safety on your end.

---

## Roadmap

### Done in v0.5.x
- 5-tier dashboard, fixed 3-cards-per-row, full-width
- Always-on-top + opacity controls
- USB topology, network interfaces, Wi-Fi details
- LLM Stack health checks
- Arduino bridge with PID/hysteresis controller
- About window with GPLv3 + credits

### Targeted for v1.0 (week of 2026-05-08)
- Polished release build, screenshots, demo GIF
- `.dmg` installer (drag-to-Applications)
- Apple Developer ID notarization (likely)
- Full Arduino wiring guide

### Killer features under consideration for v1.x
- **Process port killer inline** — click a listening port → kill -9 the owning process
- **Stack templates** — one-click presets for ".NET dev", "Node + Postgres", "Local LLM stack"
- **Auto-discovery** of running Docker containers and `brew services`
- **LLM Inference Profiler** — correlate Ollama tokens/s with temperature/watts, detect thermal throttling
- **Build correlator** — capture peak CPU/MEM/temp during `dotnet build` / `npm run` / `xcodebuild`, export JSON
- **Working/Idle modes** — collapse to mini-dashboard when idle
- **Prometheus endpoint** — expose metrics at `localhost:<port>/metrics`
- **Global hotkey** to show/hide the cockpit
- **Recent Sites filtered by process** — click "Ollama" → see only its outbound traffic

### Cross-platform plans
- **Linux / GNOME (Ubuntu)** — under consideration. Stack would be Rust + GTK4 + libadwaita. Triggered by community demand (50+ stars + recurring requests). The Arduino daemon already runs on Linux with minor path adjustments.
- **Other Linux DEs** (KDE, XFCE, i3, Hyprland) — should follow GTK4 portability for free
- **Windows** — not planned. The audience this app targets (devs running local AI) overwhelmingly uses macOS or Linux. Windows users running local AI typically work in WSL2, where the Linux build would apply.

---

## Building from source

```bash
git clone https://github.com/<your-username>/HaTarim.git
cd HaTarim/Swift

# Build only
swift build -c release

# Build + package + install + register LaunchAgent
./install.sh

# Run without installing
swift run -c release
```

Targets:
- macOS 13.0+ (declared in `Package.swift`)
- Apple Silicon arm64

The Swift package has a single executable target `HaTarim` with resources processed via `.process("Resources")`.

---

## Project structure

```
HaTarim/
├── Swift/                          # Main macOS app
│   ├── Package.swift               # SPM manifest
│   ├── install.sh                  # Build + install + LaunchAgent
│   ├── uninstall.sh
│   └── Sources/HaTarim/
│       ├── HaTarimApp.swift    # App entry point + AppDelegate
│       ├── DetailWindow.swift      # 5-tier dashboard view
│       ├── AboutWindow.swift       # About scene
│       ├── SystemStats.swift       # ObservableObject — central state
│       ├── *Collector.swift        # CPU/GPU/Mem/Net/Disk/StorageTree/etc
│       ├── HealthChecks/           # LLM Stack health check implementations
│       ├── Controllers/            # FanController etc
│       ├── Persistence/            # JSON storage helpers
│       └── Resources/              # PNG logos, processed at build time
├── Arduino/                        # Mega 2560 + TFT firmware (PlatformIO)
├── Python/                         # Spool daemon for serial bridge
├── Resources/                      # Original (unprocessed) image assets
└── screenshots/                    # README screenshots
```

---

## Contributing

Contributions are welcome, especially:

- New health check types for the LLM Stack section
- Additional service-port mappings (currently we map ~50 well-known + dev ports)
- Process name normalization entries (the lsof process name is awkward for many apps)
- Linux/GTK4 port (very welcome — see roadmap)
- Arduino firmware improvements

What we **won't** merge:
- Generic "make it look like X other app" PRs — the dashboard layout is intentional
- Windows port unless someone commits to maintaining it long-term
- Features that require kernel extensions or system extensions

Please open an issue first for anything non-trivial.

---

## Credits

- **Author**: Pacman / Renegados Hacker Clube
- **Bytecrackers logo**: designed by **Claudio H. Piccolo**, used with permission
- **Renegados Hacker Clube**: long-running retro hardware preservation collective

Built in Swift, SwiftUI, AppKit, IOKit, and an unreasonable amount of MSX nostalgia.

---

## License

GPL v3.0 — see [LICENSE.md](LICENSE.md) for the full text and notes on third-party assets.

`SPDX-License-Identifier: GPL-3.0-or-later`

---

## Status

This is **beta software**, currently at version `0.4.10`. The core dashboard and Arduino bridge are stable
and used daily by the author on a Mac mini and a MacBook Air. Public v1.0 release is planned for
**week of 2026-05-08**.

If you're trying it out, please [open an issue](https://github.com/<your-username>/HaTarim/issues)
with feedback — bugs, feature requests, anything.

> **Note on the project name**: "HaTarim" may be renamed before v1.0 release — the "INO" suffix can
> be confused with Arduino's `.ino` files. Working candidates: **Glance**, **Radar**, **Axis**. Decision
> pending; the GitHub repo URL may be updated accordingly.
