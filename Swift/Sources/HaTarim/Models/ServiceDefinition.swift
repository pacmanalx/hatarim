import Foundation

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case ollama
    case ssh
    case local
    case http
    case mcp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .ssh:    return "SSH host"
        case .local:  return "Local command"
        case .http:   return "HTTP endpoint"
        case .mcp:    return "MCP server"
        }
    }

    var endpointHint: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .ssh:    return "user@host"
        case .local:  return "localhost (informativo)"
        case .http:   return "https://api.exemplo.com/health"
        case .mcp:    return "(reservado)"
        }
    }
}

enum CheckLevel: Int, Codable, CaseIterable {
    case l1 = 1
    case l2 = 2
    case l3 = 3

    var label: String {
        switch self {
        case .l1: return "L1 — Conectividade"
        case .l2: return "L2 — Auth / Readiness"
        case .l3: return "L3 — End-to-end (gasta tokens)"
        }
    }

    var shortLabel: String {
        switch self {
        case .l1: return "L1"
        case .l2: return "L2"
        case .l3: return "L3"
        }
    }
}

struct LevelConfig: Codable, Equatable {
    var enabled: Bool
    var intervalSec: Int
    var command: String
    var expectedSubstring: String
    /// L3: se true, gera aritmética aleatória dinâmica e valida pela resposta esperada.
    /// O `command` deve conter o token `{{problem}}` que será substituído por "17 + 34".
    /// `expectedSubstring` é ignorado — usa o resultado da conta.
    var useMathChallenge: Bool

    init(enabled: Bool, intervalSec: Int, command: String = "",
         expectedSubstring: String = "", useMathChallenge: Bool = false) {
        self.enabled = enabled
        self.intervalSec = intervalSec
        self.command = command
        self.expectedSubstring = expectedSubstring
        self.useMathChallenge = useMathChallenge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled            = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        intervalSec        = try c.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 3600
        command            = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        expectedSubstring  = try c.decodeIfPresent(String.self, forKey: .expectedSubstring) ?? ""
        useMathChallenge   = try c.decodeIfPresent(Bool.self, forKey: .useMathChallenge) ?? false
    }

    static let l1Default = LevelConfig(enabled: true,  intervalSec: 3600)   // 60 min
    static let l2Default = LevelConfig(enabled: true,  intervalSec: 1800)   // 30 min
    static let l3Default = LevelConfig(enabled: false, intervalSec: 21600)  // 6 h
}

/// Desafio aritmético gerado dinamicamente pra L3 — cache busting + validação determinística.
struct MathChallenge {
    let problem: String      // ex: "17 + 34"
    let answer: String       // ex: "51"

    static func random() -> MathChallenge {
        let ops: [String] = ["+", "-", "×"]
        let op = ops.randomElement()!
        let a, b, result: Int
        switch op {
        case "×":
            a = Int.random(in: 5...20)
            b = Int.random(in: 5...20)
            result = a * b
        case "-":
            // Garante resultado positivo
            let big = Int.random(in: 30...99)
            let small = Int.random(in: 10...big)
            a = big; b = small
            result = a - b
        default:  // +
            a = Int.random(in: 10...99)
            b = Int.random(in: 10...99)
            result = a + b
        }
        return MathChallenge(problem: "\(a) \(op) \(b)", answer: "\(result)")
    }
}

