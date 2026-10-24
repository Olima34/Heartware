import Foundation

/// Pure rules of the iPhone page: what the device says, how photos are sorted, how the notebook reads. Checked by `PhoneChecks`.
enum PhoneRules {
    // MARK: Reading the device

    /// `com.apple.disk_usage`: the whole disk, and what is free for the user's data.
    static func storage(_ d: [String: Any]) -> PhoneStorage? {
        guard let total = int64(d["TotalDiskCapacity"]) ?? int64(d["TotalDataCapacity"]), total > 0,
              let free = int64(d["TotalDataAvailable"]) ?? int64(d["AmountDataAvailable"]) else { return nil }
        return PhoneStorage(total: total, free: min(free, total))
    }

    /// The lockdown battery domain (level, charging) and the gauge's registry entry (cycles, capacities). Recent iPhones
    /// keep the capacities inside `BatteryData`, older ones at the top with `AppleRawMaxCapacity`.
    static func battery(lockdown: [String: Any], registry: [String: Any]) -> PhoneBattery? {
        let inner = registry["BatteryData"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Int? { int(registry[key]) ?? int(inner[key]) }
        var b = PhoneBattery()
        b.level = int(lockdown["BatteryCurrentCapacity"])
        b.charging = (lockdown["BatteryIsCharging"] as? NSNumber)?.boolValue ?? false
        b.cycles = value("CycleCount")
        b.design = value("DesignCapacity")
        b.full = value("NominalChargeCapacity") ?? value("AppleRawMaxCapacity")
        // Hundredths of a degree.
        if let t = value("Temperature"), t > 0 { b.temperature = Double(t) / 100 }
        guard b.level != nil || b.cycles != nil || b.health != nil else { return nil }
        return b
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    private static func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

    /// The name on the box, from the model identifier (nil for one this table does not know yet).
    static func modelName(_ productType: String) -> String? {
        let names: [String: String] = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2e génération)", "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3e génération)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
        ]
        return names[productType]
    }

    // MARK: Sorting photos

    /// A screen-shaped PNG: what the side button and volume up make.
    static func isScreenshot(_ i: PhoneItem) -> Bool {
        guard i.kind == .photo, i.ext == "PNG", let r = ratio(i) else { return false }
        return r >= 1.3 && r <= 2.3
    }

    /// A video of the screen: no place, and the size of the screen (that of the screenshots: 1206 × 2622 on an
    /// iPhone 17), or the tall 886 × 1920 older iPhones record in. Videos received in a chat (576 × 1024…) are not.
    static func isScreenRecording(_ i: PhoneItem, screens: Set<String> = []) -> Bool {
        guard i.kind == .video, !i.located, !i.slowMo, !i.timeLapse, let r = ratio(i) else { return false }
        if screens.contains(sizeKey(i)) { return true }
        let short = min(i.width, i.height)
        let cameraSides: Set<Int> = [480, 540, 720, 1080, 1440, 1512, 2160, 2176]
        return !cameraSides.contains(short) && max(i.width, i.height) >= 1600 && r >= 1.9 && r <= 2.3
    }

    /// The same key for portrait and landscape.
    static func sizeKey(_ i: PhoneItem) -> String { "\(min(i.width, i.height))x\(max(i.width, i.height))" }

    private static func ratio(_ i: PhoneItem) -> Double? {
        guard i.width > 0, i.height > 0 else { return nil }
        return Double(max(i.width, i.height)) / Double(min(i.width, i.height))
    }

    static let bigVideo: Int64 = 50_000_000
    /// Vision's feature prints (revision 2): near-identical shots stay under this distance. Measured on a real iPhone:
    /// shots taken within a minute fall in two groups, around 0.2–0.5 and around 0.8–1.2.
    static let similarDistance: Float = 0.5
    /// Shots further apart than this are never one series.
    static let seriesWindow: TimeInterval = 180
    /// Vision's aesthetics score under which a photo is probably a failure.
    static let failedScore: Float = -0.3

    /// The categories, the biggest first. `analysed`: the deep pass ran (similar, duplicates, documents, failures).
    static func categories(_ items: [PhoneItem], analysed: Bool) -> [PhoneCategory] {
        var out: [PhoneCategory] = []
        func add(_ kind: PhoneCategoryKind, _ list: [PhoneItem], groups: [[String]] = []) {
            guard !list.isEmpty else { return }
            out.append(PhoneCategory(kind: kind, ids: list.map(\.id), size: list.reduce(0) { $0 + $1.size }, groups: groups))
        }
        let screenshots = items.filter(isScreenshot)
        let screens = Set(screenshots.map(sizeKey))
        let recordings = items.filter { isScreenRecording($0, screens: screens) }
        let recordingIDs = Set(recordings.map(\.id))
        add(.videos, items.filter { $0.kind == .video && $0.size >= bigVideo && !recordingIDs.contains($0.id) }.sorted { $0.size > $1.size })
        add(.screenshots, screenshots.sorted { $0.date < $1.date })
        add(.recordings, recordings.sorted { $0.size > $1.size })
        add(.bursts, burstExtras(items))
        guard analysed else { return out.sorted { $0.size > $1.size } }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = seriesGroups(items)
        add(.similar, groups.flatMap { $0.dropFirst() }.compactMap { byID[$0] }, groups: groups)
        let duplicates = items.filter { $0.duplicateOf != nil }
        add(.duplicates, duplicates)
        let screenshotIDs = Set(screenshots.map(\.id)), duplicateIDs = Set(duplicates.map(\.id))
        let utility = items.filter { $0.kind == .photo && $0.utility && !screenshotIDs.contains($0.id) && !duplicateIDs.contains($0.id) }
        add(.utility, utility.sorted { $0.date < $1.date })
        let utilityIDs = Set(utility.map(\.id))
        add(.failed, items.filter { i in
            i.kind == .photo && (i.score ?? 0) < failedScore && !screenshotIDs.contains(i.id) && !utilityIDs.contains(i.id) && !duplicateIDs.contains(i.id)
        }.sorted { $0.date < $1.date })
        return out.sorted { $0.size > $1.size }
    }

    /// The shots of a burst nobody picked: when some were picked, the others; otherwise all but the best.
    static func burstExtras(_ items: [PhoneItem]) -> [PhoneItem] {
        Dictionary(grouping: items.filter { $0.burst != nil }, by: { $0.burst ?? "" }).values.flatMap { shots -> [PhoneItem] in
            guard shots.count > 1 else { return [] }
            if shots.contains(where: \.burstKept) { return shots.filter { !$0.burstKept } }
            let keep = best(shots)
            return shots.filter { $0.id != keep?.id }
        }.sorted { $0.date < $1.date }
    }

    /// The shot to keep: Vision's highest score, else the biggest file (the most detail).
    static func best(_ shots: [PhoneItem]) -> PhoneItem? {
        shots.max { a, b in
            if let sa = a.score, let sb = b.score, sa != sb { return sa < sb }
            return a.size < b.size
        }
    }

    /// Near-identical series from `series`, each one's kept shot first. Bursts and screenshots stay out.
    static func seriesGroups(_ items: [PhoneItem]) -> [[String]] {
        let shots = items.filter { $0.series != nil && $0.burst == nil && !isScreenshot($0) }
        return Dictionary(grouping: shots, by: { $0.series ?? 0 }).values
            .filter { $0.count > 1 }
            .compactMap { group -> [String]? in
                guard let keep = best(group) else { return nil }
                return [keep.id] + group.filter { $0.id != keep.id }.sorted { $0.date < $1.date }.map(\.id)
            }
            .sorted { a, b in a.count != b.count ? a.count > b.count : a[0] < b[0] }
    }

    /// Numbers the series: in date order, a shot joins the previous one's series when taken within `seriesWindow`
    /// and closer than `similarDistance`. `distance(a, b)` compares two indices of `dated`.
    static func assignSeries(_ dated: [(id: String, date: Date)], distance: (Int, Int) -> Float?) -> [String: Int] {
        var out: [String: Int] = [:]
        var next = 0
        for i in dated.indices.dropFirst() {
            guard dated[i].date.timeIntervalSince(dated[i - 1].date) <= seriesWindow,
                  let d = distance(i - 1, i), d < similarDistance else { continue }
            let series = out[dated[i - 1].id] ?? { next += 1; return next }()
            out[dated[i - 1].id] = series
            out[dated[i].id] = series
        }
        return out
    }

    /// Identical files: same fingerprint. The oldest stays, the others point to it.
    static func duplicates(_ fingerprints: [(id: String, date: Date, print: String)]) -> [String: String] {
        var out: [String: String] = [:]
        for group in Dictionary(grouping: fingerprints, by: \.print).values where group.count > 1 {
            let sorted = group.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
            for d in sorted.dropFirst() { out[d.id] = sorted[0].id }
        }
        return out
    }

    // MARK: Freeing

    /// Where an original goes: the chosen folder, the device's name, the month it was taken.
    static func archiveFolder(base: String, device: String, taken: Date) -> String {
        let safe = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return (base as NSString).appendingPathComponent(safe.isEmpty ? "iPhone" : safe) + "/" + f.string(from: taken)
    }

    /// The asset of the Mac's Photos library that is this iPhone item:
    /// 1. the same name, taken within two seconds;
    /// 2. the same name and size in pixels, a whole number of quarter hours apart within 14 h (another time zone);
    /// 3. without the name (a video saved from an app gets another one in Photos): the same kind and size in pixels,
    ///    within two seconds, and the only one.
    static func match(_ item: PhoneItem, in assets: [PhoneLibraryAsset]) -> String? {
        let base = baseName(item.name)
        let kind = assets.filter { $0.video == (item.kind == .video) }
        func gap(_ a: PhoneLibraryAsset) -> Double { abs(a.date.timeIntervalSince(item.date)) }
        func closest(_ list: [PhoneLibraryAsset]) -> String? { list.min { gap($0) < gap($1) }?.id }
        let named = kind.filter { baseName($0.filename) == base }
        if let id = closest(named.filter { gap($0) <= 2 }) { return id }
        if let id = closest(named.filter { sameSize($0, item) && gap($0) <= 14 * 3600 && isZoneShift($0.date.timeIntervalSince(item.date)) }) { return id }
        let alike = kind.filter { sameSize($0, item) && gap($0) <= 2 }
        return alike.count == 1 ? alike[0].id : nil
    }

    /// The name of the asset in Photos: the edited render « IMG_E1234.JPG » the iPhone lists is the asset « IMG_1234 ».
    static func baseName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension.uppercased()
        let digits = base.dropFirst(5)
        return base.hasPrefix("IMG_E") && !digits.isEmpty && digits.allSatisfy(\.isNumber) ? "IMG_" + digits : base
    }

    static func sameSize(_ a: PhoneLibraryAsset, _ i: PhoneItem) -> Bool {
        (a.width == i.width && a.height == i.height) || (a.width == i.height && a.height == i.width)
    }

    /// A time zone apart: a whole number of quarter hours, give or take two seconds.
    static func isZoneShift(_ seconds: Double) -> Bool {
        abs(seconds - (seconds / 900).rounded() * 900) <= 2
    }

    /// Why an item was not found in the Mac's library, in one line for the actions log.
    static func miss(_ item: PhoneItem, around: Int, nearest: PhoneLibraryAsset?) -> String {
        let when = "\(Fmt.day(item.date)) \(Fmt.clock(item.date))"
        guard let nearest else {
            return "\(item.name) (\(when), \(item.width)×\(item.height)) : rien dans la photothèque à 14 h près"
        }
        let gap = Int(nearest.date.timeIntervalSince(item.date))
        return "\(item.name) (\(when), \(item.width)×\(item.height)) : \(around) à 14 h près, le plus proche « \(nearest.filename) » à \(gap) s, \(nearest.width)×\(nearest.height)"
    }

    /// A few items spread over the whole library, to see whether this Mac's Photos library holds them.
    static func sample(_ items: [PhoneItem], count: Int) -> [PhoneItem] {
        let sorted = items.sorted { $0.date < $1.date }
        guard sorted.count > count, count > 0 else { return sorted }
        return (0..<count).map { sorted[$0 * (sorted.count - 1) / max(1, count - 1)] }
    }

    /// Most of the sample found: the same library. Some of it, or more photos than at the last look: Photos is
    /// filling it from iCloud.
    static func sync(total: Int, sampled: Int, found: Int, before: Int? = nil) -> PhoneLibrarySync {
        if total > 0 && sampled > 0 && found * 2 >= sampled { return .synced(total) }
        if found > 0 || (before.map { total > $0 } ?? false) { return .syncing(total) }
        return .missing(total)
    }

    static func batches<T>(_ list: [T], size: Int) -> [[T]] {
        stride(from: 0, to: list.count, by: max(1, size)).map { Array(list[$0..<min(list.count, $0 + max(1, size))]) }
    }

    // MARK: The notebook

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func date(ofDay s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Adds today's check-up, or replaces the one already made today. Keeps the last 500 days seen.
    static func record(_ p: PhoneHealthPoint, in points: [PhoneHealthPoint]) -> [PhoneHealthPoint] {
        var out = points.filter { $0.day != p.day }
        var point = p
        // Listing the photos later the same day keeps the size found earlier, and the other way round.
        if point.media == nil { point.media = points.first { $0.day == p.day }?.media }
        out.append(point)
        out.sort { $0.day < $1.day }
        return Array(out.suffix(500))
    }

    /// How a value moves in a month (least squares), once the points cover three weeks or more.
    static func monthly(_ values: [(day: String, value: Double)]) -> Double? {
        let pts = values.compactMap { v in date(ofDay: v.day).map { ($0.timeIntervalSince1970 / 86400, v.value) } }
        guard pts.count >= 3, let first = pts.map(\.0).min(), let last = pts.map(\.0).max(), last - first >= 21 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n
        let sxx = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = pts.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx * 30
    }

    /// One sentence on the battery's wear, from the notebook.
    static func batteryTrend(_ points: [PhoneHealthPoint]) -> String? {
        guard let slope = monthly(points.compactMap { p in p.health.map { (p.day, $0) } }) else { return nil }
        let perMonth = -slope * 100
        if perMonth < 0.1 { return "Sa batterie tient bon : pas d'usure visible depuis le premier bilan." }
        return "Sa batterie perd environ \(Fmt.dec(perMonth)) % de capacité par mois."
    }

    /// One sentence on how fast the iPhone fills up.
    static func storageTrend(_ points: [PhoneHealthPoint]) -> String? {
        guard let slope = monthly(points.map { ($0.day, Double($0.free)) }) else { return nil }
        if abs(slope) < 200_000_000 { return "Sa place libre est stable." }
        if slope > 0 { return "Il gagne \(Fmt.bytes(Int64(slope))) de place libre par mois." }
        let free = Double(points.last?.free ?? 0)
        let months = free / -slope
        let left = months < 24 ? " : plein dans \(months < 1.5 ? "un mois environ" : "\(Int(months.rounded())) mois") à ce rythme" : ""
        return "Il se remplit de \(Fmt.bytes(Int64(-slope))) par mois\(left)."
    }

    // MARK: Words

    static func storageStatus(_ s: PhoneStorage) -> Status {
        s.freeFraction < 0.05 || s.free < 2_000_000_000 ? .bad : (s.freeFraction < 0.12 ? .warn : .ok)
    }

    static func batteryStatus(_ b: PhoneBattery) -> Status {
        guard let h = b.health else { return .unknown }
        return h < 0.8 ? .warn : .ok
    }

    static func batteryDetail(_ b: PhoneBattery) -> String {
        var parts: [String] = []
        if let c = b.cycles { parts.append(Fmt.plural(c, "cycle", "cycles")) }
        if let h = b.health { parts.append(h < 0.8 ? "à remplacer bientôt" : "en bonne santé") }
        if let l = b.level { parts.append("chargée à \(l) %\(b.charging ? ", en charge" : "")") }
        return parts.isEmpty ? "Capacité illisible" : Fmt.cap(parts.joined(separator: " · "))
    }

    static func backupDetail(_ info: PhoneInfo) -> String {
        var parts: [String] = []
        if info.localBackup != nil { parts.append("Sur ce Mac, par le Finder") }
        if let c = info.cloudBackup { parts.append(c ? "Sauvegarde iCloud activée" : "Sauvegarde iCloud désactivée") }
        if backupStatus(info) == .warn { parts.append("à refaire avant un grand ménage") }
        return parts.isEmpty ? "Ni iCloud ni ce Mac" : parts.joined(separator: " · ")
    }

    /// Without iCloud backups, a backup on this Mac older than a month is worth redoing before deleting anything.
    static func backupStatus(_ info: PhoneInfo, now: Date = Date()) -> Status {
        if info.cloudBackup == true { return .ok }
        guard let d = info.localBackup else { return .warn }
        return now.timeIntervalSince(d) > 30 * 86400 ? .warn : .ok
    }
}
