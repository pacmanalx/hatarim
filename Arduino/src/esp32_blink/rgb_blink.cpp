// HaTarim — ESP32-C6: RGB LED onboard (WS2812 no GPIO8) varrendo o espectro
// suavemente em loop, estilo "RGB gamer" de PC. Smoke test + efeito.

#include <Arduino.h>

#ifndef RGB_BUILTIN
#define RGB_BUILTIN 8   // C6-DevKitC-1: WS2812 no GPIO8
#endif

static const uint8_t  BRIGHTNESS = 40;   // 0..255 — suave, sem ofuscar
static const uint16_t STEP_MS    = 20;   // tempo por passo (menor = mais rápido)

// HSV->RGB com S=V=máx; h em 0..359. Saída já escalada por BRIGHTNESS.
void hueToRGB(uint16_t h, uint8_t &r, uint8_t &g, uint8_t &b) {
  uint8_t region = h / 60;
  uint8_t rem    = (h % 60) * 255 / 60;     // 0..255 dentro da região
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

uint16_t hue = 0;

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println(F("HaTarim ESP32-C6 — RGB spectrum sweep (gamer mode)"));
}

void loop() {
  uint8_t r, g, b;
  hueToRGB(hue, r, g, b);
  rgbLedWrite(RGB_BUILTIN, r, g, b);
  hue = (hue + 1) % 360;
  delay(STEP_MS);
}
