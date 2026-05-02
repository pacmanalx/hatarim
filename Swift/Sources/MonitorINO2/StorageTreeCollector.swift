import Foundation
import IOKit

/// Nó da árvore de armazenamento. Pode ser controller (raiz), hub USB, ou storage device.
struct StorageTreeNode: Identifiable, Equatable {
    let id: UInt64                    // IORegistry entry ID — único e estável
    enum Kind: String, Equatable {
        case host                     // a própria máquina (raiz da árvore)
        case controller               // USB controller, Apple Fabric, Thunderbolt host
        case hub                      // hub USB intermediário
        case storage                  // disco
    }
    let kind: Kind
    let name: String                  // texto principal pra UI
    let detail: String                // subtitle: "USB 3.0", "5 Gbps", etc
    let bsdDevice: String?            // "disk6" se storage
    let totalBytes: Int64?            // capacidade se storage
    let portNumber: Int?              // posição na porta do pai
    let locationID: String?           // hex location ID (encoda caminho físico)
    var children: [StorageTreeNode]
}

final class StorageTreeCollector {

    func sample() -> [StorageTreeNode] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        // Coleta um path por disco: array de "passos relevantes" do leaf ao root.
        var paths: [[PathStep]] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            let path = buildPath(from: svc)
            if !path.isEmpty { paths.append(path) }
        }

        return mergePaths(paths)
    }

    // MARK: - Path building

    private struct PathStep {
        let entryID: UInt64
        let kind: StorageTreeNode.Kind?      // nil = passo intermediário, descartar na árvore
        let className: String
        let props: [String: Any]
        let bsdName: String?
        let totalBytes: Int64?
    }

    private func buildPath(from leaf: io_object_t) -> [PathStep] {
        var steps: [PathStep] = []
        var current: io_object_t = leaf
        IOObjectRetain(current)

        var leafBSD: String?
        var leafSize: Int64?
        var safetyHops = 0

        while current != 0, safetyHops < 32 {
            safetyHops += 1
            let className = classNameOf(current)

            // BSD Name e Size só existem em IOMedia (filho do IOBlockStorageDriver)
            // Se este passo é IOBlockStorageDriver, pega o IOMedia filho whole=true
            if leafBSD == nil, className == "IOBlockStorageDriver" {
                if let media = findChildIOMediaWhole(current) {
                    leafBSD = readString(media, key: "BSD Name")
                    leafSize = readInt64(media, key: "Size")
                    IOObjectRelease(media)
                }
            }

            let entryID = entryIDOf(current)
            let props = readProperties(current)
            let kind = classifyKind(className: className, props: props)

            // Anota o storage no nó "leaf" do path (primeiro IOBlockStorageDriver visto)
            if kind == .storage, leafBSD == nil {
                leafBSD = readString(current, key: "BSD Name")
            }

            steps.append(PathStep(
                entryID: entryID,
                kind: kind,
                className: className,
                props: props,
                bsdName: kind == .storage ? leafBSD : nil,
                totalBytes: kind == .storage ? leafSize : nil
            ))

            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS {
                IOObjectRelease(current)
                break
            }
            IOObjectRelease(current)
            current = parent
        }
        if current != 0 { IOObjectRelease(current) }

        // Retém só passos com kind != nil (descarta intermediários sem interesse)
        return steps.filter { $0.kind != nil }
    }

    private func classifyKind(className: String, props: [String: Any]?) -> StorageTreeNode.Kind? {
        if className == "IOBlockStorageDriver" { return .storage }

        // USB hubs têm bDeviceClass == 9
        if className == "IOUSBHostDevice" || className == "IOUSBDevice" {
            if let p = props, let bClass = (p["bDeviceClass"] as? NSNumber)?.intValue, bClass == 9 {
                return .hub
            }
            return nil  // device USB intermediário (storage embaixo já foi capturado)
        }

        // USB Controllers — match amplo: AppleT8103USBXHCI, IOUSBHostController, AppleUSBXHCI etc
        if className.contains("XHCI") || className == "IOUSBHostController" || className == "IOUSBController" {
            return .controller
        }
        // NVMe interno em Apple Silicon (Apple Fabric)
        if className.contains("AppleANS") || className.contains("AppleEmbeddedNVMe")
            || className.contains("AppleSSD") || className == "AppleANS3Controller" {
            return .controller
        }
        return nil
    }

    // MARK: - Merge paths into tree

    private func mergePaths(_ paths: [[PathStep]]) -> [StorageTreeNode] {
        // Cada path vem [leaf...root]. Inverte e merge recursivamente.
        var rootList: [StorageTreeNode] = []
        for path in paths {
            let topDown = Array(path.reversed())
            mergeRecursive(topDown, into: &rootList)
        }
        let sorted = sortChildren(rootList)

        // Envolve tudo num nó "host" pra ser a raiz visual
        let host = StorageTreeNode(
            id: 1,                                          // sentinel — não há entryID 1 no IORegistry
            kind: .host,
            name: hostName(),
            detail: hostModel(),
            bsdDevice: nil,
            totalBytes: nil,
            portNumber: nil,
            locationID: nil,
            children: sorted
        )
        return [host]
    }

    private func mergeRecursive(_ steps: [PathStep], into nodes: inout [StorageTreeNode]) {
        guard let head = steps.first else { return }
        let rest = Array(steps.dropFirst())
        if let idx = nodes.firstIndex(where: { $0.id == head.entryID }) {
            mergeRecursive(rest, into: &nodes[idx].children)
        } else {
            var newNode = makeNode(from: head)
            mergeRecursive(rest, into: &newNode.children)
            nodes.append(newNode)
        }
    }

    private func hostName() -> String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            return String(cString: buf)
        }
        return "Mac"
    }

    private func hostModel() -> String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func makeNode(from step: PathStep) -> StorageTreeNode {
        let kind = step.kind ?? .controller
        let p = step.props
        let vendor = (p["USB Vendor Name"] as? String)
            ?? (p["IOName"] as? String)
            ?? (p["Vendor Name"] as? String)
        let product = (p["USB Product Name"] as? String)
            ?? (p["Product Name"] as? String)
        let speed = describeSpeed(props: p, className: step.className)
        // locationID é UInt32 — extrai port do nibble correspondente à profundidade
        // Format: 0x C P 1 2 3 4 5 6 (hex nibbles) — C=controller, P=port, 1-6 hubs
        let locInt = (p["locationID"] as? NSNumber)?.uint64Value ?? 0
        let locID: String? = locInt > 0 ? String(format: "0x%08X", UInt32(locInt & 0xFFFFFFFF)) : nil
        let port = portFromLocationID(UInt32(locInt & 0xFFFFFFFF))

        let name = nodeName(kind: kind, vendor: vendor, product: product, className: step.className, bsd: step.bsdName)
        let detail = nodeDetail(kind: kind, speed: speed, className: step.className)

        return StorageTreeNode(
            id: step.entryID,
            kind: kind,
            name: name,
            detail: detail,
            bsdDevice: step.bsdName,
            totalBytes: step.totalBytes,
            portNumber: port,
            locationID: locID,
            children: []
        )
    }

    private func nodeName(kind: StorageTreeNode.Kind, vendor: String?, product: String?, className: String, bsd: String?) -> String {
        switch kind {
        case .host:
            return "Mac"   // sobrescrito pelo hostName() na construção do host node
        case .storage:
            let p = product ?? "Storage"
            if let b = bsd { return "\(p) (\(b))" }
            return p
        case .hub:
            let parts = [vendor, product].compactMap { $0 }
            return parts.isEmpty ? "USB Hub" : parts.joined(separator: " ")
        case .controller:
            if className.contains("AppleANS") || className.contains("AppleEmbeddedNVMe") {
                return "Apple Fabric (Internal NVMe)"
            }
            if let v = vendor { return v }
            return className
        }
    }

    private func nodeDetail(kind: StorageTreeNode.Kind, speed: String?, className: String) -> String {
        var parts: [String] = []
        if let s = speed { parts.append(s) }
        if kind == .controller, className.contains("XHCI") { parts.append("USB") }
        return parts.joined(separator: " · ")
    }

    /// Extrai o port number do locationID. Procura o último nibble não-zero — esse é a posição
    /// no hub-pai imediato (ou no controller se for direct-attached).
    private func portFromLocationID(_ loc: UInt32) -> Int? {
        guard loc != 0 else { return nil }
        // Caminha pelos 7 nibbles após o controller (CC P1 P2 P3 P4 P5 P6 P7)
        // O último nibble não-zero indica o port no hub mais profundo
        for shift in stride(from: 0, through: 24, by: 4) {
            let nibble = (loc >> UInt32(shift)) & 0xF
            if nibble != 0 {
                return Int(nibble)
            }
        }
        return nil
    }

    private func describeSpeed(props: [String: Any], className: String) -> String? {
        // bcdUSB ou Speed
        if let s = props["Speed"] as? Int {
            switch s {
            case 0: return "USB 1.0 (Low)"
            case 1: return "USB 1.1 (Full)"
            case 2: return "USB 2.0 (High)"
            case 3: return "USB 3.0 (Super)"
            case 4: return "USB 3.1 (Super+)"
            default: return "USB Speed \(s)"
            }
        }
        if let bcd = props["bcdUSB"] as? Int {
            // bcdUSB é 0x0200 pra USB 2.0, 0x0300 pra USB 3.0
            switch bcd {
            case 0x0100: return "USB 1.0"
            case 0x0110: return "USB 1.1"
            case 0x0200: return "USB 2.0"
            case 0x0300: return "USB 3.0"
            case 0x0310: return "USB 3.1"
            case 0x0320: return "USB 3.2"
            default: return nil
            }
        }
        return nil
    }

    private func sortChildren(_ nodes: [StorageTreeNode]) -> [StorageTreeNode] {
        nodes.map { node -> StorageTreeNode in
            var copy = node
            copy.children = sortChildren(copy.children).sorted { lhs, rhs in
                func order(_ k: StorageTreeNode.Kind) -> Int {
                    switch k {
                    case .host: return -1
                    case .controller: return 0
                    case .hub: return 1
                    case .storage: return 2
                    }
                }
                let lo = order(lhs.kind)
                let ro = order(rhs.kind)
                if lo != ro { return lo < ro }
                return lhs.name < rhs.name
            }
            return copy
        }
    }

    // MARK: - IOKit helpers

    private func classNameOf(_ entry: io_object_t) -> String {
        var className = io_name_t(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                                  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                                  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                                  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        IOObjectGetClass(entry, &className)
        return withUnsafePointer(to: &className) {
            $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
    }

    private func entryIDOf(_ entry: io_object_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private func readProperties(_ entry: io_object_t) -> [String: Any] {
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return [:]
        }
        return (ref?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    private func readString(_ entry: io_object_t, key: String) -> String? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively)) as? String
    }

    private func readInt64(_ entry: io_object_t, key: String) -> Int64? {
        guard let n = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber else {
            return nil
        }
        return n.int64Value
    }

    private func findChildIOMediaWhole(_ parent: io_object_t) -> io_object_t? {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        while case let child = IOIteratorNext(iter), child != 0 {
            let cls = classNameOf(child)
            if cls == "IOMedia" {
                // Verifica Whole = true
                if let whole = IORegistryEntryCreateCFProperty(child, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool, whole {
                    return child
                }
            }
            IOObjectRelease(child)
        }
        return nil
    }
}
