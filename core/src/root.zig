const std = @import("std");
const builtin = @import("builtin");
const glyph = @import("glyph.zig");
const vt = @import("vt.zig");

comptime {
    _ = glyph;
    _ = vt;
}

/// Swift 側のヘッダ（Sources/CWrenCore/wren_core.h）と食い違っていないかを起動時に確かめるための番号。
/// 公開する関数や構造体の形を変えたら、両方で上げる。
export fn wren_core_abi_version() u32 {
    return 2;
}

/// buf に挨拶文を書き、本来の長さを返す。cap より長い分は切り捨てる。
export fn wren_core_greeting(buf: [*]u8, cap: usize) usize {
    const msg = "hello from zig " ++ builtin.zig_version_string;
    const n = @min(cap, msg.len);
    @memcpy(buf[0..n], msg[0..n]);
    return msg.len;
}

/// 64 ビットの FNV-1a。Swift 側でも同じ計算をして、バイト列の受け渡しが壊れていないかを確かめる。
export fn wren_core_fnv1a64(data: [*]const u8, len: usize) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data[0..len]) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

test "fnv1a64" {
    const s = "wren";
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), wren_core_fnv1a64(s.ptr, 0));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), wren_core_fnv1a64("a".ptr, 1));
}
