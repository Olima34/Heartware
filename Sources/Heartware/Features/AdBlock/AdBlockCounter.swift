import SwiftUI

// The counter of ads stopped. macOS' resolver (mDNSResponder) writes each lookup in the system log: the site's name is
// masked (<private>), but a blocked answer reads "type: A, rdata: 0.0.0.0" in clear, with the app that asked.
// Counting those lines tells how many ad and tracker requests the blocker stopped, app by app, without ever seeing
// which sites are visited. The log is followed live while the app runs (`log stream`, filtered by macOS itself): a few
// lines per lookup, nothing while none happens, and nothing to read back after a sleep or at launch. Reading an hour
// of log afterwards took 18 s of processor and 100 MB on an 8 GB Mac, right when the Mac woke up.

/// What was counted, kept between launches.
struct AdBlockTally: Codable, Equatable {
    var total = 0
    /// "2026-10-20" → requests stopped that day (90 days kept).
    var days: [String: Int] = [:]
    /// App → requests stopped since the start.
    var apps: [String: Int] = [:]
    var since: Date?
    /// The log was read up to this moment.
    var readUntil: Date?

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(_ events: [AdBlockLog.Event], readUntil end: Date) {
        for e in events {
            total += 1
            days[Self.dayKey(e.date), default: 0] += 1
            apps[e.app, default: 0] += 1
            if since == nil || e.date < since! { since = e.date }
        }
        readUntil = end
        let oldest = Self.dayKey(end.addingTimeInterval(-90 * 86_400))
        days = days.filter { $0.key >= oldest }
    }

    /// One ad cut by the ad-free player (a YouTube video's ads, a Twitch ad break).
    mutating func addOne(app: String, at date: Date = Date()) {
        total += 1
        days[Self.dayKey(date), default: 0] += 1
        apps[app, default: 0] += 1
        if since == nil { since = date }
    }

    func count(lastDays n: Int, now: Date = Date()) -> Int {
        (0..<n).reduce(0) { $0 + (days[Self.dayKey(now.addingTimeInterval(-Double($1) * 86_400))] ?? 0) }
    }

    /// The last `n` days, oldest first (for the little curve).
    func series(_ n: Int, now: Date = Date()) -> [Double] {
        (0..<n).reversed().map { Double(days[Self.dayKey(now.addingTimeInterval(-Double($0) * 86_400))] ?? 0) }
    }
}

enum AdBlockLog {
    struct Event: Equatable {
        var date: Date
        var app: String
    }

    enum Failure: Error, Equatable {
        case unreadable(String)
    }

    /// mDNSResponder's lookups and the answers "blocked" (0.0.0.0), the only lines the counter needs.
    static let predicate = "process == \"mDNSResponder\" AND (eventMessage CONTAINS \"getaddrinfo start\" OR eventMessage CONTAINS \"rdata: 0.0.0.0\")"

