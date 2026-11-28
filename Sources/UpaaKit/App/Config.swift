import CUpaaCore
import Foundation

/// Settings from $XDG_CONFIG_HOME/upaa/config (~/.config/upaa/config when the variable is unset). Zig parses the text.
final class Config {
    let handle: OpaquePointer
    let fontFamily: String
    /// Points.
    let fontSize: Double
    /// How much of the default background color covers what is behind the window (0 to 1).
    let backgroundOpacity: Double
    /// Cells.
    let cols: Int
    let rows: Int
    /// The first line that could not be read, or nil.
    let problem: String?

    /// With no text, every setting is the default. Snapshots use this, so the baseline images do not depend on the user's file.
    init(text: String = "") {
        let bytes = Array(text.utf8)
        handle = upaa_config_new(bytes, bytes.count)!
        let values = upaa_config_values(handle)
        fontFamily = String(cString: values.font_family)
        fontSize = values.font_size
        backgroundOpacity = values.background_opacity
        cols = Int(values.window_width)
        rows = Int(values.window_height)
        problem = values.problem.map { String(cString: $0) }
    }

    deinit {
        upaa_config_free(handle)
    }

    /// The terminal's default background in light or dark mode, as 0xRRGGBB.
    func background(dark: Bool) -> UInt32 {
        upaa_config_background(handle, dark)
    }

    /// Whether the background the file names is dark, or nil if it names none (the two modes' backgrounds differ).
    var backgroundIsDark: Bool? {
        let rgb = background(dark: false)
        guard rgb == background(dark: true) else { return nil }
        let luminance = 0.2126 * Double(rgb >> 16 & 0xff) + 0.7152 * Double(rgb >> 8 & 0xff) + 0.0722 * Double(rgb & 0xff)
        return luminance < 128
    }

    /// Reads the user's file. Without one, every setting is the default.
    static func load() -> Config {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        guard let data = try? Data(contentsOf: base.appendingPathComponent("upaa/config")) else { return Config() }
        return Config(text: String(decoding: data, as: UTF8.self))
    }
}
