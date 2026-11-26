const std = @import("std");
// The version is written only in .version of build.zig.zon. It is passed from here to the Zig code and Swift.
const package = @import("build.zig.zon");

/// The macOS contents of the XCFramework that scripts/fetch-ghostty-vt.sh extracts.
const ghostty_vt_dir = "vendor/ghostty-vt/ghostty-vt.xcframework/macos-arm64_x86_64";

pub fn build(b: *std.Build) void {
    // Only Apple Silicon with macOS 13 or later is supported. Keep in line with platforms on the SwiftPM side.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
    });
    const optimize = b.standardOptimizeOption(.{});

    // If the target is given explicitly, Zig does not search for the SDK automatically, and the frameworks are not found.
    const sdk = b.option([]const u8, "sdk", "Path to the macOS SDK. If omitted, looked up with xcrun") orelse
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

    // libghostty-vt is not included in the static library. It is linked from the XCFramework at the final link on the Swift side.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "upaacore",
        .root_module = createModule(b, opts),
    });
    // The Swift-side linker does not know Zig's compiler_rt, so it is bundled into the static library.
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // Tests become executables, so the frameworks and libghostty-vt are linked here.
    const test_mod = createModule(b, opts);
    test_mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    test_mod.linkFramework("CoreFoundation", .{});
    test_mod.linkFramework("CoreGraphics", .{});
    test_mod.linkFramework("CoreText", .{});
    test_mod.addObjectFile(b.path(ghostty_vt_dir ++ "/libghostty-vt.a"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the Zig-side tests");
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
