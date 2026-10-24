import Foundation
import CoreGraphics
import ImageIO

extension WheelModel {
    /// The wheel's rules as pure checks: geometry, gestures, what each kind of file is offered, crop, sizes, the search
    /// for sensitive text, the reading of a photo's metadata, and a few drawings.
    func selfTest() -> [String] {
        WheelChecks.all()
    }
}

enum WheelChecks {
    static func all() -> [String] {
        geometry() + gestures() + menus() + hub() + settings() + crop() + sizes() + sensitive() + photoInfo() + drawings()
    }

    private static func geometry() -> [String] {
        var f: [String] = []
        let g = WheelGeometry(formats: 4, tools: 8)
        if g.hit(.zero) != .hub { f.append("Le centre de la roue n'est pas le moyeu") }
        let mid = (WheelGeometry.split + WheelGeometry.radius) / 2
        if g.hit(CGPoint(x: 0, y: -mid)) != .tool(0) { f.append("Le haut de l'anneau extérieur n'est pas le premier outil") }
        if g.hit(CGPoint(x: mid, y: 0)) != .tool(2) { f.append("La droite de l'anneau extérieur n'est pas le troisième outil (\(String(describing: g.hit(CGPoint(x: mid, y: 0)))))") }
        if g.hit(CGPoint(x: -mid * 0.7, y: -mid * 0.7)) != .tool(7) { f.append("En haut à gauche, ce n'est pas le dernier outil") }
        let inner = (WheelGeometry.hub + WheelGeometry.split) / 2
        if g.hit(CGPoint(x: inner, y: 0)) != .format(1) { f.append("La droite de l'anneau intérieur n'est pas le deuxième format") }
        if g.hit(CGPoint(x: 0, y: inner)) != .format(2) { f.append("Le bas de l'anneau intérieur n'est pas le troisième format") }
        if g.hit(CGPoint(x: WheelGeometry.radius + 40, y: 0)) != nil { f.append("Hors de la roue, un segment répond encore") }
        let single = WheelGeometry(formats: 0, tools: 3)
        if single.hit(CGPoint(x: 0, y: -inner)) != .tool(0) { f.append("Sans formats, l'anneau des outils ne prend pas toute la place") }
        if WheelGeometry.index(angle: -Double.pi / 2 + 0.01, count: 6) != 0 || WheelGeometry.index(angle: -Double.pi / 2 - 0.01, count: 6) != 0 {
            f.append("Le premier segment n'est pas centré en haut")
        }
        if WheelGeometry.index(angle: 3 * Double.pi, count: 4) != 3 { f.append("Un angle de plus d'un tour ne retombe pas sur le bon segment") }
        // The panel stays on screen, the wheel whole.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let corner = WheelGeometry.panelFrame(center: CGPoint(x: 5, y: 5), visible: screen)
        if corner.minX + WheelGeometry.margin < 0 || corner.minY + WheelGeometry.margin < 0 { f.append("La roue sort de l'écran dans un coin") }
        // Moving away: whole on the wheel, fading around it, gone past the distance.
        if WheelGeometry.fade(beyond: -40, limit: 170) != 1 || WheelGeometry.fade(beyond: 5, limit: 170) != 1 { f.append("La roue s'estompe sous le pointeur") }
        if let a = WheelGeometry.fade(beyond: 90, limit: 170), !(a > 0.25 && a < 1) { f.append("La roue ne s'estompe pas quand on s'éloigne (\(a))") }
        if WheelGeometry.fade(beyond: 171, limit: 170) != nil { f.append("La roue reste quand on s'en éloigne de plus de la distance") }
        if let a = WheelGeometry.fade(beyond: 40, limit: 170), let b = WheelGeometry.fade(beyond: 120, limit: 170), b >= a {
            f.append("La roue ne pâlit pas à mesure qu'on s'éloigne")
        }
        let middle = WheelGeometry.panelFrame(center: CGPoint(x: 700, y: 450), visible: screen)
        if middle.midX != 700 || middle.midY != 450 { f.append("Au milieu de l'écran, la roue n'est pas centrée sous le pointeur") }
        return f
    }

