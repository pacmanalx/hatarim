import Foundation
import Combine
import UserNotifications

struct LevelStatus: Equatable {
    var status: HealthStatus
    var lastSample: HealthSample?
    var lastRunAt: Date?
}

final class HealthCheckScheduler: ObservableObject {
    /// Status agregado por serviço (combina L1/L2/L3 enabled).
    @Published private(set) var aggregateStatuses: [UUID: HealthStatus] = [:]
    /// Estado por (serviço, nível).
    @Published private(set) var levelStatuses: [UUID: [CheckLevel: LevelStatus]] = [:]
    /// Próxima execução agendada por (serviço, nível). Exposto pra UI mostrar countdown.
    @Published private(set) var nextRunDates: [UUID: [CheckLevel: Date]] = [:]

    private var histories: [UUID: [CheckLevel: HealthHistory]] = [:]
    private var nextRun: [UUID: [CheckLevel: Date]] {
        get { nextRunDates }
        set { nextRunDates = newValue }
    }
    private var consecutiveFailures: [UUID: [CheckLevel: Int]] = [:]
    private var inflight: Set<String> = []

    private let store: ServicesStore
    let historyStore: HealthHistoryStore
    private var storeCancellable: AnyCancellable?
    private var timer: Timer?
    private let tickInterval: TimeInterval = 1.0

    private static let maxBackoffSec: Double = 1800 // 30min cap

