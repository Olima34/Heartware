import SwiftUI

struct StoragePage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.storage
        VStack(alignment: .leading, spacing: 18) {
            PageHero(symbol: "chart.pie", title: "Exploration du stockage",
                     subtitle: "La carte de ton disque, les gros fichiers et les doublons.",
                     tint: Theme.palette[1], seed: 69, tip: Self.tip) {
                HStack(spacing: 10) {
                    BorderlessMenu {
                        Button("Dossier personnel") { Task { await model.scan(FS.home) } }
                        Button("Applications") { Task { await model.scan("/Applications") } }
                        Button("Disque entier") { Task { await model.scan("/") } }
                        Divider()
                        Button("Choisir un dossier…") { model.chooseFolder() }
                    } label: {
                        Label(model.rootTitle, systemImage: "folder").font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                    ScanButton(title: model.root == nil ? "Analyser" : "Relancer", running: model.isScanning, activity: .sorting) {
                        Task { await model.scan() }
                    }
                }
            }
            DiskOverview()
            PillPicker(options: StorageTab.allCases, selection: $model.tab, label: { $0.title }, badge: { t in
                switch t {
                case .bigFiles: return model.bigFiles.isEmpty ? nil : "\(model.bigFiles.count)"
                case .duplicates: return model.dupGroups.isEmpty ? nil : "\(model.dupGroups.count)"
                default: return nil
                }
            })
            if let msg = model.message {
                Callout(symbol: model.messageOK ? "checkmark.circle" : "exclamationmark.triangle", title: model.messageOK ? "Fait" : "Pas tout à fait",
                          text: msg, tint: model.messageOK ? Theme.good : Theme.warn)
            }
            switch model.tab {
            case .explorer: ExplorerTab()
            case .bigFiles: BigFilesTab()
            case .duplicates: DuplicatesTab()
            }
        }
    }

    static let tip = HelpTip(
        id: "storage.page", title: "La carte de ton disque",
        text: "Chaque bloc a la taille de ce qu'il pèse : clique dessus pour y entrer. Un clic droit dans la liste l'affiche dans le Finder, demande à Claude ce que c'est ou le met à la Corbeille. Les doublons sont comparés par leur contenu exact, pas par leur nom.")
}

struct DiskOverview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.monitor
        let used = max(0, m.diskTotal - m.diskFree)
        let purgeable = max(0, m.diskFree - m.diskFreeStrict)
        Card(padding: 16) {
            HStack(spacing: 18) {
                Gauge(value: m.diskUsedFraction, text: Fmt.pct(m.diskUsedFraction), caption: "utilisé",
                      tint: Theme.load(m.diskUsedFraction), size: 70, lineWidth: 7)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(Fmt.bytes(m.diskFree)) disponibles").font(.serif(22)).foregroundStyle(Theme.text)
                        Text("sur \(Fmt.bytes(m.diskTotal))").font(.ui(12.5)).foregroundStyle(Theme.text3)
                    }
                    SegmentedBar(segments: [(Double(used), Theme.load(m.diskUsedFraction)), (Double(purgeable), Theme.palette[7].opacity(0.7))],
                                 total: Double(max(1, m.diskTotal)), height: 10)
                    HStack(spacing: 16) {
                        LegendDot(color: Theme.load(m.diskUsedFraction), label: "Utilisé", value: Fmt.bytes(used))
                        if purgeable > 100_000_000 {
                            LegendDot(color: Theme.palette[7].opacity(0.7), label: "Purgeable", value: Fmt.bytes(purgeable))
                        }
                        LegendDot(color: Theme.track, label: "Libre", value: Fmt.bytes(m.diskFreeStrict))
                    }
                }
            }
        }
    }
}

// MARK: - Explorer

struct ExplorerTab: View {
    @Environment(AppModel.self) private var app
    @State private var hovered: UUID?
    @State private var confirm: StorageNode?
    @State private var asking = false

