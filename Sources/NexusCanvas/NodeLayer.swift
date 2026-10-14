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
    /// Selection ring width (Settings › Accessibility › Selection ring).
    nonisolated(unsafe) static var ringWidth: CGFloat = 3

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
    let decor = DecorLayer()
    let imageLayer = CALayer()
    let badge = CALayer()
    let badgeText = TextLayer()
    /// Technical caption above the node (PROCESS, START, EXTERNAL ENTITY).
    let caption = TextLayer()
    /// Search hits and the present step glow around the node.
    let glowLayer = CAShapeLayer()
    private(set) var node: SceneNode?
    private var state: (selected: Bool, editing: Bool, connectTarget: Bool) = (false, false, false)
    var textScale: CGFloat = 2 {
        didSet {
            guard textScale != oldValue else { return }
            for l in [text, lead, badgeText, decor] as [CALayer] {
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
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = true
        imageLayer.isHidden = true
        addSublayer(imageLayer)
        addSublayer(decor)
        addSublayer(text)
        badge.addSublayer(badgeText)
        badge.isHidden = true
        addSublayer(badge)
        caption.isHidden = true
        addSublayer(caption)
        glowLayer.fillColor = nil
        glowLayer.isHidden = true
        glowLayer.actions = Self.noActions
        insertSublayer(glowLayer, at: 0)
        actions = Self.noActions
        for l in [
            shape, inner, gradient, gradientMask, text, ring, halo, lead, badge, badgeText, decor, imageLayer, caption,
        ]
            as [CALayer]
        {
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
        morph: Bool = false, image: CGImage? = nil, sticker: CGImage? = nil
    ) {
        let sizeChanged = node?.frame.size != n.frame.size
        let lookChanged = node?.appearance != n.appearance || node?.textStyle != n.textStyle
        let contentChanged =
            node?.displayText != n.displayText || node?.isPlaceholder != n.isPlaceholder
            || node?.priority != n.priority || node?.todo != n.todo || node?.hiddenCount != n.hiddenCount
            || node?.textRect != n.textRect || lookChanged || node?.frame.side != n.frame.side
            || node?.branchColor != n.branchColor || node != n
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
            let ns = NSColor(cgColor: color.cgColor) ?? .labelColor
            let rich = NSMutableAttributedString(
                attributedString: n.textStyle.attributed(
                    n.displayText, marks: n.marks, color: ns, linkColor: NSColor(cgColor: theme.ring.cgColor)))
            // Search matches: the substring is highlighted (artboard 47).
            for r in n.matchRanges where r.location + r.length <= rich.length {
                rich.addAttribute(
                    .backgroundColor, value: NSColor(red: 1, green: 0.86, blue: 0.3, alpha: 0.75), range: r)
            }
            if n.todo?.done == true {
                let all = NSRange(location: 0, length: rich.length)
                rich.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: all)
                rich.addAttribute(
                    .foregroundColor, value: NSColor(cgColor: n.appearance.text.alpha(0.55).cgColor)!, range: all)
            }
            text.attributed = rich
            text.frame = n.textRect
            lead.isHidden = true
            decor.node = n
            decor.stickerImage = sticker
            decor.theme = theme
            decor.frame = CGRect(origin: .zero, size: n.frame.size)
            decor.setNeedsDisplay()
            layoutBadge(n, theme: theme, canvas: canvas)
            if let c = n.tech.caption {
                let a = NSAttributedString(
                    string: c,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
                        .foregroundColor: NSColor(cgColor: theme.ink2.cgColor) ?? .secondaryLabelColor,
                        .kern: 1.2, .paragraphStyle: Self.centered,
                    ])
                caption.attributed = a
                caption.isHidden = false
                caption.contentsScale = textScale
                caption.frame = CGRect(x: -60, y: -17, width: n.frame.size.width + 120, height: 13)
                caption.setNeedsDisplay()
            } else {
                caption.isHidden = true
            }
        }
        if let image, !n.imageRect.isEmpty {
            imageLayer.isHidden = false
            imageLayer.contents = image
            imageLayer.frame = n.imageRect
        } else {
            imageLayer.isHidden = true
        }

        if stateChanged || sizeChanged || lookChanged {
            updateRing(theme: theme, canvas: canvas, selected: selected, editing: editing)
        }
        text.isHidden = editing && !n.isPlaceholder
        applyViewState(n, theme: theme)
    }

    /// Opacity, blur and glow from the view (filters, focus, search, present).
    func applyViewState(_ n: SceneNode, theme: Theme) {
        if connectRole == nil { opacity = Float(n.opacity) }
        if n.blurred {
            if filters?.isEmpty ?? true, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(2.5, forKey: kCIInputRadiusKey)
                filters = [blur]
            }
        } else if !(filters?.isEmpty ?? true) {
            filters = nil
        }
        glowLayer.isHidden = !n.glow
        if n.glow {
            let r = CGRect(origin: .zero, size: n.frame.size).insetBy(dx: -4, dy: -4)
            glowLayer.path = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
            glowLayer.strokeColor = NSColor(red: 1, green: 0.8, blue: 0.25, alpha: 0.75).cgColor
            glowLayer.lineWidth = 5
            glowLayer.shadowColor = NSColor(red: 1, green: 0.8, blue: 0.25, alpha: 1).cgColor
            glowLayer.shadowOpacity = 0.8
            glowLayer.shadowRadius = 8
            glowLayer.shadowOffset = .zero
        }
    }

    enum ConnectRole { case source, target, candidate, dimmed }
    private var connectRole: ConnectRole?

    /// Connect mode: everything else dims, the source and target take amber rings.
    func connectState(_ role: ConnectRole?, theme: Theme) {
        guard role != connectRole else { return }
        connectRole = role
        switch role {
        case .source?, .target?:
            opacity = 1
            ring.isHidden = false
            ring.strokeColor = theme.amber.cgColor
            ring.lineWidth = role == .target ? 3 : 2
            ring.shadowOpacity = role == .target ? 1 : 0
            ring.shadowColor = theme.amberSoft.cgColor
        case .candidate?: opacity = 0.55
        case .dimmed?: opacity = 0.3
        case nil:
            opacity = Float(node?.opacity ?? 1)
            if let n = node {
                updateRing(theme: theme, canvas: .white, selected: state.selected, editing: state.editing, refresh: n)
            }
        }
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

    private func updateRing(theme: Theme, canvas: RGBA, selected: Bool, editing: Bool, refresh: SceneNode? = nil) {
        let size = bounds.size
        let radius = (node?.appearance.cornerRadius ?? 10)
        func path(_ outset: CGFloat) -> CGPath {
            let r = CGRect(origin: .zero, size: size).insetBy(dx: -outset, dy: -outset)
            let rr = min(radius + outset, min(r.width, r.height) / 2)
            return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
        }
        ring.isHidden = !(selected || editing)
        ring.path = path(3)
        ring.lineWidth = NodeLayer.ringWidth
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

/// Draws a topic's decorations: leading markers and progress ring, sticker, indicators,
/// label pills and pinned metadata (artboard 07 slots 3, 5, 6, 9).
final class DecorLayer: CALayer {
    var node: SceneNode?
    /// A sticker made with Image Playground (an asset), drawn in the sticker slot.
    var stickerImage: CGImage?
    var theme: Theme = .classic

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let n = node else { return }
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let ink = NSColor(cgColor: n.appearance.text.cgColor) ?? .labelColor
        // Leading slots: progress ring, priority, to-do, other markers.
        var x = n.leadRect.minX
        let cy = n.leadRect.midY
        if let p = n.progress {
            let r = CGRect(x: x + 1, y: cy - 8, width: 16, height: 16)
            let track = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            track.lineWidth = 2
            ink.withAlphaComponent(0.2).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let frac = CGFloat(p.done) / CGFloat(max(p.total, 1))
            arc.appendArc(
                withCenter: CGPoint(x: r.midX, y: r.midY), radius: 7, startAngle: -90,
                endAngle: -90 + 360 * frac, clockwise: false)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            (NSColor(cgColor: theme.ai.cgColor) ?? .systemTeal).setStroke()
            if p.done > 0 { arc.stroke() }
            x += SceneBuilder.markerWidth
        }
        if let pr = n.priority {
            NodeLayer.priorityImage(pr).draw(in: CGRect(x: x, y: cy - 9, width: 18, height: 18))
            x += SceneBuilder.priorityWidth
        }
        if let t = n.todo {
            NodeLayer.todoImage(done: t.done, theme: theme).draw(in: CGRect(x: x, y: cy - 8, width: 16, height: 16))
            x += SceneBuilder.todoWidth
        }
        for m in n.otherMarkers {
            if let mk = MarkerLibrary.marker(m) {
                let c = NSColor(cgColor: RGBA(hex: mk.color).cgColor) ?? .gray
                let r = CGRect(x: x, y: cy - 9, width: 18, height: 18)
                c.setFill()
                NSBezierPath(ovalIn: r).fill()
                let s = NSAttributedString(
                    string: mk.glyph,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.white,
                        .paragraphStyle: NodeLayer.centered,
                    ])
                s.draw(in: r.offsetBy(dx: 0, dy: 2))
            }
            x += SceneBuilder.markerWidth
        }
        drawTech(n, ink: ink, ctx: ctx)
        // Sticker.
        if let img = stickerImage, !n.stickerRect.isEmpty {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: n.stickerRect.maxY + n.stickerRect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: n.stickerRect.insetBy(dx: 1, dy: 1))
            ctx.restoreGState()
        } else if let st = n.sticker, !n.stickerRect.isEmpty {
            let glyph = st.hasPrefix("emoji:") ? String(st.dropFirst(6)) : st.contains("/") ? "★" : st
            NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 20)])
                .draw(at: CGPoint(x: n.stickerRect.minX + 2, y: n.stickerRect.minY))
        }
        // Indicators.
        for (i, ind) in n.indicators.enumerated() where i < n.indicatorRects.count {
            let r = n.indicatorRects[i]
            let color = ind == .ai ? NSColor(cgColor: theme.ai.cgColor)! : ink.withAlphaComponent(0.6)
            NSAttributedString(
                string: ind.glyph,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color,
                    .paragraphStyle: NodeLayer.centered,
                ]
            ).draw(in: r.offsetBy(dx: 0, dy: 1))
        }
        // Label pills.
        for (i, l) in n.labels.enumerated() where i < n.labelRects.count {
            let r = n.labelRects[i]
            let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            (NSColor(cgColor: n.branchColor.alpha(0.16).cgColor) ?? .gray).setFill()
            pill.fill()
            NSAttributedString(
                string: l,
                attributes: [
                    .font: SceneBuilder.labelFont, .foregroundColor: ink.withAlphaComponent(0.85),
                    .paragraphStyle: NodeLayer.centered,
                ]
            ).draw(in: r.offsetBy(dx: 0, dy: 2))
        }
        // Pinned metadata.
        if !n.pinned.isEmpty {
            let text = n.pinned.map { "\($0.key) \($0.value)" }.joined(separator: "  ·  ")
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    .foregroundColor: ink.withAlphaComponent(0.6),
                ]
            ).draw(at: n.pinnedRect.origin)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Technical decorations: data-store accent bar, icon, kicker, lead text, risk badge,
    /// and the rule-check flag.
    private func drawTech(_ n: SceneNode, ink: NSColor, ctx: CGContext) {
        let t = n.tech
        let tint = NSColor(cgColor: (t.tint ?? n.appearance.text).cgColor) ?? ink
        if let a = t.accent {
            (NSColor(cgColor: a.cgColor) ?? tint).setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 6, height: bounds.height)).fill()
            let edge = NSBezierPath()
            edge.move(to: CGPoint(x: 0, y: 1))
            edge.line(to: CGPoint(x: bounds.width, y: 1))
            edge.move(to: CGPoint(x: 0, y: bounds.height - 1))
            edge.line(to: CGPoint(x: bounds.width, y: bounds.height - 1))
            edge.lineWidth = 2
            (NSColor(cgColor: a.cgColor) ?? tint).setStroke()
            edge.stroke()
        }
        if let icon = t.icon, let path = TechIcons.path(icon, in: t.iconRect) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(tint.cgColor)
            ctx.setLineWidth(1.6 * t.iconRect.width / 24)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
        let small: [NSAttributedString.Key: Any] = [
            .font: SceneBuilder.kickerFont, .foregroundColor: tint, .kern: 0.6,
        ]
        if let k = t.kicker {
            NSAttributedString(string: k, attributes: small).draw(at: t.kickerRect.origin)
        }
        if let l = t.leadText {
            NSAttributedString(string: l, attributes: small).draw(at: t.leadTextRect.origin)
        }
        if let b = t.badge {
            let r = t.badgeRect
            let c = NSColor(cgColor: (t.badgeColor ?? n.branchColor).cgColor) ?? tint
            let pill = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if b.count == 1 {
                c.setFill()
                pill.fill()
            } else {
                c.setStroke()
                pill.lineWidth = 1
                pill.stroke()
            }
            NSAttributedString(
                string: b,
                attributes: [
                    .font: SceneBuilder.badgeFont, .foregroundColor: b.count == 1 ? NSColor.white : c,
                    .paragraphStyle: NodeLayer.centered,
                ]
            ).draw(in: r.offsetBy(dx: 0, dy: 2))
        }
        if t.flagged {
            let r = CGRect(x: bounds.width - 17, y: 3, width: 14, height: 14)
            (NSColor(cgColor: theme.critical.cgColor) ?? .systemRed).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSAttributedString(
                string: "!",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.white,
                    .paragraphStyle: NodeLayer.centered,
                ]
            ).draw(in: r.offsetBy(dx: 0, dy: 1))
        }
    }
}
