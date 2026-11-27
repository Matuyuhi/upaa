import AppKit
import CUpaaCore
import MetalKit

/// A view that displays one terminal and receives key input. Redraws only when the screen changes.
final class TerminalView: MTKView, MTKViewDelegate {
    private let session: TerminalSession
    private let renderer: Renderer
    private let commandQueue: MTLCommandQueue
    private var gridSize: (cols: Int, rows: Int) = (0, 0)
    /// The cursor cell from the last frame. The IME candidate window is placed below it.
    private var cursor: (col: Int, row: Int)?
    /// Scroll amount (in rows) not applied yet, since trackpads scroll by less than a row at a time.
    private var pendingScroll: CGFloat = 0
    /// Runs while a selection drag is past the top or bottom edge, scrolling one row per tick.
    private var autoscrollTimer: Timer?
    private var lastDrag: NSEvent?

    /// Drawable pixels per view point (2 on Retina).
    private var scale: CGFloat { drawableSize.width / max(bounds.width, 1) }

    /// Text being composed with IME. Passed to Zig when drawing and overlaid with an underline at the cursor position.
    private var markedText = NSMutableAttributedString()
    /// Collects characters committed from IME during keyDown processing. nil outside keyDown.
    private var insertedText: String?

    init(session: TerminalSession, renderer: Renderer) {
        self.session = session
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()!
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = Renderer.pixelFormat
        // Draw only when needsDisplay is set, not on every frame.
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        session.onWakeup = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Drawing

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
        // Register to receive the next change notification before drawing.
        _ = session.takeDirty()
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        cursor = renderer.draw(
            session: session, preedit: markedText.string, commandBuffer: commandBuffer, pass: pass,
            viewport: (Int(drawableSize.width), Int(drawableSize.height)))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report points; mouse wheels report rows. Positive is toward older output.
        let rows = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / (CGFloat(renderer.cellSize.height) / scale)
            : event.scrollingDeltaY
        pendingScroll += rows
        let whole = pendingScroll.rounded(.towardZero)
        guard whole != 0 else { return }
        pendingScroll -= whole
        session.scroll(rows: -Int(whole))
        needsDisplay = true
    }

    // MARK: Selection

    override func mouseDown(with event: NSEvent) {
        _ = session.select(pointer(UPAA_POINTER_PRESS, event))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        lastDrag = event
        let wantsAutoscroll = session.select(pointer(UPAA_POINTER_DRAG, event))
        needsDisplay = true
        if wantsAutoscroll, autoscrollTimer == nil {
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let drag = self.lastDrag else { return }
                if !self.session.select(self.pointer(UPAA_POINTER_AUTOSCROLL, drag)) { self.stopAutoscroll() }
                self.needsDisplay = true
            }
        } else if !wantsAutoscroll {
            stopAutoscroll()
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        _ = session.select(pointer(UPAA_POINTER_RELEASE, event))
        needsDisplay = true
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// The event as a selection pointer, in drawable pixels from the top-left.
    private func pointer(_ kind: Int, _ event: NSEvent) -> UpaaPointer {
        let location = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSize
        return UpaaPointer(
            kind: UInt8(kind),
            rectangle: event.modifierFlags.contains(.option),
            x: location.x * scale,
            y: (bounds.height - location.y) * scale,
            time_ns: UInt64(event.timestamp * 1e9),
            repeat_interval_ns: UInt64(NSEvent.doubleClickInterval * 1e9),
            repeat_distance: Double(cell.width),
            cols: UInt32(gridSize.cols), rows: UInt32(gridSize.rows),
            cell_width: UInt32(cell.width), cell_height: UInt32(cell.height),
            padding_left: UInt32(renderer.padding.horizontal), padding_top: UInt32(renderer.padding.top),
            screen_height: UInt32(drawableSize.height))
    }

    @objc func copy(_ sender: Any?) {
        guard let text = session.selectionText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        session.selectAll()
        needsDisplay = true
    }

    // MARK: Key input

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Keys that include ⌘ are left to menu shortcuts.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let wasComposing = hasMarkedText()
        insertedText = ""
        // Go through IME. Committed characters arrive in insertText; text being composed arrives in setMarkedText.
        interpretKeyEvents([event])
        let text = insertedText ?? ""
        insertedText = nil

        if wasComposing || hasMarkedText() {
            // Keys during composition belong to IME. Only the committed characters are sent to the shell.
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

    /// Arrow keys, Return, and similar keys arrive here instead of insertText. They are sent as keys, so nothing is done here.
    override func doCommand(by selector: Selector) {}

    private static func mods(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods = 0
        if flags.contains(.shift) { mods |= UPAA_MOD_SHIFT }
        if flags.contains(.control) { mods |= UPAA_MOD_CTRL }
        if flags.contains(.option) { mods |= UPAA_MOD_ALT }
        if flags.contains(.command) { mods |= UPAA_MOD_SUPER }
        return UInt8(mods)
    }

    /// Control characters (such as 0x03 for Ctrl+C) and private-use characters assigned to arrow keys are
    /// not sent as text. The encoder builds them from the key and modifier keys.
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
        needsDisplay = true
        if insertedText != nil {
            insertedText! += text
        } else {
            // Input that does not go through keyDown (such as the character viewer).
            session.write(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        needsDisplay = true
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        needsDisplay = true
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

    /// Screen rect of the cursor cell (where composition starts). The input method shows its candidate window below it.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cursor else { return .zero }
        // Renderer works in drawable pixels from the top-left; the view is in points from the bottom-left.
        let cell = renderer.cellSize
        let x = CGFloat(renderer.padding.horizontal + cursor.col * cell.width) / scale
        let top = CGFloat(renderer.padding.top + cursor.row * cell.height) / scale
        let height = CGFloat(cell.height) / scale
        let rect = NSRect(x: x, y: bounds.height - top - height, width: CGFloat(cell.width) / scale, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
