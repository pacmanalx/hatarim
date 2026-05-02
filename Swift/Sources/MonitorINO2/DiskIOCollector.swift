import Foundation
import IOKit

struct DiskIORate: Equatable {
    var readBytesPerSec: Double
    var writeBytesPerSec: Double
}

struct DiskIOSnapshot {
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var timestamp: Date
}

enum DeviceClass: String, Equatable {
    case internalDisk
    case external
    case network
}

final class DiskIOCollector {
    private var lastSnapshots: [String: DiskIOSnapshot] = [:]
    private(set) var deviceClasses: [String: DeviceClass] = [:]
    private(set) var deviceInterconnects: [String: String] = [:]   // "USB", "Apple Fabric", "Thunderbolt"…

    /// Retorna read/write bytes per sec por BSD device pai (ex: "disk0", "disk3", "disk5").
    func sample() -> [String: DiskIORate] {
        var rates: [String: DiskIORate] = [:]
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return rates }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return rates
        }
        defer { IOObjectRelease(iter) }

        let now = Date()
        var current: [String: DiskIOSnapshot] = [:]

        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }

            // BSD Name vive numa entrada filha (IOMedia) — busca recursiva
            guard let bsdName = IORegistryEntrySearchCFProperty(
                svc,
                kIOServicePlane,
                "BSD Name" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)
            ) as? String else { continue }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }

            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            let snap = DiskIOSnapshot(bytesRead: read, bytesWritten: write, timestamp: now)
            current[bsdName] = snap

            // Classifica device via "Physical Interconnect Location" — vive numa entrada PAI
            // (storage controller), não no IOMedia. Valores: "Internal" / "External".
            if deviceClasses[bsdName] == nil {
                let location = IORegistryEntrySearchCFProperty(
                    svc,
                    kIOServicePlane,
                    "Physical Interconnect Location" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                ) as? String
                if let loc = location {
                    deviceClasses[bsdName] = (loc == "Internal") ? .internalDisk : .external
                    // Interconnect também vive como propriedade no parent
                    if let proto = IORegistryEntrySearchCFProperty(
                        svc,
                        kIOServicePlane,
                        "Physical Interconnect" as CFString,
                        kCFAllocatorDefault,
                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                    ) as? String {
                        deviceInterconnects[bsdName] = proto
                    }
                } else {
                    // Fallback: Removable=true certamente é externo (CD/SD/etc); senão assume interno
                    let removable = (IORegistryEntrySearchCFProperty(
                        svc,
                        kIOServicePlane,
                        "Removable" as CFString,
                        kCFAllocatorDefault,
                        IOOptionBits(kIORegistryIterateRecursively)
                    ) as? Bool) ?? false
                    deviceClasses[bsdName] = removable ? .external : .internalDisk
                }
            }

            if let prev = lastSnapshots[bsdName] {
                let dt = now.timeIntervalSince(prev.timestamp)
                if dt > 0 {
                    let dr = read >= prev.bytesRead ? Double(read - prev.bytesRead) / dt : 0
                    let dw = write >= prev.bytesWritten ? Double(write - prev.bytesWritten) / dt : 0
                    rates[bsdName] = DiskIORate(readBytesPerSec: dr, writeBytesPerSec: dw)
                }
            }
        }
        lastSnapshots = current
        return rates
    }
}
