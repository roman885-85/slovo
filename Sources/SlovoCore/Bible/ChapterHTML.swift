import Foundation

/// Розбір файла книги модуля на розділи й вірші.
///
/// У «Цитаті з Біблії» структуру книги задано не тегами, а двома рядками-
/// маркерами з ini: `ChapterSign` починає розділ, `VerseSign` — вірш.
/// Тому розбір тут — це пошук маркерів, а не обхід дерева.
public enum ChapterHTML {

    /// - Parameter expectedChapters: `ChapterQty` з ini. Служить арбітром,
    ///   коли розмітка книги допускає два прочитання (див. `chapterStarts`).
    public static func parse(_ html: String, info: ModuleInfo, expectedChapters: Int = 0) -> [Chapter] {
        let dropStrong: Set<String> = info.hasStrongNumbers ? ["s"] : []
        let starts = chapterStarts(in: html, info: info, expectedChapters: expectedChapters)

        guard !starts.isEmpty else {
            // Маркер розділу не трапився: книга з одного розділу (так буває
            // в небіблійних модулів — збірників проповідей, словників).
            let verses = parseVerses(html[...], info: info, dropContentOf: dropStrong)
            return verses.isEmpty ? [] : [Chapter(number: firstChapterNumber(info), heading: nil, verses: verses)]
        }

        var chapters: [Chapter] = []
        var number = firstChapterNumber(info)

        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].markerStart : html.endIndex
            let slice = html[start.bodyStart..<end]

            chapters.append(Chapter(number: number,
                                    heading: headingText(of: slice, info: info, dropContentOf: dropStrong),
                                    verses: parseVerses(slice, info: info, dropContentOf: dropStrong)))
            number += 1
        }
        return chapters
    }

    // MARK: - Межі розділів

    private struct ChapterStart {
        let markerStart: String.Index   // де починається сам маркер
        let bodyStart: String.Index     // де починається вміст розділу
    }

    /// Знаходить початки розділів, розбираючи неоднозначність розмітки на користь того,
    /// що модуль сам про себе оголосив.
    ///
    /// Просто рахувати входження `ChapterSign` не можна: в узбецькому модулі тим самим
    /// `<strong>` виділено два заголовки в шапці файла, і Приповісті розпадаються на
    /// 33 розділи замість 31. Але й відкидати входження без номера в заголовку
    /// не можна: 151-й псалом у Синодальному позначено `A NAME="glava-d"`, без цифр
    /// зовсім, і сувора перевірка з'їдає його.
    ///
    /// Тому будуємо обидва прочитання і беремо те, що ближче до `ChapterQty`.
    /// За рівності виграє суворе: зайвий розділ ламає нумерацію всієї
    /// книги, відсутній — лише сам себе.
    private static func chapterStarts(in text: String, info: ModuleInfo, expectedChapters: Int) -> [ChapterStart] {
        let chapterMarks = occurrences(of: info.chapterSign, in: text)
        guard !chapterMarks.isEmpty else { return [] }

        let lenient = chapterMarks.map { ChapterStart(markerStart: $0.lowerBound, bodyStart: $0.upperBound) }

        let verseMarks = occurrences(of: info.verseSign, in: text)
        let allMarks = (chapterMarks + verseMarks).sorted { $0.lowerBound < $1.lowerBound }

        var strict: [ChapterStart] = []
        for mark in chapterMarks {
            let headEnd = allMarks.first { $0.lowerBound >= mark.upperBound }?.lowerBound ?? text.endIndex
            guard headEnd > mark.upperBound,
                  text[mark.upperBound..<headEnd].contains(where: \.isNumber) else { continue }
            strict.append(ChapterStart(markerStart: mark.lowerBound, bodyStart: mark.upperBound))
        }

        guard expectedChapters > 0 else { return strict }
        return abs(lenient.count - expectedChapters) < abs(strict.count - expectedChapters) ? lenient : strict
    }

    private static func occurrences(of marker: String, in text: String) -> [Range<String.Index>] {
        guard !marker.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: marker, options: .caseInsensitive, range: searchFrom..<text.endIndex) {
            found.append(range)
            searchFrom = range.upperBound
        }
        return found
    }

    // MARK: - Вірші

    private static func firstChapterNumber(_ info: ModuleInfo) -> Int {
        info.chapterZero ? 0 : 1
    }

    private static func parseVerses(_ slice: Substring, info: ModuleInfo, dropContentOf: Set<String>) -> [Verse] {
        var verses: [Verse] = []
        var fallbackNumber = 1

        let marks = occurrences(of: info.verseSign, in: String(slice))
        guard !marks.isEmpty else { return [] }

        // occurrences працює по копії рядка, тому ріжемо ту саму копію.
        let source = String(slice)
        for (position, mark) in marks.enumerated() {
            let end = position + 1 < marks.count ? marks[position + 1].lowerBound : source.endIndex
            var body = source[mark.upperBound..<end]

            let number = leadingNumber(in: &body) ?? fallbackNumber
            fallbackNumber = number + 1

            let text = HTMLText.plain(body, dropContentOf: dropContentOf)
            guard !text.isEmpty else { continue }
            verses.append(Verse(number: number, text: text))
        }
        return verses
    }

    /// Зчитує номер вірша одразу за маркером і з'їдає закривальний тег,
    /// якщо номер було обгорнуто в нього (`<sup>12</sup>текст`).
    private static func leadingNumber(in body: inout Substring) -> Int? {
        var cursor = body.startIndex
        while cursor < body.endIndex, body[cursor].isWhitespace || body[cursor] == "\u{200B}" {
            cursor = body.index(after: cursor)
        }

        var digits = ""
        while cursor < body.endIndex, body[cursor].isNumber {
            digits.append(body[cursor])
            cursor = body.index(after: cursor)
        }
        guard let number = Int(digits) else { return nil }

        var lookahead = cursor
        while lookahead < body.endIndex, body[lookahead].isWhitespace {
            lookahead = body.index(after: lookahead)
        }
        if lookahead < body.endIndex, body[lookahead] == "<",
           body.index(after: lookahead) < body.endIndex,
           body[body.index(after: lookahead)] == "/",
           let close = body[lookahead...].firstIndex(of: ">") {
            cursor = body.index(after: close)
        }

        body = body[cursor...]
        return number
    }

    private static func headingText(of slice: Substring, info: ModuleInfo, dropContentOf: Set<String>) -> String? {
        guard let firstVerse = slice.range(of: info.verseSign, options: .caseInsensitive) else { return nil }
        let head = HTMLText.plain(slice[slice.startIndex..<firstVerse.lowerBound], dropContentOf: dropContentOf)
        // У шапці розділу зазвичай лежить лише його номер — як заголовок він марний.
        let meaningful = head.filter { !$0.isNumber && !$0.isWhitespace && $0 != "=" && $0 != "\"" }
        return meaningful.isEmpty ? nil : head
    }
}
