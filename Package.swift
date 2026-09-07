// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nido",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Nido", targets: ["Nido"]),
        .library(name: "NidoAWS", targets: ["NidoAWS"]),
        .library(name: "NidoSchema", targets: ["NidoSchema"]),
        .executable(name: "nido", targets: ["NidoCLI"]),
        .executable(name: "nido-example", targets: ["BasicExample"]),
        .executable(name: "nido-aws-example", targets: ["AWSExample"]),
        .executable(name: "nido-architecture-example", targets: ["ArchitectureExample"]),
    ],
    targets: [
        .target(name: "Nido"),
        .target(name: "NidoAWS", dependencies: ["Nido"]),
        .target(name: "NidoSchema", dependencies: ["Nido"]),
        .executableTarget(name: "NidoCLI", dependencies: ["Nido", "NidoSchema"]),
        .executableTarget(name: "BasicExample", dependencies: ["Nido"], path: "Examples/Basic"),
        .executableTarget(name: "AWSExample", dependencies: ["Nido", "NidoAWS"], path: "Examples/AWS"),
        .executableTarget(name: "ArchitectureExample", dependencies: ["Nido"], path: "Examples/Architecture"),
        .testTarget(name: "NidoTests", dependencies: ["Nido", "NidoAWS", "NidoSchema"]),
    ]
)
