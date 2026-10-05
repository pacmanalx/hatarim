// HaTarim — teste MÍNIMO de sanidade da ESP32-C6.
//
// Objetivo: separar HARDWARE de FIRMWARE. NÃO toca em RGB, NÃO lê GPIO,
// NÃO usa RMT/I2C/nada. Só imprime um contador de uptime a cada 500ms.
//
//   - Se ISTO travar aos ~6s  -> a placa está danificada (HW).
//   - Se rodar liso pra sempre -> o problema é o firmware do supervisor (RMT/GPIO).
//
// Build/flash:  pio run -e esp32_mintest -t upload

#include <Arduino.h>

uint32_t n = 0;

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println(F("=== MIN_TEST C6 — so uptime, sem perifericos ==="));
}

void loop() {
  Serial.printf("alive  n=%lu  uptime=%lu ms\n", (unsigned long)n, (unsigned long)millis());
  n++;
  delay(500);
}
