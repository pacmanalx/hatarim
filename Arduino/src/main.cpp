// MonitorINO_V2 firmware — Protocolo v2 (linha-única + checksum XOR + ACK)
// Display: MCUFRIEND TFT 240x320 ILI9341 sobre Arduino Mega 2560.
//
// Spec do protocolo: project_arduino_protocolo.md (RAG)
//   Formato: TOKEN:VALOR;XX\n
//   Checksum XOR de TOKEN:VALOR; em hex 2 chars.
//   ACK: echo da msg com checksum invertido (~XX) ANTES de executar.
//
// Tokens: TEMP, CPU, ECORES, GPU, MEM, DSK, NET_UP, NET_DN, FAN, HOST, INFO,
//         CLEAR, CLRVAR, RESET.

#include <Arduino.h>
#include <MCUFRIEND_kbv.h>
#include <Adafruit_GFX.h>

MCUFRIEND_kbv tft;

// ─────────────── Cores RGB565 ───────────────
#define C_BG        0x0000
#define C_DARK      0x18E3
#define C_DARKER    0x0861
#define C_DIVIDER   0x4208
#define C_WHITE     0xFFFF
#define C_GRAY      0xBDF7
#define C_DIMGRAY   0x6B6D
#define C_GREEN     0x07E0
#define C_CYAN      0x07FF
#define C_YELLOW    0xFFE0
#define C_ORANGE    0xFD20
#define C_RED       0xF800
#define C_MAGENTA   0xF81F
#define C_BLUE      0x34DF

// ─────────────── Layout ───────────────
#define TFT_W   240
#define TFT_H   320
#define HEADER_H        44
#define HEADER_LINE1_Y   6
#define HEADER_LINE2_Y  24

#define MINI_TOP_Y      48
#define MINI_BOT_Y      80
#define MINI_H          30
#define MINI_LEFT_X     0
#define MINI_RIGHT_X    122
#define MINI_W          118

#define SPARK_X         4
#define SPARK_W         (TFT_W - 8)
#define SPARK_H         38
#define SPARK_TEMP_Y    114
#define SPARK_GPU_Y     (SPARK_TEMP_Y + SPARK_H + 2)
#define SPARK_CPU_Y     (SPARK_GPU_Y  + SPARK_H + 2)
#define SPARK_LBL_W     46
#define HISTORY_LEN     60

#define CORES_Y0        236
#define CORES_BAR_TOP   240
#define CORES_BAR_BASE  288
#define CORES_BAR_H     (CORES_BAR_BASE - CORES_BAR_TOP)
#define CORES_LBL_Y     292

#define FOOTER_Y        300
#define FOOTER_H        20

#define MAX_CORES   32       // futuro-proof pra M3 Ultra
#define INFO_LEN   100       // buffer único de string (HOST + INFO usam mesmo limite)

// ─────────────── FAN relay ───────────────
#define RELAY_PIN          22
#define RELAY_ACTIVE_LOW   true
// Failsafe FAN removido em 2026-04-28 — gerava falsos positivos sem benefício
// real (Mac tem fan interna; auxiliar ficar OFF se app morre não é catástrofe).

// ─────────────── Protocolo serial v2 ───────────────
#define LINE_BUF_LEN 128         // recebe UMA linha completa (TOKEN:VALOR;XX\n)
char    lineBuf[LINE_BUF_LEN];
uint8_t lineBufPos = 0;

// ─────────────── Render timer ───────────────
#define RENDER_MS 2000UL
unsigned long lastRenderAt = 0;
bool stateDirty = true;          // qualquer mudança marca pra próximo render

// ─────────────── Estado de telemetria ───────────────
float    cpuTemp = 0;
uint8_t  cpuCores[MAX_CORES] = {0};
uint8_t  numCores = 0;
uint8_t  numEcores = 0;
uint8_t  gpuPercent = 0;
uint8_t  memPercent = 0;
uint8_t  diskPercent = 0;
float    netUp = 0;
float    netDown = 0;

bool          fanState = false;
unsigned long pktCount = 0;        // bom comando recebido (RX no footer)

// Histórico
float    tempHist[HISTORY_LEN];
uint8_t  cpuHist[HISTORY_LEN];
uint8_t  gpuHist[HISTORY_LEN];
uint8_t  histIdx = 0;
uint8_t  histCount = 0;

// Strings
char hostBuf[INFO_LEN] = {0};      // linha 1 do header (pinned)
char infoBuf[INFO_LEN] = {0};      // linha 2 do header (rotativa via sender)

