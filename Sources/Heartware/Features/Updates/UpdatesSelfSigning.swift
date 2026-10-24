import Foundation

/// The certificates an update is signed with. macOS ties the permissions (Full Disk Access, Accessibility…) and the app's
/// keychain items to the designated requirement, which pins the certificate: signed by the same one, an update keeps them.
///
/// The published versions are signed by the CI with the release certificate, "Clean My Claude" (`releaseCertificate`,
/// made once by scripts/setup_release_signing.sh, its key only in GitHub's secrets): they are installed as published,
/// nothing asked. A copy built on this Mac (scripts/build_app.sh) is signed with the local certificate of
/// scripts/setup_signing.sh, "Clean My Claude Dev", and its updates are re-signed with it. That one lives in a keychain of
/// its own, out of the search list, locked at sleep and after five minutes: codesign signs with it only once the user
/// typed that keychain's password, asked by the update panel. In the session keychain, where earlier versions of the
/// script put it, any program run under the account could have codesign sign a fake Heartware with it, without a
/// window: the fake would inherit the permissions and read the app's keychain items.
enum UpdatesSelfSigning {
    static let name = "Clean My Claude Dev"
    static var keychainPath: String { FS.home + "/Library/Keychains/cleanmyclaude-signing.keychain-db" }

    /// The SHA-1 (upper case) of the certificate the CI signs the published versions with, written here by
    /// scripts/setup_release_signing.sh. The CI reads it from this line and refuses to publish with another certificate;
    /// nil: the versions are published ad hoc.
    static let releaseCertificate: String? = "955FC89DAF31B05FC7CC1926E54A48585D142284"

    /// An identity to sign with: its certificate's SHA-1, and the keychain codesign finds it in (nil: the search list).
    struct Identity: Equatable {
        var hash: String
        var keychain: String?
    }

    /// How a copy of the app is signed.
    struct Signer: Equatable {
        /// The certificate the designated requirement pins (a self-signed one), upper-case SHA-1.
        var leaf: String?
        /// The first "Authority=" of `codesign -dvv`: the name of the signing certificate.
        var authority: String?
        var adhoc = false
    }

    /// One line of `security find-identity`.
    struct Listed: Equatable {
        var hash: String
        var name: String
    }

