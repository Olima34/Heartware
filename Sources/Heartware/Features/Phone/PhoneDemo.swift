import Foundation

/// An invented iPhone for `--demo`: Camille's, a little full, with what a real library holds.
@MainActor
enum PhoneDemo {
    static let udid = "00008110-001A2D3C4E5F6789"

    static var info: PhoneInfo {
        PhoneInfo(udid: udid, name: "iPhone de Camille", productType: "iPhone15,4", deviceClass: "iPhone", iosVersion: "27.0", build: "24A350",
                  storage: PhoneStorage(total: 128_000_000_000, free: 6_800_000_000),
                  battery: PhoneBattery(level: 64, charging: true, cycles: 612, design: 3349, full: 2873),
                  cloudBackup: false, localBackup: Date().addingTimeInterval(-41 * 86400))
    }

    static func fill(_ m: PhoneModel) {
        let items = makeItems()
        m.setDemo(link: .ready, info: info, items: items, analysed: true, iCloudPhotos: false, canDelete: true)
        m.settings.archiveFolder = "/Users/camille/Pictures/iPhone"
        var device = PhoneHealthDevice(name: "iPhone de Camille", productType: "iPhone15,4", lastSeen: Date())
        let now = Date()
        for k in 0..<13 {
            let days = Double(12 - k) * 10
            let day = PhoneRules.day(now.addingTimeInterval(-days * 86400))
            device.points.append(PhoneHealthPoint(day: day, free: Int64(6_800_000_000 + days * 130_000_000 + Double(k % 3) * 300_000_000),
                                                  total: 128_000_000_000, health: 0.858 + days * 0.00028, cycles: 612 - Int(days * 0.9),
                                                  media: nil))
        }
        var old = PhoneHealthDevice(name: "iPad de Camille", productType: "iPad13,18", lastSeen: now.addingTimeInterval(-63 * 86400))
        old.points = [PhoneHealthPoint(day: PhoneRules.day(now.addingTimeInterval(-63 * 86400)), free: 41_200_000_000, total: 64_000_000_000,
                                       health: 0.93, cycles: 214)]
        m.health = PhoneHealthLog(devices: [udid: device, "00008103-000E4A2C1B9D3F21": old])
    }

    static func applyTab(_ tab: String, to m: PhoneModel) {
        switch tab {
        case "vide":
            m.link = .absent
            m.info = nil
        case "confiance":
            m.link = .untrusted
        case "photos":
            m.setDemo(link: .ready, info: info, items: [], analysed: false, iCloudPhotos: false, canDelete: false)
        case "attente":
            m.setDemo(link: .ready, info: info, items: makeItems().map { var i = $0; (i.series, i.duplicateOf, i.utility, i.score) = (nil, nil, false, nil); return i },
                      analysed: false, iCloudPhotos: false, canDelete: true)
            m.task = PhoneTask(kind: .analysis, done: 1_284, total: 2_973)
        case "revue":
            m.reviewing = .videos
            m.selection = Set(m.category(.videos)?.ids.prefix(5) ?? [])
        case "series":
            m.reviewing = .similar
            m.selection = Set(m.category(.similar)?.ids.prefix(4) ?? [])
        case "icloud":
            m.setDemo(link: .ready, info: info, items: makeItems(), analysed: true, iCloudPhotos: true, canDelete: false)
            m.photosAccess = .notAsked
            m.librarySync = .unknown
            m.selection = Set(m.category(.screenshots)?.ids.prefix(30) ?? [])
        case "autre-phototheque":
            m.setDemo(link: .ready, info: info, items: makeItems(), analysed: true, iCloudPhotos: true, canDelete: false)
            m.librarySync = .missing(40)
        case "synchro":
            m.setDemo(link: .ready, info: info, items: makeItems(), analysed: true, iCloudPhotos: true, canDelete: false)
            m.librarySync = .syncing(1_284)
            m.selection = Set(m.category(.screenshots)?.ids.prefix(30) ?? [])
        default:
            break
        }
    }

