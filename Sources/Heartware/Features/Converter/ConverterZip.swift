import Foundation
import Compression

/// Reads the parts of a ZIP package in memory (Word, OpenDocument): stored and deflated entries, no ZIP64.
struct ConverterZip {
    private let bytes: [UInt8]
    private var entries: [String: (method: Int, compressed: Int, size: Int, offset: Int)] = [:]

    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ConverterError.failed("Ce fichier n'est pas une archive ZIP valide.") }
        // End of central directory: the last record with its signature, at most 64 Kio of comment after it.
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if u32(i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw ConverterError.failed("Ce fichier n'est pas une archive ZIP valide.") }
        let count = u16(end + 10)
        var p = u32(end + 16)
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { break }
            let nameLength = u16(p + 28)
            guard p + 46 + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = (u16(p + 10), u32(p + 20), u32(p + 24), u32(p + 42))
            p += 46 + nameLength + u16(p + 30) + u16(p + 32)
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// The uncompressed content of one part, or nil when it is missing or unreadable.
    func data(_ name: String) -> Data? {
        guard let e = entries[name], e.compressed != 0xFFFF_FFFF, e.size != 0xFFFF_FFFF,
              e.offset + 30 <= bytes.count, u32(e.offset) == 0x0403_4B50 else { return nil }
        let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
        guard start + e.compressed <= bytes.count else { return nil }
        switch e.method {
        case 0:
            return Data(bytes[start..<(start + e.compressed)])
        case 8:
            guard e.size > 0 else { return Data() }
            guard e.size < 512_000_000 else { return nil }
            var out = [UInt8](repeating: 0, count: e.size)
            let written = bytes.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, e.size, src.baseAddress! + start, e.compressed, nil, COMPRESSION_ZLIB)
                }
            }
            return written == e.size ? Data(out) : nil
        default:
            return nil
        }
    }

    private func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
}
