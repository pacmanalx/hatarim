import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Card pra mandar pergunta a uma LLM Ollama cadastrada e ver a resposta.
/// Histórico de pergunta×resposta acumulado em sessão (não persistido).
struct CallLLMCard: View {
    let services: [ServiceDefinition]

    @State private var selectedTargetID: String = ""
    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var history: [QAPair] = []
    @State private var loading: Bool = false
    @State private var lastDurationMs: Int? = nil
    @State private var errorText: String? = nil
    @State private var showHistorySheet: Bool = false
    @State private var showFullAnswerSheet: Bool = false
    @State private var saveAlertText: String? = nil
    @State private var sharingAnchorView: NSView? = nil

    private var targets: [LLMTarget] {
        var out: [LLMTarget] = []
        for svc in services where svc.enabled &&
                                 (svc.kind == .ollama || svc.kind == .ssh || svc.kind == .local) {
            if isEmbeddingService(name: svc.name) { continue }
            let models = svc.modelsToCheck.isEmpty ? ["(default)"] : svc.modelsToCheck
            let template = svc.callTemplate
            for m in models where !isEmbeddingModel(m) {
                out.append(LLMTarget(serviceId: svc.id,
                                     serviceName: svc.name,
                                     kind: svc.kind,
                                     endpoint: svc.endpoint,
                                     sshExtraArgs: svc.sshExtraArgs,
                                     callTemplate: template,
                                     model: m,
                                     timeoutSec: max(svc.timeoutSec, 60)))
            }
        }
        return out
    }

    /// Heurística pra excluir modelos de embedding do dropdown — eles usam /api/embed (não /api/generate)
    /// e retornam vetor numérico, inúteis em chat interativo.
    private func isEmbeddingModel(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("embed")
            || n.hasPrefix("bge-") || n.hasPrefix("bge:")
            || n.hasPrefix("e5-") || n.hasPrefix("e5:")
            || n.hasPrefix("gte-") || n.hasPrefix("gte:")
            || n.contains("minilm")
            || n.contains("arctic-embed")
    }

    private func isEmbeddingService(name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("embed ") || n.contains(" embed ") || n.contains("(embed")
    }

