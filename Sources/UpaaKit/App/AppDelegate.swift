import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.load()
        var problem = config.problem
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        func makeRenderer(device: MTLDevice, fontFamily: String) -> Renderer? {
            try? Renderer(device: device, fontName: fontFamily, fontSize: config.fontSize, scale: scale, mascot: true)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = makeRenderer(device: device, fontFamily: config.fontFamily) ?? {
                  problem = "config: font-family not found, using the default"
                  return makeRenderer(device: device, fontFamily: Config().fontFamily)
              }(),
              let session = TerminalSession(cols: UInt16(config.cols), rows: UInt16(config.rows), config: config)
        else {
            NSLog("upaa: failed to start the terminal")
            NSApp.terminate(nil)
            return
        }
        session.onExit = { NSApp.terminate(nil) }

        let pixels = renderer.pixelSize(cols: config.cols, rows: config.rows)
        let size = NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "upaa"
        // Make the size change in steps of one cell.
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        let view = TerminalView(session: session, renderer: renderer)
        window.contentView = view
        UpdateCheck.run { [weak view] message in view?.showNote(message) }
        if let problem {
            NSLog("upaa: \(problem)")
            view.showNote(problem)
        }
        window.makeFirstResponder(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
