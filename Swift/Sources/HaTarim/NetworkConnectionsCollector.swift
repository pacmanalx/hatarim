import Foundation

struct ListeningPort: Identifiable, Equatable {
    let id: String           // "proc:port:proto"
    let process: String
    let pid: Int
    let port: Int
    let proto: String        // "TCP" / "UDP"
    let bindAddress: String  // "*" (todas interfaces), "127.0.0.1" (loopback), "::1", etc
    let serviceName: String? // "HTTPS", "MySQL", "Ollama" pra portas conhecidas
}

struct OutboundConnection: Identifiable, Equatable {
    let id: String
    let process: String
    let pid: Int
    let remoteHost: String
    let remotePort: Int
    let proto: String
    let serviceName: String?
    let count: Int           // muitos sockets paralelos pro mesmo (proc, host, port)
}

struct RecentConnection: Identifiable, Equatable {
    let id: String              // proc:host:port
    let process: String
    let remoteHost: String      // IP numérico
    let resolvedHostname: String?  // reverse DNS — pode ser nil se não resolveu
    let remotePort: Int
    let serviceName: String?
    let firstSeen: Date
    let lastSeen: Date
    let isActive: Bool          // ainda aparece no lsof atual?
}

final class NetworkConnectionsCollector {
    private var cachedListening: [ListeningPort] = []
    private var cachedOutbound: [OutboundConnection] = []
    private var historyMap: [String: RecentConnection] = [:]
    private var lastSample: Date = .distantPast
    private static let refreshSec: TimeInterval = 2          // mais agressivo pra pegar conexões breves
    private static let historyLimit = 200                    // máximo de entradas mantidas
    private static let historyMaxAge: TimeInterval = 20 * 60 // 20 min — depois disso descarta

    /// Mapeia nomes de processos crípticos do `lsof` pra nomes amigáveis.
    /// Apple/lsof trunca/mostra o nome curto do executável.
    static let processNameMap: [String: String] = [
        "Google":         "Chrome",
        "Google Chrome H": "Chrome Helper",
        "WhatsAp":        "WhatsApp",
        "WhatsAppHelp":   "WhatsApp Helper",
        "Slack Helpe":    "Slack Helper",
        "Code Helpe":     "VSCode Helper",
        "Microsoft":      "MS Office",
        "MicrosoftR":     "MS Remote",
        "iTerm2":         "iTerm",
        "Spotify_Hel":    "Spotify Helper",
        "Brave Brows":    "Brave",
        "BraveBrowse":    "Brave",
        "firefox":        "Firefox",
        "MainThread":     "MainThread",  // identifica processo Java/etc
        "rapportd":       "Apple Continuity",
        "mDNSRespon":     "mDNSResponder",
        "configd":        "System Config",
        "trustd":         "Cert Trust",
        "apsd":           "Apple Push",
        "nsurlsession":   "URLSession",
        "Discord Hel":    "Discord Helper",
        "Telegram":       "Telegram",
        "TelegramH":      "Telegram Helper",
        "ControlCe":      "Control Center",
        "ControlCenter":  "Control Center",
        "sharingd":       "Apple Sharing",
        "AirPlayUIA":     "AirPlay UI",
        "AirPlayXPC":     "AirPlay XPC",
        "bluetoothd":     "Bluetooth",
        "WindowServer":   "WindowServer",
        "loginwindow":    "Login Window",
        "launchd":        "launchd",
        "WhatsApp Hel":   "WhatsApp Helper",
        "Cursor Help":    "Cursor Helper",
        "Cursor":         "Cursor",
        "Code":           "VSCode",
        "ollama":         "Ollama",
        "node":           "Node.js",
        "python3":        "Python 3",
        "python3.1":      "Python 3.x",
        "ruby":           "Ruby",
        "java":           "Java"
    ]

    /// Normaliza nome de processo do lsof pra forma amigável.
    static func friendlyProcessName(_ raw: String) -> String {
        if let mapped = processNameMap[raw] { return mapped }
        // Aplica prefix match pra Helpers do Chrome ("Google Chrome Helper (Renderer)" → "Chrome Helper")
        if raw.hasPrefix("Google Chrome") { return "Chrome Helper" }
        if raw.hasPrefix("Google ")       { return "Chrome" }
        if raw.hasPrefix("Slack ")        { return "Slack" }
        if raw.hasPrefix("Code ")         { return "VSCode" }
        if raw.hasPrefix("Brave ")        { return "Brave" }
        return raw
    }

