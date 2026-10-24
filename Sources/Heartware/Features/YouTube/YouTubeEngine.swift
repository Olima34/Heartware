import Foundation
import ImageIO

/// The command line tools the module needs: yt-dlp (reads YouTube), ffmpeg (joins image and sound, cuts, makes MP3),
/// and Homebrew to install them.
struct YouTubeTools: Equatable {
    var ytdlp: String?
    var ffmpeg: String?
    var brew: String?

    var ready: Bool { ytdlp != nil && ffmpeg != nil }

    /// What `brew install` has to add.
    var missing: [String] { [ytdlp == nil ? "yt-dlp" : nil, ffmpeg == nil ? "ffmpeg" : nil].compactMap { $0 } }

    static func find() -> YouTubeTools {
        if DemoData.isEnabled { return YouTubeTools(ytdlp: "/opt/homebrew/bin/yt-dlp", ffmpeg: "/opt/homebrew/bin/ffmpeg", brew: "/opt/homebrew/bin/brew") }
        return YouTubeTools(ytdlp: Shell.which("yt-dlp"), ffmpeg: Shell.which("ffmpeg"), brew: Shell.which("brew"))
    }
}

/// Everything that talks to YouTube or to yt-dlp, and the pure rules behind it (tested by `selfTest`).
enum YouTubeEngine {
    // MARK: Reading a video

