import Foundation
import Darwin

struct MemorySample {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var freeBytes: UInt64
    var pressureUsedRatio: Double

    static let zero = MemorySample(
        totalBytes: 0, usedBytes: 0, wiredBytes: 0,
        compressedBytes: 0, freeBytes: 0, pressureUsedRatio: 0
    )
}

final class MemoryCollector {
    private let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    private let total: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()

    func sample() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reb, &count)
            }
        }

        guard kr == KERN_SUCCESS else {
            return MemorySample(
                totalBytes: total, usedBytes: 0, wiredBytes: 0,
                compressedBytes: 0, freeBytes: total, pressureUsedRatio: 0
            )
        }

        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        let used = active + wired + compressed
        let ratio = total > 0 ? Double(used) / Double(total) : 0

        return MemorySample(
            totalBytes: total,
            usedBytes: used,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            pressureUsedRatio: ratio
        )
    }
}
