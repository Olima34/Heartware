import Foundation

// The four sources of updates, as pure functions (parsers, version rules) and background checks.
// Nothing here installs anything: Homebrew upgrades go through `UpdatesModel`, apps update themselves.

struct UpdatesFailure: Error, Equatable {
    let message: String
}

// MARK: - Versions

/// Compares version strings the way Sparkle's `SUStandardVersionComparator` does: split in runs of digits,
/// letters and separators, numbers compared as numbers ("1.10" > "1.9"), letters as text, a version with an extra
/// letter part older than without ("1.0b1" < "1.0"). One addition: trailing zeros are equal ("1.0" == "1.0.0"),
/// so an app is never told it is late because of a different way of writing the same version.
enum UpdatesVersion {
    enum Kind { case number, string, separator }

    static func kind(_ c: Character) -> Kind {
        if c == "." || c.isWhitespace || c.isPunctuation { return .separator }
        if c.isASCII && c.isNumber { return .number }
        return .string
    }

    static func parts(_ version: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentKind: Kind?
        for c in version.trimmingCharacters(in: .whitespacesAndNewlines) {
            let k = kind(c)
            if let ck = currentKind, ck == k, k != .separator {
                current.append(c)
            } else {
                if !current.isEmpty { out.append(current) }
                current = String(c)
                currentKind = k
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parts(a), pb = parts(b)
        let n = min(pa.count, pb.count)
        for i in 0..<n {
            let ka = kind(pa[i].first!), kb = kind(pb[i].first!)
            if ka == kb {
                if ka == .number {
                    let r = compareNumbers(pa[i], pb[i])
                    if r != .orderedSame { return r }
                } else if ka == .string {
                    let r = pa[i].compare(pb[i])
                    if r != .orderedSame { return r }
                }
            } else if ka != .string && kb == .string {
                return .orderedDescending
            } else if ka == .string && kb != .string {
                return .orderedAscending
            } else {
                // A number against a separator: the number wins.
                return ka == .number ? .orderedDescending : .orderedAscending
            }
        }
        guard pa.count != pb.count else { return .orderedSame }
        let longerIsA = pa.count > pb.count
        let rest = (longerIsA ? pa : pb)[n...]
        // The first part that counts (neither a separator nor zeros) decides: letters mean a pre-release
        // ("1.0b1", "1.0.0b1" and "1.0-beta" < "1.0"), a number a later version ("1.0.1" > "1.0"); none, the same version.
        guard let first = rest.first(where: { kind($0.first!) != .separator && !$0.allSatisfy { $0 == "0" } }) else {
            return .orderedSame
        }
        let shorterWins = kind(first.first!) == .string
        return longerIsA == shorterWins ? .orderedAscending : .orderedDescending
    }

    /// Digits of any length, compared as numbers.
    private static func compareNumbers(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.drop { $0 == "0" }, y = b.drop { $0 == "0" }
        if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - Homebrew

struct UpdatesBrewPackage: Identifiable, Hashable {
    var id: String { (isCask ? "cask:" : "formula:") + name }
    let name: String
    let installed: String
    let current: String
    let isCask: Bool
    var pinned = false
    /// The cask runs a .pkg installer: macOS asks for the administrator password, which only a Terminal can type.
    var needsPassword = false
    /// The app updates itself (listed only with "--greedy").
    var autoUpdates = false

    /// What to type in the Terminal to update it by hand.
    var command: String { "brew upgrade " + (isCask ? "--cask " : "") + name }
}

enum UpdatesBrew {
    /// Child processes never update Homebrew on their own (the "brew update" button does) and print no colors.
    static let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]

    /// What `sudo` says when Homebrew needs the password and there is no Terminal to type it in.
    static func askedForPassword(_ lines: [String]) -> Bool {
        lines.contains { $0.hasPrefix("sudo:") && ($0.contains("terminal is required") || $0.contains("password is required")) }
    }

    /// `brew outdated --json=v2` → packages (nil when the text is not that JSON).
    static func parseOutdated(_ data: Data) -> [UpdatesBrewPackage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func versions(_ v: Any?) -> String {
            if let a = v as? [String] { return a.last ?? "?" }
            return v as? String ?? "?"
        }
        var out: [UpdatesBrewPackage] = []
        for (key, isCask) in [("formulae", false), ("casks", true)] {
            for f in root[key] as? [[String: Any]] ?? [] {
                guard let name = f["name"] as? String else { continue }
                out.append(UpdatesBrewPackage(name: name, installed: versions(f["installed_versions"]),
                                              current: versions(f["current_version"]), isCask: isCask,
                                              pinned: f["pinned"] as? Bool ?? false))
            }
        }
        return out
    }

    /// `brew info --cask --json=v2 …` → the casks that need a password (a .pkg to install, receipts to remove)
    /// and those that update themselves.
    static func parseCaskInfo(_ data: Data) -> (password: Set<String>, autoUpdates: Set<String>) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        var password = Set<String>(), auto = Set<String>()
        for c in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = c["token"] as? String else { continue }
            if c["auto_updates"] as? Bool == true { auto.insert(token) }
            for artifact in c["artifacts"] as? [[String: Any]] ?? [] {
                if artifact["pkg"] != nil || artifact["installer"] != nil { password.insert(token) }
                for step in artifact["uninstall"] as? [[String: Any]] ?? [] where step["pkgutil"] != nil || step["kext"] != nil {
                    password.insert(token)
                }
            }
        }
        return (password, auto)
    }

    /// Reads what is late. Runs `brew` twice (outdated, then info on the casks): call it off the main thread.
    static func outdated(brew: String, greedy: Bool) -> Result<[UpdatesBrewPackage], UpdatesFailure> {
        let r = Shell.run(brew, ["outdated", "--json=v2"] + (greedy ? ["--greedy"] : []), env: environment, timeout: 180)
        guard var list = parseOutdated(Data(r.out.utf8)) else {
            let reason = r.err.split(separator: "\n").last.map(String.init) ?? "réponse illisible"
            return .failure(UpdatesFailure(message: "brew outdated a échoué : \(reason)"))
        }
        let casks = list.filter(\.isCask).map(\.name)
        if !casks.isEmpty {
            let info = Shell.run(brew, ["info", "--cask", "--json=v2"] + casks, env: environment, timeout: 60)
            let flags = parseCaskInfo(Data(info.out.utf8))
            for i in list.indices where list[i].isCask {
                list[i].needsPassword = flags.password.contains(list[i].name)
                list[i].autoUpdates = flags.autoUpdates.contains(list[i].name)
            }
        }
        return .success(list.sorted { ($0.isCask ? 1 : 0, $0.name) < ($1.isCask ? 1 : 0, $1.name) })
    }

    /// The commands of "Tout mettre à jour": what is listed, minus pins and casks that need a password.
    static func upgradeAllSteps(_ packages: [UpdatesBrewPackage], greedy: Bool) -> [[String]] {
        let formulae = packages.filter { !$0.isCask && !$0.pinned }.map(\.name)
        let casks = packages.filter { $0.isCask && !$0.needsPassword }.map(\.name)
        var steps: [[String]] = []
        if !formulae.isEmpty { steps.append(["upgrade", "--formula"] + formulae) }
        if !casks.isEmpty { steps.append(["upgrade", "--cask"] + (greedy ? ["--greedy"] : []) + casks) }
        return steps
    }

    /// One line of live output, without progress bar redraws or terminal colors.
    static func clean(_ line: String) -> String {
        var s = line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Apps (Sparkle and App Store)

/// An app found in /Applications that one of the sources knows how to check.
struct UpdatesApp: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    /// CFBundleShortVersionString (shown), else CFBundleVersion.
    let version: String
    /// CFBundleVersion, what Sparkle compares.
    let build: String?
    /// SUFeedURL (Sparkle apps only).
    var feedURL: String? = nil
    var result: UpdatesResult = .unchecked
}

enum UpdatesResult: Equatable {
    case unchecked
    case upToDate(latest: String?)
    case available(UpdatesRelease)
    /// Checked, but the answer cannot be compared (an App Store listing for iPhone and iPad only).
    case unknown(String, link: String?)
    case failed(String)

    var release: UpdatesRelease? {
        if case .available(let r) = self { return r }
        return nil
    }
}

struct UpdatesRelease: Equatable {
    var version: String
    /// The installed version as it should be shown next to `version` (with the build when both read the same).
    var installed: String? = nil
    var notesURL: String? = nil
    /// The App Store page (macappstore://…).
    var storeURL: String? = nil
    var notes: String? = nil
    var date: Date? = nil
}

enum UpdatesInventory {
    /// Apps with a Sparkle feed, apps from the App Store, and apps that embed Sparkle without a public feed.
    /// Only reads Info.plist files on this Mac: no network.
    static func scan() -> (sparkle: [UpdatesApp], store: [UpdatesApp], sparkleWithoutFeed: Int) {
        if DemoData.isEnabled { return ([], [], 0) }
        var sparkle: [UpdatesApp] = [], store: [UpdatesApp] = []
        var withoutFeed = 0
        for path in AppInventory.bundlePaths() {
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { continue }
            let short = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
            let build = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
            guard let version = short ?? build, !version.isEmpty else { continue }
            let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let app = UpdatesApp(path: path, name: name, bundleID: info["CFBundleIdentifier"] as? String,
                                 version: version, build: build)
            if FS.exists(path + "/Contents/_MASReceipt/receipt") {
                if app.bundleID != nil { store.append(app) }
            } else if let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces), !feed.isEmpty {
                var a = app
                a.feedURL = feed
                sparkle.append(a)
            } else if FS.exists(path + "/Contents/Frameworks/Sparkle.framework") {
                withoutFeed += 1
            }
        }
        let byName: (UpdatesApp, UpdatesApp) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (sparkle.sorted(by: byName), store.sorted(by: byName), withoutFeed)
    }
}

// MARK: - Sparkle feeds

struct UpdatesFeedItem: Equatable {
    var title: String?
    var version: String?
    var shortVersion: String?
    var channel: String?
    var minimumSystemVersion: String?
    var maximumSystemVersion: String?
    var hardwareRequirements: String?
    var releaseNotesLink: String?
    var link: String?
    var description: String?
    var pubDate: Date?
    var os: String?
    var hasEnclosure = false

