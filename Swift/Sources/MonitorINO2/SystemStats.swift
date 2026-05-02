import Foundation
import Combine
import Darwin

final class SystemStats: ObservableObject {
    @Published var perCoreCPU: [Double] = []
    @Published var pCoreCount: Int = 0
    @Published var eCoreCount: Int = 0

    @Published var gpuUtilPercent: Double? = nil
    @Published var gpuCoreCount: Int? = nil

    @Published var memory: MemorySample = .zero
    @Published var net: NetSample = .zero
    @Published var interfaces: [InterfaceInfo] = []
    @Published var listeningPorts: [ListeningPort] = []
    @Published var outboundConnections: [OutboundConnection] = []
    @Published var recentConnections: [RecentConnection] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var diskIORates: [String: DiskIORate] = [:]
    @Published var diskIOHistory: [String: [DiskIOHistoryPoint]] = [:]
    @Published var deviceClasses: [String: DeviceClass] = [:]
    @Published var deviceInterconnects: [String: String] = [:]
    @Published var storageTree: [StorageTreeNode] = []

    @Published var power: PowerSample = .zero
    @Published var powerAvailable: Bool = false

    @Published var netHistory: [NetHistoryPoint] = []
    @Published var gpuHistory: [GPUHistoryPoint] = []
    @Published var powerHistory: [PowerHistoryPoint] = []
    @Published var memoryHistory: [MemoryHistoryPoint] = []
    @Published var tempHistory: [TempHistoryPoint] = []
    @Published var overallHistory: [OverallHistoryPoint] = []
    private var lastHistoryTime: Date = .distantPast
    private static let historyIntervalSec: TimeInterval = 10
    private static let historyCapacity: Int = 60   // 10 min em janela 10s

    /// Temperatura corrente (°C). Usada pelo FanController e pelo PayloadBuilder.
    @Published var cpuTempC: Double = 0
    @Published var gpuTempC: Double = 0
    /// FanController opcional — quando setado, decide F:0/F:1 no payload.
    weak var fanController: FanController?

    let arduino = ArduinoBridge()
    private lazy var arduinoSender = ArduinoSender(bridge: arduino)

    @Published var lastTickTime: Date = Date()
    @Published var refreshInterval: Double = 2.0 {
        didSet {
            guard refreshInterval != oldValue else { return }
            restartTimer()
        }
    }

