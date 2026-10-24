import Foundation
import Photos

/// iCloud Photos is on: the iPhone refuses deletions through the cable. The Photos library of this Mac, when it is the
/// same iCloud library, deletes for every device instead, and keeps each photo 30 days in « Supprimés récemment ».
/// macOS asks for the Photos permission on the first use, and confirms every deletion itself.
enum PhonePhotoLibrary {
    static var access: PermissionState {
        guard !DemoData.isEnabled else { return .granted }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    /// Only from a click (the Info.plist of the assembled app explains it; `swift build` has none and would be stopped).
    @MainActor
    static func requestAccess() async -> PermissionState {
        guard Notifier.available else { return access }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return access
    }

    /// The assets of this Mac's library that are these iPhone items. Missing ones are not in it: another Apple Account,
    /// iCloud Photos off on the Mac, or not synced yet; `misses` says what was there instead.
    static func find(_ items: [PhoneItem], diagnose: Bool = true) async -> PhoneLibrarySearch {
        guard access == .granted else { return PhoneLibrarySearch() }
        return await Task.detached(priority: .userInitiated) {
            var search = PhoneLibrarySearch()
            let all = PHFetchOptions()
            all.includeHiddenAssets = true
            search.total = PHAsset.fetchAssets(with: all).count
            for item in items {
                // Close in time first, then (another time zone) the same size in pixels within 14 hours.
                let near = assets(item, within: 2, sameSize: false)
                if let id = PhoneRules.match(item, in: near) ?? PhoneRules.match(item, in: assets(item, within: 14 * 3600, sameSize: true)) {
                    search.found[item.id] = id
                } else if diagnose, search.total > 0, search.misses.count < 20 {
                    // Why not, for the first ones: what the library holds around that moment (one file name read).
                    let around = assets(item, within: 14 * 3600, sameSize: false, names: false)
                    var nearest = around.min { abs($0.date.timeIntervalSince(item.date)) < abs($1.date.timeIntervalSince(item.date)) }
                    if let n = nearest, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [n.id], options: nil).firstObject {
                        nearest?.filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
                    }
                    search.misses.append(PhoneRules.miss(item, around: around.count, nearest: nearest))
                }
            }
            return search
        }.value
    }

    /// The library's photos or videos (the item's kind) taken around the item; file names only when needed (slower).
    private static func assets(_ item: PhoneItem, within seconds: Double, sameSize: Bool, names: Bool = true) -> [PhoneLibraryAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var format = "creationDate >= %@ AND creationDate <= %@ AND mediaType == %d"
        var args: [Any] = [item.date.addingTimeInterval(-seconds) as NSDate, item.date.addingTimeInterval(seconds) as NSDate,
                           (item.kind == .video ? PHAssetMediaType.video : PHAssetMediaType.image).rawValue]
        if sameSize {
            format += " AND ((pixelWidth == %d AND pixelHeight == %d) OR (pixelWidth == %d AND pixelHeight == %d))"
            args += [item.width, item.height, item.height, item.width]
        }
        options.predicate = NSPredicate(format: format, argumentArray: args)
        var out: [PhoneLibraryAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let name = names ? PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "" : ""
            out.append(PhoneLibraryAsset(id: asset.localIdentifier, filename: name, date: asset.creationDate ?? .distantPast,
                                         width: asset.pixelWidth, height: asset.pixelHeight, video: asset.mediaType == .video))
        }
        return out
    }

    /// Whether this library is the iPhone's: a dozen of its photos and videos, spread over the years, looked for in it.
    static func check(_ items: [PhoneItem], before: Int?) async -> PhoneLibrarySync {
        guard access == .granted else { return .unknown }
        let sample = PhoneRules.sample(items, count: 12)
        let search = await find(sample, diagnose: false)
        return PhoneRules.sync(total: search.total, sampled: sample.count, found: search.found.count, before: before)
    }

    /// Moves the assets to « Supprimés récemment » (macOS shows its own confirmation). Returns how many went.
    static func delete(_ assetIDs: [String]) async throws -> Int {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return 0 }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        ActionLog.write("PHOTOS iCLOUD SUPPRIMÉES \(assets.count) (Supprimés récemment, 30 jours)")
        return assets.count
    }
}
