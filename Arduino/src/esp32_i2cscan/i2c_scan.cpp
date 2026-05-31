// Scanner I2C — ESP32-C6 — supervisório fase 2 (OLED).
// Varre o barramento I2C nos pinos do supervisor (SDA=GPIO6, SCL=GPIO7)
// e lista os endereços que respondem. Esperado: 0x3C (ou 0x3D) = SSD1306.
// Não é o supervisor — é só descoberta de hardware antes do firmware do display.
#include <Arduino.h>
#include <Wire.h>

static const int PIN_SDA = 6;
static const int PIN_SCL = 7;

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== I2C scan (SDA=GPIO6, SCL=GPIO7) ===");
  Wire.begin(PIN_SDA, PIN_SCL);
}

void loop() {
  int found = 0;
  Serial.println("Varrendo 0x01..0x7E ...");
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    uint8_t err = Wire.endTransmission();
    if (err == 0) {
      Serial.printf("  -> dispositivo em 0x%02X", addr);
      if (addr == 0x3C || addr == 0x3D) Serial.print("  (SSD1306 OLED!)");
      Serial.println();
      found++;
    }
  }
  if (found == 0)
    Serial.println("  nenhum dispositivo. Confira VCC/GND/SDA/SCL e a ordem dos pinos.");
  else
    Serial.printf("Total: %d dispositivo(s).\n", found);
  Serial.println("--- nova varredura em 3s ---\n");
  delay(3000);
}
