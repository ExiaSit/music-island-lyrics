// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MusicIslandLyrics",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MusicIslandLyrics", targets: ["MusicIslandLyrics"])
    ],
    targets: [
        .executableTarget(
            name: "MusicIslandLyrics",
            path: "Sources/MusicIslandLyrics"
        ),
        .testTarget(
            name: "MusicIslandLyricsTests",
            dependencies: ["MusicIslandLyrics"],
            path: "Tests/MusicIslandLyricsTests"
        )
    ]
)
