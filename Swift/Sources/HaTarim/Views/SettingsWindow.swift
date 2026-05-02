import SwiftUI
import AppKit

struct EditPayload: Identifiable {
    let id: UUID
    let draft: ServiceDefinition
    let isNew: Bool
}

struct DebugContext: Identifiable {
    let id = UUID()
    let serviceId: UUID
    let serviceName: String
    let level: CheckLevel
}

struct SettingsWindow: View {
    @ObservedObject var store: ServicesStore
    @ObservedObject var scheduler: HealthCheckScheduler

    @State private var selectedID: UUID?
    @State private var editingPayload: EditPayload?
    @State private var debugContext: DebugContext?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                if store.config.services.isEmpty {
                    emptyState
                } else {
                    serviceList
                }
            }
            .frame(minHeight: 240)

            footer
                .frame(minHeight: 120)
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $editingPayload) { payload in
            ServiceEditView(store: store, draft: payload.draft, isNew: payload.isNew)
        }
        .sheet(item: $debugContext) { ctx in
            CheckDebugSheet(serviceName: ctx.serviceName,
                            serviceId: ctx.serviceId,
                            level: ctx.level,
                            scheduler: scheduler)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.tint)
                Text("Stack LLM — health checks")
                    .font(.title3.bold())
                Spacer()
                Text("\(scheduler.summary.ok)/\(scheduler.summary.total) saudáveis")
                    .foregroundStyle(.secondary)
                Button {
                    let svc = ServiceDefinition(name: "", kind: .ollama, endpoint: "")
                    editingPayload = EditPayload(id: svc.id, draft: svc, isNew: true)
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
                Button {
                    guard let id = selectedID,
                          let svc = store.config.services.first(where: { $0.id == id }) else { return }
                    editingPayload = EditPayload(id: svc.id, draft: svc, isNew: false)
                } label: {
                    Label("Editar", systemImage: "pencil")
                }
                .disabled(selectedID == nil)
                Button(role: .destructive) {
                    if let id = selectedID { store.remove(id: id); selectedID = nil }
                } label: {
                    Label("Remover", systemImage: "trash")
                }
                .disabled(selectedID == nil)
            }
            // Toolbar de "Verificar agora" que age no item selecionado.
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(.secondary)
                Text("Verificar selecionado:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("L1") { runForSelected(level: .l1) }
                    .help("Conectividade — sem custo")
                    .disabled(selectedID == nil || !levelEnabled(.l1))
                Button("L2") { runForSelected(level: .l2) }
                    .help("Auth/Readiness — sem custo")
                    .disabled(selectedID == nil || !levelEnabled(.l2))
                Button {
                    runForSelected(level: .l3)
                } label: {
                    Label("L3", systemImage: "bolt.fill")
                        .foregroundStyle(.orange)
                }
                .help("End-to-end — GASTA TOKENS / GPU")
                .disabled(selectedID == nil || !levelEnabled(.l3))
                Button("Todos habilitados") { runForSelected(level: nil) }
                    .disabled(selectedID == nil)
                Spacer()
            }
        }
        .padding(12)
    }

    private func runForSelected(level: CheckLevel?) {
        guard let id = selectedID,
              let svc = store.config.services.first(where: { $0.id == id }) else { return }
        if let lv = level {
            // Botão de nível específico → abre sheet de debug com saída detalhada
            debugContext = DebugContext(serviceId: id, serviceName: svc.name, level: lv)
        } else {
            // "Todos habilitados" → fire-and-forget, sem sheet (várias execuções paralelas)
            scheduler.runNow(serviceId: id, level: nil)
        }
    }

    private func levelEnabled(_ level: CheckLevel) -> Bool {
        guard let id = selectedID,
              let svc = store.config.services.first(where: { $0.id == id }) else { return false }
        return svc.config(for: level).enabled
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Nenhum serviço configurado")
                .font(.headline)
            Text("Clique em **Adicionar** pra começar a monitorar Ollama, SSH, HTTP ou MCP.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var serviceList: some View {
        Table(store.config.services, selection: $selectedID) {
            TableColumn("") { svc in
                let st = scheduler.aggregateStatuses[svc.id] ?? (svc.enabled ? .unknown : .disabled)
                Text(st.symbol)
            }
            .width(28)

            TableColumn("Nome") { svc in
                VStack(alignment: .leading) {
                    Text(svc.name).font(.headline)
                    Text(svc.endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            TableColumn("Tipo") { svc in
                Text(svc.kind.displayName)
            }
            .width(100)

            TableColumn("L1 / L2 / L3") { svc in
                HStack(spacing: 4) {
                    levelBadge(serviceId: svc.id, level: .l1, cfg: svc.level1)
                    levelBadge(serviceId: svc.id, level: .l2, cfg: svc.level2)
                    levelBadge(serviceId: svc.id, level: .l3, cfg: svc.level3)
                }
            }
            .width(120)

            TableColumn("Última latência") { svc in
                if let s = scheduler.levelStatuses[svc.id]?[.l1]?.lastSample,
                   let lat = s.latencyMs {
                    Text("\(lat)ms")
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(110)

            TableColumn("Detalhe (último L com info)") { svc in
                Text(latestDetail(serviceId: svc.id))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }

        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Menu("Verificar agora") {
                    Button("L1") { scheduler.runNow(serviceId: id, level: .l1) }
                    Button("L2") { scheduler.runNow(serviceId: id, level: .l2) }
                    Button("L3 (gasta tokens!)") { scheduler.runNow(serviceId: id, level: .l3) }
                    Divider()
                    Button("Todos os habilitados") { scheduler.runNow(serviceId: id) }
                }
                Divider()
                Button(store.config.services.first(where: { $0.id == id })?.enabled == true
                       ? "Desabilitar" : "Habilitar") {
                    store.toggleEnabled(id: id)
                }
            }
        }
    }

    @ViewBuilder
    private func levelBadge(serviceId: UUID, level: CheckLevel, cfg: LevelConfig) -> some View {
        let st = scheduler.levelStatuses[serviceId]?[level]?.status ?? (cfg.enabled ? .unknown : .disabled)
        Text(st.symbol)
            .help("\(level.shortLabel): \(st.rawValue)")
    }

    private func latestDetail(serviceId: UUID) -> String {
        for lv: CheckLevel in [.l3, .l2, .l1] {
            if let s = scheduler.levelStatuses[serviceId]?[lv]?.lastSample,
               let d = s.detail, !d.isEmpty {
                return "\(lv.shortLabel): \(d)"
            }
        }
        return "—"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Configuração persistida em")
                    .foregroundStyle(.secondary)
                Text(store.fileLocation.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Revelar no Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileLocation])
                }
            }
            Text("Edite à mão com vim se precisar — JSON simples; o app recarrega no próximo restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }
}
