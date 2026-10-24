import Foundation

/// Which copy of the app is running. The test copy ("Labo") is assembled from the local `labo` branch under its own bundle
/// identifier: its own data folder, keychain items and settings, and it never replaces itself with a version published on
/// GitHub. The published app and a `.build` binary are the regular edition.
enum AppEdition {
    static let regularID = "io.github.olima34.cleanmyclaude"
    static let labID = regularID + ".labo"
    static let isLab = Bundle.main.bundleIdentifier == labID

    /// The name macOS shows for this copy (from its Info.plist), else the app's own.
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Heartware"
    }
}
