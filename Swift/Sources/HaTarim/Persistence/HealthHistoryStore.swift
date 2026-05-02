import Foundation
import Combine

/// Entry persistida em disco (JSONL) com 1 linha por health check executado.
/// Schema enxuto pra economizar bytes — mantém info mínima pra heatmap.
struct HealthEntry: Codable, Equatable, Identifiable {
    let ts: Date
    let sid: String          // primeiros 8 chars do UUID
    let sn: String           // service name (redundante mas facilita inspeção manual)
    let lv: Int              // level 1/2/3
    let st: String           // ok / fail / timeout / degraded / unknown
    let lat: Int?            // latency ms
    let d: String?           // detail (opcional, omitido se vazio)

    var id: String { "\(ts.timeIntervalSince1970)-\(sid)-\(lv)" }

    init(timestamp: Date, serviceId: UUID, serviceName: String,
         level: CheckLevel, status: HealthStatus, latencyMs: Int?, detail: String?) {
        self.ts = timestamp
        self.sid = String(serviceId.uuidString.prefix(8))
        self.sn = serviceName
        self.lv = level.rawValue
        self.st = status.rawValue
        self.lat = latencyMs
        self.d = (detail?.isEmpty == false) ? detail : nil
    }
}

final class HealthHistoryStore: ObservableObject {
    @Published private(set) var lastFlushTime: Date = .distantPast
    @Published private(set) var totalEntries: Int = 0

    private let fileURL: URL
    private let queue = DispatchQueue(label: "hatarim.history-store", qos: .utility)
    private var sweepTimer: Timer?

    static let retentionDays: TimeInterval = 7
    static let maxEntries: Int = 50_000  // safety cap

    static func defaultURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("HaTarim", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        sweepIfNeeded(force: true)
        startSweepTimer()
    }

    deinit { sweepTimer?.invalidate() }

    var fileLocation: URL { fileURL }

    /// Append uma entry no arquivo (assíncrono, não bloqueia caller).
    func append(_ entry: HealthEntry) {
        let url = fileURL
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(entry)
                try Self.appendLine(data: data, to: url)
                DispatchQueue.main.async { self.totalEntries += 1 }
            } catch {
                FileHandle.standardError.write(Data("HealthHistoryStore.append: erro \(error)\n".utf8))
            }
        }
    }

    /// Carrega todas as entries dentro de uma janela temporal (síncrono — chamado on-demand pelo viewer).
    func load(since: Date) -> [HealthEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [HealthEntry] = []
        out.reserveCapacity(8000)
        text.enumerateLines { line, _ in
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
            if let entry = try? decoder.decode(HealthEntry.self, from: lineData),
               entry.ts >= since {
                out.append(entry)
            }
        }
        return out
    }

    func loadAll() -> [HealthEntry] {
        load(since: .distantPast)
    }

    // MARK: - Internals

    private static func appendLine(data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private func startSweepTimer() {
        sweepTimer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            self?.sweepIfNeeded(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    /// Sweep: lê tudo, filtra entries com ts >= now - 7d, reescreve.
    /// `force=true` no boot. Caso contrário só faz se passou 1h.
    private func sweepIfNeeded(force: Bool) {
        let url = fileURL
        queue.async {
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { self.totalEntries = 0 }
                return
            }
            let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86400)
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else { return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                var keptLines: [Data] = []
                keptLines.reserveCapacity(8000)
                var droppedCount = 0
                text.enumerateLines { line, _ in
                    guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return }
                    if let entry = try? decoder.decode(HealthEntry.self, from: lineData) {
                        if entry.ts >= cutoff {
                            keptLines.append(lineData)
                        } else {
                            droppedCount += 1
                        }
                    }
                    // linhas inválidas são silenciosamente descartadas
                }
                // Cap por linhas (safety)
                if keptLines.count > Self.maxEntries {
                    let excess = keptLines.count - Self.maxEntries
                    keptLines.removeFirst(excess)
                    droppedCount += excess
                }

                // Reescreve só se houve trim ou se forçado no boot.
                if force || droppedCount > 0 {
                    var combined = Data()
                    combined.reserveCapacity(keptLines.reduce(0) { $0 + $1.count + 1 })
                    for line in keptLines {
                        combined.append(line)
                        combined.append(Data("\n".utf8))
                    }
                    try combined.write(to: url, options: .atomic)
                    FileHandle.standardError.write(Data("HealthHistoryStore.sweep: -\(droppedCount), agora \(keptLines.count) entries\n".utf8))
                }
                DispatchQueue.main.async {
                    self.totalEntries = keptLines.count
                    self.lastFlushTime = Date()
                }
            } catch {
                FileHandle.standardError.write(Data("HealthHistoryStore.sweep: erro \(error)\n".utf8))
            }
        }
    }
}
