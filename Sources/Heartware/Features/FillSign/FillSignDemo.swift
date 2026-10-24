import Foundation
import PDFKit
import AppKit

/// The demo's fictional document: a holiday rental contract drawn in memory, with real form fields. Nothing here exists
/// on any Mac; the names, addresses and amounts are made up.
@MainActor
enum FillSignDemo {
    static let path = DemoData.home + "/Documents/Maison/Contrat location Étretat.pdf"

    /// The contract, two A4 pages: tenant, stay, payment, conditions and signatures.
    nonisolated static func contract() -> Data? {
        let width: CGFloat = 595.28, height: CGFloat = 841.89
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Contrat de location saisonnière"] as CFDictionary) else { return nil }
        let black = CGColor(gray: 0.1, alpha: 1), grey = CGColor(gray: 0.42, alpha: 1), rule = CGColor(gray: 0.78, alpha: 1)
        let accent = CGColor(srgbRed: 0.2, green: 0.36, blue: 0.5, alpha: 1)
        var fields: [(page: Int, kind: String, name: String, rect: CGRect)] = []

        func begin() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: 1, y: -1)
        }
        func end() {
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 10.5, bold: Bool = false, color: CGColor = black) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            ctx.restoreGState()
        }
        /// A paragraph wrapped at `w`, returns the y under it.
        func paragraph(_ s: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, size: CGFloat = 10) -> CGFloat {
            let font = FillSignText.font(size)
            var line = "", yy = y
            for word in s.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if FillSignText.width(candidate, font: font) > w, !line.isEmpty {
                    text(line, x, yy, size: size, color: grey)
                    yy += size * 1.45
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            if !line.isEmpty { text(line, x, yy, size: size, color: grey) }
            return yy + size * 1.45
        }
        func heading(_ s: String, _ y: CGFloat) {
            text(s, 56, y, size: 12, bold: true, color: accent)
            ctx.setFillColor(rule)
            ctx.fill(CGRect(x: 56, y: y + 6, width: width - 112, height: 0.6))
        }
        func field(_ page: Int, _ label: String, _ name: String, x: CGFloat, y: CGFloat, w: CGFloat, labelWidth: CGFloat = 120) {
            text(label, x, y, size: 10, color: grey)
            ctx.setFillColor(rule)
            ctx.fill(CGRect(x: x + labelWidth, y: y + 3, width: w - labelWidth, height: 0.7))
            fields.append((page, "text", name, CGRect(x: x + labelWidth, y: y - 13, width: w - labelWidth, height: 17)))
        }
        func tickBox(_ page: Int, _ label: String, _ kind: String, _ name: String, x: CGFloat, y: CGFloat) {
            ctx.setStrokeColor(grey)
            ctx.setLineWidth(0.8)
            if kind == "radio" {
                ctx.strokeEllipse(in: CGRect(x: x, y: y - 10, width: 12, height: 12))
            } else {
                ctx.stroke(CGRect(x: x, y: y - 10, width: 12, height: 12))
            }
            text(label, x + 18, y, size: 10, color: black)
            fields.append((page, kind, name, CGRect(x: x, y: y - 10, width: 12, height: 12)))
        }

        // Page 1
        begin()
        ctx.setFillColor(accent)
        ctx.fill(CGRect(x: 56, y: 52, width: 46, height: 3))
        text("Contrat de location saisonnière", 56, 84, size: 21, bold: true)
        text("Gîte « Les Hortensias » · 12 chemin des Embruns · 76790 Étretat", 56, 104, size: 10.5, color: grey)
        heading("1. Le propriétaire", 146)
        _ = paragraph("Hélène Duval, 8 rue des Tilleuls, 76600 Le Havre, ci-après « le propriétaire », loue le gîte décrit ci-dessus, meublé et équipé pour six personnes.", 56, 168, width - 112)
        heading("2. Le locataire", 222)
        field(0, "Nom et prénom", "locataire_nom", x: 56, y: 250, w: width - 112)
        field(0, "Adresse", "locataire_adresse", x: 56, y: 278, w: width - 112)
        field(0, "Téléphone", "locataire_tel", x: 56, y: 306, w: 270)
        field(0, "E-mail", "locataire_mail", x: 340, y: 306, w: width - 396, labelWidth: 46)
        heading("3. Le séjour", 352)
        field(0, "Arrivée le", "arrivee", x: 56, y: 380, w: 230)
        field(0, "Départ le", "depart", x: 310, y: 380, w: width - 366, labelWidth: 62)
        field(0, "Nombre de personnes", "personnes", x: 56, y: 408, w: 230)
        text("Options :", 56, 440, size: 10, color: grey)
        tickBox(0, "Animal de compagnie", "check", "animal", x: 176, y: 440)
        tickBox(0, "Ménage de fin de séjour (60 €)", "check", "menage", x: 176, y: 462)
        tickBox(0, "Linge de maison (15 € par personne)", "check", "linge", x: 176, y: 484)
        heading("4. Le paiement", 530)
        text("Mode :", 56, 558, size: 10, color: grey)
        tickBox(0, "Virement", "radio", "paiement:Virement", x: 176, y: 558)
        tickBox(0, "Chèque", "radio", "paiement:Cheque", x: 276, y: 558)
        tickBox(0, "Chèques-vacances", "radio", "paiement:Vacances", x: 366, y: 558)
        field(0, "Montant total", "montant", x: 56, y: 590, w: 260)
        field(0, "Acompte (30 %)", "acompte", x: 330, y: 590, w: width - 386, labelWidth: 90)
        _ = paragraph("Le solde est réglé au plus tard trente jours avant l'arrivée. Le dépôt de garantie de 400 € est rendu dans les quinze jours qui suivent le départ, déduction faite des éventuelles réparations.", 56, 630, width - 112)
        ctx.setStrokeColor(rule)
        ctx.setLineWidth(0.8)
        ctx.stroke(CGRect(x: width - 166, y: height - 96, width: 110, height: 44))
        text("Paraphes", width - 160, height - 100, size: 8.5, color: grey)
        text("Page 1 sur 2", 56, height - 50, size: 8.5, color: grey)
        end()

        // Page 2
        begin()
        heading("5. Conditions", 72)
        var y = paragraph("Le locataire occupe les lieux en bon père de famille et les rend dans l'état où il les a trouvés. Il est interdit de fumer à l'intérieur du gîte. Le nombre d'occupants ne peut dépasser celui indiqué au contrat.", 56, 96, width - 112)
        y = paragraph("En cas d'annulation par le locataire plus de trente jours avant l'arrivée, l'acompte est rendu. Au-delà, il reste acquis au propriétaire, sauf si le gîte est loué de nouveau pour la même période.", 56, y + 6, width - 112)
        y = paragraph("Un état des lieux est fait à l'arrivée et au départ. Les clés sont remises en main propre ou déposées dans la boîte à clés dont le code est communiqué la veille de l'arrivée.", 56, y + 6, width - 112)
        heading("6. Signatures", y + 30)
        field(1, "Fait à", "fait_a", x: 56, y: y + 62, w: 250, labelWidth: 44)
        field(1, "le", "fait_le", x: 320, y: y + 62, w: width - 376, labelWidth: 22)
        let top = y + 92
        for (i, who) in ["Le propriétaire", "Le locataire"].enumerated() {
            let x: CGFloat = i == 0 ? 56 : 312
            text(who, x, top, size: 10.5, bold: true)
            text("précédé de la mention « Lu et approuvé »", x, top + 14, size: 8.5, color: grey)
            ctx.setStrokeColor(rule)
            ctx.setLineWidth(0.8)
            ctx.stroke(CGRect(x: x, y: top + 24, width: 226, height: 96))
            if i == 1 { fields.append((1, "signature", "signature_locataire", CGRect(x: x + 8, y: top + 40, width: 210, height: 72))) }
        }
        text("Page 2 sur 2", 56, height - 50, size: 8.5, color: grey)
        end()
        ctx.closePDF()

        // The fields, added with PDFKit as a form editor would.
        guard let doc = PDFDocument(data: data as Data) else { return nil }
        for f in fields {
            guard let page = doc.page(at: f.page) else { continue }
            let bounds = CGRect(x: f.rect.minX, y: height - f.rect.maxY, width: f.rect.width, height: f.rect.height)
            let a = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
            switch f.kind {
            case "text":
                a.widgetFieldType = .text
                a.fieldName = f.name
                a.font = NSFont(name: FillSignText.fontName, size: 11)
            case "check":
                a.widgetFieldType = .button
                a.widgetControlType = .checkBoxControl
                a.fieldName = f.name
                a.buttonWidgetStateString = "Oui"
            case "radio":
                let parts = f.name.split(separator: ":").map(String.init)
                a.widgetFieldType = .button
                a.widgetControlType = .radioButtonControl
                a.fieldName = parts[0]
                a.buttonWidgetStateString = parts[1]
            default:
                a.widgetFieldType = .signature
                a.fieldName = f.name
            }
            let border = PDFBorder()
            border.lineWidth = 0
            a.border = border
            page.addAnnotation(a)
        }
        return doc.dataRepresentation()
    }

    /// A signature that looks handwritten ("Camille", underlined), from key points joined by smooth curves.
    nonisolated static func drawnSignature(ink: FillSignInk = .blue) -> FillSignSignature {
        let capital: [CGPoint] = [(64, 18), (52, 11), (38, 13), (26, 23), (20, 39), (22, 55), (32, 65), (46, 67), (58, 61)].map(CGPoint.init)
        let word: [CGPoint] = [
            (58, 61), (66, 50), (74, 46), (80, 52), (76, 62), (70, 64), (72, 56), (80, 50), (84, 62), (89, 66),
            (93, 53), (97, 48), (101, 54), (100, 66), (103, 54), (108, 48), (112, 54), (111, 66), (115, 54), (120, 48), (124, 54), (124, 65),
            (129, 66), (133, 55), (134, 66), (139, 66), (145, 50), (152, 29), (157, 17), (152, 15), (146, 30), (143, 52), (146, 66), (152, 66),
            (159, 50), (166, 29), (171, 17), (166, 15), (160, 30), (157, 52), (160, 66), (167, 66), (174, 58), (182, 55), (184, 49), (177, 47),
            (170, 56), (173, 66), (184, 66), (197, 58)
        ].map(CGPoint.init)
        let dot: [CGPoint] = [CGPoint(x: 134, y: 41)]
        let flourish: [CGPoint] = [(18, 79), (70, 82), (140, 78), (205, 70), (252, 58)].map(CGPoint.init)
        let strokes = [capital, word, dot, flourish].map { $0.count > 2 ? smooth($0) : $0 }
        let normalized = FillSignDraw.normalized(strokes, pen: FillSignPad.pen) ?? (strokes, CGSize(width: 260, height: 90))
        return FillSignSignature(kind: .signature, style: .drawn(strokes: normalized.strokes, width: FillSignPad.pen), size: normalized.size, ink: ink)
    }

    /// Catmull-Rom points between the key points of a stroke, as a hand would join them.
    nonisolated private static func smooth(_ p: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for k in 0..<5 {
                let t = Double(k) / 5, t2 = t * t, t3 = t2 * t
                func axis(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    nonisolated static func initials() -> FillSignSignature {
        let font = FillSignDraw.scriptFonts.first?.name ?? "Helvetica"
        return FillSignSignature(kind: .initials, style: .typed(text: "CM", font: font), size: FillSignDraw.typedLayout("CM", font: font).size, ink: .blue)
    }

    /// The contract, half filled in, signed by the tenant and initialled on its first page.
    static func fill(_ model: FillSignModel) {
        model.signatures = [drawnSignature(), initials()]
        guard let data = contract(),
              let doc = try? FillSignDocument(url: URL(fileURLWithPath: path), name: "Contrat location Étretat", data: data, password: nil, fromImage: false) else { return }
        model.show(doc)
        model.values.merge([
            "locataire_nom": "Camille Martin", "locataire_adresse": "5 allée des Peupliers, 69003 Lyon",
            "locataire_tel": "06 98 76 54 32", "locataire_mail": "camille.martin@exemple.fr", "arrivee": "10/07/2027",
            "depart": "24/07/2027", "personnes": "4", "montant": "1 260 €", "acompte": "378 €",
            "fait_a": "Lyon", "fait_le": FillSignText.today()
        ]) { $1 }
        // Ménage ticked, paid by bank transfer (the first choice).
        for key in ["menage", "paiement"] {
            if let on = doc.fields.first(where: { $0.key == key })?.onState { model.values[key] = on }
        }
        if let field = doc.fields.first(where: { $0.kind == .signature }) {
            let size = doc.pageSizes[1]
            model.fontSize = 10
            model.ink = .blue
            model.addText("Lu et approuvé", at: CGPoint(x: field.rect.minX + 4, y: field.rect.minY + 4), page: 1, edit: false)
            model.place(drawnSignature(), at: .zero, page: 1, in: field.rect.offsetBy(dx: 0, dy: 10))
            _ = size
        }
        let first = doc.pageSizes[0]
        model.place(initials(), at: CGPoint(x: first.width - 111, y: first.height - 74), page: 0, in: nil)
        model.fontSize = 12
        model.select(nil)
        model.tool = .select
    }
}

extension FillSignModel {
    func loadDemo() {
        FillSignDemo.fill(self)
    }

    /// `--snapshot --demo --page wheel --tab <scene>`, `fillsign-window-panel`: the contract being signed (default),
    /// `signer-signe` (the signed page), `signer-pad` (a new signature, drawn), `signer-taper` (typed), `signer-enregistre`
    /// (saved), `signer-motdepasse` (a PDF with a password), `attente` or `signer-attente` (a document opening).
    func applySnapshotTab(_ tab: String) {
        guard DemoData.isEnabled else { return }
        switch tab {
        case "attente", "signer-attente":
            discard()
            opening = "Bail appartement Lyon.pdf"
        case "signer-motdepasse":
            discard()
            passwordFor = URL(fileURLWithPath: DemoData.home + "/Documents/Maison/Bail appartement Lyon.pdf")
        case "signer-pad", "signer-taper":
            var pad = FillSignPad(kind: .signature)
            pad.ink = .blue
            if tab == "signer-taper" {
                pad.mode = .type
                pad.text = "Camille Martin"
            } else if case .drawn(let strokes, _) = FillSignDemo.drawnSignature().style {
                // Drawn on the line, like a hand would.
                pad.strokes = strokes.map { $0.map { CGPoint(x: $0.x * 1.45 + 90, y: $0.y * 1.45 + 22) } }
            }
            self.pad = pad
        case "signer-signe":
            // The second page, the tenant's signature selected.
            visiblePage = 1
            select(items.first { $0.signature?.kind == .signature }?.id)
        case "signer-enregistre":
            saved = URL(fileURLWithPath: DemoData.home + "/Documents/Maison/Contrat location Étretat – signé.pdf")
        default:
            break
        }
    }
}
