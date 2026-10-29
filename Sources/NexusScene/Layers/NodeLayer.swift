import CoreGraphics
import CoreImage
import Foundation
import NexusCore
import NexusLayout
import NexusTheme
@preconcurrency import QuartzCore

/// Draws styled text with the platform's engine, the same one that measured it.
package final class TextLayer: CALayer {
    package var attributed = StyledText() {
        didSet { if !attributed.isEqual(to: oldValue) { setNeedsDisplay() } }
    }

    package override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }

    package override init(layer: Any) { super.init(layer: layer) }
    package required init?(coder: NSCoder) { fatalError() }

    package override func draw(in ctx: CGContext) {
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        attributed.draw(with: bounds, options: [.lineFragmentOrigin, .fontLeading], in: ctx)
    }
}

/// One node: shape, text, leading markers, fold badge, and selection ring.
package final class NodeLayer: CALayer {
    /// Selection ring width (Settings › Accessibility › Selection ring).
    package nonisolated(unsafe) static var ringWidth: CGFloat = 3

    package let id: NodeID
    package let shape = CAShapeLayer()
    /// Second outline for the double border.
    package let inner = CAShapeLayer()
    package let gradient = CAGradientLayer()
    package let gradientMask = CAShapeLayer()
    package let text = TextLayer()
    package let ring = CAShapeLayer()
    package let halo = CAShapeLayer()
    package let lead = TextLayer()
    package let decor = DecorLayer()
    package let imageLayer = CALayer()
    package let badge = CALayer()
    package let badgeText = TextLayer()
    /// Xmind's fold control: a "−" where the branch leaves, shown while the pointer is over
    /// a topic with children (D215). Once folded, the "+N" badge takes its place.
    package let foldButton = CAShapeLayer()
    /// Set by the canvas on hover.
    package var showsFoldButton = false {
        didSet { if oldValue != showsFoldButton { foldButton.isHidden = !showsFoldButton || !badge.isHidden } }
    }
    /// Technical caption above the node (PROCESS, START, EXTERNAL ENTITY).
    package let caption = TextLayer()
    /// Search hits and the present step glow around the node.
    package let glowLayer = CAShapeLayer()
    package private(set) var node: SceneNode?
    private var state: (selected: Bool, editing: Bool, connectTarget: Bool) = (false, false, false)
    package var textScale: CGFloat = 2 {
        didSet {
            guard textScale != oldValue else { return }
            for l in textLayers {
                l.contentsScale = textScale
                l.setNeedsDisplay()
            }
        }
    }

    /// The layers that draw text and decorations, at `textScale`.
    private var textLayers: [CALayer] { [text, lead, badgeText, decor, caption] }

    package init(id: NodeID) {
        self.id = id
        super.init()
        for l in textLayers { l.contentsScale = textScale }
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
        foldButton.isHidden = true
        foldButton.lineWidth = 1.5
        foldButton.actions = Self.noActions
        addSublayer(foldButton)
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

    package override init(layer: Any) {
        id = (layer as? NodeLayer)?.id ?? "?"
        super.init(layer: layer)
    }

    package required init?(coder: NSCoder) { fatalError() }

    package nonisolated(unsafe) static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "frame": NSNull(),
        "opacity": NSNull(), "transform": NSNull(), "shadowPath": NSNull(), "backgroundColor": NSNull(),
        "sublayers": NSNull(), "colors": NSNull(), "lineDashPattern": NSNull(), "shadowColor": NSNull(),
        "shadowOpacity": NSNull(), "shadowOffset": NSNull(), "shadowRadius": NSNull(),
    ]

    /// Applies a scene node. Geometry other than position is applied here; position is
    /// driven by the animator.
    package func apply(
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
            let rich = NSMutableAttributedString(
                attributedString: n.textStyle.attributed(
                    n.displayText, marks: n.marks, color: .fixed(color.cgColor), linkColor: .fixed(theme.ring.cgColor)))
            // Search matches: the substring is highlighted (artboard 47).
            for r in n.matchRanges where r.location + r.length <= rich.length {
                rich.addAttribute(
                    TextKey.background, value: CGColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.75), range: r)
            }
            if n.todo?.done == true {
                let all = NSRange(location: 0, length: rich.length)
                rich.addAttribute(TextKey.strikethrough, value: 1, range: all)
                rich.addAttribute(TextKey.color, value: n.appearance.text.alpha(0.55).cgColor, range: all)
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
                let a = StyledText(
                    c,
                    TextAttributes(
                        font: Fonts.mono(9.5, .medium), color: .fixed(theme.ink2.cgColor), paragraph: .centered,
                        kern: 1.2))
                caption.attributed = a
                caption.isHidden = false
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
    package func applyViewState(_ n: SceneNode, theme: Theme) {
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
            glowLayer.strokeColor = CGColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 0.75)
            glowLayer.lineWidth = 5
            glowLayer.shadowColor = CGColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1)
            glowLayer.shadowOpacity = 0.8
            glowLayer.shadowRadius = 8
            glowLayer.shadowOffset = .zero
        }
    }

    package enum ConnectRole { case source, target, candidate, dimmed }
    private var connectRole: ConnectRole?

    /// Connect mode: everything else dims, the source and target take amber rings.
    package func connectState(_ role: ConnectRole?, theme: Theme) {
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
                outline, seed: Self.wobbleSeed(id),
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

    private func layoutBadge(_ n: SceneNode, theme: Theme, canvas: RGBA) {
        guard n.hiddenCount > 0 else {
            badge.isHidden = true
            layoutFoldButton(n, canvas: canvas)
            return
        }
        badge.isHidden = false
        let label = "+\(n.hiddenCount)"
        let attr = StyledText(
            label, TextAttributes(font: Fonts.system(11, .bold), color: .system(.white), paragraph: .centered))
        let w = max(22, ceil(attr.lineSize.width) + 10)
        let h: CGFloat = 22
        // Over the edge where the branch lines leave, 9 pt onto the topic (D250).
        let j = Self.junction(n)
        let origin: CGPoint =
            switch j.edge {
            case .left: CGPoint(x: j.point.x - w + 9, y: j.point.y - h / 2)
            case .right: CGPoint(x: j.point.x - 9, y: j.point.y - h / 2)
            case .top: CGPoint(x: j.point.x - w / 2, y: j.point.y - h + 9)
            case .bottom: CGPoint(x: j.point.x - w / 2, y: j.point.y - 9)
            }
        badge.frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        badge.cornerRadius = h / 2
        badge.backgroundColor = n.branchColor.cgColor
        badge.borderColor = canvas.cgColor
        badge.borderWidth = 2
        badgeText.frame = CGRect(x: 0, y: 4, width: w, height: 14)
        badgeText.attributed = attr
        foldButton.isHidden = true
    }

    /// A hand-drawn border's wobble for a topic: the same on every launch (FNV-1a of the
    /// id; `hashValue` is seeded per process, so the border used to change each launch).
    package static func wobbleSeed(_ id: NodeID) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in id.rawValue.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h % 9973 + 11
    }

    /// Diameter of the "−" fold control, in canvas points.
    package static let foldButtonSize: CGFloat = 16

    /// Where the topic's branch lines leave it, in its own coordinates; without one (a
    /// technical canvas), the middle of the edge on its branch side.
    package static func junction(_ n: SceneNode) -> BranchJunction {
        if let j = n.junction { return j }
        let size = n.frame.size
        return switch n.frame.side {
        case .left: BranchJunction(CGPoint(x: 0, y: size.height / 2), .left)
        case .down: BranchJunction(CGPoint(x: size.width / 2, y: size.height), .bottom)
        case .right: BranchJunction(CGPoint(x: size.width, y: size.height / 2), .right)
        }
    }

    /// The "−" just past the topic's edge where its branch lines leave it, over the line (D250).
    private func layoutFoldButton(_ n: SceneNode, canvas: RGBA) {
        let d = Self.foldButtonSize
        let j = Self.junction(n)
        let out = d / 2 + 2
        let center: CGPoint =
            if let s = j.slant {
                CGPoint(x: j.point.x + s.dx * out, y: j.point.y + s.dy * out)
            } else {
                switch j.edge {
                case .left: CGPoint(x: j.point.x - d / 2 - 2, y: j.point.y)
                case .right: CGPoint(x: j.point.x + d / 2 + 2, y: j.point.y)
                case .top: CGPoint(x: j.point.x, y: j.point.y - d / 2 - 2)
                case .bottom: CGPoint(x: j.point.x, y: j.point.y + d / 2 + 2)
                }
            }
        foldButton.frame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let circle = CGMutablePath()
        circle.addEllipse(in: CGRect(x: 0.75, y: 0.75, width: d - 1.5, height: d - 1.5))
        circle.move(to: CGPoint(x: d * 0.3, y: d / 2))
        circle.addLine(to: CGPoint(x: d * 0.7, y: d / 2))
        foldButton.path = circle
        foldButton.fillColor = canvas.cgColor
        foldButton.strokeColor = n.branchColor.cgColor
        foldButton.isHidden = !showsFoldButton || n.hiddenCount > 0
    }

    /// Where a click folds or unfolds this topic, in its own coordinates: the "+N" badge
    /// when folded, the "−" while it shows. Slightly larger than drawn, for the pointer.
    package var foldControlRect: CGRect? {
        if !badge.isHidden { return badge.frame.insetBy(dx: -2, dy: -2) }
        if !foldButton.isHidden { return foldButton.frame.insetBy(dx: -4, dy: -4) }
        return nil
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

    package static let centered = TextParagraph.centered

    /// The priority marker: a numbered disc, 18 pt.
    package static func drawPriority(_ n: Int, in rect: CGRect, context ctx: CGContext, flipped: Bool = true) {
        let color = Tokens.priorityColors[max(0, min(8, n - 1))].cgColor
        Graphics.platform.drawPicture(size: CGSize(width: 18, height: 18), in: rect, context: ctx, flipped: flipped) {
            c, r in
            Shapes.fill(Shapes.oval(in: r), color, in: c)
            StyledText(
                "\(n)", TextAttributes(font: Fonts.system(10.5, .bold), color: .system(.white), paragraph: .centered)
            ).draw(in: r.offsetBy(dx: 0, dy: -3), context: c, flipped: false)
        }
    }

    /// The to-do marker: a box, ticked when done, 16 pt.
    package static func drawTodo(
        done: Bool, theme: Theme, in rect: CGRect, context ctx: CGContext, flipped: Bool = true
    ) {
        let ai = theme.ai.cgColor
        let ink2 = theme.ink2.cgColor
        Graphics.platform.drawPicture(size: CGSize(width: 16, height: 16), in: rect, context: ctx, flipped: flipped) {
            c, r in
            let box = Shapes.roundedRect(r.insetBy(dx: 1, dy: 1), radius: 4)
            if done {
                Shapes.fill(box, ai, in: c)
                let check = CGMutablePath()
                check.move(to: CGPoint(x: 4, y: 8.5))
                check.addLine(to: CGPoint(x: 7, y: 5.5))
                check.addLine(to: CGPoint(x: 12, y: 11))
                Shapes.stroke(check, Graphics.platform.color(.white), width: 2, cap: .round, join: .round, in: c)
            } else {
                Shapes.stroke(box, ink2, width: 1.5, in: c)
            }
        }
    }
}

