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

    /// True se o processo é do user atual — só esses podem ser mortos sem sudo.
    /// Evita mostrar botão em processos do sistema (root/_appstore/_sntpd/etc).
    static func belongsToCurrentUser(_ pid: Int) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == geteuid()
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