    /// What Sparkle compares to CFBundleVersion.
    var comparable: String? { version ?? shortVersion }
    var display: String { shortVersion ?? version ?? title ?? "?" }
}

enum UpdatesSparkle {
    /// Reads an appcast: `<item>`s with `sparkle:version` as an attribute of `<enclosure>` (Sparkle 1)
    /// or as an element (Sparkle 2). Delta updates inside `<sparkle:deltas>` are skipped.
    static func parse(_ data: Data) -> [UpdatesFeedItem]? {
        let delegate = UpdatesFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.items.isEmpty else { return nil }
        return delegate.sawRSS ? delegate.items : nil
    }

    /// The newest item this Mac may install: no beta channel, a macOS download, a system recent enough.
    static func best(_ items: [UpdatesFeedItem], os: String, arm: Bool = UpdatesSparkle.isAppleSilicon) -> UpdatesFeedItem? {
        items.filter { item in
            guard item.comparable != nil else { return false }
            if let c = item.channel, !c.isEmpty { return false }
            if let o = item.os, !o.isEmpty, !o.lowercased().hasPrefix("macos") { return false }
            if let min = item.minimumSystemVersion, !min.isEmpty, UpdatesVersion.compare(min, os) == .orderedDescending { return false }
            if let max = item.maximumSystemVersion, !max.isEmpty, UpdatesVersion.compare(max, os) == .orderedAscending { return false }
            if let hw = item.hardwareRequirements, hw.contains("arm64"), !arm { return false }
            return true
        }
        .max { UpdatesVersion.compare($0.comparable!, $1.comparable!) == .orderedAscending }
    }