    private var selectedTarget: LLMTarget? {
        targets.first(where: { $0.id == selectedTargetID }) ?? targets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            picker
            promptArea
            answerArea
            actionToolbar
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .sheet(isPresented: $showFullAnswerSheet) {
            answerSheet
        }
        .sheet(isPresented: $showHistorySheet) {
            historySheet
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.purple)
            Text("Call LLM")
                .font(.callout.bold())
            Spacer()
            if !history.isEmpty {
                Button {
                    showHistorySheet = true
                } label: {
                    Label("\(history.count)", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Histórico desta sessão")
            }
        }
    }

    private var picker: some View {
        HStack {
            Text("Modelo:").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $selectedTargetID) {
                ForEach(targets) { t in
                    Text(t.displayName).tag(t.id)
                }
                if targets.isEmpty {
                    Text("(nenhum Ollama habilitado)").tag("")
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(targets.isEmpty)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pergunta").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $question)
                .font(.body.monospaced())
                .frame(minHeight: 60, maxHeight: 100)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            HStack {
                Button {
                    Task { await send() }
                } label: {
                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Enviando…")
                        }
                    } else {
                        Label("Enviar", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(loading || selectedTarget == nil ||
                          question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if let ms = lastDurationMs {
                    Text("\(formatDuration(ms))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var answerArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resposta").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let err = errorText {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            ScrollView {
                Text(answer.isEmpty ? "(sem resposta ainda)" : answer)
                    .font(.callout)
                    .foregroundStyle(answer.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(minHeight: 80, maxHeight: 200)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var actionToolbar: some View {
        HStack(spacing: 6) {
            Button { showFullAnswerSheet = true } label: {
                Image(systemName: "eye")
            }
            .help("Visualizar resposta completa")
            .disabled(answer.isEmpty)

            Button { copyToClipboard() } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copiar resposta pra clipboard")
            .disabled(answer.isEmpty)

            Button { saveToFile() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Salvar resposta em arquivo")
            .disabled(answer.isEmpty)

            Menu {
                Button("Apps do macOS (AirDrop, Mail, Messages…)") { showSharingPicker() }
                Divider()
                Button("WhatsApp") { openShareURL(.whatsapp) }
                Button("Telegram") { openShareURL(.telegram) }
                Button("X (Twitter)") { openShareURL(.twitter) }
                Button("Facebook") { openShareURL(.facebook) }
                Button("LinkedIn") { openShareURL(.linkedin) }
                Button("Reddit") { openShareURL(.reddit) }
                Divider()
                Button("Email rascunho (mailto:)") { openShareURL(.email) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Compartilhar")
            .disabled(answer.isEmpty)
            .background(SharingAnchor(view: $sharingAnchorView))

            Spacer()

            if let txt = saveAlertText {
                Text(txt).font(.caption2).foregroundStyle(.green)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }

    private var answerSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resposta")
                    .font(.headline)
                Spacer()
                Button("Fechar") { showFullAnswerSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                Text(answer)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 500, minHeight: 360)
        }
        .padding(16)
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Histórico — sessão atual")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) { history.removeAll() } label: { Text("Limpar") }
                    .disabled(history.isEmpty)
                Button("Fechar") { showHistorySheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(history.reversed()) { qa in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(qa.target).font(.caption.bold()).foregroundStyle(.purple)
                                Spacer()
                                Text(qa.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                if let ms = qa.durationMs {
                                    Text(formatDuration(ms)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                            }
                            Text("Q: \(qa.question)")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Text("R: \(qa.answer)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minWidth: 580, minHeight: 400)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func send() async {
        guard let target = selectedTarget else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        await MainActor.run {
            loading = true
            errorText = nil
            answer = ""
            lastDurationMs = nil
        }
        let result = await OllamaCaller.generate(target: target, prompt: q)
        await MainActor.run {
            loading = false
            switch result {
            case .success(let r):
                answer = r.text
                lastDurationMs = r.durationMs
                history.append(QAPair(timestamp: Date(),
                                       target: target.displayName,
                                       question: q,
                                       answer: r.text,
                                       durationMs: r.durationMs))
            case .failure(let e):
                errorText = e.message
            }
        }
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(shareableTranscript(), forType: .string)
        flashSaved("Copiado")
    }

    private enum WebShareTarget {
        case whatsapp, telegram, twitter, facebook, linkedin, reddit, email
    }

    private func openShareURL(_ target: WebShareTarget) {
        guard !answer.isEmpty else { return }
        let text = shareableTranscript()
        guard let enc = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlStr: String
        switch target {
        case .whatsapp: urlStr = "https://wa.me/?text=\(enc)"
        case .telegram: urlStr = "https://t.me/share/url?url=&text=\(enc)"
        case .twitter:  urlStr = "https://twitter.com/intent/tweet?text=\(enc)"
        case .facebook: urlStr = "https://www.facebook.com/sharer/sharer.php?u=https%3A%2F%2Fclaude.ai&quote=\(enc)"
        case .linkedin: urlStr = "https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fclaude.ai&summary=\(enc)"
        case .reddit:   urlStr = "https://www.reddit.com/submit?title=HaTarim+%E2%80%94+Call+LLM&text=\(enc)"
        case .email:
            let subj = "HaTarim — Call LLM"
            guard let subjEnc = subj.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
            urlStr = "mailto:?subject=\(subjEnc)&body=\(enc)"
        }
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
            flashSaved("Abrindo \(label(for: target))…")
        }
    }

    private func label(for t: WebShareTarget) -> String {
        switch t {
        case .whatsapp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .twitter:  return "X"
        case .facebook: return "Facebook"
        case .linkedin: return "LinkedIn"
        case .reddit:   return "Reddit"
        case .email:    return "Email"
        }
    }

    private func showSharingPicker() {
        guard !answer.isEmpty else { return }
        let text = shareableTranscript()
        let picker = NSSharingServicePicker(items: [text])
        // Ancora no botão que abriu (capturado via SharingAnchor). Fallback: contentView da janela.
        if let anchor = sharingAnchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            return
        }
        if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
           let view = win.contentView {
            let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.nameFieldStringValue = "hatarim-llm-\(Int(Date().timeIntervalSince1970)).txt"
        panel.canCreateDirectories = true
        let resp = panel.runModal()
        guard resp == .OK, let url = panel.url else { return }
        do {
            try shareableTranscript().write(to: url, atomically: true, encoding: .utf8)
            flashSaved("Salvo")
        } catch {
            errorText = "Falha ao salvar: \(error.localizedDescription)"
        }
    }

    private func shareableTranscript() -> String {
        let target = selectedTarget?.displayName ?? "—"
        return """
        # HaTarim — Call LLM
        Modelo: \(target)
        Quando: \(Date().formatted(date: .abbreviated, time: .standard))
        Latência: \(lastDurationMs.map(formatDuration) ?? "—")

        ## Pergunta
        \(question)

        ## Resposta
        \(answer)
        """
    }

    private func flashSaved(_ msg: String) {
        saveAlertText = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { saveAlertText = nil }
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.2fs", Double(ms) / 1000)
    }
}

// MARK: - Models

struct LLMTarget: Identifiable, Hashable {
    let serviceId: UUID
    let serviceName: String
    let kind: ServiceKind
    let endpoint: String
    let sshExtraArgs: String
    let callTemplate: String
    let model: String
    let timeoutSec: Int
    var id: String { "\(serviceId.uuidString):\(model)" }
    var displayName: String {
        let prefix: String
        switch kind {
        case .ollama: prefix = "🌐 "
        case .ssh:    prefix = "🔐 "
        case .local:  prefix = "💻 "
        default:      prefix = ""
        }
        return "\(prefix)\(serviceName) / \(model)"
    }
}

struct QAPair: Identifiable {
    let id = UUID()
    let timestamp: Date
    let target: String
    let question: String
    let answer: String
    let durationMs: Int?
}

// MARK: - Ollama caller

// MARK: - Sharing anchor (NSView wrapper)

/// Ancora invisível pra capturar a NSView do botão Compartilhar — necessário pra
/// posicionar o NSSharingServicePicker no lugar certo da UI.
struct SharingAnchor: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { self.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct OllamaCallError: Error, LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}

enum OllamaCaller {
    struct Reply { let text: String; let durationMs: Int }

    static func generate(target: LLMTarget, prompt: String) async -> Result<Reply, OllamaCallError> {
        switch target.kind {
        case .ollama: return await generateHTTP(target: target, prompt: prompt)
        case .ssh:    return await generateSSH(target: target, prompt: prompt)
        case .local:  return await generateLocal(target: target, prompt: prompt)
        default:      return .failure(OllamaCallError("kind \(target.kind.rawValue) não suportado"))
        }
    }

    /// Local: prefere `level3.command` como template (substitui {{problem}}/{{prompt}}).
    /// Se vazio, fallback `claude --print "<prompt>"` (assume Claude Code).
    private static func generateLocal(target: LLMTarget, prompt: String) async -> Result<Reply, OllamaCallError> {
        let actualCmd: String
        if let custom = substitutePrompt(template: target.callTemplate, prompt: prompt) {
            actualCmd = custom
        } else {
            let raw = target.endpoint.trimmingCharacters(in: .whitespaces)
            let bin: String
            if raw.isEmpty || raw.lowercased().hasPrefix("localhost") { bin = "claude" }
            else if raw.contains("/") || raw.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil { bin = raw }
            else { bin = "claude" }
            let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
            actualCmd = "\(bin) --print '\(escapedPrompt)'"
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Reply, OllamaCallError>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = "/bin/bash"
                process.arguments = ["-lc", actualCmd]
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let start = DispatchTime.now()
                do { try process.run() }
                catch {
                    continuation.resume(returning: .failure(OllamaCallError("bash falhou: \(error.localizedDescription)")))
                    return
                }
                // watchdog
                let killAt = DispatchTime.now() + .seconds(target.timeoutSec)
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: killAt, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()
                let durationMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    let isTimeout = durationMs >= target.timeoutSec * 1000 - 100
                    let snippet = errStr.isEmpty ? outStr : errStr
                    let detail = isTimeout ? "timeout (\(target.timeoutSec)s)" : "exit \(process.terminationStatus): \(String(snippet.prefix(180)))"
                    continuation.resume(returning: .failure(OllamaCallError(detail)))
                    return
                }
                if outStr.isEmpty {
                    continuation.resume(returning: .failure(OllamaCallError("resposta vazia")))
                    return
                }
                continuation.resume(returning: .success(Reply(text: outStr, durationMs: durationMs)))
            }
        }
    }

    private static func buildBodyJSON(target: LLMTarget, prompt: String) -> Data? {
        let modelName = target.model == "(default)" ? "" : target.model
        var bodyDict: [String: Any] = ["prompt": prompt, "stream": false]
        if !modelName.isEmpty { bodyDict["model"] = modelName }
        return try? JSONSerialization.data(withJSONObject: bodyDict)
    }

    private static func parseGenerateResponse(_ data: Data) throws -> String {
        struct GenResp: Decodable { let response: String? }
        let gen = try JSONDecoder().decode(GenResp.self, from: data)
        return gen.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func generateHTTP(target: LLMTarget, prompt: String) async -> Result<Reply, OllamaCallError> {
        let base = target.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty else { return .failure(OllamaCallError("endpoint vazio")) }
        let urlStr = "\(base)/api/generate"
        guard let url = URL(string: urlStr) else { return .failure(OllamaCallError("URL inválida: \(urlStr)")) }
        guard let bodyData = buildBodyJSON(target: target, prompt: prompt) else {
            return .failure(OllamaCallError("erro serializando body"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = TimeInterval(target.timeoutSec)
        req.httpBody = bodyData
        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(OllamaCallError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(String(body.prefix(120)))"))
            }
            let text = (try? parseGenerateResponse(data)) ?? ""
            if text.isEmpty { return .failure(OllamaCallError("resposta vazia")) }
            return .success(Reply(text: text, durationMs: durationMs))
        } catch let e as URLError where e.code == .timedOut {
            return .failure(OllamaCallError("timeout (\(target.timeoutSec)s)"))
        } catch {
            return .failure(OllamaCallError(error.localizedDescription))
        }
    }

    private static func generateSSH(target: LLMTarget, prompt: String) async -> Result<Reply, OllamaCallError> {
        let host = target.endpoint.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(OllamaCallError("host SSH vazio")) }
        // Estratégia: usa level3.command como template (substitui {{problem}}/{{prompt}} pelo
        // prompt do usuário). Se não tem template, cai no curl Ollama por padrão.
        let remoteCmd: String
        if let custom = substitutePrompt(template: target.callTemplate, prompt: prompt) {
            remoteCmd = custom
        } else if target.callTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let bodyData = buildBodyJSON(target: target, prompt: prompt),
                  let bodyJSON = String(data: bodyData, encoding: .utf8) else {
                return .failure(OllamaCallError("erro serializando body"))
            }
            let escaped = bodyJSON.replacingOccurrences(of: "'", with: "'\\''")
            remoteCmd = "curl -sS -m \(target.timeoutSec) -H 'Content-Type: application/json' -d '\(escaped)' http://localhost:11434/api/generate"
        } else {
            return .failure(OllamaCallError("template L3 sem placeholder {{problem}} ou {{prompt}}"))
        }

        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(min(target.timeoutSec, 30))",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        let extra = target.sshExtraArgs.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty {
            args.append(contentsOf: extra.split(separator: " ").map(String.init))
        }
        args.append(host)
        args.append(remoteCmd)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Reply, OllamaCallError>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = "/usr/bin/ssh"
                process.arguments = args
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let start = DispatchTime.now()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(OllamaCallError("ssh falhou: \(error.localizedDescription)")))
                    return
                }
                process.waitUntilExit()
                let durationMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    let detail = errStr.isEmpty ? "exit \(process.terminationStatus)" : errStr
                    continuation.resume(returning: .failure(OllamaCallError("ssh: \(String(detail.prefix(180)))")))
                    return
                }

                let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Se o template foi usado (CLI direta), saída é texto plain. Senão, tenta JSON Ollama.
                let usedTemplate = !target.callTemplate.trimmingCharacters(in: .whitespaces).isEmpty
                if usedTemplate {
                    if outStr.isEmpty {
                        continuation.resume(returning: .failure(OllamaCallError("resposta vazia")))
                        return
                    }
                    continuation.resume(returning: .success(Reply(text: outStr, durationMs: durationMs)))
                    return
                }
                do {
                    let text = try parseGenerateResponse(outData)
                    if text.isEmpty {
                        continuation.resume(returning: .failure(OllamaCallError("resposta vazia")))
                        return
                    }
                    continuation.resume(returning: .success(Reply(text: text, durationMs: durationMs)))
                } catch {
                    let raw = String(outStr.prefix(180))
                    continuation.resume(returning: .failure(OllamaCallError("parse falhou: \(raw)")))
                }
            }
        }
    }

    /// Substitui `{{problem}}` (e alias `{{prompt}}`) no template pelo prompt do usuário.
    /// O escape de aspas detecta o contexto: se `{{problem}}` está dentro de '...' usa `'\\''`,
    /// se está dentro de "..." usa `\"` etc. Mantém o template original intacto fora do token —
    /// se o usuário quer comportamento interativo, edita o `level3.command` removendo o prefixo
    /// hardcoded ("responda apenas com o número: " etc) e deixando só `{{problem}}`.
    static func substitutePrompt(template: String, prompt: String) -> String? {
        guard template.contains("{{prompt}}") else { return nil }
        var result = template
        for placeholder in ["{{prompt}}"] {
            while let range = result.range(of: placeholder) {
                // Detecta a aspa mais próxima ANTES do placeholder pra escolher o escape.
                let beforeText = result[..<range.lowerBound]
                var quoteContext: Character = "'"
                for c in beforeText.reversed() {
                    if c == "'" || c == "\"" { quoteContext = c; break }
                }
                let escaped: String
                if quoteContext == "'" {
                    escaped = prompt.replacingOccurrences(of: "'", with: "'\\''")
                } else {
                    escaped = prompt
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "$", with: "\\$")
                        .replacingOccurrences(of: "`", with: "\\`")
                }
                result.replaceSubrange(range, with: escaped)
            }
        }
        return result
    }
}
