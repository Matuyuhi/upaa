import AppKit

/// Sizes and colors of the window's chrome, from the design's mockup (M5: tabs, splits and search).
enum Chrome {
    static let inset: CGFloat = 8
    static let headerHeight: CGFloat = 44
    static let tabPanelWidth: CGFloat = 224
    static let sidePanelWidth: CGFloat = 240
    /// Horizontal tabs: the room left of the tabs for the traffic lights.
    static let trafficLightsWidth: CGFloat = 78
    static let inactivePaneAlpha: CGFloat = 0.6

    /// Selected tab, selected file, the branch and the main button.
    static let pill = NSColor(name: nil) { NSColor(white: 1, alpha: $0.isDark ? 0.14 : 0.85) }
    /// The tint of the glass panels.
    static let glass = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.45) : NSColor(white: 1, alpha: 0.5)
    }
    static let addedLine = NSColor.systemGreen.withAlphaComponent(0.18)
    static let removedLine = NSColor.systemRed.withAlphaComponent(0.16)

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSStackView {
    /// Adds the view as wide as the stack inside its insets, less inset on each side.
    func addFullWidth(_ view: NSView, inset: CGFloat = 0) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor, constant: -edgeInsets.left - edgeInsets.right - 2 * inset).isActive = true
    }
}

extension NSView {
    /// Pins the view to the edges of other (usually its superview), inset by the given amount.
    func pin(to other: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset),
        ])
    }
}

/// A rounded panel of the system's glass: Liquid Glass on macOS 26 and later, a blurred material before.
/// Put the panel's views in content.
final class GlassPanel: NSView {
    let content = NSView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        let glass: NSView
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            view.tintColor = Chrome.glass
            view.contentView = content
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.blendingMode = .withinWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
            view.addSubview(content)
            content.pin(to: view)
            glass = view
        }
        addSubview(glass)
        glass.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// A rounded rectangle of one color that follows light and dark mode.
final class Fill: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(_ color: NSColor, cornerRadius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Called with this view's appearance current, so the color resolves for light or dark mode.
        layer?.backgroundColor = color.cgColor
    }
}

/// A Fill that runs an action when clicked (tab items, file rows, toolbar buttons). On, it has the pill color.
final class Clickable: NSView {
    private let fill: Fill
    var onClick: (() -> Void)?
    var isOn: Bool {
        didSet { fill.color = isOn ? Chrome.pill : .clear }
    }

    init(cornerRadius: CGFloat, selected: Bool, _ views: [NSView], spacing: CGFloat = 0, vertical: Bool = false,
         padding: NSEdgeInsets) {
        fill = Fill(selected ? Chrome.pill : .clear, cornerRadius: cornerRadius)
        isOn = selected
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.edgeInsets = padding
        addSubview(fill)
        fill.pin(to: self)
        addSubview(stack)
        stack.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The click goes to this view, not to the labels in it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// The window's ground (design A3, after Arc): a base color with three soft spots of color, for light and dark mode.
final class Backdrop: NSView {
    /// Where each spot is (from the top left, as fractions of the window), how far it reaches, and its colors.
    private static let spots: [(x: CGFloat, y: CGFloat, reach: CGFloat, light: UInt32, dark: UInt32)] = [
        (0.18, 0.22, 0.52, 0xa5c8ff, 0x3b5bdb),
        (0.82, 0.30, 0.46, 0xd0bfff, 0x7048e8),
        (0.60, 0.90, 0.58, 0x99e9f2, 0x0b7285),
    ]
    private static let base = (light: UInt32(0xeef1f6), dark: UInt32(0x111827))

    private let layers = Backdrop.spots.map { _ in CAGradientLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for spot in layers {
            spot.type = .radial
            layer?.addSublayer(spot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = Self.color(dark ? Self.base.dark : Self.base.light).cgColor
        for (layer, spot) in zip(layers, Self.spots) {
            let color = Self.color(dark ? spot.dark : spot.light)
            layer.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            // A layer's y runs up from the bottom. The radius is a fraction of the width and of the height.
            layer.startPoint = CGPoint(x: spot.x, y: 1 - spot.y)
            layer.endPoint = CGPoint(x: spot.x + spot.reach, y: 1 - spot.y + spot.reach)
        }
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}
