// HaTarim — Supervisório ESP32-C6 — SONDA COM DISPLAY (caça-pino). 🔎🖥️
//
// Feedback NA TELA pra achar o pino certo do HDD_LED sem ler serial no escuro.
// Passe o tap (GPIO3) pino a pino no header e olhe o OLED reagir:
//   - LVL: nível instantâneo do pino (0/1)
//   - DUTY: % de tempo em HIGH na janela
//   - bordas + Hz: transições por janela (presença de carrier/pisca)
//   - indicador grande: "ATIVO" quando há bordas (sinal vivo) / "quieto" parado
//   - barra: taxa de bordas em escala log (curtinha=ruído, cheia=carrier)
//
// O sinal REAL do disco: bordas SOBEM quando o disco trabalha e VOLTAM A 0 quando
// para. Ruído/antena (pino solto) costuma dar bordas altas CONSTANTES sem relação
// com o disco, ou flat 0/100 sem bordas. Use isso pra separar sinal de miragem.
//
// OLED SSD1306 128x64 I2C 0x3C, SDA=GPIO6, SCL=GPIO7 (mesma fiação do VU).
// Tap em GPIO3, INPUT puro. GND comum obrigatório.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

static const uint8_t SCREEN_W = 128, SCREEN_H = 64;
static const int     PIN_SDA = 6, PIN_SCL = 7;
static const uint8_t OLED_ADDR = 0x3C;
Adafruit_SSD1306 oled(SCREEN_W, SCREEN_H, &Wire, -1);

static const uint8_t  LED_PIN   = 3;     // tap do HDD_LED (mova entre os pinos)
static const uint32_t WINDOW_MS = 150;   // janela curta = tela responsiva
// CATODO (-): o chipset puxa pra LOW no acesso; pull-up segura HIGH no repouso.
// Idle -> LVL=1/DUTY~100%; disco ativo -> LVL cai a 0 com bordas.
#define USE_PULLUP 1

bool haveOLED = false;

void setup() {
  Serial.begin(115200);
  delay(200);
#if USE_PULLUP
  pinMode(LED_PIN, INPUT_PULLUP);   // catodo: repousa HIGH, acesso puxa LOW
#else
  pinMode(LED_PIN, INPUT);          // anodo/divisor externo: sem pull interno
#endif
  Wire.begin(PIN_SDA, PIN_SCL);
  haveOLED = oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR);
  Serial.println();
  Serial.println(F("HaTarim ESP32-C6 — SONDA COM DISPLAY (caca-pino GPIO3)"));
  if (!haveOLED) Serial.println(F("!! OLED nao respondeu em 0x3C"));
  if (haveOLED) {
    oled.clearDisplay();
    oled.setTextColor(SSD1306_WHITE);
    oled.setTextSize(1);
    oled.setCursor(8, 28);
    oled.println(F("CACA-PINO GPIO3"));
    oled.display();
    delay(700);
  }
}

void loop() {
  uint32_t highs = 0, total = 0, edges = 0;
  int prev = digitalRead(LED_PIN);
  uint32_t start = millis();
  while (millis() - start < WINDOW_MS) {
    int cur = digitalRead(LED_PIN);
    if (cur) highs++;
    if (cur != prev) edges++;
    prev = cur;
    total++;
  }
  float dutyHigh = total ? (100.0f * highs / total) : 0.0f;
  float hz = (edges / 2.0f) * 1000.0f / WINDOW_MS;
  int   lvl = digitalRead(LED_PIN);
  bool  ativo = edges > 4;   // qualquer transição real = sinal vivo

  Serial.printf("LVL=%d  DUTY=%6.2f%%  edges=%5lu  ~%8.1f Hz\n",
                lvl, dutyHigh, (unsigned long)edges, hz);

  if (!haveOLED) return;
  oled.clearDisplay();

  // topo: pino + nível instantâneo
  oled.setTextSize(1);
  oled.setCursor(0, 0);
  oled.printf("TAP GPIO3   LVL:%d", lvl);

  // DUTY grande
  oled.setTextSize(2);
  oled.setCursor(0, 12);
  oled.printf("%5.1f%%", dutyHigh);

  // indicador ATIVO/quieto grande a direita
  oled.setTextSize(2);
  oled.setCursor(78, 12);
  oled.print(ativo ? F(">>>") : F("---"));

  // bordas + Hz
  oled.setTextSize(1);
  oled.setCursor(0, 34);
  oled.printf("bordas:%lu", (unsigned long)edges);
  oled.setCursor(0, 44);
  oled.printf("freq:%.0f Hz", hz);

  // barra de taxa de bordas (escala log: 1..~20k -> 0..124px)
  int bw = 0;
  if (edges > 0) {
    float l = log10f((float)edges + 1.0f) / log10f(20000.0f);
    if (l > 1) l = 1;
    bw = (int)(l * 124);
  }
  oled.drawRect(0, 56, 128, 8, SSD1306_WHITE);
  if (bw > 0) oled.fillRect(2, 58, bw, 4, SSD1306_WHITE);

  oled.display();
}
