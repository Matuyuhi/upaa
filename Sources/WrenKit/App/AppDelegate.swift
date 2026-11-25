import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? Renderer(device: device, fontName: Defaults.fontName, fontSize: Defaults.fontSize, scale: scale),
              let session = TerminalSession(cols: UInt16(Defaults.cols), rows: UInt16(Defaults.rows))
        else {
            NSLog("wren: 端末を起動できない")
            NSApp.terminate(nil)
            return
        }
        session.onExit = { NSApp.terminate(nil) }

        let size = NSSize(
            width: Double(Defaults.cols * renderer.cellSize.width) / scale,
            height: Double(Defaults.rows * renderer.cellSize.height) / scale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "wren"
        window.contentView = TerminalView(session: session, renderer: renderer)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