    /// `  1) FD519D2F… "Clean My Claude Dev" (CSSMERR_TP_NOT_TRUSTED)` → (FD519D2F…, Clean My Claude Dev), each once.
    static func identities(in text: String) -> [Listed] {
        var list: [Listed] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let tokens = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard tokens.count == 3, tokens[0].hasSuffix(")"), tokens[0].dropLast().allSatisfy(\.isNumber),
                  tokens[1].count == 40, tokens[1].allSatisfy(\.isHexDigit),
                  let open = tokens[2].firstIndex(of: "\""), let close = tokens[2].lastIndex(of: "\""), open < close else { continue }
            let entry = Listed(hash: tokens[1].uppercased(), name: String(tokens[2][tokens[2].index(after: open)..<close]))
            if !list.contains(entry) { list.append(entry) }
        }
        return list
    }

    /// `display`: what `codesign -dvv` prints; `requirement`: what `codesign -d -r-` prints.
    static func signer(display: String, requirement: String) -> Signer {
        let lines = display.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Signer(leaf: UpdatesSelfInstaller.leafHash(fromRequirement: requirement),
                      authority: lines.first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) },
                      adhoc: lines.contains("Signature=adhoc"))
    }

    /// The identity the update of a copy signed by `current` is re-signed with, nil to keep the signature it was published
    /// with (`published`):
    /// - nothing when both are signed by the same certificate: the release certificate, the usual case;
    /// - the copy's own certificate in the signing keychain: a copy built on this Mac keeps its identity;
    /// - for a version published ad hoc only, the signing keychain's certificate for a copy signed ad hoc or by a
    ///   "Clean My Claude Dev" of the session keychain (set up before the signing keychain). A version published with the
    ///   release certificate is installed as is instead: macOS asks for the permissions once more, then never again;
    /// - the copy's own certificate found in the search list: a setup older than the signing keychain, or HW_SIGN_IDENTITY;
    /// - nothing for a copy signed by a developer certificate from Apple, whose identity is never swapped.
    static func choose(for current: Signer, published: Signer, signing: [Listed], keychain: String, searchList: [Listed]) -> Identity? {
        if let leaf = published.leaf, leaf == current.leaf { return nil }
        if let leaf = current.leaf, signing.contains(where: { $0.hash == leaf }) { return Identity(hash: leaf, keychain: keychain) }
        if published.leaf == nil, current.adhoc || current.authority == name, let own = signing.first(where: { $0.name == name }) {
            return Identity(hash: own.hash, keychain: keychain)
        }
        if let leaf = current.leaf, searchList.contains(where: { $0.hash == leaf }) { return Identity(hash: leaf, keychain: nil) }
        return nil
    }

    /// The identities of the signing keychain, read without unlocking it (`security find-identity` asks nothing).
    static func signingIdentities(in keychain: String = keychainPath) -> [Listed] {
        guard FileManager.default.fileExists(atPath: keychain) else { return [] }
        return identities(in: Shell.run("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain]).out)
    }

    /// The identities of the search list (the session keychain).
    static func searchListIdentities() -> [Listed] {
        identities(in: Shell.run("/usr/bin/security", ["find-identity", "-p", "codesigning"]).out)
    }

    static func signer(of bundle: String) -> Signer {
        signer(display: Shell.run("/usr/bin/codesign", ["-dvv", bundle]).all, requirement: Shell.run("/usr/bin/codesign", ["-d", "-r-", bundle]).all)
    }

    /// What the verified update of a copy signed by `current` is re-signed with. Runs tools: not on the main thread. Unlocks nothing.
    static func identity(current: Signer, published: Signer, keychain: String = keychainPath) -> Identity? {
        choose(for: current, published: published, signing: signingIdentities(in: keychain), keychain: keychain, searchList: searchListIdentities())
    }

    /// What macOS makes of an update: re-signed with the local certificate, published with the certificate of the copy
    /// it replaces (the permissions stay), published with the release certificate when the copy is not (asked once more,
    /// then kept), or published ad hoc (asked again at every update).
    enum Continuity: Equatable {
        case local, kept, firstRelease, adhoc
    }

    /// The update kept with its published signature.
    static func continuity(current: Signer, published: Signer) -> Continuity {
        guard let leaf = published.leaf else { return .adhoc }
        return leaf == current.leaf ? .kept : .firstRelease
    }

    enum Outcome: Equatable {
        case signed, wrongPassword
        case failed(String)
    }

    /// Re-signs `app` with `identity`, keeping the hardened runtime and the entitlements of the published app, and checks
    /// that its designated requirement now pins that certificate. The signing keychain is unlocked with `password`, which
    /// `security` reads on its standard input (never in its arguments, which any program can list), then locked again
    /// right after, whatever happened. macOS's own unlock window is not relied upon: it does not show in every context,
    /// and one left open can keep the keychain refusing its password until the session ends.
    static func sign(_ app: URL, with identity: Identity, password: String? = nil) -> Outcome {
        // Locked again when this function returns (a `defer` inside the `if` below would lock it before codesign runs).
        defer { if let keychain = identity.keychain { _ = Shell.run("/usr/bin/security", ["lock-keychain", keychain], timeout: 10) } }
        if let keychain = identity.keychain {
            guard let password, !password.isEmpty,
                  Shell.run("/usr/bin/security", ["unlock-keychain", keychain], input: password + "\n", timeout: 20).ok else { return .wrongPassword }
        }
        var args = ["--force", "--deep", "--preserve-metadata=entitlements,flags,runtime"]
        if let keychain = identity.keychain { args += ["--keychain", keychain] }
        let sign = Shell.run("/usr/bin/codesign", args + ["--sign", identity.hash, app.path], timeout: 120)
        guard sign.ok else { return .failed(sign.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120).ok,
              UpdatesSelfInstaller.leafHash(fromRequirement: Shell.run("/usr/bin/codesign", ["-d", "-r-", app.path]).all) == identity.hash else {
            return .failed("signature incomplète")
        }
        return .signed
    }

    /// For `--dump`: where the certificate is, and what an update of this copy would be signed with. Asks nothing.
    static func describe(bundle: String?) -> [String] {
        let signing = signingIdentities()
        let searchList = searchListIdentities().filter { $0.name == name }
        var lines = [signing.first(where: { $0.name == name }).map { "Signature locale : « \(name) » (\($0.hash.prefix(8))…) dans son trousseau à part, \(FS.pretty(keychainPath))" }
                     ?? "Signature locale : pas de trousseau de signature (./scripts/setup_signing.sh le crée)"]
        for old in searchList {
            lines.append("⚠︎ « \(name) » (\(old.hash.prefix(8))…) encore dans le trousseau de session : n'importe quel programme peut signer avec lui. Relance ./scripts/setup_signing.sh")
        }
        lines.append(releaseCertificate.map { "Versions publiées : signées par le certificat de publication (\($0.prefix(8))…), gardé tel quel aux mises à jour" }
                     ?? "Versions publiées : signées ad hoc (./scripts/setup_release_signing.sh crée leur certificat)")
        if let bundle {
            let current = signer(of: bundle)
            let signedBy = current.adhoc ? "ad hoc" : current.authority.map { "« \($0) »" + (current.leaf.map { " (\($0.prefix(8))…)" } ?? "") } ?? "non signée"
            let published = Signer(leaf: releaseCertificate, authority: nil, adhoc: releaseCertificate == nil)
            let next = choose(for: current, published: published, signing: signing, keychain: keychainPath, searchList: searchListIdentities())
            let update = next.map { "re-signée avec \($0.hash.prefix(8))…" + ($0.keychain == nil ? " (trousseau de session, sans rien demander)" : " (mot de passe du trousseau demandé)") }
                ?? "signature publiée gardée"
            lines.append("Cette copie : signée \(signedBy) · une mise à jour serait \(update)")
        }
        return lines
    }

    /// Reading `security` and `codesign`, and the choice of the identity.
    static func selfTest() -> [String] {
        var f: [String] = []
        let found = """
        Policy: Code Signing
          Matching identities
          1) C925073CC6FBB4695CB8FF0443813419EBE03239 "Apple Development: Prénom Nom (AB12CD34EF)" (CSSMERR_TP_CERT_EXPIRED)
          2) fd519d2fb27988160f2d2bb57daab256af171bda "Clean My Claude Dev" (CSSMERR_TP_NOT_TRUSTED)
             2 identities found

          Valid identities only
          1) C925073CC6FBB4695CB8FF0443813419EBE03239 "Apple Development: Prénom Nom (AB12CD34EF)"
             1 valid identities found
        """
        let listed = identities(in: found)
        if listed != [Listed(hash: "C925073CC6FBB4695CB8FF0443813419EBE03239", name: "Apple Development: Prénom Nom (AB12CD34EF)"),
                      Listed(hash: "FD519D2FB27988160F2D2BB57DAAB256AF171BDA", name: name)] {
            f.append("Signature locale : identités mal lues (\(listed.map(\.name)))")
        }
        let display = "Executable=/Applications/Heartware.app/Contents/MacOS/Heartware\nIdentifier=io.github.olima34.cleanmyclaude\nAuthority=Clean My Claude Dev\nSignature size=1234\nTeamIdentifier=not set"
        let requirement = #"designated => identifier "io.github.olima34.cleanmyclaude" and certificate leaf = H"fd519d2fb27988160f2d2bb57daab256af171bda""#
        let old = signer(display: display, requirement: requirement)
        if old != Signer(leaf: "FD519D2FB27988160F2D2BB57DAAB256AF171BDA", authority: name, adhoc: false)
            || !signer(display: "Signature=adhoc\nTeamIdentifier=not set", requirement: #"designated => cdhash H"0123456789abcdef0123456789abcdef01234567""#).adhoc {
            f.append("Signature locale : signature de la copie mal lue")
        }

        let kc = "/Users/x/Library/Keychains/cleanmyclaude-signing.keychain-db"
        let fresh = Listed(hash: String(repeating: "7E", count: 20), name: name)
        let legacy = Listed(hash: "FD519D2FB27988160F2D2BB57DAAB256AF171BDA", name: name)
        let adhoc = Signer(leaf: nil, authority: nil, adhoc: true)
        let mine = Signer(leaf: fresh.hash, authority: name, adhoc: false)
        let apple = Signer(leaf: nil, authority: "Apple Development: Prénom Nom (AB12CD34EF)", adhoc: false)
        let custom = Signer(leaf: String(repeating: "AB", count: 20), authority: "Mon certificat", adhoc: false)
        let release = Signer(leaf: String(repeating: "5C", count: 20), authority: "Clean My Claude", adhoc: false)
        for (current, published, signing, searchList, expected, what) in [
            (mine, adhoc, [fresh], [], Identity(hash: fresh.hash, keychain: kc), "copie signée avec le trousseau à part"),
            (old, adhoc, [fresh], [legacy], Identity(hash: fresh.hash, keychain: kc), "copie signée avec l'ancien certificat, trousseau à part créé"),
            (old, adhoc, [fresh], [], Identity(hash: fresh.hash, keychain: kc), "ancien certificat supprimé"),
            (adhoc, adhoc, [fresh], [legacy], Identity(hash: fresh.hash, keychain: kc), "copie publiée (ad hoc)"),
            (old, adhoc, [], [legacy], Identity(hash: legacy.hash, keychain: nil), "ancienne installation, sans trousseau à part"),
            (adhoc, adhoc, [], [legacy], nil, "copie publiée sans trousseau à part"),
            (apple, adhoc, [fresh], [], nil, "copie signée par un certificat d'Apple"),
            (custom, adhoc, [fresh], [Listed(hash: custom.leaf!, name: "Mon certificat")], Identity(hash: custom.leaf!, keychain: nil), "HW_SIGN_IDENTITY"),
            (old, adhoc, [], [], nil, "aucun certificat"),
            // Published with the release certificate: kept as is, without a password, except on a copy built on this Mac.
            (release, release, [fresh], [legacy], nil, "copie publiée, version publiée avec le même certificat"),
            (adhoc, release, [fresh], [legacy], nil, "copie publiée ad hoc, version publiée avec le certificat de publication"),
            (old, release, [fresh], [], nil, "copie à l'ancien certificat supprimé, version publiée avec le certificat de publication"),
            (mine, release, [fresh], [], Identity(hash: fresh.hash, keychain: kc), "copie compilée ici, version publiée avec le certificat de publication"),
            (old, release, [], [legacy], Identity(hash: legacy.hash, keychain: nil), "ancienne installation, version publiée avec le certificat de publication")
        ] as [(Signer, Signer, [Listed], [Listed], Identity?, String)]
        where choose(for: current, published: published, signing: signing, keychain: kc, searchList: searchList) != expected {
            f.append("Signature locale : mauvaise identité pour une \(what)")
        }
        // Read by the CI from its line: the SHA-1 of a certificate, in upper case.
        if let releaseCertificate, releaseCertificate.count != 40 || !releaseCertificate.allSatisfy({ $0.isHexDigit && !$0.isLowercase }) {
            f.append("Certificat de publication illisible : \(releaseCertificate)")
        }
        return f
    }
}