    var body: some View {
        let model = app.storage
        let _ = model.version
        VStack(alignment: .leading, spacing: 14) {
            if model.isScanning && model.root == nil {
                Card(padding: 22) {
                    HStack(spacing: 18) {
                        BusyMascot(.sorting, pixel: 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Je cartographie \(model.rootTitle.lowercased())…").font(.serif(20)).foregroundStyle(Theme.text)
                            Text("\(Fmt.int(model.scannedCount)) fichiers mesurés").font(.ui(12)).foregroundStyle(Theme.text2).monospacedDigit()
                            Text(FS.pretty(model.scanningPath)).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Annuler") { model.cancel() }.buttonStyle(SoftButtonStyle())
                    }
                }
            } else if let node = model.current {
                breadcrumb(node)
                HStack(alignment: .top, spacing: 14) {
                    Card(padding: 10) {
                        Treemap(node: node, hovered: $hovered) { model.open($0) }
                            .frame(height: 440)
                    }
                    .frame(maxWidth: .infinity)
                    Card(padding: 14) {
                        childList(node)
                    }
                    .frame(width: 340)
                }
                .fixedSize(horizontal: false, vertical: true)
                if model.unreadable > 0 {
                    Text((model.unreadable == 1 ? "Un dossier protégé par macOS n'a pas pu être lu."
                                                : "\(Fmt.int(model.unreadable)) dossiers protégés par macOS n'ont pas pu être lus.") +
                         (app.fullDiskAccess ? "" : " L'accès complet au disque permet de tout mesurer."))
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
            } else {
                Card(padding: 24) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Où est passé mon espace ?").font(.serif(24)).foregroundStyle(Theme.text)
                            Text("Lance l'analyse : chaque dossier devient un bloc de la taille de ce qu'il pèse.")
                                .font(.ui(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            Text("macOS peut te demander l'accès à Documents, Bureau ou Téléchargements.")
                                .font(.ui(11.5)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if Theme.icons != .hidden {
                            Image(systemName: "square.grid.3x3.square").font(.ui(60)).foregroundStyle(Theme.palette[1])
                        }
                    }
                }
            }
        }
        .alert("Mettre « \(confirm?.name ?? "") » à la Corbeille ?", isPresented: $asking) {
            Button("Mettre à la Corbeille", role: .destructive) { if let n = confirm { Task { await model.trash(n) } } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(Fmt.bytes(confirm?.size ?? 0)) · \(FS.pretty(confirm?.path ?? ""))\nTu pourras le récupérer depuis la Corbeille.")
        }
    }

    private func breadcrumb(_ node: StorageNode) -> some View {
        let model = app.storage
        return HStack(spacing: 4) {
            Button { model.goUp() } label: {
                Image(systemName: "chevron.left").font(.ui(11, .semibold)).frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.r(7)).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r(7)).strokeBorder(Theme.border, lineWidth: Theme.line))
            }
            .buttonStyle(.plain)
            .disabled(node.parent == nil)
            ScrollArea(axes: .horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(node.ancestors) { a in
                        Button { model.current = a; model.version += 1 } label: {
                            Text(a.name).font(.ui(12, a === node ? .semibold : .regular))
                                .foregroundStyle(a === node ? Theme.text : Theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if a !== node { Image(systemName: "chevron.right").font(.ui(9)).foregroundStyle(Theme.text3) }
                    }
                }
            }
            Spacer()
            Text("\(Fmt.bytes(node.size)) · \(Fmt.plural(node.files, "fichier", "fichiers"))")
                .font(.ui(12)).foregroundStyle(Theme.text2).monospacedDigit()
            if model.isScanning { BusyMascot(.sorting, pixel: 1) }
        }
    }

    private func childList(_ node: StorageNode) -> some View {
        let model = app.storage
        let list = Array(node.children.prefix(40))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Contenu").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            ScrollArea {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        Button { model.open(c) } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: Theme.r(3)).fill(Treemap.color(i)).frame(width: 8, height: 8)
                                Image(systemName: c.isDirectory ? "folder.fill" : "doc.fill").font(.ui(11)).foregroundStyle(Theme.text3)
                                Text(c.name).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(Fmt.bytes(c.size)).font(.ui(11.5)).foregroundStyle(Theme.text2).monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.r(7)).fill(hovered == c.id ? Theme.hover : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? c.id : nil }
                        .help("Clic droit : Finder, Claude ou Corbeille")
                        .contextMenu {
                            if c.isDirectory { Button("Ouvrir") { model.open(c) } }
                            Button("Afficher dans le Finder") { Finder.reveal(c.path) }
                            Button("Demander à Claude ce que c'est") {
                                app.assistant.explain(c.name, details: [
                                    "\(c.isDirectory ? "Dossier" : "Fichier") : \(FS.pretty(c.path))",
                                    "Taille : \(Fmt.bytes(c.size))\(c.isDirectory ? ", \(Fmt.plural(c.files, "fichier", "fichiers"))" : "")"
                                ])
                            }
                            Divider()
                            Button("Mettre à la Corbeille…") { confirm = c; asking = true }
                        }
                    }
                    if node.looseBytes > 0 {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: Theme.r(3)).fill(Theme.track).frame(width: 8, height: 8)
                            Text("Petits fichiers").font(.ui(12)).foregroundStyle(Theme.text3)
                            Spacer()
                            Text(Fmt.bytes(node.looseBytes)).font(.ui(11.5)).foregroundStyle(Theme.text3).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    if list.isEmpty && node.looseBytes == 0 {
                        EmptyHint(text: "Dossier vide")
                    }
                }
            }
            .frame(height: 418)
        }
    }
}

