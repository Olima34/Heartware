import SwiftUI
import AppKit
import IOKit.pwr_mgt
import UniformTypeIdentifiers

enum ToolboxTab: String, CaseIterable, Identifiable {
    case colors, passwords, hashes, text, time, caffeine, cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colors: return "Couleurs"
        case .passwords: return "Mots de passe"
        case .hashes: return "Empreintes"
        case .text: return "Texte"
        case .time: return "Dates et UUID"
        case .caffeine: return "Caféine"
        case .cursor: return "Curseur"
        }
    }
}

/// What the toolbox keeps between launches.
struct ToolboxSettings: Codable {
    var colors: [ToolboxRGB] = []
    var password = ToolboxPasswordOptions()
    var passphrase = ToolboxPassphraseOptions()
    /// Generated passwords leave the clipboard after 90 s (if nothing else was copied since).
    var clearSecrets = true
    var caffeineDisplay = true
    /// Last duration chosen, in minutes; 0 means "until I stop it".
    var caffeineMinutes = 60
    var uuidLowercase = false
}

/// The text transformations of the "Texte" tab.
enum ToolboxTextOp: Hashable, Identifiable {
    case base64Encode, base64Decode, urlEncode, urlDecode, jsonPretty, jsonCompact
    case textCase(ToolboxCase)

    static let encoders: [ToolboxTextOp] = [.base64Encode, .base64Decode, .urlEncode, .urlDecode]
    static let json: [ToolboxTextOp] = [.jsonPretty, .jsonCompact]
    static let cases: [ToolboxTextOp] = ToolboxCase.allCases.map { .textCase($0) }

    var id: String {
        if case .textCase(let c) = self { return "case_" + c.rawValue }
        return "\(self)"
    }

    var title: String {
        switch self {
        case .base64Encode: return "Base64 →"
        case .base64Decode: return "← Base64"
        case .urlEncode: return "URL →"
        case .urlDecode: return "← URL"
        case .jsonPretty: return "Formater"
        case .jsonCompact: return "Compacter"
        case .textCase(let c): return c.title
        }
    }

    var help: String {
        switch self {
        case .base64Encode: return "Encode le texte en Base64"
        case .base64Decode: return "Décode du Base64 (variante URL acceptée)"
        case .urlEncode: return "Encode pour une adresse web (%20…)"
        case .urlDecode: return "Décode les %XX d'une adresse web"
        case .jsonPretty: return "Valide et indente le JSON, sans changer l'ordre des clés"
        case .jsonCompact: return "Valide et retire les espaces du JSON"
        case .textCase: return "Change la casse"
        }
    }

    func apply(_ input: String) -> Result<String, ToolboxTextFailure> {
        guard !input.isEmpty else { return .success("") }
        switch self {
        case .base64Encode: return .success(ToolboxText.base64Encode(input))
        case .base64Decode:
            if let s = ToolboxText.base64Decode(input) { return .success(s) }
            if let d = ToolboxText.base64Data(input) {
                return .failure(ToolboxTextFailure(message: "Décodé en \(Fmt.bytes(d.count)) de données binaires : ce n'est pas du texte."))
            }
            return .failure(ToolboxTextFailure(message: "Ce n'est pas du Base64 valide."))
        case .urlEncode: return .success(ToolboxText.urlEncode(input))
        case .urlDecode:
            if let s = ToolboxText.urlDecode(input) { return .success(s) }
            return .failure(ToolboxTextFailure(message: "Séquence %XX invalide."))
        case .jsonPretty, .jsonCompact:
            switch ToolboxText.json(input, pretty: self == .jsonPretty) {
            case .success(let s): return .success(s)
            case .failure(let e): return .failure(ToolboxTextFailure(message: e.description))
            }
        case .textCase(let c): return .success(ToolboxText.convertCase(input, to: c))
        }
    }
}

struct ToolboxTextFailure: Error {
    var message: String
}

