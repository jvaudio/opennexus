import Foundation

/// Fractional index keys for ordered siblings: strings over `0-9A-Za-z`, compared as plain
/// strings. A new key is a midpoint between its neighbours followed by the 16-character
/// code of the op that made it, so no two keys are ever equal (two people inserting at
/// the same place get different keys, ordered by their stamps) and there is always room
/// for another key between any two.
public enum Position {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let base = 62
    static let values: [Int] = {
        var v = [Int](repeating: -1, count: 128)
        for (i, d) in digits.enumerated() { v[Int(d)] = i }
        return v
    }()

    static func value(_ c: UInt8) -> Int { c < 128 ? values[Int(c)] : -1 }

    public static func encode(_ n: UInt64, width: Int) -> String {
        var out = [UInt8](repeating: digits[0], count: width)
        var n = n
        for i in stride(from: width - 1, through: 0, by: -1) {
            out[i] = digits[Int(n % UInt64(base))]
            n /= UInt64(base)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ s: ArraySlice<UInt8>) -> UInt64? {
        var n: UInt64 = 0
        for c in s {
            let v = value(c)
            guard v >= 0 else { return nil }
            n = n * UInt64(base) + UInt64(v)
        }
        return n
    }

    /// A key strictly between `a` and `b` (nil: the start or the end), made unique by
    /// `stamp`. Requires `a < b`.
    public static func between(_ a: String?, _ b: String?, stamp: Stamp) -> String {
        String(decoding: midpoint(a.map { Array($0.utf8) } ?? [], b.map { Array($0.utf8) }), as: UTF8.self)
            + stamp.code
    }

    /// Digits `m` with `a < m` and `m + anything < b`: greater than `a`, less than `b`, and not
    /// a prefix of `b`. Keys never end with the first digit (a stamp's code ends with a
    /// replica id, whose last character isn't `0`), so there's always room.
    static func midpoint(_ a: [UInt8], _ b: [UInt8]?) -> [UInt8] {
        var out: [UInt8] = []
        var bounded = b != nil
        var i = 0
        while true {
            let da = i < a.count ? value(a[i]) : -1
            var db = base
            if bounded, let b {
                // `b` can't end here while `a < b` (it would be a prefix of `a`).
                db = i < b.count ? value(b[i]) : base
            }
            if db - da >= 2 {
                // At the ends, step by one so runs of appends (or prepends) stay short;
                // between two keys, halve the gap.
                let x =
                    !bounded
                    ? (da >= 0 ? da + 1 : base / 2)
                    : da == -1
                        ? db - 1
                        : da + (db - da) / 2
                out.append(digits[x])
                return out
            }
            if db - da == 1 {
                if da == -1 {
                    // `a` ended and `b` has the first digit here: follow `b` down.
                    out.append(digits[0])
                } else {
                    // Below `b` from here on; keep following `a` until there's room above it.
                    out.append(digits[da])
                    bounded = false
                }
            } else {
                out.append(digits[max(da, 0)])
            }
            i += 1
        }
    }

    /// Keys for `count` new items between `a` and `b`, in order.
    public static func run(_ count: Int, between a: String?, _ b: String?, stamp: Stamp) -> [String] {
        var out: [String] = []
        var left = a
        for _ in 0..<count {
            let k = between(left, b, stamp: stamp)
            out.append(k)
            left = k
        }
        return out
    }
}
