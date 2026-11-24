import Foundation

/// Plain text files come in many encodings. UTF-8 and UTF-16 are read as they are; other 8-bit
/// text is either ArmSCII-8 (old Armenian) or Windows-1251 (Russian), told apart by the letters:
/// ArmSCII keeps lowercase Armenian letters on odd bytes from 0xB3 to 0xFD, and most letters in a
/// text are lowercase, while Cyrillic letters fill 0xC0–0xFF evenly.
enum TextDecoder {
    struct Decoded {
        let text: String
        let encodingName: String
    }

    static func decode(_ data: Data, armscii: Bool) -> Decoded {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return Decoded(text: s, encodingName: "UTF-8")
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return Decoded(text: s, encodingName: "UTF-16")
        }
        if let s = String(data: data, encoding: .utf8) {
            return Decoded(text: s, encodingName: "UTF-8")
        }
        if armscii, looksLikeArmSCII(data) {
            return Decoded(text: decodeArmSCII(data), encodingName: "ArmSCII-8")
        }
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        if let s = String(data: data, encoding: cp1251) {
            return Decoded(text: s, encodingName: "Windows-1251")
        }
        return Decoded(text: String(decoding: data, as: UTF8.self), encodingName: "UTF-8")
    }

    static func looksLikeArmSCII(_ data: Data) -> Bool {
        var letters = 0
        var odd = 0
        for byte in data where byte >= 0xB2 && byte <= 0xFD {
            letters += 1
            if byte & 1 == 1 { odd += 1 }
        }
        return letters >= 8 && Double(odd) / Double(letters) > 0.72
    }

    static func decodeArmSCII(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in data {
            scalars.append(armsciiScalar(byte))
        }
        return String(scalars)
    }

    static func armsciiScalar(_ byte: UInt8) -> Unicode.Scalar {
        let value: UInt32
        switch byte {
        case 0xA2: value = 0x0587
        case 0xA3: value = 0x0589
        case 0xA4: value = 0x0029
        case 0xA5: value = 0x0028
        case 0xA6: value = 0x00BB
        case 0xA7: value = 0x00AB
        case 0xA8: value = 0x2014
        case 0xA9: value = 0x002E
        case 0xAA: value = 0x055D
        case 0xAB: value = 0x002C
        case 0xAC: value = 0x002D
        case 0xAD: value = 0x058A
        case 0xAE: value = 0x2026
        case 0xAF: value = 0x055C
        case 0xB0: value = 0x055B
        case 0xB1: value = 0x055E
        case 0xB2...0xFD:
            let i = UInt32(byte - 0xB2) / 2
            value = (byte - 0xB2) % 2 == 0 ? 0x0531 + i : 0x0561 + i
        case 0xFE: value = 0x055A
        default: value = UInt32(byte)
        }
        return Unicode.Scalar(value) ?? Unicode.Scalar(UInt8(ascii: "?"))
    }
}
