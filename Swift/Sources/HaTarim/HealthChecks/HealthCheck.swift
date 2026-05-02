import Foundation

struct HealthResult {
    let status: HealthStatus
    let latencyMs: Int?
    let detail: String?

    // Diagnóstico (opcional) — preenchidos pra exibição em modo debug.
    let commandPreview: String?
    let rawOutput: String?
    let rawError: String?
    let exitCode: Int?

    init(status: HealthStatus,
         latencyMs: Int?,
         detail: String?,
         commandPreview: String? = nil,
         rawOutput: String? = nil,
         rawError: String? = nil,
         exitCode: Int? = nil) {
        self.status = status
        self.latencyMs = latencyMs
        self.detail = detail
        self.commandPreview = commandPreview
        self.rawOutput = rawOutput
        self.rawError = rawError
        self.exitCode = exitCode
    }
}

protocol HealthCheck {
    /// Executa o check do nível solicitado. Retorna nil se o nível não se aplica
    /// pra esse kind (ex: HTTP genérico não tem L3 e2e).
    func perform(level: CheckLevel, service: ServiceDefinition) async -> HealthResult?
}

enum HealthCheckFactory {
    static func make(for kind: ServiceKind) -> HealthCheck {
        switch kind {
        case .ollama: return OllamaHealthCheck()
        case .ssh:    return SSHHealthCheck()
        case .local:  return LocalHealthCheck()
        case .http:   return HTTPHealthCheck()
        case .mcp:    return HTTPHealthCheck()
        }
    }
}
