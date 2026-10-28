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
    /// Present's fly-to (M42): the camera follows this path, in a view of these bounds.
    var fly: (path: FlyPath, bounds: CGRect)? = nil
    let ease = Bezier(c: Motion.glide)

    func value(at t: CFTimeInterval) -> (Camera, done: Bool) {
        let p = duration <= 0 ? 1 : (t - start) / duration
        if p >= 1 { return (to, true) }
        if let fly { return (fly.path.camera(at: CGFloat(ease(p)), in: fly.bounds), false) }
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

/// van Wijk and Nuij's smooth zoom-and-pan ("Smooth and efficient zooming and panning",
/// 2003), Present's fly-to (M42). The camera pulls back as far as the distance needs, crosses
/// at a steady perceived speed, and lands on the new view: a long move rises over the map,
/// a short one barely leaves it. Positions are in world points; `width` is how much world
/// the view spans.
struct FlyPath {
    let c0: CGPoint
    let c1: CGPoint
    let w0: CGFloat
    let w1: CGFloat
    /// The trade-off between zooming and panning: √2 is the paper's recommended value.
    static let rho: CGFloat = 1.4142
    let u1: CGFloat
    let r0: CGFloat
    let S: CGFloat

    init(from c0: CGPoint, width w0: CGFloat, to c1: CGPoint, width w1: CGFloat) {
        self.c0 = c0
        self.c1 = c1
        self.w0 = max(w0, 1e-6)
        self.w1 = max(w1, 1e-6)
        let rho = Self.rho
        u1 = hypot(c1.x - c0.x, c1.y - c0.y)
        if u1 < 1e-6 {
            r0 = 0
            S = abs(log(self.w1 / self.w0)) / rho
        } else {
            let a = Self.r(w0: self.w0, w1: self.w1, u1: u1, end: false)
            r0 = a
            S = (Self.r(w0: self.w0, w1: self.w1, u1: u1, end: true) - a) / rho
        }
    }

    /// The paper's r(0) and r(1).
    static func r(w0: CGFloat, w1: CGFloat, u1: CGFloat, end: Bool) -> CGFloat {
        let (w, sign): (CGFloat, CGFloat) = end ? (w1, -1) : (w0, 1)
        let b = (w1 * w1 - w0 * w0 + sign * pow(rho, 4) * u1 * u1) / (2 * w * rho * rho * u1)
        return log(-b + sqrt(b * b + 1))
    }

    /// The view at `t` (0…1 of the path's length): its centre and width.
    func at(_ t: CGFloat) -> (center: CGPoint, width: CGFloat) {
        let rho = Self.rho
        let s = min(max(t, 0), 1) * S
        if u1 < 1e-6 {
            let k: CGFloat = w1 < w0 ? -1 : 1
            return (c0, w0 * exp(k * rho * s))
        }
        let u = w0 / (rho * rho) * (cosh(r0) * tanh(rho * s + r0) - sinh(r0))
        let f = u / u1
        return (CGPoint(x: c0.x + (c1.x - c0.x) * f, y: c0.y + (c1.y - c0.y) * f), w0 * cosh(r0) / cosh(rho * s + r0))
    }

    init(from a: Camera, to b: Camera, in bounds: CGRect) {
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        self.init(
            from: a.toWorld(mid), width: bounds.width / max(a.zoom, 1e-6), to: b.toWorld(mid),
            width: bounds.width / max(b.zoom, 1e-6))
    }

    /// The camera at `t` in a view of `bounds`.
    func camera(at t: CGFloat, in bounds: CGRect) -> Camera {
        let (c, w) = at(t)
        let z = bounds.width / w
        return Camera(offset: CGPoint(x: bounds.midX - c.x * z, y: bounds.midY - c.y * z), zoom: z)
    }
}
