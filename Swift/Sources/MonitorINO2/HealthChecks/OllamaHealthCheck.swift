import Foundation

struct OllamaHealthCheck: HealthCheck {
    struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]?
    }

    struct GenerateResponse: Decodable {
        let response: String?
        let done: Bool?
    }

    func perform(level: CheckLevel, service: ServiceDefinition) async -> HealthResult? {
        let cfg = service.config(for: level)
        guard cfg.enabled else { return nil }

        let base = service.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "endpoint vazio")
        }

        switch level {
        case .l1:
            return await checkVersion(base: base, service: service)
        case .l2:
            return await checkTags(base: base, service: service)
        case .l3:
            // Detecta modo embed pelo prefix "embed:" no command.
            // Embed: command = "embed:MODEL" ou "embed:MODEL|input customizado"
            // Generate: command = "MODEL|prompt" (existente)
            if cfg.command.hasPrefix("embed:") {
                return await checkEmbed(base: base, service: service, cfg: cfg)
            }
            return await checkGenerate(base: base, service: service, cfg: cfg)
        }
    }

    private func checkVersion(base: String, service: ServiceDefinition) async -> HealthResult {
        let urlStr = "\(base)/api/version"
        let preview = "GET \(urlStr)"
        guard let url = URL(string: urlStr) else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "URL inválida", commandPreview: preview)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(service.timeoutSec)
        req.httpMethod = "GET"
        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let body = String(data: data, encoding: .utf8) ?? ""
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return HealthResult(status: .fail, latencyMs: latencyMs,
                                    detail: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)",
                                    commandPreview: preview, rawOutput: body)
            }
            return HealthResult(status: .ok, latencyMs: latencyMs, detail: String(body.prefix(60)),
                                commandPreview: preview, rawOutput: body, exitCode: 200)
        } catch let e as URLError where e.code == .timedOut {
            return HealthResult(status: .timeout, latencyMs: nil, detail: "timeout \(service.timeoutSec)s",
                                commandPreview: preview)
        } catch let e as URLError where e.code == .cannotConnectToHost {
            return HealthResult(status: .fail, latencyMs: nil, detail: "conexão recusada",
                                commandPreview: preview)
        } catch {
            return HealthResult(status: .fail, latencyMs: nil, detail: error.localizedDescription,
                                commandPreview: preview, rawError: error.localizedDescription)
        }
    }

    private func checkTags(base: String, service: ServiceDefinition) async -> HealthResult {
        let urlStr = "\(base)/api/tags"
        let preview = "GET \(urlStr)"
        guard let url = URL(string: urlStr) else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "URL inválida", commandPreview: preview)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(service.timeoutSec)
        req.httpMethod = "GET"
        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return HealthResult(status: .fail, latencyMs: latencyMs,
                                    detail: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)",
                                    commandPreview: preview, rawOutput: bodyStr)
            }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let modelNames = (tags.models ?? []).map { $0.name }
            if !service.modelsToCheck.isEmpty {
                let missing = service.modelsToCheck.filter { wanted in
                    !modelNames.contains { $0 == wanted || $0.hasPrefix(wanted + ":") }
                }
                if !missing.isEmpty {
                    return HealthResult(status: .degraded, latencyMs: latencyMs,
                                        detail: "faltam: \(missing.joined(separator: ", "))",
                                        commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
                }
            }
            return HealthResult(status: .ok, latencyMs: latencyMs, detail: "\(modelNames.count) modelos",
                                commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
        } catch let e as URLError where e.code == .timedOut {
            return HealthResult(status: .timeout, latencyMs: nil, detail: "timeout \(service.timeoutSec)s",
                                commandPreview: preview)
        } catch {
            return HealthResult(status: .fail, latencyMs: nil, detail: error.localizedDescription,
                                commandPreview: preview, rawError: error.localizedDescription)
        }
    }

    /// L3 deep check: POST /api/generate. cfg.command = "modelo|prompt" (separados por |).
    /// Ex: "qwen2.5:0.5b|responda apenas OK"
    /// Se cfg.useMathChallenge=true, gera "17+34" dinâmico e substitui {{problem}} no prompt.
    private func checkGenerate(base: String, service: ServiceDefinition, cfg: LevelConfig) async -> HealthResult {
        let parts = cfg.command.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              !parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
              !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return HealthResult(status: .unknown, latencyMs: nil,
                                detail: "L3 precisa de \"modelo|prompt\" no campo Comando")
        }
        let model = parts[0].trimmingCharacters(in: .whitespaces)
        var prompt = parts[1].trimmingCharacters(in: .whitespaces)

        var mathChallenge: MathChallenge? = nil
        var effectiveExpected = cfg.expectedSubstring.trimmingCharacters(in: .whitespaces)
        if cfg.useMathChallenge {
            let ch = MathChallenge.random()
            mathChallenge = ch
            prompt = prompt.replacingOccurrences(of: "{{problem}}", with: ch.problem)
            effectiveExpected = ch.answer
        }

        let urlStr = "\(base)/api/generate"
        let bodyDict: [String: Any] = ["model": model, "prompt": prompt, "stream": false]
        let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict)
        let bodyJSON = String(data: bodyData ?? Data(), encoding: .utf8) ?? ""
        let preview = "POST \(urlStr)\n  body: \(bodyJSON)"
        guard let url = URL(string: urlStr) else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "URL inválida", commandPreview: preview)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(max(service.timeoutSec, 30))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let snippet = String(bodyStr.prefix(80))
                return HealthResult(status: .fail, latencyMs: latencyMs,
                                    detail: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(snippet)",
                                    commandPreview: preview, rawOutput: bodyStr)
            }
            let gen = try JSONDecoder().decode(GenerateResponse.self, from: data)
            let response = gen.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let challengeNote = mathChallenge.map { " [desafio: \($0.problem)=\($0.answer)]" } ?? ""
            if response.isEmpty {
                return HealthResult(status: .degraded, latencyMs: latencyMs,
                                    detail: "resposta vazia\(challengeNote)",
                                    commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
            }
            let expected = effectiveExpected
            if !expected.isEmpty, !response.localizedCaseInsensitiveContains(expected) {
                return HealthResult(status: .degraded, latencyMs: latencyMs,
                                    detail: "esperava '\(expected)'\(challengeNote): \(String(response.prefix(50)))",
                                    commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
            }
            return HealthResult(status: .ok, latencyMs: latencyMs,
                                detail: String(response.prefix(60)) + challengeNote,
                                commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
        } catch let e as URLError where e.code == .timedOut {
            return HealthResult(status: .timeout, latencyMs: nil, detail: "timeout (modelo lento?)",
                                commandPreview: preview)
        } catch {
            return HealthResult(status: .fail, latencyMs: nil, detail: error.localizedDescription,
                                commandPreview: preview, rawError: error.localizedDescription)
        }
    }

    /// L3 pra embeddings (bge-m3, nomic-embed-text, etc).
    /// command = "embed:MODEL" ou "embed:MODEL|input customizado".
    /// Cache-busting: useMathChallenge injeta a "conta" no input pra garantir variação.
    /// Validação: HTTP 200 + vetor não-vazio + não-todo-zero. Reporta dimensão.
    private func checkEmbed(base: String, service: ServiceDefinition, cfg: LevelConfig) async -> HealthResult {
        let stripped = String(cfg.command.dropFirst("embed:".count))
        let parts = stripped.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let model = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !model.isEmpty else {
            return HealthResult(status: .unknown, latencyMs: nil,
                                detail: "L3 precisa de \"embed:MODEL\" no campo Comando")
        }
        var input: String
        if parts.count >= 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
            input = parts[1].trimmingCharacters(in: .whitespaces)
        } else {
            input = "monitorino healthcheck seed"
        }

        var mathChallenge: MathChallenge? = nil
        if cfg.useMathChallenge {
            let ch = MathChallenge.random()
            mathChallenge = ch
            if input.contains("{{problem}}") {
                input = input.replacingOccurrences(of: "{{problem}}", with: ch.problem)
            } else {
                // Não há token — apenda a expressão pra garantir que cada chamada vai com input único.
                input = "\(input) \(ch.problem)"
            }
        }

        let urlStr = "\(base)/api/embed"
        let bodyDict: [String: Any] = ["model": model, "input": input]
        let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict)
        let bodyJSON = String(data: bodyData ?? Data(), encoding: .utf8) ?? ""
        let preview = "POST \(urlStr)\n  body: \(bodyJSON)"
        guard let url = URL(string: urlStr) else {
            return HealthResult(status: .fail, latencyMs: nil, detail: "URL inválida", commandPreview: preview)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(max(service.timeoutSec, 30))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        do {
            let start = DispatchTime.now()
            let (data, resp) = try await URLSession.shared.data(for: req)
            let latencyMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let snippet = String(bodyStr.prefix(80))
                return HealthResult(status: .fail, latencyMs: latencyMs,
                                    detail: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(snippet)",
                                    commandPreview: preview, rawOutput: bodyStr)
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let embeddings = json?["embeddings"] as? [[Double]] ?? []
            let seedNote = mathChallenge.map { " [seed: \($0.problem)]" } ?? ""
            guard let firstVec = embeddings.first, !firstVec.isEmpty else {
                return HealthResult(status: .degraded, latencyMs: latencyMs,
                                    detail: "embeddings vazio\(seedNote)",
                                    commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
            }
            let dim = firstVec.count
            if firstVec.allSatisfy({ $0 == 0 }) {
                return HealthResult(status: .degraded, latencyMs: latencyMs,
                                    detail: "vetor dim=\(dim) mas todo zero\(seedNote)",
                                    commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
            }
            let detail = "vetor dim=\(dim), [0]=\(String(format: "%.4f", firstVec[0]))\(seedNote)"
            return HealthResult(status: .ok, latencyMs: latencyMs, detail: detail,
                                commandPreview: preview, rawOutput: bodyStr, exitCode: 200)
        } catch let e as URLError where e.code == .timedOut {
            return HealthResult(status: .timeout, latencyMs: nil, detail: "timeout (embed lento?)",
                                commandPreview: preview)
        } catch {
            return HealthResult(status: .fail, latencyMs: nil, detail: error.localizedDescription,
                                commandPreview: preview, rawError: error.localizedDescription)
        }
    }
}