    /// Verifica se um IP é privado/loopback/link-local — geralmente ruído de processos internos.
    static func isPrivateOrLocalIP(_ ip: String) -> Bool {
        if ip.hasPrefix("127.") { return true }                // IPv4 loopback
        if ip.hasPrefix("10.")  { return true }                // RFC1918 10.0.0.0/8
        if ip.hasPrefix("192.168.") { return true }            // RFC1918 192.168.0.0/16
        if ip.hasPrefix("169.254.") { return true }            // link-local IPv4
        if ip == "::1" || ip == "0.0.0.0" || ip == "*" { return true }
        if ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true } // IPv6 link/local
        // 172.16.0.0 - 172.31.255.255
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), second >= 16, second <= 31 {
                return true
            }
        }
        return false
    }

    /// Mapa de portas conhecidas → nome amigável. Inclui IANA + alguns dev/Apple.
    static let wellKnownPorts: [Int: String] = [
        20: "FTP-data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP",
        53: "DNS", 67: "DHCP", 68: "DHCP", 80: "HTTP", 88: "Kerberos",
        110: "POP3", 123: "NTP", 135: "RPC", 137: "NetBIOS", 139: "NetBIOS",
        143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB",
        465: "SMTPS", 514: "Syslog", 548: "AFP", 587: "SMTP-submit", 631: "IPP",
        636: "LDAPS", 873: "rsync", 989: "FTPS", 990: "FTPS",
        993: "IMAPS", 995: "POP3S",
        1433: "MSSQL", 1521: "Oracle", 1883: "MQTT", 2049: "NFS", 2222: "SSH-alt",
        3000: "HTTP-dev", 3128: "Squid", 3306: "MySQL", 3389: "RDP",
        5000: "AirPlay", 5432: "PostgreSQL", 5500: "VNC", 5508: "MySQL-Eduxe",
        5672: "AMQP", 5900: "VNC", 5901: "VNC", 6379: "Redis", 6443: "k8s-API",
        7000: "AirPlay", 7100: "X11", 8000: "HTTP-dev", 8008: "HTTP-alt",
        8080: "HTTP-alt", 8086: "InfluxDB", 8088: "HTTP-alt", 8443: "HTTPS-alt",
        9000: "HTTP-dev", 9090: "Prometheus", 9092: "Kafka", 9200: "Elasticsearch",
        11211: "memcached", 11434: "Ollama",
        27017: "MongoDB", 27018: "MongoDB",
        50000: "DRDA"
    ]

    /// Força a próxima `sample()` a ignorar o cache e re-executar lsof imediatamente.
    /// Útil após ações que mudam o estado de portas (ex: kill de processo).
    func invalidateCache() {
        lastSample = .distantPast
    }

    func sample() -> (listening: [ListeningPort], outbound: [OutboundConnection], history: [RecentConnection]) {
        let now = Date()
        if now.timeIntervalSince(lastSample) < Self.refreshSec, !cachedListening.isEmpty || !cachedOutbound.isEmpty {
            return (cachedListening, cachedOutbound, sortedHistory())
        }
        lastSample = now

        let raw = runLsof()
        let parsed = parse(raw)
        cachedListening = parsed.listening
        cachedOutbound = parsed.outbound
        updateHistory(currentOutbound: parsed.outbound, now: now)
        return (parsed.listening, parsed.outbound, sortedHistory())
    }

    private func updateHistory(currentOutbound: [OutboundConnection], now: Date) {
        let currentIDs = Set(currentOutbound.map { $0.id })

        // Atualiza/cria entries pras conexões ativas (puxa hostname do cache de DNS)
        for oc in currentOutbound {
            let hostname = DNSResolver.shared.hostname(forIP: oc.remoteHost)
            if let existing = historyMap[oc.id] {
                historyMap[oc.id] = RecentConnection(
                    id: existing.id, process: existing.process,
                    remoteHost: existing.remoteHost,
                    resolvedHostname: hostname ?? existing.resolvedHostname,
                    remotePort: existing.remotePort, serviceName: existing.serviceName,
                    firstSeen: existing.firstSeen, lastSeen: now, isActive: true
                )
            } else {
                historyMap[oc.id] = RecentConnection(
                    id: oc.id, process: oc.process,
                    remoteHost: oc.remoteHost,
                    resolvedHostname: hostname,
                    remotePort: oc.remotePort, serviceName: oc.serviceName,
                    firstSeen: now, lastSeen: now, isActive: true
                )
            }
        }

        // Marca como inativas as que sumiram (ainda mantidas no histórico) +
        // tenta atualizar hostname caso o lookup async tenha resolvido depois
        for (key, entry) in historyMap where !currentIDs.contains(key) {
            let hostname = entry.resolvedHostname
                ?? DNSResolver.shared.hostname(forIP: entry.remoteHost)
            historyMap[key] = RecentConnection(
                id: entry.id, process: entry.process,
                remoteHost: entry.remoteHost,
                resolvedHostname: hostname,
                remotePort: entry.remotePort, serviceName: entry.serviceName,
                firstSeen: entry.firstSeen, lastSeen: entry.lastSeen, isActive: false
            )
        }

        // Descarta entries mais antigas que historyMaxAge (20 min)
        let cutoff = now.addingTimeInterval(-Self.historyMaxAge)
        historyMap = historyMap.filter { _, entry in
            entry.isActive || entry.lastSeen >= cutoff
        }

        // Cap por contagem: mantém só as N mais recentes
        if historyMap.count > Self.historyLimit {
            let toKeep = historyMap.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(Self.historyLimit)
            historyMap = Dictionary(uniqueKeysWithValues: toKeep.map { ($0.id, $0) })
        }
    }

    private func sortedHistory() -> [RecentConnection] {
        historyMap.values.sorted {
            // ativas primeiro, depois por lastSeen desc
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastSeen > $1.lastSeen
        }
    }

    private func runLsof() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-iTCP", "-P", "-n"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `lsof -iTCP -P -n` output:
    /// COMMAND  PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    /// Slack    321 user 30u IPv4 0x... 0t0      TCP  192.168.1.42:54321->1.2.3.4:443 (ESTABLISHED)
    /// nginx    456 user 6u  IPv4 0x... 0t0      TCP  *:80 (LISTEN)
    private func parse(_ raw: String) -> (listening: [ListeningPort], outbound: [OutboundConnection]) {
        var listening: [ListeningPort] = []
        var outboundDict: [String: OutboundConnection] = [:]   // key = "proc:host:port"

        for (idx, line) in raw.split(separator: "\n").enumerated() {
            if idx == 0 { continue } // header
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { continue }
            let command = String(fields[0])
            let pid = Int(fields[1]) ?? 0
            let proto = String(fields[7])  // TCP, UDP
            // NAME pode ter espaços (ex: "192.168.1.42:54321->1.2.3.4:443 (ESTABLISHED)")
            let nameField = fields[8...].joined(separator: " ")

            // Detecta estado: LISTEN ou ESTABLISHED
            if nameField.contains("(LISTEN)") {
                if let lp = parseListening(name: nameField, command: command, pid: pid, proto: proto) {
                    listening.append(lp)
                }
            } else if nameField.contains("(ESTABLISHED)") {
                if let oc = parseOutbound(name: nameField, command: command, pid: pid, proto: proto) {
                    let key = "\(command):\(oc.remoteHost):\(oc.remotePort)"
                    if let existing = outboundDict[key] {
                        outboundDict[key] = OutboundConnection(
                            id: existing.id, process: existing.process, pid: existing.pid,
                            remoteHost: existing.remoteHost, remotePort: existing.remotePort,
                            proto: existing.proto, serviceName: existing.serviceName,
                            count: existing.count + 1
                        )
                    } else {
                        outboundDict[key] = oc
                    }
                }
            }
        }

        // Dedup listening por (process, port) — mesma porta às vezes aparece em IPv4+IPv6
        var listenSeen = Set<String>()
        let listenDedup = listening.filter { lp in
            let k = "\(lp.process):\(lp.port):\(lp.proto)"
            if listenSeen.contains(k) { return false }
            listenSeen.insert(k); return true
        }.sorted { $0.port < $1.port }

        let outboundList = outboundDict.values.sorted {
            if $0.process != $1.process { return $0.process < $1.process }
            return $0.remotePort < $1.remotePort
        }

        return (listenDedup, outboundList)
    }

    /// "*:8080 (LISTEN)" ou "127.0.0.1:5432 (LISTEN)" ou "[::1]:631 (LISTEN)"
    private func parseListening(name: String, command: String, pid: Int, proto: String) -> ListeningPort? {
        let cleaned = name.replacingOccurrences(of: " (LISTEN)", with: "")
        guard let (host, port) = splitHostPort(cleaned) else { return nil }
        let friendlyCommand = Self.friendlyProcessName(command)
        return ListeningPort(
            id: "\(friendlyCommand):\(port):\(proto)",
            process: friendlyCommand,
            pid: pid,
            port: port,
            proto: proto,
            bindAddress: host.isEmpty ? "*" : host,
            serviceName: Self.wellKnownPorts[port]
        )
    }

    /// "192.168.1.42:54321->1.2.3.4:443 (ESTABLISHED)"
    /// NÃO filtra IPs locais aqui — a UI decide via toggle. Mantém todos visíveis.
    private func parseOutbound(name: String, command: String, pid: Int, proto: String) -> OutboundConnection? {
        let cleaned = name.replacingOccurrences(of: " (ESTABLISHED)", with: "")
        let parts = cleaned.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        guard let (rhost, rport) = splitHostPort(parts[1]) else { return nil }
        let friendlyCommand = Self.friendlyProcessName(command)
        return OutboundConnection(
            id: "\(friendlyCommand):\(rhost):\(rport)",
            process: friendlyCommand,
            pid: pid,
            remoteHost: rhost,
            remotePort: rport,
            proto: proto,
            serviceName: Self.wellKnownPorts[rport],
            count: 1
        )
    }

    /// Aceita "host:port", "*:port", "[ipv6]:port"
    private func splitHostPort(_ s: String) -> (host: String, port: Int)? {
        if s.hasPrefix("[") {
            // IPv6: [::1]:631
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        guard let port = Int(s[s.index(after: colon)...]) else { return nil }
        return (host, port)
    }
}
