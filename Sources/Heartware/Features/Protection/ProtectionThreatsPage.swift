import SwiftUI

struct ThreatsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        VStack(alignment: .leading, spacing: 14) {
            if model.isScanning {
                ThreatScanProgress()
            } else {
                TileRow {
                    ThreatScanChoice()
                    FileCheckDrop()
                        .frame(width: 330)
                }
            }
            FileCheckVerdict()
            if let m = model.threatMessage {
                Callout(symbol: m.ok ? "checkmark.shield" : "exclamationmark.triangle", title: m.ok ? "C'est fait" : "Pas tout à fait",
                        text: m.text, tint: m.ok ? Theme.good : Theme.warn)
            }
            let list = model.visibleThreats
            if !list.isEmpty {
                let bad = list.filter { $0.status == .bad }
                if !bad.isEmpty {
                    Panel(title: Fmt.plural(bad.count, "menace", "menaces"),
                          subtitle: "Coche-les : je les arrête, puis je les mets à la Corbeille.",
                          symbol: "exclamationmark.octagon", tint: Theme.bad) {
                        VStack(spacing: 2) { ForEach(bad) { ThreatRow(threat: $0) } }
                    }
                }
                let look = list.filter { $0.status != .bad }
                if !look.isEmpty {
                    Panel(title: "À examiner", subtitle: "Pas forcément dangereux, mais inhabituel.",
                          symbol: "exclamationmark.triangle", tint: Theme.warn) {
                        VStack(spacing: 2) { ForEach(look) { ThreatRow(threat: $0) } }
                    }
                }
            } else if let s = model.scanSummary, !model.isScanning {
                Card(padding: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        IconBadge(symbol: "checkmark.shield.fill", tint: Theme.good, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aucune menace trouvée").font(.serif(20)).foregroundStyle(Theme.text)
                            Text("\(Fmt.int(s.files)) fichiers analysés \(Fmt.relative(s.date)), analyse \(s.deep ? "complète" : "rapide"), signatures XProtect \(s.signaturesVersion).")
                                .font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !model.ignored.isEmpty {
                HStack {
                    Text("\(Fmt.plural(model.ignored.count, "élément ignoré", "éléments ignorés")) à ta demande.").font(.ui(11.5)).foregroundStyle(Theme.text3)
                    Button("Les montrer à nouveau") { model.restoreIgnored() }.buttonStyle(SoftButtonStyle(small: true))
                }
            }
        }
    }
}

struct ThreatScanChoice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        let sig = ProtectionSignatures.newest()
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rechercher les logiciels malveillants").font(.serif(20)).foregroundStyle(Theme.text)
                Text(model.scanSummary.map { "Dernière analyse \(Fmt.relative($0.date)) : \(Fmt.int($0.files)) fichiers, \($0.threats == 0 ? "rien trouvé" : Fmt.plural($0.threats, "menace", "menaces"))." }
                     ?? "Jamais lancée sur ce Mac.")
                    .font(.ui(12)).foregroundStyle(Theme.text2)
                Text(sig.map { s in "Signatures XProtect \(s.version)" + (s.date.map { ", mises à jour par Apple \(Fmt.relative($0))" } ?? "") + "." }
                     ?? "Signatures XProtect introuvables.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Analyse rapide") { Task { await model.scan(deep: false) } }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .help("Ce qui démarre tout seul, ce qui tourne, tes apps, Téléchargements, le Bureau et les cachettes habituelles : moins d'une minute.")
                Button("Analyse complète") { Task { await model.scan(deep: true) } }
                    .buttonStyle(SoftButtonStyle())
                    .help("Tous les programmes, scripts et installeurs du Mac, jusqu'au fond de ton dossier personnel : quelques minutes.")
            }
        }
    }
}

/// Drop a download (an app, an installer, a script) to check it before opening it.
struct FileCheckDrop: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        DropZone(title: "Vérifier avant d'ouvrir", subtitle: "Glisse ici une app, un installeur ou un script",
                 symbol: "checkmark.shield", allowsFolders: true) { urls in
            Task { await model.inspect(urls) }
        }
        .help("Je passe son code aux signatures d'Apple, je regarde qui l'a signé, s'il est notarisé et d'où il vient. Rien n'est ouvert ni envoyé.")
    }
}

