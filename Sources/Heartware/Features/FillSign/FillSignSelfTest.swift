import Foundation
import PDFKit
import AppKit

/// `--selftest`: the fields of a real form, the result written and read back, passwords, signatures. Writes nothing on disk.
extension FillSignModel {
    func selfTest() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }

        // Texts
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 3
        parts.day = 7
        if let day = Calendar(identifier: .gregorian).date(from: parts) {
            expect(FillSignText.today(day) == "07/03/2026", "date du jour : « \(FillSignText.today(day)) » au lieu de 07/03/2026")
        }
        expect(Self.initials(of: "Camille Martin") == "CM" && Self.initials(of: "Jean-Luc Picard") == "JLP", "initiales d'un nom")
        expect(FillSignExport.outputName("Bail", signed: true) == "Bail – signé" && FillSignExport.outputName("Bail", signed: false) == "Bail – rempli",
               "nom de la copie")
        let size = FillSignText.size("Lu et approuvé\nCamille", fontSize: 12)
        expect(size.height == FillSignText.lineHeight(12) * 2 && size.width > 60, "taille d'un texte sur deux lignes : \(size)")

        // Signatures
        let strokes = [[CGPoint(x: 50, y: 40), CGPoint(x: 90, y: 70)], [CGPoint(x: 120, y: 20)]]
        if let n = FillSignDraw.normalized(strokes, pen: 2) {
            let all = n.strokes.flatMap { $0 }
            expect(all.map(\.x).min() == 2 && all.map(\.y).min() == 2, "signature recadrée : départ \(all.first ?? .zero)")
            expect(n.size == CGSize(width: 74, height: 54), "signature recadrée : taille \(n.size)")
        } else {
            failures.append("signature dessinée refusée")
        }
        expect(FillSignDraw.normalized([[CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 2)]], pen: 2) == nil, "un simple clic accepté comme signature")
        let dense = (0...100).map { CGPoint(x: Double($0) * 0.2, y: 0) }
        let thin = FillSignDraw.thinned(dense, spacing: 1.5)
        expect(thin.count < 20 && thin.last == dense.last, "points d'un trait : \(thin.count) gardés")
        var pad = FillSignPad(kind: .signature)
        expect(pad.signature == nil, "signature vide acceptée")
        pad.mode = .type
        pad.text = "  Camille Martin "
        if case .typed(let text, _)? = pad.signature?.style { expect(text == "Camille Martin", "signature tapée : « \(text) »") } else { failures.append("signature tapée refusée") }
        failures += imageChecks()

        // Geometry: a page turned a quarter, a box near its top left corner.
        if let doc = ConverterModel.samplePDF("G", pages: 1), let page = doc.page(at: 0) {
            page.rotation = 90
            let shown = FillSignDocument.displayRect(CGRect(x: 50, y: 300, width: 100, height: 50), on: page)
            expect(FillSignDocument.displaySize(page) == CGSize(width: 400, height: 300), "page tournée : taille \(FillSignDocument.displaySize(page))")
            expect(shown == CGRect(x: 300, y: 50, width: 50, height: 100), "page tournée : champ en \(shown)")
        }

        // The demo contract: its fields, then saved and read back.
        failures += formChecks()
        failures += editingChecks()
        return failures.map { "Remplir et signer : " + $0 }
    }

    private func imageChecks() -> [String] {
        // A grey paper with an ink line across it.
        let w = 200, h = 80
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ["image de signature non créée"] }
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: 60, y: 20))
        ctx.addLine(to: CGPoint(x: 140, y: 60))
        ctx.strokePath()
        guard let image = ctx.makeImage(), let cleaned = FillSignImageImport.cleaned(image),
              let back = NSBitmapImageRep(data: cleaned.png) else { return ["signature importée : rien gardé"] }
        var failures: [String] = []
        if back.pixelsWide > 110 || back.pixelsHigh > 70 { failures.append("signature importée non recadrée (\(back.pixelsWide)×\(back.pixelsHigh))") }
        if let corner = back.colorAt(x: 0, y: 0), corner.alphaComponent > 0.05 { failures.append("le papier d'une signature importée reste opaque") }
        return failures
    }

    private func formChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }
        guard let data = FillSignDemo.contract(),
              let doc = try? FillSignDocument(url: nil, name: "Contrat", data: data, password: nil, fromImage: false) else {
            return ["contrat d'essai illisible"]
        }
        let texts = doc.fields.filter { if case .text = $0.kind { return true } else { return false } }
        let checks = doc.fields.filter { if case .checkbox = $0.kind { return true } else { return false } }
        let radios = doc.fields.filter { if case .radio = $0.kind { return true } else { return false } }
        expect(doc.pageCount == 2 && texts.count == 11 && checks.count == 3 && radios.count == 3 && doc.fields.contains { $0.kind == .signature },
               "champs trouvés : \(texts.count) textes, \(checks.count) cases, \(radios.count) boutons radio sur \(doc.pageCount) pages")
        // PDFKit names every choice "Yes" in the forms it writes: the three choices must still be told apart.
        expect(Set(radios.map(\.key)) == ["paiement"] && Set(radios.compactMap(\.onState)).count == 3,
               "boutons radio : \(radios.map { "\($0.key)=\($0.onState ?? "?")" })")
        expect(doc.hasButtons && !doc.fields.isEmpty, "cases à cocher non vues")
        if let name = texts.first(where: { $0.key == "locataire_nom" }) {
            expect(name.page == 0 && abs(name.rect.minY - 237) < 1 && name.rect.height == 17, "champ « nom » mal placé : \(name.rect)")
        }

        var values = doc.initialValues
        values["locataire_nom"] = "Camille Essai"
        let menage = checks.first { $0.key == "menage" }, animal = checks.first { $0.key == "animal" }
        values["menage"] = menage?.onState ?? ""
        values["paiement"] = radios.last?.onState ?? ""
        let signature = FillSignDemo.drawnSignature()
        let items = [
            FillSignItem(page: 1, rect: CGRect(origin: CGPoint(x: 320, y: 300), size: FillSignText.size("Lu et approuvé", fontSize: 11)),
                         content: .text("Lu et approuvé"), fontSize: 11),
            FillSignItem(page: 0, rect: CGRect(x: 60, y: 700, width: 12, height: 12), content: .mark(.check)),
            FillSignItem(page: 1, rect: CGRect(x: 330, y: 330, width: 150, height: 150 / signature.size.width * signature.size.height),
                         content: .signature(signature), ink: .blue)
        ]

        // Final version: everything in the pages, no field left, the text readable.
        if let out = try? FillSignExport.flattened(doc, values: values, items: items), let back = PDFDocument(data: out) {
            expect(back.pageCount == 2, "version finale : \(back.pageCount) pages")
            expect(back.page(at: 0).map(FillSignDocument.displaySize) == doc.pageSizes[0], "version finale : taille de page changée")
            let widgets = (0..<back.pageCount).flatMap { back.page(at: $0)?.annotations ?? [] }.filter(FillSignDocument.isWidget)
            expect(widgets.isEmpty, "version finale : \(widgets.count) champs encore modifiables")
            expect(back.page(at: 1)?.string?.contains("Lu et approuvé") == true, "version finale : texte ajouté absent")
            expect(back.page(at: 0)?.string?.contains("Camille Essai") == true, "version finale : valeur du champ absente")
            // The ticked box is drawn in the page, the other one stays empty.
            if let page = back.page(at: 0), let menage, let animal {
                let ink = { (r: CGRect) in Self.darkPixels(page, in: r.insetBy(dx: 2.5, dy: 2.5)) }
                expect(ink(menage.rect) > 4 && ink(animal.rect) == 0, "version finale : case cochée \(ink(menage.rect)) px, case vide \(ink(animal.rect)) px")
            }
        } else {
            failures.append("version finale non écrite")
        }

        // Editable form: the values are in the fields, the fields stay.
        if let out = try? FillSignExport.filledForm(doc, values: values), let back = PDFDocument(data: out) {
            let found = FillSignDocument.fields(in: back)
            expect(found.fields.count == doc.fields.count, "formulaire modifiable : \(found.fields.count) champs sur \(doc.fields.count)")
            expect(found.values["locataire_nom"] == "Camille Essai", "formulaire modifiable : valeurs relues \(found.values.filter { !$0.value.isEmpty })")
        } else {
            failures.append("formulaire modifiable non écrit")
        }

        // A PDF with a password: asked, refused when wrong, kept on the copy.
        if let plain = PDFDocument(data: data),
           let locked = plain.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "secret", PDFDocumentWriteOption.ownerPasswordOption: "secret"]) {
            func error(_ password: String?) -> String {
                do {
                    _ = try FillSignDocument(url: nil, name: "x", data: locked, password: password, fromImage: false)
                    return "ok"
                } catch FillSignError.locked {
                    return "locked"
                } catch FillSignError.wrongPassword {
                    return "wrong"
                } catch {
                    return "other"
                }
            }
            expect(error(nil) == "locked" && error("faux") == "wrong" && error("secret") == "ok",
                   "mot de passe : \(error(nil)), \(error("faux")), \(error("secret"))")
            if let open = try? FillSignDocument(url: nil, name: "x", data: locked, password: "secret", fromImage: false),
               let out = try? FillSignExport.flattened(open, values: [:], items: []), let back = PDFDocument(data: out) {
                expect(back.isLocked && back.unlock(withPassword: "secret"), "la copie perd le mot de passe de l'original")
            } else {
                failures.append("PDF protégé non enregistré")
            }
        }
        return failures
    }

    /// Dark pixels of a page drawn at 1 point per pixel, in a box of the page as shown (from its top left corner).
    static func darkPixels(_ page: PDFPage, in box: CGRect) -> Int {
        let size = FillSignDocument.displaySize(page)
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let raw = ctx.data else { return -1 }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        page.draw(with: .cropBox, to: ctx)
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var n = 0
        for y in max(0, Int(box.minY))..<min(h, Int(box.maxY)) {
            for x in max(0, Int(box.minX))..<min(w, Int(box.maxX)) {
                let i = (y * w + x) * 4
                if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) < 3 * 110 { n += 1 }
            }
        }
        return n
    }

    /// Placing, moving, resizing, undoing, on a separate model.
    private func editingChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }
        guard let data = FillSignDemo.contract(),
              let doc = try? FillSignDocument(url: nil, name: "Contrat", data: data, password: nil, fromImage: false) else { return [] }
        let m = FillSignModel()
        m.show(doc)
        m.tool = .check
        m.tap(at: CGPoint(x: 100, y: 100), page: 0)
        m.tap(at: CGPoint(x: 100, y: 130), page: 0)
        expect(m.items.count == 2 && m.tool == .check, "coches : \(m.items.count) posées, outil \(m.tool.rawValue)")
        m.tool = .date
        m.tap(at: CGPoint(x: 200, y: 200), page: 1)
        expect(m.items.last?.text == FillSignText.today() && m.tool == .select, "date : « \(m.items.last?.text ?? "") », outil \(m.tool.rawValue)")
        m.undo()
        expect(m.items.count == 2, "annuler : \(m.items.count) éléments au lieu de 2")
        m.redo()
        expect(m.items.count == 3, "rétablir : \(m.items.count) éléments au lieu de 3")
        if let id = m.items.first?.id {
            m.move(id, by: CGSize(width: -500, height: 0))
            expect(m.items.first?.rect.minX == 0, "un élément sort de la page : x = \(m.items.first?.rect.minX ?? -1)")
            m.select(id)
            m.resize(id, width: 30)
            expect(m.items.first.map { abs($0.rect.width - 30) < 0.01 && abs($0.rect.height - 30) < 0.01 } == true, "coche agrandie de travers")
        }
        if let name = doc.fields.first(where: { $0.key == "locataire_nom" }) {
            m.setValue(name, "C")
            m.setValue(name, "Ca")
            m.setValue(name, "Cam")
            m.undo()
            expect(m.value(name).isEmpty, "annuler la saisie d'un champ : « \(m.value(name)) » reste")
        }
        if let radio = doc.fields.first(where: { $0.onState == "Cheque" }), let other = doc.fields.first(where: { $0.onState == "Virement" }) {
            m.toggle(other)
            m.toggle(radio)
            expect(m.isOn(radio) && !m.isOn(other), "boutons radio : deux choix à la fois")
        }
        if let box = doc.fields.first(where: { $0.key == "animal" }) {
            m.toggle(box)
            m.toggle(box)
            expect(!m.isOn(box), "case à cocher : ne se décoche pas")
        }
        m.selection = m.items.last?.id
        m.copyToAllPages()
        expect(m.items.count == 4, "sur toutes les pages : \(m.items.count) éléments au lieu de 4")
        expect(m.hasChanges, "document modifié vu comme intact")
        failures += windowChecks()
        return failures
    }

    /// The window: its size on small and large screens, the document that moves into it, what closing it leaves.
    private func windowChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }
        let big = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let wide = FillSignWindow.frame(wanted: FillSignWindow.size, in: big)
        expect(wide.size == FillSignWindow.size && abs(wide.midX - big.midX) <= 1 && abs(wide.midY - big.midY) <= 1,
               "fenêtre sur un grand écran : \(wide)")
        let laptop = CGRect(x: 0, y: 38, width: 1440, height: 837)
        let small = FillSignWindow.frame(wanted: FillSignWindow.size, in: laptop)
        expect(laptop.contains(small) && small.height >= laptop.height - 13 && small.width == FillSignWindow.size.width,
               "fenêtre sur un petit écran : \(small) dans \(laptop)")
        let tiny = FillSignWindow.frame(wanted: CGSize(width: 3000, height: 3000), in: CGRect(x: 0, y: 0, width: 700, height: 500))
        expect(tiny.width <= 700 && tiny.height <= 500, "fenêtre plus grande que l'écran : \(tiny)")

        guard let data = FillSignDemo.contract() else { return failures }
        let url = URL(fileURLWithPath: "/tmp/Contrat essai.pdf")
        guard let doc = try? FillSignDocument(url: url, name: "Contrat essai", data: data, password: nil, fromImage: false) else { return failures }
        let m = FillSignModel()
        m.show(doc)
        m.tool = .check
        m.tap(at: CGPoint(x: 100, y: 100), page: 0)
        expect(m.windowKeeps(URL(fileURLWithPath: "/tmp/./Contrat essai.pdf")), "le document ouvert est relu en passant dans sa fenêtre")
        expect(!m.windowKeeps(URL(fileURLWithPath: "/tmp/Autre.pdf")), "un autre document pris pour celui qui est ouvert")
        expect(!m.isIdle, "fenêtre avec un document vue comme vide")
        m.passwordFor = url
        m.windowDidClose()
        expect(m.document == nil && m.items.isEmpty && m.passwordFor == nil && m.undoCount == 0 && m.isIdle,
               "fenêtre fermée : le document reste ouvert (\(m.document?.name ?? "aucun"), \(m.items.count) ajouts)")
        expect(m.windowMayClose(), "fenêtre sans document : sa fermeture demande confirmation")
        // A password given up with no document behind it: the window has nothing left and closes.
        m.passwordFor = url
        expect(!m.isIdle, "mot de passe demandé : fenêtre vue comme vide")
        m.passwordFor = nil
        expect(m.isIdle, "mot de passe abandonné : la fenêtre resterait ouverte à vide")
        return failures
    }
}
