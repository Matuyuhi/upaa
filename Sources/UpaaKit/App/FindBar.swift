import AppKit

/// The find bar (Cmd-F, design M5): a capsule of glass floating over the bottom of a pane, with the text to find and
/// the selected match's place among those found, then the buttons for the previous and next match and for closing it.
/// Return and Shift-Return go to the next and the previous match, and Escape closes it.
final class FindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = Chrome.label("", size: 11, color: .secondaryLabelColor)
    /// The text changed.
    var onChange: ((String) -> Void)?
    /// Return or a button asked for another match: the next older one, or the next newer one with back.
    var onMove: ((_ back: Bool) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = String(localized: "Find")
        field.setAccessibilityLabel(String(localized: "Find"))
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)

        let entry = NSStackView(views: [field, count])
        entry.spacing = 6
        entry.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let pill = Fill(Chrome.pill, cornerRadius: 15)
        pill.addSubview(entry)
        entry.pin(to: pill)
        let row = NSStackView(views: [
            pill,
            button("chevron.left", String(localized: "Find Previous"), tag: 0),
            button("chevron.right", String(localized: "Find Next"), tag: 1),
            button("xmark", String(localized: "Close Find"), tag: 2),
        ])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: 220),
            pill.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Liquid Glass where macOS has it (26 and later). Before that, the window's own blur, with the design's shadow.
        let glass: NSView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.cornerRadius = 20
            effect.contentView = row
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 20
            effect.layer?.masksToBounds = true
            effect.addSubview(row)
            glass = effect
            wantsLayer = true
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 15
            layer?.shadowOffset = CGSize(width: 0, height: -10)
        }
        row.pin(to: glass)
        addSubview(glass)
        glass.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows "selected/found", or nothing while there is no text to find.
    func show(count: (selected: Int, total: Int)) {
        self.count.stringValue = field.stringValue.isEmpty ? "" : "\(count.selected)/\(count.total)"
    }

    private func button(_ symbol: String, _ name: String, tag: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name)!, target: self,
                              action: #selector(press(_:)))
        button.isBordered = false
        button.tag = tag
        button.toolTip = name
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.contentTintColor = tag == 2 ? .secondaryLabelColor : .labelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    @objc private func press(_ sender: NSButton) {
        if sender.tag == 2 { onClose?() } else { onMove?(sender.tag == 0) }
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onMove?(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }
}
