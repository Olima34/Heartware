import SwiftUI
import WebKit

/// An account the ad-free player signs in to once, for every page it shows: the session lives in the app's own web data
/// (the player, its sign-in windows and the next launches share it), and the app never reads nor sends it elsewhere. Only
/// the presence of the session cookie is looked at, and Twitch's public user name.
struct AdBlockAccount: Identifiable, Equatable, Sendable {
    var key: String
    var name: String
    /// What it opens in the player, under its name.
    var serves: String
    var signIn: URL
    /// Cookies that only exist while signed in (any of them), and the domain they live on.
    var sessionCookies: [String]
    var cookieDomain: String
    /// The cookie that holds the user's public name, when the site keeps one.
    var nameCookie: String?
    /// The website data that goes on sign-out: registrable domains as WebKit names its records ("google" covers
    /// google.com, google.fr…).
    var dataDomains: [String]
    var symbol: String

    var id: String { key }

    static let google = AdBlockAccount(
        key: "google", name: "Google",
        serves: "YouTube (tes abonnements, ton historique, tes playlists), et « Se connecter avec Google » sur les autres sites du lecteur",
        // YouTube's own « Se connecter »: Google's page, then back to YouTube signed in.
        signIn: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F")!,
        sessionCookies: ["SID", "__Secure-1PSID", "__Secure-3PSID"], cookieDomain: "google.com",
        dataDomains: ["google", "youtube.com"], symbol: "person.crop.circle")
    static let twitch = AdBlockAccount(
        key: "twitch", name: "Twitch",
        serves: "Tes chaînes suivies, le chat, tes abonnements et tes points de chaîne",
        signIn: URL(string: "https://www.twitch.tv/login")!,
        sessionCookies: ["auth-token"], cookieDomain: "twitch.tv", nameCookie: "login",
        dataDomains: ["twitch.tv"], symbol: "tv")

    static let all = [google, twitch]

    static func named(_ key: String) -> AdBlockAccount? { all.first { $0.key == key } }

    /// A website data record (its display name, "google.fr") that sign-out removes.
    func removes(record: String) -> Bool {
        let r = record.lowercased()
        return dataDomains.contains { d in
            if d.contains(".") { return r == d || r.hasSuffix("." + d) }
            // A bare name: that site under any country's suffix (google.fr, google.co.uk), not another site.
            let labels = r.split(separator: ".")
            guard labels.first.map(String.init) == d else { return false }
            return labels.count == 2 || (labels.count == 3 && ["co", "com"].contains(labels[1]))
        }
    }

    func owns(cookieDomain domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return d == cookieDomain || d.hasSuffix("." + cookieDomain)
    }

    /// Each account's state from the cookies of the player's web data.
    static func states(_ cookies: [AdBlockCookie], now: Date = Date()) -> [String: AdBlockAccountState] {
        var out: [String: AdBlockAccountState] = [:]
        for a in all {
            let mine = cookies.filter { a.owns(cookieDomain: $0.domain) && ($0.expires.map { $0 > now } ?? true) }
            guard mine.contains(where: { a.sessionCookies.contains($0.name) && !$0.value.isEmpty }) else {
                out[a.key] = .signedOut
                continue
            }
            let name = a.nameCookie.flatMap { n in mine.first { $0.name == n }?.value.removingPercentEncoding }
            out[a.key] = .signedIn(name.flatMap { AdBlockAccountState.plausible($0) ? $0 : nil })
        }
        return out
    }

    // MARK: Checks

