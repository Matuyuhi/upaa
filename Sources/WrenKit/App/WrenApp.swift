import AppKit

/// アプリの入口。実行ファイル（Sources/wren/main.swift）からこれだけを呼ぶ。
public enum WrenApp {
    public static func main() -> Never {
        let report = runSelfTest()
        for line in report.lines { print(line) }

        // --check: 結果を出力して終了する（ウィンドウを出さずに確かめるため）
        if CommandLine.arguments.contains("--check") {
            exit(report.ok ? 0 : 1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()

        let delegate = AppDelegate(text: report.lines.joined(separator: "\n"))
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit wren", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
