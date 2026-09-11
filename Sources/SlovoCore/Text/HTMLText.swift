import Foundation

/// Перетворення фрагмента HTML з модуля на чистий текст.
///
/// Модулі писалися вручну і роками, тому повноцінний HTML-парсер тут
/// був би і повільнішим, і вередливішим за потрібне: розмітка зводиться до кількох
/// інлайнових тегів. Досить лінійного проходу.
public enum HTMLText {

    /// - Parameter dropContentOf: теги, у яких викидається і вміст
    ///   (так прибираються номери Стронга `<s>7225</s>`), а не лише самі дужки.
    public static func plain(_ html: some StringProtocol,
                             dropContentOf: Set<String> = ["s"]) -> String {
        var out = String()
        out.reserveCapacity(html.count)

        var index = html.startIndex
        var skipUntilCloseOf: String?

        while index < html.endIndex {
            let ch = html[index]

            guard ch == "<" else {
                if skipUntilCloseOf == nil { out.append(ch) }
                index = html.index(after: index)
                continue
            }

            guard let close = html[index...].firstIndex(of: ">") else {
                // Незакрита дужка в кінці файла — далі вже немає розмітки.
                if skipUntilCloseOf == nil { out.append(contentsOf: html[index...]) }
                break
            }

            let tagBody = html[html.index(after: index)..<close]
            let name = tagName(tagBody)

            if let skipping = skipUntilCloseOf {
                if tagBody.hasPrefix("/"), name == skipping { skipUntilCloseOf = nil }
            } else if !tagBody.hasPrefix("/"), !tagBody.hasSuffix("/"), dropContentOf.contains(name) {
                skipUntilCloseOf = name
            } else if isBreak(name) {
                out.append(" ")
            }

            index = html.index(after: close)
        }

        return decodeEntities(out).replacingOccurrences(of: "\u{200B}", with: "")
            .condensedWhitespace()
    }

    private static func tagName(_ tagBody: some StringProtocol) -> String {
        var body = Substring(tagBody)
        if body.hasPrefix("/") { body = body.dropFirst() }
        let end = body.firstIndex { $0 == " " || $0 == "\t" || $0 == "/" || $0 == "\n" } ?? body.endIndex
        return body[..<end].lowercased()
    }

    private static func isBreak(_ name: String) -> Bool {
        name == "br" || name == "p" || name == "div" || name == "pb" || name == "td" || name == "tr"
    }

    private static let namedEntities: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "apos": "'", "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = String()
        out.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semi = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }

            let body = text[text.index(after: index)..<semi]
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalar: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits)
                if let scalar, let unicode = Unicode.Scalar(scalar) {
                    out.unicodeScalars.append(unicode)
                    index = text.index(after: semi)
                    continue
                }
            } else if let replacement = namedEntities[body.lowercased()] {
                out.append(replacement)
                index = text.index(after: semi)
                continue
            }

            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }
}

extension String {
    /// Схлопує будь-які пробільні послідовності в один пробіл.
    func condensedWhitespace() -> String {
        var out = String()
        out.reserveCapacity(count)
        var lastWasSpace = false
        for ch in self {
            if ch.isWhitespace || ch == "\u{00A0}" {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
