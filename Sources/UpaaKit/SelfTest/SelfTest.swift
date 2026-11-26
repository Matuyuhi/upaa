import CUpaaCore
import Foundation

/// Swift・Zig・libghostty-vt・CoreText がつながっているかを順に確かめ、結果を 1 行ずつ返す。
func runSelfTest() -> (lines: [String], ok: Bool) {
    var lines: [String] = []
    var ok = true
    func check(_ pass: Bool, _ message: String) {
        lines.append((pass ? "OK   " : "FAIL ") + message)
        if !pass { ok = false }
    }

    // (1) Swift から Zig を呼ぶ
    let abi = upaa_core_abi_version()
    check(abi == UPAA_CORE_ABI_VERSION, "(1) ABI version: zig=\(abi) header=\(UPAA_CORE_ABI_VERSION)")

    var buf = [UInt8](repeating: 0, count: 64)
    let len = upaa_selftest_greeting(&buf, buf.count)
    let greeting = String(decoding: buf.prefix(min(len, buf.count)), as: UTF8.self)
    check(len > 0 && len <= buf.count, "(1) greeting: \"\(greeting)\"")

    let sample = Array("upaa ウーパールーパー".utf8)
    let zigHash = upaa_selftest_fnv1a64(sample, sample.count)
    let swiftHash = fnv1a64(sample)
    check(zigHash == swiftHash, "(1) fnv1a64: zig=0x\(String(zigHash, radix: 16)) swift=0x\(String(swiftHash, radix: 16))")

    // (2) Zig から libghostty-vt を呼ぶ
    let vtInput = Array("Hello, \u{1b}[1;32mworld\u{1b}[0m!\r\nあいう".utf8)
    var vtOut = [UInt8](repeating: 0, count: 256)
    let vtLen = upaa_selftest_vt_plain_text(vtInput, vtInput.count, &vtOut, vtOut.count)
    let vtText = vtLen >= 0 ? String(decoding: vtOut.prefix(min(vtLen, vtOut.count)), as: UTF8.self) : ""
    check(vtText == "Hello, world!\nあいう", "(2) libghostty-vt plain text: \(vtText.debugDescription)")

    // (3) Zig から CoreText を呼ぶ
    for (font, ch) in [("Menlo", "A"), ("Menlo", "あ")] {
        let cp = ch.unicodeScalars.first!.value
        var info = UpaaGlyphInfo()
        let found = upaa_selftest_glyph_info(font, 14, cp, &info)
        let resolved = withUnsafeBytes(of: &info.font_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        check(found && info.glyph != 0,
              "(3) \(font) '\(ch)': glyph=\(info.glyph) advance=\(info.advance) " +
              "bbox=(\(info.bbox_x), \(info.bbox_y), \(info.bbox_w), \(info.bbox_h)) font=\(resolved)")
    }

    // (4) 端末セッション: ログインシェルにコマンドを送り、結果が画面に出るのを待つ
    if let session = upaa_session_new(80, 24, nil, false, nil) {
        defer { upaa_session_free(session) }
        // 入力のエコーと区別できるよう、シェルに計算させる
        let command = Array("echo upaa-$((40+2))\n".utf8)
        upaa_session_write(session, command, command.count)
        var screen = ""
        var out = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<500 where !screen.contains("upaa-42") {
            usleep(10_000)
            let n = upaa_session_plain_text(session, &out, out.count)
            screen = n >= 0 ? String(decoding: out.prefix(min(n, out.count)), as: UTF8.self) : ""
        }
        check(screen.contains("upaa-42"), "(4) session: シェルの出力 \"upaa-42\" が画面に出た")
    } else {
        check(false, "(4) session: 起動できなかった")
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