    /// The title and the channel in a fraction of a second (YouTube's oEmbed), before yt-dlp has answered.
    static func oembed(_ id: String) async -> (title: String, channel: String)? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)")]
        guard let url = comps.url, let (data, _) = try? await HTTP.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String else { return nil }
        return (title, json["author_name"] as? String ?? "")
    }

    /// The video's picture: the large one when the channel uploaded it, YouTube's own otherwise.
    static func thumbnail(_ id: String) async -> CGImage? {
        for name in ["maxresdefault", "hqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg"),
                  let (data, _) = try? await HTTP.get(url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }

    /// yt-dlp's description of the video: duration, date, and every stream with its size. Blocks: call it off the main thread.
    static func probe(_ id: String, ytdlp: String) -> Result<YouTubeInfo, YouTubeFailure> {
        guard YouTubeLink.isVideoID(id) else { return .failure(YouTubeFailure(message: "Lien YouTube invalide.")) }
        let r = Shell.run(ytdlp, ["--ignore-config", "-J", "--no-playlist", "--no-warnings", "https://www.youtube.com/watch?v=\(id)"],
                          env: ["PYTHONUNBUFFERED": "1"], timeout: 90)
        if let info = parseInfo(Data(r.out.utf8)) { return .success(info) }
        let error = r.err.split(separator: "\n").last { $0.hasPrefix("ERROR:") }.map(String.init) ?? r.err
        return .failure(friendly(error.isEmpty ? "yt-dlp n'a rien répondu (code \(r.status))." : error))
    }

    /// `yt-dlp -J` → the video (nil when the text is not that JSON).
    static func parseInfo(_ data: Data) -> YouTubeInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let title = json["title"] as? String else { return nil }
        var info = YouTubeInfo(id: id, title: title,
                               channel: (json["channel"] as? String) ?? (json["uploader"] as? String) ?? "")
        info.duration = (json["duration"] as? NSNumber)?.doubleValue
        info.views = (json["view_count"] as? NSNumber)?.intValue
        info.isLive = (json["is_live"] as? Bool) == true || (json["live_status"] as? String) == "is_upcoming"
        if let d = json["upload_date"] as? String, d.count == 8 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd"
            info.uploaded = f.date(from: d)
        }
        for f in json["formats"] as? [[String: Any]] ?? [] {
            guard let fid = f["format_id"] as? String else { continue }
            // The "-drc" copies (compressed loudness) and storyboards are not what anyone wants to keep.
            if fid.hasSuffix("-drc") || (f["ext"] as? String) == "mhtml" { continue }
            info.streams.append(YouTubeStream(
                formatID: fid, ext: f["ext"] as? String ?? "",
                vcodec: f["vcodec"] as? String, acodec: f["acodec"] as? String,
                height: (f["height"] as? NSNumber)?.intValue,
                size: ((f["filesize"] as? NSNumber) ?? (f["filesize_approx"] as? NSNumber))?.int64Value,
                bitrate: (f["tbr"] as? NSNumber)?.doubleValue))
        }
        info.detailed = true
        return info
    }

    // MARK: Choosing the streams

    /// The video track yt-dlp will pick for `quality` (the same rules as `arguments`): the tallest under the limit,
    /// H.264 first at equal height so that QuickTime, Photos and iMovie read the file.
    static func videoStream(_ info: YouTubeInfo, quality: YouTubeQuality) -> YouTubeStream? {
        let videos = info.streams.filter { $0.hasVideo && $0.height != nil }
        let separate = videos.filter { !$0.hasAudio }
        let pool = separate.isEmpty ? videos : separate
        let limit = quality.height ?? Int.max
        let fitting = pool.filter { ($0.height ?? 0) <= limit }
        let candidates = fitting.isEmpty ? pool : fitting
        return candidates.max { a, b in
            let ka = (a.height ?? 0, a.isH264 ? 1 : 0, a.size ?? 0), kb = (b.height ?? 0, b.isH264 ? 1 : 0, b.size ?? 0)
            return ka < kb
        }
    }

    /// The sound track: AAC (.m4a) first, the richest one.
    static func audioStream(_ info: YouTubeInfo) -> YouTubeStream? {
        let audios = info.streams.filter { $0.hasAudio && !$0.hasVideo }
        return audios.max { a, b in
            ((a.ext == "m4a" ? 1 : 0), a.bitrate ?? 0) < ((b.ext == "m4a" ? 1 : 0), b.bitrate ?? 0)
        }
    }

    /// The size of the file, roughly (nil until yt-dlp has listed the streams).
    static func estimate(_ info: YouTubeInfo, options: YouTubeOptions, clip: YouTubeClip?) -> Int64? {
        guard info.detailed, let duration = info.duration, duration > 0 else { return nil }
        var total: Int64
        switch options.format {
        case .mp4:
            guard let video = videoStream(info, quality: options.quality), let v = video.bytes(duration: duration) else { return nil }
            total = v + (video.hasAudio ? 0 : (audioStream(info)?.bytes(duration: duration) ?? 0))
        case .m4a:
            guard let a = audioStream(info)?.bytes(duration: duration) else { return nil }
            total = a
        case .mp3:
            // Best variable bitrate (V0): about 245 kbit/s.
            total = Int64(245_000 / 8 * duration)
        }
        if let clip { total = Int64(Double(total) * min(1, clip.length / duration)) }
        return total
    }

    // MARK: Downloading

    /// Lines the module asks yt-dlp to print, so that its output can be read without guessing.
    static let progressTag = "HWP"
    static let selectionTag = "HWSEL"
    static let fileTag = "HWFILE"

    /// The whole yt-dlp command line of a download, into `workFolder` (inside the app's own folder).
    static func arguments(videoID: String, options: YouTubeOptions, clip: YouTubeClip?, ffmpeg: String, workFolder: String) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--newline", "--color", "never", "--no-mtime", "--embed-metadata",
                    "--ffmpeg-location", ffmpeg, "-P", workFolder, "-o", "%(id)s.%(ext)s",
                    "--progress", "--progress-template",
                    "download:\(progressTag) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
                    "--print", "before_dl:\(selectionTag) %(format_id)s",
                    "--print", "after_move:\(fileTag) %(filepath)s"]
        switch options.format {
        case .mp4:
            // The tallest picture under the limit, then H.264 + AAC: what every Apple app plays.
            let res = options.quality.height.map { "res:\($0)" } ?? "res"
            args += ["-f", "bv*+ba/b", "-S", "\(res),vcodec:h264,acodec:m4a", "--merge-output-format", "mp4"]
        case .mp3:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0", "--embed-thumbnail"]
        case .m4a:
            args += ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a", "--embed-thumbnail"]
        }
        if let clip {
            // An extract is cut by ffmpeg, which yt-dlp keeps quiet: asked for its position, it tells where it is
            // twice a second (out_time_us=…, speed=…x), the only way to show how far the cut has gone.
            args += ["--download-sections", clip.section, "--force-keyframes-at-cuts",
                     "--downloader-args", "ffmpeg_o:-progress pipe:1 -nostats"]
        }
        return args + ["https://www.youtube.com/watch?v=\(videoID)"]
    }

    enum Event: Equatable {
        /// The format IDs yt-dlp chose ("137+140": a video track then a sound track).
        case selected([String])
        case progress(done: Int64, total: Int64?, speed: Double?, eta: Double?)
        /// ffmpeg cutting an extract: how many seconds of it are written, and how many times faster than real time.
        case cutTime(Double)
        case cutSpeed(Double)
        case file(String)
        case error(String)
    }

    static func parse(_ line: String) -> Event? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix(progressTag + " ") {
            let f = l.dropFirst(progressTag.count + 1).split(separator: " ").map { Double($0) }
            guard f.count >= 5, let done = f[0] else { return nil }
            let total = f[1] ?? f[2]
            return .progress(done: Int64(done), total: total.map { Int64($0) }, speed: f[3], eta: f[4])
        }
        if l.hasPrefix(selectionTag + " ") {
            return .selected(l.dropFirst(selectionTag.count + 1).split(separator: "+").map(String.init))
        }
        if l.hasPrefix(fileTag + " ") { return .file(String(l.dropFirst(fileTag.count + 1))) }
        // ffmpeg's -progress lines ("N/A" before the first frame).
        if l.hasPrefix("out_time_us="), let us = Double(l.dropFirst("out_time_us=".count)), us >= 0 { return .cutTime(us / 1_000_000) }
        if l.hasPrefix("speed="), l.hasSuffix("x"), let x = Double(l.dropFirst("speed=".count).dropLast()), x > 0 { return .cutSpeed(x) }
        if l.hasPrefix("ERROR:") { return .error(l) }
        return nil
    }

    /// The name of the saved file: the video's title, the extract if any ("Titre (extrait 1’05–2’30).mp4").
    static func fileName(title: String, clip: YouTubeClip?, ext: String) -> String {
        var name = title.unicodeScalars.map { s -> String in
            if CharacterSet.controlCharacters.contains(s) { return " " }
            return ["/", ":", "\\"].contains(String(s)) ? "-" : String(s)
        }.joined()
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 140 { name = String(name.prefix(140)).trimmingCharacters(in: .whitespaces) + "…" }
        if name.isEmpty { name = "Vidéo YouTube" }
        if let clip {
            let mark = { (s: Double) in YouTubeTime.format(s).replacingOccurrences(of: ":", with: "’") }
            name += " (extrait \(mark(clip.start))–\(mark(clip.end)))"
        }
        return name + "." + ext
    }

    /// yt-dlp's English error, said simply. `update`: a newer yt-dlp is the likely cure.
    static func friendly(_ raw: String) -> YouTubeFailure {
        let e = raw.lowercased()
        let cases: [(keys: [String], message: String, update: Bool)] = [
            (["private video"], "Cette vidéo est privée : seul son auteur peut la voir.", false),
            (["confirm your age", "age-restricted", "inappropriate for some users"], "Vidéo réservée aux adultes : YouTube demande d'être connecté pour la voir.", false),
            (["members-only", "join this channel"], "Vidéo réservée aux membres de la chaîne.", false),
            (["not a bot"], "YouTube demande de prouver que tu n'es pas un robot. Réessaie dans quelques minutes, ou mets yt-dlp à jour.", true),
            (["live event will begin", "premieres in", "is_upcoming"], "Ce direct ou cette première n'a pas encore commencé.", false),
            (["not available in your country", "blocked it in your country", "geo restrict"], "Cette vidéo n'est pas disponible dans ton pays.", false),
            (["video unavailable", "this video is unavailable", "has been removed", "no longer available"], "Vidéo introuvable : supprimée, privée ou mal copiée.", false),
            (["unable to download webpage", "urlopen error", "timed out", "network is unreachable", "name or service not known", "nodename nor servname"], "Pas de connexion à YouTube. Vérifie ta connexion Internet.", false),
            (["requested format is not available", "nsig", "signature", "unable to extract", "http error 403", "precondition check failed", "javascript runtime"], "YouTube a changé quelque chose : mets yt-dlp à jour, c'est en général réglé.", true),
            (["no space left"], "Plus de place sur le disque.", false),
            (["ffmpeg", "ffprobe"], "ffmpeg n'a pas pu assembler le fichier. Installe-le ou mets-le à jour avec Homebrew.", false)
        ]
        for c in cases where c.keys.contains(where: e.contains) { return YouTubeFailure(message: c.message, suggestsUpdate: c.update) }
        // "ERROR: [youtube] abc: Something" → "Something".
        var text = raw.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: #"^\[[^\]]+\]\s*[A-Za-z0-9_-]{11}:\s*"#, options: .regularExpression) { text.removeSubrange(r) }
        return YouTubeFailure(message: text.isEmpty ? "Le téléchargement a échoué." : "yt-dlp : " + text, suggestsUpdate: false)
    }
}

struct YouTubeFailure: Error, Equatable {
    var message: String
    var suggestsUpdate = false
}

/// Turns the stream of progress lines into at most four updates a second for the main thread.
final class YouTubeThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    /// True when an update may go now (`force`: a change of step always goes).
    func due(force: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 0.25 else { return false }
        last = now
        return true
    }
}
