// swift-tools-version: 5.9
import PackageDescription

// Standalone `sherlockeq` command-line tool. Deliberately separate from the
// Xcode app project: it shares no app code (only the IPC wire protocol), so it
// can't drag DSP or profile logic into a second copy. Built with
// `dist/build-cli.sh` and embedded into SherlockEQ.app/Contents/Helpers/ at
// release time; also installable on its own via `swift build`.
let package = Package(
    name: "sherlockeq",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "sherlockeq",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
