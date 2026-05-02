import Foundation
import Darwin

struct NetSample {
    var rxBytesPerSec: Double
    var txBytesPerSec: Double
    var primaryInterface: String        // "en0", "en1", "—"
    var primaryIPv4: String?            // "192.168.1.42"

    static let zero = NetSample(rxBytesPerSec: 0, txBytesPerSec: 0, primaryInterface: "—", primaryIPv4: nil)
}

final class NetworkCollector {
    private var prev: (rx: UInt64, tx: UInt64, t: TimeInterval)?

    private var emaRx: Double = 0
    private var emaTx: Double = 0
    private static let emaAlpha: Double = 0.35

    private static let ignoredPrefixes = [
        "lo", "utun", "anpi", "llw", "awdl", "bridge", "gif", "stf", "ap"
    ]

    func sample() -> NetSample {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else {
            return .zero
        }
        defer { freeifaddrs(start) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        // Para escolher interface "primária", uso a non-ignored com MAIS bytes acumulados
        var perIfaceBytes: [String: UInt64] = [:]
        var ifaceIPv4: [String: String] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = start

        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            if Self.ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            guard let addr = cur.pointee.ifa_addr else { continue }

            switch addr.pointee.sa_family {
            case UInt8(AF_LINK):
                if let raw = cur.pointee.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    let ibytes = UInt64(data.ifi_ibytes)
                    let obytes = UInt64(data.ifi_obytes)
                    rx &+= ibytes
                    tx &+= obytes
                    perIfaceBytes[name, default: 0] &+= (ibytes &+ obytes)
                }
            case UInt8(AF_INET):
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if !ip.hasPrefix("127.") {
                        ifaceIPv4[name] = ip
                    }
                }
            default:
                break
            }
        }

        // Interface primária: a com mais bytes acumulados que tenha IPv4 não-loopback
        let primary = perIfaceBytes
            .filter { ifaceIPv4[$0.key] != nil }
            .max(by: { $0.value < $1.value })?.key
            ?? perIfaceBytes.max(by: { $0.value < $1.value })?.key
            ?? "—"
        let primaryIP = ifaceIPv4[primary]

        let now = Date().timeIntervalSince1970
        defer { prev = (rx, tx, now) }

        guard let p = prev, now > p.t else {
            return NetSample(rxBytesPerSec: 0, txBytesPerSec: 0,
                             primaryInterface: primary, primaryIPv4: primaryIP)
        }
        let dt = now - p.t
        let dRx = rx >= p.rx ? rx - p.rx : 0
        let dTx = tx >= p.tx ? tx - p.tx : 0
        let instRx = Double(dRx) / dt
        let instTx = Double(dTx) / dt

        emaRx = Self.emaAlpha * instRx + (1 - Self.emaAlpha) * emaRx
        emaTx = Self.emaAlpha * instTx + (1 - Self.emaAlpha) * emaTx

        return NetSample(
            rxBytesPerSec: emaRx,
            txBytesPerSec: emaTx,
            primaryInterface: primary,
            primaryIPv4: primaryIP
        )
    }
}
