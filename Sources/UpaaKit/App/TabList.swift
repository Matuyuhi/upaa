import AppKit

/// The window's sidebar: a source list of the tabs, each with its name and the directory of its focused pane, under
/// a heading with the button for a new tab. The list's look, selection and hover are AppKit's own. A row shows a close
/// button while the pointer is on it, the middle button closes it too, and a row can be dragged to another place, as
/// the tabs along the top can. AppKit's sidebar
/// glass shows what is behind the window, not upaa's gradient, so the sidebar lays the window's ground (the gradient
/// and the card, lined up with the window's) under a pane of the design's glass color.
final class TabList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// A row was picked by the user.
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
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
        table.registerForDraggedTypes([Self.row])
        table.draggingDestinationFeedbackStyle = .gap
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
        reloading = true
        // Rows rebuilt under the pointer would lose its hover, so only a change of names or places rebuilds them.
        if items.map({ [$0.title, $0.place] }) != self.items.map({ [$0.title, $0.place] }) {
            self.items = items
            table.reloadData()
        }
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
        let cell = Row()
        cell.textField = title
        cell.onClose = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = self.table.row(for: cell)
            if row >= 0 { self.onClose?(row) }
        }
        cell.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.close.leadingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Dragging a row

    private static let row = NSPasteboard.PasteboardType("local.upaa.tab")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.row)
        return item
    }

    /// The row is dragged as it shows, from where it is: its whole row view, placed by its frame in the table. The
    /// picture AppKit makes on its own is built from the cell's textField, which here sits in a stack, and it jumped
    /// up away from the pointer as the drag started.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first, let view = tableView.rowView(atRow: row, makeIfNecessary: false),
              let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: picture)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(picture)
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self],
                                       searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(view.frame, contents: image)
        }
    }

    /// A drop just above or just below the dragged row would leave it where it is, so it is refused: the gap that
    /// shows a drop would otherwise open beside the row as soon as the drag starts, and the row would look as if it
    /// had jumped.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, let from = dragged(info), row != from, row != from + 1
        else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = dragged(info) else { return false }
        onMove?(from, from < row ? row - 1 : row)
        return true
    }

    private func dragged(_ info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: Self.row).flatMap(Int.init)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

/// A tab's row, with a close button at its right while the pointer is on it.
private final class Row: NSTableCellView {
    let close = NSButton()
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "閉じる")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        close.isBordered = false
        close.isHidden = true
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "タブを閉じる"
        close.target = self
        close.action = #selector(closeTab)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false }

    override func mouseExited(with event: NSEvent) { close.isHidden = true }

    override func otherMouseUp(with event: NSEvent) { onClose?() }

    @objc private func closeTab() { onClose?() }
}
