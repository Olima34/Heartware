import SwiftUI

struct AppsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.apps
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "square.grid.2x2", title: "Gestion des applications",
                     subtitle: "Tes apps, et une désinstallation qui n'oublie rien.",
                     tint: Theme.palette[4], seed: 57, tip: Self.tip) {
                ScanButton(title: model.lastScan == nil ? "Analyser" : "Actualiser", symbol: "arrow.clockwise", running: model.isScanning,
                           activity: .checking) {
                    Task { await model.scan() }
                }
            }
            if model.isScanning && model.apps.isEmpty {
                ScanProgressCard(title: "Je fais l'inventaire de tes apps…", label: "Tailles, versions, dernière ouverture", progress: model.progress,
                                 activity: .checking)
            } else if model.apps.isEmpty {
                Card { EmptyHint(text: "Lance l'analyse pour voir tes applications.", symbol: "square.grid.2x2") }
            } else {
                if let msg = model.message {
                    Callout(symbol: model.messageOK ? "checkmark.circle" : "exclamationmark.triangle", title: model.messageOK ? "Fait" : "Pas tout à fait",
                          text: msg, tint: model.messageOK ? Theme.good : Theme.warn)
                }
                HStack(spacing: 10) {
                    PillPicker(options: AppFilter.allCases, selection: $model.filter, label: { $0.title }, badge: { f in
                        switch f {
                        case .unused: return model.unused.isEmpty ? nil : "\(model.unused.count)"
                        case .intel: return model.intel.isEmpty ? nil : "\(model.intel.count)"
                        case .leftovers: return model.orphans.isEmpty ? nil : "\(model.orphans.count)"
                        default: return nil
                        }
                    })
                    Spacer()
                    if model.filter != .leftovers {
                        SearchField(text: $model.search, prompt: "Rechercher une app")
                            .frame(width: 200)
                        BorderlessMenu {
                            Picker("Trier par", selection: $model.sort) {
                                ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label(model.sort.title, systemImage: "arrow.up.arrow.down").font(.ui(11.5)).foregroundStyle(Theme.text2)
                        }
                    }
                }
                if model.filter == .leftovers {
                    OrphansView()
                } else {
                    summary(model)
                    Card(padding: 8) {
                        VStack(spacing: 0) {
                            let list = model.visible
                            ForEach(list) { a in
                                AppRow(item: a)
                            }
                            if list.isEmpty { EmptyHint(text: "Aucune app dans cette catégorie.") }
                        }
                    }
                }
            }
        }
        .task { if app.apps.lastScan == nil { await app.apps.scan() } }
        .sheet(item: $model.uninstallTarget) { target in
            UninstallSheet(target: target)
                .environment(app)
        }
    }

    /// One line over the list, for the chosen filter: what used to be four tiles.
    private func summary(_ model: AppsModel) -> some View {
        let line: String
        var tint = Theme.text2
        var help: String?
        switch model.filter {
        case .unused:
            line = model.unused.isEmpty ? "Tu te sers de toutes tes apps, bravo."
                : "\(Fmt.plural(model.unused.count, "app pas ouverte", "apps pas ouvertes")) depuis 3 mois · \(Fmt.bytes(model.unused.reduce(0) { $0 + $1.size })) récupérables"
            help = "D'après Spotlight, sans les composants d'Apple. Une app qui tourne seulement en arrière-plan peut s'y glisser à tort."
        case .intel:
            line = model.intel.isEmpty ? "Tout est natif Apple Silicon."
                : "Elles passent par Rosetta, plus lentes, et la plupart ne marcheront plus après macOS 27 : cherche leur version Apple Silicon."
            if !model.intel.isEmpty { tint = Theme.warn }
        case .appStore:
            line = "\(Fmt.plural(model.apps.filter(\.fromAppStore).count, "app", "apps")) de l'App Store · les autres se mettent à jour elles-mêmes"
        default:
            line = "\(Fmt.plural(model.apps.count, "application", "applications")) · \(Fmt.bytes(model.totalSize)) au total"
        }
        return HStack(spacing: 6) {
            Text(line).font(.ui(12)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
            if help != nil, Theme.icons != .hidden {
                Image(systemName: "info.circle").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .help(help ?? line)
    }

    static let tip = HelpTip(
        id: "apps.page", title: "Gestion des applications",
        text: "« Inutilisées » liste les apps que tu n'as pas ouvertes depuis 3 mois, « Intel » celles qui passent encore par Rosetta. « Désinstaller… » te montre l'app et tous ses fichiers (réglages, caches) avant de les mettre à la Corbeille. « Restes » retrouve ceux des apps déjà jetées.")
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.ui(11.5)).foregroundStyle(Theme.text3)
            if Snapshot.isActive {
                Text(text.isEmpty ? prompt : text).font(.ui(12.5)).foregroundStyle(text.isEmpty ? Theme.text3 : Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: $text).textFieldStyle(.plain).font(.ui(12.5))
            }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.ui(11)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.r(8)).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(8)).strokeBorder(Theme.border, lineWidth: Theme.line))
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var app
    var item: InstalledApp
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: item.path, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if let v = item.version { Text(v).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                }
                HStack(spacing: 5) {
                    if item.isRunning { Tag(text: "Ouverte", symbol: "circle.fill", tint: Theme.good, filled: true) }
                    if item.fromAppStore { Tag(text: "App Store", symbol: "bag", tint: Theme.palette[1], filled: true) }
                    if item.architecture == .intel { Tag(text: "Intel", symbol: "cpu", tint: Theme.warn, filled: true) }
                    if item.isApple { Tag(text: "Apple", symbol: "apple.logo", tint: Theme.text3) }
                    Text(lastUsedText).font(.ui(11)).foregroundStyle(item.isUnused ? Theme.warn : Theme.text3)
                }
            }
            Spacer(minLength: 10)
            Text(Fmt.bytes(item.size)).font(.ui(12.5, .medium)).foregroundStyle(Theme.text2).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button("Désinstaller…") { Task { await app.apps.prepareUninstall(item) } }
                .buttonStyle(SoftButtonStyle(small: true))
                .opacity(hovering ? 1 : 0.35)
            Button { Finder.reveal(item.path) } label: {
                Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .help("Afficher dans le Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.r(9)).fill(hovering ? Theme.hover.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var lastUsedText: String {
        if let d = item.lastUsed { return "Ouverte \(Fmt.relative(d))" }
        return "Jamais ouverte d'après Spotlight"
    }
}

