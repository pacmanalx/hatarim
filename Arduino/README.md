# Arduino — firmware HaTarim

Firmware do display físico, **idêntico ao v1**: parser do protocolo serial + render no TFT 240x320 + LCD RGB 16x2. Foi copiado de `/Volumes/512Gb(SSD)/dev/PlatformIO/HaTarim/`.

## Hardware

- **Arduino Mega 2560** (`megaatmega2560`)
- **MCUFRIEND TFT 240x320** (driver autodetectado, normalmente ILI9341 / `0x9341`)
- **Grove RGB LCD 16x2** (I2C, endereço default)

Pinout fixo dentro de `src/main.cpp` (MCUFRIEND_kbv usa pinos pré-definidos do shield; LCD I2C nos pinos SDA/SCL do Mega).

## Bibliotecas (em `platformio.ini`)

- `seeed-studio/Grove - LCD RGB Backlight`
- `prenticedavid/MCUFRIEND_kbv`
- `adafruit/Adafruit GFX Library`

## Protocolo

Recebido via Serial0 @ **115200 baud**, linhas terminadas em `\n`:

```
T:{temp}|C:{c0,c1,...}|E:{nEcores}|G:{gpu%}|M:{mem%}|D:{disk%}|U:{up_MB/s}|N:{dn_MB/s}|S:txt;cor;...
```

E-cores **vêm primeiro** em `C:`. Cores `S:` são RGB565 hex de 4 chars (ex.: `07E0`=verde). Buffer firmware = 256 bytes.

Quem manda os dados agora é o **app Swift** (`../Swift/HaTarim.app`), não mais o `monitor.py` do v1.

## Build via CLI (sem VS Code)

PlatformIO Core está em `~/.platformio/penv/bin/pio`. Atalho recomendado:

```bash
alias pio=~/.platformio/penv/bin/pio
```

Comandos:

```bash
pio run                      # compila
pio run -t upload            # upload pro Mega plugado
pio run -t clean             # limpa build artifacts
pio device list              # lista portas seriais
pio device monitor -b 115200 # serial monitor (Ctrl+T Ctrl+X pra sair)
pio check                    # static analysis
```

Iteração típica (alterar `src/main.cpp` → ver no display):

```bash
pio run -t upload && pio device monitor -b 115200
```