    private static func gestures() -> [String] {
        var f: [String] = []
        var shake = WheelShake()
        var t = 0.0
        var done = false
        for x in [0.0, 25, 50, 20, -10, 20, 50, 20] {
            done = shake.feed(x: CGFloat(x), at: t) || done
            t += 0.05
        }
        if !done { f.append("Un aller-retour rapide n'ouvre pas la roue") }
        var straight = WheelShake()
        var opened = false
        for i in 0..<40 { opened = straight.feed(x: CGFloat(i * 12), at: Double(i) * 0.02) || opened }
        if opened { f.append("Un glisser en ligne droite ouvre la roue") }
        var overshoot = WheelShake()
        opened = false
        for (i, x) in [0.0, 60, 120, 100, 80, 78].enumerated() { opened = overshoot.feed(x: CGFloat(x), at: Double(i) * 0.06) || opened }
        if opened { f.append("Dépasser un dossier et revenir ouvre la roue") }
        var slow = WheelShake()
        opened = false
        for (i, x) in [0.0, 30, 0, 30, 0].enumerated() { opened = slow.feed(x: CGFloat(x), at: Double(i) * 0.5) || opened }
        if opened { f.append("Des allers-retours lents ouvrent la roue") }
        if !WheelGestureRules.held(downAt: 10, movedAt: 10.5, delay: 0.45) || WheelGestureRules.held(downAt: 10, movedAt: 10.2, delay: 0.45) {
            f.append("La pause avant le glisser n'est pas mesurée")
        }
        if WheelGestureRules.moved(from: .zero, to: CGPoint(x: 2, y: 2)) { f.append("Une main qui tremble compte comme un départ") }
        return f
    }

    private static func file(_ name: String) -> WheelFile {
        WheelFile(url: URL(fileURLWithPath: "/tmp/" + name), kind: ConverterKind.detect(name: name, isDirectory: false))
    }

    private static func menus() -> [String] {
        var f: [String] = []
        let all = WheelCapabilities(ffmpeg: true, webp: true)
        let none = WheelCapabilities()
        let jpeg = WheelMenu.make([file("photo.jpg")], chosen: nil, capabilities: all)
        if jpeg.formats.contains(.jpeg) { f.append("Un JPEG se voit proposer « En JPEG »") }
        if !jpeg.tools.contains(.crop) || !jpeg.tools.contains(.backdrop) { f.append("Une photo n'a pas Recadrer et Fond") }
        if jpeg.formats.count > WheelMenu.maxFormats || jpeg.tools.count > WheelMenu.maxTools { f.append("La roue d'une photo déborde") }
        if !WheelMenu.make([file("capture.png")], chosen: nil, capabilities: none).formats.contains(.jpeg) { f.append("Un PNG n'a pas « En JPEG »") }
        let two = WheelMenu.make([file("a.jpg"), file("b.heic")], chosen: nil, capabilities: all)
        if two.tools.contains(.crop) || two.tools.contains(.metadata) { f.append("Deux photos se voient proposer une fenêtre pour une seule") }
        if !two.formats.contains(.pdf) || WheelAction.pdf.title(count: 2, family: .image) != "Assembler en PDF" { f.append("Deux photos ne s'assemblent pas en PDF") }
        let pdf = WheelMenu.make([file("contrat.pdf")], chosen: nil, capabilities: all)
        if pdf.tools.contains(.merge) { f.append("Un seul PDF se voit proposer la fusion") }
        if !pdf.formats.contains(.word) || !pdf.tools.contains(.pdfPages) { f.append("Un PDF n'a pas Word et Pages") }
        if !WheelMenu.make([file("a.pdf"), file("b.pdf")], chosen: nil, capabilities: all).tools.contains(.merge) { f.append("Deux PDF ne se fusionnent pas") }
        if WheelMenu.available([file("photo.jpg")], in: [.webp], capabilities: none) == [.webp] { f.append("WebP proposé sans ffmpeg") }
        if WheelMenu.available([file("photo.jpg")], in: [.webp], capabilities: WheelCapabilities(ffmpeg: true, webp: false)) == [.webp] {
            f.append("WebP proposé avec un ffmpeg qui ne sait pas l'écrire")
        }
        let m4a = WheelMenu.make([file("mémo.m4a")], chosen: nil, capabilities: none)
        if m4a.formats.contains(.aac) || m4a.formats.contains(.alac) || m4a.formats.contains(.mp3) { f.append("Un M4A se voit proposer AAC, ALAC ou MP3 sans ffmpeg") }
        let mixed = WheelMenu.make([file("a.jpg"), file("b.mov")], chosen: nil, capabilities: all)
        if !mixed.formats.isEmpty || mixed.tools != [.zip, .airdrop] { f.append("Une photo et une vidéo ensemble : \(mixed.tools.map(\.label))") }
        let zip = WheelMenu.make([file("photos.zip")], chosen: nil, capabilities: all)
        if !zip.tools.contains(.extract) || zip.tools.contains(.zip) { f.append("Une archive ne s'extrait pas ou se recompresse") }
        // The user's own order, with an action that does not suit that file skipped.
        let custom = WheelMenu.make([file("photo.jpg")], chosen: [.cutout, .pdfRotate, .crop, .png], capabilities: all)
        if custom.tools != [.cutout, .crop] || custom.formats != [.png] { f.append("L'ordre choisi n'est pas suivi") }
        for family in WheelFamily.allCases {
            if WheelMenu.make([WheelModel.sample(family)], chosen: nil, capabilities: none).isEmpty { f.append("La roue des \(family.title) est vide") }
            if Set(family.defaultActions).count != family.defaultActions.count { f.append("Une action en double sur la roue des \(family.title)") }
        }
        for a in WheelAction.allCases {
            if a.label.count > 11 { f.append("L'étiquette « \(a.label) » ne tient pas dans son segment") }
            if a.accepts.isEmpty { f.append("\(a.title) n'accepte aucun fichier") }
            if a.isFormat && a.editor != nil { f.append("Le format \(a.label) ouvre une fenêtre") }
        }
        return f
    }

