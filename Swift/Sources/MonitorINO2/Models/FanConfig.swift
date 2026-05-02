import Foundation

enum FanMode: String, Codable, CaseIterable, Identifiable {
    case alwaysOff
    case alwaysOn
    case pidTPO
    case hysteresis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysOff:  return "Sempre desligada"
        case .alwaysOn:   return "Sempre ligada"
        case .pidTPO:     return "Auto (PID + TPO)"
        case .hysteresis: return "Auto (Histerese)"
        }
    }

    var icon: String {
        switch self {
        case .alwaysOff:  return "power"
        case .alwaysOn:   return "fan.fill"
        case .pidTPO:     return "waveform.path.ecg"
        case .hysteresis: return "thermometer.variable"
        }
    }
}

struct FanConfig: Codable, Equatable {
    var mode: FanMode
    var setpointC: Double
    var kp: Double
    var ki: Double
    var kd: Double
    var cycleTimeMs: Int
    var thermalHardCapC: Double

    // Histerese (legado/alternativa)
    var hystTempOnC: Double
    var hystTempOffC: Double

    init(
        mode: FanMode = .alwaysOn,
        setpointC: Double = 55.0,
        kp: Double = 4.0,
        ki: Double = 0.2,
        kd: Double = 1.0,
        cycleTimeMs: Int = 60_000,
        thermalHardCapC: Double = 90.0,
        hystTempOnC: Double = 70.0,
        hystTempOffC: Double = 60.0
    ) {
        self.mode = mode
        self.setpointC = setpointC
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.cycleTimeMs = cycleTimeMs
        self.thermalHardCapC = thermalHardCapC
        self.hystTempOnC = hystTempOnC
        self.hystTempOffC = hystTempOffC
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode             = try c.decodeIfPresent(FanMode.self, forKey: .mode) ?? .alwaysOn
        setpointC        = try c.decodeIfPresent(Double.self, forKey: .setpointC) ?? 55.0
        kp               = try c.decodeIfPresent(Double.self, forKey: .kp) ?? 4.0
        ki               = try c.decodeIfPresent(Double.self, forKey: .ki) ?? 0.2
        kd               = try c.decodeIfPresent(Double.self, forKey: .kd) ?? 1.0
        cycleTimeMs      = try c.decodeIfPresent(Int.self, forKey: .cycleTimeMs) ?? 60_000
        thermalHardCapC  = try c.decodeIfPresent(Double.self, forKey: .thermalHardCapC) ?? 90.0
        hystTempOnC      = try c.decodeIfPresent(Double.self, forKey: .hystTempOnC) ?? 70.0
        hystTempOffC     = try c.decodeIfPresent(Double.self, forKey: .hystTempOffC) ?? 60.0
    }

    private enum CodingKeys: String, CodingKey {
        case mode, setpointC, kp, ki, kd, cycleTimeMs, thermalHardCapC
        case hystTempOnC, hystTempOffC
    }
}

struct FanHistoryPoint: Equatable {
    let timestamp: Date
    let temperatureC: Double
    let setpointC: Double
    let dutyPct: Double
    let fanOn: Bool
}
