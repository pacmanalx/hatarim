import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

enum InterfaceType: String, Equatable {
    case wifi, ethernet, cellular, loopback, tunnel, bridge, usb, awdl, firewire, virtual, unknown

    var iconName: String {
        switch self {
        case .wifi:     return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .tunnel:   return "lock.shield"
        case .bridge:   return "rectangle.connected.to.line.below"
        case .usb:      return "cable.connector.horizontal"
        case .awdl:     return "dot.radiowaves.left.and.right"
        case .firewire: return "bolt.horizontal"
        case .virtual:  return "square.dashed"
        case .unknown:  return "network"
        }
    }
}

struct InterfaceInfo: Identifiable, Equatable {
    let id: String                // bsd name
    let bsdName: String
    let displayName: String       // "Wi-Fi", "Ethernet", "Thunderbolt Bridge", etc
    let type: InterfaceType
    let isUp: Bool                // IFF_UP
    let isRunning: Bool           // IFF_RUNNING (link active)
    let isPrimary: Bool           // detém a default route
    let ipv4: String?
    let macAddress: String?
    // Wi-Fi specific
    let ssid: String?
    let rssi: Int?                // dBm (negative). nil se sem permissão Location ou não Wi-Fi
    let wifiBand: String?         // "2.4 GHz", "5 GHz", "6 GHz"
    let wifiChannel: Int?
    let wifiTxRateMbps: Double?
    // Traffic
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

final class NetworkInterfaceCollector {
    private struct PrevSample {
        var rx: UInt64
        var tx: UInt64
        var t: TimeInterval
    }
    private var prevByName: [String: PrevSample] = [:]
    private var emaByName: [String: (rx: Double, tx: Double)] = [:]
    private static let emaAlpha: Double = 0.35

    private static let ignoredPrefixes = ["lo", "anpi", "llw", "gif", "stf", "ap"]

    /// Cache de friendly names — SystemConfiguration é caro, refrescar 1x a cada 30 ticks
    private var displayNameCache: [String: String] = [:]
    private var typeCache: [String: InterfaceType] = [:]
    private var cacheTickCounter = 0
    private static let cacheRefreshTicks = 30

    func sample() -> [InterfaceInfo] {
        cacheTickCounter += 1
        if cacheTickCounter >= Self.cacheRefreshTicks || displayNameCache.isEmpty {
            cacheTickCounter = 0
            refreshFriendlyNames()
        }

        var result: [InterfaceInfo] = []
        let primary = primaryInterfaceName()

        // Coleta IPv4 + MAC + AF_LINK stats num único pass do getifaddrs
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return [] }
        defer { freeifaddrs(start) }

        var ipv4ByIface: [String: String] = [:]
        var macByIface: [String: String] = [:]
        var rxByIface: [String: UInt64] = [:]
        var txByIface: [String: UInt64] = [:]
        var flagsByIface: [String: UInt32] = [:]
        var seen: Set<String> = []

