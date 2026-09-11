import Foundation

/// Коротка адреса веб-сторінки.
///
/// Ім'я файлу сторінки годиться для теки, але не для адресного рядка: у ньому
/// бувають пробіли, кирилиця і розширення, і в браузері воно перетворюється на
/// «VBWebSlide%20%D0%BA%D0%BE%D0%BF%D0%B8%D1%8F.html». Таку адресу не можна ні
/// продиктувати, ні набрати в чужій програмі руками — а саме це з нею і
/// роблять: вписують у джерело браузера в OBS.
///
/// Тому в кожної сторінки є коротке ім'я: латиницею, малими, через
/// дефіс, без розширення. Стара адреса при цьому працювати не перестає —
/// посилання, записані раніше, ламати не можна.
public enum WebPageAddress {

    /// Коротке ім'я сторінки: `VBWebSlide копия.html` → `vbwebslide-kopiya`.
    public static func slug(of fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var result = ""
        var lastWasDash = false
        for character in stem.lowercased() {
            if let latin = Self.letters[character] {
                result += latin
                lastWasDash = false
            } else if character.isASCII && (character.isLetter || character.isNumber) {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "page" : result
    }

    /// Адреса сторінки цілком — нею й налаштовують зовнішні програми.
    public static func url(host: String, port: Int, fileName: String) -> String {
        "http://\(host):\(port)/\(slug(of: fileName))"
    }

    /// Домашня сторінка зі списком.
    public static func home(host: String, port: Int) -> String {
        "http://\(host):\(port)/"
    }

    /// Кирилиця латиницею. Ряд узято за правилами закордонного паспорта: він звичний
    /// оку і не вимагає пояснень.
    private static let letters: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "ґ": "g", "д": "d", "е": "e",
        "ё": "e", "є": "ie", "ж": "zh", "з": "z", "и": "i", "і": "i", "ї": "i",
        "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p",
        "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
        "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e",
        "ю": "iu", "я": "ia", "ў": "u",
    ]
}
