import SwiftUI
import Darwin



private struct CardOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}
extension EnvironmentValues {
    var cardOpacity: Double {
        get { self[CardOpacityKey.self] }
        set { self[CardOpacityKey.self] = newValue }
    }
}

/// Controla `NSWindow.level` — `.floating` faz a janela ficar acima das normais
/// (mas abaixo de menus/dialogs modais). API pública desde Mac OS X 10.0,
/// sem entitlements ou permissões necessárias.
private struct WindowLevelController: NSViewRepresentable {
    let alwaysOnTop: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }
    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}

/// Mantém a NSWindow não-opaca pra que os fundos translúcidos (do tint do
/// windowAlpha e do .opacity nos cards) revelem o desktop em vez da cor de
/// fundo padrão da janela. Não toca em alphaValue — opacidade é controlada
/// puramente em SwiftUI por slider.
private struct WindowAlphaController: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }
    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.alphaValue = 1.0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        if let cv = window.contentView {
            cv.wantsLayer = true
            cv.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

struct DetailWindow: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var servicesStore: ServicesStore
    @ObservedObject var healthScheduler: HealthCheckScheduler
    @AppStorage("windowAlpha") private var windowAlpha: Double = 1.0
    @AppStorage("cardsAlpha")  private var cardsAlpha: Double = 1.0
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false

    private let threeCols: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    private let adaptiveCols = [GridItem(.adaptive(minimum: 300), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Tier 1 — System
                section(L.t("System", "Sistema"), icon: "cpu.fill", color: .blue) {
                    LazyVGrid(columns: threeCols, spacing: 10) {
                        ThermalPowerCard(stats: stats).alignedTop()
                        CPUCard(stats: stats).alignedTop()
                        OverallPerformanceCard(stats: stats).alignedTop()
                    }
                }

                // Tier 2 — Memory & Storage
                section(L.t("Memory & Storage", "Memória & Armazenamento"),
                        icon: "internaldrive.fill", color: .pink) {
                    LazyVGrid(columns: threeCols, spacing: 10) {
                        MemoryCard(stats: stats).alignedTop()
                        DiskCard(stats: stats).alignedTop()
                        VolumeTreeCard(stats: stats).alignedTop()
                    }
                }

                // Tier 3 — Outside Connections
                section(L.t("Outside Connections", "Conexões Externas"),
                        icon: "globe", color: .teal) {
                    LazyVGrid(columns: threeCols, spacing: 10) {
                        NetworkCard(stats: stats).alignedTop()
                        NetworkConnectionsCard(stats: stats).alignedTop()
                        RecentConnectionsCard(stats: stats).alignedTop()
                    }
                }

                // Tier 4 — LLM Stack (só aparece se houver pelo menos 1 serviço configurado)
                if !servicesStore.config.services.isEmpty {
                    section(L.t("LLM Stack", "Stack LLM"), icon: "checkmark.shield.fill", color: schedulerColor,
                            subtitle: schedulerSubtitle) {
                        VStack(spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                StackHealthTable(services: servicesStore.config.services,
                                                 scheduler: healthScheduler)
                                    .frame(maxWidth: .infinity)
                                CallLLMCard(services: servicesStore.config.services)
                                    .frame(maxWidth: .infinity)
                            }
                            HeatmapCard(store: servicesStore, scheduler: healthScheduler)
                        }
                    }
                }

                // Tier 5 — Specialized Hardware
                section(L.t("Specialized Hardware", "Hardware Especializado"),
                        icon: "cable.connector.horizontal", color: .orange) {
                    LazyVGrid(columns: threeCols, spacing: 10) {
                        ArduinoCard(stats: stats).alignedTop()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, minHeight: 360)
        // Window slider = opacidade do TINT de fundo da janela (independente dos cards)
        .background(Color(NSColor.windowBackgroundColor).opacity(windowAlpha))
        .environment(\.cardOpacity, cardsAlpha)
        .background(WindowAlphaController())
        .background(WindowLevelController(alwaysOnTop: alwaysOnTop))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshCountdownGauge(stats: stats)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(SystemStats.availableIntervals, id: \.self) { rate in
                        Button {
                            stats.refreshInterval = rate
                        } label: {
                            if rate == stats.refreshInterval {
                                Label(formatRefreshInterval(rate), systemImage: "checkmark")
                            } else {
                                Text(formatRefreshInterval(rate))
                            }
                        }
                    }
                } label: {
                    Label(formatRefreshInterval(stats.refreshInterval), systemImage: "timer")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .help(L.t("Refresh rate", "Taxa de atualização"))
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $alwaysOnTop) {
                    Label(
                        L.t("Always on Top", "Sempre no Topo"),
                        systemImage: alwaysOnTop ? "pin.fill" : "pin"
                    )
                    .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .help(L.t("Keep window always on top",
                          "Mantém a janela sempre acima das outras"))
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    opacitySliderRow(icon: "macwindow",
                                     value: $windowAlpha,
                                     tooltip: L.t("Window background opacity",
                                                  "Opacidade do fundo da janela"))
                    opacitySliderRow(icon: "square.stack.fill",
                                     value: $cardsAlpha,
                                     tooltip: L.t("Cards opacity",
                                                  "Opacidade dos cards"))
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
            }
        }
    }

    @ViewBuilder
    private func opacitySliderRow(icon: String, value: Binding<Double>, tooltip: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0.1...1.0)
                .frame(width: 120)
                .help(String(format: "%@ %.0f%%", tooltip, value.wrappedValue * 100))
        }
    }

    private func formatRefreshInterval(_ s: Double) -> String {
        if s >= 60 { return String(format: "%.0fm", s / 60) }
        if s < 1 { return String(format: "%.2fs", s).replacingOccurrences(of: "0.", with: ".") }
        return String(format: "%.0fs", s)
    }

    private var schedulerColor: Color {
        healthScheduler.aggregateStatus.color
    }

    private var schedulerSubtitle: String? {
        let s = healthScheduler.summary
        if s.total == 0 {
            return L.t("No services configured — open Configuration (⌘,)",
                       "Nenhum serviço configurado — abra Configuração (⌘,)")
        }
        return "\(s.ok)/\(s.total) \(L.t("healthy", "saudáveis")) · \(healthScheduler.aggregateStatus.rawValue)"
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        icon: String,
        color: Color,
        subtitle: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let trailing = trailing {
                    trailing
                }
            }
            content()
        }
    }
}

// MARK: - Card chrome (uniformizado, compacto)

struct PanelCard<Content: View>: View {
    @Environment(\.cardOpacity) private var cardOpacity
    let icon: String
    let iconColor: Color
    let title: String
    let trailing: String?
    @ViewBuilder var content: () -> Content

    init(icon: String, iconColor: Color, title: String, trailing: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20)
                    .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(cardOpacity)
    }
}

// MARK: - Power & Heat (Térmica & Energia)

