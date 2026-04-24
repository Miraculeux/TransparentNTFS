import Foundation
import DiskArbitration

// MARK: - Logging

enum Log {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) {
        FileHandle.standardOutput.write(Data("[\(dateFormatter.string(from: Date()))] [INFO]  \(msg)\n".utf8))
    }

    static func warn(_ msg: String) {
        FileHandle.standardError.write(Data("[\(dateFormatter.string(from: Date()))] [WARN]  \(msg)\n".utf8))
    }

    static func error(_ msg: String) {
        FileHandle.standardError.write(Data("[\(dateFormatter.string(from: Date()))] [ERROR] \(msg)\n".utf8))
    }
}

// MARK: - Configuration

struct Config {
    /// Candidate locations for the ntfs-3g binary (Homebrew on Apple Silicon, Intel, MacPorts, manual).
    static let ntfs3gCandidates = [
        "/opt/homebrew/bin/ntfs-3g",
        "/opt/homebrew/sbin/ntfs-3g",
        "/usr/local/bin/ntfs-3g",
        "/usr/local/sbin/ntfs-3g",
        "/opt/local/bin/ntfs-3g",
        "/opt/local/sbin/ntfs-3g",
        "/usr/sbin/ntfs-3g",
        "/sbin/ntfs-3g",
    ]

    /// Mount root for ntfs-3g remounts. Each volume becomes /Volumes/<name>.
    static let mountRoot = "/Volumes"

