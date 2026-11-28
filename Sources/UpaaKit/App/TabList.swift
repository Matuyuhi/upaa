import AppKit

/// The window's sidebar: a source list of the tabs, each with its name and the directory of its focused pane, under
/// a heading with the button for a new tab, on a glass panel. The list's look, selection and hover are AppKit's own.
final class TabList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// A row was picked by the user.
    var onSelect: ((Int) -> Void)?
    private var items: [(title: String, place: String)] = []
    private let table = NSTableView()
    /// Set while the rows are being replaced, so that the new selection is not taken as the user's.
    private var reloading = false

    init() {
        super.init(nibName: nil, bundle: nil)
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .sourceList
        table.headerView = nil
        table.backgroundColor = .clear
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
        // The panel runs up behind the traffic lights, as AppKit's floating sidebar does. The list sits over it, beside
        // it in the view, since the glass places its own content only when it is laid out.
        let panel = GlassPanel(cornerRadius: 16)
        view.addSubview(panel)
        panel.pin(to: view, inset: 8)
        for subview in [heading, scroll] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The safe area keeps the heading below the traffic lights and the toolbar.
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            heading.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            heading.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        self.view = view
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
