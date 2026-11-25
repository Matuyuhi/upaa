import AppKit

/// 実際のウィンドウにキーイベントを流して確認や計測をする。結果を標準出力に出して終了する。
enum Automation {
    /// 文字列をキー入力として流し、画面の文字を出力する（入力の確認用）。
    case type(String)
    /// ファイルを cat して、出力が終わるまでの時間を測る。
    case benchCat(String)
    /// 1 文字ずつ打って、キーを受け取ってから画面に出るまでの時間を測る。
    case benchKeys

    func run(window: NSWindow, view: TerminalView, session: TerminalSession) {
        // シェルの起動とプロンプトの表示を待ってから始める。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            switch self {
            case .type(let text):
                Self.type(text, into: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print(session.plainText())
                    exit(0)
                }
            case .benchCat(let path):
                Self.benchCat(path, window: window, view: view, session: session)
            case .benchKeys:
                Self.benchKeys(window: window, view: view)
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

    private static func benchCat(_ path: String, window: NSWindow, view: TerminalView, session: TerminalSession) {
        // 入力のエコーと区別できるよう、終わりの目印はシェルに計算させる。
        type("cat \(path); echo uparupa-done-$((40+2))\n", into: window)
        let start = CACurrentMediaTime()
        let framesBefore = view.frameStats
        Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            guard session.plainText().contains("uparupa-done-42") else { return }
            let elapsed = CACurrentMediaTime() - start
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let frames = view.frameStats.count - framesBefore.count
            let frameSeconds = view.frameStats.seconds - framesBefore.seconds
            print(String(format: "cat: %.3f 秒, %.1f MB, %.1f MB/秒", elapsed, Double(bytes) / 1e6, Double(bytes) / 1e6 / elapsed))
            print(String(format: "描画: %d フレーム, 1 フレームの組み立て 平均 %.2f ミリ秒", frames, frames > 0 ? frameSeconds / Double(frames) * 1000 : 0))
            exit(0)
        }
    }

    private static func benchKeys(window: NSWindow, view: TerminalView) {
        var latencies: [Double] = []
        view.onKeyLatency = { latencies.append($0) }
        let count = 60
        var sent = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if sent < count {
                type("a", into: window)
                sent += 1
                return
            }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let sorted = latencies.sorted().map { $0 * 1000 }
                guard !sorted.isEmpty else {
                    print("キー: 1 件も測れなかった")
                    exit(1)
                }
                print(String(
                    format: "キーから表示まで: %d 件, 最小 %.1f / 中央 %.1f / 最大 %.1f ミリ秒",
                    sorted.count, sorted.first!, sorted[sorted.count / 2], sorted.last!))
                exit(0)
            }
        }
    }
}