private struct ThermalPowerCard: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        let cpu = stats.cpuTempC
        let gpu = stats.gpuTempC
        let cpuColor = tempColor(cpu)
        let gpuColor = tempColor(gpu)
        let headColor = tempColor(max(cpu, gpu))
        let pkg = stats.power.packageMilliwatts
        let title = L.t("Power & Heat", "Térmica & Energia")
        let trailing = cpu > 0
            ? "\(String(format: "%.1f°C", cpu)) · \(formatPower(pkg))"
            : "—"

        let cpuSpan = tempStats(\.celsius)
        let gpuSpan = tempStats(\.gpuC)
        let pkgSpan = powerStats(\.packageMilliwatts)
        let gpuPwSpan = powerStats(\.gpuMilliwatts)
        let pSpan = powerStats(\.pCpuMilliwatts)
        let eSpan = powerStats(\.eCpuMilliwatts)
        let hasGPU = stats.tempHistory.contains { $0.gpuC > 0 }

        return PanelCard(icon: "bolt.fill", iconColor: headColor, title: title, trailing: trailing) {
            VStack(alignment: .leading, spacing: 4) {
                if cpu > 0 || gpu > 0 {
                    tempRow(label: "CPU", value: cpu, color: cpuColor,
                            stats: cpuSpan, fmt: tempFmt)
                    if gpu > 0 {
                        tempRow(label: "GPU", value: gpu, color: gpuColor,
                                stats: gpuSpan, fmt: tempFmt)
                    }
                } else {
                    Text(L.t("No reading — IOHIDEvent sensor unavailable",
                             "Sem leitura — sensor IOHIDEvent indisponível"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if stats.powerAvailable {
                    Divider().padding(.vertical, 1)
                    powerRow("Pkg", stats.power.packageMilliwatts, .yellow, stats: pkgSpan)
                    powerRow("P",   stats.power.pCpuMilliwatts,    .orange, stats: pSpan)
                    powerRow("E",   stats.power.eCpuMilliwatts,    .blue,   stats: eSpan)
                    powerRow("GPU", stats.power.gpuMilliwatts,     .green,  stats: gpuPwSpan)
                    if stats.power.aneMilliwatts > 0 {
                        powerRow("ANE", stats.power.aneMilliwatts, .purple, stats: powerStats(\.aneMilliwatts))
                    }
                    if stats.power.dramMilliwatts > 0 {
                        powerRow("DRAM", stats.power.dramMilliwatts, .pink, stats: powerStats(\.dramMilliwatts))
                    }
                }

                if !stats.tempHistory.isEmpty || !stats.powerHistory.isEmpty {
                    Divider().padding(.vertical, 1)
                    sparklineBlock(
                        title: L.t("Heat", "Térmica"),
                        spark: thermalSpark,
                        legend: hasGPU ? [(.orange, "CPU°"), (.green, "GPU°")]
                                       : [(.orange, "°C")]
                    )
                    sparklineBlock(
                        title: L.t("Power", "Energia"),
                        spark: powerSpark,
                        legend: [(.yellow, "Pkg"), (.green, "GPU"), (.orange, "CPU")]
                    )
                    HStack {
                        Spacer()
                        Text(historySpan(stats.tempHistory.first?.timestamp, stats.tempHistory.last?.timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var thermalSpark: some View {
        let hasGPU = stats.tempHistory.contains { $0.gpuC > 0 }
        return Sparkline(series: hasGPU ? [
            SparkSeries(values: stats.tempHistory.map(\.celsius), color: .orange, label: "CPU°", filled: true),
            SparkSeries(values: stats.tempHistory.map(\.gpuC),    color: .green,  label: "GPU°")
        ] : [
            SparkSeries(values: stats.tempHistory.map(\.celsius), color: .orange, label: "°C", filled: true)
        ])
            .frame(height: 28)
    }

    private var powerSpark: some View {
        Sparkline(series: [
            SparkSeries(values: stats.powerHistory.map(\.packageMilliwatts),
                        color: .yellow, label: "Pkg", filled: true),
            SparkSeries(values: stats.powerHistory.map(\.gpuMilliwatts),
                        color: .green,  label: "GPU"),
            SparkSeries(values: stats.powerHistory.map { $0.pCpuMilliwatts + $0.eCpuMilliwatts },
                        color: .orange, label: "CPU")
        ], minFloor: 1000)
            .frame(height: 28)
    }

    @ViewBuilder
    private func sparklineBlock<S: View>(
        title: String,
        spark: S,
        legend: [(Color, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(0..<legend.count, id: \.self) { i in
                    HStack(spacing: 3) {
                        Circle().fill(legend[i].0).frame(width: 5, height: 5)
                        Text(legend[i].1)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            spark
        }
    }

    /// Linha estilo CPU slot: label + capsule gauge + valor + min/avg/max inline.
    @ViewBuilder
    private func tempRow(
        label: String,
        value: Double,
        color: Color,
        stats: (min: Double, avg: Double, max: Double),
        fmt: (Double) -> String
    ) -> some View {
        gaugeRow(
            label: label,
            color: color,
            fillRatio: max(0, min((value - 30) / 60, 1)),
            currentText: String(format: "%4.1f°", value),
            statsText: stats.max > 0 ? "\(fmt(stats.min))/\(fmt(stats.avg))/\(fmt(stats.max))" : ""
        )
    }

    @ViewBuilder
    private func powerRow(
        _ name: String,
        _ mW: Double,
        _ tint: Color,
        stats: (min: Double, avg: Double, max: Double)
    ) -> some View {
        let scale = max(self.stats.power.packageMilliwatts, 5_000)
        gaugeRow(
            label: name,
            color: tint,
            fillRatio: max(0, min(mW / scale, 1)),
            currentText: formatPower(mW),
            statsText: stats.max > 0 ? formatPowerStats(stats) : ""
        )
    }

    /// Formato unificado por linha: tudo em W se max ≥ 1W, senão tudo em mW.
    private func formatPowerStats(_ s: (min: Double, avg: Double, max: Double)) -> String {
        if s.max >= 1000 {
            return String(format: "%.1f/%.1f/%.1fW", s.min/1000, s.avg/1000, s.max/1000)
        }
        return String(format: "%.0f/%.0f/%.0fmW", s.min, s.avg, s.max)
    }

    @ViewBuilder
    private func gaugeRow(
        label: String,
        color: Color,
        fillRatio: Double,
        currentText: String,
        statsText: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 28, alignment: .leading)
                .foregroundStyle(color)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(fillRatio))
                }
            }
            .frame(height: 5)
            Text(currentText)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
            Text(statsText)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(height: 11)
    }

    private func tempFmt(_ t: Double) -> String { String(format: "%.0f°", t) }

    private func tempColor(_ t: Double) -> Color {
        switch t {
        case ..<55: return .green
        case ..<70: return .yellow
        case ..<85: return .orange
        default: return .red
        }
    }

    private func tempStats(_ key: KeyPath<TempHistoryPoint, Double>) -> (min: Double, avg: Double, max: Double) {
        let vs = stats.tempHistory.map { $0[keyPath: key] }.filter { $0 > 0 }
        guard !vs.isEmpty else { return (0, 0, 0) }
        return (vs.min() ?? 0, vs.reduce(0, +) / Double(vs.count), vs.max() ?? 0)
    }

    private func powerStats(_ key: KeyPath<PowerHistoryPoint, Double>) -> (min: Double, avg: Double, max: Double) {
        let vs = stats.powerHistory.map { $0[keyPath: key] }
        guard !vs.isEmpty else { return (0, 0, 0) }
        return (vs.min() ?? 0, vs.reduce(0, +) / Double(vs.count), vs.max() ?? 0)
    }
}

private func formatPowerCompact(_ mW: Double) -> String {
    if mW >= 1000 { return String(format: "%.1fW", mW / 1000) }
    return String(format: "%.0fmW", mW)
}

private struct FanInline: View {
    @ObservedObject var controller: FanController

    var body: some View {
        let on = controller.fanShouldBeOn
        let icon = on ? "fan.fill" : "fan"
        let color: Color = on ? .cyan : .secondary
        let mode = controller.store.config.mode.rawValue
        let setp = controller.store.config.setpointC
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
            Text(on ? "FAN ON" : "FAN OFF")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text("·")
                .foregroundStyle(.tertiary)
                .font(.caption2)
            Text(String(format: "duty %.0f%%", controller.currentDutyPct))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
                .font(.caption2)
            Text("\(mode) sp=\(Int(setp))°")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - CPU

private struct CPUCard: View {
    @ObservedObject var stats: SystemStats

    // Maior config Apple Silicon conhecida (M3 Ultra). Layout fixo desse tamanho —
    // núcleos fora do real ficam cinza estáticos.
    private static let MAX_P = 24
    private static let MAX_E = 8
    private static let P_ROWS = MAX_P / 2  // 12
    private static let E_ROWS = MAX_E / 2  // 4

    private static let chipShort: String = {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let full = String(cString: buf)
        if let r = full.range(of: #"M\d+(?: (?:Pro|Max|Ultra))?"#, options: .regularExpression) {
            return String(full[r])
        }
        return full
    }()

    var body: some View {
        let titleSuffix = Self.chipShort.isEmpty ? "" : " (\(Self.chipShort))"
        return PanelCard(
            icon: "cpu",
            iconColor: .orange,
            title: "CPU\(titleSuffix)",
            trailing: String(format: "%.1f%% · %dP+%dE", stats.cpuAverage, stats.pCoreCount, stats.eCoreCount)
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<Self.P_ROWS, id: \.self) { row in
                    HStack(spacing: 8) {
                        slot(coreIdx: row,                kind: .p)
                        slot(coreIdx: row + Self.P_ROWS,  kind: .p)
                    }
                }
                Divider().padding(.vertical, 1)
                ForEach(0..<Self.E_ROWS, id: \.self) { row in
                    HStack(spacing: 8) {
                        slot(coreIdx: row,                kind: .e)
                        slot(coreIdx: row + Self.E_ROWS,  kind: .e)
                    }
                }
            }
        }
    }

    private enum CoreKind { case p, e }

    @ViewBuilder
    private func slot(coreIdx: Int, kind: CoreKind) -> some View {
        let realCount = (kind == .p) ? stats.pCoreCount : stats.eCoreCount
        let exists = coreIdx < realCount
        let perCoreIdx = (kind == .p) ? coreIdx : stats.pCoreCount + coreIdx
        let val = (exists && perCoreIdx < stats.perCoreCPU.count) ? stats.perCoreCPU[perCoreIdx] : 0
        let activeColor: Color = (kind == .p) ? .orange : .blue
        let inactive = Color.primary.opacity(0.18)

        HStack(spacing: 5) {
            Text("\(kind == .p ? "P" : "E")\(coreIdx)")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 24, alignment: .leading)
                .foregroundStyle(exists ? activeColor : inactive)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if exists {
                        Capsule()
                            .fill(activeColor)
                            .frame(width: geo.size.width * CGFloat(max(0, min(val, 100)) / 100))
                    }
                }
            }
            .frame(height: 5)
            Text(exists ? String(format: "%3.0f%%", val) : "—")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(exists ? .primary : inactive)
                .monospacedDigit()
        }
        .frame(height: 11)
    }
}

private func formatPower(_ mW: Double) -> String {
    if mW < 1 { return "—" }
    if mW < 1000 { return String(format: "%4.0f mW", mW) }
    return String(format: "%4.2f W", mW / 1000)
}

// MARK: - GPU

private struct OverallPerformanceCard: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        let cpu = stats.cpuAverage
        let gpu = stats.gpuUtilPercent ?? 0
        let mem = stats.memory.pressureUsedRatio * 100
        let busy = (cpu + gpu + mem) / 3
        let title = L.t("Overall Performance", "Desempenho Geral")
        let trailing = formatTrailing(busy: busy, info: stats.systemInfo)

        let cpuSpan = histStats(\.cpuPct)
        let gpuSpan = histStats(\.gpuPct)
        let memSpan = histStats(\.memPct)

        return PanelCard(icon: "speedometer", iconColor: tintFor(busy), title: title, trailing: trailing) {
            VStack(alignment: .leading, spacing: 4) {
                gaugeRow(label: "CPU", color: .orange, value: cpu, stats: cpuSpan)
                gaugeRow(label: "GPU", color: .green,  value: gpu, stats: gpuSpan)
                gaugeRow(label: "MEM", color: .pink,   value: mem, stats: memSpan)

                if !stats.overallHistory.isEmpty {
                    Divider().padding(.vertical, 1)
                    HStack(spacing: 6) {
                        Text(L.t("Load", "Carga"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        legendDot(.cyan,   "Busy")
                        legendDot(.orange, "CPU")
                        legendDot(.green,  "GPU")
                        legendDot(.pink,   "MEM")
                        Spacer()
                    }
                    Sparkline(series: [
                        SparkSeries(values: stats.overallHistory.map(\.busyPct), color: .cyan,   label: "Busy", filled: true),
                        SparkSeries(values: stats.overallHistory.map(\.cpuPct),  color: .orange, label: "CPU"),
                        SparkSeries(values: stats.overallHistory.map(\.gpuPct),  color: .green,  label: "GPU"),
                        SparkSeries(values: stats.overallHistory.map(\.memPct),  color: .pink,   label: "MEM")
                    ], maxScale: 100)
                        .frame(height: 58)

                    HStack {
                        Text("0–100%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(historySpan(stats.overallHistory.first?.timestamp, stats.overallHistory.last?.timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider().padding(.vertical, 1)
                systemInfoFooter(stats.systemInfo)
            }
        }
    }

    @ViewBuilder
    private func systemInfoFooter(_ info: SystemInfoSample) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            // Linha 1: Load avg + Process count
            GridRow {
                infoCell(
                    label: L.t("Load", "Carga"),
                    value: String(format: "%.2f / %.2f / %.2f", info.loadAvg1, info.loadAvg5, info.loadAvg15)
                )
                infoCell(
                    label: L.t("Procs", "Procs"),
                    value: "\(info.processCount)"
                )
            }
            // Linha 2: Uptime + Idle
            GridRow {
                infoCell(
                    label: L.t("Up", "Up"),
                    value: formatUptime(info.uptimeSec)
                )
                infoCell(
                    label: L.t("Idle", "Ocioso"),
                    value: formatDuration(info.userIdleSec)
                )
            }
            // Linha 3: Thermal (full-width)
            GridRow {
                HStack(spacing: 4) {
                    Text(L.t("Thermal", "Térmica"))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(thermalColor(info.thermalState))
                        .frame(width: 6, height: 6)
                    Text(thermalLabel(info.thermalState))
                        .foregroundStyle(thermalColor(info.thermalState))
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .gridCellColumns(2)
            }
            // Linha 4 opcional: Swap (só se há uso)
            if info.swapUsedBytes > 0 {
                GridRow {
                    HStack(spacing: 4) {
                        Text("Swap").foregroundStyle(.secondary)
                        Text("\(formatBytes(info.swapUsedBytes)) / \(formatBytes(info.swapTotalBytes))")
                            .foregroundStyle(info.swapUsedBytes > 100_000_000 ? .orange : .secondary)
                            .monospacedDigit()
                        Spacer()
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .gridCellColumns(2)
                }
            }
        }
    }

    /// `35% busy · AC` ou `35% busy · BA 78%` ou `35% busy · BA 78% · 4h`
    private func formatTrailing(busy: Double, info: SystemInfoSample) -> String {
        let busyStr = String(format: "%.0f%% busy", busy)
        if let pct = info.batteryPercent {
            if info.onAC {
                return "\(busyStr) · AC \(Int(pct))%"
            } else {
                let label = String(format: "BA %.0f%%", pct)
                if let tr = info.batteryTimeRemainingMin, tr > 0 {
                    let h = tr / 60, m = tr % 60
                    let timeStr = h > 0 ? "\(h)h\(m)min" : "\(m)min"
                    return "\(busyStr) · \(label) · \(timeStr)"
                }
                return "\(busyStr) · \(label)"
            }
        }
        return "\(busyStr) · AC"
    }

    @ViewBuilder
    private func infoCell(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary).monospacedDigit()
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private func thermalColor(_ s: ProcessInfo.ThermalState) -> Color {
        switch s {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private func topColor(_ pct: Double) -> Color {
        switch pct {
        case ..<30: return .secondary
        case ..<60: return .yellow
        case ..<90: return .orange
        default:    return .red
        }
    }

    private func formatDuration(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)min" }
        return "\(s / 3600)h \((s % 3600) / 60)min"
    }

    private func formatUptime(_ sec: Double) -> String {
        let s = Int(sec)
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)min" }
        return "\(mins)min"
    }

    private func gaugeRow(
        label: String,
        color: Color,
        value: Double,
        stats: (min: Double, avg: Double, max: Double)
    ) -> some View {
        let statsText = stats.max > 0
            ? String(format: "%.0f/%.0f/%.0f%%", stats.min, stats.avg, stats.max)
            : ""
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 28, alignment: .leading)
                .foregroundStyle(color)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(value, 100)) / 100))
                }
            }
            .frame(height: 5)
            Text(String(format: "%3.0f%%", value))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
            Text(statsText)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 88, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(height: 11)
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tintFor(_ pct: Double) -> Color {
        switch pct {
        case ..<40: return .green
        case ..<70: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    private func histStats(_ key: KeyPath<OverallHistoryPoint, Double>) -> (min: Double, avg: Double, max: Double) {
        let vs = stats.overallHistory.map { $0[keyPath: key] }
        guard !vs.isEmpty else { return (0, 0, 0) }
        return (vs.min() ?? 0, vs.reduce(0, +) / Double(vs.count), vs.max() ?? 0)
    }
}

// MARK: - Memory

private struct MemoryCard: View {
    @ObservedObject var stats: SystemStats

    /// Min: 5 processos + cabeçalho + grid → ~280pt. Acima disso a row do
    /// LazyVGrid pode crescer (geralmente Volumes/Storage Tree são mais altos)
    /// e o Memory cresce junto mostrando mais processos.
    private static let minIntrinsicHeight: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            cardBody(availableHeight: geo.size.height)
        }
        .frame(minHeight: Self.minIntrinsicHeight)
    }

    private func computeMaxProcs(forHeight h: CGFloat) -> Int {
        // Espaço fixo: padding (20) + header (32) + progressView (14)
        //              + grid 3 linhas (~50) + divider (8) + título "Top by RSS" (16) ≈ 140
        // Por linha de processo: ~17pt (linha 14pt + spacing 3pt)
        let fixed: CGFloat = 140
        let perRow: CGFloat = 17
        let n = Int(max(0, (h - fixed) / perRow))
        return min(max(n, 5), 30)
    }

    @ViewBuilder
    private func cardBody(availableHeight: CGFloat) -> some View {
        let n = computeMaxProcs(forHeight: availableHeight)
        let tops = Array(stats.systemInfo.topMemProcesses.prefix(n))
        let maxRSS = tops.first?.rssBytes ?? 1
        let swapUsed = stats.systemInfo.swapUsedBytes

        PanelCard(
            icon: "memorychip.fill",
            iconColor: .pink,
            title: L.t("Memory", "Memória"),
            trailing: String(format: "%.0f%%", stats.memory.pressureUsedRatio * 100)
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: max(0, min(stats.memory.pressureUsedRatio, 1)), total: 1)
                    .tint(memTint(stats.memory.pressureUsedRatio))

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow {
                        Text("Used").foregroundStyle(.secondary)
                        Text(formatBytes(stats.memory.usedBytes)).monospacedDigit()
                        Text("Wired").foregroundStyle(.secondary)
                        Text(formatBytes(stats.memory.wiredBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("Total").foregroundStyle(.secondary)
                        Text(formatBytes(stats.memory.totalBytes)).monospacedDigit()
                        Text("Comp").foregroundStyle(.secondary)
                        Text(formatBytes(stats.memory.compressedBytes)).monospacedDigit()
                    }
                    GridRow {
                        Text("Swap").foregroundStyle(.secondary)
                        Text(swapUsed > 0 ? formatBytes(swapUsed) : "—")
                            .monospacedDigit()
                            .foregroundStyle(swapUsed > 0 ? .orange : .secondary)
                        Text("Procs").foregroundStyle(.secondary)
                        Text("\(stats.systemInfo.processCount)").monospacedDigit()
                    }
                }
                .font(.caption2)

                if !tops.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text(L.t("Top by RSS", "Maiores em RAM"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tops.enumerated()), id: \.offset) { _, p in
                            topRow(name: p.name, rss: p.rssBytes, maxRSS: maxRSS)
                        }
                    }
                } else {
                    Text(L.t("Sampling top processes…", "Coletando processos…"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func topRow(name: String, rss: UInt64, maxRSS: UInt64) -> some View {
        let ratio = maxRSS > 0 ? Double(rss) / Double(maxRSS) : 0
        return HStack(spacing: 6) {
            Text(name)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 5)
                    Capsule()
                        .fill(Color.pink.opacity(0.85))
                        .frame(width: max(2, geo.size.width * ratio), height: 5)
                }
            }
            .frame(height: 5)
            Text(formatBytes(rss))
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func memTint(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.6: return .green
        case ..<0.85: return .yellow
        default: return .red
        }
    }
}

// MARK: - Network

private struct NetworkCard: View {
    @ObservedObject var stats: SystemStats
    @State private var showInactive: Bool = false

    var body: some View {
        let activeIfaces = stats.interfaces.filter { $0.isRunning && $0.ipv4 != nil }
        let inactiveIfaces = stats.interfaces.filter { !($0.isRunning && $0.ipv4 != nil) }
        let peakRx = stats.netHistory.map(\.rxBytesPerSec).max() ?? 0
        let peakTx = stats.netHistory.map(\.txBytesPerSec).max() ?? 0

        return PanelCard(
            icon: "network",
            iconColor: .teal,
            title: L.t("Network", "Rede"),
            trailing: "\(activeIfaces.count) active"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Lista de interfaces ativas
                if activeIfaces.isEmpty {
                    Text(L.t("No active interface", "Nenhuma interface ativa"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(activeIfaces) { iface in
                            interfaceRow(iface)
                        }
                    }
                }

                // Sparkline + rates totais (todas interfaces)
                Divider().padding(.vertical, 2)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        Text("↓").font(.caption2).foregroundStyle(.cyan)
                        Text(formatRate(stats.net.rxBytesPerSec))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.cyan)
                            .monospacedDigit()
                        Text("peak \(formatRate(peakRx))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    GridRow {
                        Text("↑").font(.caption2).foregroundStyle(.green)
                        Text(formatRate(stats.net.txBytesPerSec))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                        Text("peak \(formatRate(peakTx))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                NetSparkline(samples: stats.netHistory)
                    .frame(height: 24)

                // Toggle pra mostrar inativas
                if !inactiveIfaces.isEmpty {
                    Divider().padding(.vertical, 2)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInactive.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showInactive ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(showInactive
                                 ? L.t("Hide inactive (\(inactiveIfaces.count))", "Esconder inativas (\(inactiveIfaces.count))")
                                 : L.t("Show inactive (\(inactiveIfaces.count))", "Ver inativas (\(inactiveIfaces.count))"))
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if showInactive {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(inactiveIfaces) { iface in
                                inactiveRow(iface)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func interfaceRow(_ i: InterfaceInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: i.type.iconName)
                    .font(.caption2)
                    .foregroundStyle(.teal)
                    .frame(width: 14)
                Text(i.displayName)
                    .font(.caption.weight(.semibold))
                Text("(\(i.bsdName))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if i.isPrimary {
                    Text("primary")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green.opacity(0.15))
                        )
                }
                Spacer()
                if let ip = i.ipv4 {
                    Text(ip)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            // Detalhes específicos
            if i.type == .wifi {
                wifiDetails(i)
            } else if i.rxBytesPerSec > 0 || i.txBytesPerSec > 0 {
                Text("↓ \(formatRate(i.rxBytesPerSec))  ↑ \(formatRate(i.txBytesPerSec))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private func wifiDetails(_ i: InterfaceInfo) -> some View {
        HStack(spacing: 6) {
            if let ssid = i.ssid, !ssid.isEmpty {
                Text(ssid)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
            } else {
                Text(L.t("(SSID hidden — Location permission needed)",
                         "(SSID oculto — permissão Location necessária)"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let band = i.wifiBand, let ch = i.wifiChannel {
                Text("ch \(ch) (\(band))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let rssi = i.rssi {
                Text("\(rssi) dBm")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(rssiColor(rssi))
            }
            if let tx = i.wifiTxRateMbps {
                Text("\(Int(tx)) Mbps")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private func inactiveRow(_ i: InterfaceInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: i.type.iconName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(i.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("(\(i.bsdName))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(i.isUp ? "no IP" : "down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-80): return .red
        case ..<(-67): return .orange
        case ..<(-50): return .yellow
        default:       return .green
        }
    }
}

private struct NetSparkline: View {
    let samples: [NetHistoryPoint]

    var body: some View {
        Sparkline(series: [
            SparkSeries(values: samples.map(\.rxBytesPerSec), color: .cyan, label: "RX"),
            SparkSeries(values: samples.map(\.txBytesPerSec), color: .green, label: "TX")
        ], minFloor: 1024)
    }
}

// MARK: - Disk

private struct DiskCard: View {
    @ObservedObject var stats: SystemStats
    @State private var expandedSections: Set<String> = []

    var body: some View {
        let sections = sectioned(stats.volumes)
        return PanelCard(
            icon: "internaldrive.fill",
            iconColor: .indigo,
            title: "Volumes",
            trailing: "\(stats.volumes.count)"
        ) {
            if stats.volumes.isEmpty {
                Text(L.t("No volume mounted", "Nenhum volume montado"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections, id: \.id) { section in
                        sectionView(section)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: TypeSection) -> some View {
        let isExpanded = expandedSections.contains(section.id)
        let space = aggregateSpace(volumes: section.allVolumes)
        let usedRatio = space.total > 0 ? Double(space.used) / Double(space.total) : 0
        let aggHistory = aggregateHistory(devices: section.allDevices)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded { expandedSections.remove(section.id) }
                    else { expandedSections.insert(section.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(section.color)
                        .frame(width: 10)
                    Image(systemName: section.icon)
                        .font(.caption2)
                        .foregroundStyle(section.color)
                    Text("Type: \(section.fsShort) — \(section.fsLong)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(section.color)
                        .lineLimit(1)
                    Spacer()
                    Text(section.locationLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Group {
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.groups, id: \.device) { g in
                        deviceGroupView(device: g.device, volumes: g.volumes)
                    }
                }
            } else {
                // Collapsed: agregado de espaço + sparkline somada
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView(value: max(0, min(usedRatio, 1)), total: 1)
                            .tint(diskTint(usedRatio))
                        Text("\(formatBytes(space.used)) / \(formatBytes(space.total))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(String(format: "%.0f%%", usedRatio * 100))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !aggHistory.isEmpty {
                        Sparkline(series: [
                            SparkSeries(values: aggHistory.map(\.readBytesPerSec), color: .cyan, label: "R"),
                            SparkSeries(values: aggHistory.map(\.writeBytesPerSec), color: .green, label: "W")
                        ], minFloor: 1024)
                            .frame(height: 18)
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
            }
            .padding(.leading, 14)
        }
    }

    private func aggregateSpace(volumes: [VolumeInfo]) -> (total: UInt64, used: UInt64) {
        let byDevice = Dictionary(grouping: volumes, by: { $0.parentDevice })
        var total: UInt64 = 0
        var used: UInt64 = 0
        for (_, vols) in byDevice {
            // APFS: volumes irmãos compartilham container → total via max evita double-count
            let dTotal = vols.map { UInt64(max(0, $0.totalBytes)) }.max() ?? 0
            let dUsed = vols.reduce(UInt64(0)) { acc, v in
                acc + UInt64(max(0, v.totalBytes - v.availableBytes))
            }
            total += dTotal
            used += dUsed
        }
        return (total, used)
    }

    private func aggregateHistory(devices: [String]) -> [DiskIOHistoryPoint] {
        let histories = devices.compactMap { stats.diskIOHistory[$0] }
        guard !histories.isEmpty else { return [] }
        let len = histories.map(\.count).min() ?? 0
        guard len > 0 else { return [] }
        var result: [DiskIOHistoryPoint] = []
        for i in 0..<len {
            var r = 0.0, w = 0.0
            var ts = histories[0][i].timestamp
            for h in histories {
                r += h[i].readBytesPerSec
                w += h[i].writeBytesPerSec
                ts = h[i].timestamp
            }
            result.append(DiskIOHistoryPoint(timestamp: ts, readBytesPerSec: r, writeBytesPerSec: w))
        }
        return result
    }

    @ViewBuilder
    private func deviceGroupView(device: String, volumes: [VolumeInfo]) -> some View {
        let rate = stats.diskIORates[device]
        let history = stats.diskIOHistory[device] ?? []
        VStack(alignment: .leading, spacing: 4) {
            // 1. Volumes (com BSD + interconnect inline)
            ForEach(volumes) { v in
                volumeRow(v)
            }
            // 2. Sparkline com rates overlay no canto superior direito
            if !history.isEmpty {
                Sparkline(series: [
                    SparkSeries(values: history.map(\.readBytesPerSec), color: .cyan, label: "R"),
                    SparkSeries(values: history.map(\.writeBytesPerSec), color: .green, label: "W")
                ], minFloor: 1024)
                    .frame(height: 18)
                    .overlay(alignment: .topTrailing) {
                        if let r = rate {
                            Text("R \(formatRate(r.readBytesPerSec)) · W \(formatRate(r.writeBytesPerSec))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .padding(.trailing, 2)
                                .padding(.top, -2)
                        }
                    }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func volumeRow(_ v: VolumeInfo) -> some View {
        let usedRatio = 1 - v.freeRatio
        let usedBytes = UInt64(max(0, v.totalBytes - v.availableBytes))
        let dev = v.parentDevice
        let interconnect = stats.deviceInterconnects[dev]
        let metaSuffix: String = {
            var parts: [String] = [dev]
            if let proto = interconnect, !proto.isEmpty { parts.append(proto) }
            if !v.fsType.isEmpty, v.fsType != "?" { parts.append(v.fsType) }
            return " (\(parts.joined(separator: ", ")))"
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(v.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(metaSuffix)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                ProgressView(value: max(0, min(usedRatio, 1)), total: 1)
                    .tint(diskTint(usedRatio))
                Text("\(formatBytes(usedBytes)) / \(formatBytes(UInt64(v.totalBytes)))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private struct DeviceGroup {
        let device: String
        let volumes: [VolumeInfo]
    }

    private struct TypeSection {
        let id: String              // "Internal-APFS", "External-exFAT", etc
        let location: DeviceClass
        let fsShort: String
        let fsLong: String
        let icon: String
        let color: Color
        let locationLabel: String   // "Internal" / "External" / "Network"
        let groups: [DeviceGroup]
        var allVolumes: [VolumeInfo] { groups.flatMap(\.volumes) }
        var allDevices: [String]    { groups.map(\.device) }
    }

    private static let fsLongName: [String: String] = [
        "APFS":  "Apple File System",
        "HFS+":  "Hierarchical File System Plus",
        "exFAT": "Extensible File Allocation Table",
        "FAT32": "File Allocation Table 32-bit",
        "FAT":   "File Allocation Table",
        "NTFS":  "New Technology File System",
        "SMB":   "Server Message Block",
        "AFP":   "Apple Filing Protocol",
        "NFS":   "Network File System"
    ]

    private func sectioned(_ vols: [VolumeInfo]) -> [TypeSection] {
        // Agrupa por (location, fsType). Cada combinação vira uma seção.
        struct Key: Hashable { let loc: DeviceClass; let fs: String }
        var buckets: [Key: [String: [VolumeInfo]]] = [:]

        for v in vols {
            let dev = v.parentDevice
            let loc = classify(device: dev)
            let fs = v.fsType.isEmpty ? "?" : v.fsType
            let k = Key(loc: loc, fs: fs)
            buckets[k, default: [:]][dev, default: []].append(v)
        }

        func locOrder(_ l: DeviceClass) -> Int {
            switch l {
            case .internalDisk: return 0
            case .external: return 1
            case .network: return 2
            }
        }
        func locVisuals(_ l: DeviceClass) -> (icon: String, color: Color, label: String) {
            switch l {
            case .internalDisk: return ("internaldrive.fill", .indigo, L.t("Internal", "Interno"))
            case .external:     return ("externaldrive.fill", .orange, L.t("External", "Externo"))
            case .network:      return ("network",            .teal,   L.t("Network", "Rede"))
            }
        }

        return buckets
            .map { (key, devDict) -> TypeSection in
                let groups = devDict
                    .map { DeviceGroup(device: $0.key, volumes: $0.value) }
                    .sorted { $0.device < $1.device }
                let visuals = locVisuals(key.loc)
                let long = Self.fsLongName[key.fs] ?? key.fs
                return TypeSection(
                    id: "\(key.loc.rawValue)-\(key.fs)",
                    location: key.loc,
                    fsShort: key.fs,
                    fsLong: long,
                    icon: visuals.icon,
                    color: visuals.color,
                    locationLabel: visuals.label,
                    groups: groups
                )
            }
            .sorted { lhs, rhs in
                let lOrd = locOrder(lhs.location)
                let rOrd = locOrder(rhs.location)
                if lOrd != rOrd { return lOrd < rOrd }
                return lhs.fsShort < rhs.fsShort
            }
    }

    private func classify(device: String) -> DeviceClass {
        if !device.hasPrefix("disk") { return .network }
        return stats.deviceClasses[device] ?? .internalDisk
    }

    private func diskTint(_ used: Double) -> Color {
        switch used {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }
}

// MARK: - Arduino (3 estados: idle / ok / problema)

private struct ArduinoCard: View {
    @ObservedObject var stats: SystemStats
    @State private var nowTick: Date = Date()
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let bridge = stats.arduino
        let (color, label, iconName) = visual(for: bridge.health)
        let trailing: String? = {
            switch bridge.health {
            case .idle: return nil
            case .ok, .degraded, .error:
                return String(format: "%.1f%% ACK", bridge.ackSuccessPercent)
            }
        }()
        return PanelCard(icon: iconName, iconColor: color, title: "Arduino", trailing: trailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.6), radius: bridge.isCommunicating ? 3 : 0)
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Spacer()
                }

                switch bridge.health {
                case .idle:
                    Text("Modo monitor — sem Arduino conectado neste Mac. O daemon `hatarim_daemon.py` não está rodando.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .ok, .degraded, .error:
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        GridRow {
                            Text("Porta").foregroundStyle(.secondary)
                            Text(bridge.portPath ?? "—")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        GridRow {
                            Text("Daemon").foregroundStyle(.secondary)
                            Text("PID \(bridge.daemonPID) · up \(uptime(bridge.daemonUptimeSec))")
                        }
                        GridRow {
                            Text("ACK").foregroundStyle(.secondary)
                            Text("\(bridge.ackOkCount) ok / \(bridge.ackFailCount) fail")
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("Backlog").foregroundStyle(.secondary)
                            Text("\(bridge.backlogFiles) arquivos · falhas \(bridge.consecutiveFails)")
                                .monospacedDigit()
                        }
                        GridRow {
                            Text(L.t("Last", "Última")).foregroundStyle(.secondary)
                            Text("\(bridge.lastPayload.isEmpty ? "—" : bridge.lastPayload) · \(lastAckLabel(bridge.lastAckTime, now: nowTick))")
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))

                    if let fail = bridge.lastFailureReason, bridge.health != .ok {
                        Text(fail)
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.85))
                            .lineLimit(2)
                    }
                }

                if let fc = stats.fanController {
                    Divider().padding(.vertical, 1)
                    FanInline(controller: fc)
                }
            }
        }
        .onReceive(tickTimer) { nowTick = $0 }
    }

    private func visual(for h: ArduinoBridge.Health) -> (Color, String, String) {
        switch h {
        case .idle:     return (.gray, "Modo monitor", "circle.dotted")
        case .ok:       return (.green, "Conectado · ACK fluindo", "circle.fill")
        case .degraded: return (.yellow, "Daemon degradado", "exclamationmark.triangle.fill")
        case .error:    return (.red, "Daemon sem porta serial", "xmark.octagon.fill")
        }
    }

    private func lastAckLabel(_ t: Date?, now: Date) -> String {
        guard let t else { return "nunca" }
        let dt = now.timeIntervalSince(t)
        if dt < 1 { return "agora" }
        if dt < 60 { return L.t("\(Int(dt))s ago", "há \(Int(dt))s") }
        return L.t("\(Int(dt / 60))min ago", "há \(Int(dt / 60))min")
    }

    private func uptime(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}

// MARK: - Refresh

private struct RefreshCard: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        PanelCard(icon: "timer", iconColor: .gray, title: L.t("Refresh Rate", "Taxa de atualização"),
                  trailing: formatInterval(stats.refreshInterval)) {
            Picker("", selection: Binding(
                get: { stats.refreshInterval },
                set: { stats.refreshInterval = $0 }
            )) {
                ForEach(SystemStats.availableIntervals, id: \.self) { rate in
                    Text(formatInterval(rate)).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func formatInterval(_ s: Double) -> String {
        s < 1 ? String(format: "%.1fs", s) : String(format: "%.0fs", s)
    }
}

// MARK: - Layout helpers

private extension View {
    /// Em LazyVGrid, força a célula a alinhar o conteúdo no topo da row
    /// (default centraliza verticalmente, criando faixas vazias acima/abaixo de cards menores).
    func alignedTop() -> some View {
        VStack(spacing: 0) {
            self
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared formatters

private func formatBytes(_ b: UInt64) -> String {
    let bcf = ByteCountFormatter()
    bcf.allowedUnits = [.useGB, .useMB, .useKB]
    bcf.countStyle = .memory
    return bcf.string(fromByteCount: Int64(b))
}

private func formatRate(_ bps: Double) -> String {
    guard bps.isFinite, bps > 1 else { return "0 B/s" }
    let bcf = ByteCountFormatter()
    bcf.allowedUnits = [.useKB, .useMB, .useGB]
    bcf.countStyle = .binary
    return bcf.string(fromByteCount: Int64(bps)) + "/s"
}

private struct RefreshCountdownGauge: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let elapsed = context.date.timeIntervalSince(stats.lastTickTime)
            let interval = stats.refreshInterval
            // Retrai: começa cheio e vai esvaziando até o próximo tick
            let remaining = max(0, interval - elapsed)
            let progress = interval > 0 ? min(max(remaining / interval, 0), 1) : 0
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .frame(width: 42, alignment: .center)   // container 3x da gauge, gauge centralizado
            .help(String(format: "%.1fs", remaining))
        }
    }
}

private func historySpan(_ first: Date?, _ last: Date?) -> String {
    guard let first, let last else { return "—" }
    let span = Int(last.timeIntervalSince(first))
    if span < 60 { return "\(span)s" }
    return "\(span / 60)m\(span % 60)s"
}

// MARK: - Volume Tree

private struct VolumeTreeCard: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        PanelCard(
            icon: "point.3.connected.trianglepath.dotted",
            iconColor: .purple,
            title: L.t("Storage Tree", "Árvore de Armazenamento"),
            trailing: "\(stats.volumes.count)"
        ) {
            if stats.storageTree.isEmpty {
                Text(L.t("Building tree…", "Montando árvore…"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(stats.storageTree.enumerated()), id: \.element.id) { idx, node in
                        TreeNodeView(
                            node: node,
                            isLast: idx == stats.storageTree.count - 1,
                            ancestorsContinue: []
                        )
                    }
                }
            }
        }
    }
}

private struct TreeNodeView: View {
    let node: StorageTreeNode
    let isLast: Bool
    let ancestorsContinue: [Bool]   // pra cada ancestral: tinha mais irmãos depois?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<ancestorsContinue.count, id: \.self) { i in
                    Text(ancestorsContinue[i] ? "│ " : "  ")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if !ancestorsContinue.isEmpty || isLast || !node.children.isEmpty {
                    Text(branchPrefix)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: iconFor(node.kind))
                    .font(.caption2)
                    .foregroundStyle(colorFor(node.kind))
                    .frame(width: 14)
                Text(node.name)
                    .font(.caption.weight(node.kind == .controller || node.kind == .host ? .semibold : .regular))
                    .lineLimit(1)
                if !node.detail.isEmpty {
                    Text(" · \(node.detail)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let port = node.portNumber, node.kind != .controller, node.kind != .host {
                    Text("P\(port)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                if let bytes = node.totalBytes, bytes > 0 {
                    Text(formatBytes(UInt64(bytes)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(Array(node.children.enumerated()), id: \.element.id) { idx, child in
                TreeNodeView(
                    node: child,
                    isLast: idx == node.children.count - 1,
                    ancestorsContinue: ancestorsContinue + [!isLast]
                )
            }
        }
    }

    private var branchPrefix: String {
        if ancestorsContinue.isEmpty { return "" }   // root level
        return isLast ? "└─ " : "├─ "
    }

    private func iconFor(_ kind: StorageTreeNode.Kind) -> String {
        switch kind {
        case .host:       return "macmini.fill"
        case .controller: return "cpu"
        case .hub:        return "personalhotspot"
        case .storage:    return "internaldrive"
        }
    }

    private func colorFor(_ kind: StorageTreeNode.Kind) -> Color {
        switch kind {
        case .host:       return .pink
        case .controller: return .purple
        case .hub:        return .orange
        case .storage:    return .indigo
        }
    }
}


// MARK: - Network Connections (listening + outbound)

private struct NetworkConnectionsCard: View {
    @ObservedObject var stats: SystemStats
    @AppStorage("showLocalConns") private var showLocal: Bool = false
    @State private var showAllListening: Bool = false
    @State private var showAllOutbound: Bool = false
    @State private var hoveredRowId: String? = nil
    @State private var killCandidate: ListeningPort? = nil
    @State private var killingPids: Set<Int> = []
    @State private var killToast: (message: String, isError: Bool)? = nil
    @State private var deniedCommand: String? = nil

    private static let initialListeningCount = 8
    private static let initialOutboundCount = 8

    var body: some View {
        let listening = stats.listeningPorts
        let outbound = showLocal
            ? stats.outboundConnections
            : stats.outboundConnections.filter { !NetworkConnectionsCollector.isPrivateOrLocalIP($0.remoteHost) }
        let trailing = "\(listening.count) ⇄ \(outbound.count)"

        return PanelCard(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: .teal,
            title: L.t("Connections", "Conexões"),
            trailing: trailing
        ) {
            VStack(alignment: .leading, spacing: 8) {
                showLocalToggle
                listeningSection(listening)
                Divider().padding(.vertical, 2)
                outboundSection(outbound)
            }
        }
    }

    private var showLocalToggle: some View {
        Toggle(isOn: $showLocal) {
            Text(L.t("Show local addresses (127.x, 192.168.x, 10.x…)",
                     "Mostrar endereços locais (127.x, 192.168.x, 10.x…)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

    @ViewBuilder
    private func listeningSection(_ items: [ListeningPort]) -> some View {
        let visible = showAllListening ? items : Array(items.prefix(Self.initialListeningCount))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(L.t("Listening (services)", "Escutando (serviços)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if items.isEmpty {
                Text(L.t("No listening ports", "Nenhuma porta escutando"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visible) { lp in
                    listeningRow(lp)
                }
                if items.count > Self.initialListeningCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllListening.toggle() }
                    } label: {
                        Text(showAllListening
                             ? L.t("Show fewer", "Mostrar menos")
                             : L.t("+ \(items.count - Self.initialListeningCount) more",
                                   "+ \(items.count - Self.initialListeningCount) mais"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func listeningRow(_ lp: ListeningPort) -> some View {
        let canKill = ProcessKiller.belongsToCurrentUser(lp.pid, processName: lp.process)
        let isKilling = killingPids.contains(lp.pid)
        let isHovered = hoveredRowId == lp.id

        HStack(spacing: 6) {
            Text(lp.process)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 110, alignment: .leading)
                .opacity(isKilling ? 0.5 : 1.0)
            Text(":\(lp.port)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .opacity(isKilling ? 0.5 : 1.0)
            if let svc = lp.serviceName {
                Text(svc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            Spacer()
            if isKilling {
                Text(L.t("stopping…", "parando…"))
                    .font(.caption2.italic())
                    .foregroundStyle(.orange)
            } else {
                Text(lp.bindAddress == "*" ? "all" : lp.bindAddress)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(bindColor(lp.bindAddress))
            }
            if canKill && !isKilling {
                Button { killCandidate = lp } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(isHovered ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(L.t("Kill \(lp.process) (PID \(lp.pid))",
                          "Matar \(lp.process) (PID \(lp.pid))"))
            } else {
                // Reserva mesma largura pra alinhamento das linhas (ícone 12px + spacing)
                Color.clear.frame(width: 14, height: 12)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in hoveredRowId = hovering ? lp.id : nil }
        .confirmationDialog(
            killDialogTitle(killCandidate),
            isPresented: Binding(
                get: { killCandidate != nil },
                set: { if !$0 { killCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: killCandidate
        ) { lp in
            Button(L.t("Kill", "Matar"), role: .destructive) {
                performKill(lp)
                killCandidate = nil
            }
            Button(L.t("Cancel", "Cancelar"), role: .cancel) { killCandidate = nil }
        } message: { lp in
            Text(L.t(
                "PID \(lp.pid) listening on port \(lp.port).\nSends SIGTERM first; escalates to SIGKILL after 5s if still alive.\nUnsaved state may be lost.",
                "PID \(lp.pid) escutando na porta \(lp.port).\nManda SIGTERM primeiro; escala pra SIGKILL após 5s se ainda estiver vivo.\nEstado não salvo pode ser perdido."
            ))
        }
        .overlay(alignment: .topTrailing) {
            if let toast = killToast {
                killToastView(toast)
            }
        }
    }

    private func killDialogTitle(_ lp: ListeningPort?) -> String {
        guard let lp = lp else { return "" }
        return L.t("Kill \(lp.process)?", "Matar \(lp.process)?")
    }

    @ViewBuilder
    private func killToastView(_ toast: (message: String, isError: Bool)) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(toast.message)
                .font(.caption2)
                .foregroundStyle(toast.isError ? .red : .green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.thinMaterial)
                )
            if let cmd = deniedCommand {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    deniedCommand = nil
                    showToast("Copiado", isError: false)
                } label: {
                    Label(L.t("Copy sudo command", "Copiar comando sudo"), systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func performKill(_ lp: ListeningPort) {
        let pid = lp.pid
        _ = withAnimation(.easeInOut(duration: 0.15)) { killingPids.insert(pid) }
        deniedCommand = nil

        let termResult = ProcessKiller.sendTerm(pid)
        switch termResult {
        case .denied:
            killingPids.remove(pid)
            deniedCommand = "sudo kill -9 \(pid)"
            showToast(L.t("Permission denied — try sudo", "Permissão negada — use sudo"), isError: true)
            return
        case .alreadyDead:
            killingPids.remove(pid)
            showToast(L.t("Already dead", "Já estava morto"), isError: false)
            return
        case .error(let msg):
            killingPids.remove(pid)
            showToast("kill: \(msg)", isError: true)
            return
        case .ok:
            break
        }

        // Refresh imediato do collector (não esperar os 2s do tick agendado)
        stats.refreshConnectionsNow()

        // Watchdog: após 5s, se ainda vivo, escala pra SIGKILL
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard killingPids.contains(pid) else { return }
            if ProcessKiller.isAlive(pid) {
                let killResult = ProcessKiller.sendKill(pid)
                if case .ok = killResult {
                    showToast(L.t("Force killed PID \(pid)", "PID \(pid) morto à força"), isError: false)
                } else {
                    showToast(L.t("Could not kill PID \(pid)", "Não consegui matar PID \(pid)"), isError: true)
                }
            } else {
                showToast(L.t("Stopped PID \(pid)", "PID \(pid) parado"), isError: false)
            }
            killingPids.remove(pid)
            stats.refreshConnectionsNow()
        }
    }

    private func showToast(_ msg: String, isError: Bool) {
        killToast = (msg, isError)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if killToast?.message == msg { killToast = nil }
        }
    }

    @ViewBuilder
    private func outboundSection(_ items: [OutboundConnection]) -> some View {
        let visible = showAllOutbound ? items : Array(items.prefix(Self.initialOutboundCount))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "tray.and.arrow.up.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                Text(L.t("Outbound (active calls)", "Saindo (chamadas ativas)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if items.isEmpty {
                Text(L.t("No active outbound connections", "Nenhuma conexão saindo"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visible) { oc in
                    outboundRow(oc)
                }
                if items.count > Self.initialOutboundCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllOutbound.toggle() }
                    } label: {
                        Text(showAllOutbound
                             ? L.t("Show fewer", "Mostrar menos")
                             : L.t("+ \(items.count - Self.initialOutboundCount) more",
                                   "+ \(items.count - Self.initialOutboundCount) mais"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func outboundRow(_ oc: OutboundConnection) -> some View {
        HStack(spacing: 6) {
            Text(oc.process)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 90, alignment: .leading)
            Text("→")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(oc.remoteHost)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(":\(oc.remotePort)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let svc = oc.serviceName {
                Text(svc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            if oc.count > 1 {
                Text("×\(oc.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
        }
    }

    private func bindColor(_ addr: String) -> Color {
        if addr == "*" { return .orange }                           // exposto a tudo
        if addr.hasPrefix("127.") || addr == "::1" { return .green } // só local
        return .yellow                                              // bind específico
    }
}

// MARK: - Recent Connections (histórico de destinos visitados)

private struct RecentConnectionsCard: View {
    @ObservedObject var stats: SystemStats
    @AppStorage("showLocalConns") private var showLocal: Bool = false
    @State private var showAll: Bool = false
    private static let initialCount = 12

    var body: some View {
        let items = showLocal
            ? stats.recentConnections
            : stats.recentConnections.filter { !NetworkConnectionsCollector.isPrivateOrLocalIP($0.remoteHost) }
        let visible = showAll ? items : Array(items.prefix(Self.initialCount))
        let activeCount = items.filter(\.isActive).count
        let trailing = "\(activeCount)/\(items.count)"

        return PanelCard(
            icon: "clock.arrow.circlepath",
            iconColor: .teal,
            title: L.t("Recent Sites", "Sites Recentes"),
            trailing: trailing
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $showLocal) {
                    Text(L.t("Show local addresses",
                             "Mostrar endereços locais"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                contentView(items: items, visible: visible)
            }
        }
    }

    @ViewBuilder
    private func contentView(items: [RecentConnection], visible: [RecentConnection]) -> some View {
        if items.isEmpty {
            Text(L.t("Watching for outbound connections…",
                     "Aguardando conexões de saída…"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible) { rc in
                    recentRow(rc)
                }
                if items.count > Self.initialCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                    } label: {
                        Text(showAll
                             ? L.t("Show fewer", "Mostrar menos")
                             : L.t("+ \(items.count - Self.initialCount) more",
                                   "+ \(items.count - Self.initialCount) mais"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// Portas que dispensam badge — universais o suficiente que mostrar é redundante.
    private static let implicitPorts: Set<Int> = [80, 443, 22, 53]

    @ViewBuilder
    private func recentRow(_ rc: RecentConnection) -> some View {
        let hostDisplay = rc.resolvedHostname ?? rc.remoteHost
        let showServiceBadge = rc.serviceName != nil && !Self.implicitPorts.contains(rc.remotePort)
        HStack(spacing: 5) {
            Circle()
                .fill(rc.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(rc.process)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80, alignment: .leading)
            Text(hostDisplay)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rc.remoteHost)   // tooltip mostra o IP literal
            Text(":\(rc.remotePort)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if showServiceBadge, let svc = rc.serviceName {
                Text(svc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            Spacer(minLength: 4)
            Text(timeAgo(rc.lastSeen))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60    { return "\(secs)s" }
        if secs < 3600  { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}
