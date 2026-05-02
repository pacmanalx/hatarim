import Foundation
import IOKit

final class GPUCollector {
    private(set) var coreCount: Int? = nil

    init() {
        coreCount = readCoreCount()
    }

    func sample() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = unmanagedProps?.takeRetainedValue() as? [String: Any],
               let perf = props["PerformanceStatistics"] as? [String: Any] {
                if let util = perf["Device Utilization %"] as? Double {
                    return util
                }
                if let util = perf["Device Utilization %"] as? Int {
                    return Double(util)
                }
                if let util = perf["GPU Activity(%)"] as? Int {
                    return Double(util)
                }
            }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    private func readCoreCount() -> Int? {
        for service in ["AGXAccelerator", "IOAccelerator"] {
            guard let matching = IOServiceMatching(service) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                defer { IOObjectRelease(entry) }
                let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                if let prop = IORegistryEntrySearchCFProperty(
                    entry,
                    kIOServicePlane,
                    "gpu-core-count" as CFString,
                    kCFAllocatorDefault,
                    opts
                ) {
                    let any = prop as Any
                    if let n = any as? Int { return n }
                    if let n = any as? NSNumber { return n.intValue }
                    if let data = any as? Data, data.count >= 4 {
                        let val = data.withUnsafeBytes { $0.load(as: UInt32.self) }
                        return Int(UInt32(littleEndian: val))
                    }
                }
                entry = IOIteratorNext(iterator)
            }
        }
        return nil
    }
}
