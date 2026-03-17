// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MAGIRestore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MAGIRestore",
            path: "Sources"
        )
    ]
)
