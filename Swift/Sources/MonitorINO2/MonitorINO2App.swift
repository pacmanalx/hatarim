import SwiftUI
import AppKit

@main
struct MonitorINO2App: App {
    @StateObject private var stats: SystemStats
    @StateObject private var servicesStore: ServicesStore
    @StateObject private var healthScheduler: HealthCheckScheduler
    @StateObject private var fanStore: FanConfigStore
    @StateObject private var fanController: FanController

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Redireciona stderr pra arquivo persistente (independente de como o app
        // foi aberto — Finder, open, double-click). Permite inspecionar a serial
        // e o FanController em produção sem precisar rodar o binário no terminal.
        let fm = FileManager.default
        if let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MonitorINO2", isDirectory: true) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let logURL = logsDir.appendingPathComponent("activity.log")
            // append mode, line-buffered
            freopen(logURL.path, "a", stderr)
            setvbuf(stderr, nil, _IOLBF, 0)
            let stamp = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardError.write(Data("\n=== APP START \(stamp) ===\n".utf8))
        }

        if !Platform.isAppleSilicon {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "MonitorINO2 requer Apple Silicon"
            alert.informativeText = "Este app só roda em Macs com chip Apple (M1 ou superior)."
            alert.runModal()
            NSApp.terminate(nil)
        }

        // Cria tudo localmente
        let st = SystemStats()
        let store = ServicesStore()
        let scheduler = HealthCheckScheduler(store: store)
        let fStore = FanConfigStore()
        let fc = FanController(store: fStore)

        // INJEÇÃO CRÍTICA: SystemStats precisa de referência pro FanController
        // pra produzir F:0/F:1 no payload desde o primeiro tick.
        st.fanController = fc

        _stats = StateObject(wrappedValue: st)
        _servicesStore = StateObject(wrappedValue: store)
        _healthScheduler = StateObject(wrappedValue: scheduler)
        _fanStore = StateObject(wrappedValue: fStore)
        _fanController = StateObject(wrappedValue: fc)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(stats: stats, scheduler: healthScheduler)
            ReopenObserver()
        } label: {
            MenuBarChipIconView()
        }
        .menuBarExtraStyle(.menu)

        Window(L.t("MonitorINO2 — Details", "MonitorINO2 — Detalhes"), id: "detail") {
            DetailWindow(stats: stats, servicesStore: servicesStore, healthScheduler: healthScheduler)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)

        Window(L.t("MonitorINO2 — Configuration", "MonitorINO2 — Configuração"), id: "settings") {
            SettingsWindow(store: servicesStore, scheduler: healthScheduler)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Window(L.t("MonitorINO2 — Heatmap 7d", "MonitorINO2 — Heatmap 7d"), id: "heatmap") {
            HeatmapWindow(store: servicesStore, scheduler: healthScheduler)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        Window(L.t("MonitorINO2 — FAN Control", "MonitorINO2 — Controle da FAN"), id: "fan") {
            FanControlWindow(store: fanStore, controller: fanController, bridge: stats.arduino)
        }
        .defaultSize(width: 720, height: 760)
        .windowResizability(.contentMinSize)
        Window(L.t("About MonitorINO2", "Sobre o MonitorINO2"), id: "about") {
            AboutWindow()
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button(L.t("About MonitorINO2", "Sobre o MonitorINO2")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Configuração…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Monitor") {
                Button("Janela Detalhada") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .reopenDetail, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Configuração…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Heatmap 7d…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openHeatmap, object: nil)
                }
                .keyboardShortcut("h", modifiers: .command)

                Button("Controle da FAN…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openFan, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Menu("Taxa de atualização") {
                    ForEach(SystemStats.availableIntervals, id: \.self) { rate in
                        Button {
                            stats.refreshInterval = rate
                        } label: {
                            if abs(stats.refreshInterval - rate) < 0.01 {
                                Label(formatInterval(rate), systemImage: "checkmark")
                            } else {
                                Text(formatInterval(rate))
                            }
                        }
                    }
                }
            }
        }
    }

    private func formatInterval(_ s: Double) -> String {
        s < 1 ? String(format: "%.1fs", s) : String(format: "%.0fs", s)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pede permissão Location agora que o app já está com run loop ativo —
        // requestWhenInUseAuthorization no init() do struct App às vezes é silenciosamente
        // ignorado pelo macOS porque a UI ainda não tá pronta pra apresentar prompts.
        LocationPermissionHelper.shared.requestIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows where window.identifier?.rawValue.contains("detail") == true {
                window.makeKeyAndOrderFront(nil)
                return true
            }
            NotificationCenter.default.post(name: .reopenDetail, object: nil)
        }
        return true
    }
}

extension Notification.Name {
    static let reopenDetail = Notification.Name("MonitorINO2.reopenDetail")
    static let openSettings = Notification.Name("MonitorINO2.openSettings")
    static let openHeatmap = Notification.Name("MonitorINO2.openHeatmap")
    static let openFan = Notification.Name("MonitorINO2.openFan")
    static let openAbout = Notification.Name("MonitorINO2.openAbout")
    static let fanControllerReady = Notification.Name("MonitorINO2.fanControllerReady")
}

struct ReopenObserver: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onReceive(NotificationCenter.default.publisher(for: .reopenDetail)) { _ in
                openOrFocus(windowId: "detail")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                openOrFocus(windowId: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openHeatmap)) { _ in
                openOrFocus(windowId: "heatmap")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFan)) { _ in
                openOrFocus(windowId: "fan")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
                openOrFocus(windowId: "about")
            }
    }

    /// Foca uma janela existente (des-minimiza se necessário) ou abre nova se não houver.
    /// Evita o comportamento default do SwiftUI de às vezes criar duplicatas.
    private func openOrFocus(windowId: String) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            let id = window.identifier?.rawValue ?? ""
            // SwiftUI WindowGroup gera identifiers como "detail-AppWindow-1" — contains basta
            if id.contains(windowId) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        openWindow(id: windowId)
    }
}
