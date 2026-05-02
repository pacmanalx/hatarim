import SwiftUI

/// Card compacto de UM serviço da Stack LLM. Pensado pra encaixar num LazyVGrid
/// com mínimo ~320px, lado a lado com outros cards de métrica do sistema.
struct ServiceHealthCard: View {
    let service: ServiceDefinition
    @ObservedObject var scheduler: HealthCheckScheduler

    var body: some View {
        let agg = scheduler.aggregateStatuses[service.id] ?? (service.enabled ? .unknown : .disabled)
        VStack(alignment: .leading, spacing: 10) {
            header(aggregateStatus: agg)
            Divider()
            VStack(spacing: 6) {
                levelRow(.l1, cfg: service.level1)
                levelRow(.l2, cfg: service.level2)
                levelRow(.l3, cfg: service.level3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func header(aggregateStatus agg: HealthStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agg.color)
                .frame(width: 10, height: 10)
                .shadow(color: agg.color.opacity(0.6), radius: agg == .ok ? 3 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(.callout.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(service.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                scheduler.runNow(serviceId: service.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Verificar todos os níveis habilitados agora")
        }
    }

    @ViewBuilder
    private func levelRow(_ level: CheckLevel, cfg: LevelConfig) -> some View {
        let info = scheduler.levelStatuses[service.id]?[level]
        let status: HealthStatus = info?.status ?? (cfg.enabled ? .unknown : .disabled)
        HStack(spacing: 8) {
            Text(level.shortLabel)
                .font(.caption2.bold().monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(detailText(info: info, cfg: cfg))
                .font(.caption)
                .foregroundStyle(cfg.enabled ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let lat = info?.lastSample?.latencyMs {
                Text(formatLatency(lat))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .opacity(cfg.enabled ? 1.0 : 0.4)
    }

    private func detailText(info: LevelStatus?, cfg: LevelConfig) -> String {
        if !cfg.enabled { return "(desabilitado)" }
        guard let info = info else { return "(aguardando)" }
        if let d = info.lastSample?.detail, !d.isEmpty {
            return d
        }
        return info.status.rawValue
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
