import Foundation

// MARK: - Archives

/// ZIP with `ditto` (like the Finder) or `zip` for several items; extraction with `ditto` or `bsdtar`, always into a new folder.
enum ConverterArchiveEngine {
    static let tarExtensions: Set<String> = ["tar", "tgz", "tbz", "tbz2", "txz", "7z", "rar", "cpio", "xar"]

    /// "photos.tar.gz" → "photos", "rapport.zip" → "rapport".
    static func baseName(_ name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if ["tar"].contains((base as NSString).pathExtension.lowercased()) { base = (base as NSString).deletingPathExtension }
        return base.isEmpty ? name : base
    }

    /// The deepest folder containing every item.
    static func commonParent(_ urls: [URL]) -> URL {
        let paths = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = paths.first else { return URL(fileURLWithPath: "/") }
        for p in paths.dropFirst() {
            var n = 0
            while n < common.count, n < p.count, common[n] == p[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        return URL(fileURLWithPath: common.isEmpty ? "/" : NSString.path(withComponents: common))
    }

    static func zip(_ inputs: [URL], mode: ConverterZipMode, folder: URL?, control: ConverterControl) async throws -> [URL] {
        control.progress(nil)
        if mode == .each || inputs.count == 1 {
            var outs: [URL] = []
            for input in inputs {
                try control.check()
                let out = FileOps.uniqueURL((folder ?? input.deletingLastPathComponent()).appendingPathComponent(input.lastPathComponent + ".zip"))
                try await run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, out.path], output: out, control: control)
                outs.append(out)
            }
            return outs
        }
        let parent = commonParent(inputs)
        let out = FileOps.uniqueURL((folder ?? parent).appendingPathComponent("Archive.zip"))
        let prefix = parent.standardizedFileURL.path == "/" ? "/" : parent.standardizedFileURL.path + "/"
        let relative = inputs.map { "./" + $0.standardizedFileURL.path.dropFirst(prefix.count) }
        let script = #"cd "$1" || exit 1; out="$2"; shift 2; exec /usr/bin/zip -q -r -y "$out" "$@" -x "*.DS_Store" -x "__MACOSX/*""#
        try await run("/bin/sh", ["-c", script, "sh", parent.path, out.path] + relative, output: out, control: control)
        return [out]
    }

    static func extract(_ input: URL, folder: URL?, control: ConverterControl) async throws -> URL {
        control.progress(nil)
        let dir = folder ?? input.deletingLastPathComponent()
        let name = input.lastPathComponent.lowercased()
        let ext = input.pathExtension.lowercased()
        let isTar = name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") || tarExtensions.contains(ext)

        // A single compressed file (data.csv.gz): decompressed next to it.
        if !isTar && ["gz", "bz2", "xz"].contains(ext) {
            let tool = ext == "gz" ? "/usr/bin/gzcat" : (ext == "bz2" ? "/usr/bin/bzcat" : Shell.which("xz"))
            guard let tool else { throw ConverterError.unsupported("Le .xz seul demande l'outil xz (brew install xz).") }
            let out = FileOps.uniqueURL(dir.appendingPathComponent((input.lastPathComponent as NSString).deletingPathExtension))
            let args = ext == "xz" ? ["-dc"] : []
            let script = #"tool="$1"; out="$2"; shift 2; "$tool" "$@" > "$out""#
            try await run("/bin/sh", ["-c", script, "sh", tool, out.path] + args + [input.path], output: out, control: control)
            return out
        }

        let dest = FileOps.uniqueURL(dir.appendingPathComponent(baseName(input.lastPathComponent)))
        if ext == "zip" {
            try await run("/usr/bin/ditto", ["-x", "-k", input.path, dest.path], output: dest, control: control)
        } else {
            let script = #"mkdir -p "$2" && exec /usr/bin/tar -xf "$1" -C "$2""#
            try await run("/bin/sh", ["-c", script, "sh", input.path, dest.path], output: dest, control: control)
        }
        return flattened(dest)
    }

