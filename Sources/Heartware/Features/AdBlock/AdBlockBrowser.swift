import SwiftUI
import AppKit

/// A Safari extension that blocks ads inside the pages: what the DNS cannot do (YouTube's video ads come from the very
/// servers of the videos, sponsored posts from the site itself).
struct AdBlockExtension: Equatable, Identifiable {
    var identifier: String
    var name: String
    /// The app that holds the extension (it opens Safari's settings on it).
    var appPath: String?
    /// Known to cut YouTube's video ads (with its permission on youtube.com).
    var youtube: Bool

    var id: String { identifier }
}

enum AdBlockBrowser {
    /// uBlock Origin Lite: free, open source, by the author of uBlock Origin; blocks YouTube's ads in Safari.
    static let recommendedName = "uBlock Origin Lite"
    static let recommendedStore = "macappstore://apps.apple.com/app/id6745342698"

    /// Names (or identifiers) of ad blockers, the ones known to handle YouTube marked.
    private static let known: [(key: String, youtube: Bool)] = [
        ("ublock", true), ("adguard", true), ("1blocker", true), ("vinegar", true), ("baking soda", true),
        ("wipr", false), ("adblock", false), ("ghostery", false), ("magic lasso", false), ("hush", false), ("stopthemadness", false)
    ]

    /// The ad blockers among Safari's extensions (`pluginkit`, read only: their state in Safari is Safari's own secret).
    static func installed() -> [AdBlockExtension] {
        guard !DemoData.isEnabled else { return demo }
        var out: [AdBlockExtension] = []
        for point in ["com.apple.Safari.web-extension", "com.apple.Safari.content-blocker"] {
            let r = Shell.run("/usr/bin/pluginkit", ["-mAvvv", "-p", point], timeout: 8)
            for e in parse(r.out) where !out.contains(where: { $0.identifier == e.identifier }) { out.append(e) }
        }
        return out
    }

    /// `pluginkit -mAvvv` blocks: "identifier(version)" then "Key = value" lines. Only the ad blockers are kept.
    static func parse(_ text: String) -> [AdBlockExtension] {
        var out: [AdBlockExtension] = []
        var current: (id: String, fields: [String: String])?
        func flush() {
            guard let c = current else { return }
            let name = c.fields["Parent Name"] ?? c.fields["Display Name"] ?? c.id
            let haystack = Fuzzy.fold(name + " " + c.id)
            if let match = known.first(where: { haystack.contains($0.key) }) {
                out.append(AdBlockExtension(identifier: c.id, name: name, appPath: c.fields["Parent Bundle"], youtube: match.youtube))
            }
            current = nil
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let eq = line.range(of: " = ") {
                current?.fields[String(line[..<eq.lowerBound])] = String(line[eq.upperBound...])
                continue
            }
            // A leading "+", "-", "!" or "=" (then spaces) is pluginkit's election mark, not part of the identifier.
            var head = line
            if let mark = head.first, "+-!=".contains(mark) { head = head.dropFirst().trimmingCharacters(in: .whitespaces) }
            if let paren = head.firstIndex(of: "("), head.hasSuffix(")"), !head.contains(" ") {
                flush()
                current = (String(head[..<paren]), [:])
            }
        }
        flush()
        return out
    }

    static let demo = [AdBlockExtension(identifier: "net.raymondhill.uBlock-Origin-Lite.Extension", name: "uBlock Origin Lite",
                                        appPath: "/Applications/uBlock Origin Lite.app", youtube: true)]
}

/// YouTube's ads in Safari: the extension to install, or the one found. Safari's three switches wait in the « ? ».
struct AdBlockYouTubePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        let found = m.browserExtensions ?? []
        let youtube = found.first(where: \.youtube)
        Panel(title: "Pubs YouTube dans Safari", subtitle: "Une extension de Safari les coupe, sans passer par le lecteur",
              symbol: "play.rectangle", tint: AdBlockStyle.tint) {
            HelpTipButton(tip: AdBlockTips.safariExtension(youtube?.name ?? AdBlockBrowser.recommendedName), opensByItself: false)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if let ext = youtube {
                    HStack(spacing: 8) {
                        if let path = ext.appPath { FileIcon(path: path, size: 22) }
                        Text("\(ext.name) est installé").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Tag(text: "Gratuit", tint: Theme.good, filled: true)
                    }
                    HStack(spacing: 10) {
                        Button("Ouvrir Safari") { m.openSafari() }
                            .buttonStyle(SoftButtonStyle(small: true))
                        if ext.appPath != nil {
                            Button("Ouvrir \(ext.name)") { m.openExtensionApp(ext) }
                                .buttonStyle(SoftButtonStyle(small: true))
                                .help("Son app ouvre les réglages de Safari sur l'extension")
                        }
                    }
                } else {
                    Text(found.isEmpty
                         ? "Aucune extension anti-pub dans Safari."
                         : "\(found.map(\.name).joined(separator: ", ")) laisse passer celles de YouTube.")
                        .font(.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Button("Installer \(AdBlockBrowser.recommendedName)") { m.openRecommendedStore() }
                        .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                        .help("Gratuit et open source, par l'auteur de uBlock Origin, sur l'App Store")
                }
            }
        }
    }
}
