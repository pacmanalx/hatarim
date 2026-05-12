import SwiftUI

/// Card compacto pro Tier 6 — lista resumida das tarefas + atalho pra janela de edição.
struct SchedulerCard: View {
    @ObservedObject var store: TasksStore
    @ObservedObject var scheduler: TaskScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.indigo)
                Text("Scheduler")
                    .font(.callout.bold())
                Spacer()
                Text("\(enabledCount)/\(store.config.tasks.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    NotificationCenter.default.post(name: .openScheduler, object: nil)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Abrir janela do Scheduler (⌘K)")
            }
            Divider()
            if store.config.tasks.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Tarefa").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text("Próxima").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text("Última").font(.caption2.bold()).foregroundStyle(.secondary)
                            Color.clear.frame(width: 16)
                        }
                        Divider().gridCellColumns(5)
                        ForEach(store.config.tasks) { t in
                            GridRow(alignment: .center) {
                                Circle()
                                    .fill(statusColor(t))
                                    .frame(width: 8, height: 8)
                                HStack(spacing: 4) {
                                    Image(systemName: t.actionKind.systemImage)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(t.name).font(.caption).lineLimit(1)
                                }
                                Text(nextRunText(t, now: ctx.date))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(lastRunText(t))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Button {
                                    scheduler.runNow(id: t.id)
                                } label: {
                                    Image(systemName: "play.fill").font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .help("Rodar agora")
                            }
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Nenhuma tarefa")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Criar tarefa…") {
                NotificationCenter.default.post(name: .openScheduler, object: nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var enabledCount: Int { store.config.tasks.filter(\.enabled).count }

    private func statusColor(_ t: ScheduledTask) -> Color {
        if !t.enabled { return .gray }
        if let ok = t.lastOk { return ok ? .green : .red }
        return .yellow
    }

    private func nextRunText(_ t: ScheduledTask, now: Date) -> String {
        guard t.enabled else { return "(off)" }
        guard let next = t.nextRun else { return "—" }
        let delta = Int(next.timeIntervalSince(now))
        if delta < 0 { return "agora" }
        if delta < 60 { return "\(delta)s" }
        if delta < 3600 { return "\(delta/60)m \(delta%60)s" }
        if delta < 86400 { return "\(delta/3600)h \(delta%3600/60)m" }
        return "\(delta/86400)d"
    }

    private func lastRunText(_ t: ScheduledTask) -> String {
        guard let last = t.lastRun else { return "—" }
        let delta = Int(Date().timeIntervalSince(last))
        if delta < 60 { return "\(delta)s atrás" }
        if delta < 3600 { return "\(delta/60)m atrás" }
        if delta < 86400 { return "\(delta/3600)h atrás" }
        return "\(delta/86400)d atrás"
    }
}

extension Notification.Name {
    static let openScheduler = Notification.Name("hatarim.openScheduler")
}