    static let isAppleSilicon: Bool = {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }()

    /// What the app should be told, given the newest item of its feed.
    static func result(for app: UpdatesApp, best: UpdatesFeedItem?) -> UpdatesResult {
        guard let item = best else { return .upToDate(latest: nil) }
        let newer: Bool
        if let v = item.version, let build = app.build {
            newer = UpdatesVersion.isNewer(v, than: build)
        } else {
            newer = UpdatesVersion.isNewer(item.shortVersion ?? item.version ?? "", than: app.version)
        }
        guard newer else { return .upToDate(latest: item.display) }
        let links = [item.releaseNotesLink, item.link].compactMap { $0 }.filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
        // Same version number, newer build ("1.6.0 (6413) → 1.6.0 (6575)").
        let sameLabel = item.display == app.version && item.version != nil
        return .available(UpdatesRelease(version: sameLabel ? "\(item.display) (\(item.version!))" : item.display,
                                         installed: sameLabel ? "\(app.version) (\(app.build ?? "?"))" : nil,
                                         notesURL: links.first,
                                         notes: item.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 },
                                         date: item.pubDate))
    }

    /// Downloads and reads one feed. HTTPS only: an "http://" feed is tried over HTTPS.
    static func check(_ app: UpdatesApp, os: String) async -> UpdatesResult {
        guard var text = app.feedURL else { return .failed("Pas de flux") }
        if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else {
            return .failed("Adresse de flux illisible")
        }
        do {
            let (data, _) = try await HTTP.get(url, headers: ["Accept": "application/rss+xml, application/xml, text/xml"])
            guard let items = parse(data) else { return .failed("Flux illisible") }
            return result(for: app, best: best(items, os: os))
        } catch {
            let insecure = app.feedURL?.lowercased().hasPrefix("http://") ?? false
            return .failed(insecure ? "Flux en HTTP seulement (non vérifié)" : "Flux injoignable")
        }
    }

