import AppKit
import NexusCore
import NexusTheme
@preconcurrency import QuartzCore

/// Draws attributed text with AppKit string drawing, the same engine that measured it.
final class TextLayer: CALayer {
    var attributed = NSAttributedString() {
        didSet { if !attributed.isEqual(to: oldValue) { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        attributed.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One node: shape, text, leading markers, fold badge, and selection ring.
final class NodeLayer: CALayer {
    let id: NodeID
    let shape = CAShapeLayer()
    let text = TextLayer()
    let ring = CAShapeLayer()
    let halo = CAShapeLayer()
    let lead = TextLayer()
    let badge = CALayer()
    let badgeText = TextLayer()
    private(set) var node: SceneNode?
    private var state: (selected: Bool, editing: Bool, connectTarget: Bool) = (false, false, false)
    var textScale: CGFloat = 2 {
        didSet {
            guard textScale != oldValue else { return }
            for l in [text, lead, badgeText] {
                l.contentsScale = textScale
                l.setNeedsDisplay()
            }
        }
    }

    init(id: NodeID) {
        self.id = id
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        for l in [halo, ring] {
            l.fillColor = nil
            l.isHidden = true
            addSublayer(l)
        }
        addSublayer(shape)
        addSublayer(lead)
        addSublayer(text)
        badge.addSublayer(badgeText)
        badge.isHidden = true
        addSublayer(badge)
        actions = Self.noActions
        for l in [shape, text, ring, halo, lead, badge, badgeText] as [CALayer] { l.actions = Self.noActions }
    }

    override init(layer: Any) {
        id = (layer as? NodeLayer)?.id ?? "?"
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated(unsafe) static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "frame": NSNull(),
        "opacity": NSNull(), "transform": NSNull(), "shadowPath": NSNull(), "backgroundColor": NSNull(),
        "sublayers": NSNull(),
    ]

    /// Applies a scene node. Geometry other than size is driven by the animator.
    func apply(_ n: SceneNode, theme: Theme, selected: Bool, primary: Bool, editing: Bool) {
        let sizeChanged = node?.frame.size != n.frame.size
        let lookChanged = node?.look != n.look || node?.textStyle != n.textStyle
        let contentChanged =
            node?.displayText != n.displayText || node?.isPlaceholder != n.isPlaceholder
            || node?.priority != n.priority || node?.todo != n.todo || node?.hiddenCount != n.hiddenCount
            || node?.textRect != n.textRect || lookChanged || node?.frame.side != n.frame.side
        let stateChanged = state != (selected, editing, false)
        node = n
        state = (selected, editing, false)
        let size = n.frame.size
        if sizeChanged { bounds = CGRect(origin: .zero, size: size) }

        if sizeChanged || lookChanged {
            let look = n.look
            let inset = look.borderWidth / 2
            let r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let radius = min(look.cornerRadius, Double(min(size.width, size.height) / 2))
            shape.path = CGPath(
                roundedRect: r, cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset),
                transform: nil)
            shape.fillColor = look.fill.cgColor
            shape.strokeColor = look.borderWidth > 0 ? look.borderColor.cgColor : nil
            shape.lineWidth = look.borderWidth
            shape.lineDashPattern = look.dashed ? [4, 3] : nil
            shadowOpacity = Float(look.shadowOpacity > 0 ? 1 : 0)
            shadowColor = RGBA.black.alpha(look.shadowOpacity).cgColor
            shadowRadius = 1
            shadowOffset = CGSize(width: 0, height: 1)
            shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius,
                transform: nil)
        }

        if contentChanged {
            let color = n.isPlaceholder ? n.look.text.alpha(0.4) : n.look.text
            var attrs = n.textStyle.attributes(color: NSColor(cgColor: color.cgColor) ?? .labelColor)
            if n.todo?.done == true {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NSColor(cgColor: n.look.text.alpha(0.55).cgColor)
            }
            text.attributed = NSAttributedString(string: n.displayText, attributes: attrs)
            text.frame = n.textRect
            layoutLead(n, theme: theme)
            layoutBadge(n, theme: theme)
        }

        if stateChanged || sizeChanged || lookChanged {
            updateRing(theme: theme, selected: selected, editing: editing)
        }
        text.isHidden = editing && !n.isPlaceholder
    }

    private func layoutLead(_ n: SceneNode, theme: Theme) {
        guard n.priority != nil || n.todo != nil else {
            lead.isHidden = true
            return
        }
        lead.isHidden = false
        let w = (n.priority != nil ? SceneBuilder.priorityWidth : 0) + (n.todo != nil ? SceneBuilder.todoWidth : 0)
        lead.frame = CGRect(x: n.textRect.minX - w, y: (n.frame.size.height - 18) / 2, width: w, height: 18)
        let s = NSMutableAttributedString()
        if let p = n.priority {
            let a = NSTextAttachment()
            a.image = Self.priorityImage(p)
            a.bounds = CGRect(x: 0, y: -4, width: 18, height: 18)
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " "))
        }
        if let t = n.todo {
            let a = NSTextAttachment()
            a.image = Self.todoImage(done: t.done, theme: theme)
            a.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
            s.append(NSAttributedString(attachment: a))
        }
        lead.attributed = s
    }