    /// "rapport/rapport/…" becomes "rapport/…" when the archive held a single folder.
    private static func flattened(_ dest: URL) -> URL {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dest.path).filter({ $0 != "__MACOSX" && $0 != ".DS_Store" }),
              items.count == 1, FS.isDirectory(dest.appendingPathComponent(items[0]).path),
              Remover.isSafe(dest.path), !DemoData.isEnabled else { return dest }
        let rest = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        guard rest.count == items.count else { return dest }
        let child = dest.appendingPathComponent(items[0])
        let parent = dest.deletingLastPathComponent()
        do {
            // Moved out under a temporary name, then the empty folder goes and the child keeps its own name
            // (like Archive Utility).
            let parked = try FileOps.move(child, to: parent.appendingPathComponent(".hw-\(UUID().uuidString.prefix(8))"))
            _ = Remover.remove([RemovalEntry(path: dest.path, size: 0)], mode: .delete)
            return try FileOps.rename(parked, to: items[0])
        } catch {
            return dest
        }
    }

    private static func run(_ tool: String, _ args: [String], output: URL, control: ConverterControl) async throws {
        let result = await Task.detached(priority: .userInitiated) {
            Shell.stream(tool, args, isCancelled: { control.isCancelled }) { _ in }
        }.value
        if control.isCancelled {
            ConverterOutputs.discard(output)
            throw ConverterError.cancelled
        }
        guard result.ok, FileManager.default.fileExists(atPath: output.path) else {
            ConverterOutputs.discard(output)
            throw ConverterError.failed(ConverterMediaEngine.lastLines(result.out) ?? "L'archive n'a pas pu être traitée.")
        }
        FileOps.didCreate(output)
        control.progress(1)
    }
}

// MARK: - Batch renaming

/// One line of the renaming preview.
struct ConverterRenamePreview: Identifiable, Equatable {
    var id: UUID
    var url: URL
    var newName: String
    /// Another file already has this name: a number will be added.
    var conflict: Bool

    var unchanged: Bool { newName == url.lastPathComponent }
}

enum ConverterRename {
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    static let tokens: [(token: String, label: String)] = [
        ("{nom}", "Nom actuel"), ("{n}", "Numéro"), ("{n:3}", "Numéro 001"), ("{date}", "Date"), ("{heure}", "Heure"), ("{dossier}", "Dossier")
    ]

    /// The new name of the `index`-th file (extension kept).
    static func newName(name: String, isDirectory: Bool, folderName: String, index: Int, date: Date?, rule: ConverterRenameRule) -> String {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        var base = isDirectory || ext.isEmpty ? name : (name as NSString).deletingPathExtension
        if !rule.find.isEmpty {
            base = base.replacingOccurrences(of: rule.find, with: rule.replace, options: [.caseInsensitive])
        }
        let number = rule.start + index
        var out = ""
        var rest = Substring(rule.pattern.isEmpty ? "{nom}" : rule.pattern)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                rest = ""
                break
            }
            let token = rest[rest.index(after: open)..<close].lowercased()
            switch token {
            case "nom", "name": out += base
            case "n": out += String(number)
            case "date": out += dayFormat.string(from: date ?? Date())
            case "heure", "time": out += timeFormat.string(from: date ?? Date())
            case "dossier", "folder": out += folderName
            case "ext": out += ext
            default:
                if token.hasPrefix("n:"), let width = Int(token.dropFirst(2)), (1...9).contains(width) {
                    let s = String(number)
                    out += String(repeating: "0", count: max(0, width - s.count)) + s
                } else {
                    out += rest[open...close]
                }
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        switch rule.caseMode {
        case .unchanged: break
        case .lower: out = out.lowercased()
        case .upper: out = out.uppercased()
        case .capitalized: out = out.prefix(1).uppercased() + out.dropFirst().lowercased()
        }
        out = sanitize(out)
        let finalExt = rule.lowercaseExtension ? ext.lowercased() : ext
        while (out + "." + finalExt).utf8.count > 250 { out.removeLast() }
        return finalExt.isEmpty ? out : out + "." + finalExt
    }

