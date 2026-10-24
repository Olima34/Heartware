import Foundation

/// `--selftest` for the iPhone page, and `--dump --only phone` (with a real iPhone plugged in: add `--photos` to list
/// its library, `--analyse` to run the deep analysis; nothing is ever deleted).
@MainActor
enum PhoneChecks {
    static func run() -> [String] {
        var f: [String] = []

        // What the device says, in both shapes.
        let s = PhoneRules.storage(["TotalDiskCapacity": NSNumber(value: 256_000_000_000), "TotalDataCapacity": NSNumber(value: 246_300_000_000),
                                    "TotalDataAvailable": NSNumber(value: 185_500_000_000)])
        if s != PhoneStorage(total: 256_000_000_000, free: 185_500_000_000) { f.append("Stockage mal lu : \(String(describing: s))") }
        if PhoneRules.storage([:]) != nil { f.append("Stockage inventé sans données") }
        let recent = PhoneRules.battery(lockdown: ["BatteryCurrentCapacity": NSNumber(value: 62), "BatteryIsCharging": NSNumber(value: true)],
                                        registry: ["CycleCount": NSNumber(value: 296),
                                                   "BatteryData": ["DesignCapacity": NSNumber(value: 3652), "NominalChargeCapacity": NSNumber(value: 3467)]])
        if recent?.cycles != 296 || recent?.level != 62 || recent?.charging != true || abs((recent?.health ?? 0) - 0.949) > 0.001 {
            f.append("Batterie récente mal lue : \(String(describing: recent))")
        }
        let older = PhoneRules.battery(lockdown: [:], registry: ["CycleCount": NSNumber(value: 800), "DesignCapacity": NSNumber(value: 1821),
                                                                 "AppleRawMaxCapacity": NSNumber(value: 1400), "Temperature": NSNumber(value: 3050)])
        if older?.full != 1400 || older?.temperature != 30.5 || PhoneRules.batteryStatus(older ?? PhoneBattery()) != .warn {
            f.append("Batterie ancienne mal lue : \(String(describing: older))")
        }
        if PhoneRules.battery(lockdown: [:], registry: [:]) != nil { f.append("Batterie inventée sans données") }
        if PhoneRules.modelName("iPhone18,3") != "iPhone 17" || PhoneRules.modelName("iPhone99,1") != nil { f.append("Noms de modèles faux") }
        if PhoneInfo(udid: "", name: "", productType: "iPad13,18", deviceClass: "iPad", iosVersion: "", build: "").symbol != "ipad" {
            f.append("Un iPad montré comme un iPhone")
        }

        // Sorting.
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ id: String, _ kind: PhoneItem.Kind = .photo, ext: String = "HEIC", size: Int64 = 3_000_000, w: Int = 4032, h: Int = 3024,
                  at: TimeInterval = 0, _ edit: (inout PhoneItem) -> Void = { _ in }) -> PhoneItem {
            var i = PhoneItem(id: id, name: "IMG_\(id).\(ext)", kind: kind, size: size, date: t0.addingTimeInterval(at), width: w, height: h)
            i.located = true
            edit(&i)
            return i
        }
        if !PhoneRules.isScreenshot(item("s", ext: "PNG", w: 1179, h: 2556)) || PhoneRules.isScreenshot(item("s", ext: "PNG", w: 512, h: 512))
            || PhoneRules.isScreenshot(item("s", w: 1179, h: 2556)) {
            f.append("Captures d'écran mal reconnues")
        }
        let recording = item("r", .video, ext: "MP4", w: 888, h: 1920) { $0.located = false }
        let tiktok = item("t", .video, ext: "MP4", w: 1080, h: 1920) { $0.located = false }
        let received = item("w", .video, ext: "MP4", w: 576, h: 1024) { $0.located = false }
        let tablet = item("n", .video, ext: "MOV", w: 1014, h: 1474) { $0.located = false }
        if !PhoneRules.isScreenRecording(recording) || PhoneRules.isScreenRecording(tiktok) || PhoneRules.isScreenRecording(item("c", .video, ext: "MOV", w: 888, h: 1920))
            || PhoneRules.isScreenRecording(received) || PhoneRules.isScreenRecording(tablet)
            || !PhoneRules.isScreenRecording(tablet, screens: ["1014x1474"]) {
            f.append("Enregistrements d'écran mal reconnus")
        }
        let burst = [item("b1", size: 1) { $0.burst = "x" }, item("b2", size: 2) { $0.burst = "x"; $0.burstKept = true }, item("b3", size: 3) { $0.burst = "x" }]
        if Set(PhoneRules.burstExtras(burst).map(\.id)) != ["b1", "b3"] { f.append("Rafale choisie : les autres vues attendues") }
        let unpicked = burst.map { var b = $0; b.burstKept = false; return b }
        if Set(PhoneRules.burstExtras(unpicked).map(\.id)) != ["b1", "b2"] { f.append("Rafale sans choix : la plus grande vue doit rester") }
        let videos = [item("v1", .video, ext: "MOV", size: 80_000_000, w: 1920, h: 1080), item("v2", .video, ext: "MOV", size: 900_000_000, w: 3840, h: 2160),
                      item("v3", .video, ext: "MOV", size: 10_000_000, w: 1920, h: 1080), recording]
        let quick = PhoneRules.categories(videos, analysed: false)
        if quick.first(where: { $0.kind == .videos })?.ids != ["v2", "v1"] { f.append("Grosses vidéos mal triées") }
        if quick.contains(where: { $0.kind.needsAnalysis }) { f.append("Catégories de l'analyse fine montrées avant elle") }