    /// mDNSResponder's lines between `start` and `end`: the lookups answered 0.0.0.0, with the app that asked
    /// (`--adblock compteur`). `log` runs at background priority (`taskpolicy -b`).
    static func read(from start: Date, to end: Date) -> Result<[Event], Failure> {
        guard !DemoData.isEnabled else { return .success([]) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let args = ["show", "--start", f.string(from: start), "--end", f.string(from: end), "--style", "compact", "--predicate", predicate]
        let policy = "/usr/sbin/taskpolicy"
        let r = FileManager.default.isExecutableFile(atPath: policy)
            ? Shell.run(policy, ["-b", "/usr/bin/log"] + args, timeout: 180)
            : Shell.run("/usr/bin/log", args, timeout: 180)
        guard r.ok else {
            return .failure(.unreadable(r.err.isEmpty ? "macOS n'a pas laissé lire son journal." : r.err.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(parse(r.out))
    }

    /// One event per lookup (a request may get several answers: the cached one, then the fresh one).
    static func parse(_ text: String) -> [Event] {
        var parser = AdBlockLogParser()
        return text.split(separator: "\n").compactMap { parser.feed(String($0)) }
    }

    fileprivate static let lineDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// "[R130252->Q9103]" or "[R130252]" → "R130252".
    fileprivate static func request(in line: String) -> String? {
        guard let start = line.range(of: "] [R") else { return nil }
        let rest = line[line.index(start.upperBound, offsetBy: -1)...]
        let id = rest.prefix { $0 == "R" || $0.isNumber }
        return id.count > 1 ? String(id) : nil
    }

    /// The log keeps 15 characters of a process name: a readable app name, or "Services de macOS" for its daemons.
    static func appName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Autres apps" }
        let known: [(String, String)] = [
            ("com.apple.WebKi", "Safari et pages web"), ("Safari", "Safari et pages web"), ("Google Chrome", "Google Chrome"),
            ("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave"), ("firefox", "Firefox"), ("Arc", "Arc"),
            ("Opera", "Opera"), ("Vivaldi", "Vivaldi"), ("Mail", "Mail"), ("Spotify", "Spotify"), ("Discord", "Discord"),
            ("Slack", "Slack"), ("zoom.us", "Zoom"), ("Microsoft Teams", "Teams"), ("Code Helper", "Visual Studio Code")
        ]
        if let hit = known.first(where: { raw.hasPrefix($0.0) }) { return hit.1 }
        // Daemons: lowercase names, often ending in "d" (cloudd, nsurlsessiond, cloudtelemetryd).
        if raw.first?.isLowercase == true { return "Services de macOS" }
        return raw
    }
}

/// Reads mDNSResponder's lines one at a time: remembers which app started each lookup, and turns the first "blocked"
/// answer of a lookup into an event. What it remembers stays small (a few thousand lookups at most).
struct AdBlockLogParser {
    private var apps: [String: String] = [:]
    private var seen = Set<String>()
    static let memory = 4_000
    /// Lookups remembered right now (the self-test checks it stays small).
    var remembered: Int { apps.count + seen.count }

    mutating func feed(_ line: String) -> AdBlockLog.Event? {
        if line.contains("] getaddrinfo start"), let r = AdBlockLog.request(in: line),
           let pid = line.range(of: "client pid: "), let open = line[pid.upperBound...].firstIndex(of: "("),
           let close = line[open...].firstIndex(of: ")") {
            if apps.count >= Self.memory { apps.removeAll(keepingCapacity: true) }
            apps[r] = String(line[line.index(after: open)..<close])
        } else if line.contains("getaddrinfo result"), line.contains("type: A, rdata: 0.0.0.0"), let r = AdBlockLog.request(in: line),
                  line.count > 23, let date = AdBlockLog.lineDate.date(from: String(line.prefix(23))) {
            if seen.count >= Self.memory { seen.removeAll(keepingCapacity: true) }
            guard seen.insert(r).inserted else { return nil }
            return AdBlockLog.Event(date: date, app: AdBlockLog.appName(apps.removeValue(forKey: r)))
        }
        return nil
    }
}

/// The counter's live reading: `log stream` at background priority, its lines parsed on a queue of its own, the events
/// handed to the main thread at most once a minute. A stream that ends starts again after 30 s, then a minute, two…
/// (10 min at most); a run that lasted starts the count of failures again. If the app is killed without quitting,
/// `log stream` ends by itself at its next line: nobody reads its pipe any more (checked on this Mac).
final class AdBlockLogStream: @unchecked Sendable {
    static let flushEvery: TimeInterval = 60

    private let queue = DispatchQueue(label: "heartware.adblock.stream", qos: .utility)
    private let onEvents: @MainActor ([AdBlockLog.Event]) -> Void
    private let onError: @MainActor (String?) -> Void
    private var following: Shell.Following?
    private var parser = AdBlockLogParser()
    private var batch: [AdBlockLog.Event] = []
    private var flushPending = false
    private var running = false
    private var failures = 0
    private var startedAt = Date()
    /// The "paused" message is showing: the first line of a stream that works again takes it away.
    private var errorShown = false

    init(onEvents: @escaping @MainActor ([AdBlockLog.Event]) -> Void, onError: @escaping @MainActor (String?) -> Void) {
        self.onEvents = onEvents
        self.onError = onError
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            failures = 0
            launch()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            following?.stop()
            following = nil
            flush()
        }
    }

    /// The app quits: the stream stops now, and the events not handed over yet come back here (the main thread will not
    /// run another block).
    func stopNow() -> [AdBlockLog.Event] {
        queue.sync {
            running = false
            following?.stop()
            following = nil
            let events = batch
            batch = []
            return events
        }
    }

    /// The seconds before the next try after `failures` stops in a row.
    static func retryDelay(after failures: Int) -> TimeInterval {
        min(600, 30 * pow(2, Double(max(0, failures - 1))))
    }

    private func launch() {
        guard running, following == nil else { return }
        parser = AdBlockLogParser()
        startedAt = Date()
        let policy = "/usr/sbin/taskpolicy"
        let args = ["stream", "--style", "compact", "--predicate", AdBlockLog.predicate]
        let (path, all) = FileManager.default.isExecutableFile(atPath: policy) ? (policy, ["-b", "/usr/bin/log"] + args) : ("/usr/bin/log", args)
        following = Shell.follow(path, all, queue: queue, onLine: { [weak self] line in self?.line(line) },
                                 onExit: { [weak self] _ in self?.ended() })
        if following == nil { ended() }
    }

    private func line(_ text: String) {
        if errorShown {
            errorShown = false
            let report = onError
            DispatchQueue.main.async { MainActor.assumeIsolated { report(nil) } }
        }
        guard let event = parser.feed(text) else { return }
        batch.append(event)
        guard !flushPending else { return }
        flushPending = true
        queue.asyncAfter(deadline: .now() + Self.flushEvery) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushPending = false
        guard !batch.isEmpty else { return }
        let events = batch
        batch = []
        let handler = onEvents
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(events) } }
    }

