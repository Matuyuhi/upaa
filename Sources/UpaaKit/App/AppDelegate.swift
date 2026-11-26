import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    /// 起動後に自動で行う確認や計測。普通の起動では nil。
    private let automation: Automation?

    init(automation: Automation?) {
        self.automation = automation
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? Renderer(device: device, fontName: Defaults.fontName, fontSize: Defaults.fontSize, scale: scale),
              // 確認や計測のときは起動時の顔を出さない。画面の中身や時間が変わってしまうため。
              let session = TerminalSession(
                  cols: UInt16(Defaults.cols), rows: UInt16(Defaults.rows), showIntro: automation == nil)
        else {
            NSLog("upaa: 端末を起動できない")
            NSApp.terminate(nil)
            return
        }
        session.onExit = { NSApp.terminate(nil) }
        if automation == nil {
            // 起動時の顔を流している間に、裏で更新を調べる。
            UpdateCheck.run { [weak session] message in session?.setIntroNote(message) }
        }

        let pixels = renderer.pixelSize(cols: Defaults.cols, rows: Defaults.rows)
        let size = NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "upaa"
        // セル 1 つ分ずつ大きさが変わるようにする。
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        let view = TerminalView(session: session, renderer: renderer)
        window.contentView = view
        window.makeFirstResponder(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        automation?.run(window: window, view: view, session: session)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
