// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TransparentNTFS",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "transparent-ntfsd", targets: ["TransparentNTFSDaemon"]),
        .executable(name: "TransparentNTFS", targets: ["TransparentNTFSApp"]),
    ],
    targets: [
        .executableTarget(
            name: "TransparentNTFSDaemon",
            path: "Sources/Daemon",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "TransparentNTFSApp",
            path: "Sources/App",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
