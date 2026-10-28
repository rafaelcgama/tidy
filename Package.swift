// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tidy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TidyCore", targets: ["TidyCore"]),
        .executable(name: "tidy", targets: ["tidy"]),
        .executable(name: "TidyApp", targets: ["TidyApp"]),
        .executable(name: "TidyHelper", targets: ["TidyHelper"]),
    ],
    targets: [
        // libyara 4.5.4, the engine behind the malware scan's YARA rules. Its source is in the
        // package, so there's nothing to install; see Sources/CYara/NOTICE.md.
        .target(
            name: "CYara",
            exclude: ["NOTICE.md", "LICENSE-APACHE-2.0", "libyara/modules/module_list", "libyara/modules/hash/hash.c"],
            publicHeadersPath: "libyara/include",
            cSettings: [
                .headerSearchPath("libyara"),
                .define("_GNU_SOURCE"),
                .define("USE_NO_PROC"),
                .define("HAVE_STDBOOL_H"),
                .define("HAVE_MEMMEM"),
                .define("HAVE_STRLCPY"),
                .define("HAVE_STRLCAT"),
                .define("BUCKETS_128"),
                .define("CHECKSUM_1B"),
                .define("DOTNET_MODULE"),
                .define("MACHO_MODULE"),
                .define("DEX_MODULE"),
                .define("HASH_MODULE", .when(platforms: [.macOS])),
                .define("HAVE_COMMONCRYPTO_COMMONCRYPTO_H", .when(platforms: [.macOS])),
                // Third-party code, built as released: its warnings aren't ours to fix.
                .unsafeFlags(["-w"]),
            ]),
        .target(name: "TidyCore", dependencies: ["CYara"]),
        .executableTarget(name: "tidy", dependencies: ["TidyCore"]),
        .executableTarget(name: "TidyApp", dependencies: ["TidyCore"]),
        .executableTarget(name: "TidyHelper", dependencies: ["TidyCore"]),
        .testTarget(name: "TidyCoreTests", dependencies: ["TidyCore"]),
    ]
)
