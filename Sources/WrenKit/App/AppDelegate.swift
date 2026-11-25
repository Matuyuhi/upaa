import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    /// --type で渡された文字列。ウィンドウにキーイベントとして流し、画面の文字を出力して終了する（入力の確認用）。
    private let typeText: String?

    init(typeText: String?) {
        self.typeText = typeText
    }

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

        let pixels = renderer.pixelSize(cols: Defaults.cols, rows: Defaults.rows)
        let size = NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "wren"
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

        if let typeText {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.type(typeText, into: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print(session.plainText())
                    exit(0)
                }
            }
        }
    }

    /// 1 文字ずつキーを押したことにする。改行は Return キー、それ以外はキーコード 0 に文字を載せて送る。
    private static func type(_ text: String, into window: NSWindow) {
        for character in text {
            let isReturn = character == "\n"
            let characters = isReturn ? "\r" : String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: isReturn ? 36 : 0)
            else { continue }
            window.sendEvent(event)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
