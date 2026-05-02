import Foundation
import SwiftUI

enum HealthStatus: String, Codable {
    case unknown
    case ok
    case degraded
    case fail
    case timeout
    case disabled

    var color: Color {
        switch self {
        case .ok:       return .green
        case .degraded: return .yellow
        case .fail:     return .red
        case .timeout:  return .orange
        case .unknown:  return .gray
        case .disabled: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok:       return "🟢"
        case .degraded: return "🟡"
        case .fail:     return "🔴"
        case .timeout:  return "🟠"
        case .unknown:  return "⚪️"
        case .disabled: return "⚫️"
        }
    }
}

struct HealthSample: Codable, Equatable {
    let timestamp: Date
    let status: HealthStatus
    let latencyMs: Int?
    let detail: String?
}

final class HealthHistory {
    private(set) var samples: [HealthSample] = []
    let capacity: Int

    init(capacity: Int = 240) {
        self.capacity = capacity
    }

    func append(_ sample: HealthSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    var latest: HealthSample? { samples.last }

    var uptimePct: Double? {
        guard !samples.isEmpty else { return nil }
        let ok = samples.filter { $0.status == .ok }.count
        return Double(ok) / Double(samples.count) * 100
    }
}
