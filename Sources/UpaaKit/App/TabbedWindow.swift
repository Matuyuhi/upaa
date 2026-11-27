import AppKit

/// One window with a row of tabs above the selected terminal. Each tab has its own shell, and the row shows the
/// title each shell's program set. The row is a stack view, so turning both orientations puts it down the side instead.
/// The tab actions reach this object through the responder chain, as the window's delegate.
final class TabbedWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let makeTerminal: () -> TerminalView?
    private let root = NSStackView()
    private let tabRow = NSStackView()
    private var tabs: [TerminalView] = []
    private var selected = 0
    /// The window closed (its last tab closed, or the window itself).
    var onClose: (() -> Void)?

    init(window: NSWindow, first: TerminalView, makeTerminal: @escaping () -> TerminalView?) {
        self.window = window
        self.makeTerminal = makeTerminal
        super.init()
        root.orientation = .vertical
        root.spacing = 0
        tabRow.orientation = .horizontal
        tabRow.distribution = .fillEqually
        tabRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        root.addArrangedSubview(tabRow)
        tabRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.delegate = self
        add(first)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @objc func newTab(_ sender: Any?) {
        guard let terminal = makeTerminal() else { return NSSound.beep() }
        add(terminal)
    }

    @objc func closeTab(_ sender: Any?) {
        close(tabs[selected])
    }

    @objc func showNextTab(_ sender: Any?) {
        select((selected + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        select((selected + tabs.count - 1) % tabs.count)
    }

    /// Cmd-1 to Cmd-9, from the menu item's tag. Cmd-9 is the last tab.
    @objc func showTab(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard index < tabs.count else { return NSSound.beep() }
        select(index)
    }

    @objc private func tabClicked(_ sender: NSButton) {
        select(sender.tag)
    }

    /// Opens the terminal as a tab to the right of the selected one. Its shell exiting closes the tab.
    private func add(_ terminal: TerminalView) {
        terminal.session.onTitle = { [weak self] in self?.refresh() }
        terminal.session.onExit = { [weak self, weak terminal] in
            if let self, let terminal { self.close(terminal) }
        }
        let index = tabs.isEmpty ? 0 : selected + 1
        tabs.insert(terminal, at: index)
        select(index)
    }

    /// Closing the last tab closes the window.
    private func close(_ terminal: TerminalView) {
        guard let index = tabs.firstIndex(of: terminal) else { return }
        tabs.remove(at: index)
        // The view and its session go away once it leaves the window, which ends the shell.
        terminal.removeFromSuperview()
        guard !tabs.isEmpty else { return window.close() }
        select(index < selected || selected == tabs.count ? selected - 1 : selected)
    }

    private func select(_ index: Int) {
        let terminal = tabs[index]
        if terminal.superview == nil {
            root.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
            root.addArrangedSubview(terminal)
            terminal.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            // Take all the height the tab row leaves.
            terminal.setContentHuggingPriority(.init(1), for: .vertical)
        }
        selected = index
        window.makeFirstResponder(terminal)
        refresh()
    }

    /// Rebuilds the row of tabs and the window title. The row shows only when there are two tabs or more.
    private func refresh() {
        tabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, terminal) in tabs.enumerated() {
            let button = NSButton(title: terminal.session.title ?? "upaa", target: self, action: #selector(tabClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.state = index == selected ? .on : .off
            button.tag = index
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tabRow.addArrangedSubview(button)
        }
        tabRow.isHidden = tabs.count < 2
        window.title = tabs[selected].session.title ?? "upaa"
    }
}
