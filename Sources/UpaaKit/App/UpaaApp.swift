import AppKit
import CUpaaCore

/// Entry point of the app. The executable (Sources/upaa/main.swift) calls only this.
///
/// Arguments:
///   --version                            Print the version and exit
///   --snapshot <png> [--command <command>] [--input <string>]
///                                        Send a string to the shell (or to --command if given), write the resulting screen to a PNG, and exit
///   --compare-png <baseline> <current> [--max-diff <ratio>]
///                                        Compare two PNGs. Fail if the ratio of differing pixels exceeds the limit (default 0.01)
///   --bench-headless <file> [--max-frame-ms <ms>] [--min-mb-per-s <MB/s>]
///                                        Without a window, measure how fast the file is cat'ed and how long one frame takes to build. Fail if outside the upper or lower limit
public enum UpaaApp {
    public static func main() -> Never {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") {
            print(String(cString: upaa_version()))
            exit(0)
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
                print(String(format: "Differing pixels: %.4f%% (limit %.4f%%)", difference * 100, limit * 100))
                exit(difference <= limit ? 0 : 1)
            }

            if let file = value(after: "--bench-headless", in: arguments) {
                let result = try Snapshot.bench(file: file, cols: Defaults.cols, rows: Defaults.rows)
                let maxFrame = value(after: "--max-frame-ms", in: arguments).flatMap(Double.init) ?? .infinity
                let minSpeed = value(after: "--min-mb-per-s", in: arguments).flatMap(Double.init) ?? 0
                print(String(format: "cat (no rendering): %.1f MB/s (min %.1f)", result.megabytesPerSecond, minSpeed))
                print(String(format: "1 frame build: %.3f ms (max %.1f)", result.frameMilliseconds, maxFrame))
                exit(result.megabytesPerSecond >= minSpeed && result.frameMilliseconds <= maxFrame ? 0 : 1)
            }
        } catch {
            FileHandle.standardError.write(Data("upaa: \(error)\n".utf8))
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        let delegate = AppDelegate()
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
        appItem.submenu?.addItem(withTitle: "Quit upaa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)

        // The actions go to the first responder (TerminalView).
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu?.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)
        return mainMenu
    }
}
