// HaTarim — Supervisório ESP32-C6 (fase 1.5: duty cycle + feedback no RGB)
//
// Lê o HDD_LED da placa-mãe do OpenFrame pelo DUTY CYCLE (% de tempo aceso).
//
// FIAÇÃO DEFINITIVA (achada 2026-05-31): tap no CATODO (-) do HDD_LED, com
// INPUT_PULLUP na ESP. O anodo (+) é só VCC (100% cravado, inútil). No catodo o
// chipset puxa pra LOW a cada acesso => ACTIVE-LOW:
//   - disco parado: pull-up segura HIGH -> dutyHigh ~100% -> atividade 0
//   - disco ativo:  catodo vai a LOW (pisca) -> dutyHigh cai -> atividade sobe
// Logo atividade = 100 - dutyHigh  ->  ACTIVE_HIGH = false.
//
// FEEDBACK VISUAL no RGB onboard (WS2812 @ GPIO8):
//   - disco OCIOSO  -> RGB parado num verde fixo discreto ("vivo, ocioso")
//   - disco ATIVO   -> RGB cicla o espectro (sweep HSV)
// Histerese no limiar pra não tremer.
//
// Placa: ESP32-C6, GPIO3 = leitura (INPUT_PULLUP). GND comum obrigatório.

#include <Arduino.h>

#ifndef RGB_BUILTIN
#define RGB_BUILTIN 8            // C6-DevKitC-1: WS2812 no GPIO8
#endif

static const uint8_t  LED_PIN   = 3;     // tap no CATODO (-) do HDD_LED
static const uint32_t WINDOW_MS = 20;    // janela de amostragem do duty (curta p/ RGB fluido)
static const uint32_t PRINT_MS  = 500;   // cadência do log serial

// active-low: catodo conduzindo = LOW no GPIO; atividade = 100 - dutyHigh.
static const bool ACTIVE_HIGH = false;

// Limiar de atividade (idle ~0% de atividade; acesso de disco spica bem acima).
static const float    DUTY_ON  = 25.0f;  // atividade acima disso = "tem disco"
static const uint32_t HOLD_MS  = 1500;   // segura "ativo" por 1,5s pós-pico
                                         // (rajadas curtas viram ciclagem visível)

// Sweep do RGB.
static const float   HUE_PER_MS  = 0.10f;  // ~3,6s por volta completa
static const uint8_t BRIGHTNESS  = 40;     // brilho do sweep (0..255)

// Cor "parado" (ocioso): verde discreto.
static const uint8_t IDLE_R = 0, IDLE_G = 14, IDLE_B = 0;

// HSV->RGB com S=V=máx; h em 0..359. Saída escalada por BRIGHTNESS.
void hueToRGB(uint16_t h, uint8_t &r, uint8_t &g, uint8_t &b) {
  uint8_t region = h / 60;
  uint8_t rem    = (h % 60) * 255 / 60;
  uint8_t up     = (uint16_t)BRIGHTNESS * rem / 255;
  uint8_t down   = BRIGHTNESS - up;
  switch (region) {
    case 0:  r = BRIGHTNESS; g = up;         b = 0;          break;
    case 1:  r = down;       g = BRIGHTNESS; b = 0;          break;
    case 2:  r = 0;          g = BRIGHTNESS; b = up;         break;
    case 3:  r = 0;          g = down;       b = BRIGHTNESS; break;
    case 4:  r = up;         g = 0;          b = BRIGHTNESS; break;
    default: r = BRIGHTNESS; g = 0;          b = down;       break;
  }
}

bool     active     = false;   // estado de atividade (com hold)
uint32_t lastActive = 0;       // millis() do último pico acima do limiar
float    hue        = 0.0f;    // posição do sweep (só avança quando ativo)
uint32_t lastLoop = 0;
uint32_t lastPrint = 0;
float    dutyMin = 100.0f, dutyMax = 0.0f;

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(LED_PIN, INPUT_PULLUP);   // catodo: repousa HIGH, acesso puxa LOW
  Serial.println();
  Serial.println(F("HaTarim ESP32-C6 LED-supervisor v0.7 — catodo+pullup, active-low"));
  Serial.println(F("RGB: parado=ocioso / ciclando=disco ativo"));
  lastLoop = millis();
  lastPrint = lastLoop;
}

void loop() {
  // 1) mede duty cycle por amostragem rápida durante WINDOW_MS
  uint32_t highs = 0, total = 0;
  uint32_t start = millis();
  while (millis() - start < WINDOW_MS) {
    if (digitalRead(LED_PIN)) highs++;
    total++;
  }
  float dutyHigh = total ? (100.0f * highs / total) : 0.0f;
  float duty = ACTIVE_HIGH ? dutyHigh : (100.0f - dutyHigh);

  // 2) atualiza estado de atividade com hold retrigger
  uint32_t now = millis();
  if (duty >= DUTY_ON) lastActive = now;          // pico: rearma o hold
  active = (now - lastActive) < HOLD_MS;           // ativo enquanto dentro do hold

  // 3) pilota o RGB
  float dt = (float)(now - lastLoop);
  lastLoop = now;

  if (active) {
    hue += HUE_PER_MS * dt;          // só avança quando há atividade
    while (hue >= 360.0f) hue -= 360.0f;
    uint8_t r, g, b;
    hueToRGB((uint16_t)hue, r, g, b);
    rgbLedWrite(RGB_BUILTIN, r, g, b);
  } else {
    rgbLedWrite(RGB_BUILTIN, IDLE_R, IDLE_G, IDLE_B);  // parado
  }

  // 4) log serial esporádico
  if (duty < dutyMin) dutyMin = duty;
  if (duty > dutyMax) dutyMax = duty;
  if (now - lastPrint >= PRINT_MS) {
    lastPrint = now;
    Serial.printf("DUTY=%5.1f%%  %s   min=%5.1f max=%5.1f\n",
                  duty, active ? "ATIVO (ciclando)" : "ocioso (parado)",
                  dutyMin, dutyMax);
  }
}
