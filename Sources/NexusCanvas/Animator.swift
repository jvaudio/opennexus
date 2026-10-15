import AppKit
import NexusTheme

/// A critically-damped-ish spring (tokens: `snap` 0.28 / 0.80, `settle` 0.36 / 0.68),
/// stepped per frame so new targets retarget in-flight motion instead of queueing.
struct SpringValue {
    var value: CGPoint
    var velocity: CGVector = .zero
    var target: CGPoint

    init(_ p: CGPoint) {
        value = p
        target = p
    }

    var isSettled: Bool {
        abs(value.x - target.x) < 0.05 && abs(value.y - target.y) < 0.05 && abs(velocity.dx) < 0.5
            && abs(velocity.dy) < 0.5
    }

    mutating func step(_ dt: CGFloat, spring: Motion.Spring) {
        let k = CGFloat(spring.stiffness)
        let c = CGFloat(spring.damping)
        // Fixed sub-steps keep the integration stable at any frame rate.
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            let ax = -k * (value.x - target.x) - c * velocity.dx
            let ay = -k * (value.y - target.y) - c * velocity.dy
            velocity.dx += ax * h
            velocity.dy += ay * h
            value.x += velocity.dx * h
            value.y += velocity.dy * h
            remaining -= h
        }
        if isSettled {
            value = target
            velocity = .zero
        }
    }

    mutating func snap() {
        value = target
        velocity = .zero
    }
}

/// A scalar spring (node grow-in scale).
struct SpringScalar {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    var isSettled: Bool { abs(value - target) < 0.002 && abs(velocity) < 0.01 }

    mutating func step(_ dt: CGFloat, spring: Motion.Spring) {
        let k = CGFloat(spring.stiffness)
        let c = CGFloat(spring.damping)
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
            remaining -= h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }
}

/// Cubic-bezier easing (tokens: `glide`, `exit`).
struct Bezier {
    let c: Motion.Curve

    func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        // Solve x(u) = t for u with Newton's method, then return y(u).
        var u = t
        for _ in 0..<8 {
            let x = bez(u, c.c1x, c.c2x) - t
            let d = dbez(u, c.c1x, c.c2x)
            if abs(x) < 1e-5 || d == 0 { break }
            u -= x / d
        }
        return bez(min(max(u, 0), 1), c.c1y, c.c2y)
    }

    private func bez(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }

    private func dbez(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * p1 + 6 * v * u * (p2 - p1) + 3 * u * u * (1 - p2)
    }
}

/// Camera: translation (view points) and zoom.
public struct Camera: Equatable, Sendable {
    public var offset: CGPoint
    public var zoom: CGFloat

    public init(offset: CGPoint = .zero, zoom: CGFloat = 1) {
        self.offset = offset
        self.zoom = zoom
    }

    public func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * zoom, y: offset.y + p.y * zoom)
    }

    public func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    public func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    func interpolated(to other: Camera, _ t: Double) -> Camera {
        let t = CGFloat(t)
        return Camera(
            offset: CGPoint(
                x: offset.x + (other.offset.x - offset.x) * t, y: offset.y + (other.offset.y - offset.y) * t),
            zoom: zoom + (other.zoom - zoom) * t)
    }
}

struct CameraTween {
    var from: Camera
    var to: Camera
    var start: CFTimeInterval
    var duration: CFTimeInterval
    /// Present's Zoom transition: out to `via` in the first half, then in to `to`.
    var via: Camera? = nil
    let ease = Bezier(c: Motion.glide)

    func value(at t: CFTimeInterval) -> (Camera, done: Bool) {
        let p = duration <= 0 ? 1 : (t - start) / duration
        if p >= 1 { return (to, true) }
        guard let via else { return (from.interpolated(to: to, ease(p)), false) }
        return p < 0.5
            ? (from.interpolated(to: via, ease(p * 2)), false) : (via.interpolated(to: to, ease((p - 0.5) * 2)), false)
    }

    /// The camera that shows what both `from` and `to` show, in a view of `bounds`, or nil
    /// when that's under 20% further out than either (neighbouring slides just glide).
    static func overview(from: Camera, to: Camera, in bounds: CGRect) -> Camera? {
        func seen(_ c: Camera) -> CGRect {
            let a = c.toWorld(CGPoint(x: bounds.minX, y: bounds.minY))
            let b = c.toWorld(CGPoint(x: bounds.maxX, y: bounds.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        let both = seen(from).union(seen(to))
        guard bounds.width > 0, bounds.height > 0, both.width > 0, both.height > 0 else { return nil }
        let fit = min(bounds.width / both.width, bounds.height / both.height)
        guard fit < min(from.zoom, to.zoom) * 0.8 else { return nil }
        let z = fit * 0.9  // a margin around both
        return Camera(offset: CGPoint(x: bounds.midX - both.midX * z, y: bounds.midY - both.midY * z), zoom: z)
    }
}
