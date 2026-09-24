// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleBooks",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apple-books", targets: ["AppleBooks"])
    ],
    targets: [
        .executableTarget(name: "AppleBooks")
    ]
)
