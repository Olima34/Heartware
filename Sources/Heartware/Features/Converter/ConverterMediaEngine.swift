import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video and audio: AVFoundation export sessions, `afconvert`, and ffmpeg when it is installed (MKV, WebM, MP3…).
enum ConverterMediaEngine {
    static let afconvert = "/usr/bin/afconvert"

    static func needsFFmpeg(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ConverterKind.ffmpegVideoExtensions.contains(ext) || ConverterKind.ffmpegAudioExtensions.contains(ext)
    }

    // MARK: - AVFoundation

    /// Exports with an Apple preset, checked first with `AVAssetExportSession.compatibility` (determineCompatibility).
    static func export(_ input: URL, preset: String, fileType: AVFileType, ext: String, suffix: String?, folder: URL?,
                       control: ConverterControl) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType) else {
            throw ConverterError.unsupported("Ce réglage ne convient pas à « \(input.lastPathComponent) ».")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConverterError.unreadable(input.lastPathComponent)
        }
        let out = FileOps.outputURL(for: input, extension: ext, suffix: suffix, folder: folder)
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4 || fileType == .m4a
        let done = ConverterFlag()
        // macOS 14 has no async `export(to:as:)`: the classic call, with its progress read four times a second.
        session.exportAsynchronously { done.set() }
        while !done.isSet {
            if control.isCancelled || Task.isCancelled { session.cancelExport() }
            control.progress(Double(session.progress))
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        switch session.status {
        case .completed:
            FileOps.didCreate(out)
            control.progress(1)
            return out
        case .cancelled:
            ConverterOutputs.discard(out)
            throw ConverterError.cancelled
        default:
            ConverterOutputs.discard(out)
            throw ConverterError.failed(session.error?.localizedDescription ?? "L'export de la vidéo a échoué.")
        }
    }

    static func compress(_ input: URL, preset: ConverterVideoPreset, container: ConverterVideoContainer, folder: URL?,
                         control: ConverterControl) async throws -> URL {
        if needsFFmpeg(input) {
            throw ConverterError.unsupported("macOS ne sait pas lire ce format : passe d'abord par « MOV ↔ MP4 » avec ffmpeg.")
        }
        let fileType: AVFileType = container == .mov ? .mov : .mp4
        return try await export(input, preset: preset.rawValue, fileType: fileType, ext: container == .mov ? "mov" : "mp4",
                                suffix: preset.short, folder: folder, control: control)
    }

    /// Refuses a video already in that container: "MOV ↔ MP4" would have nothing to do (the preview asks too).
    static func checkChangesContainer(_ input: URL, to container: ConverterVideoContainer) throws {
        let ext = input.pathExtension.lowercased()
        if ext == container.ext || (container == .mp4 && ext == "m4v") {
            throw ConverterError.unsupported("« \(input.lastPathComponent) » est déjà en \(container.name).")
        }
    }

    /// MOV ↔ MP4 without re-encoding when the streams allow it; MKV and WebM (and exotic sources) through ffmpeg.
    static func changeContainer(_ input: URL, to container: ConverterVideoContainer, ffmpeg: String?, folder: URL?,
                                control: ConverterControl) async throws -> (url: URL, note: String?) {
        try checkChangesContainer(input, to: container)
        if container.viaFFmpeg || needsFFmpeg(input) {
            guard let ffmpeg else { throw ConverterError.unsupported("Ce format demande ffmpeg (brew install ffmpeg).") }
            let url = try await ffmpegVideo(input, to: container, ffmpeg: ffmpeg, folder: folder, control: control)
            return (url, nil)
        }
        let fileType: AVFileType = container == .mov ? .mov : .mp4
        let asset = AVURLAsset(url: input)
        if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType) {
            let url = try await export(input, preset: AVAssetExportPresetPassthrough, fileType: fileType, ext: container.ext,
                                       suffix: nil, folder: folder, control: control)
            return (url, "Sans réencodage : qualité identique.")
        }
        let url = try await export(input, preset: AVAssetExportPresetHighestQuality, fileType: fileType, ext: container.ext,
                                   suffix: nil, folder: folder, control: control)
        return (url, "Réencodée en H.264 : ce codec n'entre pas tel quel dans un \(container.name).")
    }

    static func extractAudio(_ input: URL, folder: URL?, control: ConverterControl) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw ConverterError.unsupported("« \(input.lastPathComponent) » n'a pas de piste audio.") }
        return try await export(input, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a", suffix: nil,
                                folder: folder, control: control)
    }

    /// An animated GIF: frames taken one by one with `AVAssetImageGenerator` and written as they come.
    static func gif(_ input: URL, width: Int, fps: Int, seconds: Int, folder: URL?, control: ConverterControl) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConverterError.unsupported("« \(input.lastPathComponent) » n'a pas d'image.")
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(upright.width), h = abs(upright.height)
        guard w > 0, h > 0, duration > 0 else { throw ConverterError.unreadable(input.lastPathComponent) }
        let targetW = min(CGFloat(width), w)
        let targetH = (h * targetW / w).rounded()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: targetW, height: targetH)
        let tolerance = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let length = seconds > 0 ? min(duration, Double(seconds)) : duration
        let count = max(1, Int(length * Double(fps)))
        let out = FileOps.outputURL(for: input, extension: "gif", folder: folder)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, ConverterImageFormat.gif.uti as CFString, count, nil) else {
            throw ConverterError.failed("Impossible de créer le GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                          kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for i in 0..<count {
            if control.isCancelled {
                ConverterOutputs.discard(out)
                throw ConverterError.cancelled
            }
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(dest, frame, frameProps)
            control.progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else {
            ConverterOutputs.discard(out)
            throw ConverterError.failed("L'écriture du GIF a échoué.")
        }
        FileOps.didCreate(out)
        return out
    }

    // MARK: - Audio

    static func convertAudio(_ input: URL, to format: ConverterAudioFormat, bitrate: Int, ffmpeg: String?, folder: URL?,
                             control: ConverterControl) async throws -> URL {
        if format.viaFFmpeg || needsFFmpeg(input) {
            guard let ffmpeg else { throw ConverterError.unsupported("Le \(format.short) demande ffmpeg (brew install ffmpeg).") }
            let out = FileOps.outputURL(for: input, extension: format.ext, folder: folder)
            var codec: [String] = ["-vn"]
            switch format {
            case .mp3: codec += ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
            case .aac: codec += ["-c:a", "aac", "-b:a", "\(bitrate)k"]
            case .alac: codec += ["-c:a", "alac"]
            case .wav: codec += ["-c:a", "pcm_s16le"]
            case .aiff: codec += ["-c:a", "pcm_s16be"]
            case .flac: codec += ["-c:a", "flac"]
            }
            let duration = await mediaDuration(input, ffmpeg: ffmpeg)
            try await runFFmpeg(ffmpeg, input: input, codec: codec, output: out, duration: duration, control: control)
            return out
        }
        let out = FileOps.outputURL(for: input, extension: format.ext, folder: folder)
        var args: [String]
        switch format {
        case .aac: args = ["-f", "m4af", "-d", "aac", "-q", "127", "-b", "\(bitrate * 1000)"]
        case .alac: args = ["-f", "m4af", "-d", "alac"]
        case .wav: args = ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: args = ["-f", "AIFF", "-d", "BEI16"]
        case .flac: args = ["-f", "flac", "-d", "flac"]
        case .mp3: args = []
        }
        control.progress(nil)
        var result = await afconvertRun(args + [input.path, out.path], control: control)
        if !result.ok, !control.isCancelled, format == .aac {
            // Some sources (mono, low sample rates) refuse a high bitrate: let the encoder choose.
            ConverterOutputs.discard(out)
            result = await afconvertRun(["-f", "m4af", "-d", "aac", "-q", "127", input.path, out.path], control: control)
        }
        if control.isCancelled {
            ConverterOutputs.discard(out)
            throw ConverterError.cancelled
        }
        guard result.ok, FileManager.default.fileExists(atPath: out.path) else {
            ConverterOutputs.discard(out)
            throw ConverterError.failed(lastLines(result.out) ?? "La conversion audio a échoué.")
        }
        FileOps.didCreate(out)
        return out
    }

    private static func afconvertRun(_ args: [String], control: ConverterControl) async -> Shell.Output {
        await Task.detached(priority: .userInitiated) {
            Shell.stream(afconvert, args, isCancelled: { control.isCancelled }) { _ in }
        }.value
    }

    // MARK: - ffmpeg

    private final class ConverterEncoderCache: @unchecked Sendable {
        let lock = NSLock()
        var byPath: [String: Set<String>] = [:]
    }
    private static let encoderCache = ConverterEncoderCache()

    /// The encoders this ffmpeg was built with ("libx264", "libwebp"…), asked when a conversion first needs them and kept
    /// for the session. Slow-ish: call off the main thread.
    static func ffmpegEncoders(_ ffmpeg: String) -> Set<String> {
        encoderCache.lock.lock()
        let known = encoderCache.byPath[ffmpeg]
        encoderCache.lock.unlock()
        if let known { return known }
        let r = Shell.run(ffmpeg, ["-hide_banner", "-encoders"], timeout: 15)
        guard r.ok else { return [] }
        let names = ffmpegEncodersParse(r.out)
        encoderCache.lock.lock()
        encoderCache.byPath[ffmpeg] = names
        encoderCache.lock.unlock()
        return names
    }

    static func ffmpegEncodersParse(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // " V....D libx264   libx264 H.264…": flags then name.
            if parts.count >= 2, parts[0].count == 6, parts[0].allSatisfy({ "VASFXBD.".contains($0) }) {
                names.insert(String(parts[1]))
            }
        }
        return names
    }

    static func ffmpegVideo(_ input: URL, to container: ConverterVideoContainer, ffmpeg: String, folder: URL?,
                            control: ConverterControl) async throws -> URL {
        let encoders = await Task.detached { ffmpegEncoders(ffmpeg) }.value
        var codec: [String]
        switch container {
        case .mkv:
            codec = ["-map", "0:v", "-map", "0:a?", "-c", "copy"]
        case .webm:
            guard encoders.contains("libvpx-vp9"), encoders.contains("libopus") else {
                throw ConverterError.unsupported("Ton ffmpeg n'a pas les encodeurs VP9 et Opus du WebM.")
            }
            codec = ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1",
                     "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case .mp4, .mov:
            let video = encoders.contains("libx264") ? ["-c:v", "libx264", "-crf", "21", "-preset", "veryfast"]
                                                      : ["-c:v", "h264_videotoolbox", "-b:v", "8M"]
            codec = ["-map", "0:v:0", "-map", "0:a:0?"] + video + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            if container == .mp4 { codec += ["-movflags", "+faststart"] }
        }
        let out = FileOps.outputURL(for: input, extension: container.ext, folder: folder)
        let duration = await mediaDuration(input, ffmpeg: ffmpeg)
        try await runFFmpeg(ffmpeg, input: input, codec: codec, output: out, duration: duration, control: control)
        return out
    }

    /// Runs ffmpeg (never overwriting: `-n`), with its progress read from `-progress pipe:1`.
    static func runFFmpeg(_ ffmpeg: String, input: URL, codec: [String], output: URL, duration: Double?,
                          control: ConverterControl) async throws {
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", input.path] + codec
            + ["-progress", "pipe:1", "-nostats", output.path]
        control.progress(duration == nil ? nil : 0)
        let result = await Task.detached(priority: .userInitiated) {
            Shell.stream(ffmpeg, args, isCancelled: { control.isCancelled }) { line in
                guard let duration, duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                      let us = Double(line.split(separator: "=").last ?? "") else { return }
                control.progress(us / 1_000_000 / duration)
            }
        }.value
        if control.isCancelled {
            ConverterOutputs.discard(output)
            throw ConverterError.cancelled
        }
        guard result.ok, FileManager.default.fileExists(atPath: output.path) else {
            ConverterOutputs.discard(output)
            throw ConverterError.failed(lastLines(result.out) ?? "ffmpeg a échoué.")
        }
        FileOps.didCreate(output)
        control.progress(1)
    }

    /// The meaningful end of a tool's output (progress lines removed).
    static func lastLines(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.contains("=") && !$0.contains(" ")) }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(2).joined(separator: " ")
    }

    /// Duration in seconds: AVFoundation when it can read the file, ffprobe otherwise.
    static func mediaDuration(_ url: URL, ffmpeg: String?) async -> Double? {
        if !needsFFmpeg(url), let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 { return d }
        guard let ffmpeg else { return nil }
        let probe = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        guard Shell.exists(probe) else { return nil }
        let r = await Task.detached {
            Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path], timeout: 15)
        }.value
        return Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "2:14 · 1 920 × 1 080" for the file list.
    static func describe(_ url: URL, kind: ConverterKind) async -> String? {
        guard !needsFFmpeg(url) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        var parts = [clock(duration)]
        if kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            parts.append("\(Fmt.int(Int(abs(r.width)))) × \(Fmt.int(Int(abs(r.height))))")
        }
        return parts.joined(separator: " · ")
    }

    /// 134 → "2:14", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}