    private static func settings() -> [String] {
        var f: [String] = []
        let json = #"{"enabled": false, "layouts": {"image": ["crop", "disparue", "png"]}}"#
        guard let s = try? JSONDecoder().decode(WheelSettings.self, from: Data(json.utf8)) else { return ["Réglages anciens illisibles"] }
        if s.enabled || !s.hold || !s.shake || s.destination != .beside || !s.instant || s.leaveDistance != 3.5 {
            f.append("Un réglage absent ne prend pas sa valeur par défaut")
        }
        if s.layouts["image"] != [.crop, .png] { f.append("Une action inconnue efface toute la roue choisie") }
        if let back = try? JSONDecoder().decode(WheelSettings.self, from: JSONEncoder().encode(s)), back != s { f.append("Les réglages ne se relisent pas") }
        if s.folder != nil || s.lastUsed != nil { f.append("Un dossier des copies ou une date d'usage sortis de nulle part") }
        let folder = #"{"destination": "folder", "folder": "/Users/exemple/Copies"}"#
        if let d = try? JSONDecoder().decode(WheelSettings.self, from: Data(folder.utf8)), d.destination != .folder || d.folder != "/Users/exemple/Copies" {
            f.append("Le dossier choisi pour les copies ne se relit pas")
        }
        let unknown = #"{"destination": "nulle-part", "enabled": false}"#
        if let d = try? JSONDecoder().decode(WheelSettings.self, from: Data(unknown.utf8)) {
            if d.destination != .beside || d.enabled { f.append("Une destination inconnue efface les autres réglages") }
        } else {
            f.append("Une destination inconnue rend les réglages illisibles")
        }
        var used = WheelSettings()
        used.lastUsed = Date(timeIntervalSince1970: 1_800_000_000)
        if let back = try? JSONDecoder().decode(WheelSettings.self, from: JSONEncoder().encode(used)), back.lastUsed != used.lastUsed {
            f.append("La date de la dernière copie ne se relit pas")
        }
        let place = WheelJobs.folder(for: URL(fileURLWithPath: "/tmp/a.jpg"), destination: .folder, custom: "/dossier/qui/n'existe/pas")
        if place.folder != ConverterDestination.downloadsURL || place.note == nil { f.append("Un dossier choisi disparu ne renvoie pas vers Téléchargements") }
        if WheelJobs.folder(for: URL(fileURLWithPath: "/tmp/a.jpg"), destination: .downloads).folder != ConverterDestination.downloadsURL {
            f.append("« Dans Téléchargements » ne va pas dans Téléchargements")
        }
        return f
    }