        var ptr = start
        while true {
            let cur = ptr.pointee
            let name = String(cString: cur.ifa_name)
            seen.insert(name)
            flagsByIface[name] = cur.ifa_flags

            if let addr = cur.ifa_addr {
                switch addr.pointee.sa_family {
                case UInt8(AF_INET):
                    var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buf)
                        if !ip.hasPrefix("127.") {
                            ipv4ByIface[name] = ip
                        }
                    }
                case UInt8(AF_LINK):
                    if let raw = cur.ifa_data {
                        let data = raw.assumingMemoryBound(to: if_data.self).pointee
                        rxByIface[name, default: 0] &+= UInt64(data.ifi_ibytes)
                        txByIface[name, default: 0] &+= UInt64(data.ifi_obytes)
                    }
                    // MAC address from sockaddr_dl
                    let dl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                    if dl.sdl_alen == 6 {
                        let macOffset = Int(dl.sdl_nlen)
                        let mac = withUnsafePointer(to: dl.sdl_data) {
                            $0.withMemoryRebound(to: UInt8.self, capacity: 12) { ptr in
                                (0..<6).map { String(format: "%02x", ptr[macOffset + $0]) }.joined(separator: ":")
                            }
                        }
                        if mac != "00:00:00:00:00:00" { macByIface[name] = mac }
                    }
                default:
                    break
                }
            }
            guard let next = cur.ifa_next else { break }
            ptr = next
        }

        let now = Date().timeIntervalSince1970

        // Pra Wi-Fi — pega 1x e correlaciona com o BSD da interface Wi-Fi
        let wifiInfo = currentWiFiInfo()

        for name in seen.sorted() {
            if Self.ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let flags = flagsByIface[name] ?? 0
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
            let type = typeCache[name] ?? classifyByName(name)
            let displayName = displayNameCache[name] ?? friendlyByType(name: name, type: type)
            let ipv4 = ipv4ByIface[name]

            // Rate calculation
            let rx = rxByIface[name] ?? 0
            let tx = txByIface[name] ?? 0
            var rxRate: Double = 0
            var txRate: Double = 0
            if let p = prevByName[name], now > p.t {
                let dt = now - p.t
                let dRx = rx >= p.rx ? Double(rx - p.rx) / dt : 0
                let dTx = tx >= p.tx ? Double(tx - p.tx) / dt : 0
                let prevEMA = emaByName[name] ?? (0, 0)
                rxRate = Self.emaAlpha * dRx + (1 - Self.emaAlpha) * prevEMA.rx
                txRate = Self.emaAlpha * dTx + (1 - Self.emaAlpha) * prevEMA.tx
                emaByName[name] = (rxRate, txRate)
            }
            prevByName[name] = PrevSample(rx: rx, tx: tx, t: now)

            // Wi-Fi data (apenas pra interface Wi-Fi correta)
            var ssid: String?
            var rssi: Int?
            var band: String?
            var channel: Int?
            var txMbps: Double?
            if type == .wifi, let wifi = wifiInfo, wifi.bsdName == name {
                ssid = wifi.ssid
                rssi = wifi.rssi
                band = wifi.band
                channel = wifi.channel
                txMbps = wifi.txRate
            }

            result.append(InterfaceInfo(
                id: name,
                bsdName: name,
                displayName: displayName,
                type: type,
                isUp: isUp,
                isRunning: isRunning,
                isPrimary: name == primary,
                ipv4: ipv4,
                macAddress: macByIface[name],
                ssid: ssid,
                rssi: rssi,
                wifiBand: band,
                wifiChannel: channel,
                wifiTxRateMbps: txMbps,
                rxBytesPerSec: rxRate,
                txBytesPerSec: txRate
            ))
        }

        // Limpa estado de interfaces que sumiram
        for name in prevByName.keys where !seen.contains(name) {
            prevByName.removeValue(forKey: name)
            emaByName.removeValue(forKey: name)
        }

        // Ordenação: ativas (running+IP) primeiro, depois ordem alfabética
        return result.sorted { lhs, rhs in
            let lActive = lhs.isRunning && lhs.ipv4 != nil
            let rActive = rhs.isRunning && rhs.ipv4 != nil
            if lActive != rActive { return lActive }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.bsdName < rhs.bsdName
        }
    }

    // MARK: - Helpers

    private struct WiFiSnapshot {
        let bsdName: String
        let ssid: String?
        let rssi: Int?
        let band: String?
        let channel: Int?
        let txRate: Double?
    }

    private func currentWiFiInfo() -> WiFiSnapshot? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        guard let bsdName = iface.interfaceName else { return nil }
        let ssid = iface.ssid()      // nil se sem permissão Location ou desconectado
        let rssi = iface.rssiValue() // 0 se desconectado
        let chan = iface.wlanChannel()
        let band: String? = {
            switch chan?.channelBand {
            case .band2GHz: return "2.4 GHz"
            case .band5GHz: return "5 GHz"
            case .band6GHz: return "6 GHz"
            default:        return nil
            }
        }()
        return WiFiSnapshot(
            bsdName: bsdName,
            ssid: ssid,
            rssi: rssi != 0 ? rssi : nil,
            band: band,
            channel: chan?.channelNumber,
            txRate: iface.transmitRate() > 0 ? iface.transmitRate() : nil
        )
    }

    private func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "HaTarim.NetCollector" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = dict["PrimaryInterface"] as? String else {
            return nil
        }
        return primary
    }

    private func refreshFriendlyNames() {
        displayNameCache.removeAll()
        typeCache.removeAll()
        guard let raw = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        for iface in raw {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            displayNameCache[bsd] = name
            // Type via SC
            if let typeRef = SCNetworkInterfaceGetInterfaceType(iface) {
                let typeStr = typeRef as String
                typeCache[bsd] = mapSCType(typeStr, bsdName: bsd)
            } else {
                typeCache[bsd] = classifyByName(bsd)
            }
        }
    }

    private func mapSCType(_ scType: String, bsdName: String) -> InterfaceType {
        // SCNetworkInterface type strings (literais do framework SC)
        switch scType {
        case "IEEE80211": return .wifi
        case "Ethernet":
            if bsdName.hasPrefix("bridge") { return .bridge }
            if bsdName.contains("usb")     { return .usb }
            return .ethernet
        case "PPP", "PPPoE", "Modem":      return .tunnel
        case "FireWire":                   return .firewire
        case "Bridge":                     return .bridge
        case "Bond":                       return .ethernet
        case "VLAN":                       return .virtual
        case "WWAN":                       return .cellular
        default:
            return classifyByName(bsdName)
        }
    }

    private func classifyByName(_ bsd: String) -> InterfaceType {
        if bsd.hasPrefix("en")     { return .ethernet }   // pode ser Wi-Fi (en0) — mas SC sobrescreve
        if bsd.hasPrefix("utun")   { return .tunnel }
        if bsd.hasPrefix("ipsec")  { return .tunnel }
        if bsd.hasPrefix("ppp")    { return .tunnel }
        if bsd.hasPrefix("bridge") { return .bridge }
        if bsd.hasPrefix("awdl")   { return .awdl }
        if bsd.hasPrefix("llw")    { return .awdl }
        if bsd.hasPrefix("anpi")   { return .virtual }
        if bsd.hasPrefix("pdp")    { return .cellular }
        if bsd.hasPrefix("lo")     { return .loopback }
        return .unknown
    }

    private func friendlyByType(name: String, type: InterfaceType) -> String {
        switch type {
        case .wifi:     return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .tunnel:   return "VPN"
        case .bridge:   return "Bridge"
        case .awdl:     return "AWDL"
        case .cellular: return "Cellular"
        case .firewire: return "FireWire"
        case .usb:      return "USB"
        default:        return name
        }
    }
}
