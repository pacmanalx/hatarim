import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Despacha telemetria pro Arduino HaTarim usando o protocolo v2.
///
/// Cadência sender-controlled (Mac decide quando manda cada token).
/// Cada chamada `tick()`:
///   - manda telemetria (TEMP/CPU/GPU/MEM/DSK/NET_UP/NET_DN) toda vez
///   - manda ECORES + HOST só na primeira vez
///   - manda INFO rotativo a cada `infoIntervalSec`
///   - manda FAN só quando muda + heartbeat a cada `fanHeartbeatSec`
///
/// O `ArduinoBridge.sendCommand()` já garante o gap de 30ms entre comandos
/// (interCommandDelayMs), então aqui só pedimos os comandos em sequência.
final class ArduinoSender {

    private let bridge: ArduinoBridge
    init(bridge: ArduinoBridge) { self.bridge = bridge }

    // MARK: - rotation state
    private let infoIntervalSec: TimeInterval = 3
    // Heartbeat 10s — 6× mais frequente que antes (era 30s) pra dar margem
    // confortável ao watchdog do firmware (60s). Comando FAN é leve (~9 bytes).
    private let fanHeartbeatSec: TimeInterval = 10
    private var lastInfoSentAt: Date = .distantPast
    private var lastFanSentAt: Date = .distantPast
    private var lastFanState: Bool? = nil
    private var lastSeenModeCounter: Int = 0
    private var infoIndex: Int = 0
    private var sentBoot: Bool = false
    private var lastECores: Int = -1

    // MARK: - cache de strings estáticas (CPU brand, GPU label, hostname, macOS)
    private lazy var staticInfos: [String] = [
        cpuBrand().asciiSafe(33),
        gpuLabel().asciiSafe(33),
        macOSVersion().asciiSafe(33)
    ]

    // MARK: - API

    /// Despacha o snapshot atual do SystemStats. Chamado pelo tick() do app.
    /// Cada bridge.sendCommand vira UM arquivo em send_commands/ — daemon
    /// Python processa em ordem (00_ priority antes de 99_ regular).
    func tick(stats: SystemStats) {
        // Gate idle: sem daemon detectado, não despacha NADA. Evita acumular
        // arquivos órfãos no spool em Mac sem Arduino conectado, e também
        // mantém o cache de `lastFanState`/`lastInfoSentAt` "intacto" pra que
        // o primeiro tick após o daemon voltar reenvie tudo.
        if stats.arduino.isIdle {
            // Reset dos caches pra forçar reenvio quando hardware aparecer.
            sentBoot = false
            lastECores = -1
            lastFanState = nil
            lastInfoSentAt = .distantPast
            lastFanSentAt = .distantPast
            return
        }

        let now = Date()

        // 0) FAN priority — quando muda ou heartbeat. Prefixo 00_ no arquivo
        // garante que daemon processa antes de qualquer telemetria pendente.
        if let fc = stats.fanController {
            let desired = fc.fanShouldBeOn
            let stateChanged = (lastFanState != desired)
            let modeChanged = (fc.modeChangeCounter != lastSeenModeCounter)
            let heartbeatDue = now.timeIntervalSince(lastFanSentAt) >= fanHeartbeatSec
            if stateChanged || modeChanged || heartbeatDue {
                let reasonStr = stateChanged ? "stateCh" : (modeChanged ? "modeCh" : "heartbeat")
                FileHandle.standardError.write(Data(
                    "FanCmd: SENDER tick FAN:\(desired ? "1" : "0") reason=\(reasonStr) mode=\(fc.store.config.mode.rawValue)\n".utf8
                ))
                bridge.sendCommandPriority(token: .fan, value: desired ? "1" : "0")
                lastFanState = desired
                lastFanSentAt = now
                lastSeenModeCounter = fc.modeChangeCounter
            }
        }

        // 1) Boot: HOST e ECORES uma vez
        if !sentBoot {
            bridge.sendCommand(token: .host, value: hostname().asciiSafe(33))
            sentBoot = true
        }
        if stats.eCoreCount != lastECores {
            bridge.sendCommand(token: .ecores, value: String(stats.eCoreCount))
            lastECores = stats.eCoreCount
        }

        // 2) Telemetria viva
        bridge.sendCommand(token: .temp, value: String(format: "%.2f", stats.cpuTempC))

        let cores = reorderCoresEcoresFirst(values: stats.perCoreCPU, pCoreCount: stats.pCoreCount)
        let coresCSV = cores.map { String(Int($0.rounded())) }.joined(separator: ",")
        if !coresCSV.isEmpty {
            bridge.sendCommand(token: .cpu, value: coresCSV)
        }

        bridge.sendCommand(token: .gpu, value: String(Int((stats.gpuUtilPercent ?? 0).rounded())))
        bridge.sendCommand(token: .mem, value: String(Int((stats.memory.pressureUsedRatio * 100).rounded())))
        bridge.sendCommand(token: .dsk, value: String(rootDiskUsedPercent()))
        bridge.sendCommand(token: .netUp, value: String(format: "%.2f", stats.net.txBytesPerSec / 1_048_576))
        bridge.sendCommand(token: .netDn, value: String(format: "%.2f", stats.net.rxBytesPerSec / 1_048_576))

        // 3) INFO rotativo a cada 3s
        if now.timeIntervalSince(lastInfoSentAt) >= infoIntervalSec {
            let infos = currentInfoStrings()
            if !infos.isEmpty {
                let s = infos[infoIndex % infos.count]
                bridge.sendCommand(token: .info, value: s)
                infoIndex = (infoIndex + 1) % infos.count
            }
            lastInfoSentAt = now
        }
    }

