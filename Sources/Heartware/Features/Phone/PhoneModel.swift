import SwiftUI
import AppKit

/// The iPhone page: a check-up as soon as an iPhone is plugged in by cable (storage, battery, iOS, backups), a health
/// notebook kept from one check-up to the next, and its photos and videos sorted to free space without losing anything.
/// Listening for the cable costs nothing at rest; the photos are only opened on a click.
@Observable
@MainActor
final class PhoneModel: AppModule {
    var link: PhoneLink = .absent
    var info: PhoneInfo?
    // The photo library, as last seen by `PhoneLibrary`.
    var photoState: PhoneLibraryState = .idle
    var items: [PhoneItem] = []
    var categories: [PhoneCategory] = []
    var analysed = false
    var iCloudPhotos = false
    var canDelete = false
    var task: PhoneTask?
    var selection: Set<String> = [] {
        didSet { if selection != oldValue { lookUpSelection() } }
    }
    /// With iCloud Photos, while this Mac's library is not known to be the iPhone's: which ticked items it holds
    /// (item → asset), looked a moment after each change; nil while looking.
    var selectionInLibrary: [String: String]?
    @ObservationIgnored private var selectionLookup: Task<Void, Never>?
    /// The category being reviewed, thumbnail by thumbnail.
    var reviewing: PhoneCategoryKind?
    /// The Photos permission, for iCloud Photos.
    var photosAccess: PermissionState = .notAsked
    /// With iCloud Photos: whether this Mac's library is the iPhone's, the only way to delete.
    var librarySync: PhoneLibrarySync = .unknown
    var libraryCheckedAt: Date?
    /// The page is on screen: a library still filling is looked at again every minute.
    @ObservationIgnored var pageVisible = false {
        didSet { updateRecheck() }
    }
    @ObservationIgnored private var recheck: Timer?
    var health: PhoneHealthLog {
        didSet { healthStore.value = health }
    }
    var settings: PhoneSettings {
        didSet { settingsStore.value = settings }
    }
    /// Demo and snapshots: the thumbnails are drawn, nothing is read.
    @ObservationIgnored private(set) var drawnThumbnails = false

    @ObservationIgnored let library = PhoneLibrary()
    @ObservationIgnored private let healthStore = JSONStore<PhoneHealthLog>("phone-health", default: PhoneHealthLog())
    @ObservationIgnored private let settingsStore = JSONStore<PhoneSettings>("phone", default: PhoneSettings())
    @ObservationIgnored private let archiveStore = JSONStore<[PhoneArchiveEntry]>("phone-archive", default: [])
    @ObservationIgnored private var subscription: UnsafeMutableRawPointer?
    /// Devices plugged by cable, by UDID (retained), the first one shown.
    @ObservationIgnored private var devices: [(udid: String, device: PhoneBridge.Device)] = []
    @ObservationIgnored private var cancel = CancelFlag()
    @ObservationIgnored private var trustTask: Task<Void, Never>?

    init() {
        health = healthStore.value
        settings = settingsStore.value
        library.onChange = { [weak self] in self?.sync() }
    }

    var current: String? { devices.first?.udid }
    var deletion: PhoneDeletion {
        if canDelete { return .cable }
        guard iCloudPhotos else { return .none }
        if !librarySync.waiting { return .library }
        // Part of the library came from iCloud (older photos, or iCloud full): the ticked items that are there.
        return selectionInLibrary?.isEmpty == false ? .library : .none
    }
    var isBusy: Bool { task != nil }
    var mediaSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// What the categories hold, each item once.
    var freeable: Int64 {
        let ids = Set(categories.flatMap(\.ids))
        return items.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var selectedSize: Int64 { items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    // MARK: Module

    var sidebarBadge: String? {
        if let task { return Fmt.pct(task.fraction) }
        guard link == .ready, let s = info?.storage else { return nil }
        return Fmt.bytes(s.free)
    }

    func start(app: AppModel) {
        listen()
    }

    /// Follows the cable through MobileDevice (its notifications arrive on the main run loop).
    func listen() {
        guard subscription == nil, PhoneBridge.isAvailable else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        subscription = PhoneBridge.subscribe({ info, context in
            guard let info, let context, let (device, event) = PhoneBridge.event(info) else { return }
            PhoneBridge.retain(device)
            let model = Unmanaged<PhoneModel>.fromOpaque(context).takeUnretainedValue()
            if Thread.isMainThread {
                MainActor.assumeIsolated { model.deviceEvent(device, event) }
            } else {
                let address = UInt(bitPattern: device)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let d = UnsafeMutableRawPointer(bitPattern: address) { model.deviceEvent(d, event) }
                    }
                }
            }
        }, context: context)
    }