    @MainActor
    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("comptes : " + message) } }
        let soon = Date().addingTimeInterval(86_400), gone = Date().addingTimeInterval(-60)
        let signedIn = states([
            AdBlockCookie(name: "SID", domain: ".google.com", value: "abc", expires: soon),
            AdBlockCookie(name: "auth-token", domain: ".twitch.tv", value: "xyz", expires: soon),
            AdBlockCookie(name: "login", domain: ".twitch.tv", value: "camille_du_34", expires: soon)
        ])
        expect(signedIn["google"] == .signedIn(nil), "un cookie SID sur .google.com veut dire connecté à Google")
        expect(signedIn["twitch"] == .signedIn("camille_du_34"), "Twitch donne le nom du compte (\(String(describing: signedIn["twitch"])))")
        let out = states([
            AdBlockCookie(name: "SID", domain: ".google.com", value: "abc", expires: gone),
            AdBlockCookie(name: "SID", domain: ".notgoogle.com", value: "abc", expires: soon),
            AdBlockCookie(name: "PREF", domain: ".youtube.com", value: "f1=1", expires: soon),
            AdBlockCookie(name: "auth-token", domain: ".twitch.tv", value: "", expires: nil),
            AdBlockCookie(name: "login", domain: ".twitch.tv", value: "x", expires: soon)
        ])
        expect(out["google"] == .signedOut, "un cookie expiré, d'un autre domaine ou de préférences n'est pas une connexion")
        expect(out["twitch"] == .signedOut, "sans jeton, pas de connexion à Twitch, même avec un nom")
        expect(states([AdBlockCookie(name: "__Secure-3PSID", domain: "accounts.google.com", value: "a", expires: nil)])["google"] == .signedIn(nil),
               "les cookies sécurisés de Google comptent aussi")
        expect(states([AdBlockCookie(name: "auth-token", domain: ".twitch.tv", value: "a", expires: nil),
                       AdBlockCookie(name: "login", domain: ".twitch.tv", value: "<script>", expires: nil)])["twitch"] == .signedIn(nil),
               "un nom de compte étrange n'est pas affiché")

        expect(google.removes(record: "google.com") && google.removes(record: "google.fr") && google.removes(record: "youtube.com")
               && google.removes(record: "google.co.uk"), "la déconnexion de Google efface google.com, google.fr et youtube.com")
        expect(!google.removes(record: "googlevideo.com") && !google.removes(record: "notgoogle.com") && !google.removes(record: "twitch.tv")
               && !google.removes(record: "google.evil.com"), "la déconnexion de Google ne touche pas aux autres sites")
        expect(twitch.removes(record: "twitch.tv") && !twitch.removes(record: "youtube.com"), "la déconnexion de Twitch efface twitch.tv seulement")
        for a in all {
            expect(AdBlockPlayer.belongs(a.signIn), "la page de connexion \(a.name) doit s'ouvrir dans le lecteur")
        }
        return f
    }
}

/// What the account state reads of a cookie (no other field is kept).
struct AdBlockCookie: Sendable {
    var name: String
    var domain: String
    var value: String
    var expires: Date?
}

enum AdBlockAccountState: Equatable {
    case signedOut
    /// With the account's public name when the site keeps one.
    case signedIn(String?)

    var isSignedIn: Bool { if case .signedIn = self { return true } else { return false } }

    /// A user name as Twitch makes them (letters, digits, underscore), short.
    static func plausible(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

// MARK: - Signing in and out

extension AdBlockModel {
    static let accountsKey = "Heartware.Player.Accounts"

    /// The states last read, kept between launches (the web data is only read while the player is open, or on sign-out).
    static func storedAccounts() -> [String: AdBlockAccountState] {
        let raw = UserDefaults.standard.dictionary(forKey: accountsKey) as? [String: String] ?? [:]
        var out: [String: AdBlockAccountState] = [:]
        for (key, value) in raw where AdBlockAccount.named(key) != nil {
            out[key] = value == "-" ? .signedOut : .signedIn(value == "+" ? nil : value)
        }
        return out
    }

    func storeAccounts() {
        var raw: [String: String] = [:]
        for (key, state) in accounts {
            switch state {
            case .signedOut: raw[key] = "-"
            case .signedIn(let name): raw[key] = name ?? "+"
            }
        }
        UserDefaults.standard.set(raw, forKey: Self.accountsKey)
    }

    /// Reads the sessions in the player's web data.
    func refreshAccounts() {
        guard !DemoData.isEnabled, !Snapshot.isActive else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let found = AdBlockAccount.states(cookies.map {
                AdBlockCookie(name: $0.name, domain: $0.domain, value: $0.value, expires: $0.expiresDate)
            })
            MainActor.assumeIsolated {
                guard let self, found != self.accounts else { return }
                self.accounts = found
                self.storeAccounts()
            }
        }
    }

    /// The account's sign-in page, in the player: once signed in, the site opens.
    func signIn(_ account: AdBlockAccount) {
        player.open(account.signIn)
    }

    /// Forgets the account in the player: its cookies and the site data of its domains (this Mac's browsers keep theirs).
    func signOut(_ account: AdBlockAccount) {
        guard !DemoData.isEnabled, !Snapshot.isActive else {
            HUD.show(DemoData.refusal, symbol: "info.circle.fill")
            return
        }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            let mine = records.filter { account.removes(record: $0.displayName) }
            store.removeData(ofTypes: types, for: mine) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ActionLog.write("LECTEUR SANS PUB déconnexion \(account.key) · \(mine.count) sites")
                    self.accounts[account.key] = .signedOut
                    self.storeAccounts()
                    self.player.reloadAfterSignOut()
                    HUD.show("Déconnecté de \(account.name) dans le lecteur", symbol: "person.crop.circle.badge.minus")
                }
            }
        }
    }
}

