import AppKit

/// The Windscribe app on this Mac and its `windscribe-cli`, which talks to the running app. Heartware starts a closed
/// Windscribe itself, out of sight (`launchHidden`), before any call of the CLI: on a click, or when Windscribe is open.
enum VPNWindscribe {
    /// `com.windscribe.client` in the current sources (cmake/integrations/gui.cmake), `com.windscribe.gui.macos` in the
    /// Homebrew cask's uninstall list (older builds).
    static let bundleIDs: Set<String> = ["com.windscribe.client", "com.windscribe.gui.macos"]
    static let appName = "Windscribe.app"
    /// Installed by the app beside itself, and linked into /usr/local/bin.
    static let cliInBundle = "Contents/MacOS/windscribe-cli"
    static let cliLink = "/usr/local/bin/windscribe-cli"

    /// The installed app, nil when there is none (an app in the Trash or on a disk image does not count).
    static func appURL() -> URL? {
        guard !DemoData.isEnabled else { return nil }
        var candidates: [URL] = []
        for id in bundleIDs.sorted() {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { candidates.append(url) }
        }
        candidates.append(URL(fileURLWithPath: "/Applications/" + appName))
        candidates.append(URL(fileURLWithPath: FS.home + "/Applications/" + appName))
        return candidates.first { url in
            let path = url.path
            return !path.contains("/.Trash/") && !path.hasPrefix("/Volumes/") && !path.contains("/Caskroom/")
                && Shell.exists(url.appendingPathComponent(cliInBundle).path)
        }
    }

    /// The CLI to run: the one inside the app, or the link the app installed.
    static func cliPath() -> String? {
        if let app = appURL() { return app.appendingPathComponent(cliInBundle).path }
        guard !DemoData.isEnabled else { return nil }
        let resolved = (cliLink as NSString).resolvingSymlinksInPath
        return resolved.hasSuffix("/" + appName + "/" + cliInBundle) && Shell.exists(resolved) ? resolved : nil
    }

    static var isRunning: Bool {
        guard !DemoData.isEnabled else { return false }
        return NSWorkspace.shared.runningApplications.contains { isWindscribe($0) }
    }

    static func isWindscribe(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
        return app.bundleURL?.lastPathComponent == appName
    }

    static func running() -> NSRunningApplication? {
        guard !DemoData.isEnabled else { return nil }
        return NSWorkspace.shared.runningApplications.first { isWindscribe($0) }
    }

    /// Opens Windscribe in front, on a click only: to sign in, or for its own settings. On a running Windscribe,
    /// LaunchServices sends it « reopen » (a click on its Dock icon): it shows its window, even when it starts minimized.
    @discardableResult
    static func open() async -> NSRunningApplication? {
        guard !DemoData.isEnabled, let url = appURL() else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Out of sight

    /// How Heartware starts Windscribe: in the background and hidden, never activated, out of the recent items.
    static func hiddenLaunchConfiguration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        return config
    }

    /// Starts a closed Windscribe out of sight: `windscribe-cli` would start its executable itself, in front of everything.
    /// Never on a running one (« reopen » would show its window).
    static func launchHidden() async -> NSRunningApplication? {
        guard !DemoData.isEnabled, let url = appURL() else { return nil }
        if let app = running() { return app }
        ActionLog.write("VPN Windscribe démarré en arrière-plan")
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: hiddenLaunchConfiguration())
    }

    // MARK: Its « Hide from Dock » and « Start minimized »

    /// Where Heartware keeps a copy of Windscribe's settings before changing them.
    static let backupFolder = "WindscribeSettings"

    enum VisibilityWrite: Equatable { case written, unchanged, running, unreadable, failed }

    /// The two settings as Windscribe saved them; nil when they cannot be read with certainty (or were never saved).
    static func visibility() -> VPNWindscribeFlags? {
        guard !DemoData.isEnabled, let stored = VPNWindscribeSettings.readStored() else { return nil }
        return VPNWindscribeSettings.flags(in: stored)
    }

    /// Writes them, only while Windscribe is closed (it reads them once, at launch, and would write its own over them),
    /// after a copy of what was there.
    static func setVisibility(_ flags: VPNWindscribeFlags) -> VisibilityWrite {
        guard !DemoData.isEnabled else { return .failed }
        guard !isRunning else { return .running }
        guard let stored = VPNWindscribeSettings.readStored(), let current = VPNWindscribeSettings.flags(in: stored) else {
            return .unreadable
        }
        if current == flags { return .unchanged }
        guard let changed = VPNWindscribeSettings.setting(flags, in: stored) else { return .unreadable }
        guard backup(stored), VPNWindscribeSettings.writeStored(changed) else { return .failed }
        ActionLog.write("VPN réglages de Windscribe · masqué du Dock : \(flags.hideFromDock) · démarrage réduit : \(flags.startMinimized)")
        return .written
    }

    /// The two settings before Heartware first changed them (its oldest copy), nil when it never did.
    static func originalVisibility() -> VPNWindscribeFlags? {
        guard !DemoData.isEnabled else { return nil }
        let folder = DataStore.url(backupFolder)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(VPNWindscribeSettings.key + "-") }
        guard let oldest = names.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).first,
              let text = try? String(contentsOf: folder.appendingPathComponent(oldest), encoding: .utf8) else { return nil }
        return VPNWindscribeSettings.flags(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func backup(_ stored: String) -> Bool {
        guard let folder = DataStore.ensureFolder(backupFolder) else { return false }
        let name = VPNWindscribeSettings.key + "-" + String(Int(Date().timeIntervalSince1970)) + ".txt"
        guard let url = try? FileOps.write(Data(stored.utf8), to: folder.appendingPathComponent(name)) else { return false }
        DataStore.protect(url)
        return true
    }

    // MARK: The CLI

    /// One `windscribe-cli` at a time (it refuses to run beside another one): Heartware's calls wait for each other here.
    private static let queue = DispatchQueue(label: "heartware.vpn.cli", qos: .userInitiated)

    /// Runs the CLI with fixed words (`status`, `disconnect`) or a validated location, off the main thread.
    static func run(_ cli: String, _ args: [String], timeout: TimeInterval = 20) async -> Shell.Output {
        await withCheckedContinuation { continuation in
            queue.async {
                var out = Shell.run(cli, args, timeout: timeout)
                // The user's own windscribe-cli in a terminal: one more try a moment later.
                if !out.ok, VPNStatusParser.failure(out.all) == .busy {
                    usleep(800_000)
                    out = Shell.run(cli, args, timeout: timeout)
                }
                continuation.resume(returning: out)
            }
        }
    }

    static func status(_ cli: String) async -> (VPNStatus?, Shell.Output) {
        let out = await run(cli, ["status"], timeout: 25)
        return (out.ok ? VPNStatusParser.parse(out.out) : nil, out)
    }

    /// `connect -n <location>`: returns once Windscribe took the order ("Connection is in progress…"); the tunnel is
    /// then followed with `status`. The location must be one of the country's known names.
    static func connect(_ cli: String, to location: String, in country: VPNCountry) async -> Shell.Output? {
        guard let safe = VPNCountry.validated(location, for: country) else { return nil }
        ActionLog.write("VPN windscribe-cli connect -n \(safe)")
        return await run(cli, ["connect", "-n", safe], timeout: 40)
    }

    /// `disconnect`: waits until the tunnel is down.
    static func disconnect(_ cli: String) async -> Shell.Output {
        ActionLog.write("VPN windscribe-cli disconnect")
        return await run(cli, ["disconnect"], timeout: 40)
    }
}
