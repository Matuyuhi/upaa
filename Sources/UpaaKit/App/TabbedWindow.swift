import AppKit

/// One window with tabs, laid out as design A3. A tab is one terminal, or split views with terminals (panes) at their
/// ends. Each pane has its own shell, and a tab is named after the title its focused pane's program set.
/// With the tabs down the left side, the window's ground is a color gradient, as in Arc, with the tab list on it and the
/// terminal as a rounded card. With the tabs at the top (Cmd-B), the terminal fills the window. Either way the title or
/// tabs and the tools float over the terminal's top in glass capsules, its text starting below them. The right panel
/// (Cmd-J) shows the changed files of the focused pane's git repository: down the side it takes room from the
/// terminal, with the tabs at the top it floats over the terminal as a card.
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
        var panes: [TerminalView] { terminals(in: top) }
    }

    private let window: NSWindow
    /// Makes a terminal whose shell starts in the given directory.
    private let makeTerminal: (String?) -> TerminalView?
    private var tabs: [Tab] = []
    private var selected = 0
    /// The window closed (its last tab closed, or the window itself).
    var onClose: (() -> Void)?

    /// Tabs down the left side, or along the top.
    private var vertical = true
    private var sidePanelWanted = false
    /// The layout in place: vertical, and whether the right panel shows.
    private var arranged: (Bool, Bool)?
    private var layout: [NSLayoutConstraint] = []
    private var timer: Timer?

    /// Holds the selected tab's view.
    private let host = Host()
    /// Sits on the window's backdrop, as Arc's sidebar does.
    private let tabPanel = NSView()
    private let tabList = NSStackView()
    private let tabCapsule = GlassPanel(cornerRadius: 18)
    private let tabStrip = NSStackView()
    private let header = NSStackView()
    private let titleLabel = Chrome.label("", size: 13, weight: .semibold)
    private let branchLabel = Chrome.label("", size: 11, mono: true, color: .secondaryLabelColor)
    private let branchCapsule = Fill(Chrome.pill, cornerRadius: 9)
    /// The tab's name and branch, floating over the terminal when the tabs are down the side.
    private let titleCapsule = GlassPanel(cornerRadius: 17)
    private let changesLabel: NSTextField
    private let changesButton: Clickable
    private let shellButton: Clickable
    private let sidePanel = GlassPanel(cornerRadius: 16)
    private let changes = ChangesPanel()

    init(window: NSWindow, first: TerminalView, makeTerminal: @escaping (String?) -> TerminalView?) {
        self.window = window
        self.makeTerminal = makeTerminal
        let toolButton = { (label: NSTextField) in
            Clickable(cornerRadius: 14, selected: false, [label], padding: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
        }
        let changesLabel = Chrome.label("変更", size: 12)
        self.changesLabel = changesLabel
        changesButton = toolButton(changesLabel)
        shellButton = toolButton(Chrome.label("シェル", size: 12))
        super.init()

        // The window was made to fit the terminal; the chrome around it is added here.
        let terminalSize = window.contentRect(forFrameRect: window.frame).size
        let ground = Backdrop()
        window.contentView = ground
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar makes the title bar taller, which puts the traffic lights in line with the header.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(
            width: terminalSize.width + 3 * Chrome.inset + Chrome.tabPanelWidth,
            height: terminalSize.height + 2 * Chrome.inset + Chrome.headerHeight + 4))
        for view in [host, tabPanel, header, sidePanel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            ground.addSubview(view)
        }
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        buildTabPanel()
        buildHeader()
        sidePanel.content.addSubview(changes)
        changes.pin(to: sidePanel.content)
        changes.onUpdate = { [weak self] count, branch in
            self?.changesLabel.stringValue = count.map { "変更 \($0)" } ?? "変更"
            self?.branchLabel.stringValue = branch ?? ""
            self?.refresh()
        }

        watch(first)
        tabs.append(Tab(first))
        select(0)
        // The tab list follows the shells' directories, and the panel the files, without a signal from either.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.readChanges() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose?()
    }

    private func buildTabPanel() {
        let heading = NSStackView(views: [
            Chrome.label("タブ", size: 11, weight: .semibold, color: .secondaryLabelColor), NSView(), plusButton(size: 22),
        ])
        heading.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        tabList.orientation = .vertical
        tabList.spacing = 2
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .vertical)
        let line = NSBox()
        line.boxType = .separator
        let footer = Chrome.label("⌘1〜9 で切り替え", size: 11, color: .secondaryLabelColor)
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        // The top of the panel is left for the traffic lights.
        column.edgeInsets = NSEdgeInsets(top: Chrome.headerHeight, left: 8, bottom: 10, right: 8)
        tabPanel.addSubview(column)
        column.pin(to: tabPanel)
        column.addFullWidth(heading)
        column.addFullWidth(tabList)
        column.addArrangedSubview(space)
        column.addFullWidth(line)
        column.addFullWidth(footer, inset: 6)

        tabStrip.spacing = 2
        tabStrip.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        tabCapsule.content.addSubview(tabStrip)
        tabStrip.pin(to: tabCapsule.content)
    }

    private func buildHeader() {
        let label = NSStackView(views: [branchLabel])
        label.edgeInsets = NSEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        branchCapsule.addSubview(label)
        label.pin(to: branchCapsule)
        let title = NSStackView(views: [titleLabel, branchCapsule])
        title.spacing = 8
        title.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 6)
        title.heightAnchor.constraint(equalToConstant: 34).isActive = true
        titleCapsule.content.addSubview(title)
        title.pin(to: titleCapsule.content)

        let hide = NSButton(image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "右パネル")!,
                            target: self, action: #selector(toggleSidePanel(_:)))
        hide.isBordered = false
        hide.contentTintColor = .secondaryLabelColor
        changesButton.onClick = { [weak self] in
            guard let self, !self.sidePanelWanted else { return }
            self.toggleSidePanel(nil)
        }
        shellButton.onClick = { [weak self] in
            guard let self else { return }
            // Off, it puts a shell beside the pane; on, it moves to the other pane.
            self.tabs[self.selected].panes.count > 1 ? self.movePane(by: 1) : self.split(vertical: true)
        }
        let tools = NSStackView(views: [changesButton, shellButton, hide])
        tools.spacing = 2
        tools.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        for view in tools.arrangedSubviews { view.heightAnchor.constraint(equalToConstant: 28).isActive = true }
        hide.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let toolbar = GlassPanel(cornerRadius: 17)
        toolbar.content.addSubview(tools)
        tools.pin(to: toolbar.content)

        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [tabCapsule, titleCapsule, space, toolbar] as [NSView] { header.addArrangedSubview(view) }
        header.spacing = 8
    }

    private func plusButton(size: CGFloat) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新しいタブ")!,
                              target: self, action: #selector(newTab(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        return button
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

    /// Cmd-B. Moves the tabs between the left side and the top.
    @objc func toggleTabLayout(_ sender: Any?) {
        vertical.toggle()
        refresh()
    }

    /// Cmd-J. Shows or hides the right panel.
    @objc func toggleSidePanel(_ sender: Any?) {
        sidePanelWanted.toggle()
        refresh()
        readChanges()
    }

    // MARK: Tabs and panes

    /// Follows the pane's title, focus and shell. Its shell exiting closes the pane.
    private func watch(_ terminal: TerminalView) {
        terminal.session.onTitle = { [weak self] in self?.refresh() }
        terminal.onFocus = { [weak self, weak terminal] in
            guard let self, let terminal, let tab = self.tab(of: terminal) else { return }
            tab.focus = terminal
            self.refresh()
            self.readChanges()
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
        readChanges()
    }

    /// Puts the tab in the host, in place of the one shown. A pane that was in a split view keeps what the split view
    /// set on it, so the host sizes its view directly rather than through autoresizing or constraints.
    private func show(_ tab: Tab) {
        host.subviews.forEach { $0.removeFromSuperview() }
        tab.top.translatesAutoresizingMaskIntoConstraints = true
        tab.top.autoresizingMask = []
        host.addSubview(tab.top)
        host.needsLayout = true
    }

    /// Reads the git state of the focused pane's directory, for the panel, the change count and the branch.
    private func readChanges() {
        guard window.occlusionState.contains(.visible) else { return }
        changes.refresh(directory: tabs[selected].focus.session.cwd)
    }

    // MARK: Layout

    /// Brings the layout, the tab list, the toolbar and the window title up to date.
    private func refresh() {
        let tab = tabs[selected]
        // With the tabs at the top, a shell beside the pane takes the card's place.
        let sidePanelShown = sidePanelWanted && (vertical || tab.panes.count == 1)
        if arranged.map({ $0 != (vertical, sidePanelShown) }) ?? true {
            arrange(sidePanel: sidePanelShown)
        }

        let title = tab.focus.session.title ?? "upaa"
        window.title = title
        titleLabel.stringValue = title
        branchCapsule.isHidden = !vertical || branchLabel.stringValue.isEmpty
        let list = vertical ? tabList : tabStrip
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = tabItem(tab, selected: index == selected)
            item.onClick = { [weak self] in self?.select(index) }
            if vertical { tabList.addFullWidth(item) } else { tabStrip.addArrangedSubview(item) }
        }
        if !vertical { tabStrip.addArrangedSubview(plusButton(size: 30)) }

        // A split or a closed pane can change which panes are along the top.
        host.needsLayout = true
        let panes = tab.panes
        for pane in panes { pane.alphaValue = panes.count == 1 || pane === tab.focus ? 1 : Chrome.inactivePaneAlpha }
        shellButton.isOn = panes.count > 1
        changesButton.isOn = sidePanelShown
    }

    /// Down the side: the tab's name, and the directory of its focused pane. At the top: the name alone.
    private func tabItem(_ tab: Tab, selected: Bool) -> Clickable {
        let title = tab.focus.session.title ?? "upaa"
        guard vertical else {
            let item = Clickable(cornerRadius: 15, selected: selected,
                                 [Chrome.label(title, size: 12, weight: selected ? .semibold : .regular)],
                                 padding: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12))
            item.heightAnchor.constraint(equalToConstant: 30).isActive = true
            item.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            return item
        }
        var place = tab.focus.session.cwd ?? ""
        let home = NSHomeDirectory()
        if place.hasPrefix(home) { place = "~" + place.dropFirst(home.count) }
        return Clickable(cornerRadius: 10, selected: selected, [
            Chrome.label(title, size: 13, weight: selected ? .semibold : .regular),
            Chrome.label(place, size: 11, color: .secondaryLabelColor),
        ], spacing: 2, vertical: true, padding: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))
    }

    private func arrange(sidePanel shown: Bool) {
        arranged = (vertical, shown)
        tabPanel.isHidden = !vertical
        // The glass header floats over the terminal, whose text starts below it. Down the side the terminal is a card on
        // the backdrop, and the header sits inside its top; with the tabs at the top the terminal fills the window.
        host.layer?.cornerRadius = vertical ? Chrome.terminalCornerRadius : 0
        host.topInset = (vertical ? 0 : Chrome.inset) + Chrome.headerHeight + 4
        tabCapsule.isHidden = vertical
        titleCapsule.isHidden = !vertical
        sidePanel.isHidden = !shown
        NSLayoutConstraint.deactivate(layout)
        let ground = window.contentView!
        let inset = Chrome.inset
        layout = [header.heightAnchor.constraint(equalToConstant: Chrome.headerHeight)]
        if vertical {
            layout += [
                tabPanel.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: inset),
                tabPanel.topAnchor.constraint(equalTo: ground.topAnchor, constant: inset),
                tabPanel.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -inset),
                tabPanel.widthAnchor.constraint(equalToConstant: Chrome.tabPanelWidth),
                header.topAnchor.constraint(equalTo: host.topAnchor),
                header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
                header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
                host.leadingAnchor.constraint(equalTo: tabPanel.trailingAnchor, constant: inset),
                host.topAnchor.constraint(equalTo: ground.topAnchor, constant: inset),
                host.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -inset),
                host.trailingAnchor.constraint(equalTo: shown ? sidePanel.leadingAnchor : ground.trailingAnchor, constant: -inset),
                sidePanel.topAnchor.constraint(equalTo: ground.topAnchor, constant: inset),
                sidePanel.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -inset),
                sidePanel.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -inset),
                sidePanel.widthAnchor.constraint(equalToConstant: Chrome.sidePanelWidth),
            ]
        } else {
            layout += [
                header.topAnchor.constraint(equalTo: ground.topAnchor, constant: inset),
                header.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 12 + Chrome.trafficLightsWidth),
                header.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -12),
                host.topAnchor.constraint(equalTo: ground.topAnchor),
                host.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: ground.bottomAnchor),
                sidePanel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
                sidePanel.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -14),
                sidePanel.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -38),
                sidePanel.widthAnchor.constraint(equalToConstant: Chrome.cardWidth),
            ]
        }
        NSLayoutConstraint.activate(layout)
    }
}

/// Holds the selected tab's view and gives it all of its own size each time it is laid out.
private final class Host: NSView {
    /// Room the panes along the top edge keep free above their text.
    var topInset: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        for view in subviews {
            view.frame = bounds
            view.layoutSubtreeIfNeeded()
            for pane in terminals(in: view) {
                let touchesTop = abs(pane.convert(pane.bounds, to: self).maxY - bounds.maxY) < 1
                pane.topInset = touchesTop ? topInset : 0
            }
        }
    }
}

/// The terminals in a tab's view, from left to right and top to bottom.
private func terminals(in view: NSView) -> [TerminalView] {
    if let terminal = view as? TerminalView { return [terminal] }
    return (view as? NSSplitView)?.arrangedSubviews.flatMap(terminals(in:)) ?? []
}
