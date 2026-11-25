import CUparupaCore
import Foundation

/// 新しいバージョンが GitHub の Releases に出ていないかを調べる。知らせるだけで、更新はしない。
///
/// GitHub に問い合わせるのは 1 日 1 回まで。それ以外は前回の結果を使う。
/// 環境変数 UPARUPA_NO_UPDATE_CHECK を設定すると何もしない。
enum UpdateCheck {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Matuyuhi/uparupa/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckedKey = "updateCheck.lastChecked"
    private static let latestTagKey = "updateCheck.latestTag"

    /// 新しいバージョンがあれば、知らせる文を notify に渡す。notify はメインスレッドで呼ばれる。
    /// 起動時の顔を流している間に終わらなければ、結果は次回の起動で使われる。
    static func run(notify: @escaping (String) -> Void) {
        guard ProcessInfo.processInfo.environment["UPARUPA_NO_UPDATE_CHECK"] == nil else { return }
        let defaults = UserDefaults.standard

        if let tag = defaults.string(forKey: latestTagKey), let message = message(for: tag) {
            notify(message)
        }

        let lastChecked = defaults.object(forKey: lastCheckedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastChecked) >= interval else { return }

        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data)
            else { return }
            defaults.set(Date(), forKey: lastCheckedKey)
            let known = defaults.string(forKey: latestTagKey)
            defaults.set(release.tag_name, forKey: latestTagKey)
            // 前回の結果ですでに知らせたものは、もう一度出さない。
            guard release.tag_name != known, let message = message(for: release.tag_name) else { return }
            DispatchQueue.main.async { notify(message) }
        }.resume()
    }

    private static func message(for tag: String) -> String? {
        guard uparupa_version_is_newer(tag) else { return nil }
        return "\(tag) is available (current \(String(cString: uparupa_version()))). Run: uparupa update"
    }

    private struct Release: Decodable {
        let tag_name: String
    }
}