// "Prev" pra dirty diff
float    prevCpuTemp = -999;
uint8_t  prevCpuCores[MAX_CORES];
uint8_t  prevNumCores = 0;
uint8_t  prevNumEcores = 255;
uint8_t  prevGpuPercent = 255;
uint8_t  prevMemPercent = 255;
uint8_t  prevDiskPercent = 255;
float    prevNetUp = -1;
float    prevNetDown = -1;
char     prevHostBuf[INFO_LEN] = {0};
char     prevInfoBuf[INFO_LEN] = {0};
bool     firstFrame = true;

// Forward declarations — yieldSerial chama processLine, que é definido
// depois do renderDirty (que precisa chamar yieldSerial entre primitivas).
void processLine();
void yieldSerial();

// ─────────────── Helpers de cor ───────────────
uint16_t tempZoneColor(float t) {
    if (t < 50) return C_GREEN;
    if (t < 75) return C_ORANGE;
    return C_RED;
}
uint16_t coreLoadColor(int pct, bool isE) {
    if (pct >= 80) return C_RED;
    if (pct >= 50) return C_YELLOW;
    return isE ? C_CYAN : C_GREEN;
}
uint16_t miniBarColor(int pct, uint16_t base) {
    if (pct >= 90) return C_RED;
    if (pct >= 75) return C_ORANGE;
    return base;
}
int cpuAverage() {
    if (numCores == 0) return 0;
    long sum = 0;
    for (uint8_t i = 0; i < numCores; i++) sum += cpuCores[i];
    return (int)(sum / numCores);
}

// ─────────────── FAN helpers ───────────────
void writeFan(bool on) {
    fanState = on;
    int level = on ? (RELAY_ACTIVE_LOW ? LOW : HIGH)
                   : (RELAY_ACTIVE_LOW ? HIGH : LOW);
    digitalWrite(RELAY_PIN, level);
}

// ─────────────── Splash ───────────────
void drawCpuIconLarge(int cx, int cy, uint16_t color) {
    int s = 4;
    int x0 = cx - 7 * s;
    int y0 = cy - 7 * s;
    tft.drawRoundRect(x0 + 2*s, y0 + 2*s, 10*s, 10*s, 6, color);
    tft.drawRoundRect(x0 + 2*s + 1, y0 + 2*s + 1, 10*s - 2, 10*s - 2, 5, color);
    tft.fillRoundRect(x0 + 4*s, y0 + 4*s, 6*s, 6*s, 3, color);
    for (int i = 0; i < 3; i++) {
        int p = i * 3 * s;
        tft.fillRect(x0 + 3*s + p, y0,           2*s, 2*s, color);
        tft.fillRect(x0 + 3*s + p, y0 + 12*s,    2*s, 2*s, color);
        tft.fillRect(x0,           y0 + 3*s + p, 2*s, 2*s, color);
        tft.fillRect(x0 + 12*s,    y0 + 3*s + p, 2*s, 2*s, color);
    }
}

void drawSplash() {
    tft.fillScreen(C_BG);
    drawCpuIconLarge(TFT_W / 2, 110, C_CYAN);
    const char *name = "MonitorINO";
    int nameLen = (int)strlen(name);
    int nameW = nameLen * 18;
    int nameX = (TFT_W - nameW) / 2;
    tft.setTextSize(3);
    tft.setTextColor(C_WHITE, C_BG);
    tft.setCursor(nameX, 175);
    tft.print(name);
    tft.setTextSize(2);
    tft.setTextColor(C_CYAN, C_BG);
    int v2W = 2 * 12;
    tft.setCursor(nameX + nameW - v2W, 205);
    tft.print("v2");
    const char *waiting = "aguardando dados...";
    int waitW = (int)strlen(waiting) * 6;
    tft.setTextSize(1);
    tft.setTextColor(C_DIMGRAY, C_BG);
    tft.setCursor((TFT_W - waitW) / 2, 245);
    tft.print(waiting);
}

// ─────────────── FAN status badge ───────────────
void drawFanBadge() {
    const int x = 186, y = 2, w = 52, h = 14;
    uint16_t bg, fg;
    const char *txt;
    if (fanState) { bg = C_GREEN;   fg = C_BG;    txt = "FAN ON";  }
    else          { bg = C_DIMGRAY; fg = C_BG;    txt = "FAN OFF"; }
    tft.fillRoundRect(x, y, w, h, 3, bg);
    tft.drawRoundRect(x, y, w, h, 3, C_WHITE);
    tft.setTextSize(1);
    tft.setTextColor(fg, bg);
    int textW = (int)strlen(txt) * 6;
    tft.setCursor(x + (w - textW) / 2, y + 4);
    tft.print(txt);
}

