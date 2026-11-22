// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyExplorer",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyExplorerApp", targets: ["MyExplorer"]),
        .executable(name: "myexplorer", targets: ["ExplorerCLI"]),
        .library(name: "ExplorerCore", targets: ["ExplorerCore"])
    ],
    targets: [
        .target(name: "CArchive", exclude: ["README.md"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "CPDFio", exclude: ["LICENSE", "NOTICE"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("z")]),
        .systemLibrary(name: "CRemovefile"),
        .target(name: "ExplorerCore", dependencies: ["CArchive", "CPDFio", "CRemovefile"]),
        .target(name: "ExplorerClipboard", dependencies: ["ExplorerCore"]),
        .target(name: "ExplorerLocalization", resources: [.process("Resources")]),
        .target(name: "ExplorerAutomation", dependencies: ["ExplorerCore"]),
        .executableTarget(name: "ExplorerCLI", dependencies: ["ExplorerAutomation"]),
        .executableTarget(name: "MyExplorer", dependencies: ["ExplorerCore", "ExplorerClipboard", "ExplorerLocalization", "ExplorerAutomation"]),
        .testTarget(name: "ExplorerAutomationTests", dependencies: ["ExplorerAutomation"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerClipboardTests", dependencies: ["ExplorerClipboard"]),
        .testTarget(name: "ExplorerLocalizationTests", dependencies: ["ExplorerLocalization"])
    ]
)
