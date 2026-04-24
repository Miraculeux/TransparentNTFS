import AppKit
import Foundation

// MARK: - Helpers

@discardableResult
func sh(_ launch: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct NTFSMount {
    let device: String
    let mountPoint: String
    let mode: String   // "rw" or "ro"
    let viaNTFS3G: Bool
}

func listNTFSMounts() -> [NTFSMount] {
    let (_, out) = sh("/sbin/mount", [])
    var result: [NTFSMount] = []
    for line in out.split(separator: "\n") {
        let s = String(line)
        // Examples:
        //   /dev/disk4s1 on /Volumes/Data (ntfs, local, nodev, nosuid, read-only, noowners)
        //   /dev/disk4s1 on /Volumes/Data (macfuse, local, nodev, nosuid, synchronous, mounted by root)
        let lower = s.lowercased()
        let isNTFS = lower.contains("(ntfs") || lower.contains(" ntfs,") || lower.contains("macfuse") || lower.contains("fuse")
        guard isNTFS else { continue }
        // crude parse
        let parts = s.components(separatedBy: " on ")
        guard parts.count == 2 else { continue }
        let device = parts[0]
        let rest = parts[1]
        guard let parenIdx = rest.firstIndex(of: "(") else { continue }
        let mountPoint = String(rest[..<parenIdx]).trimmingCharacters(in: .whitespaces)
        let opts = rest[rest.index(after: parenIdx)...].dropLast()
        let mode = opts.contains("read-only") ? "ro" : "rw"
        let viaFuse = opts.lowercased().contains("macfuse") || opts.lowercased().contains("fuse")
        // Only keep if it is plausibly NTFS — skip pure macFUSE entries that aren't NTFS by checking device path heuristics is tricky;
        // for a status bar this list is fine.
        result.append(NTFSMount(device: device, mountPoint: mountPoint, mode: mode, viaNTFS3G: viaFuse))
    }
    return result
}

// MARK: - Daemon control

enum DaemonControl {
    static let label = "io.transparentntfs.daemon"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func isRunning() -> Bool {
        let (_, out) = sh("/bin/launchctl", ["list"])
        return out.split(separator: "\n").contains { $0.contains(label) }
    }

    static func start() {
        _ = sh("/usr/bin/osascript", [
            "-e",
            "do shell script \"/bin/launchctl load -w \(plistPath)\" with administrator privileges"
        ])
    }

    static func stop() {
        _ = sh("/usr/bin/osascript", [
            "-e",
            "do shell script \"/bin/launchctl unload -w \(plistPath)\" with administrator privileges"
        ])
    }
}

// MARK: - Status item

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "NTFS"
            button.toolTip = "TransparentNTFS"
        }
        rebuildMenu()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    @objc private func rebuildMenuAction() { rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()
        let running = DaemonControl.isRunning()
        let installed = DaemonControl.isInstalled()

        let header = NSMenuItem(
            title: installed ? (running ? "Daemon: running" : "Daemon: stopped") : "Daemon: not installed",
            action: nil, keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let mounts = listNTFSMounts()
        if mounts.isEmpty {
            let none = NSMenuItem(title: "No NTFS volumes mounted", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for m in mounts {
                let badge = m.viaNTFS3G ? "RW" : (m.mode == "rw" ? "rw" : "RO")
                let item = NSMenuItem(
                    title: "[\(badge)] \(m.mountPoint)  —  \(m.device)",
                    action: #selector(revealMount(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = m.mountPoint
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        if installed {
            let toggle = NSMenuItem(
                title: running ? "Stop Daemon…" : "Start Daemon…",
                action: running ? #selector(stopDaemon) : #selector(startDaemon),
                keyEquivalent: ""
            )
            toggle.target = self
            menu.addItem(toggle)
        } else {
            let install = NSMenuItem(title: "Daemon not installed (run install.sh)", action: nil, keyEquivalent: "")
            install.isEnabled = false
            menu.addItem(install)
        }

        let refresh = NSMenuItem(title: "Refresh", action: #selector(rebuildMenuAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit TransparentNTFS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func revealMount(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc private func startDaemon() {
        DaemonControl.start()
        rebuildMenu()
    }

    @objc private func stopDaemon() {
        DaemonControl.stop()
        rebuildMenu()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
app.run()
