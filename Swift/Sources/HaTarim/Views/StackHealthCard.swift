import SwiftUI

/// Card "LLM HaTarim" — o painel original que deu nome ao projeto inteiro.
/// Todos os serviços LLM em linhas, com seus 3 níveis de health check (L1/L2/L3) em colunas.
struct StackHealthTable: View {
    let services: [ServiceDefinition]
    @ObservedObject var scheduler: HealthCheckScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars.fill")
                    .foregroundStyle(.cyan)
                Text("LLM HaTarim")
                    .font(.callout.bold())
                Spacer()
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Service")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        columnHeader(level: .l1, now: ctx.date)
                        columnHeader(level: .l2, now: ctx.date)
                        columnHeader(level: .l3, now: ctx.date)
                        Color.clear.frame(width: 18)
                    }
                    Divider().gridCellColumns(5)
                    ForEach(services) { svc in
                        GridRow(alignment: .center) {
                            serviceLabel(svc)
                            cell(svc: svc, level: .l1, cfg: svc.level1)
                            cell(svc: svc, level: .l2, cfg: svc.level2)
                            cell(svc: svc, level: .l3, cfg: svc.level3)
                            Button {
                                scheduler.runNow(serviceId: svc.id)
                            } label: {
                                Image(systemName: "arrow.clockwise").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Verificar todos os níveis agora")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func columnHeader(level: CheckLevel, now: Date) -> some View {
        let countdown = nextEventCountdown(level: level, now: now)
        HStack(spacing: 4) {
            Text(level.shortLabel)
                .font(.caption2.bold().monospaced())
                .foregroundStyle(.secondary)
            if let cd = countdown {
                Text("(\(cd))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .help("Tempo até a próxima verificação \(level.shortLabel) (do serviço mais próximo)")
    }

    /// Menor tempo até o próximo `nextRunDates` entre todos os serviços enabled neste nível.
    private func nextEventCountdown(level: CheckLevel, now: Date) -> String? {
        var soonest: TimeInterval?
        for svc in services where svc.enabled && svc.config(for: level).enabled {
            guard let next = scheduler.nextRunDates[svc.id]?[level] else { continue }
            let dt = next.timeIntervalSince(now)
            if soonest == nil || dt < soonest! { soonest = dt }
        }
        guard let s = soonest else { return nil }
        return formatCountdown(s)
    }

    private func formatCountdown(_ sec: TimeInterval) -> String {
        if sec <= 0 { return "now" }
        let s = Int(sec.rounded())
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m > 0 && h < 10 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(s/86400)d"
    }

    @ViewBuilder
    private func serviceLabel(_ svc: ServiceDefinition) -> some View {
        let agg = scheduler.aggregateStatuses[svc.id] ?? (svc.enabled ? .unknown : .disabled)
        HStack(spacing: 7) {
            Circle()
                .fill(agg.color)
                .frame(width: 9, height: 9)
                .shadow(color: agg.color.opacity(0.6), radius: agg == .ok ? 2.5 : 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(svc.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(svc.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cell(svc: ServiceDefinition, level: CheckLevel, cfg: LevelConfig) -> some View {
        let info = scheduler.levelStatuses[svc.id]?[level]
        let status: HealthStatus = info?.status ?? (cfg.enabled ? .unknown : .disabled)
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(cellText(info: info, cfg: cfg))
                .font(.caption)
                .foregroundStyle(cfg.enabled ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .opacity(cfg.enabled ? 1.0 : 0.4)
        .help(tooltip(info: info, cfg: cfg))
    }

    private func cellText(info: LevelStatus?, cfg: LevelConfig) -> String {
        if !cfg.enabled { return "—" }
        if let lat = info?.lastSample?.latencyMs { return formatLatency(lat) }
        guard let info = info else { return "…" }
        return info.status.rawValue
    }

    private func tooltip(info: LevelStatus?, cfg: LevelConfig) -> String {
        if !cfg.enabled { return "Disabled" }
        guard let info = info, let s = info.lastSample else { return "Aguardando primeira amostra" }
        var parts: [String] = []
        if let d = s.detail, !d.isEmpty { parts.append(d) }
        parts.append("status: \(info.status.rawValue)")
        if let lat = s.latencyMs { parts.append("latência: \(formatLatency(lat))") }
        return parts.joined(separator: "  ·  ")
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }
}

/// Card placeholder mostrado quando NÃO há serviços configurados.
struct StackHealthEmptyCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Nenhum serviço configurado")
                .font(.callout.bold())
            Text("⌘,  abre Configuração pra começar")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