/// Squarified treemap of a folder's children.
struct Treemap: View {
    var node: StorageNode
    @Binding var hovered: UUID?
    var open: (StorageNode) -> Void

    static func color(_ i: Int) -> Color { Theme.color(index: i) }

    struct Cell: Identifiable {
        let id: UUID
        let name: String
        let size: Int64
        let node: StorageNode?
        let index: Int
        var rect: CGRect = .zero
    }

    var body: some View {
        GeometryReader { g in
            let cells = layout(in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(cells) { c in
                    cell(c)
                        .frame(width: max(0, c.rect.width - 3), height: max(0, c.rect.height - 3))
                        .offset(x: c.rect.minX, y: c.rect.minY)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ c: Cell) -> some View {
        let base = c.node == nil ? Theme.track : Self.color(c.index)
        let on = hovered == c.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.r(6), style: .continuous)
                .fill(base.opacity(on ? 0.95 : (c.node == nil ? 1 : 0.72)))
            if c.rect.width > 70 && c.rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.ui(11.5, .semibold)).lineLimit(1)
                    Text(Fmt.bytes(c.size)).font(.ui(10.5)).opacity(0.85)
                }
                .foregroundStyle(c.node == nil ? Theme.text2 : Theme.ink(on: base))
                .padding(7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
        .onTapGesture { if let n = c.node { open(n) } }
        .help("\(c.name) · \(Fmt.bytes(c.size))")
    }

    private func layout(in rect: CGRect) -> [Cell] {
        var cells: [Cell] = []
        let kids = node.children.filter { $0.size > 0 }
        let shown = Array(kids.prefix(36))
        for (i, k) in shown.enumerated() { cells.append(Cell(id: k.id, name: k.name, size: k.size, node: k, index: i)) }
        let rest = kids.dropFirst(36).reduce(0) { $0 + $1.size } + node.looseBytes
        if rest > 0 { cells.append(Cell(id: node.id, name: kids.count > 36 ? "Autres éléments" : "Petits fichiers", size: rest, node: nil, index: 0)) }
        let total = Double(cells.reduce(0) { $0 + $1.size })
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let area = Double(rect.width * rect.height)
        let values = cells.map { Double($0.size) / total * area }
        let rects = Self.squarify(values, in: rect)
        for i in cells.indices where i < rects.count { cells[i].rect = rects[i] }
        return cells
    }

    /// Bruls, Huizing & van Wijk's squarified layout. Values must be sorted and sum to the rect's area.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        var remaining = rect
        var i = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        while i < values.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [values[i]]
            var j = i + 1
            while j < values.count, worst(row + [values[j]], side) <= worst(row, side) {
                row.append(values[j])
                j += 1
            }
            let sum = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let w = CGFloat(sum / Double(max(remaining.height, 1)))
                var y = remaining.minY
                for v in row {
                    let h = CGFloat(v) / max(w, 0.0001)
                    out.append(CGRect(x: remaining.minX, y: y, width: w, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(sum / Double(max(remaining.width, 1)))
                var x = remaining.minX
                for v in row {
                    let w = CGFloat(v) / max(h, 0.0001)
                    out.append(CGRect(x: x, y: remaining.minY, width: w, height: h))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(0, remaining.height - h))
            }
            i = j
        }
        return out
    }
}

// MARK: - Big files

struct BigFilesTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.storage
        VStack(alignment: .leading, spacing: 14) {
            if model.root == nil {
                Card {
                    VStack(spacing: 12) {
                        EmptyHint(text: "Les gros fichiers sont repérés pendant l'analyse du stockage.", symbol: "doc.badge.ellipsis")
                        ScanButton(title: "Analyser mon dossier personnel", running: model.isScanning, activity: .sorting) { Task { await model.scan(FS.home) } }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 10) {
                    PillPicker(options: SizeFilter.all, selection: $model.sizeFilter, label: { $0.title })
                    PillPicker(options: AgeFilter.all, selection: $model.ageFilter, label: { $0.title })
                    Spacer()
                    BorderlessMenu {
                        Picker("Type", selection: $model.kindFilter) {
                            ForEach(FileKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.kindFilter.title, systemImage: model.kindFilter.symbol).font(.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                }
                let list = model.visibleBigFiles
                Card(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(list.prefix(150)) { f in
                            BigFileRow(file: f)
                        }
                        if list.isEmpty {
                            EmptyHint(text: "Aucun fichier ne correspond à ces filtres.")
                        } else if list.count > 150 {
                            Text("et \(list.count - 150) autres : affine les filtres").font(.ui(11)).foregroundStyle(Theme.text3).padding(8)
                        }
                    }
                }
            }
        }
    }
}

struct BigFileRow: View {
    @Environment(AppModel.self) private var app
    var file: BigFile

    var body: some View {
        let model = app.storage
        HoverRow {
            HStack(spacing: 10) {
                CheckBox(state: model.bigSelection.contains(file.id) ? .on : .off) {
                    if model.bigSelection.contains(file.id) { model.bigSelection.remove(file.id) } else { model.bigSelection.insert(file.id) }
                }
                FileIcon(path: file.path, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(FS.pretty(file.folder)).font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("Utilisé \(Fmt.relative(file.lastUse))").font(.ui(11)).foregroundStyle(Theme.text3).frame(width: 140, alignment: .trailing)
                Text(Fmt.bytes(file.size)).font(.ui(12, .medium)).foregroundStyle(Theme.text2).monospacedDigit().frame(width: 76, alignment: .trailing)
                Button { Finder.reveal(file.path) } label: {
                    Image(systemName: "magnifyingglass").font(.ui(11)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                .help("Afficher dans le Finder")
            }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.storage
        VStack(alignment: .leading, spacing: 14) {
            Panel(title: "Où chercher", subtitle: "Les fichiers de plus de 1 Mo au contenu identique",
                  symbol: "doc.on.doc", tint: Theme.palette[1]) {
                HStack(spacing: 8) {
                    Button("Ajouter un dossier…") { model.addDupRoot() }.buttonStyle(SoftButtonStyle(small: true))
                    if model.isFindingDups {
                        Button("Annuler") { model.cancelDuplicates() }.buttonStyle(SoftButtonStyle(small: true))
                    }
                    ScanButton(title: model.dupsScanned ? "Relancer" : "Chercher les doublons", symbol: "doc.on.doc", running: model.isFindingDups,
                               activity: .sorting) {
                        Task { await model.findDuplicates() }
                    }
                }
            } content: {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(model.dupRoots, id: \.self) { r in
                        HStack(spacing: 5) {
                            Image(systemName: "folder").font(.ui(10.5))
                            Text(FS.pretty(r)).font(.ui(11.5))
                            Button { model.dupRoots.removeAll { $0 == r } } label: {
                                Image(systemName: "xmark").font(.ui(8.5, .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(PillShape().fill(Theme.track))
                    }
                }
                if model.isFindingDups {
                    HStack(spacing: 12) {
                        BusyMascot(.sorting, pixel: 2)
                        Text(model.dupProgress).font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            if model.dupsScanned && !model.isFindingDups {
                if model.dupGroups.isEmpty {
                    Card { EmptyHint(text: "Aucun doublon dans ces dossiers. Impeccable.", symbol: "checkmark.seal") }
                } else {
                    HStack {
                        Text("\(Fmt.plural(model.dupGroups.count, "groupe", "groupes")) de fichiers identiques · \(Fmt.bytes(model.dupWasted)) en trop")
                            .font(.ui(12.5, .medium)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("Garder le plus ancien de chaque groupe") { model.autoSelectDuplicates() }
                            .buttonStyle(SoftButtonStyle(small: true))
                        Button("Tout décocher") { model.dupSelection = [] }
                            .buttonStyle(SoftButtonStyle(small: true))
                    }
                    ForEach(model.dupGroups.prefix(80)) { g in
                        DuplicateGroupCard(group: g)
                    }
                }
            }
        }
    }
}

struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var app
    var group: DuplicateGroup

    var body: some View {
        let model = app.storage
        let allChecked = group.paths.allSatisfy { model.dupSelection.contains($0) }
        Card(padding: 12) {
            HStack(spacing: 10) {
                FileIcon(path: group.paths[0], size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text((group.paths[0] as NSString).lastPathComponent).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(group.paths.count) copies de \(Fmt.bytes(group.size)) · \(Fmt.bytes(group.wasted)) récupérables")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if allChecked {
                    Label("Garde au moins une copie", systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(Theme.bad)
                }
            }
            VStack(spacing: 0) {
                ForEach(group.paths, id: \.self) { p in
                    HStack(spacing: 10) {
                        CheckBox(state: model.dupSelection.contains(p) ? .on : .off) {
                            if model.dupSelection.contains(p) { model.dupSelection.remove(p) } else { model.dupSelection.insert(p) }
                        }
                        Text(FS.pretty(p)).font(.ui(11.5)).foregroundStyle(model.dupSelection.contains(p) ? Theme.text3 : Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let m = FS.modified(p) { Text(Fmt.day(m)).font(.ui(10.5)).foregroundStyle(Theme.text3) }
                        Button { Finder.reveal(p) } label: { Image(systemName: "magnifyingglass").font(.ui(10.5)).foregroundStyle(Theme.text3) }
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4).padding(.leading, 36)
                }
            }
        }
    }
}

// MARK: - Bottom bars

struct StorageActionBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    var body: some View {
        let model = app.storage
        let isDup = model.tab == .duplicates
        let count = isDup ? model.dupSelection.count : model.bigSelection.count
        let size = isDup ? model.selectedDupSize : model.selectedBigSize
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.bytes(size)) sélectionnés").font(.serif(18)).foregroundStyle(Theme.text).monospacedDigit()
                Text(Fmt.plural(count, "fichier", "fichiers") + " · direction la Corbeille").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if isDup && model.dupSelectionUnsafe {
                Label("Un groupe perdrait toutes ses copies", systemImage: "exclamationmark.triangle").font(.ui(11.5)).foregroundStyle(Theme.bad)
            }
            Button("Tout décocher") { if isDup { model.dupSelection = [] } else { model.bigSelection = [] } }
                .buttonStyle(SoftButtonStyle())
            Button { confirm = true } label: {
                HStack(spacing: 6) {
                    if model.isRemoving { BusyMascot(.sweeping, pixel: 1, ink: Theme.onAccent) }
                    Text("Mettre à la Corbeille")
                }
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(count == 0 || model.isRemoving || (isDup && model.dupSelectionUnsafe))
        }
        .confirmAction("Mettre \(Fmt.plural(count, "fichier", "fichiers")) à la Corbeille ?",
                       message: "\(Fmt.bytes(size)). Tu pourras les récupérer tant que la Corbeille n'est pas vidée.",
                       button: "Mettre à la Corbeille", isPresented: $confirm) {
            Task { if isDup { await model.trashDuplicates() } else { await model.trashBigFiles() } }
        }
    }
}
