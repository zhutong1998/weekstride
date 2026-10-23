// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeekStride",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkLedgerCore", targets: ["WorkLedgerCore"]),
        .executable(name: "WeekStrideDev", targets: ["WorkLedger"]),
    ],
    targets: [
        .target(name: "WorkLedgerCore"),
        .executableTarget(name: "WorkLedger", dependencies: ["WorkLedgerCore"], resources: [.process("Resources")]),
        .testTarget(name: "WorkLedgerCoreTests", dependencies: ["WorkLedgerCore"]),
        .testTarget(name: "LocalAPITests", dependencies: ["WorkLedger", "WorkLedgerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