// ─────────────── Header (linha 1: HOST, linha 2: INFO) ───────────────
void drawHeader() {
    tft.fillRect(0, 0, TFT_W, HEADER_H, C_BG);
    tft.drawFastHLine(0, HEADER_H, TFT_W, C_DIVIDER);

    // Linha 1: HOST pinned ciano
    if (hostBuf[0] != '\0') {
        int len = strlen(hostBuf);
        int charW = 12, sz = 2;
        if (len * charW > TFT_W - 6) { sz = 1; charW = 6; }
        int px = (TFT_W - len * charW) / 2;
        if (px < 2) px = 2;
        tft.setTextSize(sz);
        tft.setTextColor(C_CYAN, C_BG);
        tft.setCursor(px, HEADER_LINE1_Y);
        tft.print(hostBuf);
    }

    // Linha 2: INFO branco
    if (infoBuf[0] != '\0') {
        int len = strlen(infoBuf);
        int charW = 12, sz = 2;
        if (len * charW > TFT_W - 6) { sz = 1; charW = 6; }
        int px = (TFT_W - len * charW) / 2;
        if (px < 2) px = 2;
        tft.setTextSize(sz);
        tft.setTextColor(C_WHITE, C_BG);
        tft.setCursor(px, HEADER_LINE2_Y);
        tft.print(infoBuf);
    }
}

// ─────────────── Mini-cards ───────────────
void drawMiniCard(int x, int y, int w, int h,
                  const char *label, uint16_t labelColor,
                  const char *valueText, int barPct, uint16_t barColor,
                  bool full) {
    const int radius = 4;
    if (full) {
        tft.fillRoundRect(x, y, w, h, radius, C_DARKER);
        tft.drawRoundRect(x, y, w, h, radius, C_DIVIDER);
    } else {
        tft.fillRoundRect(x + 1, y + 1, w - 2, h - 2, radius - 1, C_DARKER);
    }
    tft.setTextSize(1);
    tft.setTextColor(labelColor, C_DARKER);
    tft.setCursor(x + 5, y + 4);
    tft.print(label);
    tft.setTextSize(2);
    tft.setTextColor(C_WHITE, C_DARKER);
    int strW = strlen(valueText) * 12;
    tft.setCursor(x + w - strW - 5, y + 4);
    tft.print(valueText);
    int barX = x + 4, barY = y + h - 7, barW = w - 8, barH = 4;
    int safe = barPct < 0 ? 0 : (barPct > 100 ? 100 : barPct);
    int filled = (long)(barW - 2) * safe / 100;
    tft.fillRect(barX, barY, barW, barH, C_DARK);
    if (filled > 0) tft.fillRect(barX + 1, barY + 1, filled, barH - 2, barColor);
}
void drawTempCard(bool full) {
    char buf[12];
    dtostrf(cpuTemp, 4, 1, buf);
    int n = (int)strlen(buf);
    if (n + 3 < (int)sizeof(buf)) { buf[n] = (char)0xF8; buf[n+1] = 'C'; buf[n+2] = '\0'; }
    drawMiniCard(MINI_LEFT_X, MINI_TOP_Y, MINI_W, MINI_H,
                 "TEMP", C_ORANGE, buf, (int)cpuTemp, tempZoneColor(cpuTemp), full);
}
void drawGpuCard(bool full) {
    char buf[6]; snprintf(buf, sizeof(buf), "%d%%", gpuPercent);
    drawMiniCard(MINI_RIGHT_X, MINI_TOP_Y, MINI_W, MINI_H,
                 "GPU", C_MAGENTA, buf, gpuPercent, miniBarColor(gpuPercent, C_MAGENTA), full);
}
void drawRamCard(bool full) {
    char buf[6]; snprintf(buf, sizeof(buf), "%d%%", memPercent);
    drawMiniCard(MINI_LEFT_X, MINI_BOT_Y, MINI_W, MINI_H,
                 "RAM", C_CYAN, buf, memPercent, miniBarColor(memPercent, C_CYAN), full);
}
void drawDskCard(bool full) {
    char buf[6]; snprintf(buf, sizeof(buf), "%d%%", diskPercent);
    drawMiniCard(MINI_RIGHT_X, MINI_BOT_Y, MINI_W, MINI_H,
                 "DSK", C_YELLOW, buf, diskPercent, miniBarColor(diskPercent, C_YELLOW), full);
}

