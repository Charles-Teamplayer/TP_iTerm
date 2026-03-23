// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TPiTermRestore",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TPiTermRestore",
            path: "Sources"
        )
    ]
)
