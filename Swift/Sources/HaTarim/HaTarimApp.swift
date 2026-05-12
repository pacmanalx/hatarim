import SwiftUI
import AppKit

@main
struct HaTarimApp: App {
    @StateObject private var stats: SystemStats
    @StateObject private var servicesStore: ServicesStore
    @StateObject private var healthScheduler: HealthCheckScheduler
    @StateObject private var fanStore: FanConfigStore
    @StateObject private var fanController: FanController
    @StateObject private var tasksStore: TasksStore
    @StateObject private var taskScheduler: TaskScheduler

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Redireciona stderr pra arquivo persistente (independente de como o app
        // foi aberto — Finder, open, double-click). Permite inspecionar a serial
        // e o FanController em produção sem precisar rodar o binário no terminal.
        let fm = FileManager.default
        if let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/HaTarim", isDirectory: true) {
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
            alert.messageText = L.t("HaTarim requires Apple Silicon", "HaTarim requer Apple Silicon")
            alert.informativeText = L.t("This app only runs on Macs with Apple chips (M1 or later).",
                                        "Este app só roda em Macs com chip Apple (M1 ou superior).")
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

        let tStore = TasksStore()
        let tSched = TaskScheduler()
        tSched.bind(store: tStore)
        tSched.start()

        _stats = StateObject(wrappedValue: st)
        _servicesStore = StateObject(wrappedValue: store)
        _healthScheduler = StateObject(wrappedValue: scheduler)
        _fanStore = StateObject(wrappedValue: fStore)
        _fanController = StateObject(wrappedValue: fc)
        _tasksStore = StateObject(wrappedValue: tStore)
        _taskScheduler = StateObject(wrappedValue: tSched)
    }

    var body: some Scene {
        Window("HaTarim", id: "detail") {
            DetailWindow(stats: stats,
                         servicesStore: servicesStore,
                         healthScheduler: healthScheduler,
                         tasksStore: tasksStore,
                         taskScheduler: taskScheduler)
                .background(ReopenObserver())
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)

        Window(L.t("HaTarim — Configuration", "HaTarim — Configuração"), id: "settings") {
            SettingsWindow(store: servicesStore, scheduler: healthScheduler)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Window(L.t("HaTarim — FAN Control", "HaTarim — Controle da FAN"), id: "fan") {
            FanControlWindow(store: fanStore, controller: fanController, bridge: stats.arduino)
        }
        .defaultSize(width: 720, height: 760)
        .windowResizability(.contentMinSize)
        Window(L.t("About HaTarim", "Sobre o HaTarim"), id: "about") {
            AboutWindow()
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentSize)

        Window(L.t("HaTarim — GPU Bench", "HaTarim — GPU Bench"), id: "gpubench") {
            GPUBenchWindow(stats: stats)
        }
        .defaultSize(width: 880, height: 560)
        .windowResizability(.contentMinSize)

        Window(L.t("HaTarim — Scheduler", "HaTarim — Scheduler"), id: "scheduler") {
            SchedulerWindow(store: tasksStore, scheduler: taskScheduler)
        }
        .defaultSize(width: 820, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button(L.t("About HaTarim", "Sobre o HaTarim")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L.t("Settings…", "Configuração…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Monitor") {
                Button("HaTarim") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .reopenDetail, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Button(L.t("Settings…", "Configuração…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button(L.t("FAN Control…", "Controle da FAN…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openFan, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button(L.t("GPU Bench…", "GPU Bench…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openGPUBench, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(L.t("Scheduler…", "Scheduler…")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openScheduler, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Menu(L.t("Refresh rate", "Taxa de atualização")) {
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
        true
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
    static let reopenDetail = Notification.Name("HaTarim.reopenDetail")
    static let openSettings = Notification.Name("HaTarim.openSettings")
    static let openFan = Notification.Name("HaTarim.openFan")
    static let openAbout = Notification.Name("HaTarim.openAbout")
    static let openGPUBench = Notification.Name("HaTarim.openGPUBench")
    static let fanControllerReady = Notification.Name("HaTarim.fanControllerReady")
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
            .onReceive(NotificationCenter.default.publisher(for: .openFan)) { _ in
                openOrFocus(windowId: "fan")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
                openOrFocus(windowId: "about")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGPUBench)) { _ in
                openOrFocus(windowId: "gpubench")
            }
            .onReceive(NotificationCenter.default.publisher(for: .openScheduler)) { _ in
                openOrFocus(windowId: "scheduler")
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
