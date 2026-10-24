import Foundation

/// `Heartware --update-check [--as-version 0.2.0] [--as-commit <sha>]` asks GitHub exactly like the app does and
/// prints the answer. `--update-install "<…/Heartware.app>"` also downloads the new version, checks it and puts it
/// in place of that copy (the old one goes to the Trash), without opening anything: the update tested end to end
/// on a throwaway copy, never on the running app.
enum UpdatesSelfCLI {
    static func run() async {
        guard !DemoData.isEnabled else {
            print(HTTP.Failure.demo.localizedDescription)
            return
        }
        var build = UpdatesSelfBuild.current
        var target: URL?
        if let path = Entry.value(after: "--update-install") {
            let url = URL(fileURLWithPath: FS.expand(path)).standardizedFileURL
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == UpdatesSelfInstaller.bundleID else {
                print("✗ \(url.path) n'est pas une copie de Heartware.")
                return
            }
            target = url
            build = UpdatesSelfBuild(version: info["CFBundleShortVersionString"] as? String,
                                     commit: (info["HeartwareCommit"] as? String).flatMap { UpdatesSelfGitHub.isCommit($0) ? $0 : nil },
                                     bundlePath: url.path)
        }
        if let v = Entry.value(after: "--as-version") {
            build.version = v
            build.commit = nil
        }
        if let c = Entry.value(after: "--as-commit") { build.commit = c }
        print("Copie comparée : \(build.label) · \(FS.pretty(build.bundlePath))")

        let result: (latest: UpdatesSelfRelease, isUpdate: Bool)
        do {
            result = try await UpdatesSelfGitHub.check(build)
        } catch {
            print("✗ \(UpdatesSelfGitHub.message(for: error))")
            return
        }
        let r = result.latest
        print("Dernière version publiée : \(r.version) (\(r.tag))" + (r.published.map { ", le \(Fmt.day($0))" } ?? ""))
        print("  Archive : \(r.downloadURL ?? "aucune") · \(Fmt.bytes(r.size)) · \(r.digest ?? "pas d'empreinte") · signature \(r.signatureURL == nil ? "absente" : "publiée")")
        guard result.isUpdate else {
            print("→ À jour : rien à installer.")
            return
        }
        print("→ Mise à jour disponible, \(Fmt.plural(r.changeCount, "changement", "changements")) :")
        for c in r.changes {
            print("  • \(c.title.topic.map { "[\($0)] " } ?? "")\(c.title.text)")
            for d in c.details { print("      - \(d.topic.map { "\($0) : " } ?? "")\(d.text)") }
        }
        if r.moreChanges > 0 { print("  … et \(r.moreChanges) de plus sur GitHub") }
        guard let target else { return }

        let readOnly = (try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let fm = FileManager.default
        switch UpdatesSelfInstaller.place(bundlePath: target.path, readOnly: readOnly,
                                          writable: fm.isWritableFile(atPath: target.deletingLastPathComponent().path)
                                              && fm.isWritableFile(atPath: target.path)) {
        case .blocked(let why):
            print("✗ \(why)")
            return
        case .applications:
            print("✗ Cette copie ne se remplace pas sur place (image disque, volume en lecture seule) : ouverte, l'app installerait la nouvelle version dans Applications. Essaie sur une copie dans un dossier modifiable.")
            return
        case .inPlace:
            break
        }
        guard let link = r.downloadURL else {
            print("✗ Cette version n'a pas d'archive à installer.")
            return
        }
        guard UpdatesSelfGitHub.isTrustedDownload(link), let url = URL(string: link) else {
            print("✗ \(UpdatesSelfInstaller.Failure.untrusted.localizedDescription)")
            return
        }
        guard r.digest != nil else {
            print("✗ \(UpdatesSelfInstaller.Failure.noDigest.localizedDescription)")
            return
        }
        guard let base = DataStore.ensureFolder(UpdatesSelfInstaller.folderName),
              let folder = try? FileOps.makeDirectory(base.appendingPathComponent("\(r.version) (essai)")) else {
            print("✗ Impossible de préparer le dossier de téléchargement.")
            return
        }
        defer { Remover.removeInternal(folder.path) }
        do {
            print("→ Téléchargement de \(link)")
            let zip = try await HTTP.download(url, into: folder, name: UpdatesSelfGitHub.assetName) { received, expected in
                print("   \(Fmt.bytes(received)) sur \(Fmt.bytes(expected))")
            }
            let signature = try await UpdatesSelfSignature.fetch(for: r)
            print("→ Vérification : empreinte comparée à celle de GitHub, "
                  + (UpdatesSelfSignature.publicKey == nil ? "signature Ed25519 pas encore exigée" : "signature Ed25519") + ", contenu, signature de l'app")
            let app = try UpdatesSelfInstaller.prepare(zip: zip, folder: folder, release: r, signature: signature, isCancelled: { false })
            // `--signing-keychain <fichier>`: a throwaway signing keychain, for the tests.
            let keychain = Entry.value(after: "--signing-keychain").map { FS.expand($0) } ?? UpdatesSelfSigning.keychainPath
            let current = UpdatesSelfSigning.signer(of: target.path), published = UpdatesSelfSigning.signer(of: app.path)
            if let identity = UpdatesSelfSigning.identity(current: current, published: published, keychain: keychain) {
                print("→ Re-signature avec le certificat local \(identity.hash.prefix(8))…" + (identity.keychain == nil ? " (trousseau de session)" : ""))
                let password = identity.keychain == nil ? nil : askPassword()
                switch UpdatesSelfSigning.sign(app, with: identity, password: password) {
                case .signed: print("  Re-signée : elle garde l'exigence désignée de la copie remplacée")
                case .wrongPassword: throw UpdatesSelfInstaller.Failure.signingPassword
                case .failed(let why): throw UpdatesSelfInstaller.Failure.localSign(why)
                }
            } else {
                switch UpdatesSelfSigning.continuity(current: current, published: published) {
                case .kept: print("  Signature publiée gardée : même certificat que la copie remplacée (\(published.leaf?.prefix(8) ?? "?")…)")
                case .firstRelease: print("  Signature publiée gardée : certificat de publication \(published.leaf?.prefix(8) ?? "?")…, nouveau pour cette copie")
                case .adhoc, .local: print("  Signature publiée gardée (ad hoc)")
                }
            }
            print("→ Remplacement : l'ancienne copie part à la Corbeille")
            let installed = try UpdatesSelfInstaller.replace(target, with: app)
            let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            print("✓ \(installed.path) est maintenant en version \(info?["CFBundleShortVersionString"] as? String ?? "?")")
        } catch {
            print("✗ \(UpdatesSelfGitHub.message(for: error))")
        }
    }

    /// The password of the signing keychain, typed in the Terminal without echo (or read on the standard input).
    private static func askPassword() -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        defer { buffer.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let typed = readpassphrase("  Mot de passe du trousseau de signature (celui choisi avec setup_signing.sh) : ", &buffer, buffer.count, 0) else {
            return nil
        }
        return String(cString: typed)
    }
}
