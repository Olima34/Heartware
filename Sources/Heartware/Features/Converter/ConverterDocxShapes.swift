import AppKit

/// The outlines of Word shapes: the common preset geometries, connectors and free-form paths (`a:custGeom`),
/// in the shape's own box (origin top left, y pointing down).
enum ConverterDocxGeometry {
    /// A preset shape; `open` is true for lines and connectors, which are stroked but never filled.
    static func preset(_ name: String, size s: CGSize, adjust: [String: CGFloat]) -> (path: CGPath, open: Bool) {
        let w = s.width, h = s.height
        let p = CGMutablePath()
        func poly(_ pts: [(CGFloat, CGFloat)]) {
            guard let first = pts.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath()
        }
        func adj(_ key: String, _ fallback: CGFloat) -> CGFloat { (adjust[key] ?? fallback) / 100_000 }
        let m = min(w, h)
        switch name {
        case "line", "straightConnector1":
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: h))
            return (p, true)
        case "bentConnector2":
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h))
            return (p, true)
        case "bentConnector3", "bentConnector4", "bentConnector5":
            let x = w * adj("adj1", 50_000)
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: h))
            p.addLine(to: CGPoint(x: w, y: h))
            return (p, true)
        case "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
            p.move(to: .zero)
            p.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w * 0.5, y: 0), control2: CGPoint(x: w * 0.5, y: h))
            return (p, true)
        case "arc":
            p.addArc(center: CGPoint(x: w / 2, y: h / 2), radius: m / 2, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            return (p, true)
        case "ellipse", "flowChartConnector", "donut":
            p.addEllipse(in: CGRect(origin: .zero, size: s))
        case "roundRect", "flowChartAlternateProcess":
            let r = m * adj("adj", 16_667)
            p.addRoundedRect(in: CGRect(origin: .zero, size: s), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2))
        case "flowChartTerminator":
            p.addRoundedRect(in: CGRect(origin: .zero, size: s), cornerWidth: min(w, h) / 2, cornerHeight: min(w, h) / 2)
        case "triangle", "flowChartExtract":
            let x = w * adj("adj", 50_000)
            poly([(x, 0), (w, h), (0, h)])
        case "flowChartMerge": poly([(0, 0), (w, 0), (w / 2, h)])
        case "rtTriangle": poly([(0, 0), (w, h), (0, h)])
        case "diamond", "flowChartDecision": poly([(w / 2, 0), (w, h / 2), (w / 2, h), (0, h / 2)])
        case "parallelogram", "flowChartInputOutput":
            let d = m * adj("adj", 25_000)
            poly([(d, 0), (w, 0), (w - d, h), (0, h)])
        case "trapezoid", "flowChartManualOperation":
            let d = m * adj("adj", 25_000)
            poly([(d, 0), (w - d, 0), (w, h), (0, h)])
        case "pentagon", "homePlate":
            if name == "homePlate" {
                let d = m * adj("adj", 50_000)
                poly([(0, 0), (w - d, 0), (w, h / 2), (w - d, h), (0, h)])
            } else {
                poly([(w / 2, 0), (w, h * 0.38), (w * 0.81, h), (w * 0.19, h), (0, h * 0.38)])
            }
        case "chevron":
            let d = m * adj("adj", 50_000)
            poly([(0, 0), (w - d, 0), (w, h / 2), (w - d, h), (0, h), (d, h / 2)])
        case "hexagon":
            let d = m * adj("adj", 25_000)
            poly([(d, 0), (w - d, 0), (w, h / 2), (w - d, h), (d, h), (0, h / 2)])
        case "octagon":
            let d = m * adj("adj", 29_289)
            poly([(d, 0), (w - d, 0), (w, d), (w, h - d), (w - d, h), (d, h), (0, h - d), (0, d)])
        case "plus":
            let d = m * adj("adj", 25_000)
            poly([(d, 0), (w - d, 0), (w - d, d), (w, d), (w, h - d), (w - d, h - d), (w - d, h), (d, h), (d, h - d), (0, h - d), (0, d), (d, d)])
        case "rightArrow", "leftArrow", "upArrow", "downArrow", "leftRightArrow", "upDownArrow":
            let horizontal = ["rightArrow", "leftArrow", "leftRightArrow"].contains(name)
            let (L, T) = horizontal ? (w, h) : (h, w)
            let shaft = T * adj("adj1", 50_000)
            let head = min(L, T * adj("adj2", 50_000))
            let a = (T - shaft) / 2, b = (T + shaft) / 2
            var pts: [(CGFloat, CGFloat)]
            switch name {
            case "leftRightArrow", "upDownArrow":
                pts = [(0, T / 2), (head, 0), (head, a), (L - head, a), (L - head, 0), (L, T / 2), (L - head, T), (L - head, b), (head, b), (head, T)]
            default:
                pts = [(0, a), (L - head, a), (L - head, 0), (L, T / 2), (L - head, T), (L - head, b), (0, b)]
            }
            if name == "leftArrow" || name == "upArrow" { pts = pts.map { (L - $0.0, $0.1) } }
            if !horizontal { pts = pts.map { ($0.1, $0.0) } }
            poly(pts)
        case "star5":
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<10 {
                let angle = -CGFloat.pi / 2 + CGFloat(k) * .pi / 5
                let r: CGFloat = k % 2 == 0 ? 0.5 : 0.19
                pts.append((w / 2 + cos(angle) * w * r, h / 2 + sin(angle) * h * r * 1.05 + h * 0.03))
            }
            poly(pts)
        case "flowChartDocument", "wave":
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h * 0.83))
            p.addCurve(to: CGPoint(x: 0, y: h * 0.9), control1: CGPoint(x: w * 0.67, y: h * 0.7), control2: CGPoint(x: w * 0.33, y: h * 1.08))
            p.closeSubpath()
        case "can", "flowChartMagneticDisk":
            let e = h * 0.12
            p.move(to: CGPoint(x: 0, y: e))
            p.addLine(to: CGPoint(x: 0, y: h - e))
            p.addCurve(to: CGPoint(x: w, y: h - e), control1: CGPoint(x: 0, y: h + e / 3), control2: CGPoint(x: w, y: h + e / 3))
            p.addLine(to: CGPoint(x: w, y: e))
            p.addCurve(to: CGPoint(x: 0, y: e), control1: CGPoint(x: w, y: -e / 3), control2: CGPoint(x: 0, y: -e / 3))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: 2 * e))
        case "cloud", "cloudCallout":
            p.addEllipse(in: CGRect(origin: .zero, size: s))
        default:
            p.addRect(CGRect(origin: .zero, size: s))
        }
        return (p, false)
    }

    /// `a:custGeom`: its paths, scaled from their own coordinate space to the shape's box.
    static func custom(_ geometry: ConverterXMLNode, size s: CGSize) -> (path: CGPath, open: Bool)? {
        let p = CGMutablePath()
        var open = true
        for path in geometry.child("pathLst")?.all("path") ?? [] {
            let pw = CGFloat(Double(path["w"] ?? "") ?? 0), ph = CGFloat(Double(path["h"] ?? "") ?? 0)
            let sx = pw > 0 ? s.width / pw : 1 / 12_700, sy = ph > 0 ? s.height / ph : 1 / 12_700
            func point(_ n: ConverterXMLNode?) -> CGPoint {
                CGPoint(x: CGFloat(Double(n?["x"] ?? "0") ?? 0) * sx, y: CGFloat(Double(n?["y"] ?? "0") ?? 0) * sy)
            }
            if path["fill"] != "none" { open = false }
            for c in path.children {
                switch c.name {
                case "moveTo": p.move(to: point(c.child("pt")))
                case "lnTo": p.addLine(to: point(c.child("pt")))
                case "cubicBezTo":
                    let pts = c.all("pt").map(point)
                    if pts.count == 3 { p.addCurve(to: pts[2], control1: pts[0], control2: pts[1]) }
                case "quadBezTo":
                    let pts = c.all("pt").map(point)
                    if pts.count == 2 { p.addQuadCurve(to: pts[1], control: pts[0]) }
                case "arcTo":
                    let wr = CGFloat(Double(c["wR"] ?? "0") ?? 0) * sx, hr = CGFloat(Double(c["hR"] ?? "0") ?? 0) * sy
                    let start = CGFloat(Double(c["stAng"] ?? "0") ?? 0) / 60_000 * .pi / 180
                    let sweep = CGFloat(Double(c["swAng"] ?? "0") ?? 0) / 60_000 * .pi / 180
                    guard wr > 0, hr > 0, !p.isEmpty else { continue }
                    let current = p.currentPoint
                    let center = CGPoint(x: current.x - wr * cos(start), y: current.y - hr * sin(start))
                    let t = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: wr, y: hr)
                    p.addArc(center: .zero, radius: 1, startAngle: start, endAngle: start + sweep, clockwise: sweep < 0, transform: t)
                case "close": p.closeSubpath()
                default: break
                }
            }
        }
        return p.isEmpty ? nil : (p, open)
    }

    /// An arrowhead at `tip`, pointing away from `from`.
    static func arrow(_ type: String, tip: CGPoint, from: CGPoint, width: CGFloat) -> (path: CGPath, fill: Bool)? {
        guard type != "none" else { return nil }
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length = max(5, width * 4.5), spread = max(3, width * 2.6)
        let back = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let left = CGPoint(x: back.x + sin(angle) * spread, y: back.y - cos(angle) * spread)
        let right = CGPoint(x: back.x - sin(angle) * spread, y: back.y + cos(angle) * spread)
        let p = CGMutablePath()
        switch type {
        case "oval":
            p.addEllipse(in: CGRect(x: tip.x - spread * 0.7, y: tip.y - spread * 0.7, width: spread * 1.4, height: spread * 1.4))
            return (p, true)
        case "diamond":
            let mid = CGPoint(x: tip.x - cos(angle) * length / 2, y: tip.y - sin(angle) * length / 2)
            p.move(to: tip)
            p.addLine(to: CGPoint(x: mid.x + sin(angle) * spread, y: mid.y - cos(angle) * spread))
            p.addLine(to: back)
            p.addLine(to: CGPoint(x: mid.x - sin(angle) * spread, y: mid.y + cos(angle) * spread))
            p.closeSubpath()
            return (p, true)
        case "arrow":
            p.move(to: left)
            p.addLine(to: tip)
            p.addLine(to: right)
            return (p, false)
        case "stealth":
            let notch = CGPoint(x: tip.x - cos(angle) * length * 0.6, y: tip.y - sin(angle) * length * 0.6)
            p.move(to: tip)
            p.addLine(to: left)
            p.addLine(to: notch)
            p.addLine(to: right)
            p.closeSubpath()
            return (p, true)
        default:
            p.move(to: tip)
            p.addLine(to: left)
            p.addLine(to: right)
            p.closeSubpath()
            return (p, true)
        }
    }

    /// The first and last segments of an open path, to orient its arrowheads.
    static func ends(_ path: CGPath) -> (start: CGPoint, afterStart: CGPoint, beforeEnd: CGPoint, end: CGPoint)? {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint:
                points.append(e.points[0])
                points.append(e.points[1])
            case .addCurveToPoint:
                points.append(e.points[0])
                points.append(e.points[1])
                points.append(e.points[2])
            default: break
            }
        }
        guard points.count >= 2 else { return nil }
        return (points[0], points[1], points[points.count - 2], points[points.count - 1])
    }
}
