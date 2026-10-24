import Foundation
import ImageCaptureCore
import ImageIO
import Vision
import CryptoKit

/// The photos and videos of the plugged iPhone, through Apple's public ImageCaptureCore (what Transfert d'images uses).
/// Opened only on a click. Lists, shows thumbnails, looks at them on this Mac (Vision), copies originals and, when
/// iCloud Photos is off, deletes through the cable.
@MainActor
final class PhoneLibrary {
    /// Something the page shows changed.
    var onChange: (() -> Void)?
    private(set) var state: PhoneLibraryState = .idle
    private(set) var items: [PhoneItem] = []
    private(set) var analysed = false
    /// iCloud Photos is on in the iPhone's settings.
    private(set) var iCloudPhotos = false
    /// The iPhone accepts deletions through the cable (only with iCloud Photos off).
    private(set) var canDelete = false
    var isOpen: Bool { camera != nil || wanting }

    /// One browser for the app's whole life, started the first time the photos are opened and never stopped: once
    /// stopped, it still receives the iPhone plugged back in, and a new browser never hears of it (seen on iOS 27).
    private var browser: ICDeviceBrowser?
    private var bridge: PhoneCameraDelegate?
    /// The cameras plugged in, as the browser announced them.
    private var present: [ICCameraDevice] = []
    /// The photos were asked for: the session opens as soon as the iPhone is there.
    private var wanting = false
    /// The camera whose session is open, or opening.
    private var camera: ICCameraDevice?
    private var files: [String: ICCameraFile] = [:]
    /// The same file listed again in another folder (« 202609_a » and « 202609_b »): same name, date and size.
    private var twins: [String: [ICCameraFile]] = [:]
    /// The UDID of the iPhone MobileDevice saw, to pick the right camera when several are plugged.
    private var wanted: String?
    private var settle: Timer?
    private var giveUp: Timer?
    /// Sessions refused as « locked » by an iPhone that is no longer locked.
    private var retries = 0
    private var lastCount = -1
    private let thumbs: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.totalCostLimit = 48_000_000
        return c
    }()

    // MARK: Opening

    func open(udid: String?) {
        wanted = udid.map(Self.normalized)
        wanting = true
        state = .listing
        if let b = browser {
            if camera == nil, let c = pick(b) { start(c) }
        } else {
            let delegate = PhoneCameraDelegate(self)
            let b = ICDeviceBrowser()
            b.delegate = delegate
            if let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) {
                b.browsedDeviceTypeMask = mask
            }
            bridge = delegate
            browser = b
            b.start()
        }
        armGiveUp()
        changed()
    }

    /// An iPhone that says nothing: the page offers to try again rather than wait for ever.
    private func armGiveUp() {
        giveUp?.invalidate()
        let t = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timedOut() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        giveUp = t
    }

    private func timedOut() {
        giveUp = nil
        guard state == .listing else { return }
        close()
        state = .failed("L'iPhone ne montre pas ses photos. Déverrouille-le, débranche-le et rebranche-le, puis réessaie.")
        changed()
    }

    /// Closes the session and forgets the listing (the iPhone was unplugged, or the page let it go). The browser stays.
    func close() {
        settle?.invalidate()
        giveUp?.invalidate()
        (settle, giveUp) = (nil, nil)
        camera?.requestCloseSession()
        camera?.delegate = nil
        camera = nil
        wanting = false
        files = [:]
        twins = [:]
        items = []
        analysed = false
        thumbs.removeAllObjects()
        state = .idle
        changed()
    }

    /// The app quits.
    func shutdown() {
        close()
        browser?.stop()
        browser?.delegate = nil
        (browser, bridge) = (nil, nil)
    }

    private static func normalized(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").lowercased() }

    private func changed() { onChange?() }

    /// Several cameras: the one MobileDevice saw, by its serial number (the UDID on an iPhone), else the first.
    private func pick(_ b: ICDeviceBrowser) -> ICCameraDevice? {
        let all = present + (b.devices ?? []).compactMap { $0 as? ICCameraDevice }.filter { d in !present.contains { $0 === d } }
        return all.first { c in wanted.map { Self.normalized(c.serialNumberString ?? "") == $0 } ?? false } ?? all.first
    }

    private func start(_ c: ICCameraDevice) {
        retries = 0
        camera = c
        c.delegate = bridge
        c.requestOpenSession()
    }

    // MARK: Device events (from `PhoneCameraDelegate`)

    fileprivate func found(_ device: ICDevice) {
        guard let c = device as? ICCameraDevice else { return }
        if !present.contains(where: { $0 === c }) { present.append(c) }
        if wanting, camera == nil, let b = browser, let p = pick(b) { start(p) }
    }

    fileprivate func lost(_ device: ICDevice) {
        present.removeAll { $0 === device }
        guard device === camera else { return }
        close()
    }

    fileprivate func opened(_ device: ICDevice, error: Error?) {
        guard device === camera, let c = camera else { return }
        if let error = error as NSError? {
            // -9943: ICReturnDeviceIsPasscodeLocked. The iPhone often answers it first, then says it is unlocked: when
            // that came before this answer, nothing else would ask again.
            if error.code == -9943, !c.isAccessRestrictedAppleDevice, retries < 3 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated { if self?.camera === c { c.requestOpenSession() } }
                }
                return
            }
            state = error.code == -9943 || c.isAccessRestrictedAppleDevice ? .locked : .failed(error.localizedDescription)
            changed()
            return
        }
        // The real HEIC and HEVC files, not JPEG and H.264 copies made on the fly (their sizes would be wrong).
        if c.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) { c.mediaPresentation = .originalAssets }
        iCloudPhotos = c.iCloudPhotosEnabled
        canDelete = c.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        state = .listing
        changed()
    }

    fileprivate func restricted(_ on: Bool) {
        guard let c = camera else { return }
        if on {
            state = .locked
            changed()
        } else if state == .locked {
            state = .listing
            armGiveUp()
            changed()
            c.requestOpenSession()
        }
    }

    /// The listing may still grow after « complete »: it is read once the count holds still.
    fileprivate func catalogued() {
        lastCount = -1
        settle?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSettled() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        settle = t
    }

    private func checkSettled() {
        let n = camera?.mediaFiles?.count ?? 0
        guard n == lastCount else { lastCount = n; return }
        settle?.invalidate()
        settle = nil
        rebuild()
    }

    /// New photos taken while plugged in, or deletions made on the iPhone.
    fileprivate func contentsChanged() {
        guard state == .ready, settle == nil else { return }
        catalogued()
    }

    private func rebuild() {
        guard let c = camera else { return }
        let old = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var map: [String: ICCameraFile] = [:]
        var doubles: [String: [ICCameraFile]] = [:]
        var byListing: [String: String] = [:]
        var out: [PhoneItem] = []
        for case let f as ICCameraFile in c.mediaFiles ?? [] {
            let name = f.name ?? ""
            let date = f.creationDate ?? f.fileCreationDate ?? .distantPast
            // The iPhone gives no handle (all 0): its folder, name and date tell the files apart. Listed twice under the
            // same name, date and size, it is one item, never a duplicate: deleting « the copy » could delete the only one.
            let listing = "\(name)|\(Int(date.timeIntervalSince1970))|\(f.fileSize)"
            if let first = byListing[listing] {
                doubles[first, default: []].append(f)
                continue
            }
            var id = f.ptpObjectHandle != 0 ? String(f.ptpObjectHandle) : "\(f.parentFolder?.name ?? "")/\(listing)"
            while map[id] != nil { id += "+" }
            byListing[listing] = id
            let sidecars = (f.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
            let ext = (name as NSString).pathExtension.uppercased()
            var item = PhoneItem(id: id, name: name, kind: f.uti == "public.movie" || ["MOV", "MP4", "M4V"].contains(ext) ? .video : .photo,
                                 size: f.fileSize + sidecars.reduce(0) { $0 + $1.fileSize },
                                 date: date, width: f.width, height: f.height)
            item.duration = f.duration
            item.burst = f.burstUUID
            item.burstKept = f.burstPicked || f.burstFavorite
            item.live = sidecars.contains { ["MOV", "MP4"].contains(($0.name as NSString?)?.pathExtension.uppercased() ?? "") }
            item.slowMo = f.highFramerate
            item.timeLapse = f.timeLapse
            item.located = !(f.gpsString ?? "").isEmpty
            // What the analysis found stays.
            if let o = old[id] { (item.score, item.utility, item.series, item.duplicateOf) = (o.score, o.utility, o.series, o.duplicateOf) }
            map[id] = f
            out.append(item)
        }
        files = map
        twins = doubles
        items = out
        giveUp?.invalidate()
        giveUp = nil
        state = .ready
        changed()
    }

    // MARK: Thumbnails

    /// A small picture of the item, from the iPhone (JPEG of a few kilobytes), kept while the page lives.
    func thumbnail(_ id: String) async -> CGImage? {
        if let cached = thumbs.object(forKey: id as NSString) { return cached }
        guard let f = files[id], let data = await Self.thumbnailData(f, size: 360) else { return nil }
        let image = await Task.detached(priority: .utility) { Self.decode(data, max: 240) }.value
        if let image { thumbs.setObject(image, forKey: id as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }

    private static func thumbnailData(_ f: ICCameraFile, size: Int) async -> Data? {
        await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
            f.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: size]) { data, _ in k.resume(returning: data) }
        }
    }

    nonisolated private static func decode(_ data: Data, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: Deep analysis

    /// What Vision says of one photo.
    private struct Look {
        var print: VNFeaturePrintObservation
        var score: Float?
        var utility: Bool
    }

    /// Looks at every photo on this Mac (about 25 a second): near-identical series, receipts and documents, failures,
    /// then identical files. Nothing leaves the Mac. `progress(done, total)` comes at most four times a second.
    func analyse(cancel: CancelFlag, progress: @escaping @MainActor (Int, Int) -> Void) async {
        let photos = items.filter { $0.kind == .photo }.sorted { $0.date < $1.date }
        let sameSize = Dictionary(grouping: items, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        let total = photos.count + sameSize.count
        var done = 0
        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastReport) >= 0.25 else { return }
            lastReport = Date()
            progress(done, total)
        }
        var looks: [String: Look] = [:]
        await withTaskGroup(of: (String, Look?).self) { group in
            var queue = photos.compactMap { p in files[p.id].map { (p.id, $0) } }.makeIterator()
            func launch() {
                guard !cancel.isCancelled, let (id, f) = queue.next() else { return }
                group.addTask {
                    guard let data = await Self.thumbnailData(f, size: 360) else { return (id, nil) }
                    return (id, Self.look(data))
                }
            }
            for _ in 0..<4 { launch() }
            for await (id, look) in group {
                done += 1
                if let look { looks[id] = look }
                report()
                launch()
            }
        }
        guard !cancel.isCancelled, !items.isEmpty else { return }
        let dated = photos.filter { looks[$0.id] != nil }.map { (id: $0.id, date: $0.date) }
        let series = PhoneRules.assignSeries(dated) { a, b in
            guard let pa = looks[dated[a].id]?.print, let pb = looks[dated[b].id]?.print else { return nil }
            var d: Float = 0
            return (try? pa.computeDistance(&d, to: pb)) != nil ? d : nil
        }
        var prints: [(id: String, date: Date, print: String)] = []
        for item in sameSize where !cancel.isCancelled {
            if let f = files[item.id], let p = await Self.fingerprint(f) { prints.append((item.id, item.date, p)) }
            done += 1
            report()
        }
        guard !cancel.isCancelled else { return }
        let duplicates = PhoneRules.duplicates(prints)
        for i in items.indices {
            let id = items[i].id
            if let look = looks[id] {
                items[i].score = look.score
                items[i].utility = look.utility
            }
            items[i].series = series[id]
            items[i].duplicateOf = duplicates[id]
        }
        analysed = true
        report(force: true)
        changed()
    }

    nonisolated private static func look(_ data: Data) -> Look? {
        guard let image = decode(data, max: 360) else { return nil }
        let printRequest = VNGenerateImageFeaturePrintRequest()
        printRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
        var requests: [VNRequest] = [printRequest]
        var aesthetics: VNRequest?
        if #available(macOS 15, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            requests.append(r)
            aesthetics = r
        }
        try? VNImageRequestHandler(cgImage: image).perform(requests)
        guard let print = printRequest.results?.first else { return nil }
        var look = Look(print: print, score: nil, utility: false)
        if #available(macOS 15, *), let o = (aesthetics as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
            look.score = o.overallScore
            look.utility = o.isUtility
        }
        return look
    }

    /// The file's fingerprint, computed on the iPhone (macOS 15), or the hash of its first megabyte and its size.
    private static func fingerprint(_ f: ICCameraFile) async -> String? {
        if #available(macOS 15, *) {
            return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
                f.requestFingerprint { print, _ in k.resume(returning: print) }
            }
        }
        let head = await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
            f.requestReadData(atOffset: 0, length: min(f.fileSize, 1_000_000)) { data, _ in k.resume(returning: data) }
        }
        return head.map { Self.hash($0, size: f.fileSize) }
    }

    nonisolated private static func hash(_ head: Data, size: Int64) -> String {
        SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined() + "-\(size)"
    }

    // MARK: Copies

    enum Failure: LocalizedError {
        case gone, copy(String), mismatch

        var errorDescription: String? {
            switch self {
            case .gone: return "Il n'est plus sur l'iPhone."
            case .copy(let why): return "Copie impossible : \(why)"
            case .mismatch: return "La copie ne correspond pas à l'original : rien n'est supprimé."
            }
        }
    }

    /// Copies the original (and its Live Photo video, its edits) into `folder`, each file checked against the iPhone:
    /// same size, and the same bytes at its start, middle and end, read again from the iPhone. Nothing is kept from a
    /// copy that does not match. (The fingerprints ImageCaptureCore computes on the iPhone and on the Mac differ even
    /// for identical files: they cannot be compared.)
    func copy(_ id: String, into folder: URL) async throws -> [URL] {
        guard let f = files[id] else { throw Failure.gone }
        let parts = [f] + (f.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
        // First into a waiting folder of its own: ImageCaptureCore dates each file to the shot, and only a folder
        // made now lets `Remover` take a failed copy away.
        let staging = try FileOps.makeDirectory(folder.appendingPathComponent(".heartware-copie"))
        defer { Remover.discardOutput(staging) }
        var staged: [URL] = []
        for part in parts {
            let url = try await Self.download(part, to: staging.appendingPathComponent(part.name ?? id))
            guard await Self.matches(part, url) else { throw Failure.mismatch }
            staged.append(url)
        }
        // All checked: into the month's folder under free names, the Live Photo video with the photo's name.
        let main = folder.appendingPathComponent(f.name ?? id)
        var out: [URL] = []
        for (n, url) in staged.enumerated() {
            let base = out.first?.deletingPathExtension().lastPathComponent ?? main.deletingPathExtension().lastPathComponent
            out.append(try FileOps.move(url, to: n == 0 ? main : folder.appendingPathComponent(base).appendingPathExtension(url.pathExtension)))
        }
        return out
    }

    private static func download(_ f: ICCameraFile, to target: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<URL, Error>) in
            let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: target.deletingLastPathComponent(),
                                                    .saveAsFilename: target.lastPathComponent, .overwrite: false]
            f.requestDownload(options: options) { name, error in
                if let error { k.resume(throwing: Failure.copy(error.localizedDescription)); return }
                k.resume(returning: target.deletingLastPathComponent().appendingPathComponent(name ?? target.lastPathComponent))
            }
        }
    }

    /// Same size, and the same bytes in three places read again from the iPhone.
    private static func matches(_ f: ICCameraFile, _ url: URL) async -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size == f.fileSize, let local = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? local.close() }
        let chunk = min(size, 65_536)
        for offset in Set([0, max(0, size / 2 - chunk / 2), max(0, size - chunk)]) {
            let remote = await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
                f.requestReadData(atOffset: offset, length: chunk) { data, _ in k.resume(returning: data) }
            }
            guard let remote, remote.count == Int(chunk), (try? local.seek(toOffset: UInt64(offset))) != nil,
                  (try? local.read(upToCount: Int(chunk))) == remote else { return false }
        }
        return true
    }

    // MARK: Deletion through the cable

    /// Deletes for good, ten at a time (big batches crawl), with their Live Photo videos. Returns what went.
    /// Only when the iPhone allows it: iCloud Photos off.
    func delete(_ ids: [String], cancel: CancelFlag, progress: @escaping @MainActor (Int) -> Void) async -> Set<String> {
        guard let c = camera, canDelete else { return [] }
        var gone = Set<String>()
        for batch in PhoneRules.batches(ids.filter { files[$0] != nil }, size: 10) where !cancel.isCancelled {
            var targets: [ICCameraItem] = []
            var owner: [ObjectIdentifier: String] = [:]
            for id in batch {
                guard let f = files[id] else { continue }
                owner[ObjectIdentifier(f)] = id
                // With the other listings of the same file: what the user deleted must not come back.
                for g in [f] + (twins[id] ?? []) {
                    targets.append(g)
                    targets += g.sidecarFiles ?? []
                }
            }
            let deleted = await withCheckedContinuation { (k: CheckedContinuation<[ICCameraItem], Never>) in
                // Answered once: by the completion, or at once when the request could not even start.
                let once = PhoneOnce()
                let p = c.requestDeleteFiles(targets, deleteFailed: { _ in }) { result, _ in
                    if once.claim() { k.resume(returning: result[.successful] ?? []) }
                }
                if p == nil, once.claim() { k.resume(returning: []) }
            }
            for item in deleted { if let id = owner[ObjectIdentifier(item)] { gone.insert(id) } }
            progress(gone.count)
        }
        // Only what really left the listing counts.
        let still = Set((c.mediaFiles ?? []).map { ObjectIdentifier($0) })
        gone = gone.filter { id in files[id].map { !still.contains(ObjectIdentifier($0)) } ?? true }
        for id in gone {
            if let f = files[id] { ActionLog.write("SUPPRIMÉ DE L'IPHONE \(f.name ?? id) \(Fmt.bytes(f.fileSize)) (\(f.parentFolder?.name ?? "?"))") }
        }
        forget(gone)
        return gone
    }

    /// Removes items that left the iPhone (deleted here or through the Photos library).
    func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids { files[id] = nil; twins[id] = nil }
        changed()
    }
}

/// True the first time only.
private final class PhoneOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// ImageCaptureCore's delegate: its messages come on the main thread and go to the library.
private final class PhoneCameraDelegate: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    weak var library: PhoneLibrary?

    init(_ library: PhoneLibrary) {
        self.library = library
    }

    private func main(_ work: @escaping @MainActor (PhoneLibrary) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let l = self?.library { work(l) } }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) { main { $0.found(device) } }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { main { $0.lost(device) } }
    func didRemove(_ device: ICDevice) { main { $0.lost(device) } }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { main { $0.opened(device, error: error) } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { main { $0.catalogued() } }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { main { $0.contentsChanged() } }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { main { $0.contentsChanged() } }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { main { $0.restricted(false) } }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { main { $0.restricted(true) } }
}
