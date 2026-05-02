import Foundation
import Combine

final class FanConfigStore: ObservableObject {
    @Published var config: FanConfig {
        didSet { save() }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "monitorino2.fan-store", qos: .utility)

    static func defaultURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("MonitorINO2", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fan.json")
    }

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(FanConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = FanConfig()
            // Persiste o default no primeiro boot pra ter o JSON visível
            queue.async { try? Self.writeSync(FanConfig(), to: url) }
        }
    }

    var fileLocation: URL { fileURL }

    private func save() {
        let snapshot = config
        let url = fileURL
        queue.async {
            do {
                try Self.writeSync(snapshot, to: url)
            } catch {
                FileHandle.standardError.write(Data("FanConfigStore.save: erro \(error)\n".utf8))
            }
        }
    }

    private static func writeSync(_ cfg: FanConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        try data.write(to: url, options: .atomic)
    }
}
