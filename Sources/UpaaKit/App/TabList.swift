import AppKit

/// The window's sidebar: a source list of the tabs, each with its name and the directory of its focused pane, under
/// a heading with the button for a new tab. The list's look, selection and hover are AppKit's own. AppKit's sidebar
/// glass shows what is behind the window, not upaa's gradient, so the sidebar lays the window's ground (the gradient
/// and the card, lined up with the window's) under a pane of the design's glass color.
final class TabList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// A row was picked by the user.
    var onSelect: ((Int) -> Void)?
    private var items: [(title: String, place: String)] = []
    private let table = NSTableView()
    /// Set while the rows are being replaced, so that the new selection is not taken as the user's.
    private var reloading = false
    private let ground = Backdrop(frame: .zero)
    private var groundPinned = false

    /// background is the card's color, as in the rest of the window.
    init(background: NSColor) {
        super.init(nibName: nil, bundle: nil)
        let card = Fill(background)
        ground.addSubview(card)
        card.pin(to: ground)
        let glass = Fill(NSColor(name: nil) {
            $0.isDark ? NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.45) : NSColor(white: 1, alpha: 0.5)
        })
        ground.addSubview(glass)
        glass.pin(to: ground)
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .sourceList
        table.headerView = nil
        table.rowHeight = 40
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // The keyboard stays with the terminal.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        // The plus button's action goes up the responder chain to the window's TabbedWindow.
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新しいタブ")!,
                            target: nil, action: #selector(TabbedWindow.newTab(_:)))
        plus.isBordered = false
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "新しいタブ (⌘T)"
        let heading = NSStackView(views: [
            Chrome.label("タブ", size: 11, weight: .semibold, color: .secondaryLabelColor), NSView(), plus,
        ])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Chrome.tabPanelWidth, height: 400))
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        for subview in [ground, heading, scroll] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The safe area keeps the heading below the traffic lights and the toolbar.
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heading.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    /// The ground covers the window's content, so that its gradient lines up with the one beside the sidebar.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard !groundPinned, let content = view.window?.contentView else { return }
        groundPinned = true
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func show(_ items: [(title: String, place: String)], selected: Int) {
        self.items = items
        reloading = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        reloading = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title = Chrome.label(items[row].title, size: 13)
        let stack = NSStackView(views: [title, Chrome.label(items[row].place, size: 11, mono: true, color: .secondaryLabelColor)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        let cell = NSTableCellView()
        cell.textField = title
        cell.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}