    func stop() {
        if let subscription { PhoneBridge.unsubscribe(subscription) }
        subscription = nil
        cancel.cancel()
        library.shutdown()
        for d in devices { PhoneBridge.release(d.device) }
        devices = []
        healthStore.flush()
        archiveStore.flush()
    }

    // MARK: The cable

    /// `device` was retained by the callback: kept, or released here.
    private func deviceEvent(_ device: PhoneBridge.Device, _ event: PhoneBridge.Event) {
        guard let udid = PhoneBridge.identifier(device) else { PhoneBridge.release(device); return }
        switch event {
        case .attached:
            guard PhoneBridge.isUSB(device), !devices.contains(where: { $0.udid == udid }) else { PhoneBridge.release(device); return }
            devices.append((udid, device))
            if devices.count == 1 { read() }
        case .detached:
            PhoneBridge.release(device)
            guard let i = devices.firstIndex(where: { $0.udid == udid }) else { return }
            let wasShown = i == 0
            PhoneBridge.release(devices[i].device)
            devices.remove(at: i)
            if wasShown { unplugged() }
        }
    }

    private func unplugged() {
        cancel.cancel()
        trustTask?.cancel()
        library.close()
        (info, task, reviewing) = (nil, nil, nil)
        selection = []
        link = .absent
        if !devices.isEmpty { read() }
    }

