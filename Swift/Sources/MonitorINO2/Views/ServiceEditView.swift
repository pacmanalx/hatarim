import SwiftUI

struct ServiceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ServicesStore

    @State var draft: ServiceDefinition
    let isNew: Bool

    @State private var modelsCSV: String

    init(store: ServicesStore, draft: ServiceDefinition, isNew: Bool) {
        self.store = store
        _draft = State(initialValue: draft)
        self.isNew = isNew
        _modelsCSV = State(initialValue: draft.modelsToCheck.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    identificationCard
                    levelCard(level: .l1, binding: $draft.level1)
                    levelCard(level: .l2, binding: $draft.level2)
                    levelCard(level: .l3, binding: $draft.level3)
                    if draft.kind == .ollama {
                        ollamaModelsCard
                    }
                    if draft.kind == .http {
                        httpExtraCard
                    }
                    if draft.kind == .ssh {
                        sshExtraCard
                    }
                    notificationsCard
                    enabledCard
                }
                .padding(20)
            }
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
            footerBar
        }
        .frame(minWidth: 680, minHeight: 760)
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: kindIcon(draft.kind))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? "Novo serviço" : "Editar serviço")
                    .font(.title2.bold())
                Text(isNew ? "Adicione um novo health check à stack" : draft.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footerBar: some View {
        HStack {
            if let warning = validationMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Adicionar" : "Salvar") {
                draft.modelsToCheck = modelsCSV
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if isNew { store.add(draft) } else { store.update(draft) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(validationMessage != nil)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var identificationCard: some View {
        Card(
            icon: "tag.fill",
            iconColor: .blue,
            title: "Identificação",
            subtitle: "Como esse serviço é referenciado e onde é encontrado"
        ) {
            VStack(spacing: 12) {
                FormRow(label: "Nome") {
                    TextField("ex: Codex (Macbook Air)", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Tipo") {
                    Picker("", selection: $draft.kind) {
                        ForEach(ServiceKind.allCases) { k in
                            Label(k.displayName, systemImage: kindIcon(k)).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                FormRow(label: "Endpoint") {
                    TextField(draft.kind.endpointHint, text: $draft.endpoint)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Timeout") {
                    HStack {
                        Stepper("\(draft.timeoutSec)s", value: $draft.timeoutSec, in: 1...120)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func levelCard(level: CheckLevel, binding: Binding<LevelConfig>) -> some View {
        let cfg = binding.wrappedValue
        Card(
            icon: levelIcon(level),
            iconColor: levelColor(level),
            title: levelTitle(level),
            subtitle: levelSubtitle(level),
            trailing: AnyView(
                Toggle("", isOn: binding.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            )
        ) {
            if cfg.enabled {
                VStack(spacing: 12) {
                    if level == .l3 {
                        l3WarningBanner
                    }
                    FormRow(label: "Intervalo") {
                        HStack {
                            Stepper("\(formatInterval(cfg.intervalSec))",
                                    value: binding.intervalSec, in: 60...86400, step: 60)
                            Spacer()
                            Text(intervalHint(cfg.intervalSec))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    FormRow(label: "Comando") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(commandPlaceholder(level: level),
                                      text: binding.command,
                                      axis: .vertical)
                                .lineLimit(1...4)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                            Text(commandHelp(level: level))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if level == .l3 {
                        Toggle(isOn: binding.useMathChallenge) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Validar com cálculo aleatório").font(.callout)
                                Text("Gera \"17 + 34\" novo a cada execução, substitui `{{problem}}` no comando, valida resultado")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if cfg.useMathChallenge && !cfg.command.contains("{{problem}}") {
                            mathTokenWarning
                        }
                    }
                    FormRow(label: "Espera substring") {
                        TextField(level == .l3 && cfg.useMathChallenge ? "ignorado (usa resultado do cálculo)" : "opcional, ex: OK",
                                  text: binding.expectedSubstring)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .disabled(level == .l3 && cfg.useMathChallenge)
                    }
                }
            } else {
                Text("Nível desabilitado — habilite o toggle acima para configurar")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var l3WarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("End-to-end real").font(.caption.bold()).foregroundStyle(.orange)
                Text("Esse nível executa o modelo de verdade. Pode consumir tokens (Codex/Kimi/Claude) ou GPU local (Ollama). Use intervalo amplo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var mathTokenWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Comando sem `{{problem}}`")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text("O cálculo aleatório está ativo, mas o token `{{problem}}` não aparece no comando. Insira-o onde a conta deve ser injetada.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var ollamaModelsCard: some View {
        Card(
            icon: "shippingbox.fill",
            iconColor: .purple,
            title: "Ollama — modelos esperados",
            subtitle: "Lista validada no L2 (/api/tags). Falta de modelo = degraded."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("vazio = só verifica que servidor responde", text: $modelsCSV,
                          prompt: Text("bge-m3, qwen2.5-coder:7b"))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text("Separe por vírgula. Ex: `bge-m3, mistral:7b, llama3.1:8b`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var httpExtraCard: some View {
        Card(
            icon: "globe",
            iconColor: .green,
            title: "HTTP — status esperado",
            subtitle: "Código HTTP que conta como sucesso (default 200)"
        ) {
            FormRow(label: "Status") {
                HStack {
                    Stepper("\(draft.expectedHTTPStatus)", value: $draft.expectedHTTPStatus, in: 100...599)
                    Spacer()
                }
            }
        }
    }

    private var sshExtraCard: some View {
        Card(
            icon: "terminal.fill",
            iconColor: .gray,
            title: "SSH — opções avançadas",
            subtitle: "Flags injetadas antes do host (geralmente vazio)"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("ex: -i ~/.ssh/outra_key -p 2222", text: $draft.sshExtraArgs)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text("Pré-requisito: chave SSH configurada sem senha. Aliases do `~/.ssh/config` funcionam no campo Endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsCard: some View {
        Card(
            icon: "bell.fill",
            iconColor: .yellow,
            title: "Notificações & Cluster",
            subtitle: "Avisos de mudança de estado e identificação multi-node"
        ) {
            VStack(spacing: 12) {
                Toggle(isOn: $draft.notifyOnStateChange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notificar quando estado mudar").font(.callout)
                        Text("Pop-up nativo do macOS quando o status do serviço transiciona (ex: 🟢 → 🔴)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "Node hint") {
                    TextField("vazio = local (futuro: cluster)", text: $draft.nodeHint)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var enabledCard: some View {
        HStack {
            Image(systemName: draft.enabled ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(draft.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.enabled ? "Serviço ativo" : "Serviço pausado")
                    .font(.headline)
                Text(draft.enabled
                     ? "Health checks rodam conforme intervalos definidos"
                     : "Pausado — nenhum check será executado")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $draft.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Helpers

    private func kindIcon(_ kind: ServiceKind) -> String {
        switch kind {
        case .ollama: return "brain"
        case .ssh:    return "terminal.fill"
        case .local:  return "desktopcomputer"
        case .http:   return "globe"
        case .mcp:    return "cpu"
        }
    }

    private func levelIcon(_ level: CheckLevel) -> String {
        switch level {
        case .l1: return "antenna.radiowaves.left.and.right"
        case .l2: return "key.fill"
        case .l3: return "bolt.fill"
        }
    }

    private func levelColor(_ level: CheckLevel) -> Color {
        switch level {
        case .l1: return .green
        case .l2: return .yellow
        case .l3: return .orange
        }
    }

    private func levelTitle(_ level: CheckLevel) -> String {
        switch level {
        case .l1: return "L1 — Conectividade"
        case .l2: return "L2 — Auth / Readiness"
        case .l3: return "L3 — End-to-end"
        }
    }

    private func levelSubtitle(_ level: CheckLevel) -> String {
        switch level {
        case .l1: return "O host está acessível? (sem custo, frequente)"
        case .l2: return "A ferramenta/API responde? (sem custo, médio)"
        case .l3: return "O modelo realmente funciona? (custo real, raro)"
        }
    }

    private func commandPlaceholder(level: CheckLevel) -> String {
        switch (draft.kind, level) {
        case (.ssh, .l1):    return "vazio = ssh host true"
        case (.ssh, .l2):    return "ex: bash -lc 'codex login status'"
        case (.ssh, .l3):
            return draft.level3.useMathChallenge
                ? "ex: bash -lc \"codex exec --skip-git-repo-check 'responda apenas o número: {{problem}}'\""
                : "ex: bash -lc \"codex exec --skip-git-repo-check 'responda OK'\""
        case (.local, .l1):  return "vazio = só roda 'true' localmente"
        case (.local, .l2):  return "ex: claude --version"
        case (.local, .l3):
            return draft.level3.useMathChallenge
                ? "ex: claude --print 'responda apenas o número: {{problem}}'"
                : "ex: claude --print 'responda OK'"
        case (.ollama, .l1): return "ignorado — usa /api/version"
        case (.ollama, .l2): return "ignorado — usa /api/tags"
        case (.ollama, .l3):
            return draft.level3.useMathChallenge
                ? "chat: mistral:7b|responda com o número: {{problem}}\nembed: embed:bge-m3"
                : "chat: mistral:7b|responda OK\nembed: embed:bge-m3"
        case (.http, _):     return "ignorado para HTTP"
        case (.mcp, _):      return "(reservado)"
        }
    }

    private func commandHelp(level: CheckLevel) -> String {
        switch (draft.kind, level) {
        case (.ssh, .l1):    return "L1: testa SSH up. Vazio roda apenas \"true\" remotamente."
        case (.ssh, .l2):    return "L2: valida ferramenta sem custo (codex login status, kimi info, claude --version)."
        case (.ssh, .l3):    return "L3: end-to-end real, gasta tokens. Use {{problem}} se ativar cálculo aleatório."
        case (.local, .l1):  return "L1: roda comando local via /bin/bash -lc. Vazio = só \"true\"."
        case (.local, .l2):  return "L2: valida ferramenta local (ex: claude --version, codex --version) — sem custo."
        case (.local, .l3):  return "L3: end-to-end local. Roda via /bin/bash -lc. Sem SSH, usa Keychain do user logado."
        case (.ollama, .l1): return "L1: GET /api/version (servidor Ollama responde)."
        case (.ollama, .l2): return "L2: GET /api/tags (lista de modelos disponível, valida modelos esperados)."
        case (.ollama, .l3): return "L3: chat usa /api/generate, embed usa /api/embed. Use {{problem}} pra cache busting."
        case (.http, _):     return "HTTP usa apenas L1 e L2 (ambos GET no endpoint)."
        case (.mcp, _):      return "(MCP é placeholder pra integração futura)"
        }
    }

    private func formatInterval(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h)h \(m)m"
    }

    private func intervalHint(_ s: Int) -> String {
        let perDay = 86400 / max(s, 1)
        return "≈ \(perDay) checks/dia"
    }

    private var validationMessage: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Preencha o nome" }
        if draft.endpoint.trimmingCharacters(in: .whitespaces).isEmpty { return "Preencha o endpoint" }
        return nil
    }
}

// MARK: - Reusable card components

private struct Card<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let trailing = trailing {
                    trailing
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .padding(.top, 4)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
