import SwiftUI

/// The demo's fictional videos: never a real video, channel or address.
enum YouTubeDemo {
    static let videoID = "Lm4tB9qXe2A"

    static var info: YouTubeInfo {
        var info = YouTubeInfo(id: videoID, title: "Tourner un bol en grès, du pain de terre à l'émaillage",
                               channel: "Atelier Lumen", duration: 754, views: 48_210)
        info.uploaded = Date().addingTimeInterval(-36 * 86_400)
        info.streams = [
            YouTubeStream(formatID: "401", ext: "mp4", vcodec: "av01.0.12M.08", acodec: "none", height: 2160, size: 912_000_000),
            YouTubeStream(formatID: "400", ext: "mp4", vcodec: "av01.0.08M.08", acodec: "none", height: 1440, size: 431_000_000),
            YouTubeStream(formatID: "137", ext: "mp4", vcodec: "avc1.640028", acodec: "none", height: 1080, size: 171_400_000),
            YouTubeStream(formatID: "248", ext: "webm", vcodec: "vp9", acodec: "none", height: 1080, size: 118_000_000),
            YouTubeStream(formatID: "136", ext: "mp4", vcodec: "avc1.4d401f", acodec: "none", height: 720, size: 78_600_000),
            YouTubeStream(formatID: "135", ext: "mp4", vcodec: "avc1.4d401e", acodec: "none", height: 480, size: 39_900_000),
            YouTubeStream(formatID: "134", ext: "mp4", vcodec: "avc1.4d401e", acodec: "none", height: 360, size: 22_300_000),
            YouTubeStream(formatID: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", size: 12_200_000, bitrate: 129.5),
            YouTubeStream(formatID: "251", ext: "webm", vcodec: "none", acodec: "opus", size: 11_100_000, bitrate: 117.8)
        ]
        info.detailed = true
        return info
    }

    static func jobs() -> [YouTubeJob] {
        let downloads = URL(fileURLWithPath: DemoData.home + "/Downloads")
        var running = YouTubeJob(videoID: videoID, title: info.title, channel: "Atelier Lumen",
                                 options: YouTubeOptions(format: .mp4, quality: .p1080), clip: YouTubeClip(start: 65, end: 150), folder: downloads)
        running.state = .running
        running.phase = "Découpe de l'extrait"
        running.progress = 0.62
        // An extract: ffmpeg says how far the cut is and how long is left, not a speed in bytes.
        running.eta = 9
        running.started = Date().addingTimeInterval(-14)
        var done = YouTubeJob(videoID: "Qr7Vn2KdW0s", title: "Émail à la cendre : trois recettes simples", channel: "Atelier Lumen",
                              options: YouTubeOptions(format: .mp3, quality: .p1080), clip: nil, folder: downloads)
        done.state = .done
        done.progress = 1
        done.output = downloads.appendingPathComponent("Émail à la cendre - trois recettes simples.mp3")
        done.finished = Date().addingTimeInterval(-600)
        var failed = YouTubeJob(videoID: "Zp1sH8cYt3u", title: "Cuisson raku dans le jardin", channel: "Terre & Feu",
                                options: YouTubeOptions(format: .mp4, quality: .best), clip: nil, folder: downloads)
        failed.state = .failed
        failed.error = "YouTube a changé quelque chose : mets yt-dlp à jour, c'est en général réglé."
        failed.suggestsUpdate = true
        return [running, done, failed]
    }

    static let installLines = [
        "==> Fetching downloads for: yt-dlp",
        "==> Fetching dependencies for yt-dlp: deno, python@3.15",
        "==> Pouring deno--2.5.6.arm64_tahoe.bottle.tar.gz",
        "==> Pouring yt-dlp--2026.08.19.all.bottle.tar.gz",
        "==> Installing yt-dlp"
    ]
}

/// A made-up picture for the demo's videos: a potter's wheel in warm light (drawn, nothing is downloaded).
struct YouTubeDemoPicture: View {
    var seed: String

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 40) / 360
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hue: 0.07 + hue, saturation: 0.55, brightness: 0.78),
                                        Color(hue: 0.02 + hue, saturation: 0.62, brightness: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The window's light.
                Circle().fill(Color(hue: 0.12, saturation: 0.35, brightness: 1).opacity(0.35))
                    .frame(width: w * 0.55).offset(x: -w * 0.3, y: -h * 0.35).blur(radius: 18)
                // The wheel and the bowl.
                Ellipse().fill(Color(hue: 0.08, saturation: 0.25, brightness: 0.22))
                    .frame(width: w * 0.62, height: h * 0.2).offset(y: h * 0.3)
                Ellipse().fill(Color(hue: 0.07, saturation: 0.3, brightness: 0.35))
                    .frame(width: w * 0.5, height: h * 0.13).offset(y: h * 0.26)
                BowlShape().fill(LinearGradient(colors: [Color(hue: 0.06, saturation: 0.45, brightness: 0.82),
                                                         Color(hue: 0.05, saturation: 0.5, brightness: 0.55)],
                                                startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.34, height: h * 0.32).offset(y: h * 0.08)
                Ellipse().fill(Color(hue: 0.05, saturation: 0.4, brightness: 0.4))
                    .frame(width: w * 0.3, height: h * 0.07).offset(y: -h * 0.08)
            }
        }
    }
}

private struct BowlShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