    private func ended() {
        following = nil
        flush()
        guard running else { return }
        if Date().timeIntervalSince(startedAt) > 600 { failures = 0 }
        failures += 1
        let report = onError
        let why: String? = failures >= 3 ? "macOS ne laisse pas suivre son journal (essai toutes les \(Int(Self.retryDelay(after: failures) / 60)) min)." : nil
        errorShown = why != nil
        DispatchQueue.main.async { MainActor.assumeIsolated { report(why) } }
        queue.asyncAfter(deadline: .now() + Self.retryDelay(after: failures)) { [weak self] in self?.launch() }
    }
}

/// Playful orders of magnitude for a number of ads stopped.
struct AdBlockEquivalence: Identifiable, Equatable {
    var id: String
    var symbol: String
    var value: String
    /// After the value, on the page ("de pub télé").
    var label: String
    /// The whole comparison, on hover and in the command line.
    var text: String
}

enum AdBlockFun {
    /// If each ad stopped were a 30-second TV spot, a 5 g flyer 0.1 mm thick, or about 50 KB of data.
    static func equivalences(_ n: Int) -> [AdBlockEquivalence] {
        let grams = Double(n) * 5, meters = Double(n) * 0.0001, megabytes = Double(n) * 0.05
        return [
            AdBlockEquivalence(id: "tv", symbol: "tv", value: duration(seconds: n * 30), label: "de pub télé",
                               text: "de coupures pub à la télé, si chaque pub arrêtée était un spot de 30 secondes"),
            AdBlockEquivalence(id: "paper", symbol: "newspaper", value: mass(grams), label: "de prospectus",
                               text: "de prospectus de 5 g, " + compare(grams / 1000, lead: "le poids", to: weights)),
            AdBlockEquivalence(id: "pile", symbol: "ruler", value: length(meters), label: "de pile",
                               text: "de pile, un prospectus sur l'autre, " + compare(meters, lead: "la hauteur", to: heights)),
            AdBlockEquivalence(id: "data", symbol: "arrow.down.circle", value: Fmt.bytes(Int64(megabytes * 1_000_000)), label: "de données en moins",
                               text: "de données en moins (≈ 50 Ko par pub ou pisteur), " + compare(megabytes, lead: "l'équivalent", to: data))
        ]
    }

    static let weights: [(String, String, Double)] = [
        ("une pomme", "pommes", 0.15), ("un chat", "chats", 4), ("une valise en soute", "valises en soute", 23),
        ("un adulte", "adultes", 70), ("un piano", "pianos", 300), ("une voiture", "voitures", 1_200),
        ("un éléphant", "éléphants", 6_000), ("une baleine bleue", "baleines bleues", 150_000)
    ]
    static let heights: [(String, String, Double)] = [
        ("une tasse", "tasses", 0.1), ("une table", "tables", 0.75), ("une porte", "portes", 2), ("une girafe", "girafes", 5.5),
        ("un immeuble de 10 étages", "immeubles de 10 étages", 30), ("la tour Eiffel", "tours Eiffel", 330),
        ("le mont Blanc", "monts Blanc", 4_806), ("l'Everest", "Everest", 8_849)
    ]
    static let data: [(String, String, Double)] = [
        ("une photo", "photos", 3), ("une chanson", "chansons", 4), ("un épisode de série", "épisodes de série", 700),
        ("un film en HD", "films en HD", 4_000)
    ]

    /// "le poids de 3 chats", "la hauteur de la tour Eiffel", "presque l'équivalent d'une chanson":
    /// the biggest reference not above `value` (the smallest one when `value` is below them all).
    static func compare(_ value: Double, lead: String, to refs: [(one: String, many: String, size: Double)]) -> String {
        guard let ref = refs.last(where: { $0.size <= value }) ?? refs.first else { return "" }
        let times = value / ref.size
        if times < 1 { return "presque \(lead) \(of(ref.one))" }
        if times < 1.5 { return "\(lead) \(of(ref.one))" }
        return "\(lead) de \(times < 10 ? Fmt.dec(times) : Fmt.int(times)) \(ref.many)"
    }

    /// "un chat" → "d'un chat", "le mont Blanc" → "du mont Blanc", "l'Everest" → "de l'Everest".
    static func of(_ s: String) -> String {
        if s.hasPrefix("un ") || s.hasPrefix("une ") { return "d'" + s }
        if s.hasPrefix("le ") { return "du " + s.dropFirst(3) }
        return "de " + s
    }

