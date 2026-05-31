// HaTarim — Supervisório ESP32-C6 — SONDA do HDD_LED (diagnóstico). 🔬
//
// A main board NOVA do OpenFrame foi trocada e a premissa antiga ("a mobo dirige
// o LED com portadora/PWM, a info está no duty ~75%") aparentemente morreu junto
// com a placa velha. Esta sonda NÃO converte nada — só mostra o sinal cru pra a
// gente descobrir COMO a placa nova aciona o LED:
//
//   - LED em DC liso (liga/desliga normal): duty ~0% parado, sobe com atividade,
//     e o nº de BORDAS por janela é baixo (blink lento, alguns Hz).
//   - LED com portadora/PWM (como a antiga): duty alto e ESTÁVEL mesmo parado,
//     com MUITAS bordas por janela (kHz).
//
// Pino: GPIO3 (mesmo tap da fase 2/OLED). Troque LED_PIN se religar no GPIO2.
// INPUT puro; R2 externo define o LOW. GND comum com o OpenFrame obrigatório.

#include <Arduino.h>

static const uint8_t  LED_PIN  = 3;     // tap do HDD_LED via divisor
static const uint32_t WINDOW_MS = 200;  // janela de observação (longa p/ ver blink lento)

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(LED_PIN, INPUT);
  Serial.println();
  Serial.println(F("HaTarim ESP32-C6 — SONDA do HDD_LED (cru, sem conversao)"));
  Serial.printf("pino=GPIO%u  janela=%lums\n", LED_PIN, (unsigned long)WINDOW_MS);
  Serial.println(F("Rode PARADO e depois com 'dd if=/dev/zero of=... ' e compare."));
  Serial.println(F("dutyHigh = %% do tempo em HIGH | edges = transicoes/janela"));
}

void loop() {
  uint32_t highs = 0, total = 0, edges = 0;
  int prev = digitalRead(LED_PIN);
  uint32_t start = millis();
  while (millis() - start < WINDOW_MS) {
    int cur = digitalRead(LED_PIN);
    if (cur) highs++;
    if (cur != prev) edges++;   // conta bordas (sobe+desce) -> mede frequência
    prev = cur;
    total++;
  }
  float dutyHigh = total ? (100.0f * highs / total) : 0.0f;
  // edges/2 ≈ ciclos na janela; *1000/WINDOW_MS ≈ Hz aproximado
  float approxHz = (edges / 2.0f) * 1000.0f / WINDOW_MS;

  Serial.printf("dutyHigh=%6.2f%%  edges=%5lu  ~%7.1f Hz  amostras=%lu\n",
                dutyHigh, (unsigned long)edges, approxHz, (unsigned long)total);
}
