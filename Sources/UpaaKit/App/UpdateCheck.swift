import CUpaaCore
import Foundation

/// Checks whether a newer version is published on GitHub Releases. It only notifies; it does not update.
///
/// Queries GitHub at most once a day. Otherwise the previous result is used.
/// Setting the environment variable UPAA_NO_UPDATE_CHECK makes this do nothing.
enum UpdateCheck {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Matuyuhi/upaa/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckedKey = "updateCheck.lastChecked"
    private static let latestTagKey = "updateCheck.latestTag"

    /// If a newer version is available, passes a message to notify. notify is called on the main thread.
    /// If this does not finish while the startup face is playing, the result is used on the next launch.
    static func run(notify: @escaping (String) -> Void) {
        guard ProcessInfo.processInfo.environment["UPAA_NO_UPDATE_CHECK"] == nil else { return }
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
            // Do not show again a version that the previous result already announced.
            guard release.tag_name != known, let message = message(for: release.tag_name) else { return }
            DispatchQueue.main.async { notify(message) }
        }.resume()
    }

    private static func message(for tag: String) -> String? {
        guard upaa_version_is_newer(tag) else { return nil }
        return "\(tag) is available (current \(String(cString: upaa_version()))). Run: upaa update"
    }

    private struct Release: Decodable {
        let tag_name: String
    }
}
