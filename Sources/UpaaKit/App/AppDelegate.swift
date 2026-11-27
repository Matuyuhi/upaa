import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = Config.load()
    private lazy var fontFamily = config.fontFamily
    /// A config problem not shown yet. The next terminal to open shows it.
    private lazy var problem = config.problem
    /// AppKit does not keep a window alive by itself, so open windows are held here until they close.
    private var windows: [TabbedWindow] = []

    private var scale: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard case let (window, terminal)? = makeWindow() else {
            NSLog("upaa: failed to start the terminal")
            NSApp.terminate(nil)
            return
        }
        UpdateCheck.run { [weak terminal] message in terminal?.showNote(message) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Cmd-N. Opens a window slightly below and to the right of the current one.
    @objc func newWindow(_ sender: Any?) {
        guard case let (window, _)? = makeWindow() else { return NSSound.beep() }
        if let current = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A window sized for the config's columns and rows, with one tab.
    private func makeWindow() -> (NSWindow, TerminalView)? {
        guard let terminal = makeTerminal() else { return nil }
        let renderer = terminal.renderer
        let pixels = renderer.pixelSize(cols: config.cols, rows: config.rows)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Make the size change in steps of one cell.
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        let tabs = TabbedWindow(window: window, first: terminal) { [weak self] cwd in self?.makeTerminal(cwd: cwd) }
        tabs.onClose = { [weak self, weak tabs] in self?.windows.removeAll { $0 === tabs } }
        windows.append(tabs)
        return (window, terminal)
    }

    /// A terminal view with its own shell, started in cwd (nil for the home directory).
    private func makeTerminal(cwd: String? = nil) -> TerminalView? {
        let scale = scale
        func makeRenderer(device: MTLDevice) -> Renderer? {
            try? Renderer(device: device, fontName: fontFamily, fontSize: config.fontSize, scale: scale, mascot: true,
                         backgroundOpacity: config.backgroundOpacity)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = makeRenderer(device: device) ?? {
                  problem = "config: font-family not found, using the default"
                  fontFamily = Config().fontFamily
                  return makeRenderer(device: device)
              }(),
              let session = TerminalSession(cols: UInt16(config.cols), rows: UInt16(config.rows), cwd: cwd, config: config)
        else { return nil }
        let view = TerminalView(session: session, renderer: renderer)
        if let problem {
            NSLog("upaa: \(problem)")
            view.showNote(problem)
            self.problem = nil
        }
        return view
    }
}
