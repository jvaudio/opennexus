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
    /// Second outline for the double border.
    let inner = CAShapeLayer()
    let gradient = CAGradientLayer()
    let gradientMask = CAShapeLayer()
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
        gradient.mask = gradientMask
        gradient.isHidden = true
        addSublayer(shape)
        addSublayer(gradient)
        inner.fillColor = nil
        inner.isHidden = true
        addSublayer(inner)
        addSublayer(lead)
        addSublayer(text)
        badge.addSublayer(badgeText)
        badge.isHidden = true
        addSublayer(badge)
        actions = Self.noActions
        for l in [shape, inner, gradient, gradientMask, text, ring, halo, lead, badge, badgeText] as [CALayer] {
            l.actions = Self.noActions
        }
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
        "sublayers": NSNull(), "colors": NSNull(), "lineDashPattern": NSNull(), "shadowColor": NSNull(),
        "shadowOpacity": NSNull(), "shadowOffset": NSNull(), "shadowRadius": NSNull(),
    ]

    /// Applies a scene node. Geometry other than position is applied here; position is
    /// driven by the animator.
    func apply(
        _ n: SceneNode, theme: Theme, canvas: RGBA, selected: Bool, primary: Bool, editing: Bool,
        morph: Bool = false
    ) {
        let sizeChanged = node?.frame.size != n.frame.size
        let lookChanged = node?.appearance != n.appearance || node?.textStyle != n.textStyle
        let contentChanged =
            node?.displayText != n.displayText || node?.isPlaceholder != n.isPlaceholder
            || node?.priority != n.priority || node?.todo != n.todo || node?.hiddenCount != n.hiddenCount
            || node?.textRect != n.textRect || lookChanged || node?.frame.side != n.frame.side
            || node?.branchColor != n.branchColor
        let stateChanged = state != (selected, editing, false)
        if morph, lookChanged, node != nil {
            // Node style changes morph: a 300 ms cross-fade on the glide curve.
            let t = CATransition()
            t.type = .fade
            t.duration = Motion.nodeStyleCycle
            t.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            add(t, forKey: "morph")
        }
        node = n
        state = (selected, editing, false)
        let size = n.frame.size
        if sizeChanged { bounds = CGRect(origin: .zero, size: size) }

        if sizeChanged || lookChanged {
            drawShape(n, canvas: canvas)
        }

        if contentChanged {
            var color = n.appearance.text
            if n.isPlaceholder { color = color.alpha(0.4) }
            var attrs = n.textStyle.attributes(color: NSColor(cgColor: color.cgColor) ?? .labelColor)
            if n.todo?.done == true {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NSColor(cgColor: n.appearance.text.alpha(0.55).cgColor)
            }
            text.attributed = NSAttributedString(string: n.displayText, attributes: attrs)
            text.frame = n.textRect
            layoutLead(n, theme: theme)
            layoutBadge(n, theme: theme, canvas: canvas)
        }

        if stateChanged || sizeChanged || lookChanged {
            updateRing(theme: theme, canvas: canvas, selected: selected, editing: editing)
        }
        text.isHidden = editing && !n.isPlaceholder
    }

    private func drawShape(_ n: SceneNode, canvas: RGBA) {
        let a = n.appearance
        let size = n.frame.size
        let bw = CGFloat(a.borderWidth)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: bw / 2, dy: bw / 2)
        let radius = max(0, CGFloat(a.cornerRadius) - bw / 2)
        var outline = ShapeLibrary.path(a.shape, in: rect, radius: radius)
        if a.border == .hand {
            outline = ShapeLibrary.wobble(
                outline, seed: UInt64(abs(id.rawValue.hashValue % 9973)) + 11,
                amplitude: 1.2)
        }
        let open = ShapeLibrary.openShapes.contains(a.shape)

        if a.isUnderline {
            let line = CGMutablePath()
            line.move(to: CGPoint(x: 0, y: size.height - bw / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height - bw / 2))
            shape.path = line
            shape.fillColor = nil
        } else {
            shape.path = outline
            switch a.fill {
            case .solid(let c) where !open: shape.fillColor = c.cgColor
            default: shape.fillColor = nil
            }
        }
        if case .gradient(let c1, let c2) = a.fill, !open {
            gradient.isHidden = false
            gradient.frame = CGRect(origin: .zero, size: size)
            gradient.colors = [c2.cgColor, c1.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradientMask.path = outline
        } else {
            gradient.isHidden = true
        }
        let stroked = a.border != .none && bw > 0
        shape.strokeColor = stroked ? a.borderColor.cgColor : nil
        shape.lineWidth = bw
        shape.lineCap = a.border == .dotted ? .round : .butt
        shape.lineDashPattern =
            switch a.border {
            case .dashed: [NSNumber(value: Double(bw) * 3), NSNumber(value: Double(bw) * 2)]
            case .dotted: [0.01, NSNumber(value: Double(bw) * 2.2)]
            default: nil
            }
        if a.border == .double && stroked {
            inner.isHidden = false
            let i = rect.insetBy(dx: bw * 2, dy: bw * 2)
            inner.path = ShapeLibrary.path(a.shape, in: i, radius: max(0, radius - bw * 2))
            inner.strokeColor = a.borderColor.cgColor
            inner.lineWidth = max(1, bw / 2)
        } else {
            inner.isHidden = true
        }
        if let sh = a.shadow {
            shape.shadowColor = sh.color.alpha(1).cgColor
            shape.shadowOpacity = Float(sh.color.a)
            shape.shadowOffset = CGSize(width: sh.dx, height: sh.dy)
            shape.shadowRadius = CGFloat(sh.radius)
            shape.shadowPath = a.isUnderline ? nil : outline
        } else {
            shape.shadowOpacity = 0
        }
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

    private func layoutBadge(_ n: SceneNode, theme: Theme, canvas: RGBA) {
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
        badge.borderColor = canvas.cgColor
        badge.borderWidth = 2
        badgeText.frame = CGRect(x: 0, y: 4, width: w, height: 14)
        badgeText.attributed = attr
    }

    private func updateRing(theme: Theme, canvas: RGBA, selected: Bool, editing: Bool) {
        let size = bounds.size
        let radius = (node?.appearance.cornerRadius ?? 10)
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