// ─────────────── Sparklines ───────────────
void drawSparkline(int x, int y, int w, int h,
                   const char *label, uint16_t labelColor,
                   int curValue, const char *unit,
                   int colorMode, uint16_t lineColor, bool isTemp) {
    tft.fillRoundRect(x, y, w, h, 4, C_DARKER);
    tft.drawRoundRect(x, y, w, h, 4, C_DIVIDER);
    tft.setTextSize(1);
    tft.setTextColor(labelColor, C_DARKER);
    tft.setCursor(x + 4, y + (h - 8) / 2 + 1);
    tft.print(label);
    char buf[10]; snprintf(buf, sizeof(buf), "%d%s", curValue, unit);
    int strW = strlen(buf) * 6;
    tft.setTextColor(C_WHITE, C_DARKER);
    tft.setCursor(x + w - strW - 4, y + (h - 8) / 2 + 1);
    tft.print(buf);
    int gx = x + SPARK_LBL_W;
    int gw = w - SPARK_LBL_W - (strW + 8);
    int gy = y + 2, gh = h - 4;
    if (gw < 30 || histCount < 2) return;
    int n = histCount < HISTORY_LEN ? histCount : HISTORY_LEN;
    if (isTemp) {
        float tmin = 999, tmax = -999;
        for (int i = 0; i < n; i++) {
            int idx = (histIdx - n + i + HISTORY_LEN) % HISTORY_LEN;
            if (tempHist[idx] < tmin) tmin = tempHist[idx];
            if (tempHist[idx] > tmax) tmax = tempHist[idx];
        }
        tmin = ((int)(tmin / 5)) * 5;
        tmax = ((int)(tmax / 5) + 1) * 5;
        if (tmax - tmin < 5) tmax = tmin + 5;
        float range = tmax - tmin;
        for (int i = 1; i < n; i++) {
            int i0 = (histIdx - n + i - 1 + HISTORY_LEN) % HISTORY_LEN;
            int i1 = (histIdx - n + i      + HISTORY_LEN) % HISTORY_LEN;
            int px0 = gx + (long)gw * (i - 1) / (HISTORY_LEN - 1);
            int px1 = gx + (long)gw *  i      / (HISTORY_LEN - 1);
            int py0 = gy + gh - 1 - (int)((float)gh * (tempHist[i0] - tmin) / range);
            int py1 = gy + gh - 1 - (int)((float)gh * (tempHist[i1] - tmin) / range);
            tft.drawLine(px0, py0, px1, py1, tempZoneColor(tempHist[i1]));
        }
    } else {
        const uint8_t *hist = (colorMode == 2) ? gpuHist : cpuHist;
        for (int i = 1; i < n; i++) {
            int i0 = (histIdx - n + i - 1 + HISTORY_LEN) % HISTORY_LEN;
            int i1 = (histIdx - n + i      + HISTORY_LEN) % HISTORY_LEN;
            int px0 = gx + (long)gw * (i - 1) / (HISTORY_LEN - 1);
            int px1 = gx + (long)gw *  i      / (HISTORY_LEN - 1);
            int py0 = gy + gh - 1 - (long)gh * hist[i0] / 100;
            int py1 = gy + gh - 1 - (long)gh * hist[i1] / 100;
            tft.drawLine(px0, py0, px1, py1, lineColor);
        }
    }
}
void drawSparklineTemp() { drawSparkline(SPARK_X, SPARK_TEMP_Y, SPARK_W, SPARK_H, "TEMP", C_ORANGE, (int)cpuTemp, "\xF7""C", 0, C_ORANGE, true); }
void drawSparklineGpu()  { drawSparkline(SPARK_X, SPARK_GPU_Y,  SPARK_W, SPARK_H, "GPU",  C_MAGENTA, gpuPercent,  "%",      2, C_MAGENTA, false); }
void drawSparklineCpu()  { drawSparkline(SPARK_X, SPARK_CPU_Y,  SPARK_W, SPARK_H, "CPU",  C_GREEN,   cpuAverage(), "%",      1, C_GREEN, false); }

