import Foundation
import Combine

final class TasksStore: ObservableObject {
    @Published var config: TasksConfig

    private let fileURL: URL
    private let queue = DispatchQueue(label: "hatarim.tasks-store", qos: .utility)

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.config = Self.loadOrCreate(at: url)
    }

    static func defaultURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("HaTarim", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    private static func loadOrCreate(at url: URL) -> TasksConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = TasksConfig.empty()
            try? writeSync(empty, to: url)
            return empty
        }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(TasksConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(Data(
                "TasksStore: erro ao carregar \(url.path): \(error). Usando vazio.\n".utf8
            ))
            return .empty()
        }
    }

    func add(_ task: ScheduledTask) {
        config.tasks.append(task)
        save()
    }

    func update(_ task: ScheduledTask) {
        guard let idx = config.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        config.tasks[idx] = task
        save()
    }

    func remove(id: UUID) {
        config.tasks.removeAll { $0.id == id }
        save()
    }

    func toggleEnabled(id: UUID) {
        guard let idx = config.tasks.firstIndex(where: { $0.id == id }) else { return }
        config.tasks[idx].enabled.toggle()
        save()
    }

    func save() {
        let snapshot = config
        let url = fileURL
        queue.async {
            do {
                try Self.writeSync(snapshot, to: url)
            } catch {
                FileHandle.standardError.write(Data("TasksStore.save ERRO: \(error)\n".utf8))
            }
        }
    }

    private static func writeSync(_ cfg: TasksConfig, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(cfg)
        try data.write(to: url, options: .atomic)
    }

    var fileLocation: URL { fileURL }
}
