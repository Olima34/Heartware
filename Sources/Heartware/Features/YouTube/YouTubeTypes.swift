import SwiftUI

// MARK: - Links

/// A YouTube video link, read from what the user pasted: youtube.com/watch, youtu.be, Shorts, live, embed, YouTube Music.
/// Only the video ID is kept: yt-dlp always gets the canonical address built from it, never the pasted text.
struct YouTubeLink: Equatable {
    let id: String
    /// "t=90" or "t=1m30s" in the link: where the video was shared from (offered as the start of an extract).
    var start: Double?
    var isShort = false

    var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }
    var shortURL: String { "youtu.be/\(id)" }

    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
                                             "youtube-nocookie.com", "www.youtube-nocookie.com", "youtu.be", "www.youtu.be"]

    /// nil for anything else than one video (a playlist, a channel, a search, a sentence with a link inside).
    static func parse(_ raw: String) -> YouTubeLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 15, text.count <= 400, !text.contains(where: \.isWhitespace) else { return nil }
        let withScheme = text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") ? text : "https://" + text
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        let query = comps.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var id: String?
        var short = false
        if host.hasSuffix("youtu.be") {
            id = parts.first
        } else if parts.first == "watch" || parts.isEmpty {
            id = value("v")
        } else if parts.count >= 2, ["shorts", "live", "embed", "v", "e"].contains(parts[0]) {
            id = parts[1]
            short = parts[0] == "shorts"
        }
        guard let id, isVideoID(id) else { return nil }
        return YouTubeLink(id: id, start: value("t").flatMap(parseOffset) ?? value("start").flatMap(parseOffset), isShort: short)
    }

    /// Eleven characters of base64url: what YouTube gives every video.
    static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// "90", "90s", "1m30s", "1h02m03s" → seconds.
    static func parseOffset(_ s: String) -> Double? {
        if let n = Double(s), n >= 0 { return n }
        var total = 0.0, number = ""
        for c in s.lowercased() {
            if c.isNumber { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
        }
        if !number.isEmpty { return nil }
        return total > 0 ? total : nil
    }
}

// MARK: - Options

enum YouTubeFormat: String, CaseIterable, Identifiable, Codable {
    case mp4, mp3, m4a

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var isAudio: Bool { self != .mp4 }
    var symbol: String { isAudio ? "waveform" : "film" }
    var ext: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "Vidéo MP4"
        case .mp3: return "Son MP3"
        case .m4a: return "Son M4A"
        }
    }
}

enum YouTubeQuality: Int, CaseIterable, Identifiable, Codable {
    case best = 0, p1080 = 1080, p720 = 720, p480 = 480, p360 = 360

    var id: Int { rawValue }
    var height: Int? { self == .best ? nil : rawValue }
    var label: String { self == .best ? "Max" : "\(rawValue)p" }
    var title: String { self == .best ? "La meilleure" : "\(rawValue)p" }
}

/// What the user chose: kept between launches (an extract belongs to one video and is not).
struct YouTubeOptions: Equatable, Codable {
    var format: YouTubeFormat = .mp4
    var quality: YouTubeQuality = .p1080

    private static let key = "youtube.options"

    static func saved() -> YouTubeOptions {
        guard !DemoData.isEnabled, let data = UserDefaults.standard.data(forKey: key),
              let o = try? JSONDecoder().decode(YouTubeOptions.self, from: data) else { return YouTubeOptions() }
        return o
    }

    func save() {
        guard !DemoData.isEnabled, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// "MP4 · 1080p", "MP3".
    var summary: String { format.isAudio ? format.label : "\(format.label) · \(quality.title)" }
}

/// The part of the video to keep, in seconds.
struct YouTubeClip: Equatable {
    var start: Double
    var end: Double

    var length: Double { max(0, end - start) }

    /// "1:05 → 2:30".
    var label: String { "\(YouTubeTime.format(start)) → \(YouTubeTime.format(end))" }

    /// What yt-dlp's --download-sections expects.
    var section: String { "*" + YouTubeTime.seconds(start) + "-" + YouTubeTime.seconds(end) }
}

/// Where the files go: Téléchargements by default, or a folder the user picked.
enum YouTubeDestination: Equatable {
    case downloads, folder(URL)

    private static let key = "youtube.destination"
    static var downloadsURL: URL { URL(fileURLWithPath: FS.home + "/Downloads") }

    var url: URL {
        switch self {
        case .downloads: return Self.downloadsURL
        case .folder(let url): return url
        }
    }

    var label: String {
        switch self {
        case .downloads: return "Téléchargements"
        case .folder(let url): return url.lastPathComponent
        }
    }

