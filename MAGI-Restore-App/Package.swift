// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TPiTermRestore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TPiTermRestore",
            path: "Sources"
        )
    ]
)
