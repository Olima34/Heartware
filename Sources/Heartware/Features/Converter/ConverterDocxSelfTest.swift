import AppKit
import PDFKit

/// `--selftest` for the Word reader and its page layout, in memory: units, colors, numbering, symbols, math letters,
/// a metafile, and a small .docx built here then laid out on pages.
extension ConverterModel {
    static func docxChecks() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append("Word : " + what()) }
        }

        expect(ConverterDocxUnit.twips("240") == 12 && ConverterDocxUnit.twips("1in") == 72 && ConverterDocxUnit.emu("12700") == 1, "unités")
        expect(ConverterDocxColor.adjust("000000", tint: "00", shade: nil) == "FFFFFF", "teinte de thème")
        expect(ConverterDocxColor.adjust("FFFFFF", tint: nil, shade: "80") == "808080", "ombre de thème")
        expect(ConverterDocxColor.mix("FFFFFF", "000000", 0.5) == "808080", "trame de fond")
        expect(ConverterDocxNumbering.roman(1994) == "MCMXCIV", "chiffres romains")
        expect(ConverterDocxNumbering.format(28, "lowerLetter") == "bb" && ConverterDocxNumbering.format(3, "upperLetter") == "C", "lettres")
        expect(ConverterDocxNumbering.format(4, "lowerRoman") == "iv" && ConverterDocxNumbering.format(7, "decimalZero") == "07", "formats")
        expect(ConverterDocxNumbering.symbol("\u{F0B7}", font: "Symbol").text == "•", "puce Symbol")
        expect(ConverterDocxNumbering.symbol("\u{F0A7}", font: "Wingdings").text == "▪", "puce Wingdings")
        expect(ConverterMath.styled("xh", style: "i") == "𝑥ℎ" && ConverterMath.styled("x2", style: "p") == "x2", "lettres mathématiques")
        var tabs = ConverterDocxParaProps()
        tabs.tabs = [ConverterDocxTab(position: 36, align: "left", leader: nil), ConverterDocxTab(position: 72, align: "right", leader: nil)]
        var cleared = ConverterDocxParaProps()
        cleared.tabs = [ConverterDocxTab(position: 36, align: "clear", leader: nil)]
        tabs.merge(cleared)
        expect(tabs.tabs.map(\.position) == [72], "taquets effacés par un style dérivé")

        // A metafile: a red rectangle drawn by a placeable WMF.
        if let image = ConverterMetafile.image(Self.sampleWMF(), size: CGSize(width: 20, height: 20)) {
            expect(Self.pixel(image, x: image.width / 2, y: image.height / 2).red > 0.9, "WMF : rectangle rouge absent")
        } else {
            failures.append("Word : WMF illisible")
        }

        // A small document, end to end.
        guard let docx = Self.sampleDocx() else { return failures + ["Word : document d'essai non créé"] }
        do {
            let doc = try ConverterDocx.read(docx)
            let text = doc.text.string
            let s = doc.sections.first
            expect(abs((s?.pageSize.width ?? 0) - 419.55) < 0.1 && abs((s?.pageSize.height ?? 0) - 595.3) < 0.1, "format A5")
            expect(abs((s?.margins.left ?? 0) - 36) < 0.1, "marges")
            expect(text.contains("1.\tPremier") && text.contains("2.\tSecond"), "liste numérotée : \(text.prefix(80))")
            expect(doc.breaks.count == 1, "saut de page (\(doc.breaks.count))")
            if let range = text.range(of: "Titre d'essai") {
                let i = NSRange(range, in: text).location
                let font = doc.text.attribute(.font, at: i, effectiveRange: nil) as? NSFont
                let color = (doc.text.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                expect(font?.pointSize == 20 && font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "style du titre")
                expect(abs((color?.blueComponent ?? 0) - 0x64 / 255.0) < 0.01, "couleur du titre")
            } else {
                failures.append("Word : titre absent")
            }
            if let range = text.range(of: "Cellule B2") {
                let style = doc.text.attribute(.paragraphStyle, at: NSRange(range, in: text).location, effectiveRange: nil) as? NSParagraphStyle
                let cell = style?.textBlocks.last as? NSTextTableBlock
                expect(cell?.startingRow == 1 && cell?.startingColumn == 1, "case du tableau")
            } else {
                failures.append("Word : tableau absent")
            }
            guard let data = try ConverterPageLayout.render(doc, title: "Essai"), let pdf = PDFDocument(data: data) else {
                return failures + ["Word : PDF non dessiné"]
            }
            expect(pdf.pageCount == 2, "\(pdf.pageCount) pages au lieu de 2")
            let first = pdf.page(at: 0)?.string ?? "", second = pdf.page(at: 1)?.string ?? ""
            expect(first.contains("Titre d'essai") && first.contains("Page 1 sur 2"), "page 1 : \(first.prefix(60))")
            expect(second.contains("Après le saut") && second.contains("Page 2 sur 2"), "page 2 : \(second.prefix(60))")
            expect(abs((pdf.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) - 419.55) < 0.5, "largeur de page du PDF")
        } catch {
            failures.append("Word : \(error.localizedDescription)")
        }
        return failures
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat) {
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (CGFloat(data[0]) / 255, CGFloat(data[1]) / 255)
    }

    /// A placeable WMF: a red brush and a rectangle over its whole frame.
    private static func sampleWMF() -> Data {
        var b: [UInt8] = []
        func w(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func d(_ v: Int) { w(v & 0xFFFF); w(v >> 16 & 0xFFFF) }
        d(0x9AC6_CDD7); w(0); w(0); w(0); w(100); w(100); w(1440); d(0); w(0)
        w(1); w(9); w(0x0300); d(0); w(1); d(7); w(0)
        d(7); w(0x02FC); w(0); d(0x0000FF); w(0)
        d(4); w(0x012D); w(0)
        d(7); w(0x041B); w(100); w(100); w(0); w(0)
        d(3); w(0)
        return Data(b)
    }

    /// A .docx built in memory (stored ZIP): styles, a numbered list, a table, a page break, an A5 page, a header.
    private static func sampleDocx() -> Data? {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        func p(_ text: String, _ props: String = "") -> String { "<w:p><w:pPr>\(props)</w:pPr><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>" }
        let cell = { (t: String) in "<w:tc><w:tcPr><w:tcW w:w=\"2000\" w:type=\"dxa\"/></w:tcPr>\(p(t))</w:tc>" }
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document \(w)><w:body>\
        \(p("Titre d'essai", "<w:pStyle w:val=\"Titre\"/>"))\
        \(p("Premier", "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>"))\
        \(p("Second", "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>"))\
        <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4"/><w:insideH w:val="single" w:sz="4"/></w:tblBorders></w:tblPr>\
        <w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>\
        <w:tr>\(cell("Cellule A1"))\(cell("Cellule B1"))</w:tr><w:tr>\(cell("Cellule A2"))\(cell("Cellule B2"))</w:tr></w:tbl>\
        <w:p><w:r><w:t>Fin de la page</w:t></w:r><w:r><w:br w:type="page"/></w:r></w:p>\(p("Après le saut"))\
        <w:sectPr><w:headerReference w:type="default" r:id="rIdH"/><w:pgSz w:w="8391" w:h="11906"/>\
        <w:pgMar w:top="1134" w:right="720" w:bottom="1134" w:left="720" w:header="400" w:footer="400"/></w:sectPr></w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles \(w)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica"/>\
        <w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Titre"><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="40"/></w:rPr></w:style>\
        </w:styles>
        """
        let numbering = """
        <?xml version="1.0" encoding="UTF-8"?><w:numbering \(w)><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/>\
        <w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
        """
        let header = """
        <?xml version="1.0" encoding="UTF-8"?><w:hdr \(w)><w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>\
        <w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve"> sur </w:t></w:r>\
        <w:fldSimple w:instr=" NUMPAGES "><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:hdr>
        """
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdS" Type="\(rel)/styles" Target="styles.xml"/><Relationship Id="rIdN" Type="\(rel)/numbering" Target="numbering.xml"/>\
        <Relationship Id="rIdH" Type="\(rel)/header" Target="header1.xml"/></Relationships>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="word/document.xml"/></Relationships>
        """
        return storedZip([("_rels/.rels", rootRels), ("word/document.xml", document), ("word/_rels/document.xml.rels", documentRels),
                          ("word/styles.xml", styles), ("word/numbering.xml", numbering), ("word/header1.xml", header)])
    }

    /// A ZIP archive of uncompressed entries.
    private static func storedZip(_ files: [(String, String)]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func w(_ v: Int, into b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func d(_ v: Int, into b: inout [UInt8]) { w(v & 0xFFFF, into: &b); w(v >> 16 & 0xFFFF, into: &b) }
        for (name, text) in files {
            let n = Array(name.utf8), body = Array(text.utf8)
            let offset = out.count
            d(0x0403_4B50, into: &out); w(20, into: &out); w(0, into: &out); w(0, into: &out); d(0, into: &out); d(0, into: &out)
            d(body.count, into: &out); d(body.count, into: &out); w(n.count, into: &out); w(0, into: &out)
            out += n + body
            d(0x0201_4B50, into: &central); w(20, into: &central); w(20, into: &central); w(0, into: &central); w(0, into: &central)
            d(0, into: &central); d(0, into: &central); d(body.count, into: &central); d(body.count, into: &central)
            w(n.count, into: &central); w(0, into: &central); w(0, into: &central); w(0, into: &central); w(0, into: &central)
            d(0, into: &central); d(offset, into: &central)
            central += n
        }
        let start = out.count
        out += central
        d(0x0605_4B50, into: &out); w(0, into: &out); w(0, into: &out); w(files.count, into: &out); w(files.count, into: &out)
        d(central.count, into: &out); d(start, into: &out); w(0, into: &out)
        return Data(out)
    }
}
