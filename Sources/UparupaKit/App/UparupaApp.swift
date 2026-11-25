import AppKit

/// アプリの入口。実行ファイル（Sources/uparupa/main.swift）からこれだけを呼ぶ。
///
/// 引数:
///   --check                              リンクの確認をして結果を出力し、終了する
///   --snapshot <png> [--command <コマンド>] [--input <文字列>]
///                                        シェル（--command があればそのコマンド）に文字列を送ったあとの画面を PNG に書き出し、終了する
///   --compare-png <基準> <今回> [--max-diff <割合>]
///                                        2 枚の PNG を比べ、違うピクセルの割合が上限（既定 0.01）を超えたら失敗する
///   --bench-headless <ファイル> [--max-frame-ms <ミリ秒>] [--min-mb-per-s <MB/秒>]
///                                        ウィンドウなしでファイルを cat する速さと 1 フレームの組み立て時間を測り、上限・下限を外れたら失敗する
///   --type <文字列>                       ウィンドウを開いて文字列をキー入力として流し、画面の文字を出力して終了する
///   --bench-cat <ファイル>                ウィンドウを開いてファイルを cat し、かかった時間を出力して終了する
///   --bench-keys                         ウィンドウを開いて 1 文字ずつ打ち、キーから表示までの時間を出力して終了する
public enum UparupaApp {
    public static func main() -> Never {
        let arguments = CommandLine.arguments

        if arguments.contains("--check") {
            let report = runSelfTest()
            for line in report.lines { print(line) }
            exit(report.ok ? 0 : 1)
        }

        do {
            if let path = value(after: "--snapshot", in: arguments) {
                try Snapshot.write(
                    to: URL(fileURLWithPath: path), cols: Defaults.cols, rows: Defaults.rows,
                    command: value(after: "--command", in: arguments), input: value(after: "--input", in: arguments))
                exit(0)
            }

            if let index = arguments.firstIndex(of: "--compare-png"), index + 2 < arguments.count {
                let difference = try Snapshot.difference(
                    URL(fileURLWithPath: arguments[index + 1]), URL(fileURLWithPath: arguments[index + 2]))
                let limit = value(after: "--max-diff", in: arguments).flatMap(Double.init) ?? 0.01
                print(String(format: "違うピクセル: %.4f%%（上限 %.4f%%）", difference * 100, limit * 100))
                exit(difference <= limit ? 0 : 1)
            }

            if let file = value(after: "--bench-headless", in: arguments) {
                let result = try Snapshot.bench(file: file, cols: Defaults.cols, rows: Defaults.rows)
                let maxFrame = value(after: "--max-frame-ms", in: arguments).flatMap(Double.init) ?? .infinity
                let minSpeed = value(after: "--min-mb-per-s", in: arguments).flatMap(Double.init) ?? 0
                print(String(format: "cat（描画なし）: %.1f MB/秒（下限 %.1f）", result.megabytesPerSecond, minSpeed))
                print(String(format: "1 フレームの組み立て: %.3f ミリ秒（上限 %.1f）", result.frameMilliseconds, maxFrame))
                exit(result.megabytesPerSecond >= minSpeed && result.frameMilliseconds <= maxFrame ? 0 : 1)
            }
        } catch {
            FileHandle.standardError.write(Data("uparupa: \(error)\n".utf8))
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        var automation: Automation?
        if let text = value(after: "--type", in: arguments) {
            automation = .type(text)
        } else if let path = value(after: "--bench-cat", in: arguments) {
            automation = .benchCat(path)
        } else if arguments.contains("--bench-keys") {
            automation = .benchKeys
        }
        let delegate = AppDelegate(automation: automation)
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
        appItem.submenu?.addItem(withTitle: "Quit uparupa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
