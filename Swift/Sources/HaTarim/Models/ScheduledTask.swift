import Foundation

enum TaskActionKind: String, Codable, CaseIterable, Identifiable {
    case script
    case reminder
    case email
    case mouseClick
    var id: String { rawValue }
    var label: String {
        switch self {
        case .script:     return "Script"
        case .reminder:   return "Lembrete"
        case .email:      return "Email"
        case .mouseClick: return "Mouse Click"
        }
    }
    var systemImage: String {
        switch self {
        case .script:     return "terminal"
        case .reminder:   return "bell.badge"
        case .email:      return "envelope"
        case .mouseClick: return "cursorarrow.click"
        }
    }
}

enum TaskScheduleKind: String, Codable, CaseIterable, Identifiable {
    case oneShot
    case everyMinutes
    case daily
    case weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oneShot:      return "Uma vez"
        case .everyMinutes: return "A cada N min"
        case .daily:        return "Diário"
        case .weekly:       return "Semanal"
        }
    }
}

enum TaskMouseButton: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
}

struct TaskActionPayload: Codable, Hashable {
    var command: String = ""
    var title: String = ""
    var body: String = ""
    var to: String = ""
    var pointX: Double = 0
    var pointY: Double = 0
    var mouseButton: TaskMouseButton = .left
    var doubleClick: Bool = false
}

struct TaskSchedulePayload: Codable, Hashable {
    var oneShotAt: Date = Date().addingTimeInterval(300)
    var intervalMinutes: Int = 60
    var hour: Int = 9
    var minute: Int = 0
    /// Calendar.Component.weekday: 1=Sun … 7=Sat
    var weekday: Int = 2
}

struct TaskHistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var when: Date
    var ok: Bool
    var detail: String
    var durationMs: Int
}

struct ScheduledTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "Nova tarefa"
    var enabled: Bool = true
    var actionKind: TaskActionKind = .reminder
    var action: TaskActionPayload = TaskActionPayload()
    var scheduleKind: TaskScheduleKind = .daily
    var schedule: TaskSchedulePayload = TaskSchedulePayload()
    var nextRun: Date? = nil
    var lastRun: Date? = nil
    var lastOk: Bool? = nil
    /// Últimas 20 execuções (mais recente primeiro).
    var history: [TaskHistoryEntry] = []
}

struct TasksConfig: Codable {
    static let currentSchema = 1
    var schemaVersion: Int = currentSchema
    var tasks: [ScheduledTask] = []
    static func empty() -> TasksConfig { TasksConfig() }
}
