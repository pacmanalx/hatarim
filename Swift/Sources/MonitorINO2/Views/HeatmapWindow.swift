import SwiftUI
import AppKit

/// Janela de espectrograma 2D mostrando disponibilidade dos health checks.
/// Eixo X = últimos 7 dias, Eixo Y = hora do dia (0-24h),
/// Cor (calor) = quantidade de hits codificada em HSL+brilho:
///   - Hue: uptime % (vermelho 0% → ciano 100%)
///   - Lightness: latência relativa (escuro = rápido, claro = lento)
///   - Brightness/saturation: densidade de hits no bucket
struct HeatmapWindow: View {
    @ObservedObject var store: ServicesStore
    @ObservedObject var scheduler: HealthCheckScheduler

    @State private var entries: [HealthEntry] = []
    @State private var selectedSid: String? = nil   // nil = todos
    @State private var selectedLevel: Int? = nil     // nil = todos
    @State private var hoverBucket: BucketKey? = nil

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            heatmapPane
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reload() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Filtros")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                filterRow(label: "Todos os serviços", isSelected: selectedSid == nil) {
                    selectedSid = nil
                }
                ForEach(store.config.services) { svc in
                    filterRow(label: svc.name,
                              isSelected: selectedSid == String(svc.id.uuidString.prefix(8))) {
                        selectedSid = String(svc.id.uuidString.prefix(8))
                    }
                }

                Divider().padding(.vertical, 4)

                Text("Nível")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                filterRow(label: "Todos", isSelected: selectedLevel == nil) { selectedLevel = nil }
                filterRow(label: "L1 — Conectividade", isSelected: selectedLevel == 1) { selectedLevel = 1 }
                filterRow(label: "L2 — Auth", isSelected: selectedLevel == 2) { selectedLevel = 2 }
                filterRow(label: "L3 — End-to-end", isSelected: selectedLevel == 3) { selectedLevel = 3 }

                Divider().padding(.vertical, 4)

                Button {
                    reload()
                } label: {
                    Label("Recarregar", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }

                Spacer()

                stats
            }
            .padding(14)
        }
    }

    private func filterRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(label).font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Histórico").font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            Text("\(filteredEntries.count) checks no filtro")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(entries.count) totais nos últimos 7d")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Main pane

    private var heatmapPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 8) {
                yAxis
                heatmapGrid
            }
            xAxis
            Divider()
            HStack(alignment: .top, spacing: 12) {
                colorbarLegend
                Spacer()
                hoverInfo
            }
        }
        .padding(14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.tint)
                Text("Espectrograma de disponibilidade — 7 dias")
                    .font(.title3.bold())
                Spacer()
            }
            Text("X: dias  ·  Y: hora do dia 0–24h  ·  vermelho = saudável + ativo · azul = falhas / inatividade · brilho = densidade de hits")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 24 linhas × 7 colunas
    private var heatmapGrid: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / 7
            let cellH = geo.size.height / 24
            let bucketsByKey = computeBuckets()
            let maxHits = max(bucketsByKey.values.map(\.count).max() ?? 1, 1)

            ZStack(alignment: .topLeading) {
                ForEach(0..<7, id: \.self) { dayIdx in
                    ForEach(0..<24, id: \.self) { hour in
                        let key = BucketKey(dayIndex: dayIdx, hour: hour)
                        let bucket = bucketsByKey[key]
                        let color = bucket.map { spectralColor(uptime: $0.uptimePct, latency: $0.avgLatencyMs, hits: $0.count, maxHits: maxHits) } ?? Color.black.opacity(0.04)

                        Rectangle()
                            .fill(color)
                            .frame(width: cellW, height: cellH)
                            .position(x: cellW * (CGFloat(dayIdx) + 0.5),
                                      y: cellH * (CGFloat(23 - hour) + 0.5))
                            .onHover { hovering in
                                if hovering { hoverBucket = key }
                            }
                    }
                }
                // Border
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(minHeight: 360)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Axes

    private var yAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // 23h em cima, 0h embaixo (eixo cartesiano com Y crescendo pra cima)
            ForEach((0..<24).reversed(), id: \.self) { hour in
                Text(hour % 3 == 0 ? String(format: "%02dh", hour) : "")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .frame(width: 38)
    }

    private var xAxis: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 38)
            ForEach(0..<7, id: \.self) { dayIdx in
                Text(dayLabel(dayIdx))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Legend & Hover

    private var colorbarLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Legenda").font(.caption.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 0) {
                ForEach(0..<40, id: \.self) { i in
                    let pct = Double(i) / 39.0 * 100
                    spectralColor(uptime: pct, latency: 200, hits: 5, maxHits: 5)
                        .frame(width: 6, height: 14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                Text("0% uptime (frio)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("100% (quente)").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 240)
            HStack(spacing: 12) {
                Label("Azul = falhas / inativo", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Vermelho = saudável + ativo", systemImage: "circle.fill").foregroundStyle(.red)
            }
            .font(.caption2)
            Text("Brilho da célula = densidade de hits no intervalo (mais hits = mais quente)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var hoverInfo: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let key = hoverBucket {
                let buckets = computeBuckets()
                let b = buckets[key]
                Text(bucketTitle(key)).font(.caption.bold())
                if let b = b {
                    Text("\(b.count) hits · uptime \(String(format: "%.0f%%", b.uptimePct))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if b.avgLatencyMs > 0 {
                        Text("latência média: \(b.avgLatencyMs) ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("sem dados").font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Text("Passe o mouse sobre uma célula").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Computation

    private func reload() {
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86400)
        entries = scheduler.historyStore.load(since: cutoff)
    }

    private var filteredEntries: [HealthEntry] {
        entries.filter { e in
            (selectedSid == nil || e.sid == selectedSid) &&
            (selectedLevel == nil || e.lv == selectedLevel)
        }
    }

    struct BucketKey: Hashable {
        let dayIndex: Int   // 0 = 6 dias atrás, 6 = hoje
        let hour: Int       // 0-23
    }

    struct BucketStats {
        var count: Int
        var okCount: Int
        var totalLatency: Int
        var latencyCount: Int

        var uptimePct: Double {
            count > 0 ? Double(okCount) / Double(count) * 100 : 0
        }
        var avgLatencyMs: Int {
            latencyCount > 0 ? totalLatency / latencyCount : 0
        }
    }

    private func computeBuckets() -> [BucketKey: BucketStats] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let cutoff = todayStart.addingTimeInterval(-6 * 86400)

        var out: [BucketKey: BucketStats] = [:]
        for e in filteredEntries where e.ts >= cutoff {
            let dayDiff = cal.dateComponents([.day], from: cutoff, to: cal.startOfDay(for: e.ts)).day ?? 0
            guard (0..<7).contains(dayDiff) else { continue }
            let hour = cal.component(.hour, from: e.ts)
            let key = BucketKey(dayIndex: dayDiff, hour: hour)
            var b = out[key] ?? BucketStats(count: 0, okCount: 0, totalLatency: 0, latencyCount: 0)
            b.count += 1
            if e.st == "ok" { b.okCount += 1 }
            if let lat = e.lat, lat > 0 {
                b.totalLatency += lat
                b.latencyCount += 1
            }
            out[key] = b
        }
        return out
    }

    private func dayLabel(_ idx: Int) -> String {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let date = todayStart.addingTimeInterval(Double(idx - 6) * 86400)
        let f = DateFormatter()
        f.dateFormat = "EE dd"
        f.locale = Locale(identifier: "pt_BR")
        return f.string(from: date).uppercased()
    }

    private func bucketTitle(_ key: BucketKey) -> String {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let date = todayStart.addingTimeInterval(Double(key.dayIndex - 6) * 86400)
        let f = DateFormatter()
        f.dateFormat = "EEEE dd/MM"
        f.locale = Locale(identifier: "pt_BR")
        return "\(f.string(from: date)) · \(String(format: "%02dh", key.hour))-\(String(format: "%02dh", key.hour + 1))"
    }

    /// Mapeamento espectral 3D estilo termovisor:
    ///   - Hue: vermelho (Hue 0) = 100% uptime · azul/ciano (Hue 0.58) = 0%
    ///   - Saturation: alta quando rápido, pálida quando lento
    ///   - Brightness: densidade de hits (mais hits = mais quente)
    /// Vermelho = bom (alta utilização + poucas falhas).
    private func spectralColor(uptime: Double, latency: Int, hits: Int, maxHits: Int) -> Color {
        // INVERTIDO: 100% uptime = vermelho (0deg) · 0% = ciano-azul (~210deg)
        let hue = (1.0 - uptime / 100.0) * 0.58
        // Latency: <50ms = denso/saturado, >2000ms = pálido
        let latNorm = min(Double(max(latency, 0)) / 2000.0, 1.0)
        let saturation = 1.0 - latNorm * 0.5
        // Brightness: densidade de hits (log scale)
        let densityNorm = log(Double(hits) + 1) / log(Double(maxHits) + 1)
        let brightness = 0.4 + densityNorm * 0.6
        return Color(hue: hue, saturation: saturation, brightness: brightness, opacity: 1.0)
    }
}
