import AppKit

/// アプリの入口。実行ファイル（Sources/wren/main.swift）からこれだけを呼ぶ。
///
/// 引数:
///   --check                              リンクの確認をして結果を出力し、終了する
///   --snapshot <png> [--input <文字列>]   シェルに文字列を送ったあとの画面を PNG に書き出し、終了する
///   --type <文字列>                       ウィンドウを開いて文字列をキー入力として流し、画面の文字を出力して終了する
public enum WrenApp {
    public static func main() -> Never {
        let arguments = CommandLine.arguments

        if arguments.contains("--check") {
            let report = runSelfTest()
            for line in report.lines { print(line) }
            exit(report.ok ? 0 : 1)
        }

        if let path = value(after: "--snapshot", in: arguments) {
            do {
                try Snapshot.write(
                    to: URL(fileURLWithPath: path), cols: Defaults.cols, rows: Defaults.rows,
                    input: value(after: "--input", in: arguments))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                exit(1)
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        let delegate = AppDelegate(typeText: value(after: "--type", in: arguments))
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
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
