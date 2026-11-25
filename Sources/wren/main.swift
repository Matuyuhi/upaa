import AppKit

let report = runM0Checks()
for line in report.lines { print(line) }

// --check: 結果を出力して終了する（ウィンドウを出さずに確かめるため）
if CommandLine.arguments.contains("--check") {
    exit(report.ok ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let text: String

    init(text: String) {
        self.text = text
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "wren — M0"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "Quit wren", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
mainMenu.addItem(appItem)
app.mainMenu = mainMenu

let delegate = AppDelegate(text: report.lines.joined(separator: "\n"))
app.delegate = delegate
app.run()
