import Foundation
import Darwin

struct VolumeInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let bsdDevice: String           // "disk3s5", "//user@host/share", "—"
    let purgeableBytes: Int64       // diferença entre forImportantUsage e availableCapacity
    let fsType: String              // "APFS", "exFAT", "MS-DOS (FAT32)", "SMB"…

    var freeRatio: Double {
        totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0
    }

    /// Parent block device ("disk3s5" → "disk3"). Para network mounts ou nomes não-disk, retorna o nome inteiro.
    var parentDevice: String {
        guard bsdDevice.hasPrefix("disk") else { return bsdDevice }
        var idx = bsdDevice.index(bsdDevice.startIndex, offsetBy: 4)
        while idx < bsdDevice.endIndex, bsdDevice[idx].isNumber {
            idx = bsdDevice.index(after: idx)
        }
        return String(bsdDevice[..<idx])
    }
}

final class DiskCollector {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeIsBrowsableKey,
        .volumeLocalizedFormatDescriptionKey
    ]

    func sample() -> [VolumeInfo] {
        let fm = FileManager.default
        guard let urls = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var out: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0 else {
                continue
            }
            // Real free space (não inclui purgeable). Bug fix vs forImportantUsage.
            let availReal = Int64(values.volumeAvailableCapacity ?? 0)
            let availImportant = values.volumeAvailableCapacityForImportantUsage ?? availReal
            let purgeable = max(0, availImportant - availReal)

            let name = values.volumeName ?? url.lastPathComponent
            let dev = Self.bsdDevice(forPath: url.path) ?? "—"
            let fsType = Self.shortFSType(values.volumeLocalizedFormatDescription ?? "")

            out.append(VolumeInfo(
                id: url.path,
                name: name,
                totalBytes: Int64(total),
                availableBytes: availReal,
                bsdDevice: dev,
                purgeableBytes: purgeable,
                fsType: fsType
            ))
        }
        // Ordena por % usado desc (volumes apertados sobem ao topo)
        return out.sorted { (1 - $0.freeRatio) > (1 - $1.freeRatio) }
    }

    /// Encurta o nome reportado pelo macOS pra formas compactas usadas em UI.
    /// Ex: "Mac OS Extended (Journaled)" → "HFS+", "MS-DOS (FAT32)" → "FAT32".
    private static func shortFSType(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("apfs") { return "APFS" }
        if r.contains("mac os extended") { return "HFS+" }
        if r.contains("exfat") { return "exFAT" }
        if r.contains("fat32") { return "FAT32" }
        if r.contains("ms-dos") || r.contains("fat") { return "FAT" }
        if r.contains("ntfs") { return "NTFS" }
        if r.contains("smb") { return "SMB" }
        if r.contains("afp") { return "AFP" }
        if r.contains("nfs") { return "NFS" }
        return raw.isEmpty ? "?" : raw
    }

    private static func bsdDevice(forPath path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let raw: String = withUnsafePointer(to: &st.f_mntfromname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if raw.hasPrefix("/dev/") {
            return String(raw.dropFirst("/dev/".count))
        }
        return raw
    }
}
