import Foundation

struct PowerSample: Equatable {
    var aneMilliwatts: Double = 0
    var pCpuMilliwatts: Double = 0
    var eCpuMilliwatts: Double = 0
    var gpuMilliwatts: Double = 0
    var dramMilliwatts: Double = 0

    var packageMilliwatts: Double {
        aneMilliwatts + pCpuMilliwatts + eCpuMilliwatts + gpuMilliwatts + dramMilliwatts
    }

    static let zero = PowerSample()
}

final class PowerCollector {
    private let bridge = IOReportBridge.shared
    private var subscription: OpaquePointer?
    private var subscribedChannels: CFMutableDictionary?
    private var lastSample: CFDictionary?
    private var lastSampleTime: TimeInterval?

    private(set) var available: Bool = false

    init() {
        guard bridge.available,
              let copyChannels = bridge.copyChannels,
              let createSubscription = bridge.createSubscription else {
            return
        }

        guard let unmanagedChannels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0) else {
            return
        }
        let channels = unmanagedChannels.takeRetainedValue()

        var subbedUnmanaged: Unmanaged<CFMutableDictionary>? = nil
        guard let sub = createSubscription(nil, channels, &subbedUnmanaged, 0, nil) else {
            return
        }
        guard let subbed = subbedUnmanaged?.takeRetainedValue() else {
            return
        }

        self.subscription = sub
        self.subscribedChannels = subbed
        self.available = true

        // Primer: cria o snapshot inicial sem retornar resultado.
        _ = sample()
    }

    func sample() -> PowerSample? {
        guard available,
              let sub = subscription,
              let subbed = subscribedChannels,
              let createSamples = bridge.createSamples,
              let createSamplesDelta = bridge.createSamplesDelta,
              let iterate = bridge.iterate,
              let getChannelName = bridge.getChannelName,
              let simpleGetInt = bridge.simpleGetInt else {
            return nil
        }

        let now = Date().timeIntervalSince1970
        guard let unmanagedCurrent = createSamples(sub, subbed, nil) else { return nil }
        let current = unmanagedCurrent.takeRetainedValue()

        defer {
            lastSample = current
            lastSampleTime = now
        }

        guard let last = lastSample, let t0 = lastSampleTime else {
            return PowerSample.zero
        }
        let dt = now - t0
        guard dt > 0 else { return PowerSample.zero }

        guard let unmanagedDelta = createSamplesDelta(last, current, nil) else {
            return PowerSample.zero
        }
        let delta = unmanagedDelta.takeRetainedValue()

        let getUnit = bridge.getUnitLabel
        let acc = Accumulator()
        _ = iterate(delta) { (channel: CFDictionary) -> Int32 in
            guard let nameUM = getChannelName(channel) else { return 0 }
            let name = nameUM.takeUnretainedValue() as String
            let raw = Double(simpleGetInt(channel, 0))
            let unit = (getUnit?(channel)?.takeUnretainedValue() as String?) ?? ""

            // Converte energia integrada no intervalo dt para potência em mW.
            // mJ/dt = mW direto; µJ/dt/1000 = mW; nJ/dt/1e6 = mW.
            let mW: Double
            switch unit {
            case "mJ":  mW = raw / dt
            case "uJ":  mW = raw / dt / 1_000
            case "nJ":  mW = raw / dt / 1_000_000
            case "pJ":  mW = raw / dt / 1_000_000_000
            default:    mW = 0   // unidade desconhecida — ignora
            }

            // Match exato: usar APENAS os channels consolidados.
            // Os per-core (ECPU0..N, PCPU0..N) e DTL (DVFS state) são
            // sub-componentes do total — somá-los duplica.
            switch name {
            case "ANE":           acc.ane  += mW
            case "PCPU":          acc.pCpu += mW
            case "ECPU":          acc.eCpu += mW
            case "GPU Energy":    acc.gpu  += mW
            case "DRAM":          acc.dram += mW
            default: break
            }
            return 0  // kIOReportIterOk
        }

        return PowerSample(
            aneMilliwatts: max(0, acc.ane),
            pCpuMilliwatts: max(0, acc.pCpu),
            eCpuMilliwatts: max(0, acc.eCpu),
            gpuMilliwatts: max(0, acc.gpu),
            dramMilliwatts: max(0, acc.dram)
        )
    }

    private final class Accumulator {
        var ane: Double = 0
        var pCpu: Double = 0
        var eCpu: Double = 0
        var gpu: Double = 0
        var dram: Double = 0
    }
}
