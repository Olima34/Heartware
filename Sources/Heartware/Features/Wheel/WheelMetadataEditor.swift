import SwiftUI
import ImageIO

/// What a photo says about itself, read from its metadata. Pure: `selfTest` reads a made-up set.
struct WheelPhotoInfo: Equatable {
    struct Row: Equatable {
        var label: String
        var value: String
        var symbol: String
        /// Personal: a copy "sans métadonnées" drops it.
        var personal: Bool
    }

    var rows: [Row] = []
    var latitude: Double?
    var longitude: Double?

    var hasPosition: Bool { latitude != nil && longitude != nil }
    var hasPersonal: Bool { rows.contains(where: \.personal) || hasPosition }

    static func read(_ p: [CFString: Any]) -> WheelPhotoInfo {
        var info = WheelPhotoInfo()
        let exif = (p[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        let gps = (p[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            info.rows.append(Row(label: "Prise le", value: readableDate(date), symbol: "calendar", personal: true))
        }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !camera.isEmpty {
            // "Apple iPhone 15 Pro" rather than "Apple Apple iPhone…".
            let text = camera.count == 2 && camera[1].hasPrefix(camera[0]) ? camera[1] : camera.joined(separator: " ")
            info.rows.append(Row(label: "Appareil", value: text, symbol: "camera", personal: true))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
            info.rows.append(Row(label: "Objectif", value: lens, symbol: "camera.aperture", personal: true))
        }
        var shot: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { shot.append("f/\(Fmt.dec(f))") }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            shot.append(t >= 1 ? "\(Fmt.dec(t)) s" : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { shot.append("\(Fmt.dec(focal)) mm") }
        if !shot.isEmpty { info.rows.append(Row(label: "Réglages", value: shot.joined(separator: " · "), symbol: "dial.medium", personal: false)) }
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            info.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            info.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            var text = coordinates(info.latitude!, info.longitude!)
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { text += " · \(Fmt.int(alt)) m" }
            info.rows.append(Row(label: "Position", value: text, symbol: "location.fill", personal: true))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String, !software.isEmpty {
            info.rows.append(Row(label: "Logiciel", value: software, symbol: "app.badge", personal: true))
        }
        let iptc = (p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        let author = tiff[kCGImagePropertyTIFFArtist] as? String ?? (iptc[kCGImagePropertyIPTCByline] as? [String])?.first
        if let author, !author.isEmpty { info.rows.append(Row(label: "Auteur", value: author, symbol: "person", personal: true)) }
        if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String, !copyright.isEmpty {
            info.rows.append(Row(label: "Droits", value: copyright, symbol: "c.circle", personal: false))
        }
        if var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int {
            if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            info.rows.append(Row(label: "Dimensions", value: "\(Fmt.int(w)) × \(Fmt.int(h)) px", symbol: "aspectratio", personal: false))
        }
        return info
    }

    /// "2024:07:14 18:32:05" → "14 juil. 2024 à 18:32".
    static func readableDate(_ exif: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let d = f.date(from: exif) else { return exif }
        return "\(Fmt.day(d)) à \(Fmt.clock(d))"
    }

    /// 43.6047, 3.8767 → "43,605° N, 3,877° E" (a hundred metres or so: enough to find the place).
    static func coordinates(_ lat: Double, _ lon: Double) -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", abs(v)).replacingOccurrences(of: ".", with: ",") }
        return "\(f(lat))° \(lat >= 0 ? "N" : "S"), \(f(lon))° \(lon >= 0 ? "E" : "O")"
    }
}

/// « Métadonnées » : what the photo tells about you (date, camera, position…) and a copy without it.
struct WheelMetadataEditor: View {
    let context: WheelEditorContext
    @State private var info: WheelPhotoInfo?
    @State private var thumb: CGImage?

    init(context: WheelEditorContext) {
        self.context = context
        if DemoData.isEnabled {
            _info = State(initialValue: WheelDemo.photoInfo)
            _thumb = State(initialValue: WheelDemo.photo(width: 360, height: 240))
        }
    }

    var body: some View {
        WheelWindowChrome(title: "Métadonnées", subtitle: context.file.name, close: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let thumb {
                            Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Theme.track
                        }
                    }
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.r(8)))
                    VStack(alignment: .leading, spacing: 4) {
                        if let info {
                            Text(info.hasPosition ? "Cette photo dit où elle a été prise" : (info.hasPersonal ? "Cette photo garde des informations sur toi" : "Presque rien à retirer"))
                                .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                            Text(info.hasPosition ? "Quiconque la reçoit peut retrouver le lieu exact. Une copie sans la position règle ça."
                                 : "Date, appareil, logiciel : une copie sans métadonnées part sans rien de tout ça.")
                                .font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                        } else {
                            BusyMascot(.inspecting, pixel: 1.5)
                        }
                    }
                }
                if let info {
                    VStack(spacing: 0) {
                        ForEach(Array(info.rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { Divider().overlay(Theme.border.opacity(0.5)) }
                            HStack(spacing: 9) {
                                if Theme.icons != .hidden {
                                    Image(systemName: row.symbol).font(.ui(11)).foregroundStyle(row.personal ? Theme.warn : Theme.text3).frame(width: 16)
                                }
                                Text(row.label).font(.ui(11.5)).foregroundStyle(Theme.text3).frame(width: 76, alignment: .leading)
                                Text(row.value).font(.ui(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                if row.label == "Position", let lat = info.latitude, let lon = info.longitude {
                                    WheelSmallButton(title: "Plans", symbol: "map") {
                                        Finder.open("maps://?ll=\(lat),\(lon)&q=\(context.file.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                                    }
                                    .help("Voir le lieu dans Plans")
                                }
                            }
                            .padding(.vertical, 7)
                        }
                        if info.rows.isEmpty {
                            Text("Aucune métadonnée dans ce fichier.").font(.ui(11.5)).foregroundStyle(Theme.text3).padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: Theme.r(10)).fill(Theme.card.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r(10)).strokeBorder(Theme.border, lineWidth: Theme.line))
                }
            }
            .padding(.top, 4)
        } footer: {
            Button("Sans la position") { save(.gps) }
                .buttonStyle(SoftButtonStyle(prominent: info?.hasPosition == true))
                .disabled(info?.hasPosition != true)
            Spacer()
            Button("Sans aucune métadonnée") { save(.all) }
                .buttonStyle(SoftButtonStyle(prominent: info?.hasPosition != true))
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil)
        }
        .onAppear { read() }
    }

    private func read() {
        guard info == nil else { return }
        let url = context.file.url
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> (WheelPhotoInfo, WheelImageBox?) in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let p = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] else {
                    return (WheelPhotoInfo(), nil)
                }
                let thumb = ConverterImageEngine.uprightImage(src, index: CGImageSourceGetPrimaryImageIndex(src), maxSide: 300)
                return (WheelPhotoInfo.read(p), thumb.map { WheelImageBox($0) })
            }.value
            info = r.0
            thumb = r.1?.image
        }
    }

    private func save(_ mode: ConverterStripMode) {
        let url = context.file.url
        context.save { folder, control in
            try ConverterImageEngine.stripMetadata(url, mode: mode, folder: folder, control: control).url
        }
    }
}