        // Series and duplicates.
        let dated = [("a", 0.0), ("b", 5.0), ("c", 30.0), ("d", 40.0), ("e", 400.0)].map { (id: $0.0, date: t0.addingTimeInterval($0.1)) }
        let distances: [Float] = [0.3, 0.9, 0.2, 0.1]
        let series = PhoneRules.assignSeries(dated) { a, b in b == a + 1 ? distances[a] : nil }
        if series["a"] == nil || series["a"] != series["b"] || series["c"] == nil || series["c"] != series["d"] || series["a"] == series["c"] || series["e"] != nil {
            f.append("Séries mal formées : \(series)")
        }
        let shots = [item("p1", at: 0) { $0.series = 1; $0.score = 0.1 }, item("p2", at: 2) { $0.series = 1; $0.score = 0.7 },
                     item("p3", at: 4) { $0.series = 1; $0.score = 0.2 }, item("p4", at: 9) { $0.series = 2 }]
        if PhoneRules.seriesGroups(shots) != [["p2", "p1", "p3"]] { f.append("Série : la plus réussie doit venir en tête, seule une série d'une vue est écartée") }
        let dups = PhoneRules.duplicates([("x", t0.addingTimeInterval(60), "F"), ("y", t0, "F"), ("z", t0, "G")])
        if dups != ["x": "y"] { f.append("Doublons : le plus ancien doit rester, obtenu \(dups)") }
        var analysedItems = shots + [item("u", at: 100) { $0.utility = true }, item("k", at: 200) { $0.score = -0.6 },
                                     item("w", ext: "PNG", w: 1179, h: 2556, at: 300) { $0.utility = true; $0.located = false }]
        analysedItems.append(item("d2", at: 500) { $0.duplicateOf = "p4" })
        let full = Dictionary(PhoneRules.categories(analysedItems, analysed: true).map { ($0.kind, Set($0.ids)) }, uniquingKeysWith: { a, _ in a })
        if full[.similar] != ["p1", "p3"] || full[.utility] != ["u"] || full[.failed] != ["k"] || full[.duplicates] != ["d2"] || full[.screenshots] != ["w"] {
            f.append("Catégories de l'analyse fine fausses : \(full)")
        }

