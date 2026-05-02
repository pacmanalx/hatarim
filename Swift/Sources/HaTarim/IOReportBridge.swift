import Foundation
import Darwin

/// Bridge para o IOReport.framework (Private). Carregado via dlopen
/// para evitar linker flags hack contra `/System/Library/PrivateFrameworks`.
final class IOReportBridge {
    static let shared = IOReportBridge()

    typealias CopyChannelsFn = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?

    typealias CreateSubscriptionFn = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> OpaquePointer?

    typealias CreateSamplesFn = @convention(c) (
        OpaquePointer, CFMutableDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?

    typealias CreateSamplesDeltaFn = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?

    typealias IterateBlock = @convention(block) (CFDictionary) -> Int32
    typealias IterateFn = @convention(c) (CFDictionary, IterateBlock) -> Int32

    typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias GetIntFn = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannels: CopyChannelsFn?
    let createSubscription: CreateSubscriptionFn?
    let createSamples: CreateSamplesFn?
    let createSamplesDelta: CreateSamplesDeltaFn?
    let iterate: IterateFn?
    let getChannelName: GetStringFn?
    let getGroup: GetStringFn?
    let getUnitLabel: GetStringFn?
    let simpleGetInt: GetIntFn?

    var available: Bool {
        copyChannels != nil
            && createSubscription != nil
            && createSamples != nil
            && createSamplesDelta != nil
            && iterate != nil
            && getChannelName != nil
            && simpleGetInt != nil
    }

    private init() {
        // macOS 26+ expõe via /usr/lib/libIOReport.dylib;
        // versões anteriores usam o framework privado.
        let candidates = [
            "/usr/lib/libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport"
        ]
        var handle: UnsafeMutableRawPointer? = nil
        for path in candidates {
            if let h = dlopen(path, RTLD_LAZY) {
                handle = h
                break
            }
        }
        guard let handle = handle else {
            self.copyChannels = nil
            self.createSubscription = nil
            self.createSamples = nil
            self.createSamplesDelta = nil
            self.iterate = nil
            self.getChannelName = nil
            self.getGroup = nil
            self.getUnitLabel = nil
            self.simpleGetInt = nil
            return
        }
        func sym<T>(_ name: String, as: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        self.copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self)
        self.createSubscription = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self)
        self.createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self)
        self.createSamplesDelta = sym("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self)
        self.iterate = sym("IOReportIterate", as: IterateFn.self)
        self.getChannelName = sym("IOReportChannelGetChannelName", as: GetStringFn.self)
        self.getGroup = sym("IOReportChannelGetGroup", as: GetStringFn.self)
        self.getUnitLabel = sym("IOReportChannelGetUnitLabel", as: GetStringFn.self)
        self.simpleGetInt = sym("IOReportSimpleGetIntegerValue", as: GetIntFn.self)
    }
}
