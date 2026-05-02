import Foundation
import Combine

/// Bridge pro Arduino via daemon Python (`hatarim_daemon.py`).
///
/// O Swift NÃO abre serial. Em vez disso:
///   - escreve comandos como arquivos em `~/Library/Application Support/HaTarim/send_commands/`
///   - lê heartbeat do daemon em `~/Library/Application Support/HaTarim/daemon_status.json`
///
/// O heartbeat dita o `health` real do bridge — sem heartbeat fresco a UI fica
/// `.idle` (modo monitor sem hardware) e o bridge SUSPENDE a escrita de
/// arquivos pra não acumular spool órfão.
final class ArduinoBridge: ObservableObject {
    static let baudRate: Int = 115200

    enum Health { case idle, ok, degraded, error }

    // MARK: - UI-observed state (populado pelo heartbeat do daemon)
    @Published private(set) var health: Health = .idle
    @Published private(set) var connected: Bool = false
    @Published private(set) var portPath: String? = nil
    @Published private(set) var lastError: String? = nil
    @Published private(set) var bytesSent: UInt64 = 0
    @Published private(set) var lastPayload: String = ""
    @Published private(set) var lastSendTime: Date? = nil
    @Published private(set) var lastAckTime: Date? = nil
    @Published private(set) var deviceInfo: SerialDeviceInfo? = nil
    @Published private(set) var ackOkCount: Int = 0
    @Published private(set) var ackFailCount: Int = 0
    @Published private(set) var sentCount: UInt64 = 0
    @Published private(set) var lastFailureReason: String? = nil
    @Published private(set) var ackSuccessPercent: Double = 0
    @Published private(set) var backlogFiles: Int = 0
    @Published private(set) var daemonPID: Int = 0
    @Published private(set) var daemonUptimeSec: Double = 0
    @Published private(set) var consecutiveFails: Int = 0

    var baudRate: Int { Self.baudRate }
    var isCommunicating: Bool {
        guard let t = lastAckTime else { return false }
        return Date().timeIntervalSince(t) < 5
    }

    /// Modo "monitor sem hardware" — usado pelo Sender pra não escrever spool.
    var isIdle: Bool { health == .idle }