    // MARK: - construção das info strings rotativas

    private func currentInfoStrings() -> [String] {
        var infos = staticInfos
        infos.append("User: \(userName())".asciiSafe(33))
        if let ip = localIP() {
            infos.append("IP: \(ip)".asciiSafe(33))
        }
        infos.append(ramLabel().asciiSafe(33))
        infos.append(diskLabel().asciiSafe(33))
        infos.append(uptimeLabel().asciiSafe(33))
        infos.append(processCountLabel().asciiSafe(33))
        if let bat = batteryLabel() {
            infos.append(bat.asciiSafe(33))
        }
        return infos
    }

    private func reorderCoresEcoresFirst(values: [Double], pCoreCount: Int) -> [Double] {
        guard pCoreCount > 0, pCoreCount < values.count else { return values }
        let p = Array(values.prefix(pCoreCount))
        let e = Array(values.dropFirst(pCoreCount))
        return e + p
    }

    private func rootDiskUsedPercent() -> Int {
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
           let total = values.volumeTotalCapacity, total > 0 {
            let avail = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let used = Int64(total) - avail
            return Int((Double(used) / Double(total) * 100).rounded())
        }
        return 0
    }

    // MARK: - sysctls e APIs nativas (copiados de PayloadBuilder pra desacoplar)

    private func cpuBrand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "CPU N/A" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func gpuLabel() -> String {
        var label = "Apple GPU"
        var coreCount: Int? = nil
        for service in ["AGXAccelerator", "IOAccelerator"] {
            guard let matching = IOServiceMatching(service) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iter) }
            var entry = IOIteratorNext(iter)
            while entry != 0 {
                defer { IOObjectRelease(entry) }
                let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                if let prop = IORegistryEntrySearchCFProperty(
                    entry, kIOServicePlane, "gpu-core-count" as CFString,
                    kCFAllocatorDefault, opts
                ) {
                    if let n = (prop as? NSNumber)?.intValue { coreCount = n }
                    else if let d = prop as? Data, d.count >= 4 {
                        let v = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                        coreCount = Int(UInt32(littleEndian: v))
                    }
                }
                entry = IOIteratorNext(iter)
            }
        }
        if let n = coreCount, n > 0 { label += " \(n)-core" }
        return label
    }

    private func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private func hostname() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        let h = String(cString: buf)
        if let dot = h.firstIndex(of: ".") {
            return String(h[..<dot])
        }
        return h
    }

    private func userName() -> String { NSUserName() }

    private func localIP() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(start) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("bridge") {
                continue
            }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                &hostBuf, socklen_t(hostBuf.count),
                                nil, 0, NI_NUMERICHOST)
            if r == 0 {
                let ip = String(cString: hostBuf)
                if ip.hasPrefix("127.") { continue }
                return ip
            }
        }
        return nil
    }

    private func ramLabel() -> String {
        let totalGB = Double(memTotal()) / 1_073_741_824
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let used: Double
        if kr == KERN_SUCCESS {
            let bytes = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
            used = Double(bytes) / 1_073_741_824
        } else { used = 0 }
        return String(format: "RAM %.1f / %.0f GB", used, totalGB)
    }

    private func memTotal() -> UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }

    private func diskLabel() -> String {
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
           let total = values.volumeTotalCapacity, total > 0 {
            let avail = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let totalGB = Double(total) / 1_073_741_824
            let freeGB = Double(avail) / 1_073_741_824
            return String(format: "Disco %.0fGB livre / %.0fGB", freeGB, totalGB)
        }
        return "Disco N/A"
    }

    private func uptimeLabel() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &bootTime, &size, nil, 0)
        let elapsed = Int(Date().timeIntervalSince1970) - Int(bootTime.tv_sec)
        let days = elapsed / 86400
        let hours = (elapsed % 86400) / 3600
        let mins = (elapsed % 3600) / 60
        if days > 0 { return "Up \(days)d \(hours)h \(mins)m" }
        return "Up \(hours)h \(mins)m"
    }

    private func processCountLabel() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, 4, nil, &size, nil, 0) != 0 || size == 0 {
            return "? processos"
        }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return "\(n) processos"
    }

    private func batteryLabel() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for src in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard let percent = dict[kIOPSCurrentCapacityKey as String] as? Int else { continue }
            let charging = (dict[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue
            return charging ? "Charging \(percent)%" : "Battery \(percent)%"
        }
        return nil
    }
}

// MARK: - String helpers

private extension String {
    /// Trunca pra no máximo `n` chars; se truncar coloca `+` no fim
    /// (mesmo símbolo que o firmware usa). Remove acentos antes pra ASCII puro.
    func asciiSafe(_ n: Int) -> String {
        // Strip acentos / diacríticos pra caber em ASCII (firmware é ASCII puro)
        let folded = self.folding(options: .diacriticInsensitive, locale: .current)
        // Remove caracteres que podem confundir o parser do protocolo
        let cleaned = folded.unicodeScalars
            .map { sc -> Character in
                let v = sc.value
                if v == 0x0A || v == 0x0D || v == 0x3A || v == 0x3B { return " " } // \n \r : ;
                if v < 0x20 || v > 0x7E { return "?" }
                return Character(sc)
            }
        let asAscii = String(cleaned)
        if asAscii.count <= n { return asAscii }
        return String(asAscii.prefix(n - 1)) + "+"
    }
}
