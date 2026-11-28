import AppKit

/// The Settings window (Cmd-,). As in other Mac apps' settings, a change takes effect as soon as it is made.
final class SettingsWindow: NSWindowController {
    private let fontButton = NSPopUpButton()
    private let fallbackButton = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    /// Fallbacks the file lists after the first. The window shows only the first; the rest are kept as they are.
    private let moreFallbacks: [String]
    private let onChange: (_ families: [String], _ size: Double) -> Void

    /// families is the font, then its fallbacks. onChange gets them back, with the size in points, after each change.
    init(families: [String], size: Double, onChange: @escaping (_ families: [String], _ size: Double) -> Void) {
        moreFallbacks = Array(families.dropFirst(2))
        self.onChange = onChange
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "設定"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Monospaced families for the font, each shown in its own face. Any family can be a fallback, such as a
        // Nerd Font with only icons.
        let manager = NSFontManager.shared
        let monospaced = Set((manager.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap {
            NSFont(name: $0, size: NSFont.systemFontSize)?.familyName
        })
        for family in monospaced.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            fontButton.addItem(withTitle: family)
            if let font = manager.font(withFamily: family, traits: [], weight: 5, size: NSFont.systemFontSize) {
                fontButton.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
        }
        Self.select(families.first, in: fontButton)
        fallbackButton.addItem(withTitle: "なし")
        fallbackButton.menu?.addItem(.separator())
        fallbackButton.addItems(withTitles: manager.availableFontFamilies)
        if families.count > 1 { Self.select(families[1], in: fallbackButton) }

        let formatter = NumberFormatter()
        formatter.minimum = 4
        formatter.maximum = 200
        formatter.maximumFractionDigits = 1
        sizeField.formatter = formatter
        sizeField.doubleValue = size
        sizeField.alignment = .right
        sizeField.cell?.sendsActionOnEndEditing = true
        sizeStepper.minValue = 4
        sizeStepper.maxValue = 200
        sizeStepper.doubleValue = size
        sizeStepper.valueWraps = false
        for control in [fontButton, fallbackButton, sizeField, sizeStepper] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }

        let note = NSTextField(wrappingLabelWithString:
            "フォントにない文字（Nerd Font のアイコンなど）はフォールバックで描きます。保存先: "
                + (Config.fileURL.path as NSString).abbreviatingWithTildeInPath)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 260
        let size = NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])
        size.spacing = 4
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "フォント:"), fontButton],
            [NSTextField(labelWithString: "サイズ:"), size],
            [NSTextField(labelWithString: "フォールバック:"), fallbackButton],
            [NSGridCell.emptyContentView, note],
        ])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.row(at: 3).topPadding = 4
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fontButton.widthAnchor.constraint(equalToConstant: 260),
            fallbackButton.widthAnchor.constraint(equalTo: fontButton.widthAnchor),
            note.widthAnchor.constraint(equalTo: fontButton.widthAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 48),
        ])
        window.contentView = content
        // Not the size field, which would open with its text selected.
        window.initialFirstResponder = fontButton
        window.setContentSize(content.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Selects family, adding it if the list lacks it (a name the file gives that is not a family name, or a font
    /// that is not installed), so that what the file says is kept.
    private static func select(_ family: String?, in button: NSPopUpButton) {
        guard let family else { return }
        if button.item(withTitle: family) == nil { button.addItem(withTitle: family) }
        button.selectItem(withTitle: family)
    }

    @objc private func changed(_ sender: NSControl) {
        if sender === sizeStepper { sizeField.doubleValue = sizeStepper.doubleValue } else { sizeStepper.doubleValue = sizeField.doubleValue }
        guard let font = fontButton.titleOfSelectedItem else { return }
        let fallback = fallbackButton.indexOfSelectedItem > 0 ? fallbackButton.titleOfSelectedItem.map { [$0] } ?? [] : []
        onChange([font] + fallback + moreFallbacks, sizeField.doubleValue)
    }
}
