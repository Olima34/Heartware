import Foundation
import Compression

/// Windscribe's own « Hide from Dock » and « Start minimized » (its Preferences › General), read and changed where the app
/// keeps them. Pure code (Foundation only), so it can be checked on a copy of the preferences file.
///
/// From Windscribe's sources (github.com/Windscribe/Desktop-App, v2.24.9 to v2.25.4, the same format):
/// - `Preferences::saveGuiSettings` writes `QSettings("Windscribe", "Windscribe2")`, i.e. the user defaults domain
///   `com.windscribe.Windscribe2`, key `guiSettings2`: a `SimpleCrypt(SIMPLE_CRYPT_KEY)` string (types/global_consts.h).
/// - Its clear text is a big-endian `QDataStream`: `magic_` (0x7715C211), the preferences' version (1), then
///   `types::GuiSettings` (version 8): `isLaunchOnStartup`, `isAutoConnect`, `isHideFromDock`, … the nested hotspot, proxy,
///   split tunneling and background settings, then `isStartMinimized`, … the sound settings.
/// - `MainWindow::showAfterLaunch`: with both set, Windscribe turns itself into an agent (no Dock icon) and shows no window.
/// No `windscribe-cli` command nor IPC message changes these two (the CLI's `.conf` file exists only in the Linux CLI-only
/// build): this file is the only way, used when Windscribe is closed (it reads its settings once, at launch).
struct VPNWindscribeFlags: Equatable {
    var hideFromDock: Bool
    var startMinimized: Bool

    static let invisible = VPNWindscribeFlags(hideFromDock: true, startMinimized: true)
    /// Windscribe's defaults (`types::GuiSettings`).
    static let visible = VPNWindscribeFlags(hideFromDock: false, startMinimized: false)
}

enum VPNWindscribeSettings {
    static let domain = "com.windscribe.Windscribe2"
    static let key = "guiSettings2"
    /// SIMPLE_CRYPT_KEY of types/global_consts.h.
    static let cryptKey: UInt64 = 0x4572_A4AC_F31A_31BA
    /// Preferences::magic_.
    static let magic: UInt32 = 0x7715_C211

    // MARK: Reading and changing

    /// The two flags of a stored `guiSettings2`, nil when it is not exactly the known format.
    static func flags(in stored: String) -> VPNWindscribeFlags? {
        guard let plain = VPNSimpleCrypt.decrypt(stored, key: cryptKey),
              let at = VPNGuiSettingsLayout.locate(plain) else { return nil }
        return VPNWindscribeFlags(hideFromDock: plain[at.hideFromDock] == 1, startMinimized: plain[at.startMinimized] == 1)
    }

    /// `stored` with the two flags changed and nothing else, encrypted again; nil when it cannot be read with certainty.
    /// `random`: SimpleCrypt's first byte (any value).
    static func setting(_ flags: VPNWindscribeFlags, in stored: String, random: UInt8 = .random(in: 0...255)) -> String? {
        guard let plain = VPNSimpleCrypt.decrypt(stored, key: cryptKey),
              let at = VPNGuiSettingsLayout.locate(plain) else { return nil }
        var patched = plain
        patched[at.hideFromDock] = flags.hideFromDock ? 1 : 0
        patched[at.startMinimized] = flags.startMinimized ? 1 : 0
        let result = VPNSimpleCrypt.encrypt(patched, key: cryptKey, random: random)
        // Read back the way Windscribe will: the same clear text, the two flags as asked.
        guard let again = VPNSimpleCrypt.decrypt(result, key: cryptKey), again == patched,
              Self.flags(in: result) == flags else { return nil }
        return result
    }

    // MARK: Where Windscribe keeps them

    /// What is stored now (read through cfprefsd, as Qt does), nil when Windscribe never saved its settings.
    static func readStored() -> String? {
        let d = domain as CFString
        _ = CFPreferencesAppSynchronize(d)
        return CFPreferencesCopyAppValue(key as CFString, d) as? String
    }

    /// Writes through cfprefsd (never the .plist file itself, which cfprefsd caches): only while Windscribe is closed.
    static func writeStored(_ value: String) -> Bool {
        let d = domain as CFString
        CFPreferencesSetAppValue(key as CFString, value as CFString, d)
        return CFPreferencesAppSynchronize(d) && readStored() == value
    }
}

// MARK: - SimpleCrypt

/// Andre Somers' SimpleCrypt, version 3, as Windscribe uses it (utils/simplecrypt.cpp): a random byte, a checksum, the data
/// (zlib-compressed when that is smaller), XOR-chained with the eight bytes of the key, behind a version and a flags byte.
enum VPNSimpleCrypt {
    static let flagCompression: UInt8 = 0x01
    static let flagChecksum: UInt8 = 0x02
    static let flagHash: UInt8 = 0x04

