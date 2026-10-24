import SwiftUI

/// The dust bunny chase: during a long analysis, dust bunnies roll across the waiting card; a click and the chamois
/// catches one (+1 blueberry, three a day). The wait becomes a little game. Only while the analysis runs.
struct RefugeChase: View {
    @Environment(AppModel.self) private var app
    /// The lap on which each bunny was caught: it hides until it comes round again.
    @State private var caught: [Int: Int] = [:]
    @State private var pops: [(id: UUID, x: CGFloat, text: String, at: Date)] = []

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)
    private static let speeds: [Double] = [46, 31, 58]
    private static let offsets: [Double] = [0, 240, 480]

    var body: some View {
        let m = app.refuge
        HStack(spacing: 14) {
            RefugeAvatar(look: m.look(), mood: .happy, pixel: 2.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pendant que j'analyse, attrape les moutons !").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Text("Clique sur ceux qui passent : +1 myrtille chacun, 3 par jour.").font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            .frame(width: 270, alignment: .leading)
            GeometryReader { geo in
                TimelineView(.periodic(from: Self.epoch, by: 0.1)) { context in
                    let t = context.date.timeIntervalSince(Self.epoch)
                    let span = Double(geo.size.width) + 60
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Theme.mascot.wood.opacity(0.35)).frame(height: 3).offset(y: 44)
                        ForEach(0..<3, id: \.self) { i in
                            let travel = t * Self.speeds[i] + Self.offsets[i]
                            let lap = Int(travel / span)
                            let x = CGFloat(travel.truncatingRemainder(dividingBy: span)) - 30
                            if caught[i] != lap {
                                Button { catchBunny(i, lap: lap, x: x) } label: {
                                    RefugeBunny(frame: Int(t * 6) + i)
                                }
                                .buttonStyle(.plain)
                                .position(x: x, y: 32 - (Int(t * 4 + Double(i)) % 2 == 0 ? 0 : 2))
                            }
                        }
                        ForEach(pops, id: \.id) { pop in
                            let age = context.date.timeIntervalSince(pop.at)
                            if age < 0.9 {
                                Text(pop.text).font(.ui(12, .bold)).foregroundStyle(RefugePage.tint)
                                    .opacity(1 - age / 0.9)
                                    .position(x: pop.x, y: 14 - age * 16)
                            }
                        }
                    }
                }
            }
            .frame(height: 50)
            .clipped()
        }
        .padding(.top, 6)
    }

    private func catchBunny(_ i: Int, lap: Int, x: CGFloat) {
        caught[i] = lap
        let paid = app.refuge.caughtBunny()
        pops.append((UUID(), x, paid > 0 ? "+1" : "Attrapé !", Date()))
        if pops.count > 6 { pops.removeFirst(pops.count - 6) }
    }
}

/// A dust bunny, wiggling.
struct RefugeBunny: View {
    var frame: Int
    var pixel: CGFloat = 4

    var body: some View {
        Canvas { ctx, _ in
            let c = Theme.mascot
            let rows = frame % 2 == 0 ? ["..d.d..", ".ddddd.", "ddededd", "ddddddd", ".DDDDD."] : [".d...d.", ".ddddd.", "ddededd", "ddddddd", "D.DDD.D"]
            for (y, line) in rows.enumerated() {
                for (x, ch) in line.enumerated() {
                    let color: Color? = switch ch {
                    case "d": c.dust
                    case "D": c.dustShade
                    case "e": c.eye
                    default: nil
                    }
                    if let color { ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)), with: .color(color)) }
                }
            }
        }
        .frame(width: pixel * 7, height: pixel * 5)
        .contentShape(Rectangle())
    }
}
