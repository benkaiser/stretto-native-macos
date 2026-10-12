// swift-tools-version: 5.9
import PackageDescription

let audioFrameworks = [
    ("Mpv", "dccd14f7bc54a9163c1d25d301fa053abccb7aed018dcc039ef8068c1806b114"),
    ("Avcodec", "22253d866c30aead468f17f1ad41b4d69842d122bf9a8c277fb4cc168f0a2f32"),
    ("Avfilter", "c12eab2744e0e84d44ecf7eaeccad4295178237bce086d6e4aea7d52e5751f1e"),
    ("Avformat", "6161fcf62e80943ccc17b6187cd60b66d72521da51e8edd7d232d147f02c2ca7"),
    ("Avutil", "354ab94bc822d63af6ff8843cd5916b8e9ae041cfa5c6fd156fdca9c1663a1fb"),
    ("Swresample", "e3996e554d1e7298fa863b88779e5a885a23f7d1ef5ab6ea3defe2aa859b9207"),
    ("Swscale", "4dc3e94f54eab9b00e27a8e340495b0e20d89c612c10c184c0d3c389301b11dc"),
    ("Mbedcrypto", "d5c6b38137484dffe325e99464727483070ccf9ce8a0c26d49f21b1400ea50d4"),
    ("Mbedtls", "09dd975469c2f0bb64b1e61cec5c574e2b3c821594ed4079ee70f93472264349"),
    ("Mbedx509", "1031f20c2736537f2d4bdc7af8a4b9d9fff7b8d1dd9236b731d31296a1308b59"),
]

let package = Package(
    name: "StrettoNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Stretto", targets: ["StrettoMac"]), .library(name: "StrettoCore", targets: ["StrettoCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "StrettoCore", dependencies: ["CSQLite"]),
        .target(name: "StrettoMedia", dependencies: [.target(name: "StrettoCore")] + audioFrameworks.map { .target(name: $0.0) },
                linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
                                 .linkedFramework("VideoToolbox"), .linkedFramework("Security"), .linkedLibrary("iconv"), .linkedLibrary("z"), .linkedLibrary("c++")]),
        .executableTarget(name: "StrettoMac", dependencies: ["StrettoCore", "StrettoMedia"], resources: [.copy("Resources")]),
        .testTarget(name: "StrettoCoreTests", dependencies: ["StrettoCore"]),
        .testTarget(name: "StrettoMacTests", dependencies: ["StrettoMac", "StrettoMedia", "StrettoCore"]),
    ] + audioFrameworks.map { name, checksum in
        .binaryTarget(name: name,
                      url: "https://github.com/media-kit/libmpv-darwin-build/releases/download/v0.7.3/libmpv-xcframeworks_v0.7.3_macos-universal-audio-default_\(name).zip",
                      checksum: checksum)
    }
)