    static func keyParts(_ key: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: key >> (8 * UInt64($0))) }
    }

    static func decrypt(_ base64: String, key: UInt64) -> Data? {
        guard let cypher = Data(base64Encoded: base64), cypher.count >= 3 else { return nil }
        let bytes = [UInt8](cypher)
        guard bytes[0] == 3 else { return nil }
        let flags = bytes[1]
        // Only the flags SimpleCrypt knows; a SHA-1 hash is not what Windscribe uses: refused rather than half-checked.
        guard flags & ~(flagCompression | flagChecksum) == 0 else { return nil }
        let parts = keyParts(key)
        var ba = Array(bytes[2...])
        var last: UInt8 = 0
        for i in ba.indices {
            let current = ba[i]
            ba[i] = ba[i] ^ last ^ parts[i % 8]
            last = current
        }
        ba.removeFirst()
        if flags & flagChecksum != 0 {
            guard ba.count >= 2 else { return nil }
            let stored = UInt16(ba[0]) << 8 | UInt16(ba[1])
            ba.removeFirst(2)
            guard checksum(ba) == stored else { return nil }
        }
        if flags & flagCompression != 0 { return qUncompress(ba) }
        return Data(ba)
    }

    /// Never compressed (SimpleCrypt reads its flags: Windscribe takes it as it is), with its checksum.
    static func encrypt(_ plain: Data, key: UInt64, random: UInt8) -> String {
        let data = [UInt8](plain)
        let sum = checksum(data)
        var ba: [UInt8] = [random, UInt8(sum >> 8), UInt8(sum & 0xFF)] + data
        let parts = keyParts(key)
        var last: UInt8 = 0
        for i in ba.indices {
            ba[i] = ba[i] ^ parts[i % 8] ^ last
            last = ba[i]
        }
        return Data([3, flagChecksum] + ba).base64EncodedString()
    }

    /// Qt's `qChecksum` (CRC-16 of ISO 3309, "X.25"): reflected 0x1021, starting from 0xFFFF, inverted at the end.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return ~crc
    }

    /// Qt's `qUncompress`: the size, big-endian on 4 bytes, then a zlib stream (2-byte header, deflate, Adler-32).
    static func qUncompress(_ bytes: [UInt8]) -> Data? {
        guard bytes.count >= 4 + 2 + 4 else { return nil }
        let expected = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        let cmf = bytes[4]
        let flg = bytes[5]
        guard expected > 0, expected < 1 << 24, cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0,
              flg & 0x20 == 0 else { return nil }
        let deflate = Array(bytes[6..<(bytes.count - 4)])
        var out = [UInt8](repeating: 0, count: expected + 1)
        let written = deflate.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { return nil }
        out.removeLast(out.count - written)
        let trailer = Array(bytes.suffix(4))
        let stored = UInt32(trailer[0]) << 24 | UInt32(trailer[1]) << 16 | UInt32(trailer[2]) << 8 | UInt32(trailer[3])
        return adler32(out) == stored ? Data(out) : nil
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for x in bytes {
            a = (a + UInt32(x)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }
}

// MARK: - The QDataStream of GuiSettings

/// Walks Windscribe's `guiSettings2` clear text field by field, and gives where the two flags are. Every version number
/// must be one the sources above know, every boolean 0 or 1, and the walk must end exactly at the last byte: otherwise nil.
enum VPNGuiSettingsLayout {
    struct Offsets: Equatable {
        var hideFromDock: Int
        var startMinimized: Int
    }

    /// The newest versions known (prefs, GuiSettings, ShareSecureHotspot, ShareProxyGateway, SplitTunneling and its
    /// settings, apps and routes, BackgroundSettings, SoundSettings).
    static let maxPrefs: UInt32 = 1
    static let maxGui: UInt32 = 8

    static func locate(_ plain: Data) -> Offsets? {
        var r = VPNQtReader([UInt8](plain))
        guard r.u32() == VPNWindscribeSettings.magic, let prefs = r.u32(), (1...maxPrefs).contains(prefs),
              let gui = r.u32(), (1...maxGui).contains(gui) else { return nil }
        guard r.bool() != nil, r.bool() != nil else { return nil }     // isLaunchOnStartup, isAutoConnect
        let hide = r.position
        guard r.bool() != nil, r.bool() != nil, r.u32() != nil else { return nil }     // isHideFromDock, isShowNotifications, orderLocation
        if gui < 6 { guard r.u32() != nil else { return nil } }        // latencyDisplay, gone in version 6
        guard hotspot(&r), proxy(&r), splitTunneling(&r) else { return nil }
        guard r.bool() != nil, r.bool() != nil, background(&r) else { return nil }     // isDockedToTray, isMinimizeAndCloseToTray
        let minimized = r.position
        guard r.bool() != nil, r.bool() != nil, r.bool() != nil else { return nil }    // isStartMinimized, isShowLocationHealth, isAutoSecureNetworks
        if gui >= 2 { guard r.u32() != nil else { return nil } }       // appSkin
        if gui >= 3 { guard r.u32() != nil else { return nil } }       // trayIconColor
        if gui >= 4 { guard r.u32() != nil else { return nil } }       // multiDesktopBehavior
        if gui >= 5 { guard sound(&r) else { return nil } }
        guard r.atEnd else { return nil }
        return Offsets(hideFromDock: hide, startMinimized: minimized)
    }

    private static func version(_ r: inout VPNQtReader, max: UInt32) -> UInt32? {
        guard let v = r.u32(), (1...max).contains(v) else { return nil }
        return v
    }

    /// isEnabled, password, ssid (version 2).
    private static func hotspot(_ r: inout VPNQtReader) -> Bool {
        guard let v = version(&r, max: 2), r.bool() != nil, r.string() else { return false }
        return v < 2 || r.string()
    }

    /// isEnabled, mode, port (2), whileConnected (3), requireAuth, username, password (4).
    private static func proxy(_ r: inout VPNQtReader) -> Bool {
        guard let v = version(&r, max: 4), r.bool() != nil, r.u32() != nil else { return false }
        if v >= 2 { guard r.u32() != nil else { return false } }
        if v >= 3 { guard r.bool() != nil else { return false } }
        if v >= 4 { guard r.bool() != nil, r.string(), r.string() else { return false } }
        return true
    }

    /// settings (active, mode), apps (type, name, fullName, active, icon), network routes (type, name, active).
    private static func splitTunneling(_ r: inout VPNQtReader) -> Bool {
        guard version(&r, max: 1) != nil, version(&r, max: 1) != nil, r.bool() != nil, r.u32() != nil else { return false }
        guard let apps = r.count() else { return false }
        for _ in 0..<apps {
            guard let v = version(&r, max: 2), r.u32() != nil, r.string(), r.string(), r.bool() != nil else { return false }
            if v >= 2 { guard r.string() else { return false } }
        }
        guard let routes = r.count() else { return false }
        for _ in 0..<routes {
            guard let v = version(&r, max: 2), r.u32() != nil, r.string() else { return false }
            if v >= 2 { guard r.bool() != nil else { return false } }
        }
        return true
    }

    /// Version 1: one background type and two images; version 2: two types, two images, the aspect ratio.
    private static func background(_ r: inout VPNQtReader) -> Bool {
        guard let v = version(&r, max: 2) else { return false }
        if v == 1 { return r.u32() != nil && r.string() && r.string() }
        return r.u32() != nil && r.u32() != nil && r.string() && r.string() && r.u32() != nil
    }

    private static func sound(_ r: inout VPNQtReader) -> Bool {
        guard version(&r, max: 1) != nil else { return false }
        return r.u32() != nil && r.string() && r.u32() != nil && r.string()
    }
}

/// A big-endian `QDataStream` (Qt 6): 4-byte integers and enums, 1-byte booleans, strings and lists behind their size.
struct VPNQtReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { position == bytes.count }

    mutating func u32() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8
            | UInt32(bytes[position + 3])
        position += 4
        return v
    }

    mutating func bool() -> Bool? {
        guard position < bytes.count, bytes[position] <= 1 else { return nil }
        position += 1
        return bytes[position - 1] == 1
    }

    /// A list's count (0xFFFFFFFE announces a 64-bit size: never that big here).
    mutating func count() -> Int? {
        guard let n = u32(), n < 0xFFFF_FFFE, n <= 100_000 else { return nil }
        return Int(n)
    }

    /// A QString, skipped: its size in bytes (0xFFFFFFFF: null), then UTF-16.
    mutating func string() -> Bool {
        guard let n = u32() else { return false }
        if n == 0xFFFF_FFFF { return true }
        guard n < 0xFFFF_FFFE, n % 2 == 0, position + Int(n) <= bytes.count else { return false }
        position += Int(n)
        return true
    }
}

/// Writes the same stream: the self-tests build Windscribe's settings with it.
struct VPNQtWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u32(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    mutating func bool(_ b: Bool) { bytes.append(b ? 1 : 0) }

    mutating func string(_ s: String?) {
        guard let s else { return u32(0xFFFF_FFFF) }
        let units = Array(s.utf16)
        u32(UInt32(units.count * 2))
        for u in units { bytes += [UInt8(u >> 8), UInt8(u & 0xFF)] }
    }
}
