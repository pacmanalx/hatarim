import SwiftUI
import AppKit

struct GPUBenchWindow: View {
    @ObservedObject var stats: SystemStats
    @StateObject private var engine = GPUBenchEngine()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
            Divider()
            HStack(spacing: 0) {
                MetalCanvasView(engine: engine, vsync: engine.vsync)
                    .frame(minWidth: 360, minHeight: 320)
                Divider()
                metricsPane
                    .frame(width: 220)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker(L.t("Scene", "Cena"), selection: Binding(
                get: { engine.sceneIndex },
                set: { engine.selectScene($0) }
            )) {
                ForEach(Array(engine.scenes.enumerated()), id: \.offset) { idx, s in
                    Text(s.name).tag(idx)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            if let scene = engine.currentScene {
                let lo = scene.loadRange.lowerBound
                let hi = scene.loadRange.upperBound
                Text("\(scene.loadLabel.capitalized):")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(engine.load) },
                    set: { engine.load = Int($0) }
                ), in: Double(lo)...Double(hi))
                .frame(maxWidth: 240)
                Text("\(formatLoad(engine.load))")
                    .frame(width: 70, alignment: .leading)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            Spacer()

            Toggle(isOn: $engine.vsync) {
                Text("VSync").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L.t("VSync off lets GPU work flat-out per frame instead of blocking on display refresh.",
                      "VSync off libera a GPU pra trabalhar sem bloquear no refresh do display."))

            Button(engine.running
                   ? L.t("Stop", "Parar")
                   : L.t("Start", "Iniciar")) {
                engine.running.toggle()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button {
                copyReport()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help(L.t("Copy report", "Copiar relatório"))
            .disabled(!engine.running && engine.fps == 0)
        }
    }

    private var metricsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricBlock(title: "FPS",
                        value: String(format: "%.1f", engine.fps),
                        accent: fpsColor(engine.fps))
            metricBlock(title: L.t("Frame", "Frame"),
                        value: String(format: "%.2f ms", engine.frameMS),
                        accent: .secondary)
            HStack(spacing: 8) {
                metricSmall(title: "p50", value: String(format: "%.1f", engine.p50MS))
                metricSmall(title: "p99", value: String(format: "%.1f", engine.p99MS))
            }

            Divider()

            sysRow(label: "GPU", value: gpuLine)
            sysRow(label: L.t("GPU power", "Power GPU"), value: powerLine)
            sysRow(label: L.t("GPU temp", "Temp GPU"), value: tempLine)
            sysRow(label: "CPU avg", value: String(format: "%.1f%%", stats.cpuAverage))

            Divider()

            Text(L.t("FPS history", "Histórico de FPS"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Sparkline(series: [
                SparkSeries(values: engine.fpsHistory,
                            color: .green,
                            label: nil,
                            filled: true)
            ], maxScale: nil, minFloor: 30, showGrid: true)
            .frame(height: 60)

            Spacer()
        }
        .padding(12)
    }

    private func metricBlock(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
        }
    }

    private func metricSmall(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sysRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }

    private var gpuLine: String {
        if let u = stats.gpuUtilPercent {
            return String(format: "%.0f%%", u)
        }
        return "—"
    }

    private var powerLine: String {
        let mW = stats.power.gpuMilliwatts
        if mW < 1 { return "—" }
        if mW < 1000 { return String(format: "%.0f mW", mW) }
        return String(format: "%.2f W", mW / 1000)
    }

    private var tempLine: String {
        if stats.gpuTempC > 0 { return String(format: "%.1f °C", stats.gpuTempC) }
        return "—"
    }

    private func fpsColor(_ fps: Double) -> Color {
        if fps == 0 { return .secondary }
        if fps >= 100 { return .green }
        if fps >= 50  { return .yellow }
        return .red
    }

    private func formatLoad(_ v: Int) -> String {
        if v >= 10_000 { return "\(v / 1000)k" }
        return "\(v)"
    }

    private func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(engine.report(), forType: .string)
    }
}