struct ServiceDefinition: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: ServiceKind
    var endpoint: String
    var timeoutSec: Int
    var notifyOnStateChange: Bool
    var nodeHint: String
    var enabled: Bool

    // 3 níveis de check, cada um com sua frequência e comando próprio.
    var level1: LevelConfig
    var level2: LevelConfig
    var level3: LevelConfig

    // Específicos por kind (continuam úteis, embora alguns convivam com level.command).
    var modelsToCheck: [String]
    var expectedHTTPStatus: Int
    var sshExtraArgs: String

    /// Template de chamada interativa (Call LLM card). Substitui `{{prompt}}` pelo input do usuário.
    /// Para Ollama HTTP, deixa vazio — usa /api/generate direto.
    /// Para SSH/local, ex: `bash -lc "claude --print '{{prompt}}'"` ou
    /// `bash -lc "/path/kimi --print --prompt '{{prompt}}'"`.
    var callTemplate: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: ServiceKind,
        endpoint: String,
        timeoutSec: Int = 5,
        notifyOnStateChange: Bool = false,
        nodeHint: String = "",
        enabled: Bool = true,
        level1: LevelConfig = .l1Default,
        level2: LevelConfig = .l2Default,
        level3: LevelConfig = .l3Default,
        modelsToCheck: [String] = [],
        expectedHTTPStatus: Int = 200,
        sshExtraArgs: String = "",
        callTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.timeoutSec = timeoutSec
        self.notifyOnStateChange = notifyOnStateChange
        self.nodeHint = nodeHint
        self.enabled = enabled
        self.level1 = level1
        self.level2 = level2
        self.level3 = level3
        self.modelsToCheck = modelsToCheck
        self.expectedHTTPStatus = expectedHTTPStatus
        self.sshExtraArgs = sshExtraArgs
        self.callTemplate = callTemplate
    }

    /// Decoder tolerante: aceita schema novo (level1/level2/level3) ou
    /// migra do schema antigo (intervalSec/sshRemoteCommand/deepCheck) preservando configs existentes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decode(UUID.self, forKey: .id)
        name                = try c.decode(String.self, forKey: .name)
        kind                = try c.decode(ServiceKind.self, forKey: .kind)
        endpoint            = try c.decode(String.self, forKey: .endpoint)
        timeoutSec          = try c.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? 5
        notifyOnStateChange = try c.decodeIfPresent(Bool.self, forKey: .notifyOnStateChange) ?? false
        nodeHint            = try c.decodeIfPresent(String.self, forKey: .nodeHint) ?? ""
        enabled             = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        modelsToCheck       = try c.decodeIfPresent([String].self, forKey: .modelsToCheck) ?? []
        expectedHTTPStatus  = try c.decodeIfPresent(Int.self, forKey: .expectedHTTPStatus) ?? 200
        sshExtraArgs        = try c.decodeIfPresent(String.self, forKey: .sshExtraArgs) ?? ""
        callTemplate        = try c.decodeIfPresent(String.self, forKey: .callTemplate) ?? ""

        if let l1 = try c.decodeIfPresent(LevelConfig.self, forKey: .level1) {
            level1 = l1
            level2 = try c.decodeIfPresent(LevelConfig.self, forKey: .level2) ?? .l2Default
            level3 = try c.decodeIfPresent(LevelConfig.self, forKey: .level3) ?? .l3Default
        } else {
            // Migração schema antigo
            let legacyInterval = try c.decodeIfPresent(Int.self, forKey: .intervalSec) ?? 3600
            let legacyRemote   = try c.decodeIfPresent(String.self, forKey: .sshRemoteCommand) ?? ""
            let legacyDeep     = try c.decodeIfPresent(Bool.self, forKey: .deepCheck) ?? false
            level1 = LevelConfig(enabled: true, intervalSec: max(legacyInterval, 3600))
            level2 = LevelConfig(enabled: true, intervalSec: 1800, command: legacyRemote)
            level3 = LevelConfig(enabled: legacyDeep, intervalSec: 21600)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, endpoint, timeoutSec, notifyOnStateChange, nodeHint, enabled
        case level1, level2, level3
        case modelsToCheck, expectedHTTPStatus, sshExtraArgs, callTemplate
        // legacy (only for decoding migration)
        case intervalSec, sshRemoteCommand, deepCheck
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(timeoutSec, forKey: .timeoutSec)
        try c.encode(notifyOnStateChange, forKey: .notifyOnStateChange)
        try c.encode(nodeHint, forKey: .nodeHint)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(level1, forKey: .level1)
        try c.encode(level2, forKey: .level2)
        try c.encode(level3, forKey: .level3)
        try c.encode(modelsToCheck, forKey: .modelsToCheck)
        try c.encode(expectedHTTPStatus, forKey: .expectedHTTPStatus)
        try c.encode(sshExtraArgs, forKey: .sshExtraArgs)
        try c.encode(callTemplate, forKey: .callTemplate)
    }

    func config(for level: CheckLevel) -> LevelConfig {
        switch level {
        case .l1: return level1
        case .l2: return level2
        case .l3: return level3
        }
    }
}

struct ServicesConfig: Codable {
    var schemaVersion: Int
    var services: [ServiceDefinition]

    static let currentSchema = 2

    static func empty() -> ServicesConfig {
        ServicesConfig(schemaVersion: currentSchema, services: [])
    }
}