struct ToolboxHashJob: Identifiable {
    enum State { case waiting, running, done, failed, cancelled }

    let id = UUID()
    var name: String
    var path: String
    var size: Int64
    var done: Int64 = 0
    var state = State.waiting
    var results: [ToolboxHashAlgo: String] = [:]
    var error: String?
    var seconds: Double?
    let cancel = CancelFlag()

    var fraction: Double { size > 0 ? Double(done) / Double(size) : (state == .done ? 1 : 0) }
}

@Observable
@MainActor
final class ToolboxModel: AppModule {
    var tab: ToolboxTab = .colors
    var settings = ToolboxSettings() {
        didSet { store.value = settings }
    }

    // Colors
    var color = ToolboxRGB(hex: Theme.brandHex)
    var colorInput = ""
    // Passwords
    var password = ""
    var passphrase = ""
    // Digests
    var hashJobs: [ToolboxHashJob] = []
    var expectedHash = ""
    var hashText = ""
    // Text
    var textInput = ""
    var textOp: ToolboxTextOp = .jsonPretty
    var loremUnit: ToolboxText.LoremUnit = .paragraphs
    var loremCount = 2
    var loremSeed: UInt64 = 1
    // Dates
    var uuid = UUID().uuidString
    var dateInput = ""
    // Caffeine
    var caffeineActive = false
    var caffeineStart: Date?
    /// nil while active: until the user stops it.
    var caffeineEnd: Date?
    /// Refreshed every minute while Caféine runs, for the sidebar badge and the menu bar.
    var minuteTick = Date()
    // Pointer
    var cursor = ToolboxCursorSettings() {
        didSet {
            cursorStore.value = cursor
            if started { cursorHider.update(cursor) }
        }
    }
    /// The pointer is hidden right now.
    var cursorHidden = false

    /// The general pasteboard; the live tests swap in a private one so the user's clipboard is never touched.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored private let store = JSONStore<ToolboxSettings>("toolbox", default: ToolboxSettings())
    @ObservationIgnored private let cursorStore = JSONStore<ToolboxCursorSettings>("toolbox-cursor", default: ToolboxCursorSettings())
    @ObservationIgnored let cursorHider = ToolboxCursorHider()
    /// `start()` ran: the pointer may be hidden from now on (never during the first-launch cards).
    @ObservationIgnored private var started = false
    @ObservationIgnored private var assertions: [IOPMAssertionID] = []
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var sampler: NSColorSampler?
    @ObservationIgnored private var clearWork: DispatchWorkItem?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private weak var app: AppModel?

    init() {
        settings = store.value
        cursor = cursorStore.value
        password = ToolboxPassword.generate(settings.password)
        passphrase = ToolboxPassword.passphrase(settings.passphrase)
    }

    // MARK: Module

    var sidebarBadge: String? {
        guard caffeineActive else { return nil }
        _ = minuteTick
        let cup = Theme.icons == .hidden ? "" : "☕︎ "
        return cup + (caffeineEnd == nil ? "∞" : caffeineShortRemaining(Date()))
    }

    func start(app: AppModel) {
        self.app = app
        started = true
        cursorHider.onChange = { [weak self] hidden in self?.cursorHidden = hidden }
        cursorHider.update(cursor)
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        stopCaffeine()
        cursorHider.halt()
        for job in hashJobs { job.cancel.cancel() }
        store.flush()
        cursorStore.flush()
    }

    func applySnapshotTab(_ tab: String) {
        if let t = ToolboxTab(rawValue: tab) { self.tab = t }
    }

