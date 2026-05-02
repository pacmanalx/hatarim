import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var scheduler: HealthCheckScheduler
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(cpuHeader)
        Menu("Cores") {
            ForEach(Array(stats.perCoreCPU.enumerated()), id: \.offset) { idx, val in
                Text("\(coreLabel(idx))   \(formatPercent(val))")
            }
        }
        Divider()

        Text(gpuLine)
        Divider()

        if stats.powerAvailable {
            Text(powerHeader)
            Menu("Power detalhado") {
                Text("ANE         \(formatPower(stats.power.aneMilliwatts))")
                Text("P-cluster   \(formatPower(stats.power.pCpuMilliwatts))")
                Text("E-cluster   \(formatPower(stats.power.eCpuMilliwatts))")
                Text("GPU         \(formatPower(stats.power.gpuMilliwatts))")
                Text("DRAM        \(formatPower(stats.power.dramMilliwatts))")
            }
            Divider()
        }

        Text(memLine)
        Text("    wired \(formatBytes(stats.memory.wiredBytes))   comp \(formatBytes(stats.memory.compressedBytes))")
        Divider()

        Text("Net   ↓ \(formatRate(stats.net.rxBytesPerSec))   ↑ \(formatRate(stats.net.txBytesPerSec))")
        Divider()

        Menu("Volumes (\(stats.volumes.count))") {
            if stats.volumes.isEmpty {
                Text("nenhum montado")
            } else {
                ForEach(stats.volumes) { v in
                    Text("\(v.name)   \(formatBytes(UInt64(v.availableBytes))) livres / \(formatBytes(UInt64(v.totalBytes)))")
                }
            }
        }
        Divider()

        Text(arduinoLine)
        Divider()

        Text(stackLine)
        Divider()

        Button("Janela detalhada…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "detail")
        }
        .keyboardShortcut("d")

        Button("Configuração…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Divider()

        Menu("Taxa: \(formatInterval(stats.refreshInterval))") {
            ForEach(SystemStats.availableIntervals, id: \.self) { rate in
                Button {
                    stats.refreshInterval = rate
                } label: {
                    if abs(stats.refreshInterval - rate) < 0.01 {
                        Label(formatInterval(rate), systemImage: "checkmark")
                    } else {
                        Text(formatInterval(rate))
                    }
                }
            }
        }
        Divider()

        Button("Sair") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var cpuHeader: String {
        let avg = formatPercent(stats.cpuAverage)
        if stats.pCoreCount > 0 || stats.eCoreCount > 0 {
            return "CPU \(avg)   (\(stats.pCoreCount)P + \(stats.eCoreCount)E)"
        }
        return "CPU \(avg)"
    }

    private var gpuLine: String {
        let coresPart: String
        if let n = stats.gpuCoreCount, n > 0 {
            coresPart = "  (\(n) cores)"
        } else {
            coresPart = ""
        }
        if let util = stats.gpuUtilPercent {
            return "GPU \(formatPercent(util))\(coresPart)"
        }
        return "GPU —\(coresPart)"
    }

    private var powerHeader: String {
        "Power \(formatPower(stats.power.packageMilliwatts))   (pkg)"
    }

    private var stackLine: String {
        let s = scheduler.summary
        if s.total == 0 { return "Stack  ⚪️  nenhum serviço" }
        return "Stack \(scheduler.aggregateStatus.symbol)  \(s.ok)/\(s.total) saudáveis"
    }

    private var arduinoLine: String {
        let b = stats.arduino
        if b.health == .idle { return "Arduino  ⚪️  modo monitor (sem hardware)" }
        if !b.connected { return "Arduino  🔴  daemon sem porta serial" }
        let dev = b.deviceInfo?.friendlyName ?? "Serial device"
        let port = (b.portPath ?? "—").replacingOccurrences(of: "/dev/", with: "")
        let dot: String
        switch b.health {
        case .idle:     dot = "⚪️"
        case .ok:       dot = "🟢"
        case .degraded: dot = "🟡"
        case .error:    dot = "🔴"
        }
        let pct = String(format: "%.1f%%", b.ackSuccessPercent)
        return "Arduino \(dot)  \(dev)  ·  \(port) @ \(b.baudRate)  ·  ACK \(pct)"
    }

    private func formatPower(_ mW: Double) -> String {
        if mW < 1 { return "—" }
        if mW < 1000 {
            return String(format: "%4.0f mW", mW)
        }
        return String(format: "%5.2f W", mW / 1000)
    }

    private var memLine: String {
        let used = formatBytes(stats.memory.usedBytes)
        let total = formatBytes(stats.memory.totalBytes)
        let pct = formatPercent(stats.memory.pressureUsedRatio * 100)
        return "RAM \(used) / \(total)   \(pct)"
    }

    private func coreLabel(_ index: Int) -> String {
        if stats.pCoreCount > 0 && index < stats.pCoreCount {
            return String(format: "P%d", index)
        }
        if stats.pCoreCount > 0 {
            return String(format: "E%d", index - stats.pCoreCount)
        }
        return String(format: "C%d", index)
    }

    private func formatPercent(_ v: Double) -> String {
        String(format: "%5.1f%%", v)
    }

    private func formatInterval(_ s: Double) -> String {
        s < 1 ? String(format: "%.1fs", s) : String(format: "%.0fs", s)
    }

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
}
