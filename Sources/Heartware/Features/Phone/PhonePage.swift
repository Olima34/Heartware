import SwiftUI
import AppKit

struct PhonePage: View {
    @Environment(AppModel.self) private var app
    static var tint: Color { Theme.accent }

    var body: some View {
        let m = app.phone
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: m.info?.symbol ?? "iphone", title: "iPhone",
                     subtitle: "Sa santé, et ses photos et vidéos triées pour libérer de la place.",
                     tint: Self.tint, seed: 91, tip: Self.tip) {
                if let i = m.info, m.link == .ready { PhoneDevicePill(info: i) }
            }
            if let kind = m.reviewing, m.photoState == .ready {
                PhoneReview(kind: kind)
            } else {
                switch m.link {
                case .absent:
                    PhoneWaitingCard()
                    if !PhoneBridge.isAvailable && !DemoData.isEnabled { PhonePhotosPanel() }
                    if !m.knownDevices.isEmpty { PhoneKnownDevices() }
                case .reading:
                    Card(padding: 24) {
                        HStack(spacing: 12) {
                            BusyMascot(.checking, pixel: 1.5)
                            Text("Je fais connaissance avec ton iPhone…").font(.ui(13)).foregroundStyle(Theme.text2)
                        }
                    }
                case .untrusted:
                    PhoneTrustCard()
                case .ready:
                    if let i = m.info {
                        PhoneCheckupRow(info: i)
                        PhoneNotebookPanel(info: i)
                    }
                    PhonePhotosPanel()
                }
            }
        }
        // A fresh check-up each time the page comes back (about a second, in the background).
        .onAppear {
            m.pageVisible = true
            if m.link == .ready { m.read() }
        }
        .onDisappear { m.pageVisible = false }
        // Back from Photos (its iCloud settings): a library still filling is looked at again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if m.librarySync.waiting { m.checkLibrary() }
        }
    }

    static let tip = HelpTip(
        id: "phone.page", title: "Ton iPhone sur ce Mac",
        text: "Branche-le avec un câble (un iPad marche aussi) : Heartware note son bilan à chaque branchement. Ses photos sont examinées sur ce Mac, rien n'est envoyé ailleurs, et rien ne quitte l'iPhone sans une copie vérifiée sur ton Mac, sauf les doublons exacts.")
}

// MARK: - Header

private struct PhoneDevicePill: View {
    var info: PhoneInfo

