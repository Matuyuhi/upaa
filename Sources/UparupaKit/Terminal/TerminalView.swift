import AppKit
import CUparupaCore
import MetalKit

/// 端末 1 つを表示し、キー入力を受け取るビュー。画面が変わったときだけ描き直す。
final class TerminalView: MTKView, MTKViewDelegate {
    private let session: TerminalSession
    private let renderer: Renderer
    private let commandQueue: MTLCommandQueue
    private var gridSize: (cols: Int, rows: Int) = (0, 0)

    /// IME で変換中の文字列。画面への表示はまだしていない。
    private var markedText = NSMutableAttributedString()
    /// keyDown の処理中に IME から確定した文字を集める。nil は keyDown の外。
    private var insertedText: String?

    /// 計測用。これまでに描いたフレームの数と、CPU 側で 1 フレームを組み立てるのにかかった時間の合計（秒）。
    private(set) var frameStats: (count: Int, seconds: Double) = (0, 0)
    /// 計測用。キーを受け取ってから、その次に描いたフレームが画面に出るまでの秒数を受け取る。
    var onKeyLatency: ((Double) -> Void)?
    private var pendingKeyTime: TimeInterval?

    init(session: TerminalSession, renderer: Renderer) {
        self.session = session
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()!
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = Renderer.pixelFormat
        // 毎フレームではなく、needsDisplay を立てたときだけ描く。
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        session.onWakeup = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    // MARK: 描画

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let (cols, rows) = renderer.gridSize(for: (Int(size.width), Int(size.height)))
        guard (cols, rows) != gridSize else { return }
        gridSize = (cols, rows)
        session.resize(
            cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
            cellWidth: renderer.cellSize.width, cellHeight: renderer.cellSize.height)
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        // 次の変化の通知を受け取れるようにしてから描く。
        _ = session.takeDirty()
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        let start = CACurrentMediaTime()
        renderer.draw(
            session: session, commandBuffer: commandBuffer, pass: pass,
            viewport: (Int(drawableSize.width), Int(drawableSize.height)))
        if let keyTime = pendingKeyTime, let onKeyLatency {
            pendingKeyTime = nil
            drawable.addPresentedHandler { presented in
                // 画面に出なかったフレームは presentedTime が 0 になる。
                guard presented.presentedTime > 0 else { return }
                let latency = presented.presentedTime - keyTime
                DispatchQueue.main.async { onKeyLatency(latency) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameStats.count += 1
        frameStats.seconds += CACurrentMediaTime() - start
    }

    // MARK: キー入力

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘ を含むキーはメニューのショートカットに任せる。
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if onKeyLatency != nil { pendingKeyTime = event.timestamp }

        let wasComposing = hasMarkedText()
        insertedText = ""
        // IME を通す。確定した文字は insertText、変換中の文字列は setMarkedText に来る。
        interpretKeyEvents([event])
        let text = insertedText ?? ""
        insertedText = nil

        if wasComposing || hasMarkedText() {
            // 変換中のキーは IME のもの。確定した文字だけをシェルへ送る。
            if !text.isEmpty { session.write(text) }
            return
        }

        session.key(
            code: event.keyCode,
            isRepeat: event.isARepeat,
            mods: Self.mods(event.modifierFlags),
            unshifted: event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0,
            text: Self.printable(text))
    }

    /// 矢印キーや Return などは insertText ではなくここに来る。キーとして送るので何もしない。
    override func doCommand(by selector: Selector) {}

    private static func mods(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods = 0
        if flags.contains(.shift) { mods |= UPARUPA_MOD_SHIFT }
        if flags.contains(.control) { mods |= UPARUPA_MOD_CTRL }
        if flags.contains(.option) { mods |= UPARUPA_MOD_ALT }
        if flags.contains(.command) { mods |= UPARUPA_MOD_SUPER }
        return UInt8(mods)
    }

    /// 制御文字（Ctrl+C の 0x03 など）と、矢印キーなどに割り当てられた私用領域の文字は、
    /// 文字としては送らない。キーと修飾キーからエンコーダが作る。
    private static func printable(_ text: String) -> String? {
        guard let first = text.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        if (0xF700...0xF8FF).contains(first.value) { return nil }
        return text
    }
}

// MARK: IME

extension TerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString()
        if insertedText != nil {
            insertedText! += text
        } else {
            // keyDown を通らない入力（文字ビューアなど）。
            session.write(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// 変換候補のウィンドウを出す位置。カーソルの位置に合わせるのは変換中の表示と一緒に作る。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: 0, y: 0, width: 0, height: 0), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
