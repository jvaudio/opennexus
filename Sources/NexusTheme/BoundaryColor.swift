import NexusCore

extension Boundary {
    /// The colour a boundary draws in: its own, else its meaning's, else the canvas's
    /// default boundary colour (D245), else the ring. A trust boundary marks risk on a threat
    /// model (artboard 21, red) and a network edge elsewhere (artboard 20's internal network,
    /// violet); a zone such as PCI is red on both; regions, VPCs and subnets take the
    /// entity line. The canvas and the Xmind export both use this.
    public func drawnColor(theme t: Theme, canvasType: DiagramType, canvasDefault: String?) -> RGBA {
        if let own = color.flatMap(RGBA.init(hexString:)) { return own }
        switch meaning {
        case "trust": return canvasType == .threatModel ? t.critical : t.processLine
        case "zone": return t.critical
        default:
            if isNetwork { return t.entityLine }
            return canvasDefault.flatMap(RGBA.init(hexString:)) ?? t.ring
        }
    }
}