    static let availableIntervals: [Double] = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 15.0, 30.0, 60.0]

    private let cpu = CPUCollector()
    private let gpu = GPUCollector()
    private let mem = MemoryCollector()
    private let netCol = NetworkCollector()
    private let ifaceCol = NetworkInterfaceCollector()
    private let connsCol = NetworkConnectionsCollector()
    private let disk = DiskCollector()
    private let diskIO = DiskIOCollector()
    private let storageTreeCol = StorageTreeCollector()
    private var storageTreeTickCounter = 0
    private static let storageTreeRefreshEveryNTicks = 10  // ~10s a cada 1s tick
    private let powerCol = PowerCollector()
    private let tempCol = TempCollector()
    private let sysInfoCol = SystemInfoCollector()
    @Published var systemInfo: SystemInfoSample = SystemInfoSample()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        pCoreCount = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        eCoreCount = Self.sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        gpuCoreCount = gpu.coreCount
        powerAvailable = powerCol.available

        // primer pra zerar deltas (descarta a primeira leitura)
        _ = cpu.sample()
        _ = netCol.sample()

        // propaga mudanças do ArduinoBridge pra a UI que observa SystemStats
        arduino.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tick()
        restartTimer()
    }

    deinit { timer?.invalidate() }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let cpuVals = cpu.sample()
        let gpuVal = gpu.sample()
        let memVal = mem.sample()
        let netVal = netCol.sample()
        let ifacesVal = ifaceCol.sample()
        let connsVal = connsCol.sample()
        let diskVal = disk.sample()
        let diskIORatesVal = diskIO.sample()

        // Storage tree: coleta cara, throttle 10x
        var storageTreeVal: [StorageTreeNode]? = nil
        storageTreeTickCounter += 1
        if storageTreeTickCounter >= Self.storageTreeRefreshEveryNTicks || storageTree.isEmpty {
            storageTreeTickCounter = 0
            storageTreeVal = storageTreeCol.sample()
        }
        let powerVal = powerCol.sample()
        let tempVal = tempCol.sample()
        let sysInfoVal = sysInfoCol.sample()

        DispatchQueue.main.async {
            self.lastTickTime = Date()
            self.perCoreCPU = cpuVals
            self.gpuUtilPercent = gpuVal
            self.memory = memVal
            self.net = netVal
            self.interfaces = ifacesVal
            self.listeningPorts = connsVal.listening
            self.outboundConnections = connsVal.outbound
            self.recentConnections = connsVal.history
            self.volumes = diskVal
            self.diskIORates = diskIORatesVal
            self.deviceClasses = self.diskIO.deviceClasses
            self.deviceInterconnects = self.diskIO.deviceInterconnects
            if let tree = storageTreeVal { self.storageTree = tree }
            self.cpuTempC = tempVal.cpuC
            self.gpuTempC = tempVal.gpuC
            self.systemInfo = sysInfoVal
            if let p = powerVal { self.power = p }
            // Atualiza decisão da FAN com temperatura corrente (CPU/SoC).
            self.fanController?.update(temperatureC: tempVal.cpuC)

            // Histórico pra sparklines — append a cada N segundos, ring buffer.
            let now = Date()
            if now.timeIntervalSince(self.lastHistoryTime) >= Self.historyIntervalSec {
                self.lastHistoryTime = now
                self.netHistory.append(NetHistoryPoint(timestamp: now,
                                                      rxBytesPerSec: netVal.rxBytesPerSec,
                                                      txBytesPerSec: netVal.txBytesPerSec))
                self.gpuHistory.append(GPUHistoryPoint(timestamp: now,
                                                      utilPercent: gpuVal ?? 0))
                self.memoryHistory.append(MemoryHistoryPoint(
                    timestamp: now,
                    usedPercent: memVal.pressureUsedRatio * 100,
                    wiredPercent: memVal.totalBytes > 0 ? Double(memVal.wiredBytes) / Double(memVal.totalBytes) * 100 : 0,
                    compressedPercent: memVal.totalBytes > 0 ? Double(memVal.compressedBytes) / Double(memVal.totalBytes) * 100 : 0
                ))
                if let p = powerVal {
                    self.powerHistory.append(PowerHistoryPoint(
                        timestamp: now,
                        packageMilliwatts: p.packageMilliwatts,
                        pCpuMilliwatts: p.pCpuMilliwatts,
                        eCpuMilliwatts: p.eCpuMilliwatts,
                        gpuMilliwatts: p.gpuMilliwatts,
                        aneMilliwatts: p.aneMilliwatts,
                        dramMilliwatts: p.dramMilliwatts
                    ))
                }
                if tempVal.cpuC > 0 || tempVal.gpuC > 0 {
                    self.tempHistory.append(TempHistoryPoint(
                        timestamp: now,
                        celsius: tempVal.cpuC,
                        gpuC: tempVal.gpuC
                    ))
                }
                self.overallHistory.append(OverallHistoryPoint(
                    timestamp: now,
                    cpuPct: self.cpuAverage,
                    gpuPct: gpuVal ?? 0,
                    memPct: memVal.pressureUsedRatio * 100
                ))
                // Histórico per-device de I/O
                let activeDevices = Set(diskVal.map { $0.parentDevice })
                for dev in activeDevices {
                    let r = diskIORatesVal[dev]?.readBytesPerSec ?? 0
                    let w = diskIORatesVal[dev]?.writeBytesPerSec ?? 0
                    var arr = self.diskIOHistory[dev] ?? []
                    arr.append(DiskIOHistoryPoint(timestamp: now, readBytesPerSec: r, writeBytesPerSec: w))
                    if arr.count > Self.historyCapacity { arr.removeFirst(arr.count - Self.historyCapacity) }
                    self.diskIOHistory[dev] = arr
                }
                // Limpa histórico de devices que sumiram (volumes desmontados)
                for stale in self.diskIOHistory.keys where !activeDevices.contains(stale) {
                    self.diskIOHistory.removeValue(forKey: stale)
                }
                let cap = Self.historyCapacity
                if self.netHistory.count > cap { self.netHistory.removeFirst(self.netHistory.count - cap) }
                if self.gpuHistory.count > cap { self.gpuHistory.removeFirst(self.gpuHistory.count - cap) }
                if self.powerHistory.count > cap { self.powerHistory.removeFirst(self.powerHistory.count - cap) }
                if self.memoryHistory.count > cap { self.memoryHistory.removeFirst(self.memoryHistory.count - cap) }
                if self.tempHistory.count > cap { self.tempHistory.removeFirst(self.tempHistory.count - cap) }
                if self.overallHistory.count > cap { self.overallHistory.removeFirst(self.overallHistory.count - cap) }
            }

            // Despacha telemetria via daemon Python (ArduinoBridge escreve
            // arquivos em send_commands/, daemon despacha pra serial).
            self.arduinoSender.tick(stats: self)
        }
    }

    var cpuAverage: Double {
        guard !perCoreCPU.isEmpty else { return 0 }
        return perCoreCPU.reduce(0, +) / Double(perCoreCPU.count)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value: Int = 0
        var len = size
        guard sysctlbyname(name, &value, &len, nil, 0) == 0 else { return nil }
        return value
    }
}

struct NetHistoryPoint: Equatable {
    let timestamp: Date
    let rxBytesPerSec: Double
    let txBytesPerSec: Double
}

struct DiskIOHistoryPoint: Equatable {
    let timestamp: Date
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
}

struct GPUHistoryPoint: Equatable {
    let timestamp: Date
    let utilPercent: Double
}

struct PowerHistoryPoint: Equatable {
    let timestamp: Date
    let packageMilliwatts: Double
    let pCpuMilliwatts: Double
    let eCpuMilliwatts: Double
    let gpuMilliwatts: Double
    let aneMilliwatts: Double
    let dramMilliwatts: Double
}

struct MemoryHistoryPoint: Equatable {
    let timestamp: Date
    let usedPercent: Double
    let wiredPercent: Double
    let compressedPercent: Double
}

struct TempHistoryPoint: Equatable {
    let timestamp: Date
    let celsius: Double   // CPU/SoC (compat: campo existente)
    let gpuC: Double
}

struct OverallHistoryPoint: Equatable {
    let timestamp: Date
    let cpuPct: Double
    let gpuPct: Double
    let memPct: Double
    var busyPct: Double { (cpuPct + gpuPct + memPct) / 3 }
}

enum Platform {
    static var isAppleSilicon: Bool {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let r = sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0)
        return r == 0 && ret == 1
    }
}