    private let sendDir: URL
    private let statusURL: URL
    private var statusTimer: Timer?

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = support.appendingPathComponent("HaTarim", isDirectory: true)
        sendDir = base.appendingPathComponent("send_commands", isDirectory: true)
        statusURL = base.appendingPathComponent("daemon_status.json")
        try? fm.createDirectory(at: sendDir, withIntermediateDirectories: true)
        FileHandle.standardError.write(Data(
            "ArduinoBridge: spool=\(sendDir.path)  status=\(statusURL.path)\n".utf8
        ))
        startStatusPolling()
    }

    deinit { statusTimer?.invalidate() }

    // MARK: - heartbeat polling

    private func startStatusPolling() {
        readStatusFile()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.readStatusFile()
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    private struct StatusFile: Decodable {
        let pid: Int?
        let port: String?
        let connected: Bool?
        let last_ack_ts: Double?
        let last_payload: String?
        let now: Double?
        let uptime_sec: Double?
        let ack_ok: Int?
        let ack_fail: Int?
        let ack_sent: Int?
        let ack_rate_pct: Double?
        let backlog_files: Int?
        let consecutive_fails: Int?
    }

    private func readStatusFile() {
        guard let data = try? Data(contentsOf: statusURL),
              let parsed = try? JSONDecoder().decode(StatusFile.self, from: data) else {
            applyIdle()
            return
        }
        // Heartbeat stale: arquivo existe mas daemon não toca há > 8s
        let now = Date().timeIntervalSince1970
        let age = now - (parsed.now ?? 0)
        if age > 8 {
            applyIdle(reason: "daemon sem heartbeat há \(Int(age))s")
            return
        }
        applyStatus(parsed)
    }

    private func applyIdle(reason: String? = nil) {
        DispatchQueue.main.async {
            self.health = .idle
            self.connected = false
            self.portPath = nil
            self.ackSuccessPercent = 0
            self.ackOkCount = 0
            self.ackFailCount = 0
            self.backlogFiles = 0
            self.daemonPID = 0
            self.daemonUptimeSec = 0
            self.consecutiveFails = 0
            self.lastFailureReason = reason
        }
    }

    private func applyStatus(_ s: StatusFile) {
        DispatchQueue.main.async {
            self.daemonPID = s.pid ?? 0
            self.daemonUptimeSec = s.uptime_sec ?? 0
            self.portPath = s.port
            self.connected = s.connected ?? false
            self.ackOkCount = s.ack_ok ?? 0
            self.ackFailCount = s.ack_fail ?? 0
            self.sentCount = UInt64(s.ack_sent ?? 0)
            self.ackSuccessPercent = s.ack_rate_pct ?? 0
            self.backlogFiles = s.backlog_files ?? 0
            self.consecutiveFails = s.consecutive_fails ?? 0
            if let p = s.last_payload, !p.isEmpty {
                self.lastPayload = p
            }
            if let ts = s.last_ack_ts, ts > 0 {
                self.lastAckTime = Date(timeIntervalSince1970: ts)
            }
            // Health derivado
            if !(s.connected ?? false) {
                self.health = .error
                self.lastFailureReason = "daemon sem porta serial"
            } else if (s.consecutive_fails ?? 0) >= 2 {
                self.health = .degraded
                self.lastFailureReason = "\(s.consecutive_fails ?? 0) falhas consecutivas"
            } else if (s.backlog_files ?? 0) > 50 {
                self.health = .degraded
                self.lastFailureReason = "backlog alto (\(s.backlog_files ?? 0) arquivos)"
            } else if (s.ack_rate_pct ?? 100) < 90 && (s.ack_sent ?? 0) > 20 {
                self.health = .degraded
                self.lastFailureReason = "ACK rate \(String(format: "%.1f", s.ack_rate_pct ?? 0))%"
            } else {
                self.health = .ok
                self.lastFailureReason = nil
            }
        }
    }

    // MARK: - API pública

    /// Comando regular (telemetria). Prefixo `99_` no nome do arquivo.
    /// No-op em modo idle (sem daemon detectado).
    func sendCommand(token: SerialToken, value: String = "") {
        guard !isIdle else { return }
        writeCommand(prefix: "99", token: token.rawValue, value: value)
    }

    func sendCommand(rawToken: String, value: String = "") {
        guard !isIdle else { return }
        writeCommand(prefix: "99", token: rawToken, value: value)
    }

    /// Comando de atuação (FAN). Prefixo `00_` faz daemon processar antes de
    /// telemetria pendente. No-op em modo idle (FAN não atua sem hardware).
    func sendCommandPriority(token: SerialToken, value: String = "") {
        guard !isIdle else { return }
        writeCommand(prefix: "00", token: token.rawValue, value: value)
    }

    /// Compat com chamadas legadas. Aceita "TOKEN:VALOR" e quebra.
    func send(_ legacyLine: String) {
        let trimmed = legacyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIdx = trimmed.firstIndex(of: ":") else { return }
        let token = String(trimmed[..<colonIdx])
        let value = String(trimmed[trimmed.index(after: colonIdx)...])
        sendCommand(rawToken: token, value: value)
    }

    // MARK: - core

    private static let maxPendingFiles = 100

    private func writeCommand(prefix: String, token: String, value: String) {
        // Se daemon morreu ou tá lento, não acumula milhares de arquivos.
        // Priority (00_) sempre passa — atuação não pode ser perdida.
        if prefix != "00" {
            if let count = try? FileManager.default.contentsOfDirectory(at: sendDir,
                                                                         includingPropertiesForKeys: nil).count,
               count > Self.maxPendingFiles {
                return  // skip silently — telemetria velha não vale
            }
        }
        let ts = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let safeToken = token.replacingOccurrences(of: "/", with: "_")
        let file = sendDir.appendingPathComponent("cmd_\(prefix)_\(ts)_\(safeToken).txt")
        let payload = "\(token):\(value)"
        do {
            try payload.write(to: file, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.bytesSent &+= UInt64(payload.utf8.count)
                self.lastSendTime = Date()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "ArduinoBridge: ERRO escrevendo \(file.path): \(error)\n".utf8
            ))
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.lastFailureReason = error.localizedDescription
            }
        }
    }
}