    static func locateNtfs3g() -> String? {
        for path in ntfs3gCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

// MARK: - Shell helpers

@discardableResult
func runProcess(_ launchPath: String, _ args: [String], env: [String: String]? = nil) -> (status: Int32, stdout: String, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let env = env { p.environment = env }
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return (-1, "", "failed to launch \(launchPath): \(error)")
    }
    p.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

// MARK: - NTFS Auto-Mount Manager

final class NTFSAutoMounter {
    private let session: DASession
    /// Disks we're currently in the middle of remounting, keyed by BSD name (e.g. "disk4s1").
    private var inFlight = Set<String>()
    /// Disks we have remounted via ntfs-3g, keyed by BSD name.
    private var managed = Set<String>()
    private let queue = DispatchQueue(label: "io.transparentntfs.daemon", qos: .utility)

    init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            Log.error("DASessionCreate failed")
            return nil
        }
        self.session = session
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // Disk appeared (e.g. drive plugged in)
        DARegisterDiskAppearedCallback(session, nil, { (disk, ctx) in
            guard let ctx = ctx else { return }
            let mounter = Unmanaged<NTFSAutoMounter>.fromOpaque(ctx).takeUnretainedValue()
            mounter.handleDiskEvent(disk: disk, reason: "appeared")
        }, ctx)

        // Disk description changed (e.g. it just got mounted)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { (disk, _, ctx) in
            guard let ctx = ctx else { return }
            let mounter = Unmanaged<NTFSAutoMounter>.fromOpaque(ctx).takeUnretainedValue()
            mounter.handleDiskEvent(disk: disk, reason: "changed")
        }, ctx)

        // Disk disappeared (cleanup tracking)
        DARegisterDiskDisappearedCallback(session, nil, { (disk, ctx) in
            guard let ctx = ctx else { return }
            let mounter = Unmanaged<NTFSAutoMounter>.fromOpaque(ctx).takeUnretainedValue()
            mounter.handleDisappear(disk: disk)
        }, ctx)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        Log.info("TransparentNTFS daemon started; watching for NTFS volumes…")
    }

    private func handleDisappear(disk: DADisk) {
        guard let bsd = bsdName(of: disk) else { return }
        queue.async { [weak self] in
            self?.managed.remove(bsd)
            self?.inFlight.remove(bsd)
        }
    }

    private func handleDiskEvent(disk: DADisk, reason: String) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        guard let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return }

        // Filter: must be NTFS
        let kind = desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? ""
        let typeStr = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let isNTFS = kind.lowercased().contains("ntfs") || typeStr == "Microsoft Basic Data" && volumeAppearsNTFS(bsd: bsd)
        guard isNTFS else { return }

        // Filter: must currently be mounted (we react after macOS mounts it RO).
        guard let volPath = (desc[kDADiskDescriptionVolumePathKey as String] as? URL)?.path,
              !volPath.isEmpty else {
            return
        }

        let volName = (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? bsd

        queue.async { [weak self] in
            guard let self = self else { return }
            if self.managed.contains(bsd) || self.inFlight.contains(bsd) {
                return
            }
            self.inFlight.insert(bsd)
            Log.info("Detected NTFS volume \"\(volName)\" on /dev/\(bsd) at \(volPath) (\(reason)); switching to read/write…")
            self.remountReadWrite(bsd: bsd, currentMount: volPath, volumeName: volName)
            self.inFlight.remove(bsd)
        }
    }

    /// Best-effort sniff: read 8 bytes at offset 3 of the raw partition for the "NTFS    " OEM ID.
    private func volumeAppearsNTFS(bsd: String) -> Bool {
        let path = "/dev/r\(bsd)"
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: 3)
            let data = try fh.read(upToCount: 8) ?? Data()
            return String(data: data, encoding: .ascii)?.hasPrefix("NTFS") ?? false
        } catch {
            return false
        }
    }

    private func bsdName(of disk: DADisk) -> String? {
        guard let cstr = DADiskGetBSDName(disk) else { return nil }
        return String(cString: cstr)
    }

    private func remountReadWrite(bsd: String, currentMount: String, volumeName: String) {
        guard let ntfs3g = Config.locateNtfs3g() else {
            Log.error("ntfs-3g not found. Install macFUSE + ntfs-3g (e.g. `brew install --cask macfuse` then `brew install gromgit/fuse/ntfs-3g-mac`).")
            return
        }

        // 1. Unmount the macOS read-only mount via diskutil (handles APFS/CoreStorage edge cases too).
        let umount = runProcess("/usr/sbin/diskutil", ["unmount", "force", "/dev/\(bsd)"])
        if umount.status != 0 {
            Log.warn("diskutil unmount /dev/\(bsd) exited \(umount.status): \(umount.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Try direct umount as a fallback.
            let alt = runProcess("/sbin/umount", ["-f", currentMount])
            if alt.status != 0 {
                Log.error("Failed to unmount /dev/\(bsd); aborting remount.")
                return
            }
        }

        // 2. Build a fresh mount point.
        let mountPoint = uniqueMountPoint(for: volumeName)
        do {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            Log.error("Failed to create mount point \(mountPoint): \(error)")
            return
        }

        // 3. Mount via ntfs-3g read/write. `local` makes Finder show it normally.
        //    `auto_xattr` enables xattr translation; `windows_names` keeps filenames Windows-safe.
        let args = [
            "/dev/\(bsd)",
            mountPoint,
            "-o", "rw,auto_xattr,windows_names,local,allow_other,noatime,volname=\(volumeName)"
        ]
        let mount = runProcess(ntfs3g, args, env: ProcessInfo.processInfo.environment)
        if mount.status == 0 {
            managed.insert(bsd)
            Log.info("Mounted /dev/\(bsd) read/write at \(mountPoint)")
        } else {
            Log.error("ntfs-3g failed (\(mount.status)) for /dev/\(bsd): \(mount.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Roll back: ask diskutil to remount the volume read-only as before.
            _ = runProcess("/usr/sbin/diskutil", ["mount", "/dev/\(bsd)"])
            try? FileManager.default.removeItem(atPath: mountPoint)
        }
    }

    private func uniqueMountPoint(for name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        var candidate = "\(Config.mountRoot)/\(safe)"
        var i = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(Config.mountRoot)/\(safe) \(i)"
            i += 1
            if i > 99 { break }
        }
        return candidate
    }
}

// MARK: - Entry point

guard getuid() == 0 else {
    Log.error("transparent-ntfsd must run as root (mount/unmount require it). Install it as a LaunchDaemon — see README.")
    exit(EXIT_FAILURE)
}

guard let mounter = NTFSAutoMounter() else {
    exit(EXIT_FAILURE)
}
mounter.start()

// Run forever on the main run loop.
CFRunLoopRun()