    private func layoutBadge(_ n: SceneNode, theme: Theme) {
        guard n.hiddenCount > 0 else {
            badge.isHidden = true
            return
        }
        badge.isHidden = false
        let label = "+\(n.hiddenCount)"
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let fg: NSColor = theme.root.foreground == .white || theme.isDark ? .white : .white
        let attr = NSAttributedString(
            string: label,
            attributes: [.font: font, .foregroundColor: fg, .paragraphStyle: Self.centered])
        let w = max(22, ceil(attr.size().width) + 10)
        let h: CGFloat = 22
        let size = n.frame.size
        let origin: CGPoint =
            switch n.frame.side {
            case .left: CGPoint(x: -w + 9, y: (size.height - h) / 2)
            case .down: CGPoint(x: (size.width - w) / 2, y: size.height - 9)
            case .right: CGPoint(x: size.width - 9, y: (size.height - h) / 2)
            }
        badge.frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        badge.cornerRadius = h / 2
        badge.backgroundColor = n.branchColor.cgColor
        badge.borderColor = theme.canvas.cgColor
        badge.borderWidth = 2
        badgeText.frame = CGRect(x: 0, y: 4, width: w, height: 14)
        badgeText.attributed = attr
    }

    private func updateRing(theme: Theme, selected: Bool, editing: Bool) {
        let size = bounds.size
        let radius = (node?.look.cornerRadius ?? 10)
        func path(_ outset: CGFloat) -> CGPath {
            let r = CGRect(origin: .zero, size: size).insetBy(dx: -outset, dy: -outset)
            let rr = min(radius + outset, min(r.width, r.height) / 2)
            return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
        }
        ring.isHidden = !(selected || editing)
        ring.path = path(3)
        ring.lineWidth = 2
        ring.strokeColor = theme.ring.cgColor
        ring.shadowColor = theme.ringSoft.cgColor
        ring.shadowOpacity = selected ? 1 : 0
        ring.shadowRadius = 12
        ring.shadowOffset = CGSize(width: 0, height: 8)
        halo.isHidden = !editing
        halo.path = path(6.5)
        halo.lineWidth = 5
        halo.strokeColor = theme.ringSoft.cgColor
    }

    nonisolated(unsafe) static let centered: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    static func priorityImage(_ n: Int) -> NSImage {
        let color = Tokens.priorityColors[max(0, min(8, n - 1))]
        return NSImage(size: CGSize(width: 18, height: 18), flipped: false) { r in
            NSColor(cgColor: color.cgColor)?.setFill()
            NSBezierPath(ovalIn: r).fill()
            let s = NSAttributedString(
                string: "\(n)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.white,
                    .paragraphStyle: centered,
                ])
            s.draw(in: r.offsetBy(dx: 0, dy: -3))
            return true
        }
    }

    static func todoImage(done: Bool, theme: Theme) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            if done {
                NSColor(cgColor: theme.ai.cgColor)?.setFill()
                box.fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: 4, y: 8.5))
                check.line(to: CGPoint(x: 7, y: 5.5))
                check.line(to: CGPoint(x: 12, y: 11))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                NSColor(cgColor: theme.ink2.cgColor)?.setStroke()
                box.lineWidth = 1.5
                box.stroke()
            }
            return true
        }
    }
}