    var quickToggles: [QuickToggle] {
        _ = minuteTick
        let title = caffeineActive ? "Caféine · " + (caffeineEnd == nil ? "∞" : caffeineShortRemaining(Date())) : "Caféine"
        return [QuickToggle(id: "tool_caffeine", title: title, symbol: "cup.and.saucer.fill", isOn: caffeineActive) { [weak self] in
            self?.toggleCaffeine()
        }, QuickToggle(id: "tool_cursor", title: cursor.enabled ? "Curseur caché · \(ToolboxCursorRule.label(cursor.delay))" : "Cacher le curseur",
                       symbol: "cursorarrow.slash", isOn: cursor.enabled) { [weak self] in
            self?.cursor.enabled.toggle()
        }]
    }

    func commands(app: AppModel) -> [AppCommand] { ToolboxLauncher.commands(self) }

    func results(for query: String, app: AppModel) -> [AppCommand] { ToolboxLauncher.results(query, model: self) }

    // MARK: Copy

    /// Copies for the page and the launcher. Secrets are marked concealed (clipboard histories skip them)
    /// and leave the clipboard after 90 s when nothing else was copied in between.
    @discardableResult
    func copy(_ text: String, secret: Bool = false) -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        let pb = pasteboard
        pb.clearContents()
        guard secret else {
            pb.setString(text, forType: .string)
            return .copied(text)
        }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pb.declareTypes([.string, concealed], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: concealed)
        clearWork?.cancel()
        guard settings.clearSecrets else { return .message("Copié (marqué confidentiel)") }
        let count = pb.changeCount
        let work = DispatchWorkItem {
            if pb.changeCount == count { pb.clearContents() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
        return .message("Copié · effacé du presse-papiers dans 90 s")
    }

    // MARK: Colors

    func setColor(_ c: ToolboxRGB, remember keep: Bool = true) {
        color = c
        if keep { remember(c) }
    }

    func remember(_ c: ToolboxRGB) {
        var list = settings.colors.filter { $0.hex != c.hex }
        list.insert(c, at: 0)
        settings.colors = Array(list.prefix(36))
    }

    func forget(_ c: ToolboxRGB) {
        settings.colors.removeAll { $0.hex == c.hex }
    }

    /// The system magnifier: no permission needed, Esc cancels.
    func pickColor() async -> ToolboxRGB? {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return nil }
        let picked: ToolboxRGB? = await withCheckedContinuation { cont in
            let s = NSColorSampler()
            sampler = s
            s.show { ns in cont.resume(returning: ns.flatMap { ToolboxRGB($0) }) }
        }
        sampler = nil
        if let picked { setColor(picked) }
        return picked
    }

    func applyColorInput() {
        if let c = ToolboxRGB.parse(colorInput) { setColor(c) }
    }

    // MARK: Passwords

    func regeneratePassword() { password = ToolboxPassword.generate(settings.password) }
    func regeneratePassphrase() { passphrase = ToolboxPassword.passphrase(settings.passphrase) }

    // MARK: Digests

    var hashRunning: Bool { hashJobs.contains { $0.state == .running || $0.state == .waiting } }

    func hash(_ urls: [URL]) {
        guard !DemoData.isEnabled, !Snapshot.isActive else { HUD.show(DemoData.refusal, symbol: "theatermasks"); return }
        for url in urls {
            // A symbolic link is read through to its target: the size shown must be the target's.
            let target = url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            var job = ToolboxHashJob(name: url.lastPathComponent, path: url.path, size: size)
            if !exists || isDir.boolValue {
                job.state = .failed
                job.error = isDir.boolValue ? "C'est un dossier : dépose plutôt les fichiers qu'il contient." : "Fichier introuvable."
            }
            hashJobs.insert(job, at: 0)
        }
        // Keep the list short: finished jobs beyond 20 go away.
        while hashJobs.count > 20, let i = hashJobs.lastIndex(where: { $0.state != .running && $0.state != .waiting }) {
            hashJobs.remove(at: i)
        }
        pumpHashes()
    }

    func cancelHash(_ id: UUID) {
        guard let i = hashJobs.firstIndex(where: { $0.id == id }) else { return }
        hashJobs[i].cancel.cancel()
        if hashJobs[i].state == .waiting { hashJobs[i].state = .cancelled }
    }

