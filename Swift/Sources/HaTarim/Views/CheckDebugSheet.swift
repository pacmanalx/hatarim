import SwiftUI

struct CheckDebugSheet: View {
    @Environment(\.dismiss) private var dismiss

    let serviceName: String
    let serviceId: UUID
    let level: CheckLevel
    @ObservedObject var scheduler: HealthCheckScheduler

    @State private var isRunning: Bool = true
    @State private var result: HealthResult?
    @State private var startedAt: Date = Date()
    @State private var elapsed: TimeInterval = 0
    private let elapsedTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isRunning {
                        runningView
                    }
                    if let r = result {
                        resultSummary(r)
                        if let cmd = r.commandPreview, !cmd.isEmpty {
                            section("Comando", body: cmd, color: .secondary)
                        }
                        if let out = r.rawOutput, !out.isEmpty {
                            section("stdout", body: out, color: .primary)
                        }
                        if let err = r.rawError, !err.isEmpty {
                            // Pinta stderr de vermelho só quando o check falhou.
                            // Muitos CLIs (ex: Codex, Claude) usam stderr como "trace humano"
                            // mesmo em sucesso — colorir tudo de vermelho seria enganoso.
                            let isFailure = (r.exitCode != 0 && r.exitCode != 200) ||
                                            r.status == .fail || r.status == .timeout
                            if isFailure {
                                section("stderr", body: err, color: .red)
                            } else {
                                section("stderr (informativo, exit OK)", body: err, color: .secondary)
                            }
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .task { await runOnce() }
        .onReceive(elapsedTimer) { now in
            if isRunning { elapsed = now.timeIntervalSince(startedAt) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(level.shortLabel)
                .font(.title2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(serviceName)
                    .font(.headline)
                Text(level.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let r = result {
                HStack(spacing: 8) {
                    Text(r.status.symbol)
                    Text(r.status.rawValue.uppercased())
                        .font(.callout.bold())
                        .foregroundStyle(r.status.color)
                }
            }
        }
        .padding(14)
    }

    private var runningView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Executando \(level.shortLabel)…")
                .font(.callout)
            Spacer()
            Text(String(format: "%.1fs", elapsed))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func resultSummary(_ r: HealthResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(r.status.symbol)
                    Text(r.status.rawValue)
                        .foregroundStyle(r.status.color)
                }
            }
            GridRow {
                Text("Latência").foregroundStyle(.secondary)
                Text(r.latencyMs.map { "\($0) ms" } ?? "—")
                    .font(.system(.body, design: .monospaced))
            }
            if let exit = r.exitCode {
                GridRow {
                    Text("Exit / HTTP").foregroundStyle(.secondary)
                    Text("\(exit)")
                        .font(.system(.body, design: .monospaced))
                }
            }
            if let d = r.detail {
                GridRow {
                    Text("Resumo").foregroundStyle(.secondary)
                    Text(d)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func section(_ title: String, body: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(color)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copia o conteúdo pra área de transferência")
            }
            Text(body)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Button("Verificar de novo") {
                Task { await runOnce() }
            }
            .disabled(isRunning)
            Spacer()
            Button("Fechar") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func runOnce() async {
        await MainActor.run {
            isRunning = true
            result = nil
            startedAt = Date()
            elapsed = 0
        }
        let r = await scheduler.runNowReturning(serviceId: serviceId, level: level)
        await MainActor.run {
            result = r
            isRunning = false
        }
    }
}
