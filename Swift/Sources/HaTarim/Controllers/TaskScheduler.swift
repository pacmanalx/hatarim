import Foundation
import Combine
import AppKit
import UserNotifications
import CoreGraphics
import ApplicationServices

/// Engine de scheduler. Tick de 1s, calcula nextRun por tarefa, dispara executor
/// e atualiza lastRun/lastOk/history no TasksStore. Lock anti-overlap por task.
@MainActor
final class TaskScheduler: ObservableObject {
    private weak var store: TasksStore?
    private var timer: Timer?
    private var inFlight: Set<UUID> = []

    func bind(store: TasksStore) {
        self.store = store
        recomputeNextRuns()
    }

    func start() {
        stop()
        // Tick a cada 1s (fineness suficiente; impacto desprezível)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runNow(id: UUID) {
        guard let store, let task = store.config.tasks.first(where: { $0.id == id }) else { return }
        fire(task: task, store: store, forced: true)
    }

    /// Recalcula nextRun pra todas as tarefas (chamado no boot e quando uma é editada).
    func recomputeNextRuns() {
        guard let store else { return }
        let now = Date()
        for i in store.config.tasks.indices {
            store.config.tasks[i].nextRun = Self.computeNextRun(task: store.config.tasks[i], after: now)
        }
        store.save()
    }

    private func tick() {
        guard let store else { return }
        let now = Date()
        for task in store.config.tasks where task.enabled {
            guard let next = task.nextRun, next <= now else { continue }
            if inFlight.contains(task.id) { continue }
            fire(task: task, store: store, forced: false)
        }
    }

    private func fire(task: ScheduledTask, store: TasksStore, forced: Bool) {
        inFlight.insert(task.id)
        let start = Date()
        Task { @MainActor in
            let result = await ScheduledTaskExecutor.execute(task: task)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            self.recordResult(taskID: task.id, ok: result.ok, detail: result.detail, durationMs: durationMs, store: store)
            // Recalcula next-run (pra one-shot, fica nil; pra recorrente, próximo)
            if let idx = store.config.tasks.firstIndex(where: { $0.id == task.id }) {
                let updated = store.config.tasks[idx]
                store.config.tasks[idx].nextRun = Self.computeNextRun(task: updated, after: Date())
                store.save()
            }
            self.inFlight.remove(task.id)
        }
    }

    private func recordResult(taskID: UUID, ok: Bool, detail: String, durationMs: Int, store: TasksStore) {
        guard let idx = store.config.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        store.config.tasks[idx].lastRun = Date()
        store.config.tasks[idx].lastOk = ok
        let entry = TaskHistoryEntry(when: Date(), ok: ok, detail: String(detail.prefix(300)), durationMs: durationMs)
        store.config.tasks[idx].history.insert(entry, at: 0)
        if store.config.tasks[idx].history.count > 20 {
            store.config.tasks[idx].history.removeLast(store.config.tasks[idx].history.count - 20)
        }
        store.save()
    }

    /// Calcula o próximo disparo a partir de `after`. Pra oneShot, retorna nil se já passou.
    static func computeNextRun(task: ScheduledTask, after now: Date) -> Date? {
        let cal = Calendar.current
        switch task.scheduleKind {
        case .oneShot:
            return task.schedule.oneShotAt > now ? task.schedule.oneShotAt : nil
        case .everyMinutes:
            let mins = max(1, task.schedule.intervalMinutes)
            // Se nunca rodou: agora + interval. Se rodou: lastRun + interval.
            let base = task.lastRun ?? now
            var next = base.addingTimeInterval(TimeInterval(mins * 60))
            if next <= now { next = now.addingTimeInterval(TimeInterval(mins * 60)) }
            return next
        case .daily:
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = task.schedule.hour
            comps.minute = task.schedule.minute
            comps.second = 0
            guard var target = cal.date(from: comps) else { return nil }
            if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
            return target
        case .weekly:
            var target = nextWeekdayDate(weekday: task.schedule.weekday,
                                         hour: task.schedule.hour,
                                         minute: task.schedule.minute,
                                         from: now,
                                         calendar: cal)
            if target <= now {
                target = cal.date(byAdding: .day, value: 7, to: target) ?? target
            }
            return target
        }
    }

    private static func nextWeekdayDate(weekday: Int, hour: Int, minute: Int, from: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day, .weekday], from: from)
        let cur = comps.weekday ?? 1
        let delta = ((weekday - cur) + 7) % 7
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.date(from: comps) ?? from
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }
}

/// Executores das ações. Cada um devolve (ok, detail).
enum ScheduledTaskExecutor {
    struct Result { let ok: Bool; let detail: String }

    static func execute(task: ScheduledTask) async -> Result {
        switch task.actionKind {
        case .script:     return await runScript(task.action.command)
        case .reminder:   return await postReminder(title: task.name.isEmpty ? "HaTarim" : task.name,
                                                    body: task.action.body.isEmpty ? task.action.title : task.action.body)
        case .email:      return await sendEmail(to: task.action.to,
                                                 subject: task.action.title.isEmpty ? task.name : task.action.title,
                                                 body: task.action.body)
        case .mouseClick: return MouseAutomation.click(x: task.action.pointX,
                                                       y: task.action.pointY,
                                                       button: task.action.mouseButton,
                                                       doubleClick: task.action.doubleClick)
        }
    }

    private static func runScript(_ cmd: String) async -> Result {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(ok: false, detail: "comando vazio") }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.launchPath = "/bin/bash"
                p.arguments = ["-lc", trimmed]
                let out = Pipe(); let err = Pipe()
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: Result(ok: false, detail: "exec: \(error.localizedDescription)"))
                    return
                }
                p.waitUntilExit()
                let oStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let eStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let ok = p.terminationStatus == 0
                let detail = ok ? oStr.trimmingCharacters(in: .whitespacesAndNewlines)
                                : "exit \(p.terminationStatus): \((eStr.isEmpty ? oStr : eStr).trimmingCharacters(in: .whitespacesAndNewlines))"
                cont.resume(returning: Result(ok: ok, detail: detail.isEmpty ? "ok" : detail))
            }
        }
    }

    private static func postReminder(title: String, body: String) async -> Result {
        let center = UNUserNotificationCenter.current()
        let granted: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else { return Result(ok: false, detail: "permissão de notificações negada") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do { try await center.add(req) } catch {
            return Result(ok: false, detail: "notif: \(error.localizedDescription)")
        }
        return Result(ok: true, detail: "enviado")
    }

    private static func sendEmail(to: String, subject: String, body: String) async -> Result {
        let recipient = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else { return Result(ok: false, detail: "destinatário vazio") }
        let cmd = "mailme '\(recipient)' '\(subject.replacingOccurrences(of: "'", with: "'\\''"))' '\(body.replacingOccurrences(of: "'", with: "'\\''"))'"
        return await runScript(cmd)
    }
}