    /// Release notes are HTML: keeps the text, on one line.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.count > 240 ? String(s.prefix(240)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMMM yyyy H:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                                      "EEE, d MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"]

    static func date(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }
}

/// SAX reader of an appcast. Names are qualified ("sparkle:version"): any namespace prefix is accepted.
private final class UpdatesFeedParser: NSObject, XMLParserDelegate {
    var items: [UpdatesFeedItem] = []
    var sawRSS = false
    private var stack: [String] = []
    private var item: UpdatesFeedItem?
    private var text = ""
    private var notesLang: String?
    private var notesScore = -1

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "rss" || name == "channel" { sawRSS = true }
        let parent = stack.last
        stack.append(name)
        text = ""
        if name == "item" {
            item = UpdatesFeedItem()
            notesScore = -1
            return
        }
        guard item != nil, parent == "item" else { return }
        if name == "enclosure" {
            item?.hasEnclosure = true
            for (key, value) in attributes {
                switch Self.local(key) {
                case "version": if item?.version == nil { item?.version = value }
                case "shortVersionString": if item?.shortVersion == nil { item?.shortVersion = value }
                case "os": item?.os = value
                default: break
                }
            }
        } else if Self.local(name) == "releaseNotesLink" || Self.local(name) == "fullReleaseNotesLink" {
            notesLang = attributes.first { Self.local($0.key) == "lang" }?.value.lowercased()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        if name == "item" {
            if let item { items.append(item) }
            item = nil
            return
        }
        guard item != nil, stack.last == "item" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let prefixed = name.contains(":")
        switch (prefixed, Self.local(name)) {
        case (false, "title"): item?.title = value
        case (false, "link"): item?.link = value
        case (false, "description"): item?.description = value
        case (false, "pubDate"): item?.pubDate = UpdatesSparkle.date(value)
        case (true, "version"): item?.version = value
        case (true, "shortVersionString"): item?.shortVersion = value
        case (true, "channel"): item?.channel = value
        case (true, "minimumSystemVersion"): item?.minimumSystemVersion = value
        case (true, "maximumSystemVersion"): item?.maximumSystemVersion = value
        case (true, "hardwareRequirements"): item?.hardwareRequirements = value
        case (true, "releaseNotesLink"), (true, "fullReleaseNotesLink"):
            // French notes first, then notes without a language; the short notes before the full history.
            let score = (notesLang?.hasPrefix("fr") == true ? 4 : (notesLang == nil ? 2 : 0)) + (Self.local(name) == "releaseNotesLink" ? 1 : 0)
            if score > notesScore {
                item?.releaseNotesLink = value
                notesScore = score
            }
        default: break
        }
    }
}