    /// The Convertisseur's window: what it lists for each kind of file, and how the launcher's operations reach it.
    private static func hub() -> [String] {
        var f: [String] = []
        let all = WheelCapabilities(ffmpeg: true, webp: true)
        func list(_ names: [String]) -> [WheelAction] {
            let files = names.map(file)
            let fam = WheelFamily.of(files.map(\.kind))
            return WheelMenu.available(files, in: WheelAction.allCases, capabilities: all).filter { !$0.coveredInHub(fam) }
        }
        let photo = list(["photo.jpg"])
        if !photo.contains(.convert) || photo.contains(.png) || photo.contains(.heic) { f.append("Une photo : « Changer de format » absent ou formats en double") }
        for a in [WheelAction.crop, .strip, .rename, .sign, .qrRead, .compress, .pdf] where !photo.contains(a) { f.append("Une photo sans « \(a.title) »") }
        let pdf = list(["contrat.pdf"])
        for a in [WheelAction.sign, .pdfSplit, .pdfImages, .pdfRotate, .pdfCompress, .word] where !pdf.contains(a) { f.append("Un PDF sans « \(a.title) »") }
        if pdf.contains(.jpeg) || pdf.contains(.merge) { f.append("Un seul PDF : « En JPEG » en double ou une fusion") }
        if list(["a.pdf", "b.pdf"]).contains(.sign) { f.append("Deux PDF à signer à la fois") }
        let around = list(["a.pdf", "photo.jpg"])
        if !around.contains(.merge) || around.contains(.convert) { f.append("Un PDF et une photo : pas de fusion, ou un format commun") }
        if list(["a.jpg", "b.jpg"]).contains(.merge) { f.append("Des photos seules se fusionnent au lieu de s'assembler") }
        let mixed = list(["a.jpg", "b.mov"])
        if !mixed.contains(.rename) || !mixed.contains(.zip) || mixed.contains(.convert) { f.append("Une photo et une vidéo : \(mixed.map(\.label))") }
        if !list(["mémo.m4a"]).contains(.convert) || list(["mémo.m4a"]).contains(.wav) { f.append("Un son : formats mal regroupés") }
        if !list(["vacances.mov"]).contains(.gif) || list(["vacances.mov"]).contains(.mp4) { f.append("Une vidéo : GIF absent ou MP4 en double") }
        if list(["rapport.docx"]).contains(.pdf) || !list(["rapport.docx"]).contains(.convert) { f.append("Un document : « En PDF » en double") }
        for op in ConverterOperation.allCases where op != .qrGenerate {
            guard let a = WheelAction.forOperation(op) else { f.append("« \(op.commandTitle) » ne mène à rien dans la fenêtre"); continue }
            guard let kind = ConverterKind.allCases.first(where: { op.accepts.contains($0) }) else { continue }
            if a.hubOperation(WheelFamily.of(kind)) != op { f.append("« \(op.commandTitle) » ouvre « \(a.title) », qui fait autre chose") }
        }
        for family in WheelFamily.allCases {
            let a = WheelAction.suggested(family, count: 1)
            if !list([WheelModel.sample(family).name]).contains(a) && family != .folder && family != .other {
                f.append("Les \(family.title) s'ouvrent sur « \(a.title) », qu'ils n'ont pas")
            }
        }
        for a in WheelAction.allCases {
            if a.opensHub && a.isFormat { f.append("Le format \(a.label) ouvre la fenêtre") }
            if a.opensHub && a.hubOperation(.image) == nil && a.hubOperation(.pdf) == nil && a.hubOperation(.document) == nil {
                f.append("« \(a.title) » ouvre la fenêtre sans réglages")
            }
            if a.verb(.image, count: 1).isEmpty { f.append("« \(a.title) » n'a pas de bouton") }
        }
        if WheelAction.copyText.hubOperation(.image) != .ocr || WheelAction.copyText.runsWithOptions(.image) {
            f.append("« Copier le texte » passe par l'OCR du convertisseur au lieu du presse-papiers")
        }
        return f
    }

