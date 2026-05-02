import Foundation
import Darwin
import IOKit.ps
import CoreGraphics

struct TopMemProc: Equatable {
    var name: String
    var rssBytes: UInt64
}

struct SystemInfoSample: Equatable {
    var loadAvg1: Double = 0
    var loadAvg5: Double = 0
    var loadAvg15: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var uptimeSec: Double = 0
    var processCount: Int = 0
    var userIdleSec: Double = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var topProcessName: String = ""
    var topProcessCPU: Double = 0
    var topMemProcesses: [TopMemProc] = []
    var batteryPercent: Double?    // nil se não tem bateria (ex: Mac mini/Studio)
    var onAC: Bool = true
    var batteryTimeRemainingMin: Int?  // nil se calculando ou n/a
}

final class SystemInfoCollector {
    private var topTickCounter = 0
    private var cachedTopName = ""
    private var cachedTopCPU = 0.0
    private var cachedTopMem: [TopMemProc] = []
    private static let topRefreshEveryNTicks = 5  // ~5s a cada 1s tick
    private static let topMemLimit = 30            // coleta até 30 — UI decide quantos mostrar

    func sample() -> SystemInfoSample {
        var s = SystemInfoSample()

        // 1. Load average
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            s.loadAvg1 = loads[0]
            s.loadAvg5 = loads[1]
            s.loadAvg15 = loads[2]
        }

        // 2. Thermal state
        s.thermalState = ProcessInfo.processInfo.thermalState

        // 3. Uptime via kern.boottime
        var bt = timeval()
        var btSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bt, &btSize, nil, 0) == 0 {
            s.uptimeSec = Date().timeIntervalSince1970 - Double(bt.tv_sec)
        }

        // 4. Process count via proc_listallpids
        let count = proc_listallpids(nil, 0)
        if count > 0 { s.processCount = Int(count) }

        // 5. User idle via CGEventSource (combinedSessionState = HID + system)
        // ~0 (UInt32 max) = "any event type"
        let anyEvent = CGEventType(rawValue: ~UInt32(0)) ?? .null
        s.userIdleSec = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)

        // 6. Swap usage
        var swap = xsw_usage()
        var swSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swSize, nil, 0) == 0 {
            s.swapUsedBytes = swap.xsu_used
            s.swapTotalBytes = swap.xsu_total
        }

        // 7. Top processo — throttle 5x (caro, spawn de ps)
        topTickCounter += 1
        if topTickCounter >= Self.topRefreshEveryNTicks || cachedTopName.isEmpty {
            topTickCounter = 0
            if let top = scanTopProcess() {
                cachedTopName = top.name
                cachedTopCPU = top.cpu
            }
            cachedTopMem = scanTopMemoryProcesses(limit: Self.topMemLimit)
        }
        s.topProcessName = cachedTopName
        s.topProcessCPU = cachedTopCPU
        s.topMemProcesses = cachedTopMem

        // 8. Battery + AC via IOPS
        readBattery(into: &s)

        return s
    }

    /// `ps -A -o "%cpu,comm" -r` (sort by cpu desc), pega top não-kernel.
    private func scanTopProcess() -> (name: String, cpu: Double)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-A", "-o", "%cpu=,comm=", "-r"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        for raw in str.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let cpuStr = line[..<space].trimmingCharacters(in: .whitespaces)
            guard let cpu = Double(cpuStr), cpu > 0 else { continue }
            var name = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            // basename do path do executável
            if let slash = name.lastIndex(of: "/") {
                name = String(name[name.index(after: slash)...])
            }
            // ignorar o próprio HaTarim e processo "ps"
            if name == "HaTarim" || name == "ps" { continue }
            return (name, cpu)
        }
        return nil
    }

    /// `ps -A -o "rss,comm" -m` (sort by memory desc). RSS em KB.
    private func scanTopMemoryProcesses(limit: Int) -> [TopMemProc] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-A", "-o", "rss=,comm=", "-m"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8) else { return [] }

        var result: [TopMemProc] = []
        for raw in str.split(separator: "\n") {
            if result.count >= limit { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let rssStr = line[..<space].trimmingCharacters(in: .whitespaces)
            guard let rssKB = UInt64(rssStr), rssKB > 0 else { continue }
            var name = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if let slash = name.lastIndex(of: "/") {
                name = String(name[name.index(after: slash)...])
            }
            if name == "ps" { continue }
            result.append(TopMemProc(name: name, rssBytes: rssKB * 1024))
        }
        return result
    }

    private func readBattery(into s: inout SystemInfoSample) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            s.batteryPercent = nil
            s.onAC = true
            return
        }

        for src in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cur = dict[kIOPSCurrentCapacityKey] as? Int,
               let mx = dict[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                s.batteryPercent = Double(cur) / Double(mx) * 100
            }
            if let st = dict[kIOPSPowerSourceStateKey] as? String {
                s.onAC = (st == kIOPSACPowerValue)
            }
            if let tr = dict[kIOPSTimeToEmptyKey] as? Int, tr > 0 {
                s.batteryTimeRemainingMin = tr
            } else if let tf = dict[kIOPSTimeToFullChargeKey] as? Int, tf > 0 {
                s.batteryTimeRemainingMin = tf
            }
        }
    }
}
