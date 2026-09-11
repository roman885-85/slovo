import Foundation

/// Перетворення вірша MySword на текст для показу.
///
/// Розмітка тут не HTML, а GBF у дусі theWord, і відмінність у неї одна, зате
/// вирішальна: закривальний тег відрізняється від відкривального лише регістром
/// літер після першої — `<TS>` … `<Ts>`, `<FI>` … `<Fi>`, — а скісної риски
/// немає зовсім. Тому спільний `HTMLText.plain` тут не годиться: він зводить ім'я
/// тега до нижнього регістру (і `<FI>` з `<Fi>` стають одним тегом) і чекає
/// закриття скісною рискою, якої не буде. Виноска `<RF>…<Rf>` за такого
/// розбору або цілком їде в текст Писання, або з'їдає решту вірша.
///
/// Звідси свій лінійний прохід. Повноцінний розбір тут був би і повільнішим,
/// і вередливішим за потрібне: розмітка зводиться до десятка тегів.
public enum MySwordText {

    /// Парний тег, у якого викидається і вміст.
    ///
    /// Заголовок розділу буває з номером рівня (`<TS1>`), а закривати його
    /// можуть і `<Ts>`, і `<Ts1>` — приймаємо будь-який.
    private enum Pair {
        case footnote          // <RF>…<Rf> — примітка перекладача
        case heading           // <TS>…<Ts> — заголовок розділу всередині вірша
        case transliteration   // <X>…<x> — латинський запис слова підрядника

        static func opening(_ name: some StringProtocol) -> Pair? {
            if name == "RF" { return .footnote }
            if name == "X" { return .transliteration }
            if name.hasPrefix("TS"), name.dropFirst(2).allSatisfy(\.isNumber) { return .heading }
            return nil
        }

        func closes(_ name: some StringProtocol) -> Bool {
            switch self {
            case .footnote:        return name == "Rf"
            case .transliteration: return name == "x"
            case .heading:         return name.hasPrefix("Ts") && name.dropFirst(2).allSatisfy(\.isNumber)
            }
        }
    }

    /// Ліворуч від викинутого тега пробіл не потрібен: слово ще не почалося.
    private static let opening: Set<Character> = ["(", "[", "«", "„", " ", "\"", "'"]
    /// Праворуч від викинутого тега пробіл не потрібен: далі розділовий знак.
    private static let closing: Set<Character> = [",", ".", ";", ":", "!", "?",
                                                  ")", "]", "»", "…", "—", "-", " ", "\"", "'"]

    public static func plain(_ raw: some StringProtocol) -> String {
        var out = String()
        out.reserveCapacity(raw.count)

        var index = raw.startIndex
        var skipUntil: Pair?

        while index < raw.endIndex {
            let ch = raw[index]

            guard ch == "<" else {
                if skipUntil == nil { out.append(ch) }
                index = raw.index(after: index)
                continue
            }

            guard let close = raw[index...].firstIndex(of: ">") else {
                // Незакрита дужка в кінці — далі розмітки вже немає.
                if skipUntil == nil { out.append(contentsOf: raw[index...]) }
                break
            }

            let body = raw[raw.index(after: index)..<close]
            let name = tagName(body)
            index = raw.index(after: close)

            if let pair = skipUntil {
                if pair.closes(name) { skipUntil = nil }
                continue
            }
            if let pair = Pair.opening(name) {
                skipUntil = pair
                continue
            }
            // `<D>` ділить префікс і корінь УСЕРЕДИНІ одного єврейського слова:
            // поставити тут пробіл — значить розірвати слово надвоє.
            if name == "D" { continue }

            // Усі інші теги викидаємо, вміст лишаємо. Пробіл на
            // місце тега ставимо лише там, де інакше злиплися б два слова:
            // «Εν<E>В начале» — це слово підрядника і його переклад, а
            // «путь<Fr>.» — слово і крапка, між ними пробілу бути не повинно.
            let left = out.last
            let right = index < raw.endIndex ? raw[index] : nil
            if let left, let right, !opening.contains(left), !closing.contains(right) {
                out.append(" ")
            }
        }

        // Незакритий парний тег решту вірша вже з'їв — так і треба: втратити
        // хвіст краще, ніж показати виноску як слова Писання.
        return HTMLText.decodeEntities(out).condensedWhitespace()
    }

    /// Ім'я тега — до першого пробілу або скісної риски, регістр не чіпаємо.
    ///
    /// У `<RF q=a>` ім'я «RF», у звичайного `</i>`, що затесався, — порожнє: такий
    /// тег просто викидається разом із дужками, як і задумано.
    private static func tagName<S: StringProtocol>(_ body: S) -> S.SubSequence {
        let end = body.firstIndex { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "/" } ?? body.endIndex
        return body[..<end]
    }
}
