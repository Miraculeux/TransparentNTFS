# TransparentNTFS

A native macOS app + background daemon that **transparently mounts NTFS
volumes read/write** on plug-in, using **macFUSE** + **ntfs-3g**.

When a disk is attached, macOS first mounts NTFS volumes read-only.
TransparentNTFS watches Disk Arbitration events, detects NTFS, unmounts
the read-only mount, and immediately re-mounts the same device through
`ntfs-3g` so Finder shows it as a normal read/write volume — no manual
steps, no Terminal.

A small menu-bar app shows daemon status and currently managed volumes.

---

## Architecture

```
┌────────────────────────────┐        ┌─────────────────────────────┐
│  TransparentNTFS.app       │        │  transparent-ntfsd          │
│  (menu bar, LSUIElement)   │  GUI   │  (LaunchDaemon, runs as root)│
│                            │ ─────▶ │                             │
│  • Lists NTFS mounts       │        │  • Disk Arbitration session │
│  • Start/stop daemon       │        │  • Detects NTFS volumes     │
│    via launchctl + sudo    │        │  • Unmounts RO mount        │
└────────────────────────────┘        │  • Re-mounts via ntfs-3g    │
                                      └────────────┬────────────────┘
                                                   │
                                                   ▼
                                       /opt/homebrew/bin/ntfs-3g
                                       (macFUSE + ntfs-3g)
```

The daemon must run as **root** because `mount`/`umount` and the FUSE
device require it. That's why it is installed as a `LaunchDaemon` in
`/Library/LaunchDaemons`. The GUI app does **not** require root and runs
as a regular menu-bar utility.

---

## Requirements

- macOS 12 or later (Apple Silicon or Intel)
- Xcode command line tools: `xcode-select --install`
- [macFUSE](https://osxfuse.github.io/) — install via:
  ```sh
  brew install --cask macfuse
  ```
  After install, allow the system extension in **System Settings → Privacy & Security**, then reboot.
- `ntfs-3g` for macOS — easiest source is the maintained Homebrew tap:
  ```sh
  brew tap gromgit/fuse
  brew install gromgit/fuse/ntfs-3g-mac
  ```

The daemon searches the following locations for `ntfs-3g`:

```
/opt/homebrew/{bin,sbin}/ntfs-3g
/usr/local/{bin,sbin}/ntfs-3g
/opt/local/{bin,sbin}/ntfs-3g
/usr/{sbin,sbin}/ntfs-3g
```

---

## Build & install

```sh
git clone <this repo>
cd TransparentNTFS
./scripts/install.sh
open /Applications/TransparentNTFS.app
```

The installer will:

1. `swift build -c release` both targets.
2. Copy `transparent-ntfsd` to `/usr/local/libexec/`.
3. Install `io.transparentntfs.daemon.plist` to `/Library/LaunchDaemons/`.
4. `launchctl load -w` the daemon (starts now, and on every boot).
5. Bundle the GUI binary into `/Applications/TransparentNTFS.app`.

Logs: `/var/log/transparent-ntfsd.log`.

### Manual build (without the installer)

```sh
swift build -c release
sudo cp .build/release/transparent-ntfsd /usr/local/libexec/
sudo cp launchd/io.transparentntfs.daemon.plist /Library/LaunchDaemons/
sudo launchctl load -w /Library/LaunchDaemons/io.transparentntfs.daemon.plist
```

---

## Uninstall

```sh
./scripts/uninstall.sh
```

---

## How it works (details)

1. The daemon creates a `DASession` and registers
   `DiskAppeared`, `DiskDescriptionChanged`, and `DiskDisappeared` callbacks.
2. On each event it inspects `DADiskCopyDescription` for
   `DAVolumeKind == "ntfs"`. If the volume kind isn't reported (some sticks
   identify only as "Microsoft Basic Data"), it sniffs the first 11 bytes of
   `/dev/r<bsd>` and checks the NTFS OEM ID at offset 3.
3. If NTFS and currently mounted, it runs:
   ```
   diskutil unmount force /dev/<bsd>
   ntfs-3g /dev/<bsd> /Volumes/<name> \
       -o rw,auto_xattr,windows_names,local,allow_other,noatime,volname=<name>
   ```
4. If `ntfs-3g` fails (e.g. dirty NTFS journal), the daemon rolls back by
   asking `diskutil` to remount the volume as it was, and logs the error.
5. State is tracked per BSD name so a single physical insert is only
   processed once.

---

## Caveats

- Apple's signed system extension policy means **macFUSE must be approved
  manually once** in *Privacy & Security* before any FUSE mount can succeed.
- A volume left dirty by Windows (fast-startup / hibernation) will be refused
  read/write by `ntfs-3g`. Boot Windows and shut down cleanly, or run
  `ntfsfix /dev/diskNsM` first.
- This project deliberately uses a LaunchDaemon rather than `SMJobBless` to
  keep the build dependency-free and easily inspectable.
- The GUI uses `osascript … with administrator privileges` to ask for the
  password when starting/stopping the daemon. Plain `launchctl list` works
  without a password.

---

## Project layout

```
TransparentNTFS/
├── Package.swift
├── Sources/
│   ├── Daemon/main.swift          # transparent-ntfsd
│   └── App/main.swift             # TransparentNTFS.app (menu bar)
├── launchd/
│   └── io.transparentntfs.daemon.plist
└── scripts/
    ├── install.sh
    └── uninstall.sh
```

---

## License

MIT.