    func removeHash(_ id: UUID) {
        hashJobs.first { $0.id == id }?.cancel.cancel()
        hashJobs.removeAll { $0.id == id }
        pumpHashes()
    }

    func clearHashes() {
        for j in hashJobs { j.cancel.cancel() }
        hashJobs.removeAll()
    }

    /// One file at a time (the disk reads faster that way), oldest first.
    private func pumpHashes() {
        guard !hashJobs.contains(where: { $0.state == .running }),
              let i = hashJobs.lastIndex(where: { $0.state == .waiting }) else { return }
        hashJobs[i].state = .running
        let job = hashJobs[i]
        let url = URL(fileURLWithPath: job.path)
        let id = job.id, cancel = job.cancel
        let started = Date()
        Task.detached(priority: .userInitiated) { [self] in
            var last = Date.distantPast
            let result = Result { () throws -> [ToolboxHashAlgo: String] in
                try ToolboxHash.file(url, cancel: cancel) { done in
                    let now = Date()
                    // At most four progress updates a second.
                    guard now.timeIntervalSince(last) >= 0.25 else { return }
                    last = now
                    Task { @MainActor in self.updateJob(id) { $0.done = done } }
                }
            }
            await MainActor.run {
                self.updateJob(id) { j in
                    switch result {
                    case .success(let r):
                        j.results = r
                        j.done = j.size
                        j.state = .done
                        j.seconds = Date().timeIntervalSince(started)
                    case .failure(let e):
                        if e is ToolboxHash.Cancelled {
                            j.state = .cancelled
                        } else {
                            j.state = .failed
                            j.error = "Lecture impossible : \(e.localizedDescription)"
                        }
                    }
                }
                self.pumpHashes()
            }
        }
    }

    private func updateJob(_ id: UUID, _ change: (inout ToolboxHashJob) -> Void) {
        guard let i = hashJobs.firstIndex(where: { $0.id == id }) else { return }
        change(&hashJobs[i])
    }

    // MARK: Caffeine

