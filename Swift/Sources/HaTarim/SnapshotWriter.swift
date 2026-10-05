import Foundation
import Combine
import Darwin

/// Grava um snapshot JSON periódico em `~/Library/Application Support/HaTarim/snapshot.json`
/// pro HaMachaneh consumir via `cat` sobre SSH, no mesmo shape do HaTarim Linux.
/// Fica atrás da pilha de collectors — reaproveita o estado já publicado pelo SystemStats
/// e os status agregados do HealthCheckScheduler. Zero coleta nova; só escreve.
final class SnapshotWriter {
    private weak var stats: SystemStats?
    private weak var scheduler: HealthCheckScheduler?
    private weak var servicesStore: ServicesStore?
    private var timer: Timer?
    private let intervalSec: TimeInterval
    private let outURL: URL
    private let tmpURL: URL

    init(stats: SystemStats, scheduler: HealthCheckScheduler, servicesStore: ServicesStore, intervalSec: TimeInterval = 5) {
        self.stats = stats
        self.scheduler = scheduler
        self.servicesStore = servicesStore
        self.intervalSec = intervalSec

        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HaTarim", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.outURL = dir.appendingPathComponent("snapshot.json")
        self.tmpURL = dir.appendingPathComponent("snapshot.json.tmp")
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: intervalSec, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        flush()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func flush() {
        guard let stats = stats, let scheduler = scheduler, let servicesStore = servicesStore else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowIso = iso.string(from: Date())

        // CPU — loadavg(3) do Darwin.
        var loads: [Double] = [0, 0, 0]
        var buf = [Double](repeating: 0, count: 3)
        _ = buf.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        loads = buf
        let threads = ProcessInfo.processInfo.activeProcessorCount
        let loadPct = threads > 0 ? (loads[0] / Double(threads) * 100).rounded(toNearest: 0.1) : 0

        // Memória — reutiliza amostra do SystemStats.
        let mem = stats.memory
        let memUsedPct = mem.totalBytes > 0
            ? (Double(mem.usedBytes) / Double(mem.totalBytes) * 100).rounded(toNearest: 0.1)
            : 0

        // Disco — root volume do sistema.
        let (diskTotal, diskUsed): (Int64, Int64) = {
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
               let total = attrs[.systemSize] as? NSNumber,
               let free = attrs[.systemFreeSize] as? NSNumber {
                let t = total.int64Value
                return (t, t - free.int64Value)
            }
            return (0, 0)
        }()
        let diskPct = diskTotal > 0 ? (Double(diskUsed) / Double(diskTotal) * 100).rounded(toNearest: 0.1) : 0

        // Serviços — agrega L1/L2/L3 do HealthCheckScheduler.
        let defs = servicesStore.config.services.filter { $0.enabled }
        let services: [[String: Any]] = defs.map { def in
            let agg = scheduler.aggregateStatuses[def.id] ?? .unknown
            let state: String
            switch agg {
            case .ok:                        state = "noAr"
            case .fail, .timeout, .degraded: state = "fora"
            default:                         state = "unknown"
            }
            let levels = scheduler.levelStatuses[def.id] ?? [:]
            let checks: [[String: Any]] = CheckLevel.allCases.compactMap { lvl in
                guard let st = levels[lvl], let s = st.lastSample else { return nil }
                var ck: [String: Any] = [
                    "type": "L\(lvl.rawValue)",
                    "ok": s.status == .ok,
                ]
                if let d = s.detail, !d.isEmpty { ck["detail"] = d }
                if let lat = s.latencyMs { ck["latencyMs"] = lat }
                return ck
            }
            var svc: [String: Any] = [
                "id": String(def.id.uuidString.prefix(8)),
                "name": def.name,
                "state": state,
            ]
            if !checks.isEmpty { svc["checks"] = checks }
            if let last = levels.values.compactMap({ $0.lastRunAt }).max() {
                svc["lastCheck"] = iso.string(from: last)
            }
            return svc
        }

        let snapshot: [String: Any] = [
            "ts": nowIso,
            "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "cpu": [
                "load1": loads[0],
                "loadPct": loadPct,
                "threads": threads,
            ],
            "mem": [
                "totalBytes": mem.totalBytes,
                "usedBytes": mem.usedBytes,
                "usedPct": memUsedPct,
            ],
            "disk": [
                "root": [
                    "totalBytes": diskTotal,
                    "usedBytes": diskUsed,
                    "usedPct": diskPct,
                ],
            ],
            "services": services,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(outURL, withItemAt: tmpURL)
        } catch {
            // Falha de escrita não trava o app — só pula o ciclo.
            FileHandle.standardError.write(Data("SnapshotWriter: erro ao gravar — \(error)\n".utf8))
        }
    }
}

private extension Double {
    func rounded(toNearest step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}
