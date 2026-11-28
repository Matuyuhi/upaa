import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private lazy var fontFamily = config.fontFamily
    /// A config problem not shown yet. The next terminal to open shows it.
    private lazy var problem = config.problem
    /// AppKit does not keep a window alive by itself, so open windows are held here until they close.
    private var windows: [TabbedWindow] = []
    /// Every open terminal, for a change of font.
    private let terminals = NSHashTable<TerminalView>.weakObjects()
    private var settings: SettingsWindow?
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// Points Cmd-+ and Cmd-− added to the config's size.
    private var zoom = 0.0
    private var fontSize: Double { min(200, max(4, config.fontSize + zoom)) }

    private var scale: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard case let (window, terminal)? = makeWindow() else {
            NSLog("upaa: failed to start the terminal")
            NSApp.terminate(nil)
            return
        }
        watchConfig()
        UpdateCheck.run { [weak terminal] message in terminal?.showNote(message) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Cmd-N. Opens a window slightly below and to the right of the current one.
    @objc func newWindow(_ sender: Any?) {
        guard case let (window, _)? = makeWindow() else { return NSSound.beep() }
        if let current = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Cmd-,.
    @objc func showSettings(_ sender: Any?) {
        let settings = settings ?? SettingsWindow(families: config.fontFamilies, size: config.fontSize) { [weak self] in
            self?.saveFont(families: $0, size: $1)
        }
        self.settings = settings
        settings.showWindow(nil)
    }

    /// Cmd-+, Cmd-− and Cmd-0. They change the size in every window until upaa quits, without touching the config file.
    @objc func biggerFont(_ sender: Any?) { zoom(by: 1) }
    @objc func smallerFont(_ sender: Any?) { zoom(by: -1) }
    @objc func defaultFontSize(_ sender: Any?) { zoom(by: -zoom) }

    private func zoom(by points: Double) {
        let size = min(200, max(4, fontSize + points))
        guard size != fontSize else { return }
        zoom = size - config.fontSize
        applyFont()
    }

    /// Saves the font to the config file. The file's change puts it in the windows.
    private func saveFont(families: [String], size: Double) {
        do {
            try Config.saveFont(families: families, size: size)
        } catch {
            if let window = settings?.window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        configChanged()
    }

    /// Watches the config file, its folder (an editor may save by replacing the file) and the folder above it (for a
    /// folder made later). Each source is made again after a change, since the file it was opened on may be gone.
    private func watchConfig() {
        watchers.forEach { $0.cancel() }
        let file = Config.fileURL.resolvingSymlinksInPath()
        watchers = [file, file.deletingLastPathComponent(), file.deletingLastPathComponent().deletingLastPathComponent()]
            .compactMap { url in
                let descriptor = open(url.path, O_EVTONLY)
                guard descriptor >= 0 else { return nil }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
                source.setEventHandler { [weak self] in self?.configChanged() }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                return source
            }
    }

    /// Reads the config file again and puts what it says in every window and in Settings.
    private func configChanged() {
        watchConfig()
        let new = Config.load()
        guard new.text != config.text else { return }
        // A size chosen in the settings or written in the file is the size to show, not one to add Cmd-+/- to.
        if new.fontSize != config.fontSize { zoom = 0 }
        config = new
        fontFamily = config.fontFamily
        for terminal in terminals.allObjects {
            terminal.session.config = config
            terminal.session.setColors(dark: terminal.effectiveAppearance.isDark)
            if let problem = config.problem { terminal.showNote(problem) }
        }
        for window in NSApp.windows where window.delegate is TabbedWindow {
            window.appearance = config.backgroundIsDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
            // The window's colors come from config when drawn, so draw them again.
            var views = window.contentView.map { [$0] } ?? []
            while let view = views.popLast() {
                view.needsDisplay = true
                views += view.subviews
            }
        }
        applyFont()
        settings?.show(families: config.fontFamilies, size: config.fontSize)
    }

    /// Puts the font in every open terminal, and steps every window's size by the new cell.
    private func applyFont() {
        for terminal in terminals.allObjects where !terminal.setFont(name: fontFamily, size: fontSize) {
            terminal.showNote("config: font-family not found, kept the font")
        }
        guard let cell = terminals.anyObject?.renderer.cellSize else { return }
        for window in NSApp.windows where window.delegate is TabbedWindow {
            window.contentResizeIncrements = NSSize(width: Double(cell.width) / scale, height: Double(cell.height) / scale)
        }
    }

    /// A window sized for the config's columns and rows, with one tab.
    private func makeWindow() -> (NSWindow, TerminalView)? {
        guard let terminal = makeTerminal() else { return nil }
        let renderer = terminal.renderer
        let pixels = renderer.pixelSize(cols: config.cols, rows: config.rows)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Make the size change in steps of one cell.
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        // A background the config names sets light or dark mode for the whole window; otherwise the system's does.
        if let dark = config.backgroundIsDark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        let background = NSColor(name: nil) { [weak self] in
            let config = self?.config ?? Config()
            let rgb = config.background(dark: $0.isDark)
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: config.backgroundOpacity)
        }
        let tabs = TabbedWindow(window: window, first: terminal, background: background) { [weak self] cwd in
            self?.makeTerminal(cwd: cwd)
        }
        tabs.onClose = { [weak self, weak tabs] in self?.windows.removeAll { $0 === tabs } }
        windows.append(tabs)
        return (window, terminal)
    }

    /// A terminal view with its own shell, started in cwd (nil for the home directory).
    private func makeTerminal(cwd: String? = nil) -> TerminalView? {
        let scale = scale
        func makeRenderer(device: MTLDevice) -> Renderer? {
            // The window's card behind the terminal has its default background, so the terminal draws none.
            try? Renderer(device: device, fontName: fontFamily, fontSize: fontSize, scale: scale, mascot: true,
                         backgroundOpacity: 0)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = makeRenderer(device: device) ?? {
                  problem = "config: font-family not found, using the default"
                  fontFamily = Config().fontFamily
                  return makeRenderer(device: device)
              }(),
              let session = TerminalSession(cols: UInt16(config.cols), rows: UInt16(config.rows), cwd: cwd, config: config)
        else { return nil }
        let view = TerminalView(session: session, renderer: renderer)
        terminals.add(view)
        if let problem {
            NSLog("upaa: \(problem)")
            view.showNote(problem)
            self.problem = nil
        }
        return view
    }
}
