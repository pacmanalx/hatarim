import Foundation
import Darwin

/// Reverse DNS cache singleton com lookup assíncrono.
/// hostname(forIP:) retorna nil na primeira chamada (e dispara lookup em background);
/// chamadas subsequentes retornam o resultado cacheado.
final class DNSResolver {
    static let shared = DNSResolver()

    private struct CacheEntry {
        let hostname: String?      // nil = não resolveu
        let resolvedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MonitorINO2.DNSResolver", qos: .utility, attributes: .concurrent)

    /// TTL do cache — depois disso re-resolve. 30 min é razoável (DNS privado raramente muda).
    private static let cacheTTL: TimeInterval = 30 * 60

    /// Retorna o hostname cacheado ou nil. Se não está em cache, dispara lookup assíncrono.
    func hostname(forIP ip: String) -> String? {
        lock.lock()
        let entry = cache[ip]
        let isInFlight = inFlight.contains(ip)
        lock.unlock()

        if let entry, Date().timeIntervalSince(entry.resolvedAt) < Self.cacheTTL {
            return entry.hostname
        }
        if !isInFlight {
            scheduleLookup(ip)
        }
        return entry?.hostname  // pode retornar valor stale enquanto re-resolve
    }

    private func scheduleLookup(_ ip: String) {
        lock.lock()
        inFlight.insert(ip)
        lock.unlock()

        queue.async { [weak self] in
            let resolved = Self.reverseResolve(ip)
            guard let self else { return }
            self.lock.lock()
            self.cache[ip] = CacheEntry(hostname: resolved, resolvedAt: Date())
            self.inFlight.remove(ip)
            self.lock.unlock()
        }
    }

    private static func reverseResolve(_ ip: String) -> String? {
        var hint = addrinfo()
        hint.ai_flags = AI_NUMERICHOST
        hint.ai_family = AF_UNSPEC

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hint, &info) == 0, let resolved = info else { return nil }
        defer { freeaddrinfo(resolved) }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(resolved.pointee.ai_addr, resolved.pointee.ai_addrlen,
                             &hostBuf, socklen_t(NI_MAXHOST),
                             nil, 0, NI_NAMEREQD)
        guard rc == 0 else { return nil }
        let host = String(cString: hostBuf)
        // getnameinfo às vezes retorna o próprio IP em forma string — descarta isso
        if host == ip { return nil }
        return host
    }
}
