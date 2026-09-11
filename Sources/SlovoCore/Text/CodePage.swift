import Foundation

/// Кодування, якими користуються модулі BibleQuote.
///
/// Модуль або прямо оголошує `DefaultEncoding = utf-8`, або не оголошує
/// нічого — і тоді єдина підказка це `DesiredFontCharset`, номер
/// windows-кодування шрифту, яким модуль малювався в Delphi.
public enum CodePage {

    /// Windows charset id (той, що лежить у `DesiredFontCharset`) -> CFStringEncoding.
    ///
    /// Значення записано числами навмисно: половина з них живе в
    /// `CFStringEncodings`, половина в `CFStringBuiltInEncodings`, і зводити
    /// два різні переліки заради семи рядків таблиці сенсу немає.
    private static let charsetMap: [Int: UInt32] = [
        0:   0x0500,  // ANSI_CHARSET — windows-1252
        161: 0x0503,  // грецька
        162: 0x0504,  // турецька
        163: 0x0508,  // в'єтнамська
        177: 0x0505,  // іврит
        178: 0x0506,  // арабська
        186: 0x0507,  // балтійська
        204: 0x0502,  // кирилиця
        238: 0x0501,  // центральноєвропейська
    ]

    public static func encoding(forCharset charset: Int) -> String.Encoding? {
        guard let cf = charsetMap[charset] else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Декодує файл, пробуючи оголошене кодування, потім розумні запасні.
    ///
    /// Порядок не випадковий: суворий UTF-8 відсікає себе сам — байт 0xD0 без
    /// продовження в CP1251-тексті розвалить декодування, і ми чесно
    /// провалимося далі на однобайтове кодування, а не отримаємо кашу.
    public static func decode(_ data: Data, declared: String.Encoding?) -> String {
        var candidates: [String.Encoding] = []
        if let declared { candidates.append(declared) }
        candidates.append(contentsOf: [.utf8, .windowsCP1251, .windowsCP1252])

        for encoding in candidates {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return stripBOM(text)
            }
        }
        // Останній рубіж: CP1251 однобайтова, вона не вміє падати.
        return stripBOM(String(decoding: data, as: UTF8.self))
    }

    /// Розбирає значення `DefaultEncoding` (`utf-8`, `windows-1251`, `cp1251`…).
    public static func encoding(forName raw: String) -> String.Encoding? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "utf-8", "utf8":               return .utf8
        case "utf-16", "utf16":             return .utf16
        case "windows-1250", "cp1250":      return encoding(forCharset: 238)
        case "windows-1251", "cp1251":      return .windowsCP1251
        case "windows-1252", "cp1252":      return .windowsCP1252
        case "windows-1253", "cp1253":      return encoding(forCharset: 161)
        case "windows-1255", "cp1255":      return encoding(forCharset: 177)
        case "windows-1257", "cp1257":      return encoding(forCharset: 186)
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