        // Freeing.
        let october = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12)) ?? t0
        if PhoneRules.archiveFolder(base: "/x", device: "iPhone de A/B", taken: october) != "/x/iPhone de A-B/2026-10" { f.append("Dossier de copie mal nommé") }
        func asset(_ id: String, _ name: String, at: TimeInterval, w: Int = 4032, h: Int = 3024, video: Bool = false) -> PhoneLibraryAsset {
            PhoneLibraryAsset(id: id, filename: name, date: t0.addingTimeInterval(at), width: w, height: h, video: video)
        }
        let shot = item("1234")
        let library = [asset("a", "IMG_1234.heic", at: 1), asset("b", "IMG_1235.HEIC", at: 0), asset("c", "IMG_1234.HEIC", at: 30)]
        if PhoneRules.match(shot, in: library) != "a" { f.append("Photothèque du Mac : même nom à 2 s près attendu") }
        if PhoneRules.match(shot, in: [asset("z", "IMG_1234.HEIC", at: 7200), asset("y", "IMG_1234.HEIC", at: 7210)]) != "z"
            || PhoneRules.match(shot, in: [asset("y", "IMG_1234.HEIC", at: 7210)]) != nil {
            f.append("Photothèque du Mac : un autre fuseau horaire doit se retrouver, pas un écart quelconque")
        }
        let saved = item("s", .video, ext: "MP4", w: 1280, h: 720)
        if PhoneRules.match(saved, in: [asset("v", "FullSizeRender.mov", at: 1, w: 720, h: 1280, video: true)]) != "v"
            || PhoneRules.match(saved, in: [asset("v", "A.mov", at: 1, w: 720, h: 1280, video: true), asset("w", "B.mov", at: 0, w: 1280, h: 720, video: true)]) != nil
            || PhoneRules.match(saved, in: [asset("p", "C.jpg", at: 0, w: 1280, h: 720)]) != nil {
            f.append("Photothèque du Mac : une vidéo renommée doit se retrouver seule et du même genre")
        }
        if PhoneRules.match(item("x") { $0.name = "IMG_E1156.JPG" }, in: [asset("e", "IMG_1156.HEIC", at: 0, w: 1206, h: 1680)]) != "e" {
            f.append("Photothèque du Mac : une retouche IMG_E doit retrouver sa photo")
        }
        let many = (0..<100).map { n in item("m\(n)", at: Double(n) * 86400) }
        let picked = PhoneRules.sample(many, count: 12)
        if picked.count != 12 || picked.first?.id != "m0" || picked.last?.id != "m99" || Set(picked.map(\.id)).count != 12
            || PhoneRules.sample(Array(many.prefix(5)), count: 12).count != 5 {
            f.append("Échantillon de la photothèque mal réparti")
        }
        if PhoneRules.sync(total: 40, sampled: 12, found: 0) != .missing(40) || PhoneRules.sync(total: 18_000, sampled: 12, found: 11) != .synced(18_000)
            || PhoneRules.sync(total: 0, sampled: 0, found: 0) != .missing(0)
            || PhoneRules.sync(total: 137, sampled: 12, found: 0, before: 40) != .syncing(137)
            || PhoneRules.sync(total: 900, sampled: 12, found: 3) != .syncing(900)
            || PhoneRules.sync(total: 137, sampled: 12, found: 0, before: 137) != .missing(137) {
            f.append("Photothèque du Mac : synchronisation mal jugée")
        }
        if PhoneRules.batches(Array(0..<25), size: 10).map(\.count) != [10, 10, 5] || !PhoneRules.batches([Int](), size: 10).isEmpty {
            f.append("Lots de suppression mal coupés")
        }

        // The notebook.
        var points = PhoneRules.record(PhoneHealthPoint(day: "2026-10-01", free: 10, total: 100, health: 0.9, cycles: 1, media: 500), in: [])
        points = PhoneRules.record(PhoneHealthPoint(day: "2026-10-01", free: 8, total: 100, health: 0.9, cycles: 2, media: nil), in: points)
        if points.count != 1 || points[0].free != 8 || points[0].media != 500 { f.append("Carnet : le bilan du jour doit remplacer le précédent et garder la photothèque") }
        let wear = [("2026-07-01", 0.92), ("2026-08-01", 0.91), ("2026-09-01", 0.90)].map { (day: $0.0, value: $0.1) }
        if let m = PhoneRules.monthly(wear), abs(m + 0.0098) > 0.001 { f.append("Carnet : pente mensuelle fausse (\(m))") }
        if PhoneRules.monthly(wear) == nil || PhoneRules.monthly(Array(wear.prefix(2))) != nil
            || PhoneRules.monthly([("2026-09-01", 1), ("2026-09-05", 2), ("2026-09-10", 3)].map { (day: $0.0, value: $0.1) }) != nil {
            f.append("Carnet : une tendance demande trois bilans sur trois semaines")
        }
        let filling = [("2026-07-01", 30), ("2026-08-01", 20), ("2026-09-01", 10)].map {
            PhoneHealthPoint(day: $0.0, free: Int64($0.1) * 1_000_000_000, total: 128_000_000_000)
        }
        if PhoneRules.storageTrend(filling)?.contains("plein dans un mois") != true { f.append("Carnet : remplissage mal annoncé (\(PhoneRules.storageTrend(filling) ?? "rien"))") }

        // The plugged/unplugged message of MobileDevice: the device, then the kind of event.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: UnsafeMutableRawPointer(bitPattern: 0x1234), as: UnsafeMutableRawPointer?.self)
        raw.storeBytes(of: UInt32(2), toByteOffset: 8, as: UInt32.self)
        if let e = PhoneBridge.event(raw), e.event != .detached || UInt(bitPattern: e.device) != 0x1234 { f.append("Message de MobileDevice mal lu") }
        return f
    }

    // MARK: Dump

    static func dump(_ m: PhoneModel) -> [String] {
        guard !DemoData.isEnabled else { return describe(m) }
        guard PhoneBridge.isAvailable else { return ["MobileDevice introuvable sur ce macOS : seul le tri des photos reste possible"] }
        m.listen()
        spin(5) { m.link == .ready || m.link == .untrusted }
        var lines = describe(m)
        if Entry.arguments.contains("--photos") || Entry.arguments.contains("--analyse"), m.link == .ready {
            let deep = Entry.arguments.contains("--analyse")
            let start = Date()
            if deep { m.analysePhotos() } else { m.openPhotos() }
            spin(30) { m.photoState == .ready || m.photoState == .locked || m.photoState != .listing && m.photoState != .idle }
            if m.photoState == .locked {
                lines.append("Photos : iPhone verrouillé, je l'attends 60 s")
                spin(60) { m.photoState == .ready }
            }
            if deep { spin(900) { m.analysed || m.photoState != .ready } }
            lines += describePhotos(m)
            lines.append("Durée : \(Fmt.duration(Date().timeIntervalSince(start)))")
        }
        // `--rouvrir`: closes the photos and opens them again, as after an unplugged iPhone or a second visit.
        if Entry.arguments.contains("--rouvrir"), m.photoState == .ready {
            m.library.close()
            let again = Date()
            m.openPhotos()
            spin(30) { m.photoState == .ready || m.photoState != .listing && m.photoState != .locked }
            lines.append("Réouverture : \(m.photoState) en \(Fmt.dec(Date().timeIntervalSince(again))) s, \(Fmt.int(m.items.count)) éléments")
        }
        // `--copie <dossier>`: copies a Live Photo and a small video, checked against the iPhone. Nothing is deleted.
        if let folder = Entry.value(after: "--copie"), m.photoState == .ready {
            let live = m.items.filter { $0.live }.min { $0.size < $1.size }
            let video = m.items.filter { $0.kind == .video }.min { $0.size < $1.size }
            for item in [live, video].compactMap({ $0 }) {
                var outcome: String?
                Task {
                    do {
                        let urls = try await m.library.copy(item.id, into: URL(fileURLWithPath: FS.expand(folder)))
                        outcome = "copié et vérifié : " + urls.map { "\($0.lastPathComponent) (\(Fmt.bytes((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0)))" }.joined(separator: ", ")
                    } catch {
                        outcome = "échec : \(error.localizedDescription)"
                    }
                }
                spin(120) { outcome != nil }
                lines.append("Copie de \(item.name) (\(Fmt.bytes(item.size))) : \(outcome ?? "trop long")")
            }
        }
        m.stop()
        return lines
    }

    private static func spin(_ seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    private static func describe(_ m: PhoneModel) -> [String] {
        guard let i = m.info, m.link == .ready else {
            return [m.link == .untrusted ? "iPhone branché, mais il ne fait pas confiance à ce Mac (déverrouille-le, touche « Se fier »)" : "Aucun iPhone branché par câble"]
        }
        var lines = ["\(i.name) · \(i.model) (\(i.productType)) · iOS \(i.iosVersion) (\(i.build))"]
        if let s = i.storage { lines.append("Stockage : \(Fmt.bytes(s.free)) libres sur \(Fmt.bytes(s.total))") }
        if let b = i.battery {
            lines.append("Batterie : \(b.health.map(Fmt.pct) ?? "?") de capacité (\(b.full.map(Fmt.int) ?? "?") mAh sur \(b.design.map(Fmt.int) ?? "?")) · \(PhoneRules.batteryDetail(b))")
        }
        lines.append("Sauvegarde : \(PhoneRules.backupDetail(i))")
        if let n = m.notebook {
            lines.append("Carnet : \(Fmt.plural(n.points.count, "bilan", "bilans"))"
                         + [PhoneRules.storageTrend(n.points), PhoneRules.batteryTrend(n.points)].compactMap { $0.map { " · " + $0 } }.joined())
        }
        if !m.items.isEmpty { lines += describePhotos(m) }
        return lines
    }

    private static func describePhotos(_ m: PhoneModel) -> [String] {
        let photos = m.items.filter { $0.kind == .photo }.count
        var lines = ["Photos : \(m.photoState) · \(Fmt.int(photos)) photos, \(Fmt.int(m.items.count - photos)) vidéos, \(Fmt.bytes(m.mediaSize))"
                     + " · Photos iCloud \(m.iCloudPhotos ? "activé" : "désactivé") · suppression \(m.deletion) · photothèque du Mac \(m.librarySync)"
                     + " · analyse fine \(m.analysed ? "faite" : "non faite")"]
        for c in m.categories {
            lines.append("  \(c.kind.title) : \(Fmt.int(c.ids.count)) · \(Fmt.bytes(c.size))\(c.groups.isEmpty ? "" : " · \(Fmt.plural(c.groups.count, "série", "séries"))")")
        }
        if let d = m.category(.duplicates) {
            lines.append("  Doublons : " + m.items.filter { d.ids.contains($0.id) }.map { "\($0.name) (\(Fmt.day($0.date)))" }.joined(separator: ", "))
        }
        // The sizes behind the guesses made from dimensions alone.
        for kind in [PhoneCategoryKind.recordings, .screenshots] {
            guard let c = m.category(kind) else { continue }
            let sizes = Dictionary(grouping: m.items.filter { c.ids.contains($0.id) }, by: { "\($0.width)×\($0.height)" }).mapValues(\.count)
            lines.append("  \(kind.title), dimensions : " + sizes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
        }
        lines.append("À libérer : \(Fmt.bytes(m.freeable))")
        return lines
    }
}
