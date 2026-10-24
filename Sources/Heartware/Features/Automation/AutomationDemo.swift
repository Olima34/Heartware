import Foundation

/// Invented automations for `--demo`: rules, a journal, a year of health history and fictional files.
/// Nothing comes from this Mac and nothing is written anywhere.
enum AutomationDemo {
    private static func mb(_ v: Double) -> Int64 { Int64(v * 1_000_000) }
    private static func gb(_ v: Double) -> Int64 { Int64(v * 1_000_000_000) }

    static func settings(now: Date) -> AutomationSettings {
        var s = AutomationSettings()
        s.cleanupEnabled = true
        s.cleanupFrequency = .weekly
        s.cleanupLastRun = now.addingTimeInterval(-3 * 86400 - 5 * 3600)
        // The Trash rule is shown in its dry run, before being turned on.
        s.trashEnabled = false
        s.trashDays = 30
        s.downloadsEnabled = true
        s.downloadsFrequency = .hourly
        s.downloadsLastRun = now.addingTimeInterval(-22 * 60)
        s.healthEnabled = true
        s.notify = true
        s.rules = AutomationRule.defaults + [
            AutomationRule(name: "Vidéos et musique", enabled: false, kinds: [.videos, .audio], minAgeDays: 7, action: .move,
                           destination: "~/Movies/Téléchargements")
        ]
        return s
    }

