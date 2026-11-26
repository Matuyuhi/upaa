// swift-tools-version: 5.9
import PackageDescription

// Where zig build puts libupaacore.a. scripts/build-app.sh runs zig build first.
let zigLibDir = Context.packageDirectory + "/zig-out/lib"

let package = Package(
    name: "upaa",
    platforms: [.macOS(.v13)],
    targets: [
        // C header for the functions the Zig side exports. It is a C target rather than systemLibrary, because with systemLibrary Swift is not recompiled when the header changes.
        .target(
            name: "CUpaaCore",
            path: "Sources/CUpaaCore",
            linkerSettings: [
                .unsafeFlags(["-L", zigLibDir]),
                .linkedLibrary("upaacore"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
        // App code. It is separate from the executable so that tests can import it.
        .target(
            name: "UpaaKit",
            dependencies: ["CUpaaCore", "GhosttyVt"],
            path: "Sources/UpaaKit"
        ),
        .executableTarget(name: "upaa", dependencies: ["UpaaKit"], path: "Sources/upaa"),
        // Link libghostty-vt, which the Zig side calls, at the final link. Fetched by scripts/fetch-ghostty-vt.sh.
        .binaryTarget(name: "GhosttyVt", path: "vendor/ghostty-vt/ghostty-vt.xcframework"),
    ]
)
