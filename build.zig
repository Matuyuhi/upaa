const std = @import("std");
// バージョンは build.zig.zon の .version だけに書く。ここから Zig のコードと Swift に渡る。
const package = @import("build.zig.zon");

/// scripts/fetch-ghostty-vt.sh が展開する XCFramework の macOS 向けの中身。
const ghostty_vt_dir = "vendor/ghostty-vt/ghostty-vt.xcframework/macos-arm64_x86_64";

pub fn build(b: *std.Build) void {
    // 対象は Apple Silicon の macOS 13 以上だけ。SwiftPM 側の platforms と揃える。
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
    });
    const optimize = b.standardOptimizeOption(.{});

    // ターゲットを明示すると Zig は SDK を自動で探さず、フレームワークが見つからない。
    const sdk = b.option([]const u8, "sdk", "macOS SDK のパス。省略時は xcrun で引く") orelse
        std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \n");

    const apple = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c/apple.h"),
        .target = target,
        .optimize = optimize,
    });
    const ghostty = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c/ghostty.h"),
        .target = target,
        .optimize = optimize,
    });
    ghostty.addIncludePath(b.path(ghostty_vt_dir ++ "/Headers"));
    const posix = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c/posix.h"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", package.version);

    const opts: ModuleOptions = .{
        .build_options = build_options,
        .target = target,
        .optimize = optimize,
        .sdk = sdk,
        .apple = apple.createModule(),
        .ghostty = ghostty.createModule(),
        .posix = posix.createModule(),
    };

    // libghostty-vt は静的ライブラリには含めず、Swift 側の最終リンクで XCFramework から入れる。
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "uparupacore",
        .root_module = createModule(b, opts),
    });
    // Swift 側のリンカは Zig の compiler_rt を知らないので、静的ライブラリに同梱する。
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // テストは実行ファイルになるので、フレームワークと libghostty-vt をここでリンクする。
    const test_mod = createModule(b, opts);
    test_mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    test_mod.linkFramework("CoreFoundation", .{});
    test_mod.linkFramework("CoreGraphics", .{});
    test_mod.linkFramework("CoreText", .{});
    test_mod.addObjectFile(b.path(ghostty_vt_dir ++ "/libghostty-vt.a"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Zig 側のテストを走らせる");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const ModuleOptions = struct {
    build_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: []const u8,
    apple: *std.Build.Module,
    ghostty: *std.Build.Module,
    posix: *std.Build.Module,
};

fn createModule(b: *std.Build, opts: ModuleOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "apple", .module = opts.apple },
            .{ .name = "ghostty", .module = opts.ghostty },
            .{ .name = "posix", .module = opts.posix },
        },
    });
    mod.addOptions("build_options", opts.build_options);
    return mod;
}
