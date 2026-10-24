import SwiftUI
import AppKit

/// Where things are on the wheel, in points from its center, y going down (as in SwiftUI). Pure: `selfTest` checks it.
/// The hub sits in the middle, the formats on an inner ring, the tools on the outer one; with only one of the two,
/// its ring takes the whole width. Segment 0 is at the top, the others follow clockwise.
struct WheelGeometry: Equatable {
    /// The outer edge of the wheel.
    static let radius: CGFloat = 172
    /// Room around it for the shadow (the panel is a little larger than the wheel).
    static let margin: CGFloat = 28
    static var side: CGFloat { (radius + margin) * 2 }
    static let hub: CGFloat = 50
    /// Between two segments, and between the rings.
    static let gap: CGFloat = 5
    /// Where the formats' ring ends when the tools' ring is there too.
    static let split: CGFloat = 104
    /// Past this distance from the edge, the pointer has left the wheel.
    static let slack: CGFloat = 10

    let formats: Int
    let tools: Int

    enum Hit: Equatable {
        case hub, format(Int), tool(Int)
    }

    /// The formats' ring, from its inner to its outer radius.
    var formatBand: (CGFloat, CGFloat)? {
        formats > 0 ? (Self.hub + Self.gap, tools > 0 ? Self.split : Self.radius) : nil
    }

    var toolBand: (CGFloat, CGFloat)? {
        tools > 0 ? ((formats > 0 ? Self.split : Self.hub) + Self.gap, Self.radius) : nil
    }

    /// What is under a point (from the center), nil when it is out of the wheel.
    func hit(_ p: CGPoint) -> Hit? {
        let r = hypot(p.x, p.y)
        if r > Self.radius + Self.slack { return nil }
        if r <= Self.hub + Self.gap / 2 || (formats == 0 && tools == 0) { return .hub }
        let angle = atan2(Double(p.y), Double(p.x))
        if let f = formatBand, r <= (toolBand == nil ? Self.radius + Self.slack : f.1 + Self.gap / 2) {
            return .format(Self.index(angle: angle, count: formats))
        }
        return tools > 0 ? .tool(Self.index(angle: angle, count: tools)) : .hub
    }

    /// The segment at `angle` (radians, 0 pointing right, growing clockwise on screen).
    static func index(angle: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let span = 2 * Double.pi / Double(count)
        // Segment 0 is centered at the top.
        var a = angle + Double.pi / 2 + span / 2
        a = a.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return min(count - 1, Int(a / span))
    }

    /// The middle of segment `index` out of `count`.
    static func centerAngle(_ index: Int, of count: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(1, count))
    }

    static func point(_ angle: Double, _ r: CGFloat, around c: CGPoint = .zero) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(angle)), y: c.y + r * CGFloat(sin(angle)))
    }

    /// A segment with soft corners, `index` out of `count`, between two radii. One segment alone is the whole ring.
    static func sector(_ index: Int, of count: Int, inner r: CGFloat, outer R: CGFloat, center c: CGPoint,
                       corner: CGFloat = 9) -> Path {
        var path = Path()
        guard count > 1 else {
            path.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            return path
        }
        let span = 2 * Double.pi / Double(count)
        let mid = centerAngle(index, of: count)
        let half = Double(gap / 2)
        let a0o = mid - span / 2 + half / Double(R), a1o = mid + span / 2 - half / Double(R)
        let a0i = mid - span / 2 + half / Double(r), a1i = mid + span / 2 - half / Double(r)
        // Corners no larger than what the segment allows.
        let k = min(corner, (R - r) / 2.5, CGFloat(a1i - a0i) * r / 2.5)
        let co0 = point(a0o, R, around: c), co1 = point(a1o, R, around: c)
        let ci0 = point(a0i, r, around: c), ci1 = point(a1i, r, around: c)
        func toward(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
            let len = max(0.001, hypot(b.x - a.x, b.y - a.y))
            return CGPoint(x: a.x + (b.x - a.x) * d / len, y: a.y + (b.y - a.y) * d / len)
        }
        let ko = Double(k / R), ki = Double(k / r)
        path.move(to: toward(co0, ci0, k))
        path.addQuadCurve(to: point(a0o + ko, R, around: c), control: co0)
        path.addRelativeArc(center: c, radius: R, startAngle: .radians(a0o + ko), delta: .radians(a1o - a0o - 2 * ko))
        path.addQuadCurve(to: toward(co1, ci1, k), control: co1)
        path.addLine(to: toward(ci1, co1, k))
        path.addQuadCurve(to: point(a1i - ki, r, around: c), control: ci1)
        path.addRelativeArc(center: c, radius: r, startAngle: .radians(a1i - ki), delta: .radians(-(a1i - a0i - 2 * ki)))
        path.addQuadCurve(to: toward(ci0, co0, k), control: ci0)
        path.closeSubpath()
        return path
    }

    /// The panel's frame (screen points, y up) for a wheel centered on `point`, kept on the visible part of the screen:
    /// the wheel itself stays whole, only its shadow may go past the edge.
    static func panelFrame(center point: CGPoint, visible: CGRect) -> CGRect {
        var frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let room = visible.insetBy(dx: -margin, dy: -margin)
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - side)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - side)
        return frame
    }
}

