// HaTarim — Supervisório ESP32-C6 — fase 2: VU METER do HD no OLED. 🎚️
//
// Lê o HDD_LED do OpenFrame pelo DUTY CYCLE (GPIO3) e desenha um VU meter no
// OLED SSD1306 128x64 (I2C @ 0x3C, SDA=GPIO6, SCL=GPIO7).
//
// FIAÇÃO DEFINITIVA (achada 2026-05-31): tap no CATODO (-) do HDD_LED, com
// INPUT_PULLUP na ESP. O anodo (+) é só VCC (fica 100% cravado, inútil). No
// catodo o chipset puxa pra LOW a cada acesso => ACTIVE-LOW:
//   - disco parado: pull-up segura HIGH -> dutyHigh ~100% -> atividade 0
//   - disco ativo:  catodo vai a LOW (pisca) -> dutyHigh cai -> atividade sobe
// Logo atividade = 100 - dutyHigh  ->  ACTIVE_HIGH = false.
//
// Cara de VU de áudio: barra de SEGMENTOS que enche conforme o disco trabalha,
// EMA pra suavizar o tremor, e um PEAK-HOLD (tracinho que marca o pico e decai
// devagar). RGB onboard segue como antes: parado=ocioso / ciclando=ativo.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- OLED ----
static const uint8_t SCREEN_W = 128, SCREEN_H = 64;
static const int     PIN_SDA = 6, PIN_SCL = 7;
static const uint8_t OLED_ADDR = 0x3C;
Adafruit_SSD1306 oled(SCREEN_W, SCREEN_H, &Wire, -1);

// ---- leitura do LED ----
static const uint8_t  LED_PIN   = 3;     // tap no CATODO (-) do HDD_LED
static const uint32_t SAMPLE_MS = 6;     // mini-leitura por loop (anima fluido)
static const uint32_t INTEG_MS  = 240;   // janela travada na rede: 60Hz full-wave (120Hz) ->
                                         // 240ms = nº inteiro de ciclos, cancela o ripple de rede
static const bool     ACTIVE_HIGH = false;  // catodo: LED conduzindo = LOW

// Mapa duty->escala (duty já = atividade = 100 - dutyHigh). Calibrado 2026-05-31.
static const float DUTY_IDLE = 0.0f;     // 0% de atividade (catodo em HIGH, pull-up)
static const float DUTY_FULL = 80.0f;    // 100% de atividade (disco bem ocupado)
static const float EMA_ALPHA = 0.40f;    // suavização leve (a janela INTEG manda na balística)
static const float ACT_GATE  = 8.0f;     // squelch: abaixo disso, idle=0 (mata o
                                         // tremor residual com disco parado)

// ---- VU ----
static const int  N_SEG   = 20;          // nº de segmentos da barra
static const float PEAK_DECAY = 0.6f;    // segmentos/quadro que o peak cai

// ---- RGB onboard ----
#ifndef RGB_BUILTIN
#define RGB_BUILTIN 8
#endif
static const float    DUTY_ON = 25.0f;   // atividade acima disso = RGB ciclando
static const uint32_t HOLD_MS = 1500;
static const float    HUE_PER_MS = 0.10f;
static const uint8_t  BRIGHTNESS = 40;

float    actEMA = 0.0f;     // atividade suavizada 0..100
float    peakSeg = 0.0f;    // posição do peak-hold (em segmentos)
bool     active = false;
uint32_t lastActive = 0;
float    hue = 0.0f, lastLoop = 0;
bool     haveOLED = false;

