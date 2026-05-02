import SwiftUI
import AppKit

/// Card consolidador do tier LLM HaTarim — espectrograma 2D de disponibilidade.
/// Eixo X = últimos 7 dias, Eixo Y = hora do dia (0-24h),
/// Cor (calor) = quantidade de hits codificada em HSL+brilho:
///   - Hue: uptime % (vermelho 0% → ciano 100%)
///   - Lightness: latência relativa (escuro = rápido, claro = lento)
///   - Brightness/saturation: densidade de hits no bucket
struct HeatmapCard: View {
    @ObservedObject var store: ServicesStore
    @ObservedObject var scheduler: HealthCheckScheduler

    @State private var entries: [HealthEntry] = []
    @State private var selectedSid: String? = nil   // nil = todos
    @State private var selectedLevel: Int? = nil     // nil = todos
    @State private var hoverBucket: BucketKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.tint)
                Text("Heatmap 7d — consolidado LLM HaTarim")
                    .font(.callout.bold())
                Spacer()
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Recarregar histórico")
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 220)
                heatmapPane
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
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

                stats
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("X: dias  ·  Y: hora do dia 0–24h  ·  amarelo = alta atividade + saudável · roxo escuro = inativo · cor magma com interpolação bilinear")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                yAxis
                heatmapGrid
                colorbarVertical
            }
            xAxis
            Divider()
            hoverInfo
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // 24 linhas × 7 colunas — renderiza CGImage 7×24 e usa interpolação bilinear de
    // Core Graphics pra dar look de spectrogram tipo matplotlib (sem grades visíveis).
    private var heatmapGrid: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / 7
            let cellH = geo.size.height / 24
            let bucketsByKey = computeBuckets()
            let maxHits = max(bucketsByKey.values.map(\.count).max() ?? 1, 1)
            let cgImage = buildSpectrogramImage(buckets: bucketsByKey, maxHits: maxHits)

            ZStack(alignment: .topLeading) {
                if let cgImage = cgImage {
                    Image(decorative: cgImage, scale: 1, orientation: .up)
                        .interpolation(.high)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                // Overlay invisível por bucket pra captar hover sem atrapalhar o gradient
                ForEach(0..<7, id: \.self) { dayIdx in
                    ForEach(0..<24, id: \.self) { hour in
                        let key = BucketKey(dayIndex: dayIdx, hour: hour)
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .frame(width: cellW, height: cellH)
                            .position(x: cellW * (CGFloat(dayIdx) + 0.5),
                                      y: cellH * (CGFloat(23 - hour) + 0.5))
                            .onHover { hovering in
                                if hovering { hoverBucket = key }
                            }
                    }
                }
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(minHeight: 360)
        .background(Color.black)
    }

    /// Monta uma matriz 7×24 de valores em [0..1] (combinando uptime e densidade) e
    /// gera CGImage RGBA. Quando exibido com .interpolation(.high), Core Graphics faz
    /// interpolação bilinear, transformando blocos discretos num gradient suave.
    private func buildSpectrogramImage(buckets: [BucketKey: BucketStats], maxHits: Int) -> CGImage? {
        let W = 7
        let H = 24
        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        for dayIdx in 0..<W {
            for hour in 0..<H {
                let key = BucketKey(dayIndex: dayIdx, hour: hour)
                let py = 23 - hour // Y invertido: hora 23 no topo
                let idx = (py * W + dayIdx) * 4
                let value: Double
                if let b = buckets[key], b.count > 0 {
                    let densityNorm = log(Double(b.count) + 1) / log(Double(maxHits) + 1)
                    let uptimeNorm = b.uptimePct / 100.0
                    // Combina: densidade dá brilho base, uptime modula intensidade.
                    value = densityNorm * (0.35 + 0.65 * uptimeNorm)
                } else {
                    value = 0
                }
                let (r, g, b, a) = magmaRGB(t: value)
                pixels[idx]     = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = a
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: W * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Color ramp `magma` (matplotlib-like): preto → roxo → magenta → laranja → amarelo.
    /// Stops aproximados perceptualmente uniformes. Bom contraste sobre fundo preto.
    private func magmaRGB(t: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        let stops: [(t: Double, r: Double, g: Double, b: Double)] = [
            (0.00, 0.001, 0.000, 0.014),  // preto quase puro
            (0.15, 0.080, 0.045, 0.180),  // azul-violeta escuro
            (0.30, 0.230, 0.060, 0.435),  // roxo profundo
            (0.50, 0.553, 0.183, 0.439),  // magenta
            (0.70, 0.870, 0.288, 0.408),  // vermelho-rosa
            (0.85, 0.985, 0.555, 0.348),  // laranja
            (1.00, 0.987, 0.991, 0.749)   // amarelo claro
        ]
        let clamped = max(0, min(1, t))
        var i = 0
        while i < stops.count - 2 && stops[i + 1].t < clamped { i += 1 }
        let lo = stops[i]
        let hi = stops[i + 1]
        let span = hi.t - lo.t
        let frac = span > 0 ? (clamped - lo.t) / span : 0
        let r = lo.r + (hi.r - lo.r) * frac
        let g = lo.g + (hi.g - lo.g) * frac
        let b = lo.b + (hi.b - lo.b) * frac
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255)
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

    /// Colorbar vertical no estilo matplotlib — barra de gradient à direita do heatmap,
    /// com altura igual à do grid (24 linhas). Labels indicam atividade alta no topo
    /// e inativo embaixo (alinhado ao Y do heatmap onde 23h = topo).
    private var colorbarVertical: some View {
        VStack(spacing: 4) {
            Text("alta")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            // Gradient vertical: topo = magma(1.0), base = magma(0.0)
            ZStack(alignment: .leading) {
                if let cgImage = buildVerticalRampImage() {
                    Image(decorative: cgImage, scale: 1, orientation: .up)
                        .interpolation(.high)
                        .resizable()
                        .frame(width: 16)
                }
            }
            .frame(maxWidth: 16, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            Text("inativo")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(width: 48)
    }

    /// CGImage 1×64 com a rampa magma na vertical (top = 1.0, bottom = 0.0).
    /// Quando esticado, vira gradient suave de cima pra baixo.
    private func buildVerticalRampImage() -> CGImage? {
        let W = 1
        let H = 64
        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            // y=0 (topo) = t=1.0 ; y=H-1 (base) = t=0.0
            let t = 1.0 - Double(y) / Double(H - 1)
            let (r, g, b, a) = magmaRGB(t: t)
            let idx = y * W * 4
            pixels[idx]     = r
            pixels[idx + 1] = g
            pixels[idx + 2] = b
            pixels[idx + 3] = a
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: W, height: H,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: W * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
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