    private static func crop() -> [String] {
        var f: [String] = []
        let square = WheelCropMath.fitted(1, around: CGPoint(x: 0.5, y: 0.5))
        if square != CGRect(x: 0, y: 0, width: 1, height: 1) { f.append("Le carré d'une image carrée n'est pas l'image entière") }
        let wide = WheelCropMath.unitRatio(16 / 9, image: CGSize(width: 4000, height: 3000))
        let r = WheelCropMath.fitted(wide, around: CGPoint(x: 0.5, y: 0.5))
        if abs(r.width * 4000 / (r.height * 3000) - 16 / 9) > 0.001 || r.width != 1 { f.append("Le 16:9 d'une photo 4:3 est faux") }
        let start = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)
        let corner = WheelCropMath.resized(start, handle: .bottomRight, by: CGSize(width: 0.3, height: 0.05), ratio: 1)
        if abs(corner.width - corner.height) > 0.0001 || corner.minX != 0.2 || corner.minY != 0.2 { f.append("Un coin tiré ne garde pas le format ni le coin opposé") }
        let edge = WheelCropMath.resized(start, handle: .left, by: CGSize(width: -0.5, height: 0), ratio: nil)
        if edge.minX != 0 || edge.maxX != start.maxX { f.append("Le bord gauche sort de l'image") }
        let tiny = WheelCropMath.resized(start, handle: .right, by: CGSize(width: -1, height: 0), ratio: nil)
        if tiny.width < WheelCropMath.minSide - 0.0001 { f.append("Le cadre devient plus petit que le minimum") }
        let moved = WheelCropMath.moved(start, by: CGSize(width: 2, height: -2))
        if moved.maxX > 1.0001 || moved.minY < 0 { f.append("Le cadre déplacé sort de l'image") }
        let bigRatio = WheelCropMath.resized(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), handle: .bottomRight, by: CGSize(width: 0.9, height: 0.9), ratio: 2)
        if bigRatio.maxX > 1.0001 || bigRatio.maxY > 1.0001 || abs(bigRatio.width / bigRatio.height - 2) > 0.001 { f.append("Un coin tiré trop loin sort de l'image ou perd son format") }
        if WheelCropMath.handle(at: CGPoint(x: 101, y: 99), frame: CGRect(x: 100, y: 100, width: 200, height: 100)) != .topLeft { f.append("Le coin du cadre ne s'attrape pas") }
        if WheelCropMath.handle(at: CGPoint(x: 200, y: 150), frame: CGRect(x: 100, y: 100, width: 200, height: 100)) != .move { f.append("Le milieu du cadre ne le déplace pas") }
        let px = WheelImageEngine.pixelRect(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5), width: 1000, height: 600)
        if px != CGRect(x: 250, y: 300, width: 500, height: 300) { f.append("Le recadrage en pixels est faux (\(px))") }
        return f
    }

    private static func sizes() -> [String] {
        var f: [String] = []
        if WheelShrinkSettings.targetSide(.side1920, longest: 4032) != 1920 { f.append("1 920 px ne réduit pas une photo de 4 032 px") }
        if WheelShrinkSettings.targetSide(.side1920, longest: 1200) != 0 { f.append("1 920 px agrandit une petite image") }
        if WheelShrinkSettings.targetSide(.half, longest: 4032) != 2016 { f.append("50 % ne divise pas par deux") }
        let style = WheelBackdropStyle(fill: .clear, padding: 0.1, corner: 0, shadow: 0, ratio: .square)
        let s = WheelImageEngine.backdropSize(image: CGSize(width: 1000, height: 500), style: style)
        if s.width != s.height || s.width < 1200 { f.append("Le fond carré d'une image large est faux (\(s))") }
        let auto = WheelImageEngine.backdropSize(image: CGSize(width: 1000, height: 500), style: WheelBackdropStyle(padding: 0.1, ratio: .free))
        if auto != CGSize(width: 1200, height: 700) { f.append("La marge du fond est fausse (\(auto))") }
        if WheelMediaEngine.moment(65) != "1 min 05 s" || WheelMediaEngine.moment(12.7) != "12 s" || WheelMediaEngine.moment(3725) != "1 h 02 min 05 s" {
            f.append("Le moment d'une image de vidéo est mal écrit")
        }
        if WheelMediaEngine.moment(65).contains(":") { f.append("Un nom de fichier contient « : »") }
        return f
    }

    private static func sensitive() -> [String] {
        var f: [String] = []
        let text = "Écris à camille.martin@exemple.fr ou au 06 12 34 56 78, IBAN FR76 3000 6000 0112 3456 7890 189."
        let found = WheelSensitive.ranges(in: text).map { String(text[$0]) }
        if !found.contains(where: { $0.contains("@exemple.fr") }) { f.append("Une adresse e-mail n'est pas trouvée") }
        if !found.contains(where: { $0.contains("06 12 34 56 78") }) { f.append("Un numéro de téléphone n'est pas trouvé (\(found))") }
        if !found.contains(where: { $0.hasPrefix("FR76") }) { f.append("Un IBAN n'est pas trouvé (\(found))") }
        if !WheelSensitive.ranges(in: "Carte 4970 1012 3456 7890").contains(where: { _ in true }) { f.append("Un numéro de carte n'est pas trouvé") }
        if !WheelSensitive.ranges(in: "Le sommet du Mont Blanc culmine à 4 806 m").isEmpty { f.append("Une phrase ordinaire est prise pour un secret") }
        return f
    }

    private static func photoInfo() -> [String] {
        var f: [String] = []
        let props: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 4032, kCGImagePropertyPixelHeight: 3024, kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:14 18:32:05", kCGImagePropertyExifFNumber: 1.8,
                                             kCGImagePropertyExifExposureTime: 0.0015625] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "Apple iPhone 15 Pro"] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.83, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 6.86, kCGImagePropertyGPSLongitudeRef: "W"] as [CFString: Any],
        ]
        let info = WheelPhotoInfo.read(props)
        if !info.hasPosition || info.longitude ?? 0 >= 0 { f.append("La position (ouest) d'une photo est mal lue") }
        if info.rows.first(where: { $0.label == "Appareil" })?.value != "Apple iPhone 15 Pro" { f.append("L'appareil est répété (« Apple Apple… »)") }
        if info.rows.first(where: { $0.label == "Dimensions" })?.value.hasPrefix(Fmt.int(3024)) != true { f.append("Les dimensions d'une photo en portrait sont à l'envers") }
        if info.rows.first(where: { $0.label == "Réglages" })?.value.contains("1/640 s") != true { f.append("Le temps de pose est mal écrit") }
        if !WheelPhotoInfo.read([:]).rows.isEmpty { f.append("Une image sans métadonnées en invente") }
        return f
    }

    private static func drawings() -> [String] {
        var f: [String] = []
        guard let ctx = WheelImageEngine.context(width: 40, height: 20, alpha: false) else { return ["Pas de contexte de dessin"] }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        guard let image = ctx.makeImage() else { return ["Pas d'image de test"] }
        let turned = WheelImageEngine.rotated(image, quarterTurns: 1)
        if turned?.width != 20 || turned?.height != 40 { f.append("Un quart de tour ne croise pas largeur et hauteur") }
        if WheelImageEngine.rotated(image, quarterTurns: 4)?.width != 40 { f.append("Quatre quarts de tour changent l'image") }
        let style = WheelBackdropStyle(fill: .gradient(0), padding: 0.25, corner: 0.1, shadow: 0.5, ratio: .free)
        let framed = WheelImageEngine.backdrop(image, hasAlpha: false, style: style, blurred: nil)
        if framed?.width != 60 || framed?.height != 40 { f.append("L'image sur son fond n'a pas la bonne taille (\(framed?.width ?? 0)×\(framed?.height ?? 0))") }
        let picture = WheelImageEngine.Picture(image: image, uti: "public.png", properties: [:], hasAlpha: false)
        let marks = [WheelMark(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]),
                     WheelMark(kind: .redact, points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1)]),
                     WheelMark(kind: .text, points: [CGPoint(x: 0.5, y: 0.2)], text: "ok")]
        guard let marked = WheelImageEngine.marked(picture, marks: marks, layers: nil) else { return f + ["Les annotations ne se dessinent pas"] }
        if marked.width != 40 || marked.height != 20 { f.append("L'image annotée change de taille") }
        // The black box covers the left half: its pixel is near black, the right side keeps its grey.
        if let left = gray(marked, x: 2, y: 2), left > 0.15 { f.append("Le masque noir ne couvre pas sa zone (\(left))") }
        if let right = gray(marked, x: 37, y: 3), abs(right - 0.5) > 0.08 { f.append("Le masque déborde de sa zone (\(right))") }
        if !WheelMark(kind: .box, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.501, y: 0.6)]).isEmpty { f.append("Un cadre sans largeur est gardé") }
        return f
    }

    /// The grey level of a pixel (0 black, 1 white), y from the top.
    private static func gray(_ image: CGImage, x: Int, y: Int) -> CGFloat? {
        guard let ctx = WheelImageEngine.context(width: image.width, height: image.height, alpha: true) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        // A bitmap's first row in memory is the top of the picture.
        let row = y
        let p = data.advanced(by: row * ctx.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (CGFloat(p[0]) + CGFloat(p[1]) + CGFloat(p[2])) / (3 * 255)
    }
}