// ─────────────── Cores verticais ───────────────
void drawCoresStatic() {
    tft.fillRect(0, CORES_Y0, TFT_W, FOOTER_Y - CORES_Y0 - 2, C_BG);
    tft.drawFastHLine(0, CORES_BAR_BASE + 1, TFT_W, C_DIVIDER);
    if (numEcores > 0 && numEcores < numCores) {
        int slot = TFT_W / numCores;
        int sepX = numEcores * slot - 1;
        tft.drawFastVLine(sepX, CORES_BAR_TOP - 4, CORES_BAR_BASE - CORES_BAR_TOP + 6, C_DIVIDER);
    }
}
void drawOneCoreBar(int idx) {
    if (numCores == 0) return;
    int slot = TFT_W / numCores;
    int gap  = (slot < 18) ? 2 : 3;
    int barW = slot - 2 * gap;
    if (barW < 6) barW = 6;
    int x = idx * slot + gap;
    tft.fillRect(idx * slot, CORES_BAR_TOP - 4, slot, CORES_BAR_BASE - CORES_BAR_TOP + 18, C_BG);
    if (numEcores > 0 && numEcores == idx) {
        tft.drawFastVLine(idx * slot - 1, CORES_BAR_TOP - 4, CORES_BAR_BASE - CORES_BAR_TOP + 6, C_DIVIDER);
    }
    int pct = cpuCores[idx];
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    bool isE = (idx < numEcores);
    uint16_t col = coreLoadColor(pct, isE);
    uint16_t baseTint = isE ? C_CYAN : C_GREEN;
    tft.fillRect(x, CORES_BAR_TOP, barW, CORES_BAR_H, C_DARK);
    tft.drawRect(x, CORES_BAR_TOP, barW, CORES_BAR_H, C_DIVIDER);
    int filledH = (long)(CORES_BAR_H - 2) * pct / 100;
    if (filledH > 0) {
        int fy = CORES_BAR_BASE - 1 - filledH;
        tft.fillRect(x + 1, fy, barW - 2, filledH, col);
        tft.drawFastHLine(x + 1, fy, barW - 2, C_WHITE);
    }
    tft.setTextSize(1);
    tft.setTextColor(baseTint, C_BG);
    char lbl[4];
    snprintf(lbl, sizeof(lbl), "%c%d", isE ? 'E' : 'P', isE ? idx : (idx - numEcores));
    int strW = strlen(lbl) * 6;
    int lx = x + (barW - strW) / 2;
    if (lx < x) lx = x;
    tft.setCursor(lx, CORES_LBL_Y);
    tft.print(lbl);
}
void drawAllCores() { for (uint8_t i = 0; i < numCores; i++) drawOneCoreBar(i); }

// ─────────────── Footer ───────────────
void drawFooterStatic() {
    tft.fillRect(0, FOOTER_Y, TFT_W, FOOTER_H, C_BG);
    tft.drawFastHLine(0, FOOTER_Y, TFT_W, C_DIVIDER);
}
void drawFooter() {
    tft.fillRect(0, FOOTER_Y + 2, TFT_W, FOOTER_H - 2, C_BG);
    tft.setTextSize(1);
    tft.setTextColor(C_GREEN, C_BG);
    tft.setCursor(6, FOOTER_Y + 6);
    tft.print((char)0x18);
    tft.setTextColor(C_WHITE, C_BG); tft.print(" "); tft.print(netUp, 2);
    tft.setTextColor(C_DIMGRAY, C_BG); tft.print("MB/s");
    tft.setTextColor(C_CYAN, C_BG);
    tft.setCursor(96, FOOTER_Y + 6);
    tft.print((char)0x19);
    tft.setTextColor(C_WHITE, C_BG); tft.print(" "); tft.print(netDown, 2);
    tft.setTextColor(C_DIMGRAY, C_BG); tft.print("MB/s");
    tft.setTextColor(C_DIMGRAY, C_BG);
    tft.setCursor(190, FOOTER_Y + 6);
    tft.print("RX:"); tft.print(pktCount);
}

void redrawAll() {
    tft.fillScreen(C_BG);
    drawHeader();
    drawFanBadge();
    drawTempCard(true);
    drawGpuCard(true);
    drawRamCard(true);
    drawDskCard(true);
    drawSparklineTemp();
    drawSparklineGpu();
    drawSparklineCpu();
    drawCoresStatic();
    drawAllCores();
    drawFooterStatic();
    drawFooter();
}