    var body: some View {
        HStack(spacing: 6) {
            if Theme.icons != .hidden { Image(systemName: "cable.connector").font(.ui(11.5, .semibold)) }
            Text("\(info.name) · \(info.model)").font(.ui(12, .semibold)).lineLimit(1)
        }
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(PillShape().fill(Theme.card))
        .overlay(PillShape().strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

// MARK: - Nothing plugged

private struct PhoneWaitingCard: View {
    var body: some View {
        Card(padding: 24) {
            HStack(alignment: .top, spacing: 20) {
                IconBadge(symbol: "cable.connector", tint: PhonePage.tint, size: 46)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Branche ton iPhone").font(.serif(24)).foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Branche-le à ce Mac avec un câble")
                        step(2, "Déverrouille-le")
                        step(3, "S'il le demande, touche « Se fier » et tape ton code")
                    }
                    if !PhoneBridge.isAvailable && !DemoData.isEnabled {
                        Text("Avec cette version de macOS, seules les photos et vidéos sont lisibles, pas la batterie ni le stockage.")
                            .font(.ui(11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.ui(11, .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18).background(PillShape().fill(PhonePage.tint))
            Text(text).font(.ui(12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The devices seen before, with their last check-up: the notebook stays readable without the cable.
private struct PhoneKnownDevices: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Panel(title: "Déjà vus sur ce Mac", symbol: "book.closed", tint: PhonePage.tint) {
            VStack(spacing: 2) {
                ForEach(app.phone.knownDevices, id: \.udid) { known in
                    let d = known.device
                    let last = d.points.last
                    HoverRow {
                        HStack(spacing: 10) {
                            IconBadge(symbol: d.productType.hasPrefix("iPad") ? "ipad" : "iphone", tint: PhonePage.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                Text("\(PhoneRules.modelName(d.productType) ?? (d.productType.hasPrefix("iPad") ? "iPad" : "iPhone")) · vu \(Fmt.relative(d.lastSeen)) · \(Fmt.plural(d.points.count, "bilan", "bilans"))")
                                    .font(.ui(11)).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            if let last {
                                Text("\(Fmt.bytes(last.free)) libres").font(.ui(12, .medium)).foregroundStyle(Theme.text2).monospacedDigit()
                                if let h = last.health { Tag(text: "Batterie \(Fmt.pct(h))", tint: h < 0.8 ? Theme.warn : Theme.good, filled: true) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PhoneTrustCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .top, spacing: 16) {
                IconBadge(symbol: "lock.iphone", tint: Theme.warn, size: 40)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ton iPhone ne fait pas encore confiance à ce Mac").font(.serif(20)).foregroundStyle(Theme.text)
                    Text("Déverrouille-le, touche « Se fier » et tape ton code : Heartware continue tout seul.")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Redemander à l'iPhone") { app.phone.askTrust() }
                            .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        Button("Réessayer") { app.phone.read() }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Check-up

private struct PhoneCheckupRow: View {
    var info: PhoneInfo

    var body: some View {
        TileRow {
            if let s = info.storage {
                StatTile(symbol: "internaldrive", value: "\(Fmt.bytes(s.free)) libres", label: "Stockage",
                         detail: "Sur \(Fmt.bytes(s.total)) · \(Fmt.pct(Double(s.used) / Double(max(1, s.total)))) utilisés",
                         tint: PhoneRules.storageStatus(s) == .ok ? PhonePage.tint : PhoneRules.storageStatus(s).color)
            }
            if let b = info.battery {
                StatTile(symbol: b.charging ? "battery.100percent.bolt" : "battery.75percent",
                         value: b.health.map(Fmt.pct) ?? b.level.map { "\($0) %" } ?? "—",
                         label: b.health != nil ? "Capacité de la batterie" : "Batterie", detail: PhoneRules.batteryDetail(b),
                         tint: PhoneRules.batteryStatus(b) == .warn ? Theme.warn : Theme.good)
            }
            StatTile(symbol: "gearshape.2", value: "iOS \(info.iosVersion)", label: info.model,
                     detail: info.build.isEmpty ? nil : "Version \(info.build)", tint: Theme.palette[1])
            StatTile(symbol: "externaldrive.badge.icloud",
                     value: info.localBackup.map(Fmt.relative) ?? (info.cloudBackup == true ? "Sur iCloud" : "Aucune vue"),
                     label: "Sauvegarde", detail: PhoneRules.backupDetail(info),
                     tint: PhoneRules.backupStatus(info) == .ok ? Theme.palette[2] : Theme.warn)
        }
    }
}

private struct PhoneNotebookPanel: View {
    @Environment(AppModel.self) private var app
    var info: PhoneInfo

    var body: some View {
        let points = app.phone.notebook?.points ?? []
        Panel(title: "Carnet de santé", symbol: "heart.text.square", tint: PhonePage.tint) {
            Text(points.first.flatMap { PhoneRules.date(ofDay: $0.day) }.map { "\(Fmt.plural(points.count, "bilan", "bilans")) depuis le \(Fmt.day($0))" } ?? "")
                .font(.ui(11.5)).foregroundStyle(Theme.text3)
        } content: {
            HStack(alignment: .top, spacing: 18) {
                curve(title: "Place libre", values: points.map { Double($0.free) / 1e9 }, unit: { Fmt.dec($0) + " Go" },
                      trend: PhoneRules.storageTrend(points), tint: PhonePage.tint)
                curve(title: "Capacité de la batterie", values: points.compactMap { $0.health.map { $0 * 100 } }, unit: { Fmt.int($0) + " %" },
                      trend: PhoneRules.batteryTrend(points), tint: Theme.good)
            }
        }
    }

    private func curve(title: String, values: [Double], unit: (Double) -> String, trend: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text2)
                Spacer()
                if let last = values.last { Text(unit(last)).font(.ui(12, .semibold)).foregroundStyle(Theme.text).monospacedDigit() }
            }
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                // Zoomed on its range: a battery going from 89 to 86 % must not look flat.
                let floor = max(0, lo - max(hi - lo, abs(hi) * 0.02) * 0.6)
                Sparkline(values: values.map { $0 - floor }, maxValue: (hi - floor) * 1.05, tint: tint).frame(height: 44)
            } else {
                RoundedRectangle(cornerRadius: Theme.r(6)).fill(Theme.track).frame(height: 44)
                    .overlay(Text("Se dessine au fil des branchements").font(.ui(11)).foregroundStyle(Theme.text3))
            }
            Text(trend ?? "Tendance dans quelques semaines")
                .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Photos and videos

private struct PhonePhotosPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.phone
        Panel(title: "Photos et vidéos", subtitle: subtitle, symbol: "photo.on.rectangle.angled", tint: PhonePage.tint) {
            if m.photoState == .ready {
                HStack(spacing: 10) {
                    if m.freeable > 0 {
                        Text("Jusqu'à \(Fmt.bytes(m.freeable)) à libérer").font(.ui(12, .semibold)).foregroundStyle(PhonePage.tint)
                    }
                    Button("Tout parcourir") { m.reviewing = .all }
                        .buttonStyle(SoftButtonStyle(small: true))
                        .help("Choisis toi-même parmi toutes les photos et vidéos, des plus anciennes aux plus récentes")
                }
            }
        } content: {
            switch m.photoState {
            case .idle:
                HStack(spacing: 12) {
                    ScanButton(title: "Trier les photos et vidéos", symbol: "photo.stack") { m.analysePhotos() }
                    Text("Garde l'iPhone déverrouillé. Tout est examiné sur ce Mac, rien n'est supprimé sans toi.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            case .locked:
                HStack(spacing: 12) {
                    BusyMascot(.searching, pixel: 1.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Déverrouille ton iPhone").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Text("Heartware reprend dès que tu l'ouvres.")
                            .font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                }
            case .listing:
                HStack(spacing: 12) {
                    BusyMascot(.inspecting, pixel: 1.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Je liste les photos et vidéos de l'iPhone…").font(.ui(12.5)).foregroundStyle(Theme.text2)
                        Text("Rien ne vient ? Déverrouille ton iPhone, ou débranche-le et rebranche-le.").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                }
            case .failed(let why):
                VStack(alignment: .leading, spacing: 10) {
                    Callout(symbol: "exclamationmark.triangle", title: "L'iPhone n'a pas ouvert ses photos", text: why, tint: Theme.warn)
                    Button("Réessayer") { m.analysePhotos() }.buttonStyle(SoftButtonStyle(small: true))
                }
            case .ready:
                PhoneCategoryList()
            }
        }
    }

    private var subtitle: String {
        let m = app.phone
        guard m.photoState == .ready else { return "Ce qui prend le plus de place sur un iPhone, trié pour toi" }
        let photos = m.items.filter { $0.kind == .photo }.count
        return "\(Fmt.plural(photos, "photo", "photos")) et \(Fmt.plural(m.items.count - photos, "vidéo", "vidéos")) sur l'iPhone · \(Fmt.bytes(m.mediaSize))"
    }
}

private struct PhoneCategoryList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.phone
        VStack(alignment: .leading, spacing: 12) {
            if let t = m.task, t.kind == .analysis {
                HStack(spacing: 12) {
                    BusyMascot(.inspecting, pixel: 1.2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("J'examine chaque photo sur ce Mac… \(Fmt.int(t.done)) sur \(Fmt.int(t.total))")
                            .font(.ui(12)).foregroundStyle(Theme.text2).monospacedDigit()
                        UsageBar(fraction: t.fraction, tint: PhonePage.tint, height: 5)
                    }
                    Button("Arrêter") { m.stopTask() }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
            if m.categories.isEmpty && m.analysed {
                EmptyHint(text: "Rien à trier : ton iPhone est déjà bien rangé.", symbol: "checkmark.seal")
            }
            VStack(spacing: 2) {
                ForEach(m.categories) { c in PhoneCategoryRow(category: c) }
            }
            if !m.analysed && m.task == nil {
                HStack(spacing: 10) {
                    Button("Lancer l'analyse fine") { m.analysePhotos() }.buttonStyle(SoftButtonStyle(small: true))
                    Text("Pour trouver aussi les séries, les doublons, les tickets et les photos ratées.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            PhoneModeNote()
        }
    }
}

private struct PhoneCategoryRow: View {
    @Environment(AppModel.self) private var app
    var category: PhoneCategory

    var body: some View {
        let m = app.phone
        let picked = category.ids.filter { m.selection.contains($0) }.count
        HoverRow {
            HStack(spacing: 12) {
                IconBadge(symbol: category.kind.symbol, tint: PhonePage.tint, size: 28)
                HStack(spacing: 6) {
                    Text(category.kind.title).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                    Text(Fmt.int(category.ids.count)).font(.ui(11, .semibold)).foregroundStyle(Theme.text3).monospacedDigit()
                    if picked > 0 { Tag(text: "\(Fmt.int(picked)) cochées", tint: Theme.accent, filled: true) }
                }
                Spacer(minLength: 8)
                Text(Fmt.bytes(category.size)).font(.serif(17)).foregroundStyle(Theme.text).monospacedDigit()
                Button("Revoir") { m.reviewing = category.kind }.buttonStyle(SoftButtonStyle(small: true))
            }
        }
        .help(category.kind.detail)
        .onTapGesture { m.reviewing = category.kind }
    }
}

/// How photos leave this iPhone, and the Photos permission when it is needed.
private struct PhoneModeNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.phone
        if let trouble = m.deletionTrouble {
            Callout(symbol: "exclamationmark.triangle", title: "Rien de supprimé pour ces éléments", text: trouble, tint: Theme.warn)
        }
        switch m.deletion {
        case .cable:
            PhoneNote(symbol: "checkmark.shield", tint: Theme.good,
                      text: "Rien ne quitte l'iPhone sans une copie vérifiée sur ton Mac : une suppression par le câble est définitive.")
        case .library, .none:
            if m.iCloudPhotos { PhoneCloudNote() } else {
                PhoneNote(symbol: "lock", tint: Theme.warn,
                          text: "Cet iPhone refuse les suppressions par le câble (ses photos viennent sans doute d'un ordinateur) : copie-les ici, et supprime-les depuis l'iPhone.")
            }
        }
    }
}

/// One line on how photos leave the iPhone, with its « ? » when there is more to it.
private struct PhoneNote: View {
    var symbol: String
    var tint: Color
    var text: String
    var tip: HelpTip? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if Theme.icons != .hidden {
                Image(systemName: symbol).font(.ui(12, .medium)).foregroundStyle(Theme.icons == .tinted ? tint : Theme.text2)
            }
            Text(text).font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if let tip { HelpTipButton(tip: tip, size: 13) }
        }
    }
}

/// iCloud Photos on the iPhone: deletions go through this Mac's Photos library, when it is the same one.
private struct PhoneCloudNote: View {
    @Environment(AppModel.self) private var app

    static let cloudTip = HelpTip(
        id: "phone.icloud", title: "Avec Photos iCloud",
        text: "L'iPhone refuse alors toute suppression par le câble : Heartware passe par l'app Photos de ce Mac, avec le même compte iCloud. « Mettre au frais et supprimer » garde d'abord une copie de chaque original sur ce Mac.")

    static let missingTip = HelpTip(
        id: "phone.icloudMissing", title: "Donner tes photos à ce Mac",
        text: "Si ton stockage iCloud a de la place : dans Photos sur ce Mac, Réglages › iCloud, active « Photos iCloud » avec le même compte que l'iPhone, choisis « Optimiser le stockage du Mac » et laisse la synchronisation finir.\n\nSi ton iPhone dit « Stockage iCloud saturé », ses photos récentes n'arriveront jamais ici : désactive Photos iCloud sur l'iPhone (Réglages › ton nom › iCloud › Photos, en gardant les photos). Heartware copiera, vérifiera puis supprimera par le câble ; tes photos ne se synchroniseront plus entre tes appareils.")

    static let syncTip = HelpTip(
        id: "phone.icloudSync", title: "La synchronisation de Photos",
        text: "Photos commence par les plus anciennes : compte de quelques minutes à quelques heures, et garder Photos ouvert va plus vite. Heartware revérifie toutes les minutes tant que cette page est ouverte.")

    private var actions: some View {
        let m = app.phone
        return HStack(spacing: 8) {
            Button("Ouvrir Photos") { m.openPhotosApp() }.buttonStyle(SoftButtonStyle(small: true))
            Button("Vérifier maintenant") { m.checkLibrary() }.buttonStyle(SoftButtonStyle(small: true))
            if let at = m.libraryCheckedAt {
                Text("Vérifié à \(Fmt.clock(at))").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
    }

    var body: some View {
        let m = app.phone
        VStack(alignment: .leading, spacing: 8) {
            switch (m.photosAccess, m.librarySync) {
            case (.granted, .missing(let total)):
                PhoneNote(symbol: "icloud.slash", tint: Theme.warn,
                          text: "La photothèque de ce Mac n'a pas les photos de ton iPhone (\(Fmt.int(total)) contre \(Fmt.int(m.items.count))) : pour supprimer, il lui faut les mêmes. « Copier sur le Mac » marche déjà.",
                          tip: Self.missingTip)
                actions
            case (.granted, .syncing(let total)):
                PhoneNote(symbol: "arrow.triangle.2.circlepath.icloud", tint: PhonePage.tint,
                          text: "Photos synchronise ta photothèque : \(Fmt.int(total)) arrivées sur \(Fmt.int(m.items.count)). « Supprimer » apparaîtra quand elles y seront.",
                          tip: Self.syncTip)
                actions
            case (.granted, .checking):
                HStack(spacing: 10) {
                    BusyMascot(.searching, pixel: 1)
                    Text("Je regarde si la photothèque de ce Mac est celle de ton iPhone…").font(.ui(12)).foregroundStyle(Theme.text2)
                }
            default:
                PhoneNote(symbol: "icloud", tint: PhonePage.tint,
                          text: "Photos iCloud est activé : une photo supprimée part aussi d'iCloud et de tes autres appareils, après 30 jours dans « Supprimés récemment ».",
                          tip: Self.cloudTip)
                if m.photosAccess != .granted {
                    HStack(spacing: 10) {
                        Text(m.photosAccess == .denied ? "L'accès à Photos est refusé : autorise Heartware dans Réglages Système › Confidentialité › Photos."
                                                       : "Pour supprimer, Heartware passe par ta photothèque ; macOS confirmera chaque suppression.")
                            .font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Button(m.photosAccess == .denied ? "Ouvrir les réglages" : "Autoriser l'accès à Photos") {
                            if m.photosAccess == .denied { Finder.open(PermissionKind.photos.settingsURL) } else { m.requestPhotosAccess() }
                        }
                        .buttonStyle(SoftButtonStyle(small: true))
                    }
                }
            }
        }
    }
}

// MARK: - Review

private struct PhoneReview: View {
    @Environment(AppModel.self) private var app
    var kind: PhoneCategoryKind

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: 10)]

    var body: some View {
        let m = app.phone
        let category = m.category(kind)
        let ids = category?.ids ?? []
        let byID = Dictionary(m.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allPicked = !ids.isEmpty && ids.allSatisfy { m.selection.contains($0) }
        Panel(title: kind.title, subtitle: "\(Fmt.plural(ids.count, "élément", "éléments")) · \(Fmt.bytes(category?.size ?? 0)) · \(kind.detail)",
              symbol: kind.symbol, tint: PhonePage.tint) {
            HStack(spacing: 8) {
                // Everything at once from « Tout parcourir » would be one click from emptying the iPhone.
                if kind != .all {
                    Button(allPicked ? "Tout décocher" : "Tout cocher") { allPicked ? m.deselectAll(kind) : m.selectAll(kind) }
                        .buttonStyle(SoftButtonStyle(small: true))
                }
                Button {
                    m.reviewing = nil
                } label: {
                    ThemedLabel(title: "Retour", symbol: "chevron.left")
                }
                .buttonStyle(SoftButtonStyle(small: true))
            }
        } content: {
            if kind == .similar, let groups = category?.groups {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.self) { group in
                        ScrollArea(axes: .horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(group.enumerated()), id: \.element) { n, id in
                                    if let item = byID[id] { PhoneThumb(item: item, kept: n == 0) }
                                }
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        if let item = byID[id] { PhoneThumb(item: item) }
                    }
                }
            }
        }
    }
}

/// One photo or video: its thumbnail, its size, ticked or not. The kept shot of a series cannot be ticked.
private struct PhoneThumb: View {
    @Environment(AppModel.self) private var app
    var item: PhoneItem
    var kept = false
    @State private var image: CGImage?

    var body: some View {
        let m = app.phone
        let on = m.selection.contains(item.id)
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: 118, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
            if kept {
                Tag(text: "Gardée", symbol: "star", tint: Theme.good, filled: true)
                    .background(PillShape().fill(Theme.card))
                    .padding(6)
            } else {
                CheckBox(state: on ? .on : .off) { m.toggle(item.id) }
                    .padding(7)
            }
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    if item.kind == .video, Theme.icons != .hidden { Image(systemName: "video.fill").font(.ui(8.5)) }
                    Text(caption).font(.ui(10.5, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PillShape().fill(Theme.card.opacity(0.92)))
                .padding(6)
            }
            .frame(width: 118, height: 118, alignment: .bottomTrailing)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous)
            .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2.5 : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { if !kept { m.toggle(item.id) } }
        .help("\(item.name) · \(Fmt.day(item.date)) \(Fmt.clock(item.date))")
        .task(id: item.id) { image = await m.thumbnail(item.id) }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            // Demo, snapshots, or while it arrives: a tile of the item's colour.
            let tint = Theme.color(index: abs(item.id.hashValue))
            ZStack {
                Rectangle().fill(tint.opacity(DemoData.isEnabled ? 0.55 : 0.12))
                if Theme.icons != .hidden {
                    Image(systemName: item.kind == .video ? "film" : "photo").font(.ui(22)).foregroundStyle(Theme.ink(on: tint).opacity(0.7))
                }
            }
        }
    }

    private var caption: String {
        item.kind == .video && item.duration > 0 ? "\(Fmt.duration(item.duration)) · \(Fmt.bytes(item.size))" : Fmt.bytes(item.size)
    }
}

// MARK: - Action bar

struct PhoneBottomBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirmFree = false
    @State private var confirmDelete = false

    var body: some View {
        let m = app.phone
        let count = m.selection.count
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.bytes(m.selectedSize)) sélectionnés").font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit()
                Text("\(Fmt.plural(count, "élément", "éléments")) · \(folderText)\(libraryText.map { " · " + $0 } ?? "")")
                    .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Button("Changer de dossier") { m.chooseFolder() }.buttonStyle(.plain).font(.ui(11)).foregroundStyle(Theme.accent)
            Spacer()
            if let t = m.task, t.kind != .analysis {
                BusyMascot(t.kind == .archive ? .downloading : .sweeping, pixel: 1)
                Text(t.kind == .archive ? "Copie \(Fmt.int(t.done)) sur \(Fmt.int(t.total))…" : "Suppression…")
                    .font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
                Button("Arrêter") { m.stopTask() }.buttonStyle(SoftButtonStyle())
            } else {
                Button("Tout décocher") { m.selection = [] }.buttonStyle(SoftButtonStyle())
                Button("Copier sur le Mac") { run { await m.archive(free: false) } }.buttonStyle(SoftButtonStyle(prominent: m.deletion == .none))
                switch m.deletion {
                case .cable:
                    if m.selectionIsDuplicates {
                        Button("Supprimer les doublons") { confirmDelete = true }.buttonStyle(SoftButtonStyle())
                    }
                    Button("Mettre au frais et libérer") { confirmFree = true }.buttonStyle(SoftButtonStyle(prominent: true))
                case .library:
                    Button("Mettre au frais et supprimer") { confirmFree = true }.buttonStyle(SoftButtonStyle())
                    Button("Supprimer") { confirmDelete = true }.buttonStyle(SoftButtonStyle(prominent: true))
                case .none:
                    EmptyView()
                }
            }
        }
        .confirmAction("Mettre au frais \(Fmt.plural(count, "élément", "éléments")) ?",
                       message: m.deletion == .cable
                        ? "\(Fmt.bytes(m.selectedSize)) copiés dans « \(folderName) », chaque copie vérifiée, puis supprimés de l'iPhone pour de bon. Ce qui n'a pas pu être copié reste sur l'iPhone."
                        : "\(Fmt.bytes(m.selectedSize)) copiés dans « \(folderName) », puis mis dans « Supprimés récemment » pour 30 jours, sur l'iPhone et tes autres appareils.",
                       button: m.deletion == .cable ? "Mettre au frais et libérer" : "Mettre au frais et supprimer", isPresented: $confirmFree) {
            run { await m.archive(free: true) }
        }
        .confirmAction(m.deletion == .library ? "Supprimer \(Fmt.plural(count, "élément", "éléments")) ?" : "Supprimer \(Fmt.plural(count, "doublon", "doublons")) ?",
                       message: m.deletion == .library
                        ? "\(Fmt.bytes(m.selectedSize)). Ils restent 30 jours dans « Supprimés récemment », sur l'iPhone et tes autres appareils. macOS te demandera de confirmer."
                        : "\(Fmt.bytes(m.selectedSize)). L'original de chacun reste sur l'iPhone.",
                       button: "Supprimer", isPresented: $confirmDelete) {
            run { await m.deleteSelection() }
        }
    }

    /// With iCloud Photos and a library still partial: how much of the selection Photos on this Mac holds.
    private var libraryText: String? {
        let m = app.phone
        guard m.iCloudPhotos, !m.canDelete, m.librarySync.waiting, m.photosAccess == .granted else { return nil }
        guard let found = m.selectionInLibrary?.count else { return "je cherche dans Photos…" }
        if found == 0 { return "absents de la photothèque de ce Mac" }
        return found == m.selection.count ? "tous dans Photos" : "\(Fmt.int(found)) sur \(Fmt.int(m.selection.count)) dans Photos"
    }

    private var folderName: String {
        app.phone.settings.archiveFolder.map { ($0 as NSString).lastPathComponent } ?? "le dossier que tu vas choisir"
    }

    private var folderText: String {
        app.phone.settings.archiveFolder.map { "copies dans « \(($0 as NSString).lastPathComponent) »" } ?? "tu choisiras où copier les originaux"
    }

    private func run(_ work: @escaping @MainActor () async -> CommandOutcome) {
        Task {
            switch await work() {
            case .message(let text): HUD.show(text)
            case .failed(let text): HUD.show(text, symbol: "xmark.octagon.fill")
            default: break
            }
        }
    }
}