struct UninstallSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var target: InstalledApp

    var body: some View {
        let model = app.apps
        let chosen = model.leftovers.filter { model.leftoverSelection.contains($0.id) }
        let total = target.size + chosen.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                FileIcon(path: target.path, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Désinstaller \(target.name)").font(.serif(22)).foregroundStyle(Theme.text)
                    Text([target.version.map { "Version \($0)" }, target.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
            }
            if target.isApple {
                ThemedLabel(title: "Une app d'Apple : tu pourras la retélécharger depuis l'App Store.", symbol: "apple.logo")
                    .font(.ui(12)).foregroundStyle(Theme.text2)
            }
            if target.isRunning {
                HStack {
                    Label("\(target.name) est ouverte. Quitte-la avant de la désinstaller.", systemImage: "exclamationmark.triangle")
                        .font(.ui(12)).foregroundStyle(Theme.warn)
                    Spacer()
                    Button("Quitter l'app") { model.quitTarget() }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Ce qui partira à la Corbeille").font(.ui(12, .semibold)).foregroundStyle(Theme.text2)
                ScrollView {
                    VStack(spacing: 2) {
                        HStack(spacing: 10) {
                            CheckBox(state: .on, disabled: true) {}
                            FileIcon(path: target.path, size: 18)
                            Text("\(target.name).app").font(.ui(12)).foregroundStyle(Theme.text)
                            Text("L'application").font(.ui(10.5)).foregroundStyle(Theme.text3)
                            Spacer()
                            Text(Fmt.bytes(target.size)).font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        if model.isFindingLeftovers {
                            HStack(spacing: 10) {
                                BusyMascot(.searching, pixel: 1.5)
                                Text("Je cherche ses fichiers dans ta bibliothèque…").font(.ui(11.5)).foregroundStyle(Theme.text3)
                            }
                                .padding(8)
                        }
                        ForEach(model.leftovers) { item in
                            HStack(spacing: 10) {
                                CheckBox(state: model.leftoverSelection.contains(item.id) ? .on : .off) {
                                    if model.leftoverSelection.contains(item.id) { model.leftoverSelection.remove(item.id) } else { model.leftoverSelection.insert(item.id) }
                                }
                                FileIcon(path: item.path, size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    Text("\(item.detail ?? "") · \(FS.pretty((item.path as NSString).deletingLastPathComponent))")
                                        .font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Fmt.bytes(item.size)).font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line))
            }
            HStack {
                Text("Total : \(Fmt.bytes(total))").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Annuler") { model.uninstallTarget = nil; dismiss() }
                    .buttonStyle(SoftButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.uninstall() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isRemoving { BusyMascot(.sweeping, pixel: 1, ink: Theme.onBad) }
                        Text("Désinstaller")
                    }
                }
                .buttonStyle(SoftButtonStyle(destructive: true))
                .disabled(model.isFindingLeftovers || model.isRemoving || target.isRunning)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
    }
}

struct OrphansView: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    var body: some View {
        let model = app.apps
        VStack(alignment: .leading, spacing: 14) {
            Text("Réglages et caches d'apps déjà jetées, intacts depuis deux semaines. Rien n'est coché d'office, tout part à la Corbeille.")
                .font(.ui(12)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            if !model.orphansScanned {
                HStack {
                    ScanButton(title: "Chercher les restes", symbol: "puzzlepiece", running: model.isScanningOrphans, activity: .searching) {
                        Task { await model.scanOrphans(fullDiskAccess: app.fullDiskAccess) }
                    }
                    Spacer()
                }
            } else if model.orphans.isEmpty {
                Card { EmptyHint(text: "Aucun reste trouvé. Ta bibliothèque est propre.", symbol: "checkmark.seal") }
            } else {
                Card(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(model.orphans) { item in
                            HoverRow {
                                HStack(spacing: 10) {
                                    CheckBox(state: model.orphanSelection.contains(item.id) ? .on : .off) {
                                        if model.orphanSelection.contains(item.id) { model.orphanSelection.remove(item.id) } else { model.orphanSelection.insert(item.id) }
                                    }
                                    FileIcon(path: item.path, size: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                                        Text(item.detail ?? "").font(.ui(10.5)).foregroundStyle(Theme.text3)
                                    }
                                    Spacer()
                                    Button { Finder.reveal(item.path) } label: {
                                        Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(Theme.text3)
                                    }
                                    .buttonStyle(.plain)
                                    Text(Fmt.bytes(item.size)).font(.ui(12)).foregroundStyle(Theme.text2).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                HStack {
                    let size = model.orphans.filter { model.orphanSelection.contains($0.id) }.reduce(0) { $0 + $1.size }
                    Text("\(Fmt.plural(model.orphanSelection.count, "reste coché", "restes cochés")) · \(Fmt.bytes(size))")
                        .font(.ui(12.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Mettre à la Corbeille") { confirm = true }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                        .disabled(model.orphanSelection.isEmpty || model.isRemoving)
                }
            }
        }
        .confirmAction("Mettre ces restes à la Corbeille ?", message: "Tu pourras les récupérer depuis la Corbeille tant qu'elle n'est pas vidée.",
                       button: "Mettre à la Corbeille", isPresented: $confirm) {
            Task { await model.removeOrphans() }
        }
    }
}
