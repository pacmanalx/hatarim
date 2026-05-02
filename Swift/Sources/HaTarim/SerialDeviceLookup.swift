import Foundation
import IOKit
import IOKit.serial

struct SerialDeviceInfo: Equatable {
    let path: String
    let vendorID: Int?
    let productID: Int?
    let usbVendorName: String?
    let usbProductName: String?

    /// Nome legível pra exibição. Priorida USB Product Name (vem do device).
    /// Senão tenta mapping conhecido VID:PID. Senão genérico.
    var friendlyName: String {
        if let p = usbProductName, !p.isEmpty { return p }
        if let vid = vendorID, let pid = productID {
            switch (vid, pid) {
            // Arduino LLC (0x2341)
            case (0x2341, 0x0042): return "Arduino Mega 2560 R3"
            case (0x2341, 0x0010): return "Arduino Mega 2560"
            case (0x2341, 0x0043): return "Arduino Uno R3"
            case (0x2341, 0x0001): return "Arduino Uno"
            case (0x2341, 0x0036): return "Arduino Leonardo"
            case (0x2341, 0x8036): return "Arduino Leonardo"
            case (0x2341, 0x0037): return "Arduino Micro"
            case (0x2341, _):      return String(format: "Arduino %04X", pid)
            // SparkFun (0x1B4F)
            case (0x1B4F, _):      return String(format: "SparkFun %04X", pid)
            // Adafruit (0x239A)
            case (0x239A, _):      return String(format: "Adafruit %04X", pid)
            // CH340 / WCH (clones)
            case (0x1A86, 0x7523): return "USB-Serial (CH340)"
            case (0x1A86, 0x55D4): return "USB-Serial (CH9102)"
            // Silicon Labs CP210x
            case (0x10C4, 0xEA60): return "USB-Serial (CP2102)"
            case (0x10C4, _):      return "USB-Serial (CP210x)"
            // FTDI
            case (0x0403, _):      return "USB-Serial (FTDI)"
            default:
                return String(format: "USB %04X:%04X", vid, pid)
            }
        }
        return "Serial device"
    }

    var vidPidString: String? {
        guard let v = vendorID, let p = productID else { return nil }
        return String(format: "%04X:%04X", v, p)
    }
}

enum SerialDeviceLookup {
    /// Resolve metadados USB pro device dado um path tipo `/dev/cu.usbmodem11101`.
    static func info(forPath path: String) -> SerialDeviceInfo? {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else {
            return SerialDeviceInfo(path: path, vendorID: nil, productID: nil,
                                    usbVendorName: nil, usbProductName: nil)
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return SerialDeviceInfo(path: path, vendorID: nil, productID: nil,
                                    usbVendorName: nil, usbProductName: nil)
        }
        defer { IOObjectRelease(iterator) }

        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            // O device serial expõe IOCalloutDevice (= /dev/cu.*) e IODialinDevice (= /dev/tty.*)
            let calloutPath = readStringProperty(entry, key: "IOCalloutDevice")
            if calloutPath == path {
                let vid = readIntProperty(entry, key: "idVendor", recursive: true)
                let pid = readIntProperty(entry, key: "idProduct", recursive: true)
                let vname = readStringProperty(entry, key: "USB Vendor Name", recursive: true)
                let pname = readStringProperty(entry, key: "USB Product Name", recursive: true)
                return SerialDeviceInfo(
                    path: path,
                    vendorID: vid,
                    productID: pid,
                    usbVendorName: vname,
                    usbProductName: pname
                )
            }
            entry = IOIteratorNext(iterator)
        }
        return SerialDeviceInfo(path: path, vendorID: nil, productID: nil,
                                usbVendorName: nil, usbProductName: nil)
    }

    private static func readStringProperty(_ entry: io_object_t, key: String, recursive: Bool = false) -> String? {
        let cf: CFTypeRef?
        if recursive {
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            cf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts)
        } else {
            cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return cf as? String
    }

    private static func readIntProperty(_ entry: io_object_t, key: String, recursive: Bool = false) -> Int? {
        let cf: CFTypeRef?
        if recursive {
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            cf = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts)
        } else {
            cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if let n = cf as? NSNumber { return n.intValue }
        return nil
    }
}