void hueToRGB(uint16_t h, uint8_t &r, uint8_t &g, uint8_t &b) {
  uint8_t region = h / 60, rem = (h % 60) * 255 / 60;
  uint8_t up = (uint16_t)BRIGHTNESS * rem / 255, down = BRIGHTNESS - up;
  switch (region) {
    case 0:  r = BRIGHTNESS; g = up;         b = 0;          break;
    case 1:  r = down;       g = BRIGHTNESS; b = 0;          break;
    case 2:  r = 0;          g = BRIGHTNESS; b = up;         break;
    case 3:  r = 0;          g = down;       b = BRIGHTNESS; break;
    case 4:  r = up;         g = 0;          b = BRIGHTNESS; break;
    default: r = BRIGHTNESS; g = 0;          b = down;       break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(LED_PIN, INPUT_PULLUP);   // catodo: repousa HIGH, acesso puxa LOW
  Wire.begin(PIN_SDA, PIN_SCL);
  haveOLED = oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR);
  Serial.println();
  Serial.println(F("HaTarim ESP32-C6 — VU meter do HD (fase 2, catodo+pullup)"));
  if (!haveOLED) Serial.println(F("!! OLED nao respondeu em 0x3C"));
  if (haveOLED) {
    oled.clearDisplay();
    oled.setTextColor(SSD1306_WHITE);
    oled.setTextSize(1);
    oled.setCursor(20, 28);
    oled.println(F("OpenFrame VU"));
    oled.display();
    delay(800);
  }
  lastLoop = millis();
}

// --- osciloscopio: buffer da forma de onda do duty ---
// Normaliza a area UTIL do sinal: 0% atividade -> 0.0 / DUTY_FULL -> 1.0 (cheio).
static const int   SCOPE_W   = 124;     // largura util (x 2..125)
static const float WAVE_LO   = 0.0f;    // piso da janela (idle)
static const float WAVE_HI   = 80.0f;   // teto da janela (disco bem ocupado)
float wave[SCOPE_W] = {0};

void pushWave(float dutyRaw) {
  float n = (dutyRaw - WAVE_LO) / (WAVE_HI - WAVE_LO);
  if (n < 0) n = 0; if (n > 1) n = 1;
  for (int i = 0; i < SCOPE_W - 1; i++) wave[i] = wave[i + 1];  // shift p/ esquerda
  wave[SCOPE_W - 1] = n;                                        // amostra nova entra na direita
}

// --- olho do KITT (Larson scanner) na faixa amarela ---
// 1-bit nao tem brilho, entao o rastro do cometa eh feito por ALTURA do bloco:
// pico alto no centro, blocos menores nos vizinhos = efeito de cauda esmaecendo.
static const int   SCAN_N   = 13;       // nº de "LEDs"
static const int   SCAN_W   = 96;       // largura util (x 0..95), antes do %
float scanPos = 0;                       // posicao do pico (0..SCAN_N-1)
int   scanDir = 1;                        // sentido da varredura

void drawScanner() {
  scanPos += 0.55f * scanDir;            // velocidade da varredura
  if (scanPos >= SCAN_N - 1) { scanPos = SCAN_N - 1; scanDir = -1; }
  if (scanPos <= 0)          { scanPos = 0;          scanDir =  1; }

  const int ledW = 5, pitch = SCAN_W / SCAN_N, cy = 7;  // centro vertical da faixa
  for (int i = 0; i < SCAN_N; i++) {
    float d = fabsf(i - scanPos);
    int h;
    if      (d < 0.6f) h = 9;            // pico (cauda quente)
    else if (d < 1.6f) h = 6;
    else if (d < 2.6f) h = 3;
    else continue;                       // fora da cauda: apagado
    int x = i * pitch;
    oled.fillRect(x, cy - h / 2, ledW, h, SSD1306_WHITE);
  }
}