    /// Keeps the Mac awake for `minutes` (nil: until stopped). Nothing is held in demo mode.
    func startCaffeine(minutes: Int?) {
        releaseAssertions()
        endTimer?.invalidate()
        guard DemoData.isEnabled || Snapshot.isActive || holdAssertions() else {
            caffeineActive = false
            HUD.show("macOS a refusé de garder le Mac éveillé.", symbol: "xmark.octagon.fill")
            return
        }
        let now = Date()
        caffeineActive = true
        caffeineStart = now
        caffeineEnd = minutes.map { now.addingTimeInterval(Double($0) * 60) }
        settings.caffeineMinutes = minutes ?? 0
        minuteTick = now
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        if let end = caffeineEnd {
            let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.caffeineActive else { return }
                    self.stopCaffeine()
                    Notifier.post(id: "caffeine-end", title: "Caféine terminée", body: "Ton Mac peut de nouveau se mettre en veille.", throttle: 0)
                }
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            endTimer = t
        }
        if tickTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.minuteTick = Date() }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        }
    }

    func stopCaffeine() {
        releaseAssertions()
        endTimer?.invalidate()
        endTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        caffeineActive = false
        caffeineStart = nil
        caffeineEnd = nil
    }

    func toggleCaffeine() {
        if caffeineActive {
            stopCaffeine()
        } else {
            startCaffeine(minutes: settings.caffeineMinutes > 0 ? settings.caffeineMinutes : nil)
        }
    }

    func setCaffeineDisplay(_ on: Bool) {
        settings.caffeineDisplay = on
        guard caffeineActive, !DemoData.isEnabled, !Snapshot.isActive else { return }
        releaseAssertions()
        if !holdAssertions() { stopCaffeine() }
    }

    func caffeineRemaining(_ now: Date) -> TimeInterval? {
        caffeineEnd.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Fraction of the chosen duration still to go (1 while it is unlimited).
    func caffeineFraction(_ now: Date) -> Double {
        guard let start = caffeineStart, let end = caffeineEnd else { return 1 }
        let total = end.timeIntervalSince(start)
        return total > 0 ? max(0, min(1, end.timeIntervalSince(now) / total)) : 0
    }

    func caffeineShortRemaining(_ now: Date) -> String {
        guard let r = caffeineRemaining(now) else { return "∞" }
        let m = Int((r / 60).rounded(.up))
        return m >= 60 ? ToolboxTime.durationLabel(m) : "\(max(1, m)) min"
    }

    private func holdAssertions() -> Bool {
        // ASCII only: `pmset -g assertions` and Activity Monitor garble accented names.
        let reason = Self.assertionName as CFString
        var types = [kIOPMAssertionTypePreventUserIdleSystemSleep as CFString]
        if settings.caffeineDisplay { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString) }
        for type in types {
            var id = IOPMAssertionID(0)
            guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess else {
                releaseAssertions()
                return false
            }
            assertions.append(id)
        }
        return true
    }

    private func releaseAssertions() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    static let assertionName = "Heartware - Caféine"

    /// The IOKit assertions currently held (for `dump()`).
    var heldAssertions: Int { assertions.count }

    // MARK: Pointer

    /// The apps open right now that could be added to the list (not this one, not those already there).
    func cursorCandidates() -> [ToolboxCursorApp] {
        guard !DemoData.isEnabled else {
            return [ToolboxCursorApp(bundleID: "com.pixelune.Pixelune", name: "Pixelune", path: "/Applications/Pixelune.app")]
        }
        let chosen = Set(cursor.apps.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { r -> ToolboxCursorApp? in
            guard r.activationPolicy == .regular, let id = r.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !chosen.contains(id), seen.insert(id).inserted else { return nil }
            return ToolboxCursorApp(bundleID: id, name: r.localizedName ?? id, path: r.bundleURL?.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func addCursorApp(_ a: ToolboxCursorApp) {
        guard !cursor.apps.contains(where: { $0.bundleID == a.bundleID }) else { return }
        cursor.apps.append(a)
        cursor.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app picked in the Applications folder (one that is not open).
    func chooseCursorApp() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        let panel = NSOpenPanel()
        panel.title = "Choisis une app"
        panel.prompt = "Ajouter"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            addCursorApp(ToolboxCursorApp(bundleID: id, name: name, path: url.path))
        }
    }

    func removeCursorApp(_ id: String) {
        cursor.apps.removeAll { $0.bundleID == id }
    }

    // MARK: Demo

    func loadDemo() {
        settings.colors = [0xD97757, 0x4C9AE6, 0x5BA3A0, 0x9B87C4, 0xCBB26A, 0x1F1E1D, 0xF4F3EF, 0xC46686, 0x3F8F68, 0x7C83D6, 0xE0B355]
            .map { ToolboxRGB(hex: $0) }
        color = ToolboxRGB(hex: 0xD97757)
        colorInput = "#D97757"
        password = "kN7#vRq2$Wx9mT!eZp4H"
        passphrase = "Boussole-Lavande-Tracteur7-Nuage-Griffon-Pivoine"
        expectedHash = "4f9c2e7d0b1a63c85e2f7a9d4c16b03e8a5d27f9c1e04b6a3d8f72c5e9b0a14d"
        let demoHash = ToolboxHash.digests(of: Data("Pixelune 3.8.2 · fichier fictif de démonstration".utf8))
        var matched = demoHash
        matched[.sha256] = expectedHash
        hashJobs = [
            ToolboxHashJob(name: "Pixelune-3.8.2.dmg", path: DemoData.home + "/Downloads/Pixelune-3.8.2.dmg", size: 186_400_000,
                           done: 186_400_000, state: .done, results: matched, seconds: 0.9),
            ToolboxHashJob(name: "Devis-Atelier.pdf", path: DemoData.home + "/Documents/Devis-Atelier.pdf", size: 2_480_000,
                           done: 2_480_000, state: .done,
                           results: ToolboxHash.digests(of: Data("Devis fictif".utf8)), seconds: 0.02)
        ]
        hashText = "Bonjour Camille"
        textOp = .jsonPretty
        textInput = #"{"projet":"Boussole","version":"2.4.0","plateformes":["macOS","iOS"],"options":{"sombre":true,"langue":"fr"}}"#
        uuid = "7D3F2A91-5C4E-4B8A-9E61-2F0C8D4B7A13"
        dateInput = "1792326600"
        settings.caffeineDisplay = true
        caffeineActive = true
        caffeineStart = Date().addingTimeInterval(-18 * 60)
        caffeineEnd = Date().addingTimeInterval(42 * 60)
        settings.caffeineMinutes = 60
        var c = ToolboxCursorSettings()
        c.enabled = true
        c.delay = 3
        c.onlyApps = true
        c.apps = [ToolboxCursorApp(bundleID: "fr.carnetdebord.app", name: "Carnet de bord", path: "/Applications/Carnet de bord.app"),
                  ToolboxCursorApp(bundleID: "com.monteur.studio", name: "Monteur", path: "/Applications/Monteur.app")]
        cursor = c
    }

    // MARK: Checks

    func selfTest() -> [String] { ToolboxChecks.run(self) }

    func dump() -> [String] {
        let c = ToolboxRGB(hex: 0xFF8800)
        let opts = settings.password
        let sample = ToolboxPassword.generate(opts)
        let abc = ToolboxHash.digests(of: Data("abc".utf8))
        let now = Date()
        return [
            "Couleur #FF8800 : \(c.rgbString) · \(c.hslString) · \(c.swiftUI)",
            "Historique des couleurs : \(settings.colors.count) (\(settings.colors.prefix(6).map(\.hex).joined(separator: ", ")))",
            "Mot de passe : \(sample.count) caractères, \(Int(ToolboxPassword.entropy(opts))) bits · réglages \(opts)",
            "Phrase de passe : \(settings.passphrase.words) mots parmi \(ToolboxWords.list.count), \(Int(ToolboxPassword.passphraseEntropy(settings.passphrase))) bits",
            "SHA-256(abc) = \(abc[.sha256] ?? "?")",
            "MD5(abc) = \(abc[.md5] ?? "?")",
            "Base64(Heartware) = \(ToolboxText.base64Encode("Heartware"))",
            "URL(a b&c=é) = \(ToolboxText.urlEncode("a b&c=é"))",
            "camelCase(Été à la plage) = \(ToolboxText.convertCase("Été à la plage", to: .camel))",
            "Maintenant : \(ToolboxTime.unix(now)) · \(ToolboxTime.isoString(now))",
            "Caféine : \(caffeineActive ? "active" + (caffeineEnd.map { " jusqu'à \(Fmt.clock($0))" } ?? " sans limite") : "inactive") · assertions IOKit tenues : \(heldAssertions)",
            "Empreintes en mémoire : \(hashJobs.count)",
            "Curseur : \(cursor.enabled ? "se cache après \(ToolboxCursorRule.label(cursor.delay))" : "toujours visible")"
                + (cursor.onlyApps ? " dans \(cursor.apps.map(\.name).joined(separator: ", "))" : " dans toutes les apps")
                + " · caché maintenant : \(cursorHidden ? "oui" : "non")"
                + " · masquage en arrière-plan : \(ToolboxCursorHider.backgroundAllowed.map { $0 ? "permis" : "refusé" } ?? "pas encore essayé")"
                + (DemoData.isEnabled ? "" : " · souris immobile depuis \(Int(ToolboxCursorHider.idleSeconds())) s")
        ]
    }
}