// MARK: - The page's panel

/// « Tes comptes » : Google and Twitch, signed in once in the player.
struct AdBlockAccountsPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let m = app.adblock
        Panel(title: "Tes comptes dans le lecteur", subtitle: "Connecte-toi une fois, le lecteur s'en souvient",
              symbol: "person.2", tint: AdBlockStyle.tint) {
            HelpTipButton(tip: AdBlockTips.accounts, opensByItself: false)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AdBlockAccount.all) { account in
                    row(account, m)
                    if account != AdBlockAccount.all.last { Divider().overlay(Theme.border) }
                }
            }
        }
        .onAppear { if m.player.isOpen { m.refreshAccounts() } }
    }

    private func row(_ account: AdBlockAccount, _ m: AdBlockModel) -> some View {
        let state = m.accounts[account.key] ?? .signedOut
        return HStack(alignment: .center, spacing: 10) {
            IconBadge(symbol: account.symbol, tint: AdBlockStyle.tint, size: 26)
            Text(account.name).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                .help(account.serves)
            if case .signedIn(let name) = state {
                Tag(text: name.map { "Connecté · \($0)" } ?? "Connecté", symbol: "checkmark", tint: Theme.good, filled: true)
            }
            Spacer(minLength: 8)
            if state.isSignedIn {
                Button("Ouvrir") { m.player.open(account == .google ? AdBlockPlayer.youtube : AdBlockPlayer.twitch) }
                    .buttonStyle(SoftButtonStyle(small: true))
                Button("Se déconnecter") { m.signOut(account) }
                    .buttonStyle(SoftButtonStyle(small: true))
            } else {
                Button("Se connecter") { m.signIn(account) }
                    .buttonStyle(SoftButtonStyle(prominent: true, small: true))
                    .help(account.serves)
            }
        }
    }
}

/// The player's toolbar menu: each account, signed in or not.
struct AdBlockAccountsMenu: View {
    var model: AdBlockModel

    var body: some View {
        let signedIn = AdBlockAccount.all.filter { model.accounts[$0.key]?.isSignedIn == true }
        BorderlessMenu {
            ForEach(AdBlockAccount.all) { account in
                if case .signedIn(let name) = model.accounts[account.key] ?? .signedOut {
                    Section("\(account.name) : connecté\(name.map { " (\($0))" } ?? "")") {
                        Button("Se déconnecter de \(account.name)") { model.signOut(account) }
                    }
                } else {
                    Button("Se connecter à \(account.name)…") { model.signIn(account) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if Theme.icons != .hidden { Image(systemName: signedIn.isEmpty ? "person.crop.circle" : "person.crop.circle.fill").font(.ui(12, .semibold)) }
                Text(signedIn.isEmpty ? "Se connecter" : signedIn.map(\.name).joined(separator: ", "))
                    .font(.ui(11.5, .medium))
            }
            .foregroundStyle(Theme.text2)
        }
        .help("Tes comptes Google et Twitch dans le lecteur")
    }
}