    static func saved() -> YouTubeDestination {
        guard !DemoData.isEnabled, let raw = UserDefaults.standard.string(forKey: key), raw != "downloads",
              FS.isDirectory(raw) else { return .downloads }
        return .folder(URL(fileURLWithPath: raw))
    }

    func save() {
        guard !DemoData.isEnabled else { return }
        switch self {
        case .downloads: UserDefaults.standard.set("downloads", forKey: Self.key)
        case .folder(let url): UserDefaults.standard.set(url.path, forKey: Self.key)
        }
    }
}

// MARK: - Video

/// One stream yt-dlp offers (a video track, a sound track, or both).
struct YouTubeStream: Equatable {
    var formatID: String
    var ext: String
    var vcodec: String?
    var acodec: String?
    var height: Int?
    var size: Int64?
    var bitrate: Double?

    var hasVideo: Bool { vcodec.map { $0 != "none" } ?? false }
    var hasAudio: Bool { acodec.map { $0 != "none" } ?? false }
    var isH264: Bool { vcodec?.hasPrefix("avc1") ?? false }

    /// Its size, or what its bitrate gives over `duration`.
    func bytes(duration: Double?) -> Int64? {
        if let size, size > 0 { return size }
        guard let bitrate, bitrate > 0, let duration, duration > 0 else { return nil }
        return Int64(bitrate * 1000 / 8 * duration)
    }

    /// "H.264", "VP9", "AV1".
    var codecName: String? {
        guard let v = vcodec, v != "none" else { return nil }
        if v.hasPrefix("avc1") || v.hasPrefix("h264") { return "H.264" }
        if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return "VP9" }
        if v.hasPrefix("av01") { return "AV1" }
        if v.hasPrefix("hev1") || v.hasPrefix("hvc1") { return "HEVC" }
        return v.split(separator: ".").first.map(String.init)?.uppercased()
    }
}

/// What is known about a video: the title and channel at once (oEmbed), the rest once yt-dlp has answered.
struct YouTubeInfo: Equatable {
    var id: String
    var title: String
    var channel: String
    var duration: Double?
    var uploaded: Date?
    var views: Int?
    var isLive = false
    var streams: [YouTubeStream] = []
    /// yt-dlp answered (duration, streams): until then the size and the extract wait.
    var detailed = false

    /// The heights offered, highest first.
    var heights: [Int] {
        Array(Set(streams.filter(\.hasVideo).compactMap(\.height))).sorted(by: >)
    }

    var maxHeight: Int? { heights.first }
}

// MARK: - Downloads

enum YouTubeJobState: Equatable {
    case waiting, running, done, failed, cancelled

    var isActive: Bool { self == .waiting || self == .running }
}

/// One download: what was asked, and how far it is.
struct YouTubeJob: Identifiable {
    let id = UUID()
    let videoID: String
    var title: String
    let channel: String
    let options: YouTubeOptions
    let clip: YouTubeClip?
    let folder: URL
    var state: YouTubeJobState = .waiting
    /// "Vidéo", "Son", "Assemblage"…
    var phase = ""
    /// 0…1, or nil while the step gives no progress (an extract cut by ffmpeg, the merge).
    var progress: Double?
    var speed: Double?
    var eta: Double?
    var output: URL?
    var error: String?
    /// The error looks like YouTube changed something: a newer yt-dlp usually fixes it.
    var suggestsUpdate = false
    var started: Date?
    var finished: Date?

    var summary: String {
        options.summary + (clip.map { " · extrait \($0.label)" } ?? "")
    }
}

/// yt-dlp being installed (or updated) with Homebrew, its output as it comes.
struct YouTubeInstall {
    var title: String
    var lines: [String] = []
    var running = true
    var failed = false
}

// MARK: - Time

enum YouTubeTime {
    /// 65 → "1:05", 3723 → "1:02:03".
    static func format(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1:05", "1:02:03", "90" → seconds.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap(Double.init)
        if numbers.count > 1, numbers.dropFirst().contains(where: { $0 >= 60 }) { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// Seconds for yt-dlp, with a dot whatever the locale ("65.5").
    static func seconds(_ s: Double) -> String {
        let rounded = (s * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    /// "3 min 12", "1 h 05", "45 s": a duration in words.
    static func spoken(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return t % 60 == 0 ? "\(t / 60) min" : "\(t / 60) min \(String(format: "%02d", t % 60))" }
        return "\(t / 3600) h \(String(format: "%02d", (t % 3600) / 60))"
    }
}