    static func journal(now: Date) -> [AutomationLogEntry] {
        func at(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        return [
            AutomationLogEntry(date: at(22.0 / 1440), kind: .downloads, automatic: true, title: "Téléchargements rangés",
                               detail: "3 fichiers rangés, 1 mis à la Corbeille (431,4 Mo).", bytes: mb(431.4)),
            AutomationLogEntry(date: at(1.15), kind: .downloads, automatic: true, title: "Téléchargements rangés",
                               detail: "2 fichiers rangés (18,4 Mo).", bytes: mb(18.4)),
            AutomationLogEntry(date: at(3.2), kind: .cleanup, automatic: true, title: "Nettoyage sans risque",
                               detail: "1 284 éléments traités, 6,2 Go libérés.", bytes: gb(6.2)),
            AutomationLogEntry(date: at(4.6), kind: .trash, automatic: false, title: "Corbeille allégée",
                               detail: "14 éléments supprimés (plus de 30 j), 2,1 Go libérés.", bytes: gb(2.1)),
            AutomationLogEntry(date: at(6.4), kind: .downloads, automatic: true, title: "Téléchargements rangés",
                               detail: "5 fichiers rangés, 2 mis à la Corbeille (1,3 Go).", bytes: gb(1.3)),
            AutomationLogEntry(date: at(10.2), kind: .cleanup, automatic: true, title: "Nettoyage sans risque",
                               detail: "962 éléments traités, 5,4 Go libérés.", bytes: gb(5.4)),
            AutomationLogEntry(date: at(12.8), kind: .downloads, automatic: false, title: "Rangement des Téléchargements activé",
                               detail: "Après un aperçu à blanc.", setting: true),
            AutomationLogEntry(date: at(17.2), kind: .cleanup, automatic: true, title: "Nettoyage sans risque",
                               detail: "1 107 éléments traités, 4,9 Go libérés. 2 éléments n'ont pas pu être supprimés (fichiers en cours d'utilisation ou protégés).",
                               bytes: gb(4.9), failures: 2),
            AutomationLogEntry(date: at(24.2), kind: .cleanup, automatic: true, title: "Nettoyage sans risque",
                               detail: "1 031 éléments traités, 5,8 Go libérés.", bytes: gb(5.8)),
            AutomationLogEntry(date: at(91), kind: .cleanup, automatic: false, title: "Nettoyage planifié activé",
                               detail: "Après un aperçu à blanc.", setting: true),
            AutomationLogEntry(date: at(366), kind: .health, automatic: false, title: "Historique de santé activé",
                               detail: "Un instantané par jour.", setting: true)
        ]
    }

    /// A year of fictional days: free space slowly eaten and given back by the weekly cleanup (on since 91 days),
    /// a battery that ages, a few days without the Mac.
    static func samples(now: Date) -> [AutomationHealthSample] {
        var rng = SeededRNG(state: DemoData.seed ^ 0xA07_0A71)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let total: Int64 = 994_662_584_320
        var free = 352.0, junk = 2.0
        var out: [AutomationHealthSample] = []
        for daysAgo in stride(from: 364, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let automated = daysAgo <= 91
            junk += 0.25 + rng.double(0...0.45)
            free -= 0.12 + rng.double(-0.9...1.0) + (rng.unit() > 0.97 ? rng.double(4...14) : 0)
            let cleans = automated ? daysAgo % 7 == 3 : (daysAgo % 41 == 0)
            if cleans {
                free += junk * 0.85
                junk = rng.double(0.6...1.6)
            }
            let skip = daysAgo > 0 && rng.unit() < 0.06
            guard !skip else { continue }
            let age = Double(364 - daysAgo) / 364
            // Batteries report whole percents and only go down.
            let health = (100 - 7 * age).rounded(.down)
            let score = min(97, max(55, 74 + (automated ? 9 : 0) - junk * 0.6 + (free - 300) * 0.08 + rng.double(-3...3)))
            let memory = 0.58 + 0.07 * sin(Double(daysAgo) / 6.5) + rng.double(0...0.06)
            out.append(AutomationHealthSample(day: day, diskFree: gb(free), diskTotal: total, memoryUsed: memory,
                                              batteryHealth: health / 100, batteryCycles: max(0, 187 - Int(Double(daysAgo) * 0.5)),
                                              score: Int(score.rounded()), junk: gb(junk)))
        }
        // End on the free space the demo monitor shows today.
        if let last = out.last {
            let shift = 311_408_000_000 - last.diskFree
            out = out.map { var s = $0; s.diskFree += shift; return s }
        }
        return out
    }

    static func downloadFiles(now: Date) -> [AutomationFile] {
        let folder = FS.home + "/Downloads/"
        func f(_ name: String, _ size: Int64, days: Double, modifiedMinutes: Double? = nil, dir: Bool = false) -> AutomationFile {
            let added = now.addingTimeInterval(-days * 86400)
            return AutomationFile(path: folder + name, name: name, size: size, added: added,
                                  modified: modifiedMinutes.map { now.addingTimeInterval(-$0 * 60) } ?? added, isDirectory: dir)
        }
        return [
            f("Mosaique-1.5.dmg", mb(18.2), days: 12),
            f("Lumen-Installer-3.2.pkg", mb(96), days: 3),
            f("IMG_4521.HEIC", mb(3.1), days: 2),
            f("Capture d'écran à 09.41.12.png", mb(1.2), days: 4),
            f("affiche-concert.jpg", mb(0.84), days: 6),
            f("logo-final (2).svg", mb(0.03), days: 8),
            f("facture-electricite-septembre.pdf", mb(0.21), days: 9),
            f("photos-vacances.zip", mb(412), days: 46),
            f("sauvegarde-site.tar.gz", mb(88), days: 15),
            f("Orbite-2.0.dmg", mb(64), days: 25),
            f("podcast-episode-42.mp3", mb(54), days: 5),
            f("film-famille.mp4.crdownload", mb(700), days: 0.01, modifiedMinutes: 0.2),
            f("notes-reunion.md", 4_200, days: 1),
            f("brouillon.txt", 1_800, days: 2, modifiedMinutes: 3),
            f("Projet client", 0, days: 30, dir: true)
        ]
    }

    static func trashItems(now: Date) -> [AutomationTrash.Item] {
        let folder = FS.home + "/.Trash/"
        func i(_ name: String, _ size: Int64, days: Double) -> AutomationTrash.Item {
            AutomationTrash.Item(path: folder + name, name: name, size: size, added: now.addingTimeInterval(-days * 86400))
        }
        return [
            i("ancien-export.zip", mb(820), days: 62),
            i("Capture d'écran.png", mb(1.1), days: 65),
            i("Brouillon présentation.key", mb(48), days: 41),
            i("IMG_0937.HEIC", mb(3.2), days: 35),
            i("maquette-v3.sketch", mb(5), days: 19),
            i("Notes de réunion.txt", 9_000, days: 12),
            i("Mosaique-1.4.dmg", mb(17), days: 3)
        ]
    }
}
