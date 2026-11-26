// swift-tools-version: 5.9
import PackageDescription

// zig build が libupaacore.a を置く場所。scripts/build-app.sh が先に zig build を走らせる。
let zigLibDir = Context.packageDirectory + "/zig-out/lib"

let package = Package(
    name: "upaa",
    platforms: [.macOS(.v13)],
    targets: [
        // Zig 側が export する関数の C ヘッダ。systemLibrary だとヘッダを変えても Swift が再コンパイルされないので C ターゲットにしている。
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
        // アプリの中身。実行ファイルと分けてあるのは、テストから import できるようにするため。
        .target(
            name: "UpaaKit",
            dependencies: ["CUpaaCore", "GhosttyVt"],
            path: "Sources/UpaaKit"
        ),
        .executableTarget(name: "upaa", dependencies: ["UpaaKit"], path: "Sources/upaa"),
        // Zig 側が呼ぶ libghostty-vt を最終リンクで入れる。scripts/fetch-ghostty-vt.sh が取得する。
        .binaryTarget(name: "GhosttyVt", path: "vendor/ghostty-vt/ghostty-vt.xcframework"),
    ]
)