// ─────────────── Render dirty-diff ───────────────
void renderDirty() {
    bool layoutChanged = (numCores != prevNumCores) || (numEcores != prevNumEcores);
    if (firstFrame) {
        // empilha primeira amostra de histórico
        tempHist[histIdx] = cpuTemp;
        cpuHist[histIdx]  = (uint8_t)cpuAverage();
        gpuHist[histIdx]  = (uint8_t)gpuPercent;
        histIdx = (histIdx + 1) % HISTORY_LEN;
        if (histCount < HISTORY_LEN) histCount++;
        redrawAll();
        for (uint8_t i = 0; i < numCores; i++) prevCpuCores[i] = cpuCores[i];
        prevNumCores = numCores; prevNumEcores = numEcores;
        prevCpuTemp = cpuTemp; prevGpuPercent = gpuPercent;
        prevMemPercent = memPercent; prevDiskPercent = diskPercent;
        prevNetUp = netUp; prevNetDown = netDown;
        strncpy(prevHostBuf, hostBuf, INFO_LEN);
        strncpy(prevInfoBuf, infoBuf, INFO_LEN);
        firstFrame = false;
        return;
    }

    // header (host/info changes)
    if (strncmp(prevHostBuf, hostBuf, INFO_LEN) != 0 ||
        strncmp(prevInfoBuf, infoBuf, INFO_LEN) != 0) {
        drawHeader();
        drawFanBadge();
        strncpy(prevHostBuf, hostBuf, INFO_LEN);
        strncpy(prevInfoBuf, infoBuf, INFO_LEN);
    }

    if (layoutChanged) {
        drawCoresStatic();
        yieldSerial();
        drawAllCores();
        for (uint8_t i = 0; i < numCores; i++) prevCpuCores[i] = cpuCores[i];
    } else {
        for (uint8_t i = 0; i < numCores; i++) {
            if (cpuCores[i] != prevCpuCores[i]) {
                drawOneCoreBar(i);
                prevCpuCores[i] = cpuCores[i];
            }
        }
    }
    prevNumCores = numCores; prevNumEcores = numEcores;
    yieldSerial();

    // empilha histórico
    tempHist[histIdx] = cpuTemp;
    cpuHist[histIdx]  = (uint8_t)cpuAverage();
    gpuHist[histIdx]  = (uint8_t)((gpuPercent > 100) ? 100 : gpuPercent);
    histIdx = (histIdx + 1) % HISTORY_LEN;
    if (histCount < HISTORY_LEN) histCount++;

    if (cpuTemp != prevCpuTemp)         { drawTempCard(false); prevCpuTemp = cpuTemp; }
    yieldSerial();
    if (gpuPercent != prevGpuPercent)   { drawGpuCard(false);  prevGpuPercent = gpuPercent; }
    yieldSerial();
    if (memPercent != prevMemPercent)   { drawRamCard(false);  prevMemPercent = memPercent; }
    yieldSerial();
    if (diskPercent != prevDiskPercent) { drawDskCard(false);  prevDiskPercent = diskPercent; }
    yieldSerial();

    drawSparklineTemp();
    yieldSerial();
    drawSparklineGpu();
    yieldSerial();
    drawSparklineCpu();
    yieldSerial();

    if (netUp != prevNetUp || netDown != prevNetDown) {
        drawFooter();
        prevNetUp = netUp; prevNetDown = netDown;
    } else {
        // só atualiza RX counter
        tft.fillRect(190, FOOTER_Y + 5, 50, 9, C_BG);
        tft.setTextSize(1);
        tft.setTextColor(C_DIMGRAY, C_BG);
        tft.setCursor(190, FOOTER_Y + 6);
        tft.print("RX:"); tft.print(pktCount);
    }
}

// ─────────────── Protocolo v2: parser e ACK ───────────────

// Calcula XOR cumulativo de buf[0..len-1] (len é índice depois do ';' inclusive).
uint8_t xorChecksum(const char *buf, uint8_t len) {
    uint8_t cs = 0;
    for (uint8_t i = 0; i < len; i++) cs ^= (uint8_t)buf[i];
    return cs;
}

// Converte 2 chars hex (uppercase) pra uint8_t. Retorna 256 se inválido.
uint16_t parseHex2(const char *s) {
    uint16_t out = 0;
    for (uint8_t i = 0; i < 2; i++) {
        char c = s[i];
        out <<= 4;
        if      (c >= '0' && c <= '9') out |= (c - '0');
        else if (c >= 'A' && c <= 'F') out |= (c - 'A' + 10);
        else if (c >= 'a' && c <= 'f') out |= (c - 'a' + 10);
        else return 256;
    }
    return out;
}

