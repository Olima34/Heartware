import Foundation
import PDFKit

/// The saved result, made from a fresh copy of the document: the original file is never changed.
enum FillSignExport {
    /// Everything in the pages: the fields with their values as the PDF draws them, then the text, marks and signatures.
    /// The look is final: nobody can change a value or move a signature by mistake. Keeps the password of the original.
    static func flattened(_ document: FillSignDocument, values: [String: String], items: [FillSignItem]) throws -> Data {
        let doc = try FillSignDocument.open(data: document.data, password: document.password)
        FillSignDocument.apply(values, to: doc, fields: document.fields, buttonsOff: true)
        // The ticked boxes, drawn like the editor shows them.
        let marks = document.fields.compactMap { f -> FillSignItem? in
            guard !f.readOnly, let on = f.onState, !on.isEmpty, values[f.key] == on else { return nil }
            let m = FillSignDocument.buttonMark(f)
            return FillSignItem(page: f.page, rect: m.rect, content: .mark(m.mark))
        }
        let out = NSMutableData()
        var first = CGRect(origin: .zero, size: document.pageSizes.first ?? CGSize(width: 595, height: 842))
        var info: [CFString: Any] = [kCGPDFContextCreator: "Heartware"]
        if let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { info[kCGPDFContextTitle] = title }
        if let password = document.password, !password.isEmpty {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary) else {
            throw FillSignError.failed("Le PDF n'a pas pu être créé.")
        }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), document.pageSizes.indices.contains(i) else { continue }
            let size = document.pageSizes[i]
            var media = CGRect(origin: .zero, size: size)
            let box = Data(bytes: &media, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
            ctx.saveGState()
            // The page as shown (turned, cropped), with its annotations and the fields' values.
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            for item in marks + items where item.page == i { FillSignDraw.draw(item, in: ctx) }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// The same document with its fields filled in and still editable (for a form to send back as a form).
    /// Only the fields' values: added text and signatures need `flattened`.
    static func filledForm(_ document: FillSignDocument, values: [String: String]) throws -> Data {
        let doc = try FillSignDocument.open(data: document.data, password: document.password)
        FillSignDocument.apply(values, to: doc, fields: document.fields)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let password = document.password, !password.isEmpty {
            options[.userPasswordOption] = password
            options[.ownerPasswordOption] = password
        }
        guard let data = doc.dataRepresentation(options: options) else { throw FillSignError.failed("Le PDF n'a pas pu être écrit.") }
        return data
    }

    /// "Contrat – signé", or "– rempli" when nothing was signed.
    static func outputName(_ base: String, signed: Bool) -> String {
        "\(base) – \(signed ? "signé" : "rempli")"
    }

    /// Next to the original when its folder can be written to, in Téléchargements otherwise.
    static func folder(for document: FillSignDocument) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FS.home + "/Downloads")
        guard let dir = document.url?.deletingLastPathComponent(), FileManager.default.isWritableFile(atPath: dir.path) else { return downloads }
        return dir
    }
}
