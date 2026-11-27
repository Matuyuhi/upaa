import AppKit
import Metal

/// Opens one window per terminal. Tabs are macOS window tabs: a tab is a window grouped with others.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config = Config.load()
    private lazy var fontFamily = config.fontFamily
    /// A config problem not shown yet. The next window to open shows it.
    private lazy var problem = config.problem
    /// AppKit does not keep a window alive by itself, so open windows are held here until they close.
    private var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = makeWindow() else {
            NSLog("upaa: failed to start the terminal")
            NSApp.terminate(nil)
            return
        }
        let view = window.contentView as? TerminalView
        UpdateCheck.run { [weak view] message in view?.showNote(message) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }

    /// Cmd-N. Opens a window slightly below and to the right of the current one.
    @objc func newWindow(_ sender: Any?) {
        guard let window = makeWindow() else { return NSSound.beep() }
        if let current = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Cmd-T, and the + button of the tab bar (AppKit shows the button because this action exists).
    @objc func newWindowForTab(_ sender: Any?) {
        guard let window = makeWindow() else { return NSSound.beep() }
        if let current = NSApp.keyWindow {
            current.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A window with its own shell. Closing the window ends the shell, and the shell exiting closes the window.
    private func makeWindow() -> NSWindow? {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        func makeRenderer(device: MTLDevice) -> Renderer? {
            try? Renderer(device: device, fontName: fontFamily, fontSize: config.fontSize, scale: scale, mascot: true)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = makeRenderer(device: device) ?? {
                  problem = "config: font-family not found, using the default"
                  fontFamily = Config().fontFamily
                  return makeRenderer(device: device)
              }(),
              let session = TerminalSession(cols: UInt16(config.cols), rows: UInt16(config.rows), config: config)
        else { return nil }

        let pixels = renderer.pixelSize(cols: config.cols, rows: config.rows)
        let size = NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "upaa"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Make the size change in steps of one cell.
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        let view = TerminalView(session: session, renderer: renderer)
        window.contentView = view
        session.onExit = { [weak window] in window?.close() }
        if let problem {
            NSLog("upaa: \(problem)")
            view.showNote(problem)
            self.problem = nil
        }
        window.makeFirstResponder(view)
        windows.append(window)
        return window
    }
}