// Envia ACK com checksum invertido.
// `payloadLen` inclui o ';' final.
void sendAck(const char *payload, uint8_t payloadLen, uint8_t originalCs) {
    uint8_t inverted = originalCs ^ 0xFF;
    char hex[3];
    snprintf(hex, sizeof(hex), "%02X", inverted);
    Serial.write((const uint8_t*)payload, payloadLen);  // TOKEN:VALOR;
    Serial.write((const uint8_t*)hex, 2);
    Serial.write('\n');
    Serial.flush();  // garante envio imediato — não bufferiza
}

// Aplica comando: TOKEN+VALOR.
// `tokenLen` é tamanho do TOKEN (sem ':'). `val` aponta pro VALOR (terminado em '\0').
void applyCommand(const char *token, uint8_t tokenLen, char *val) {
    // Comparação direta usando memcmp pra evitar strcmp com não-terminadas.
    #define TOK_EQ(s) (tokenLen == sizeof(s)-1 && memcmp(token, s, sizeof(s)-1) == 0)

    if (TOK_EQ("TEMP")) {
        cpuTemp = atof(val); stateDirty = true;
    } else if (TOK_EQ("CPU")) {
        // CSV: "50,30,20,10,80,75,60,45"
        uint8_t n = 0;
        char *p = val;
        while (*p && n < MAX_CORES) {
            cpuCores[n++] = (uint8_t)atoi(p);
            char *comma = strchr(p, ',');
            if (!comma) break;
            p = comma + 1;
        }
        numCores = n;
        stateDirty = true;
    } else if (TOK_EQ("ECORES")) {
        numEcores = (uint8_t)atoi(val); stateDirty = true;
    } else if (TOK_EQ("GPU")) {
        gpuPercent = (uint8_t)atoi(val); stateDirty = true;
    } else if (TOK_EQ("MEM")) {
        memPercent = (uint8_t)atoi(val); stateDirty = true;
    } else if (TOK_EQ("DSK")) {
        diskPercent = (uint8_t)atoi(val); stateDirty = true;
    } else if (TOK_EQ("NET_UP")) {
        netUp = atof(val); stateDirty = true;
    } else if (TOK_EQ("NET_DN")) {
        netDown = atof(val); stateDirty = true;
    } else if (TOK_EQ("FAN")) {
        bool wantOn = (val[0] == '1');
        if (wantOn != fanState) {
            writeFan(wantOn);
            drawFanBadge();  // imediato (não espera render timer)
        }
        // FAN não marca stateDirty pra full render (só badge mudou)
    } else if (TOK_EQ("HOST")) {
        // Trunca em INFO_LEN-1, marca '+' se truncou
        uint8_t vlen = (uint8_t)strlen(val);
        if (vlen >= INFO_LEN - 1) {
            strncpy(hostBuf, val, INFO_LEN - 2);
            hostBuf[INFO_LEN - 2] = '+';
            hostBuf[INFO_LEN - 1] = '\0';
        } else {
            strncpy(hostBuf, val, INFO_LEN - 1);
            hostBuf[INFO_LEN - 1] = '\0';
        }
        stateDirty = true;
    } else if (TOK_EQ("INFO")) {
        uint8_t vlen = (uint8_t)strlen(val);
        if (vlen >= INFO_LEN - 1) {
            strncpy(infoBuf, val, INFO_LEN - 2);
            infoBuf[INFO_LEN - 2] = '+';
            infoBuf[INFO_LEN - 1] = '\0';
        } else {
            strncpy(infoBuf, val, INFO_LEN - 1);
            infoBuf[INFO_LEN - 1] = '\0';
        }
        stateDirty = true;
    } else if (TOK_EQ("CLEAR")) {
        hostBuf[0] = '\0'; infoBuf[0] = '\0';
        stateDirty = true;
    } else if (TOK_EQ("CLRVAR")) {
        cpuTemp = 0;
        memset(cpuCores, 0, sizeof(cpuCores));
        numCores = 0; numEcores = 0;
        gpuPercent = 0; memPercent = 0; diskPercent = 0;
        netUp = 0; netDown = 0;
        histCount = 0; histIdx = 0;
        stateDirty = true;
    } else if (TOK_EQ("RESET")) {
        hostBuf[0] = '\0'; infoBuf[0] = '\0';
        cpuTemp = 0;
        memset(cpuCores, 0, sizeof(cpuCores));
        numCores = 0; numEcores = 0;
        gpuPercent = 0; memPercent = 0; diskPercent = 0;
        netUp = 0; netDown = 0;
        histCount = 0; histIdx = 0;
        firstFrame = true;
        stateDirty = true;
    }
    #undef TOK_EQ

    pktCount++;
}