void drawVU(float actPct) {
  oled.clearDisplay();

  // faixa amarela: olho do KITT (Larson scanner) varrendo + percentual a direita.
  drawScanner();
  oled.setTextSize(1);
  oled.setCursor(SCREEN_W - 24, 3);   // 4 chars*6px=24px à direita; y=3 centra no scanner (cy=7)
  oled.printf("%03.0f%%", actPct);

  // === metade de cima da faixa azul: barra VU de segmentos ===
  const int barX = 2, barY = 18, barH = 19, barW = SCREEN_W - 4;  // y 18..37
  oled.drawRect(barX, barY, barW, barH, SSD1306_WHITE);

  int litSeg = (int)roundf(actPct / 100.0f * N_SEG);
  if (litSeg > N_SEG) litSeg = N_SEG;
  float segW = (float)(barW - 4) / N_SEG;

  for (int i = 0; i < litSeg; i++) {
    int sx = barX + 2 + (int)(i * segW);
    oled.fillRect(sx, barY + 2, (int)segW - 1, barH - 4, SSD1306_WHITE);
  }

  // peak-hold (tracinho do pico)
  int px = barX + 2 + (int)(peakSeg * segW);
  oled.fillRect(px, barY + 1, 2, barH - 2, SSD1306_WHITE);

  // === metade de baixo: osciloscopio do busy% (alimentado a cada tick) ===
  const int scopeBot = SCREEN_H - 1, scopeH = 22;   // y 41..63
  for (int i = 1; i < SCOPE_W; i++) {
    int y0 = scopeBot - (int)(wave[i - 1] * scopeH);
    int y1 = scopeBot - (int)(wave[i]     * scopeH);
    oled.drawLine(2 + (i - 1), y0, 2 + i, y1, SSD1306_WHITE);
  }

  oled.display();
}

void loop() {
  // 1) AMOSTRAGEM CONTÍNUA por on-time (LED on/off, NÃO portadora):
  //    a cada loop faz uma mini-leitura e acumula; o busy% é a FRAÇÃO de tempo
  //    aceso integrada numa janela longa (INTEG_MS), que é a escala do disco.
  static uint32_t accOn = 0, accTot = 0, lastInteg = 0;
  static float    busy = 0.0f;            // % de tempo aceso na última janela
  const int onLevel = ACTIVE_HIGH ? HIGH : LOW;  // catodo: aceso = LOW
  uint32_t s = millis();
  while (millis() - s < SAMPLE_MS) {
    if (digitalRead(LED_PIN) == onLevel) accOn++;
    accTot++;
  }

  uint32_t now = millis();

  // 2) fecha a janela de integração -> busy% real e contínuo, alimenta EMA+scope
  if (now - lastInteg >= INTEG_MS) {
    lastInteg = now;
    busy = accTot ? (100.0f * accOn / accTot) : 0.0f;
    accOn = accTot = 0;

    float act = (busy - DUTY_IDLE) / (DUTY_FULL - DUTY_IDLE) * 100.0f;
    if (act < 0) act = 0; if (act > 100) act = 100;
    if (act < ACT_GATE) act = 0;          // squelch do idle
    actEMA += EMA_ALPHA * (act - actEMA);
    if (actEMA < 0.5f) actEMA = 0.0f;
    pushWave(busy);                        // scope scrolla 1 amostra/janela

    if (busy >= DUTY_ON) lastActive = now;

    static uint32_t lastPrint = 0;
    if (now - lastPrint >= 500) {
      lastPrint = now;
      Serial.printf("busy=%5.1f%%  act=%5.1f  ema=%5.1f  peak=%4.1f\n",
                    busy, act, actEMA, peakSeg);
    }
  }

  // 3) peak-hold: sobe instantaneo, desce devagar
  float curSeg = actEMA / 100.0f * N_SEG;
  if (curSeg > peakSeg) peakSeg = curSeg;
  else { peakSeg -= PEAK_DECAY; if (peakSeg < curSeg) peakSeg = curSeg; }
  if (peakSeg > N_SEG) peakSeg = N_SEG;

  // 4) RGB onboard (animação fluida: roda todo loop)
  active = (now - lastActive) < HOLD_MS;
  float dt = (float)(now - lastLoop); lastLoop = now;
  if (active) {
    hue += HUE_PER_MS * dt; while (hue >= 360.0f) hue -= 360.0f;
    uint8_t r, g, b; hueToRGB((uint16_t)hue, r, g, b);
    rgbLedWrite(RGB_BUILTIN, r, g, b);
  } else {
    rgbLedWrite(RGB_BUILTIN, 0, 14, 0);
  }

  // 5) desenha (todo loop = KITT fluido)
  if (haveOLED) drawVU(actEMA);

  // 6) log serial: ver tick de integração acima (cadência ~500ms).
}