    static func duration(seconds s: Int) -> String {
        if s < 3_600 { return "\(max(1, s / 60)) min" }
        if s < 86_400 { return "\(s / 3_600) h \(String(format: "%02d", s % 3_600 / 60))" }
        return "\(s / 86_400) j \(s % 86_400 / 3_600) h"
    }

    static func mass(_ grams: Double) -> String {
        if grams < 1_000 { return "\(Int(grams)) g" }
        if grams < 1_000_000 { return Fmt.dec(grams / 1_000) + " kg" }
        return Fmt.dec(grams / 1_000_000) + " t"
    }

    static func length(_ meters: Double) -> String {
        if meters < 1 { return "\(Int((meters * 100).rounded())) cm" }
        if meters < 1_000 { return Fmt.dec(meters) + " m" }
        return Fmt.dec(meters / 1_000) + " km"
    }

    /// Steps worth celebrating, with their names.
    static let milestones: [(Int, String)] = [
        (10, "Premières pubs à la poubelle"), (100, "Cent de moins"), (1_000, "Mille pubs balayées"),
        (5_000, "Cinq mille, la mascotte s'échauffe"), (10_000, "Dix mille !"), (50_000, "Cinquante mille, un mur de pubs tombé"),
        (100_000, "Cent mille, la mascotte n'en revient pas"), (1_000_000, "Le million")
    ]

    /// The last step reached (if any) and the next one, with the progress towards it.
    static func milestone(_ n: Int) -> (reached: (Int, String)?, next: (Int, String)?, progress: Double) {
        let reached = milestones.last { $0.0 <= n }
        let next = milestones.first { $0.0 > n }
        let from = Double(reached?.0 ?? 0), to = Double(next?.0 ?? n)
        return (reached, next, to > from ? (Double(n) - from) / (to - from) : 1)
    }
}

/// The counter on the blocker's tab: the number and its curve, what it amounts to, and the apps that tried.
struct AdBlockCounterPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        let t = m.tally
        let step = AdBlockFun.milestone(t.total)
        let apps = t.apps.sorted { $0.value > $1.value }.prefix(4)
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Fmt.int(t.total))
                                .font(.serif(48)).foregroundStyle(Theme.text).monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.6), value: t.total)
                            PixelMascot(pixel: 2)
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 4) {
                                Sparkline(values: t.series(14), tint: AdBlockStyle.tint).frame(width: 180, height: 46)
                                Text("14 derniers jours").font(.ui(10.5)).foregroundStyle(Theme.text3)
                            }
                        }
                        Text("pubs et pisteurs arrêtés" + (t.since.map { " depuis le \($0.formatted(.dateTime.day().month(.wide).locale(Fmt.fr)))" } ?? ""))
                            .font(.ui(13)).foregroundStyle(Theme.text2)
                            .help(AdBlockTips.counted)
                        HStack(alignment: .bottom, spacing: 14) {
                            figure(Fmt.int(t.count(lastDays: 1)), "aujourd'hui")
                            figure(Fmt.int(t.count(lastDays: 7)), "sur 7 jours")
                            if let next = step.next {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Prochain palier : \(Fmt.int(next.0)) · « \(next.1) »").font(.ui(11)).foregroundStyle(Theme.text3)
                                    UsageBar(fraction: step.progress, tint: AdBlockStyle.tint, height: 5).frame(width: 180)
                                }
                            }
                            if let reached = step.reached {
                                Tag(text: reached.1, symbol: "trophy", tint: Theme.good, filled: true)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Qui essayait de joindre des régies").font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                            ForEach(Array(apps), id: \.key) { name, n in
                                RankRow(name: name, value: Fmt.int(n), fraction: Double(n) / Double(max(1, apps.first?.value ?? 1)), tint: AdBlockStyle.tint)
                            }
                        }
                        .frame(width: 330)
                    }
                }
                if t.total > 0 {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(AdBlockFun.equivalences(t.total)) { e in
                            HStack(spacing: 6) {
                                if Theme.icons != .hidden {
                                    Image(systemName: e.symbol).font(.ui(11, .medium))
                                        .foregroundStyle(Theme.icons == .tinted ? AdBlockStyle.tint : Theme.text3)
                                }
                                Text(e.value).font(.ui(12, .semibold)).foregroundStyle(Theme.text).monospacedDigit()
                                Text(e.label).font(.ui(11.5)).foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(PillShape().fill(Theme.track))
                            .help(e.value + " " + e.text)
                        }
                    }
                }
                if let error = m.countError {
                    Text("Compteur en pause : \(error)")
                        .font(.ui(11)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.ui(15, .semibold)).foregroundStyle(Theme.text).monospacedDigit()
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }
}
