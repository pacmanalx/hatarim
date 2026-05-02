import SwiftUI
import AppKit

struct FanControlWindow: View {
    @ObservedObject var store: FanConfigStore
    @ObservedObject var controller: FanController
    let bridge: ArduinoBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                debugButtonsCard
                liveCard
                modeCard
                if store.config.mode == .pidTPO {
                    pidCard
                    cycleCard
                }
                if store.config.mode == .hysteresis {
                    hysteresisCard
                }
                hardCapCard
                trendCard
                footerCard
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// Botões L/D — mudam o MODO do controller (alwaysOn / alwaysOff) E
    /// disparam atuação imediata via bridge (priority). Mudar só o arquivo
    /// direto não basta: o tick do sender (a cada 2s) reenvia baseado em
    /// `fanShouldBeOn` do controller, que ignora o estado escrito manualmente.
    /// Setando o modo, sender e botão concordam.
    private var debugButtonsCard: some View {
        Card(icon: "bolt.fill", iconColor: .yellow, title: "Atuação rápida",
             subtitle: "Liga/desliga muda modo pra alwaysOn/alwaysOff e dispara FAN imediato.") {
            HStack(spacing: 16) {
                Button {
                    forceFanState(on: true)
                } label: {
                    Text("L  →  Sempre ligada")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut("l", modifiers: [])

                Button {
                    forceFanState(on: false)
                } label: {
                    Text("D  →  Sempre desligada")
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("d", modifiers: [])
            }
            Text("Atalhos: L ou D com a janela em foco. Muda o modo no card abaixo.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func forceFanState(on: Bool) {
        let desired: FanMode = on ? .alwaysOn : .alwaysOff
        // Idempotente: se já está no estado pedido, no-op. Cliques duplos /
        // teclas seguradas / acidente de mouse não geram tráfego extra.
        guard store.config.mode != desired else {
            FileHandle.standardError.write(Data(
                "FanCmd: BUTTON forceFanState(on: \(on)) — IGNORADO (já em \(desired.rawValue))\n".utf8
            ))
            return
        }
        FileHandle.standardError.write(Data(
            "FanCmd: BUTTON forceFanState(on: \(on)) — mode anterior=\(store.config.mode.rawValue)\n".utf8
        ))
        store.config.mode = desired
        bridge.sendCommandPriority(token: .fan, value: on ? "1" : "0")
    }

    // MARK: - Live readings

    private var liveCard: some View {
        Card(icon: "fan.fill", iconColor: controller.fanShouldBeOn ? .green : .secondary,
             title: "Estado atual",
             subtitle: "Decisão sendo enviada ao Arduino agora") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    metricCell("Temperatura", value: String(format: "%.1f °C", controller.currentTempC), color: tempColor)
                    metricCell("Setpoint",   value: String(format: "%.1f °C", store.config.setpointC), color: .blue)
                }
                GridRow {
                    metricCell("Erro",  value: String(format: "%+.1f °C", controller.lastErrorC),
                               color: abs(controller.lastErrorC) < 2 ? .green : (controller.lastErrorC > 0 ? .orange : .cyan))
                    metricCell("Duty (PID)", value: String(format: "%.0f%%", controller.currentDutyPct), color: .purple)
                }
                GridRow {
                    metricCell("FAN agora",
                               value: controller.fanShouldBeOn ? "🟢 ON" : "⚫️ OFF",
                               color: controller.fanShouldBeOn ? .green : .secondary)
                    metricCell("Hard cap",
                               value: controller.hardCapTriggered ? "⚠️ ATIVO" : "—",
                               color: controller.hardCapTriggered ? .red : .secondary)
                }
            }
        }
    }

    private var tempColor: Color {
        let t = controller.currentTempC
        if t >= store.config.thermalHardCapC { return .red }
        if t >= store.config.setpointC + 5 { return .orange }
        if t >= store.config.setpointC { return .yellow }
        return .green
    }

    private func metricCell(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - Mode

    private var modeCard: some View {
        Card(icon: "switch.2", iconColor: .blue, title: "Modo de controle",
             subtitle: "Como decidimos quando ligar/desligar a fan") {
            Picker("", selection: $store.config.mode) {
                ForEach(FanMode.allCases) { m in
                    Label(m.displayName, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(modeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var modeHelp: String {
        switch store.config.mode {
        case .alwaysOff:  return "FAN forçada SEMPRE desligada. Cuidado: sem proteção contra overheat (exceto hard cap)."
        case .alwaysOn:   return "FAN forçada SEMPRE ligada (modo legado, comportamento atual antes do controle)."
        case .pidTPO:     return "PID gera duty 0-100% modulado em janela TPO. Recomendado pra carga variável."
        case .hysteresis: return "Liga acima de tempOn, desliga abaixo de tempOff. Banda larga evita chattering."
        }
    }

    // MARK: - PID

    private var pidCard: some View {
        Card(icon: "waveform.path.ecg", iconColor: .purple, title: "PID — sintonia",
             subtitle: "Ganhos do controlador. Comece simples (Kp moderado) e itere.") {
            VStack(spacing: 14) {
                slider("Setpoint", value: $store.config.setpointC, in: 28...80, step: 1, suffix: "°C", color: .blue)
                slider("Kp (proporcional)", value: $store.config.kp, in: 0...20, step: 0.1, suffix: "", color: .orange)
                slider("Ki (integral)",     value: $store.config.ki, in: 0...2,  step: 0.05, suffix: "", color: .green)
                slider("Kd (derivativo)",   value: $store.config.kd, in: 0...5,  step: 0.1, suffix: "", color: .pink)
            }
        }
    }

    private var cycleCard: some View {
        Card(icon: "timer", iconColor: .gray, title: "TPO — janela de ciclo",
             subtitle: "Duty% se traduz em ON/OFF dentro dessa janela. Maior = mais estável + menos cliques.") {
            sliderInt("Cycle time", value: cycleSecBinding, in: 10...300, step: 5, suffix: "s", color: .gray)
            Text("Default 60s. Curto demais (< 20s) faz a fan oscilar; longo demais (> 120s) reage devagar a picos.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var cycleSecBinding: Binding<Int> {
        Binding(
            get: { store.config.cycleTimeMs / 1000 },
            set: { store.config.cycleTimeMs = $0 * 1000 }
        )
    }

    // MARK: - Hysteresis

    private var hysteresisCard: some View {
        Card(icon: "thermometer.variable", iconColor: .orange, title: "Histerese",
             subtitle: "Banda morta entre liga e desliga (evita chattering)") {
            VStack(spacing: 14) {
                slider("Liga acima de", value: tempOnBinding, in: 40...90, step: 1, suffix: "°C", color: .red)
                slider("Desliga abaixo de", value: tempOffBinding, in: 28...80, step: 1, suffix: "°C", color: .cyan)
            }
            let band = Int(store.config.hystTempOnC - store.config.hystTempOffC)
            if band < 5 {
                Text("⚠️ Banda mínima é 5°C — \"Liga\" precisa ser ≥ 5°C acima de \"Desliga\". Auto-ajustado.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Banda atual: \(band)°C — bandas largas (≥10°C) evitam liga-desliga frenético.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Bindings que mantêm a invariante `hystTempOffC + 5 ≤ hystTempOnC`.
    /// Se o usuário arrasta um slider que violaria, o outro é empurrado pra preservar a banda.
    private var tempOnBinding: Binding<Double> {
        Binding(
            get: { store.config.hystTempOnC },
            set: { newOn in
                store.config.hystTempOnC = newOn
                if store.config.hystTempOffC > newOn - 5 {
                    store.config.hystTempOffC = max(28, newOn - 5)
                }
            }
        )
    }

    private var tempOffBinding: Binding<Double> {
        Binding(
            get: { store.config.hystTempOffC },
            set: { newOff in
                store.config.hystTempOffC = newOff
                if store.config.hystTempOnC < newOff + 5 {
                    store.config.hystTempOnC = min(90, newOff + 5)
                }
            }
        )
    }

    // MARK: - Hard cap

    private var hardCapCard: some View {
        Card(icon: "exclamationmark.triangle.fill", iconColor: .red, title: "Hard cap térmico",
             subtitle: "Acima dessa temperatura, FAN força ON — overrides qualquer modo") {
            slider("Hard cap", value: $store.config.thermalHardCapC, in: 80...94, step: 1, suffix: "°C", color: .red)
            Text("Thermal throttling do M1 começa em ~95°C. Default 90°C dá 5°C de margem antes do throttle.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Trend (sparkline)

    private var trendCard: some View {
        Card(icon: "chart.xyaxis.line", iconColor: .teal, title: "Tendência (10 min)",
             subtitle: "Temperatura · Setpoint · Duty% — atualizado em tempo real") {
            Sparkline(series: [
                SparkSeries(values: controller.history.map(\.temperatureC), color: tempColor, label: "Temp", filled: true),
                SparkSeries(values: controller.history.map(\.setpointC),    color: .blue, label: "Setpoint", filled: false),
                SparkSeries(values: controller.history.map { $0.dutyPct * 0.95 + 5 }, color: .purple, label: "Duty", filled: false)
            ], maxScale: 100)
                .frame(height: 100)
            HStack(spacing: 12) {
                legendDot(tempColor, "Temp °C")
                legendDot(.blue, "Setpoint")
                legendDot(.purple, "Duty %")
                Spacer()
                Text("\(controller.history.count) pts")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footerCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Configuração persistida em")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.fileLocation.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Reset defaults") {
                store.config = FanConfig()
            }
            .buttonStyle(.bordered)
            Button("Revelar JSON") {
                NSWorkspace.shared.activateFileViewerSelecting([store.fileLocation])
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Slider helpers

    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, suffix: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f%@", value.wrappedValue, suffix.isEmpty ? "" : " \(suffix)"))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .tint(color)
        }
    }

    private func sliderInt(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>,
                           step: Int, suffix: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            .tint(color)
        }
    }
}

// MARK: - Card chrome

private struct Card<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 26, height: 26)
                    .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
