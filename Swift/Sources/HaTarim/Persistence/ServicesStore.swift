import Foundation
import Combine

final class ServicesStore: ObservableObject {
    @Published var config: ServicesConfig

    private let fileURL: URL
    private let queue = DispatchQueue(label: "hatarim.services-store", qos: .utility)

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        let loaded = Self.loadOrCreate(at: url)
        self.config = loaded
        // Se migrou do schema antigo, persiste no formato novo já no boot.
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = raw["schemaVersion"] as? Int,
               v < ServicesConfig.currentSchema {
                save()
                FileHandle.standardError.write(Data("ServicesStore: migrado schema \(v) → \(ServicesConfig.currentSchema)\n".utf8))
            }
        }
    }

    static func defaultURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("HaTarim", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("services.json")
    }

    private static func loadOrCreate(at url: URL) -> ServicesConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = ServicesConfig.empty()
            try? Self.writeSync(empty, to: url)
            return empty
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode(ServicesConfig.self, from: data)
            if loaded.schemaVersion < ServicesConfig.currentSchema {
                loaded = Self.migrate(loaded)
            }
            return loaded
        } catch {
            FileHandle.standardError.write(Data(
                "ServicesStore: erro ao carregar \(url.path): \(error). Usando vazio.\n".utf8
            ))
            return ServicesConfig.empty()
        }
    }

    private static func migrate(_ cfg: ServicesConfig) -> ServicesConfig {
        var out = cfg
        out.schemaVersion = ServicesConfig.currentSchema
        return out
    }

    func add(_ service: ServiceDefinition) {
        FileHandle.standardError.write(Data("ServicesStore.add: name=\(service.name) kind=\(service.kind.rawValue)\n".utf8))
        config.services.append(service)
        save()
    }

    func update(_ service: ServiceDefinition) {
        FileHandle.standardError.write(Data("ServicesStore.update: id=\(service.id) name=\(service.name)\n".utf8))
        guard let idx = config.services.firstIndex(where: { $0.id == service.id }) else {
            FileHandle.standardError.write(Data("ServicesStore.update: id não encontrado\n".utf8))
            return
        }
        config.services[idx] = service
        save()
    }

    func remove(id: UUID) {
        config.services.removeAll { $0.id == id }
        save()
    }

    func toggleEnabled(id: UUID) {
        guard let idx = config.services.firstIndex(where: { $0.id == id }) else { return }
        config.services[idx].enabled.toggle()
        save()
    }

    func save() {
        let snapshot = config
        let url = fileURL
        queue.async {
            do {
                try Self.writeSync(snapshot, to: url)
                FileHandle.standardError.write(Data("ServicesStore.save: \(snapshot.services.count) services persistidos em \(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("ServicesStore.save: ERRO ao escrever \(url.path): \(error)\n".utf8))
            }
        }
    }

    private static func writeSync(_ cfg: ServicesConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cfg)
        try data.write(to: url, options: .atomic)
    }

    var fileLocation: URL { fileURL }
}