// MARK: - App Store

enum UpdatesAppStore {
    struct Info: Equatable {
        var version: String
        var trackID: Int
        /// A Mac listing. Universal purchases are listed as iPhone and iPad apps: their version is not the Mac one.
        var isMac = true
        var notes: String?
        var date: Date?
    }

    /// `https://itunes.apple.com/lookup?bundleId=…` → the version on sale (nil when the app is not listed).
    static func parseLookup(_ data: Data) -> Info? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first(where: { $0["kind"] as? String == "mac-software" }) ?? results.first,
              let version = first["version"] as? String,
              let id = first["trackId"] as? Int else { return nil }
        let date = (first["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let notes = (first["releaseNotes"] as? String).map { UpdatesSparkle.plainText($0) }
        return Info(version: version, trackID: id, isMac: (first["kind"] as? String ?? "mac-software") == "mac-software",
                    notes: notes?.isEmpty == true ? nil : notes, date: date)
    }

    static func storeURL(_ trackID: Int) -> String { "macappstore://apps.apple.com/app/id\(trackID)" }

    static func lookupURL(_ bundleID: String) -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "country", value: "fr"),
                         URLQueryItem(name: "entity", value: "macSoftware")]
        return c?.url
    }

    static func result(for app: UpdatesApp, info: Info?) -> UpdatesResult {
        guard let info else { return .failed("Introuvable sur l'App Store français") }
        if !info.isMac {
            // Universal purchase: the listing shows the iPhone version. It only says something about the Mac app
            // when both follow the same numbering (same major version, like WhatsApp), not when they differ (Canva 1.x / 4.x).
            let major: (String) -> String? = { UpdatesVersion.parts($0).first }
            guard UpdatesVersion.compare(info.version, app.version) == .orderedSame || major(info.version) == major(app.version) else {
                return .unknown("Achat universel : l'App Store n'indique que la version iPhone et iPad", link: storeURL(info.trackID))
            }
        }
        guard UpdatesVersion.isNewer(info.version, than: app.version) else { return .upToDate(latest: info.version) }
        return .available(UpdatesRelease(version: info.version, storeURL: storeURL(info.trackID), notes: info.notes, date: info.date))
    }

    static func check(_ app: UpdatesApp) async -> UpdatesResult {
        guard let id = app.bundleID, let url = lookupURL(id) else { return .failed("Identifiant inconnu") }
        do {
            let (data, _) = try await HTTP.get(url)
            return result(for: app, info: parseLookup(data))
        } catch {
            return .failed("App Store injoignable")
        }
    }
}

// MARK: - Live output

/// Collects lines written by a background process and hands them to the main thread at most 4 times a second.
final class UpdatesLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var scheduled = false
    private let deliver: @MainActor ([String]) -> Void

    init(deliver: @escaping @MainActor ([String]) -> Void) {
        self.deliver = deliver
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                MainActor.assumeIsolated { flush() }
            }
        }
    }

    @MainActor
    func flush() {
        lock.lock()
        let out = lines
        lines = []
        scheduled = false
        lock.unlock()
        if !out.isEmpty { deliver(out) }
    }
}