extension WheelGeometry {
    /// How visible the wheel stays when the pointer is `beyond` points out of its edge: whole inside, then fading
    /// toward a quarter, and nil past `limit` (it goes).
    static func fade(beyond: CGFloat, limit: CGFloat) -> CGFloat? {
        if beyond <= slack { return 1 }
        if beyond > limit { return nil }
        return 1 - 0.75 * min(1, (beyond - slack) / max(1, limit - slack))
    }

    /// Screen points in a centimetre on this screen (its physical size from macOS; 96 dpi when unknown).
    @MainActor
    static func pointsPerCentimetre(_ screen: NSScreen?) -> CGFloat {
        guard let screen, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 37.8 }
        let mm = CGDisplayScreenSize(id)
        guard mm.width > 10 else { return 37.8 }
        return screen.frame.width / CGFloat(mm.width / 10)
    }
}

/// A quick sideways shake of the dragged file: at least `legs` strokes of `minLeg` points, back and forth, within `window`
/// seconds. A slow drag that overshoots a folder and comes back makes two strokes at most.
struct WheelShake {
    var minLeg: CGFloat = 18
    var legs = 3
    var window: TimeInterval = 0.6

    private var origin: CGFloat?
    private var direction: CGFloat = 0
    private var extreme: CGFloat = 0
    private var times: [TimeInterval] = []

    mutating func reset() {
        origin = nil
        direction = 0
        extreme = 0
        times.removeAll(keepingCapacity: true)
    }

    /// The pointer is at `x` at time `t`; true once the shake is complete.
    mutating func feed(x: CGFloat, at t: TimeInterval) -> Bool {
        guard let origin else {
            self.origin = x
            extreme = x
            return false
        }
        if direction == 0 {
            if abs(x - origin) >= minLeg {
                direction = x > origin ? 1 : -1
                extreme = x
                times.append(t)
            }
        } else if (x - extreme) * direction > 0 {
            extreme = x
        } else if abs(x - extreme) >= minLeg {
            direction = -direction
            extreme = x
            times.append(t)
        }
        times.removeAll { t - $0 > window }
        return times.count >= legs
    }
}

/// The other gestures, as pure rules.
enum WheelGestureRules {
    /// The button was held still at least `delay` seconds before the pointer started moving.
    static func held(downAt: TimeInterval, movedAt: TimeInterval, delay: Double) -> Bool {
        movedAt - downAt >= delay
    }

    /// The pointer moved far enough from where the button went down to count as moving (not a trembling hand).
    static let still: CGFloat = 4

    static func moved(from a: CGPoint, to b: CGPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > still
    }
}
