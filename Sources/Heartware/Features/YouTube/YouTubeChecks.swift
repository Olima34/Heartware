import Foundation

/// `--selftest`: links, times, yt-dlp's command line and output, the choice of streams. Nothing touches the network.
enum YouTubeChecks {
    static func run() -> [String] {
        var failures: [String] = []
        let id = "jNQXAC9IVRw"
        // An ID may start with "-": it only ever reaches yt-dlp inside the address, never as an argument of its own.
        let dashed = "-" + String(id.dropFirst())
        let links: [(String, String?, Double?)] = [
            ("https://www.youtube.com/watch?v=\(id)", id, nil),
            ("https://www.youtube.com/watch?v=\(id)&list=PL123&index=2", id, nil),
            ("youtube.com/watch?v=\(id)&t=1m30s", id, 90),
            ("https://youtu.be/\(id)?si=AbCdEf&t=42", id, 42),
            ("https://m.youtube.com/watch?feature=share&v=\(id)", id, nil),
            ("https://music.youtube.com/watch?v=\(id)", id, nil),
            ("https://www.youtube.com/shorts/\(id)?feature=share", id, nil),
            ("https://www.youtube.com/live/\(id)", id, nil),
            ("https://www.youtube-nocookie.com/embed/\(id)?start=12", id, 12),
            ("  https://youtu.be/\(id)  ", id, nil),
            ("https://www.youtube.com/playlist?list=PL123", nil, nil),
            ("https://www.youtube.com/@atelier", nil, nil),
            ("https://www.youtube.com/results?search_query=bol", nil, nil),
            ("https://youtu.be/short", nil, nil),
            ("https://vimeo.com/watch?v=\(id)", nil, nil),
            ("https://evil.com/youtube.com/watch?v=\(id)", nil, nil),
            ("https://www.youtube.com.evil.com/watch?v=\(id)", nil, nil),
            ("regarde https://youtu.be/\(id)", nil, nil),
            ("youtube", nil, nil),
            ("https://www.youtube.com/watch?v=\(dashed)", dashed, nil)
        ]
        for (text, expected, start) in links {
            let got = YouTubeLink.parse(text)
            if got?.id != expected { failures.append("lien « \(text) » → \(got?.id ?? "rien"), attendu \(expected ?? "rien")") }
            if expected != nil, got?.start != start { failures.append("lien « \(text) » : début \(got?.start.map { "\($0)" } ?? "aucun")") }
        }
        if YouTubeLink.parse("https://www.youtube.com/shorts/\(id)")?.isShort != true { failures.append("lien : un Short n'est pas reconnu") }
        if YouTubeLink.parse("https://youtu.be/\(id)")?.watchURL != "https://www.youtube.com/watch?v=\(id)" {
            failures.append("lien : adresse canonique")
        }

        for (s, text) in [(0.0, "0:00"), (65, "1:05"), (3723, "1:02:03"), (59.9, "0:59")] where YouTubeTime.format(s) != text {
            failures.append("temps \(s) → « \(YouTubeTime.format(s)) », attendu « \(text) »")
        }
        for (text, s) in [("1:05", 65.0), ("1:02:03", 3723), ("90", 90), ("0:00", 0)] where YouTubeTime.parse(text) != s {
            failures.append("temps « \(text) » → \(YouTubeTime.parse(text).map { "\($0)" } ?? "rien")")
        }
        for bad in ["1:75", "abc", "1::2", "", "1:2:3:4", "-5"] where YouTubeTime.parse(bad) != nil {
            failures.append("temps « \(bad) » aurait dû être refusé")
        }
        for (text, s) in [("1h2m3s", 3723.0), ("90s", 90), ("2m", 120)] where YouTubeLink.parseOffset(text) != s {
            failures.append("t= « \(text) » mal lu")
        }
        if YouTubeTime.seconds(65.25) != "65.3" || YouTubeTime.seconds(65) != "65" { failures.append("secondes pour yt-dlp : « \(YouTubeTime.seconds(65.25)) »") }
        if YouTubeClip(start: 65, end: 150).section != "*65-150" { failures.append("extrait : --download-sections") }

        // yt-dlp's command line: always the canonical address, last; never the pasted text.
        let mp4 = YouTubeEngine.arguments(videoID: id, options: YouTubeOptions(format: .mp4, quality: .p720), clip: YouTubeClip(start: 5, end: 12),
                                          ffmpeg: "/opt/homebrew/bin/ffmpeg", workFolder: "/tmp/w")
        if mp4.last != "https://www.youtube.com/watch?v=\(id)" { failures.append("yt-dlp : l'adresse n'est pas la dernière") }
        if !contains(mp4, ["-S", "res:720,vcodec:h264,acodec:m4a"]) || !contains(mp4, ["--merge-output-format", "mp4"]) {
            failures.append("yt-dlp : la qualité 720p en H.264 n'est pas demandée")
        }
        if !contains(mp4, ["--download-sections", "*5-12"]) || !mp4.contains("--force-keyframes-at-cuts") { failures.append("yt-dlp : extrait absent") }
        // The cut tells where it is; a whole video goes through yt-dlp's own downloader, which already does.
        if !contains(mp4, ["--downloader-args", "ffmpeg_o:-progress pipe:1 -nostats"]) { failures.append("yt-dlp : la découpe ne dit pas où elle en est") }
        if !mp4.contains("--no-playlist") || !mp4.contains("--ignore-config") { failures.append("yt-dlp : une playlist ou une configuration pourrait s'en mêler") }
        if !contains(mp4, ["-P", "/tmp/w"]) { failures.append("yt-dlp : dossier de travail") }
        let best = YouTubeEngine.arguments(videoID: id, options: YouTubeOptions(format: .mp4, quality: .best), clip: nil, ffmpeg: "f", workFolder: "/tmp/w")
        if !contains(best, ["-S", "res,vcodec:h264,acodec:m4a"]) || best.contains("--download-sections") || best.contains("--downloader-args") {
            failures.append("yt-dlp : qualité maximale")
        }
        let mp3 = YouTubeEngine.arguments(videoID: id, options: YouTubeOptions(format: .mp3, quality: .p1080), clip: nil, ffmpeg: "f", workFolder: "/tmp/w")
        if !contains(mp3, ["--audio-format", "mp3"]) || mp3.contains("--merge-output-format") { failures.append("yt-dlp : MP3") }
        let m4a = YouTubeEngine.arguments(videoID: id, options: YouTubeOptions(format: .m4a, quality: .p1080), clip: nil, ffmpeg: "f", workFolder: "/tmp/w")
        if !contains(m4a, ["--audio-format", "m4a"]) { failures.append("yt-dlp : M4A") }

        // Its output, as printed with the module's templates.
        let lines: [(String, YouTubeEngine.Event?)] = [
            ("HWSEL 137+140", .selected(["137", "140"])),
            ("HWP 1024 433081 NA NA NA", .progress(done: 1024, total: 433_081, speed: nil, eta: nil)),
            ("HWP 3072 NA 900000 1994875.66 4", .progress(done: 3072, total: 900_000, speed: 1_994_875.66, eta: 4)),
            ("HWFILE /tmp/w/\(id).mp4", .file("/tmp/w/\(id).mp4")),
            ("ERROR: [youtube] \(id): Video unavailable", .error("ERROR: [youtube] \(id): Video unavailable")),
            ("[download] Destination: x", nil),
            // ffmpeg cutting an extract, as it prints with -progress.
            ("out_time_us=7709025", .cutTime(7.709025)),
            ("out_time_us=N/A", nil),
            ("speed=15.3x", .cutSpeed(15.3)),
            ("speed=N/A", nil),
            ("progress=continue", nil)
        ]
        for (line, expected) in lines where YouTubeEngine.parse(line) != expected {
            failures.append("sortie de yt-dlp « \(line) » mal lue")
        }
        // Two tracks: the bar goes through the picture, then the sound, then the assembly; never backwards.
        let demo = YouTubeDemo.info
        let tracker = YouTubeTracker(format: .mp4, clip: nil, info: demo)
        var seen: [Double] = []
        _ = tracker.apply(.selected(["137", "140"]))
        for (done, total) in [(0, 171_400_000), (85_700_000, 171_400_000), (171_400_000, 171_400_000), (1000, 12_200_000), (12_200_000, 12_200_000)] {
            let (state, _) = tracker.apply(.progress(done: Int64(done), total: Int64(total), speed: 1e6, eta: 3))
            if let p = state.progress { seen.append(p) }
        }
        if seen != seen.sorted() { failures.append("progression : elle recule (\(seen))") }
        if (seen.last ?? 0) < 0.95 { failures.append("progression : n'arrive pas au bout (\(seen.last ?? 0))") }
        if tracker.apply(.file("/tmp/x.mp4")).0.phase != "Rangement" || tracker.file != "/tmp/x.mp4" { failures.append("progression : fichier final") }
        // An extract: ffmpeg's position over its 30 s, then the single line yt-dlp prints once the cut is over.
        let cut = YouTubeTracker(format: .mp4, clip: YouTubeClip(start: 5, end: 35), info: demo)
        _ = cut.apply(.selected(["137", "140"]))
        _ = cut.apply(.cutSpeed(15))
        let mid = cut.apply(.cutTime(15)).0
        if mid.progress.map({ abs($0 - 0.485) > 0.01 }) ?? true { failures.append("extrait : à mi-chemin, \(mid.progress.map { "\($0)" } ?? "rien")") }
        if mid.eta.map({ abs($0 - 1) > 0.01 }) ?? true { failures.append("extrait : temps restant \(mid.eta.map { "\($0)" } ?? "inconnu")") }
        if (cut.apply(.cutTime(10)).0.progress ?? 0) < mid.progress ?? 1 { failures.append("extrait : la progression recule") }
        let over = cut.apply(.progress(done: 702_445, total: 702_445, speed: 3e5, eta: nil)).0
        if over.progress != 0.98 || over.phase != "Finalisation" { failures.append("extrait : fin de la découpe (\(over.phase))") }

        // What the sidebar and the menu bar show: the running download, else the next to start.
        var queue = YouTubeDemo.jobs()
        if let a = YouTubeActivity.from(queue) {
            if a.percent != "62 %" || !a.running || !a.detail.contains("encore 9 s") { failures.append("activité : « \(a.percent) », « \(a.detail) »") }
        } else {
            failures.append("activité : le téléchargement en cours n'est pas vu")
        }
        var next = queue[0]
        next.state = .waiting
        var later = YouTubeJob(videoID: next.videoID, title: "Plus tard", channel: "", options: next.options, clip: nil, folder: next.folder)
        later.state = .waiting
        // Newest first: the oldest waiting one starts next.
        queue = [later, next] + queue.dropFirst()
        if let a = YouTubeActivity.from(queue), a.title != next.title || a.running || a.queued != 1 || a.percent != "…" {
            failures.append("activité : la file d'attente (« \(a.title) », \(a.queued) en attente)")
        }
        if YouTubeActivity.from(Array(YouTubeDemo.jobs().dropFirst())) != nil { failures.append("activité : une liste terminée paraît en cours") }
        var almost = YouTubeActivity.from(YouTubeDemo.jobs())
        almost?.progress = 0.996
        if almost?.percent != "99 %" { failures.append("activité : 99,6 % affiché \(almost?.percent ?? "")") }

        // The streams yt-dlp will pick, and the size announced.
        if YouTubeEngine.videoStream(demo, quality: .p1080)?.formatID != "137" { failures.append("flux : 1080p devrait être le H.264") }
        if YouTubeEngine.videoStream(demo, quality: .best)?.height != 2160 { failures.append("flux : la meilleure qualité devrait être la 4K") }
        if YouTubeEngine.videoStream(demo, quality: .p360)?.formatID != "134" { failures.append("flux : 360p") }
        if YouTubeEngine.audioStream(demo)?.formatID != "140" { failures.append("flux : le son devrait être l'AAC") }
        let full = YouTubeEngine.estimate(demo, options: YouTubeOptions(format: .mp4, quality: .p1080), clip: nil) ?? 0
        if full != 171_400_000 + 12_200_000 { failures.append("taille : \(full) au lieu de l'image + le son") }
        let half = YouTubeEngine.estimate(demo, options: YouTubeOptions(format: .mp4, quality: .p1080), clip: YouTubeClip(start: 0, end: 377)) ?? 0
        if abs(Double(half) - Double(full) / 2) > 2 { failures.append("taille d'un extrait : \(half)") }

        // yt-dlp -J, cut down to what is read.
        let json = """
        {"id":"\(id)","title":"Me at the zoo","channel":"jawed","duration":19,"upload_date":"20050424","view_count":10,"is_live":false,
         "formats":[{"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":309288,"tbr":129.8},
                    {"format_id":"140-drc","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":309197},
                    {"format_id":"134","ext":"mp4","vcodec":"avc1.4D400C","acodec":"none","height":240,"filesize_approx":322379},
                    {"format_id":"sb0","ext":"mhtml","vcodec":"none","acodec":"none"}]}
        """
        let info = YouTubeEngine.parseInfo(Data(json.utf8))
        if info?.title != "Me at the zoo" || info?.duration != 19 || info?.channel != "jawed" { failures.append("yt-dlp -J : titre ou durée") }
        if info?.streams.map(\.formatID) != ["140", "134"] { failures.append("yt-dlp -J : flux \(info?.streams.map(\.formatID) ?? [])") }
        if info?.maxHeight != 240 || info?.uploaded == nil { failures.append("yt-dlp -J : hauteur ou date") }
        if YouTubeEngine.parseInfo(Data("null".utf8)) != nil { failures.append("yt-dlp -J : « null » accepté") }

        // File names: the title, readable, never a path.
        let name = YouTubeEngine.fileName(title: "AC/DC: live\nà Paris", clip: YouTubeClip(start: 65, end: 150), ext: "mp4")
        if name != "AC-DC- live à Paris (extrait 1’05–2’30).mp4" { failures.append("nom de fichier : « \(name) »") }
        if YouTubeEngine.fileName(title: "...", clip: nil, ext: "mp3") != "Vidéo YouTube.mp3" { failures.append("nom de fichier vide") }
        if YouTubeEngine.fileName(title: String(repeating: "a", count: 400), clip: nil, ext: "mp4").count > 160 { failures.append("nom de fichier trop long") }

        // Errors said simply, with the update offered when it is the cure.
        if !YouTubeEngine.friendly("ERROR: [youtube] \(id): Private video. Sign in if you've been granted access").message.contains("privée") {
            failures.append("erreur : vidéo privée")
        }
        if !YouTubeEngine.friendly("ERROR: [youtube] \(id): Requested format is not available").suggestsUpdate { failures.append("erreur : mise à jour non proposée") }
        if YouTubeEngine.friendly("ERROR: [youtube] \(id): Something odd").message != "yt-dlp : Something odd" { failures.append("erreur : texte brut") }
        return failures
    }

    /// `args` holds `pair` side by side.
    private static func contains(_ args: [String], _ pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        return zip(args, args.dropFirst()).contains { $0 == pair[0] && $1 == pair[1] }
    }
}
