import Foundation
import Darwin

final class CPUCollector {
    private var prev: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []

    func sample() -> [Double] {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &info,
            &infoCount
        )
        guard kr == KERN_SUCCESS, let cpuInfo = info else { return prev.map { _ in 0 } }

        defer {
            let address = vm_address_t(UInt(bitPattern: cpuInfo))
            vm_deallocate(
                mach_task_self_,
                address,
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [(UInt32, UInt32, UInt32, UInt32)] = []
        current.reserveCapacity(Int(numCPUs))

        for i in 0..<Int(numCPUs) {
            let base = i * stride
            let user = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])
            current.append((user, system, idle, nice))
        }

        defer { prev = current }

        guard prev.count == current.count else {
            return Array(repeating: 0, count: current.count)
        }

        return current.enumerated().map { index, c in
            let p = prev[index]
            let dUser = c.0 &- p.0
            let dSystem = c.1 &- p.1
            let dIdle = c.2 &- p.2
            let dNice = c.3 &- p.3
            let total = UInt64(dUser) + UInt64(dSystem) + UInt64(dIdle) + UInt64(dNice)
            guard total > 0 else { return 0 }
            let busy = UInt64(dUser) + UInt64(dSystem) + UInt64(dNice)
            return Double(busy) / Double(total) * 100.0
        }
    }
}
