import SwiftUI
import AppKit
import CoreText

/// The color of the module in the interface.
enum FillSignStyle {
    static var tint: Color { Theme.palette[6] }
}

/// The ink of what is added to a document. Document content, not interface: the same in every theme and in the saved PDF.
enum FillSignInk: String, Codable, CaseIterable, Identifiable, Sendable {
    case black, blue

    var id: String { rawValue }
    var title: String { self == .black ? "Noir" : "Bleu" }

    var cgColor: CGColor {
        switch self {
        case .black: return CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        case .blue: return CGColor(srgbRed: 0.07, green: 0.2, blue: 0.62, alpha: 1)
        }
    }

    var color: Color { Color(cgColor: cgColor) }
}

/// What a click on the page does.
enum FillSignTool: String, CaseIterable, Identifiable {
    case select, text, check, cross, dot, date, signature, initials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Sélection"
        case .text: return "Texte"
        case .check: return "Coche"
        case .cross: return "Croix"
        case .dot: return "Point"
        case .date: return "Date"
        case .signature: return "Signature"
        case .initials: return "Paraphe"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .check: return "checkmark"
        case .cross: return "xmark"
        case .dot: return "circle.fill"
        case .date: return "calendar"
        case .signature: return "signature"
        case .initials: return "pencil.and.scribble"
        }
    }

    /// What to do next, under the toolbar.
    var hint: String {
        switch self {
        case .select: return "Clique un champ pour le remplir, un élément pour le déplacer · double-clic sur la page : du texte"
        case .text: return "Clique où tu veux écrire · ↩ termine · ⎋ revient à la sélection"
        case .check: return "Clique sur chaque case à cocher · ⎋ revient à la sélection"
        case .cross: return "Clique sur chaque case à barrer · ⎋ revient à la sélection"
        case .dot: return "Clique où mettre un point · ⎋ revient à la sélection"
        case .date: return "Clique où mettre la date du jour"
        case .signature: return "Clique où signer · ⎋ annule"
        case .initials: return "Clique où parapher · « Sur toutes les pages » le recopie ensuite partout"
        }
    }

    /// Tools that stay chosen after a click (a form has many boxes to tick); the others go back to the selection.
    var staysOn: Bool { self == .text || self == .check || self == .cross || self == .dot }

    var mark: FillSignMark? {
        switch self {
        case .check: return .check
        case .cross: return .cross
        case .dot: return .dot
        default: return nil
        }
    }
}

enum FillSignMark: String, Codable, Sendable {
    case check, cross, dot
}

/// Something added on a page: text, a mark or a signature. Positions are in points of the page as it is shown
/// (turned, cropped), from its top left corner.
struct FillSignItem: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String)
        case mark(FillSignMark)
        case signature(FillSignSignature)
    }

    var id = UUID()
    var page: Int
    var rect: CGRect
    var content: Content
    var fontSize: CGFloat = 12
    var ink: FillSignInk = .black

    var text: String? {
        if case .text(let t) = content { return t }
        return nil
    }

    var signature: FillSignSignature? {
        if case .signature(let s) = content { return s }
        return nil
    }

    /// Marks and signatures keep their proportions when resized.
    var aspect: CGFloat { rect.height > 0 ? rect.width / rect.height : 1 }
}

/// A form field of the PDF, as the editor shows it.
struct FillSignField: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(multiline: Bool, maxLength: Int, fontSize: CGFloat, alignment: Int)
        case checkbox(on: String)
        case radio(on: String)
        case choice(options: [String])
        case signature
    }

    let id: String
    let page: Int
    /// The widget's place among the page's annotations: the document opened again for saving finds it there.
    let annotationIndex: Int
    /// The field's name (widgets with the same name share their value), or `id` for a field without a name.
    let key: String
    let label: String
    let rect: CGRect
    let kind: Kind
    let readOnly: Bool

    var isButton: Bool {
        switch kind {
        case .checkbox, .radio: return true
        default: return false
        }
    }

    var onState: String? {
        switch kind {
        case .checkbox(let on), .radio(let on): return on
        default: return nil
        }
    }
}

/// A signature or initials kept for later: drawn, typed in a script font, or taken from a picture.
struct FillSignSignature: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case signature, initials
        var title: String { self == .signature ? "Signature" : "Paraphe" }
    }

    enum Style: Codable, Equatable, Sendable {
        /// Strokes in points, from the top left corner of `size`, and the pen's width at that size.
        case drawn(strokes: [[CGPoint]], width: CGFloat)
        case typed(text: String, font: String)
        /// A PNG whose paper was made transparent.
        case image(png: Data)
    }

    var id = UUID()
    var kind: Kind
    var style: Style
    /// Natural size, in points: once placed, it keeps these proportions.
    var size: CGSize
    var ink: FillSignInk = .black
    var created = Date()

    /// The ink only colors drawn and typed signatures (a picture keeps its own colors).
    var takesInk: Bool {
        if case .image = style { return false }
        return true
    }
}

/// The text written on documents (added text, field values): Helvetica, so the saved PDF looks like the editor.
enum FillSignText {
    static let fontName = "Helvetica"

    static func font(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName(fontName as CFString, size, nil)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func ascent(_ size: CGFloat) -> CGFloat { CTFontGetAscent(font(size)) }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let f = font(size)
        return (CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)).rounded(.up)
    }

    static func width(_ line: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    /// The box taken by a text at that size (at least a few points wide, so that an empty text can be clicked).
    static func size(_ text: String, fontSize: CGFloat) -> CGSize {
        let f = font(fontSize)
        let widest = lines(text).map { width($0, font: f) }.max() ?? 0
        return CGSize(width: max(widest.rounded(.up) + 2, fontSize * 0.8),
                      height: lineHeight(fontSize) * CGFloat(max(1, lines(text).count)))
    }

    /// Today in French: "20/10/2026".
    static func today(_ date: Date = Date()) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Fmt.fr))
    }
}
