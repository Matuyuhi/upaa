import AppKit

/// One window with a row of tabs above the selected tab. A tab is one terminal, or split views with terminals (panes)
/// at their ends. Each pane has its own shell, and a tab is named after the title its focused pane's program set.
/// The row is a stack view, so turning both orientations puts it down the side instead.
/// The menu actions reach this object through the responder chain, as the window's delegate.
final class TabbedWindow: NSObject, NSWindowDelegate {
    private final class Tab {
        /// The terminal, or the split view that holds the tab's panes.
        var top: NSView
        /// The pane that has (or last had) the keyboard.
        var focus: TerminalView

        init(_ terminal: TerminalView) {
            top = terminal
            focus = terminal
        }

        /// Panes from left to right, top to bottom.
        var panes: [TerminalView] { Tab.panes(in: top) }

        private static func panes(in view: NSView) -> [TerminalView] {
            if let terminal = view as? TerminalView { return [terminal] }
            return (view as? NSSplitView)?.arrangedSubviews.flatMap(panes(in:)) ?? []
        }
    }

    private let window: NSWindow
    /// Makes a terminal whose shell starts in the given directory.
    private let makeTerminal: (String?) -> TerminalView?
    private let root = NSStackView()
    private let tabRow = NSStackView()
    private var tabs: [Tab] = []
    private var selected = 0
    /// The window closed (its last tab closed, or the window itself).
    var onClose: (() -> Void)?

    init(window: NSWindow, first: TerminalView, makeTerminal: @escaping (String?) -> TerminalView?) {
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
        let tab = Tab(first)
        watch(first)
        tabs.append(tab)
        select(0)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Menu actions

    /// Opens a tab to the right of the selected one, in the focused pane's directory.
    @objc func newTab(_ sender: Any?) {
        guard let terminal = makeTerminal(tabs[selected].focus.session.cwd) else { return NSSound.beep() }
        watch(terminal)
        tabs.insert(Tab(terminal), at: selected + 1)
        select(selected + 1)
    }

    /// Closes the focused pane, and the tab with its last pane.
    @objc func closePane(_ sender: Any?) {
        close(tabs[selected].focus)
    }

    /// Puts a new pane to the right of the focused one.
    @objc func splitRight(_ sender: Any?) {
        split(vertical: true)
    }

    /// Puts a new pane below the focused one.
    @objc func splitDown(_ sender: Any?) {
        split(vertical: false)
    }

    @objc func showNextPane(_ sender: Any?) {
        movePane(by: 1)
    }

    @objc func showPreviousPane(_ sender: Any?) {
        movePane(by: -1)
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

    // MARK: Tabs and panes

    /// Follows the pane's title, focus and shell. Its shell exiting closes the pane.
    private func watch(_ terminal: TerminalView) {
        terminal.session.onTitle = { [weak self] in self?.refresh() }
        terminal.onFocus = { [weak self, weak terminal] in
            guard let self, let terminal, let tab = self.tab(of: terminal) else { return }
            tab.focus = terminal
            self.refresh()
        }
        terminal.session.onExit = { [weak self, weak terminal] in
            if let self, let terminal { self.close(terminal) }
        }
    }

    private func tab(of terminal: TerminalView) -> Tab? {
        tabs.first { terminal.isDescendant(of: $0.top) }
    }

    private func split(vertical: Bool) {
        let tab = tabs[selected]
        let pane = tab.focus
        guard let terminal = makeTerminal(pane.session.cwd) else { return NSSound.beep() }
        watch(terminal)
        let parent: NSSplitView
        if let split = pane.superview as? NSSplitView, split.isVertical == vertical {
            parent = split
            parent.insertArrangedSubview(terminal, at: parent.arrangedSubviews.firstIndex(of: pane)! + 1)
        } else {
            parent = NSSplitView()
            parent.isVertical = vertical
            parent.dividerStyle = .thin
            replace(pane, with: parent, in: tab)
            parent.addArrangedSubview(pane)
            parent.addArrangedSubview(terminal)
        }
        equalize(parent)
        window.makeFirstResponder(terminal)
    }

    /// Gives every pane of the split view the same size.
    private func equalize(_ split: NSSplitView) {
        window.contentView?.layoutSubtreeIfNeeded()
        let count = split.arrangedSubviews.count
        let length = (split.isVertical ? split.bounds.width : split.bounds.height) - CGFloat(count - 1) * split.dividerThickness
        for index in 0..<(count - 1) {
            split.setPosition(length * CGFloat(index + 1) / CGFloat(count) + CGFloat(index) * split.dividerThickness, ofDividerAt: index)
        }
    }

    /// Puts view where old was: in old's split view, or as the tab's top view.
    private func replace(_ old: NSView, with view: NSView, in tab: Tab) {
        if let split = old.superview as? NSSplitView {
            let index = split.arrangedSubviews.firstIndex(of: old)!
            old.removeFromSuperview()
            split.insertArrangedSubview(view, at: index)
        } else {
            let shown = old.superview != nil
            old.removeFromSuperview()
            tab.top = view
            if shown { show(tab) }
        }
    }

    private func movePane(by step: Int) {
        let tab = tabs[selected]
        let panes = tab.panes
        guard let index = panes.firstIndex(of: tab.focus), panes.count > 1 else { return }
        window.makeFirstResponder(panes[(index + step + panes.count) % panes.count])
    }

    /// Closes the pane; a tab's last pane closes the tab, and the last tab closes the window.
    /// A view and its session go away once they leave the window, which ends the shell.
    private func close(_ terminal: TerminalView) {
        guard let index = tabs.firstIndex(where: { terminal.isDescendant(of: $0.top) }) else { return }
        let tab = tabs[index]
        guard terminal !== tab.top, let split = terminal.superview as? NSSplitView else {
            return closeTab(at: index)
        }
        terminal.removeFromSuperview()
        if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
            only.removeFromSuperview()
            replace(split, with: only, in: tab)
        } else {
            equalize(split)
        }
        if tab.focus === terminal { tab.focus = tab.panes[0] }
        if index == selected { window.makeFirstResponder(tab.focus) }
        refresh()
    }

    private func closeTab(at index: Int) {
        tabs[index].top.removeFromSuperview()
        tabs.remove(at: index)
        guard !tabs.isEmpty else { return window.close() }
        select(index < selected || selected == tabs.count ? selected - 1 : selected)
    }

    private func select(_ index: Int) {
        let tab = tabs[index]
        if tab.top.superview == nil { show(tab) }
        selected = index
        window.makeFirstResponder(tab.focus)
        refresh()
    }

    /// Puts the tab below the row of tabs, in place of the one shown.
    private func show(_ tab: Tab) {
        root.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        root.addArrangedSubview(tab.top)
        tab.top.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        // Take all the height the tab row leaves.
        tab.top.setContentHuggingPriority(.init(1), for: .vertical)
    }

    /// Rebuilds the row of tabs and the window title. The row shows only when there are two tabs or more.
    private func refresh() {
        tabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let button = NSButton(title: tab.focus.session.title ?? "upaa", target: self, action: #selector(tabClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.state = index == selected ? .on : .off
            button.tag = index
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tabRow.addArrangedSubview(button)
        }
        tabRow.isHidden = tabs.count < 2
        window.title = tabs[selected].focus.session.title ?? "upaa"
    }
}