    /// No slash, no colon, no leading dot or spaces; never empty.
    static func sanitize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "Sans titre" : out
    }

    static func preview(_ files: [ConverterFile], rule: ConverterRenameRule) -> [ConverterRenamePreview] {
        let fm = FileManager.default
        let sources = Set(files.map { $0.url.standardizedFileURL.path.lowercased() })
        var taken = Set<String>()
        return files.enumerated().map { index, file in
            let name = newName(name: file.name, isDirectory: file.kind == .folder,
                               folderName: file.url.deletingLastPathComponent().lastPathComponent,
                               index: index, date: file.date, rule: rule)
            let target = file.url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path.lowercased()
            var conflict = !taken.insert(target).inserted
            if !conflict, name != file.name, !sources.contains(target), !DemoData.isEnabled {
                conflict = fm.fileExists(atPath: target)
            }
            return ConverterRenamePreview(id: file.id, url: file.url, newName: name, conflict: conflict)
        }
    }

    /// {date} and {heure} read each file's own date: renaming waits until it is known (else today's date would be used).
    static func needsDates(_ rule: ConverterRenameRule) -> Bool {
        let pattern = rule.pattern.lowercased()
        return ["{date}", "{heure}", "{time}"].contains { pattern.contains($0) }
    }

    /// A file waiting under a hidden temporary name (its new name belongs to another file of the batch).
    private typealias Parked = (temp: URL, original: URL, newName: String)

    /// Renames through `FileOps` (never over an existing file). Names that belong to another file of the batch
    /// (swaps, case changes) go through a temporary name first. A failure or a cancel puts everything back
    /// (the renames already done undone, the hidden files under their old names) before it is reported.
    static func apply(_ items: [(url: URL, newName: String)], control: ConverterControl) throws -> [ConverterRenamePair] {
        var done: [ConverterRenamePair] = []
        var parked: [Parked] = []
        do {
            try rename(items, control: control, done: &done, parked: &parked)
            return done
        } catch {
            rollBack(done: done, parked: parked)
            throw error
        }
    }

    private static func rename(_ items: [(url: URL, newName: String)], control: ConverterControl,
                               done: inout [ConverterRenamePair], parked: inout [Parked]) throws {
        let sources = Set(items.map { $0.url.standardizedFileURL.path.lowercased() })
        let total = Double(max(1, items.count))
        for (n, item) in items.enumerated() where item.newName != item.url.lastPathComponent {
            try control.check()
            let target = item.url.deletingLastPathComponent().appendingPathComponent(item.newName).standardizedFileURL.path.lowercased()
            if sources.contains(target) {
                let temp = try FileOps.rename(item.url, to: ".hw-\(UUID().uuidString.prefix(8))-\(item.url.lastPathComponent)")
                parked.append((temp, item.url, item.newName))
            } else {
                done.append(ConverterRenamePair(from: item.url, to: try FileOps.rename(item.url, to: item.newName)))
            }
            control.progress(Double(n + 1) / total * (parked.isEmpty ? 1 : 0.5))
        }
        let waiting = parked
        for (n, p) in waiting.enumerated() {
            done.append(ConverterRenamePair(from: p.original, to: try FileOps.rename(p.temp, to: p.newName)))
            parked.removeFirst()
            control.progress(0.5 + Double(n + 1) / Double(waiting.count) * 0.5)
        }
    }

    /// The inverse renaming, through the same two steps (a swap already done goes back through a temporary name too).
    private static func rollBack(done: [ConverterRenamePair], parked: [Parked]) {
        let back = done.reversed().map { (url: $0.to, newName: $0.from.lastPathComponent) }
            + parked.map { (url: $0.temp, newName: $0.original.lastPathComponent) }
        guard !back.isEmpty else { return }
        var undone: [ConverterRenamePair] = []
        var stuck: [Parked] = []
        do {
            try rename(back, control: ConverterControl { _ in }, done: &undone, parked: &stuck)
        } catch {
            // Last resort: nothing stays hidden under a temporary name.
            for p in stuck { _ = try? FileOps.rename(p.temp, to: p.newName) }
        }
    }
}