// Processa lineBuf (terminado em '\0' antes do '\n' já consumido).
void processLine() {
    uint8_t len = lineBufPos;  // tamanho sem '\n'
    if (len < 5) return;        // mínimo: "X:;XX" = 5 chars

    // Acha índice do ';' que separa VALOR do checksum.
    // Os 3 últimos chars devem ser ";XX". Então ';' está em len-3.
    if (lineBuf[len - 3] != ';') return;
    uint16_t csReceived = parseHex2(&lineBuf[len - 2]);
    if (csReceived > 255) return;  // hex inválido

    uint8_t payloadLen = len - 2;  // inclui o ';'
    uint8_t csCalc = xorChecksum(lineBuf, payloadLen);
    if (csCalc != (uint8_t)csReceived) return;  // checksum FAIL → silêncio

    // Manda ACK ANTES de aplicar (pra caso a aplicação demore, sender já sabe que recebeu)
    sendAck(lineBuf, payloadLen, csCalc);

    // Acha ':' separando TOKEN de VALOR
    char *colon = (char*)memchr(lineBuf, ':', payloadLen);
    if (!colon) return;
    uint8_t tokenLen = (uint8_t)(colon - lineBuf);
    if (tokenLen == 0 || tokenLen > 8) return;

    // VALOR começa em colon+1, termina em ';' (que vamos sobrescrever com '\0')
    char *val = colon + 1;
    lineBuf[len - 3] = '\0';  // null no ';' pra terminar val

    applyCommand(lineBuf, tokenLen, val);
}

// ─────────────── yieldSerial ───────────────
// Drena qualquer linha pendente da serial e processa. Chamada DENTRO do
// renderDirty entre primitivas — TFT é lento (200-300ms total), comandos
// ficariam presos no buffer USB sem isso. Comandos de atuação (FAN) atuam
// imediatamente via processLine→applyCommand→writeFan; outros só atualizam
// variáveis (cpuTemp, gpuPercent, etc) e marcam stateDirty pro próximo ciclo.
//
// Reentrância: processLine pode chamar drawFanBadge() (área fixa 186,2,52x14
// no canto superior, isolada). Não conflita com sparklines ou cards.
void yieldSerial() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n') {
            lineBuf[lineBufPos] = '\0';
            if (lineBufPos > 0) processLine();
            lineBufPos = 0;
        } else if (c == '\r') {
            // ignora CR
        } else if (lineBufPos < LINE_BUF_LEN - 1) {
            lineBuf[lineBufPos++] = c;
        } else {
            lineBufPos = 0;
        }
    }
}

// ─────────────── Setup & Loop ───────────────
void setup() {
    // FAN OFF garantido ANTES de qualquer outra coisa
    digitalWrite(RELAY_PIN, HIGH);  // pre-set buffer (HIGH = OFF em active LOW)
    pinMode(RELAY_PIN, OUTPUT);
    digitalWrite(RELAY_PIN, HIGH);
    fanState = false;

    Serial.begin(115200);

    tft.begin(0x9341);
    tft.setRotation(0);
    drawSplash();
    drawFanBadge();

    for (uint8_t i = 0; i < MAX_CORES; i++) prevCpuCores[i] = 255;
}

void loop() {
    // 1. Recepção: lê bytes até \n, então processa linha
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n') {
            lineBuf[lineBufPos] = '\0';
            if (lineBufPos > 0) processLine();
            lineBufPos = 0;
        } else if (c == '\r') {
            // ignora CR (caso sender mande CRLF)
        } else if (lineBufPos < LINE_BUF_LEN - 1) {
            lineBuf[lineBufPos++] = c;
        } else {
            // Buffer cheio sem \n — descarta o resto da linha
            lineBufPos = 0;
        }
    }

    // 2. Render por timer (RTOS-style): só repinta se passou interval E há mudança.
    // stateDirty limpa ANTES do render — o renderDirty chama yieldSerial entre
    // primitivas, que pode disparar processLine e setar stateDirty=true (TEMP novo,
    // CPU novo, etc). Esse "dirty pendente" precisa sobreviver pra próximo ciclo,
    // senão atualizações que chegam durante render são perdidas.
    unsigned long now = millis();
    if (stateDirty && (now - lastRenderAt >= RENDER_MS)) {
        lastRenderAt = now;
        stateDirty = false;
        renderDirty();
    }

}
