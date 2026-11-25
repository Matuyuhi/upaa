import CWrenCore
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

    init?(cols: UInt16, rows: UInt16) {
        let events = Events()
        var callbacks = WrenSessionCallbacks(
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
        guard let handle = wren_session_new(cols, rows, &callbacks) else { return nil }
        self.handle = handle
        self.events = events
    }

    deinit {
        // 読み取りスレッドの終了を待つので、これ以降コールバックは来ない。
        wren_session_free(handle)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        wren_session_write(handle, bytes, bytes.count)
    }

    /// キーを 1 回押したこと。text はそのキーで入力される文字（無ければ nil）。
    func key(code: UInt16, isRepeat: Bool, mods: UInt8, unshifted: UInt32, text: String?) {
        let bytes = text.map { Array($0.utf8) } ?? []
        bytes.withUnsafeBufferPointer { buffer in
            var event = WrenKeyEvent(
                key_code: code,
                action: UInt8(isRepeat ? WREN_KEY_REPEAT : WREN_KEY_PRESS),
                mods: mods,
                unshifted_codepoint: unshifted,
                text: buffer.isEmpty ? nil : buffer.baseAddress,
                text_len: buffer.count)
            wren_session_key(handle, &event)
        }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: Int, cellHeight: Int) {
        wren_session_resize(handle, cols, rows, UInt32(cellWidth), UInt32(cellHeight))
    }

    /// 画面のプレーンテキスト。
    func plainText() -> String {
        var out = [UInt8](repeating: 0, count: 64 * 1024)
        let n = wren_session_plain_text(handle, &out, out.count)
        return n >= 0 ? String(decoding: out.prefix(min(n, out.count)), as: UTF8.self) : ""
    }

    /// 前回の呼び出しから画面が変わっていれば true。
    func takeDirty() -> Bool {
        wren_session_take_dirty(handle)
    }

    /// Zig のスレッドから渡される通知の受け口。セッションより長く生きる必要があるので別のオブジェクトにしている
    /// （メインスレッドに積んだ通知が、セッションの解放後に実行されることがある）。
    private final class Events {
        var onWakeup: (() -> Void)?
        var onExit: (() -> Void)?
    }
}
