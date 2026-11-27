import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? Renderer(
                  device: device, fontName: Defaults.fontName, fontSize: Defaults.fontSize, scale: scale, mascot: true),
              let session = TerminalSession(cols: UInt16(Defaults.cols), rows: UInt16(Defaults.rows))
        else {
            NSLog("upaa: failed to start the terminal")
            NSApp.terminate(nil)
            return
        }
        session.onExit = { NSApp.terminate(nil) }

        let pixels = renderer.pixelSize(cols: Defaults.cols, rows: Defaults.rows)
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