/// What the check of a dropped file found (nothing until a file is dropped).
struct FileCheckVerdict: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        if model.isInspecting {
            Card(padding: 16) {
                HStack(spacing: 10) {
                    BusyMascot(.inspecting, pixel: 1.5)
                    Text("J'examine son code avec les signatures d'Apple…").font(.ui(12.5)).foregroundStyle(Theme.text2)
                }
            }
        } else if let v = model.verdict {
            Card(padding: 16) {
                HStack(alignment: .top, spacing: 12) {
                    if v.path.hasSuffix(".app") { FileIcon(path: v.path, size: 36) } else { IconBadge(symbol: "doc", tint: v.status.color, size: 36) }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(v.name).font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            StatusBadge(status: v.status, text: v.status == .ok ? "Rien à signaler" : nil)
                        }
                        Text(v.title).font(.ui(12.5, .medium)).foregroundStyle(v.status == .ok ? Theme.text : v.status.color)
                        Text(v.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct ThreatScanProgress: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.protection
        Card(padding: 22) {
            HStack(spacing: 18) {
                BusyMascot(.inspecting, pixel: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.scanTotal > 0 ? "\(model.scanPhase) \(Fmt.int(model.scanDone)) sur \(Fmt.int(model.scanTotal)) fichiers…" : model.scanPhase)
                        .font(.serif(20)).foregroundStyle(Theme.text)
                    Text(model.scanCurrent.isEmpty ? " " : FS.pretty(model.scanCurrent))
                        .font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    if model.scanTotal > 0 {
                        UsageBar(fraction: Double(model.scanDone) / Double(max(1, model.scanTotal)), tint: Theme.accent, height: 6)
                    } else {
                        ScanIndeterminateBar()
                    }
                }
                Button("Annuler") { model.cancelScan() }.buttonStyle(SoftButtonStyle())
            }
        }
    }
}

struct ThreatRow: View {
    @Environment(AppModel.self) private var app
    var threat: ProtectionThreat
    @State private var confirm = false

    var body: some View {
        let model = app.protection
        HoverRow {
            HStack(alignment: .top, spacing: 12) {
                CheckBox(state: model.threatSelection.contains(threat.id) ? .on : .off, disabled: threat.removable.isEmpty) { model.toggle(threat) }
                    .padding(.top, 4)
                if threat.path.hasSuffix(".app") {
                    FileIcon(path: threat.path, size: 28)
                } else {
                    IconBadge(symbol: threat.kind.symbol, tint: threat.status.color, size: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(threat.name).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Tag(text: threat.title, symbol: threat.kind.symbol, tint: threat.status.color, filled: true)
                    }
                    Text(threat.detail).font(.ui(11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Text(FS.pretty(threat.path)).font(.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    let linked = threat.removable.dropFirst().map { ($0 as NSString).lastPathComponent }
                        + threat.services.map { "service " + ($0.split(separator: "/").last.map(String.init) ?? $0) }
                    if !linked.isEmpty {
                        Text("Avec : " + linked.joined(separator: ", "))
                            .font(.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if model.removing.contains(threat.id) {
                    BusyMascot(.sweeping, pixel: 1)
                } else {
                    BorderlessMenu(indicator: false) {
                        if !threat.removable.isEmpty {
                            Button("Arrêter et mettre à la Corbeille…") { confirm = true }
                        }
                        if FS.exists(threat.path) { Button("Afficher dans le Finder") { Finder.reveal(threat.path) } }
                        Button("Demander à Claude ce que c'est") {
                            app.assistant.explain(threat.name, details: [threat.title, threat.detail, "Emplacement : \(FS.pretty(threat.path))"])
                        }
                        Divider()
                        Button("Ignorer : je sais ce que c'est") { model.ignore(threat) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.ui(14)).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
        .confirmAction("Neutraliser « \(threat.name) » ?",
                       message: ThreatActionBar.message(for: [threat]), button: "Mettre à la Corbeille", isPresented: $confirm) {
            Task { await model.remove([threat]) }
        }
    }
}

struct ThreatActionBar: View {
    @Environment(AppModel.self) private var app
    @State private var confirm = false

    static func message(for list: [ProtectionThreat]) -> String {
        let files = list.flatMap(\.removable)
        let services = list.flatMap(\.services)
        var text = files.prefix(8).map { "• " + FS.pretty($0) }.joined(separator: "\n")
        if files.count > 8 { text += "\n• et \(files.count - 8) autres" }
        text += "\n\n" + (services.isEmpty ? "" : "\(Fmt.plural(services.count, "service est arrêté", "services sont arrêtés")), puis ")
            + (services.isEmpty ? "L" : "l") + "es programmes lancés depuis ces fichiers sont fermés."
        text += "\n\nTout va dans la Corbeille : tu peux le remettre en place tant que tu ne l'as pas vidée. Un élément du système demande ton mot de passe d'administrateur."
        return text
    }

    var body: some View {
        let model = app.protection
        let selected = model.selectedThreats
        ActionBar {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.plural(selected.count, "menace sélectionnée", "menaces sélectionnées"))
                    .font(.serif(18)).foregroundStyle(Theme.text)
                Text("Arrêtées, puis mises à la Corbeille.").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button {
                confirm = true
            } label: {
                HStack(spacing: 6) {
                    if !model.removing.isEmpty { BusyMascot(.sweeping, pixel: 1, ink: Theme.onBad) }
                    Text("Neutraliser")
                }
            }
            .buttonStyle(SoftButtonStyle(destructive: true))
            .disabled(selected.isEmpty || !model.removing.isEmpty)
        }
        .confirmAction("Neutraliser \(Fmt.plural(selected.count, "menace", "menaces")) ?", message: Self.message(for: selected),
                       button: "Mettre à la Corbeille", isPresented: $confirm) {
            Task { await model.remove(selected) }
        }
    }
}
