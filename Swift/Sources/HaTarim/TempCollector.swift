import Foundation
import Darwin
import CoreFoundation

/// Coleta temperatura agregada (CPU/SoC) via IOHIDEventSystemClient SPI.
/// Mesma técnica usada por asitop/macmon. Sem sudo.
final class TempCollector {
    private typealias CreateClientFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias ServiceCopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventGetFloatFn = @convention(c) (OpaquePointer, UInt32) -> Double

    private let createClient: CreateClientFn?
    private let setMatching: SetMatchingFn?
    private let copyServices: CopyServicesFn?
    private let copyProperty: ServiceCopyPropertyFn?
    private let copyEvent: ServiceCopyEventFn?
    private let getFloat: EventGetFloatFn?

    private let client: OpaquePointer?
    private(set) var available: Bool = false

    private static let kIOHIDEventTypeTemperature: Int64 = 15

    init() {
        // IOKit é público mas as funções IOHIDEventSystem* são SPI.
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func sym<T>(_ name: String, as: T.Type) -> T? {
            guard let h = handle, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        self.createClient   = sym("IOHIDEventSystemClientCreate",      as: CreateClientFn.self)
        self.setMatching    = sym("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
        self.copyServices   = sym("IOHIDEventSystemClientCopyServices",as: CopyServicesFn.self)
        self.copyProperty   = sym("IOHIDServiceClientCopyProperty",    as: ServiceCopyPropertyFn.self)
        self.copyEvent      = sym("IOHIDServiceClientCopyEvent",       as: ServiceCopyEventFn.self)
        self.getFloat       = sym("IOHIDEventGetFloatValue",           as: EventGetFloatFn.self)

        guard let createClient,
              let setMatching,
              copyServices != nil,
              copyEvent != nil,
              getFloat != nil,
              let c = createClient(kCFAllocatorDefault) else {
            self.client = nil
            return
        }

        // Match temperature sensors: PrimaryUsagePage=0xFF00, PrimaryUsage=5
        let dict: [CFString: Any] = [
            "PrimaryUsagePage" as CFString: 0xFF00,
            "PrimaryUsage" as CFString: 5
        ]
        setMatching(c, dict as CFDictionary)

        self.client = c
        self.available = true
    }

    struct Reading {
        var cpuC: Double = 0
        var gpuC: Double = 0
    }

    /// Retorna média de temperaturas (°C) separadas por subsistema.
    /// CPU/SoC: sensores com nome contendo "soc"/"acc"/"pmgr".
    /// GPU: sensores com "gpu" no nome.
    func sample() -> Reading {
        guard available,
              let client,
              let copyServices,
              let copyEvent,
              let getFloat else { return Reading() }

        guard let unmanagedServices = copyServices(client) else { return Reading() }
        let services = unmanagedServices.takeRetainedValue() as Array

        var cpuTemps: [Double] = []
        var gpuTemps: [Double] = []

        for svc in services {
            let ptr = OpaquePointer(Unmanaged.passUnretained(svc as AnyObject).toOpaque())
            var lower = ""
            if let copyProperty,
               let nameRef = copyProperty(ptr, "Product" as CFString) {
                lower = ((nameRef.takeRetainedValue() as? String) ?? "").lowercased()
            }
            let isCPU = lower.contains("soc") || lower.contains("acc") || lower.contains("pmgr")
            let isGPU = lower.contains("gpu")
            guard isCPU || isGPU else { continue }
            guard let unmanagedEvt = copyEvent(ptr, Self.kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let evtPtr = OpaquePointer(unmanagedEvt.toOpaque())
            let temp = getFloat(evtPtr, UInt32(Self.kIOHIDEventTypeTemperature << 16))
            unmanagedEvt.release()
            guard temp > 0, temp < 150 else { continue }
            if isGPU {
                gpuTemps.append(temp)
            } else {
                cpuTemps.append(temp)
            }
        }

        func avg(_ xs: [Double]) -> Double {
            guard !xs.isEmpty else { return 0 }
            return (xs.reduce(0, +) / Double(xs.count) * 10).rounded() / 10
        }
        return Reading(cpuC: avg(cpuTemps), gpuC: avg(gpuTemps))
    }
}
