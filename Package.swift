// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "redactor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "redactor", targets: ["redactor"])
    ],
    targets: [
        .executableTarget(name: "redactor")
    ]
)