    /// About 3 000 photos and videos, the same at every run.
    static func makeItems() -> [PhoneItem] {
        var out: [PhoneItem] = []
        var n = 1000
        let start = Date().addingTimeInterval(-400 * 86400)
        func add(_ kind: PhoneItem.Kind, ext: String, size: Int64, w: Int, h: Int, day: Double, _ edit: (inout PhoneItem) -> Void = { _ in }) {
            n += 1
            var i = PhoneItem(id: "demo-\(n)", name: "IMG_\(n).\(ext)", kind: kind, size: size,
                              date: start.addingTimeInterval(day * 86400), width: w, height: h)
            i.located = true
            edit(&i)
            out.append(i)
        }
        // Big videos, 4K and 1080p.
        let videoSizes: [Int64] = [3_800, 2_950, 2_410, 1_870, 1_620, 1_380, 1_120, 980, 860, 740, 610, 540, 470, 390, 330, 260, 190, 140]
        for (k, mb) in videoSizes.enumerated() {
            add(.video, ext: "MOV", size: mb * 1_000_000, w: k % 3 == 0 ? 1920 : 3840, h: k % 3 == 0 ? 1080 : 2160, day: Double(k * 21)) {
                $0.duration = Double(mb) / (k % 3 == 0 ? 2 : 6.5)
            }
        }
        // Screen recordings.
        for (k, mb) in [612, 288, 174].enumerated() {
            add(.video, ext: "MP4", size: Int64(mb) * 1_000_000, w: 888, h: 1920, day: Double(40 + k * 90)) {
                $0.located = false
                $0.duration = Double(mb) / 1.6
            }
        }
        // Screenshots.
        for k in 0..<214 {
            add(.photo, ext: "PNG", size: Int64(1_400_000 + (k * 37_000) % 2_200_000), w: 1179, h: 2556, day: Double(k) * 1.8) { $0.located = false }
        }
        // Two bursts, one with the shot picked.
        for b in 0..<2 {
            for k in 0..<9 {
                add(.photo, ext: "HEIC", size: 2_600_000 + Int64(k) * 40_000, w: 4032, h: 3024, day: 120 + Double(b) * 70 + Double(k) / 86400) {
                    $0.burst = "burst-\(b)"
                    $0.burstKept = b == 0 && k == 4
                }
            }
        }
        // Near-identical series.
        for s in 0..<38 {
            for k in 0..<(3 + s % 3) {
                add(.photo, ext: "HEIC", size: 2_900_000 + Int64(k) * 120_000, w: 4032, h: 3024, day: 10 + Double(s) * 9 + Double(k) * 4 / 86400) {
                    $0.series = s + 1
                    $0.score = k == 1 ? 0.62 : 0.2 - Float(k) * 0.05
                }
            }
        }
        // Receipts and documents, failed shots.
        for k in 0..<46 {
            add(.photo, ext: "HEIC", size: 1_900_000, w: 3024, h: 4032, day: Double(k) * 8 + 3) { $0.utility = true; $0.score = -0.1 }
        }
        for k in 0..<29 {
            add(.photo, ext: "HEIC", size: 2_300_000, w: 4032, h: 3024, day: Double(k) * 13 + 5) { $0.score = -0.55 }
        }
        // Everything else, among which a few exact duplicates (images saved twice from a chat).
        let firstPlain = out.count
        for k in 0..<2_450 {
            add(.photo, ext: k % 5 == 0 ? "JPG" : "HEIC", size: Int64(1_700_000 + (k * 7_919) % 2_600_000), w: 4032, h: 3024, day: Double(k) * 0.16) {
                $0.score = 0.3
                $0.live = k % 3 == 0
            }
        }
        for k in 0..<17 {
            var copy = out[firstPlain + k * 40]
            n += 1
            copy = PhoneItem(id: "demo-\(n)", name: "IMG_\(n).JPG", kind: .photo, size: copy.size, date: copy.date.addingTimeInterval(3600),
                             width: copy.width, height: copy.height)
            copy.duplicateOf = out[firstPlain + k * 40].id
            copy.score = 0.3
            out.append(copy)
        }
        return out
    }
}
