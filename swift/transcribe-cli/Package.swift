// swift-tools-version:5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlistPath = "\(packageDir)/Info.plist"

let package = Package(
    name: "transcribe-cli",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "transcribe-cli",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        )
    ]
)
