import Foundation

/// `Heartware --xprotect [chemin…]`: compiles Apple's signatures, says which rules are understood,
/// then scans the given files or folders (read only).
enum ProtectionCLI {
    static func run(_ args: [String]) {
        let t = Date()
        guard let sig = ProtectionSignatures.load() else {
            print("✗ signatures XProtect introuvables")
            return
        }
        print(String(format: "XProtect %d (%@) : %d règles comprises, %d ignorées, compilées en %.2f s",
                      sig.version, sig.bundlePath, sig.ruleCount, sig.skipped.count, Date().timeIntervalSince(t)))
        if args.contains("--skipped") { for s in sig.skipped { print("  ignorée : \(s)") } }
        if args.contains("--check") {
            let c = Date()
            let failures = ProtectionYaraChecks.run()
            let (tried, missed) = ProtectionYaraChecks.synthesize(sig.binary)
            print(String(format: "Autotests du moteur : %d échecs, échantillons Apple %d/%d reconnus (%.1f s)",
                         failures.count, tried - missed.count, tried, Date().timeIntervalSince(c)))
            for m in failures { print("  ✗ \(m)") }
            for m in missed.prefix(30) { print("  manquée : \(m)") }
        }
        if let i = args.firstIndex(of: "--inspect"), i + 1 < args.count {
            let v = ProtectionThreatScanner.inspect(FS.expand(args[i + 1]))
            print("\(v.status.label) · \(v.title) — \(v.detail) (\(v.files) fichiers)")
            return
        }
        if args.contains("--threats") || args.contains("--threats-deep") {
            let deep = args.contains("--threats-deep")
            let t0 = Date()
            let items = LaunchItemScanner.scan()
            let progress = ProtectionScanProgress()
            guard let r = ProtectionThreatScanner.scan(deep: deep, launchItems: items, flag: CancelFlag(), progress: progress) else {
                print("✗ analyse impossible")
                return
            }
            print(String(format: "Analyse %@ : %d fichiers en %.1f s, %d menaces, %d à examiner", deep ? "complète" : "rapide",
                         r.summary.files, Date().timeIntervalSince(t0), r.threats.filter { $0.status == .bad }.count,
                         r.threats.filter { $0.status != .bad }.count))
            for t in r.threats { print("  \(t.status.label) [\(t.kind.title)] \(t.name) — \(t.path)") }
            return
        }
        var files = 0, read = 0, hits = 0
        let start = Date()
        for root in args where root.hasPrefix("/") || root.hasPrefix("~") {
            let path = FS.expand(root)
            var list: [String] = []
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(atPath: path)
                while let rel = e?.nextObject() as? String { list.append(path + "/" + rel) }
            } else {
                list = [path]
            }
            for f in list {
                files += 1
                guard ProtectionSignatureScanner.probe(f) != nil else { continue }
                read += 1
                let ft = Date()
                let found = ProtectionSignatureScanner.scan(f, with: sig)
                let dt = Date().timeIntervalSince(ft)
                if dt > 0.5 { print(String(format: "  lent (%.2f s) : %@", dt, f)) }
                for h in found {
                    hits += 1
                    print("  ⚠︎ \(h.detection) [\(h.rule)] \(f)")
                }
            }
        }
        if files > 0 {
            print(String(format: "%d fichiers, %d analysés, %d détections, %.1f s", files, read, hits, Date().timeIntervalSince(start)))
        }
    }
}