/// Draws a topic's decorations: leading markers and progress ring, sticker, indicators,
/// label pills and pinned metadata (artboard 07 slots 3, 5, 6, 9).
package final class DecorLayer: CALayer {
    package var node: SceneNode?
    /// A sticker made with Image Playground (an asset), drawn in the sticker slot.
    package var stickerImage: CGImage?
    package var theme: Theme = .classic

    package override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    package override init(layer: Any) { super.init(layer: layer) }
    package required init?(coder: NSCoder) { fatalError() }

    package override func draw(in ctx: CGContext) {
        guard let n = node else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let ink = n.appearance.text.cgColor
        // Leading slots: progress ring, priority, to-do, other markers.
        var x = n.leadRect.minX
        let cy = n.leadRect.midY
        if let p = n.progress {
            let r = CGRect(x: x + 1, y: cy - 8, width: 16, height: 16)
            Shapes.stroke(Shapes.oval(in: r.insetBy(dx: 1, dy: 1)), ink.copy(alpha: 0.2)!, width: 2, in: ctx)
            let arc = CGMutablePath()
            let frac = CGFloat(p.done) / CGFloat(max(p.total, 1))
            arc.addArc(
                center: CGPoint(x: r.midX, y: r.midY), radius: 7, startAngle: -.pi / 2,
                endAngle: (-90 + 360 * frac) * .pi / 180, clockwise: false)
            if p.done > 0 { Shapes.stroke(arc, theme.ai.cgColor, width: 2.4, cap: .round, in: ctx) }
            x += SceneBuilder.markerWidth
        }
        if let pr = n.priority {
            NodeLayer.drawPriority(pr, in: CGRect(x: x, y: cy - 9, width: 18, height: 18), context: ctx)
            x += SceneBuilder.priorityWidth
        }
        if let t = n.todo {
            NodeLayer.drawTodo(
                done: t.done, theme: theme, in: CGRect(x: x, y: cy - 8, width: 16, height: 16), context: ctx)
            x += SceneBuilder.todoWidth
        }
        for m in n.otherMarkers {
            if MarkerLibrary.marker(m) != nil {
                // The legend's drawing: a disc with its glyph, or an eighths pie (D247).
                LegendLayer.drawMarker(m, in: CGRect(x: x, y: cy - 9, width: 18, height: 18), context: ctx)
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
            StyledText(glyph, font: Fonts.system(20))
                .draw(at: CGPoint(x: n.stickerRect.minX + 2, y: n.stickerRect.minY), in: ctx)
        }
        // Indicators.
        for (i, ind) in n.indicators.enumerated() where i < n.indicatorRects.count {
            let r = n.indicatorRects[i]
            let color = ind == .ai ? theme.ai.cgColor : ink.copy(alpha: 0.6)!
            StyledText(
                ind.glyph, TextAttributes(font: Fonts.system(12, .semibold), color: .fixed(color), paragraph: .centered)
            ).draw(in: r.offsetBy(dx: 0, dy: 1), context: ctx)
            if ind == .comment, n.commentCount > 1 {
                StyledText(
                    "\(min(n.commentCount, 99))", TextAttributes(font: Fonts.system(7.5, .bold), color: .fixed(color))
                )
                .draw(at: CGPoint(x: r.maxX - 5, y: r.minY - 2), in: ctx)
            }
        }
        // Label pills.
        for (i, l) in n.labels.enumerated() where i < n.labelRects.count {
            let r = n.labelRects[i]
            Shapes.fill(
                Shapes.roundedRect(r, radius: r.height / 2), n.branchColor.alpha(0.16).cgColor, in: ctx)
            StyledText(
                l,
                TextAttributes(
                    font: SceneBuilder.labelFont, color: .fixed(ink.copy(alpha: 0.85)!), paragraph: .centered)
            ).draw(in: r.offsetBy(dx: 0, dy: 2), context: ctx)
        }
        // Pinned metadata.
        if !n.pinned.isEmpty {
            let text = n.pinned.map { "\($0.key) \($0.value)" }.joined(separator: "  ·  ")
            StyledText(text, TextAttributes(font: Fonts.mono(10.5), color: .fixed(ink.copy(alpha: 0.6)!)))
                .draw(at: n.pinnedRect.origin, in: ctx)
        }
    }

    /// Technical decorations: data-store accent bar, icon, kicker, lead text, risk badge,
    /// and the rule-check flag.
    private func drawTech(_ n: SceneNode, ink: CGColor, ctx: CGContext) {
        let t = n.tech
        let tint = (t.tint ?? n.appearance.text).cgColor
        if let a = t.accent {
            Shapes.fill(CGRect(x: 0, y: 0, width: 6, height: bounds.height), a.cgColor, in: ctx)
            let edge = Shapes.segments([
                (CGPoint(x: 0, y: 1), CGPoint(x: bounds.width, y: 1)),
                (CGPoint(x: 0, y: bounds.height - 1), CGPoint(x: bounds.width, y: bounds.height - 1)),
            ])
            Shapes.stroke(edge, a.cgColor, width: 2, in: ctx)
        }
        if let icon = t.icon, let path = TechIcons.path(icon, in: t.iconRect) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(tint)
            ctx.setLineWidth(1.6 * t.iconRect.width / 24)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
        let small = TextAttributes(font: SceneBuilder.kickerFont, color: .fixed(tint), kern: 0.6)
        if let k = t.kicker {
            StyledText(k, small).draw(at: t.kickerRect.origin, in: ctx)
        }
        if let l = t.leadText {
            StyledText(l, small).draw(at: t.leadTextRect.origin, in: ctx)
        }
        if let b = t.badge {
            let r = t.badgeRect
            let c = (t.badgeColor ?? n.branchColor).cgColor
            let pill = Shapes.roundedRect(r, radius: 4)
            if b.count == 1 {
                Shapes.fill(pill, c, in: ctx)
            } else {
                Shapes.stroke(pill, c, width: 1, in: ctx)
            }
            StyledText(
                b,
                TextAttributes(
                    font: SceneBuilder.badgeFont, color: b.count == 1 ? .system(.white) : .fixed(c),
                    paragraph: .centered)
            ).draw(in: r.offsetBy(dx: 0, dy: 2), context: ctx)
        }
        if t.flagged {
            let r = CGRect(x: bounds.width - 17, y: 3, width: 14, height: 14)
            Shapes.fill(Shapes.oval(in: r), theme.critical.cgColor, in: ctx)
            StyledText(
                "!", TextAttributes(font: Fonts.system(10, .heavy), color: .system(.white), paragraph: .centered)
            ).draw(in: r.offsetBy(dx: 0, dy: 1), context: ctx)
        }
    }
}
