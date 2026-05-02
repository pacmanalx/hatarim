import Foundation
import Darwin

/// Mata processos via signal (kill(2)) — sem subprocess overhead, sem `/bin/kill`.
/// Estágio TERM (graceful) com escalada automática pra KILL após N segundos.
enum ProcessKiller {
    enum Result: Equatable {
        case ok
        case alreadyDead
        case denied   // EPERM — processo de outro UID, precisa sudo
        case error(String)
    }

    /// Verifica se o processo ainda existe (kill com signal 0 não envia, só checa).
    static func isAlive(_ pid: Int) -> Bool {
        return kill(pid_t(pid), 0) == 0
    }

    /// Manda SIGTERM. Permite ao processo limpar sockets/flush antes de morrer.
    static func sendTerm(_ pid: Int) -> Result { send(SIGTERM, to: pid) }

    /// Manda SIGKILL. Imediato, sem chance de cleanup.
    static func sendKill(_ pid: Int) -> Result { send(SIGKILL, to: pid) }

    /// Processos do user que mesmo assim NÃO devem mostrar botão de kill —
    /// são essenciais pro sistema rodar (Control Center, Dock, Finder, etc).
    /// launchd respawna eles instantaneamente, então kill seria inócuo + visualmente confuso.
    private static let criticalProcesses: Set<String> = [
        "Control Center", "ControlCenter", "ControlCe",
        "WindowServer", "loginwindow",
        "Dock", "Finder", "SystemUIServer",
        "coreaudiod", "cfprefsd", "lsd", "fseventsd",
        "mds", "mds_stores", "mdworker_shared",
        "rapportd", "sharingd", "trustd", "configd",
        "powerd", "thermalmonitord",
        "Notification", "NotificationC", "NotificationCenter",
        "TextInputMen", "TextInputSwitcher",
        "AirPlayUIAg", "AirPlayUIAgent", "AirPlayXPC",
    ]

    /// True se o processo é do user atual E não está na blacklist de processos críticos.
    /// Filtro pra mostrar botão de kill apenas onde faz sentido (vai funcionar e
    /// não vai provocar respawn imediato pelo launchd).
    static func belongsToCurrentUser(_ pid: Int, processName: String = "") -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return false }
        guard info.kp_eproc.e_ucred.cr_uid == geteuid() else { return false }
        if !processName.isEmpty && criticalProcesses.contains(processName) { return false }
        return true
    }

    private static func send(_ signal: Int32, to pid: Int) -> Result {
        if kill(pid_t(pid), signal) == 0 { return .ok }
        switch errno {
        case ESRCH: return .alreadyDead
        case EPERM: return .denied
        default:    return .error(String(cString: strerror(errno)))
        }
    }
}
