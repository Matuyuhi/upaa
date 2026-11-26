import CUpaaCore
import Foundation

/// Zig 側の端末セッション（PTY、シェル、libghostty-vt の端末）を包む。
final class TerminalSession {
    let handle: OpaquePointer
    private let events: Events

    /// 画面が変わった。メインスレッドで呼ばれる。
    var onWakeup: (() -> Void)? {
        get { events.onWakeup }
        set { events.onWakeup = newValue }
    }

    /// シェルが終了した。メインスレッドで呼ばれる。
    var onExit: (() -> Void)? {
        get { events.onExit }
        set { events.onExit = newValue }
    }

    /// command が nil ならログインシェルを、そうでなければ /bin/sh -c command を起動する。
    /// showIntro が true なら、シェルの出力を出す前に起動時の顔を画面に描く。
    init?(cols: UInt16, rows: UInt16, command: String? = nil, showIntro: Bool = false) {
        let events = Events()
        var callbacks = UpaaSessionCallbacks(
            userdata: Unmanaged.passUnretained(events).toOpaque(),
            on_wakeup: { userdata in
                let events = Unmanaged<Events>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { events.onWakeup?() }
            },
            on_exit: { userdata in
                let events = Unmanaged<Events>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { events.onExit?() }
            }
        )
        guard let handle = upaa_session_new(cols, rows, command, showIntro, &callbacks) else { return nil }
        self.handle = handle
        self.events = events
    }

    deinit {
        // 読み取りスレッドの終了を待つので、これ以降コールバックは来ない。
        upaa_session_free(handle)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        upaa_session_write(handle, bytes, bytes.count)
    }

    /// キーを 1 回押したこと。text はそのキーで入力される文字（無ければ nil）。
    func key(code: UInt16, isRepeat: Bool, mods: UInt8, unshifted: UInt32, text: String?) {
        let bytes = text.map { Array($0.utf8) } ?? []
        bytes.withUnsafeBufferPointer { buffer in
            var event = UpaaKeyEvent(
                key_code: code,
                action: UInt8(isRepeat ? UPAA_KEY_REPEAT : UPAA_KEY_PRESS),
                mods: mods,
                unshifted_codepoint: unshifted,
                text: buffer.isEmpty ? nil : buffer.baseAddress,
                text_len: buffer.count)
            upaa_session_key(handle, &event)
        }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: Int, cellHeight: Int) {
        upaa_session_resize(handle, cols, rows, UInt32(cellWidth), UInt32(cellHeight))
    }

    /// 起動時の顔と一緒に出すお知らせ。顔を流し終えたあとに呼んでも何も起きない。
    func setIntroNote(_ text: String) {
        upaa_session_set_intro_note(handle, text)
    }

    /// 画面のプレーンテキスト。
    func plainText() -> String {
        var out = [UInt8](repeating: 0, count: 64 * 1024)
        let n = upaa_session_plain_text(handle, &out, out.count)
        return n >= 0 ? String(decoding: out.prefix(min(n, out.count)), as: UTF8.self) : ""
    }

    /// 前回の呼び出しから画面が変わっていれば true。
    func takeDirty() -> Bool {
        upaa_session_take_dirty(handle)
    }

    /// Zig のスレッドから渡される通知の受け口。セッションより長く生きる必要があるので別のオブジェクトにしている
    /// （メインスレッドに積んだ通知が、セッションの解放後に実行されることがある）。
    private final class Events {
        var onWakeup: (() -> Void)?
        var onExit: (() -> Void)?
    }
}