    /// Reads the shown device in the background (about a second), then notes the check-up in the notebook.
    func read() {
        guard !DemoData.isEnabled, !Snapshot.isActive, let (udid, device) = devices.first else { return }
        if info?.udid != udid { link = .reading }
        let handle = PhoneBridge.Handle(device: device)
        PhoneBridge.queue.async {
            let reading = PhoneBridge.read(handle.device, udid: udid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(reading, udid: udid) }
            }
        }
    }

    private func apply(_ reading: PhoneBridge.Reading, udid: String) {
        guard current == udid else { return }
        switch reading {
        case .info(let i):
            info = i
            link = .ready
            trustTask?.cancel()
            record(i)
        case .untrusted:
            link = .untrusted
        case .failed:
            if link != .ready { link = .untrusted }
        }
    }

    /// Asks the iPhone to trust this Mac, then looks again every few seconds for a minute.
    func askTrust() {
        guard !DemoData.isEnabled, let device = devices.first?.device else { return }
        let handle = PhoneBridge.Handle(device: device)
        PhoneBridge.queue.async { PhoneBridge.askTrust(handle.device) }
        trustTask?.cancel()
        trustTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.link == .untrusted else { return }
                self.read()
            }
        }
    }

    // MARK: The notebook

    private func record(_ i: PhoneInfo, media: Int64? = nil) {
        guard let s = i.storage else { return }
        var device = health.devices[i.udid] ?? PhoneHealthDevice(name: i.name, productType: i.productType, lastSeen: Date())
        (device.name, device.productType, device.lastSeen) = (i.name, i.productType, Date())
        device.points = PhoneRules.record(PhoneHealthPoint(day: PhoneRules.day(Date()), free: s.free, total: s.total,
                                                           health: i.battery?.health, cycles: i.battery?.cycles, media: media),
                                          in: device.points)
        health.devices[i.udid] = device
    }

    var notebook: PhoneHealthDevice? { info.flatMap { health.devices[$0.udid] } }

    /// The devices seen before, the most recent first (for the page while nothing is plugged).
    var knownDevices: [(udid: String, device: PhoneHealthDevice)] {
        health.devices.map { ($0.key, $0.value) }.sorted { $0.device.lastSeen > $1.device.lastSeen }
    }

    // MARK: Photos

    /// Opens the photo library (the iPhone must be unlocked), then looks at every photo on this Mac.
    func analysePhotos() {
        guard canOpenPhotos else { return }
        if photoState == .ready {
            runAnalysis()
        } else {
            pendingAnalysis = true
            openPhotos()
        }
    }

    /// Lists the photos and videos, without looking at them yet.
    func openPhotos() {
        guard canOpenPhotos, photoState != .ready else { return }
        library.close()
        library.open(udid: current)
    }

    /// The photos need the iPhone shown (or, without MobileDevice, whatever ImageCaptureCore finds).
    private var canOpenPhotos: Bool { !DemoData.isEnabled && !Snapshot.isActive && (link == .ready || !PhoneBridge.isAvailable) }

    @ObservationIgnored private var pendingAnalysis = false

    /// What `PhoneLibrary` shows, copied here for the page.
    private func sync() {
        let wasReady = photoState == .ready
        photoState = library.state
        items = library.items
        analysed = library.analysed
        iCloudPhotos = library.iCloudPhotos
        canDelete = library.canDelete
        categories = PhoneRules.categories(items, analysed: analysed)
        selection.formIntersection(Set(items.map(\.id)))
        if photoState == .ready, !wasReady, let i = info { record(i, media: mediaSize) }
        if photoState == .ready, pendingAnalysis {
            pendingAnalysis = false
            runAnalysis()
        }
        if photoState == .ready, iCloudPhotos {
            photosAccess = PhonePhotoLibrary.access
            if librarySync == .unknown { checkLibrary() }
        }
        if photoState != .ready {
            librarySync = .unknown
            updateRecheck()
        }
    }

    private func runAnalysis() {
        guard task == nil, !analysed else { return }
        cancel = CancelFlag()
        let flag = cancel
        task = PhoneTask(kind: .analysis, done: 0, total: max(1, items.count))
        Task {
            await library.analyse(cancel: flag) { done, total in
                self.task = PhoneTask(kind: .analysis, done: done, total: max(1, total))
            }
            if task?.kind == .analysis { task = nil }
        }
    }

    func stopTask() {
        cancel.cancel()
    }

    func thumbnail(_ id: String) async -> CGImage? {
        guard !drawnThumbnails else { return nil }
        return await library.thumbnail(id)
    }

    // MARK: Selection

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func category(_ kind: PhoneCategoryKind) -> PhoneCategory? {
        guard kind == .all else { return categories.first { $0.kind == kind } }
        let sorted = items.sorted { $0.date < $1.date }
        return PhoneCategory(kind: .all, ids: sorted.map(\.id), size: sorted.reduce(0) { $0 + $1.size })
    }

    func selectAll(_ kind: PhoneCategoryKind) { selection.formUnion(category(kind)?.ids ?? []) }
    func deselectAll(_ kind: PhoneCategoryKind) { selection.subtract(category(kind)?.ids ?? []) }

    /// Only exact duplicates selected: one copy stays on the iPhone, deleting needs no copy on the Mac.
    var selectionIsDuplicates: Bool {
        let dups = Set(category(.duplicates)?.ids ?? [])
        return !selection.isEmpty && selection.isSubset(of: dups)
    }

    // MARK: Freeing

    /// Asks where the originals go (the first time, or to change it). Returns false when the user cancels.
    @discardableResult
    func chooseFolder() -> Bool {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return false }
        let panel = NSOpenPanel()
        panel.title = "Où mettre au frais les originaux de l'iPhone ?"
        panel.message = "Heartware y range chaque photo et vidéo dans un dossier par mois, puis vérifie chaque copie avant de libérer l'iPhone."
        panel.prompt = "Choisir ce dossier"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.archiveFolder ?? FS.home + "/Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.archiveFolder = url.path
        return true
    }

    /// Copies the selection on the Mac, checks each copy, then (`free`) deletes from the iPhone what was copied.
    func archive(free: Bool) async -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        guard task == nil else { return .done }
        let device = info ?? PhoneInfo(udid: "", name: "iPhone", productType: "", deviceClass: "iPhone", iosVersion: "", build: "")
        guard settings.archiveFolder != nil || chooseFolder(), let base = settings.archiveFolder else { return .done }
        let chosen = items.filter { selection.contains($0.id) }.sorted { $0.date < $1.date }
        guard !chosen.isEmpty else { return .done }
        cancel = CancelFlag()
        let flag = cancel
        task = PhoneTask(kind: .archive, done: 0, total: chosen.count)
        var copied: [PhoneItem] = []
        var failures: [String] = []
        var entries = archiveStore.value
        var lastReport = Date.distantPast
        for item in chosen where !flag.isCancelled {
            let folder = PhoneRules.archiveFolder(base: base, device: device.name, taken: item.date)
            do {
                if !FS.exists(folder) { try FileOps.makeDirectory(URL(fileURLWithPath: folder)) }
                let urls = try await library.copy(item.id, into: URL(fileURLWithPath: folder))
                copied.append(item)
                entries.append(PhoneArchiveEntry(device: device.udid, name: item.name, taken: item.date, size: item.size,
                                                 path: urls.first?.path ?? folder, archived: Date()))
            } catch {
                failures.append("\(item.name) : \(error.localizedDescription)")
            }
            if Date().timeIntervalSince(lastReport) >= 0.25 || item.id == chosen.last?.id {
                lastReport = Date()
                task = PhoneTask(kind: .archive, done: copied.count + failures.count, total: chosen.count, bytes: copied.reduce(0) { $0 + $1.size })
            }
        }
        archiveStore.value = entries
        let copiedSize = copied.reduce(0) { $0 + $1.size }
        task = nil
        guard !copied.isEmpty else {
            return .failed(failures.first.map { "Rien n'a été copié. \($0)" } ?? "Rien n'a été copié.")
        }
        var text = "\(Fmt.bytes(copiedSize)) mis au frais dans \((base as NSString).lastPathComponent)"
        if free, !flag.isCancelled {
            let freed = await delete(copied, flag: flag)
            markFreed(freed, device: device.udid)
            text += freed.isEmpty ? " · rien n'a quitté l'iPhone" : " · \(Fmt.bytes(copied.filter { freed.contains($0.id) }.reduce(0) { $0 + $1.size })) libérés sur l'iPhone"
        }
        if !failures.isEmpty { text += " · \(Fmt.plural(failures.count, "échec", "échecs"))" }
        if let first = copied.first { Finder.reveal(entries.last { $0.name == first.name }?.path ?? base) }
        return .message(text)
    }

    /// Deletes without copying: exact duplicates (the original stays), or anything with iCloud Photos (30 days to change one's mind).
    func deleteSelection() async -> CommandOutcome {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return .message(DemoData.refusal) }
        guard task == nil, deletion == .library || selectionIsDuplicates else { return .done }
        let chosen = items.filter { selection.contains($0.id) }
        cancel = CancelFlag()
        let freed = await delete(chosen, flag: cancel)
        guard !freed.isEmpty else { return .failed(deletionTrouble == nil ? "Rien n'a été supprimé." : "Rien n'a été supprimé : l'explication est dans la page.") }
        let size = chosen.filter { freed.contains($0.id) }.reduce(0) { $0 + $1.size }
        return .message(deletion == .library ? "\(Fmt.bytes(size)) dans « Supprimés récemment » pour 30 jours" : "\(Fmt.bytes(size)) libérés sur l'iPhone")
    }

    /// Why the last deletion through the Photos library found nothing to delete.
    var deletionTrouble: String?

    private func delete(_ chosen: [PhoneItem], flag: CancelFlag) async -> Set<String> {
        deletionTrouble = nil
        task = PhoneTask(kind: .deletion, done: 0, total: chosen.count)
        defer { task = nil }
        switch deletion {
        case .cable:
            let gone = await library.delete(chosen.map(\.id), cancel: flag) { [weak self] n in
                self?.task = PhoneTask(kind: .deletion, done: n, total: chosen.count)
            }
            selection.subtract(gone)
            return gone
        case .library:
            if photosAccess != .granted { photosAccess = await PhonePhotoLibrary.requestAccess() }
            guard photosAccess == .granted else {
                deletionTrouble = "Heartware n'a pas accès à Photos : autorise-le dans Réglages Système › Confidentialité › Photos."
                return []
            }
            let search = await PhonePhotoLibrary.find(chosen)
            for line in search.misses { ActionLog.write("PHOTOS iCLOUD INTROUVABLE \(line)") }
            guard !search.found.isEmpty else {
                deletionTrouble = search.total == 0
                    ? "La photothèque de ce Mac est vide : ouvre Photos, active Photos iCloud (Photos › Réglages › iCloud) avec le même compte que l'iPhone et laisse-le se synchroniser."
                    : "Ces éléments ne sont pas dans la photothèque de ce Mac (\(Fmt.int(search.total)) photos et vidéos) : vérifie dans Photos › Réglages › iCloud que Photos iCloud y est activé avec le même compte que l'iPhone, et qu'il a fini de se synchroniser. Ou supprime-les depuis l'iPhone."
                return []
            }
            do {
                _ = try await PhonePhotoLibrary.delete(Array(search.found.values))
            } catch {
                deletionTrouble = "Suppression annulée : rien n'a changé."
                return []
            }
            let gone = Set(search.found.keys)
            if gone.count < chosen.count {
                deletionTrouble = "\(Fmt.plural(chosen.count - gone.count, "élément n'est", "éléments ne sont")) pas encore dans la photothèque de ce Mac : \(chosen.count - gone.count > 1 ? "ils restent" : "il reste") sur l'iPhone."
            }
            selection.subtract(gone)
            library.forget(gone)
            return gone
        case .none:
            deletionTrouble = "Avec Photos iCloud, l'iPhone refuse les suppressions par le câble."
            return []
        }
    }

    private func markFreed(_ ids: Set<String>, device: String) {
        guard !ids.isEmpty else { return }
        let names = Set(items.filter { ids.contains($0.id) }.map(\.name))
        var entries = archiveStore.value
        for i in entries.indices where entries[i].device == device && names.contains(entries[i].name) { entries[i].freed = true }
        archiveStore.value = entries
    }

    var archivedCount: Int { archiveStore.value.count }

    func requestPhotosAccess() {
        Task {
            photosAccess = await PhonePhotoLibrary.requestAccess()
            checkLibrary()
        }
    }

    /// Looks whether this Mac's Photos library is the iPhone's (a second or two): « Supprimer » only when it is.
    func checkLibrary() {
        guard !DemoData.isEnabled, !Snapshot.isActive, iCloudPhotos, photoState == .ready, photosAccess == .granted,
              librarySync != .checking else { return }
        let before = librarySync.total
        librarySync = .checking
        let sample = items
        Task {
            let result = await PhonePhotoLibrary.check(sample, before: before)
            if photoState == .ready { librarySync = result }
            libraryCheckedAt = Date()
            lookUpSelection()
            // The page's card says it now, better than the trouble of an earlier attempt.
            if result.waiting { deletionTrouble = nil }
            updateRecheck()
        }
    }

    private func lookUpSelection() {
        selectionLookup?.cancel()
        selectionInLibrary = nil
        let chosen = items.filter { selection.contains($0.id) }
        guard !DemoData.isEnabled, !Snapshot.isActive, iCloudPhotos, !canDelete, photosAccess == .granted,
              librarySync.waiting, !chosen.isEmpty else { return }
        selectionLookup = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let search = await PhonePhotoLibrary.find(chosen, diagnose: false)
            guard !Task.isCancelled else { return }
            selectionInLibrary = search.found
        }
    }

    /// Every minute (a dozen lookups in Photos), only while the page shows a library still filling.
    private func updateRecheck() {
        let needed = pageVisible && iCloudPhotos && photoState == .ready && photosAccess == .granted && librarySync.waiting
        if !needed {
            recheck?.invalidate()
            recheck = nil
        } else if recheck == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkLibrary() }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            recheck = t
        }
    }

    func openPhotosApp() {
        guard !DemoData.isEnabled, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Launcher

    private func open(_ app: AppModel) {
        app.page = .phone
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
    }

    func commands(app: AppModel) -> [AppCommand] {
        let subtitle: String
        if link == .ready, let i = info {
            subtitle = "\(i.name) · " + (i.storage.map { "\(Fmt.bytes($0.free)) libres" } ?? i.model)
        } else {
            subtitle = "Branche ton iPhone avec un câble"
        }
        var list = [AppCommand(id: "phone_open", title: "iPhone : bilan, photos et vidéos", subtitle: subtitle,
                               keywords: ["iphone", "ipad", "téléphone", "portable", "photos", "vidéos", "batterie", "stockage", "libérer", "place"],
                               icon: .symbol("iphone", PhonePage.tint), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
            ctx.app.phone.open(ctx.app)
            return .done
        }]
        if link == .ready, !analysed {
            list.append(AppCommand(id: "phone_analyse", title: "Trier les photos et vidéos de l'iPhone",
                                   subtitle: "Grosses vidéos, captures, séries, doublons : rien n'est supprimé",
                                   keywords: ["iphone", "photos", "vidéos", "trier", "analyser", "doublons", "captures"],
                                   icon: .symbol("photo.stack", PhonePage.tint), group: .actions, assistantSafe: true, urlSafe: true) { ctx in
                ctx.app.phone.open(ctx.app)
                ctx.app.phone.analysePhotos()
                return .done
            })
        }
        return list
    }

    // MARK: Demo and checks

    func loadDemo() {
        PhoneDemo.fill(self)
        drawnThumbnails = true
    }

    func applySnapshotTab(_ tab: String) {
        PhoneDemo.applyTab(tab, to: self)
    }

    /// Demo only: puts the model in a given state.
    func setDemo(link: PhoneLink, info: PhoneInfo?, items: [PhoneItem], analysed: Bool, iCloudPhotos: Bool, canDelete: Bool) {
        (self.link, self.info, self.items, self.analysed) = (link, info, items, analysed)
        (self.iCloudPhotos, self.canDelete) = (iCloudPhotos, canDelete)
        photoState = items.isEmpty ? .idle : .ready
        categories = PhoneRules.categories(items, analysed: analysed)
        photosAccess = .granted
        librarySync = iCloudPhotos ? .synced(18_412) : .unknown
    }

    func selfTest() -> [String] { PhoneChecks.run() }

    func dump() -> [String] { PhoneChecks.dump(self) }
}