    init(store: ServicesStore, historyStore: HealthHistoryStore? = nil) {
        self.store = store
        self.historyStore = historyStore ?? HealthHistoryStore()
        rebuildState()
        storeCancellable = store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildState() }
        startTimer()
        requestNotificationPermissionIfNeeded()
    }

    deinit { timer?.invalidate() }

    func history(for id: UUID, level: CheckLevel) -> HealthHistory {
        if let h = histories[id]?[level] { return h }
        let h = HealthHistory()
        var perLevel = histories[id] ?? [:]
        perLevel[level] = h
        histories[id] = perLevel
        return h
    }

    func runNow(serviceId: UUID, level: CheckLevel? = nil) {
        guard let svc = store.config.services.first(where: { $0.id == serviceId }) else { return }
        let levels: [CheckLevel] = (level.map { [$0] }) ?? CheckLevel.allCases
        for lv in levels where svc.config(for: lv).enabled {
            Task { _ = await self.runCheck(for: svc, level: lv) }
        }
    }

    /// Versão síncrona-await pra UI: roda o check, atualiza state global E retorna o resultado
    /// completo (com rawOutput/rawError/commandPreview) pra exibição em sheet de debug.
    func runNowReturning(serviceId: UUID, level: CheckLevel) async -> HealthResult? {
        guard let svc = store.config.services.first(where: { $0.id == serviceId }) else { return nil }
        return await runCheck(for: svc, level: level)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func rebuildState() {
        let validIds = Set(store.config.services.map { $0.id })
        for id in Array(nextRun.keys) where !validIds.contains(id) {
            nextRun.removeValue(forKey: id)
            levelStatuses.removeValue(forKey: id)
            aggregateStatuses.removeValue(forKey: id)
            histories.removeValue(forKey: id)
            consecutiveFailures.removeValue(forKey: id)
        }
        for svc in store.config.services {
            if nextRun[svc.id] == nil {
                nextRun[svc.id] = [:]
            }
            for lv in CheckLevel.allCases {
                if nextRun[svc.id]?[lv] == nil {
                    nextRun[svc.id]?[lv] = Date()
                }
            }
        }
    }

    private func tick() {
        let now = Date()
        for svc in store.config.services {
            guard svc.enabled else {
                if aggregateStatuses[svc.id] != .disabled {
                    DispatchQueue.main.async { self.aggregateStatuses[svc.id] = .disabled }
                }
                continue
            }
            for lv in CheckLevel.allCases {
                let cfg = svc.config(for: lv)
                guard cfg.enabled else { continue }
                let key = "\(svc.id):\(lv.rawValue)"
                guard !inflight.contains(key) else { continue }
                guard let scheduled = nextRun[svc.id]?[lv], scheduled <= now else { continue }
                Task { await self.runCheck(for: svc, level: lv) }
            }
        }
    }

    @discardableResult
    private func runCheck(for service: ServiceDefinition, level: CheckLevel) async -> HealthResult? {
        let key = "\(service.id):\(level.rawValue)"
        await MainActor.run { _ = self.inflight.insert(key) }
        defer { Task { @MainActor in self.inflight.remove(key) } }

        let check = HealthCheckFactory.make(for: service.kind)
        guard let result = await check.perform(level: level, service: service) else {
            return nil
        }
        let now = Date()
        let sample = HealthSample(
            timestamp: now,
            status: result.status,
            latencyMs: result.latencyMs,
            detail: result.detail
        )

        await MainActor.run {
            self.history(for: service.id, level: level).append(sample)

            var perLevel = self.levelStatuses[service.id] ?? [:]
            let previous = perLevel[level]?.status ?? .unknown
            perLevel[level] = LevelStatus(status: result.status, lastSample: sample, lastRunAt: now)
            self.levelStatuses[service.id] = perLevel

            self.recomputeAggregate(serviceId: service.id, service: service)

            let interval = self.computeNextInterval(service: service, level: level, status: result.status)
            self.nextRun[service.id]?[level] = now.addingTimeInterval(interval)

            if previous != result.status, previous != .unknown {
                self.handleStateChange(service: service, level: level, from: previous, to: result.status)
            }
        }

        // Persiste em disco pra heatmap histórico (7 dias rolling).
        let entry = HealthEntry(
            timestamp: now,
            serviceId: service.id,
            serviceName: service.name,
            level: level,
            status: result.status,
            latencyMs: result.latencyMs,
            detail: result.detail
        )
        historyStore.append(entry)

        return result
    }

    private func recomputeAggregate(serviceId: UUID, service: ServiceDefinition) {
        let perLevel = levelStatuses[serviceId] ?? [:]
        let l1 = perLevel[.l1]?.status
        let l2 = perLevel[.l2]?.status
        let l3 = perLevel[.l3]?.status
        let l2Enabled = service.level2.enabled
        let l3Enabled = service.level3.enabled

        let agg: HealthStatus
        if l1 == .fail || l1 == .timeout {
            agg = .fail
        } else if l1 == nil {
            agg = .unknown
        } else if l2Enabled && (l2 == .fail || l2 == .timeout) {
            agg = .degraded
        } else if l3Enabled && (l3 == .fail || l3 == .timeout || l3 == .degraded) {
            agg = .degraded
        } else if l1 == .degraded || l2 == .degraded {
            agg = .degraded
        } else if l1 == .ok && (!l2Enabled || l2 == .ok) && (!l3Enabled || l3 == .ok || l3 == nil) {
            agg = .ok
        } else {
            agg = .unknown
        }
        aggregateStatuses[serviceId] = agg
    }

    private func computeNextInterval(service: ServiceDefinition, level: CheckLevel, status: HealthStatus) -> TimeInterval {
        let cfg = service.config(for: level)
        let base = TimeInterval(cfg.intervalSec)
        let key = "\(service.id):\(level.rawValue)"
        switch status {
        case .ok:
            consecutiveFailures[service.id]?[level] = 0
            return base
        case .fail, .timeout, .degraded:
            var perLevel = consecutiveFailures[service.id] ?? [:]
            let n = (perLevel[level] ?? 0) + 1
            perLevel[level] = n
            consecutiveFailures[service.id] = perLevel
            let backoff = min(base * pow(1.5, Double(n - 1)), Self.maxBackoffSec)
            _ = key
            return backoff
        case .unknown, .disabled:
            return base
        }
    }

    private func handleStateChange(service: ServiceDefinition, level: CheckLevel, from: HealthStatus, to: HealthStatus) {
        guard service.notifyOnStateChange else { return }
        let title = "\(service.name) \(level.shortLabel): \(to.rawValue.uppercased())"
        let body = "Estado mudou de \(from.rawValue) para \(to.rawValue)."
        notify(title: title, body: body)
    }

    private func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    var aggregateStatus: HealthStatus {
        let active = store.config.services.filter { $0.enabled }
        guard !active.isEmpty else { return .unknown }
        let states = active.compactMap { aggregateStatuses[$0.id] }
        if states.isEmpty { return .unknown }
        if states.contains(.fail) || states.contains(.timeout) { return .fail }
        if states.contains(.degraded) { return .degraded }
        if states.allSatisfy({ $0 == .ok }) { return .ok }
        return .unknown
    }

    var summary: (ok: Int, total: Int) {
        let active = store.config.services.filter { $0.enabled }
        let ok = active.filter { (aggregateStatuses[$0.id] ?? .unknown) == .ok }.count
        return (ok, active.count)
    }
}
