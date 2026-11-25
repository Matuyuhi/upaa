import CWrenCore

/// M0 の確認項目を順に走らせ、結果を 1 行ずつ返す。
func runM0Checks() -> (lines: [String], ok: Bool) {
    var lines: [String] = []
    var ok = true
    func check(_ pass: Bool, _ message: String) {
        lines.append((pass ? "OK   " : "FAIL ") + message)
        if !pass { ok = false }
    }

    // (1) Swift から Zig を呼ぶ
    let abi = wren_core_abi_version()
    check(abi == WREN_CORE_ABI_VERSION, "(1) ABI version: zig=\(abi) header=\(WREN_CORE_ABI_VERSION)")

    var buf = [UInt8](repeating: 0, count: 64)
    let len = wren_core_greeting(&buf, buf.count)
    let greeting = String(decoding: buf.prefix(min(len, buf.count)), as: UTF8.self)
    check(len > 0 && len <= buf.count, "(1) greeting: \"\(greeting)\"")

    let sample = Array("wren ミソサザイ".utf8)
    let zigHash = wren_core_fnv1a64(sample, sample.count)
    let swiftHash = fnv1a64(sample)
    check(zigHash == swiftHash, "(1) fnv1a64: zig=0x\(String(zigHash, radix: 16)) swift=0x\(String(swiftHash, radix: 16))")

    // (2) Zig から libghostty-vt を呼ぶ
    let vtInput = Array("Hello, \u{1b}[1;32mworld\u{1b}[0m!\r\nあいう".utf8)
    var vtOut = [UInt8](repeating: 0, count: 256)
    let vtLen = wren_vt_plain_text(vtInput, vtInput.count, &vtOut, vtOut.count)
    let vtText = vtLen >= 0 ? String(decoding: vtOut.prefix(min(vtLen, vtOut.count)), as: UTF8.self) : ""
    check(vtText == "Hello, world!\nあいう", "(2) libghostty-vt plain text: \(vtText.debugDescription)")

    // (3) Zig から CoreText を呼ぶ
    for (font, ch) in [("Menlo", "A"), ("Menlo", "あ")] {
        let cp = ch.unicodeScalars.first!.value
        var info = WrenGlyphInfo()
        let found = wren_ct_glyph_info(font, 14, cp, &info)
        let resolved = withUnsafeBytes(of: &info.font_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        check(found && info.glyph != 0,
              "(3) \(font) '\(ch)': glyph=\(info.glyph) advance=\(info.advance) " +
              "bbox=(\(info.bbox_x), \(info.bbox_y), \(info.bbox_w), \(info.bbox_h)) font=\(resolved)")
    }

    return (lines, ok)
}

private func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in bytes {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return h
}
