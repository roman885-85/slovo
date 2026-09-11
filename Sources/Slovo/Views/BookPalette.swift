import AppKit
import Combine
import SlovoCore

/// Раскраска книг по разделам канона — как в оригинале.
///
/// Там кнопки книг не одноцветные: Пятикнижие тёмное, исторические и
/// поэтические зелёные, Евангелия красные, послания синие. Оператор находит
/// нужную книгу по цвету быстрее, чем читает подпись, — поэтому это не
/// украшение, а часть навигации.
enum BookPalette {

    enum Section {
        case law, history, poetry, prophets, gospels, acts, epistles, revelation, other

        /// Цвет раздела в величинах AppKit: им красит список книг окно,
        /// и держать ради него цвет SwiftUI незачем.
        var color: NSColor {
            switch self {
            case .law:        return NSColor(srgbRed: 0.10, green: 0.14, blue: 0.42, alpha: 1)
            case .history:    return NSColor(srgbRed: 0.00, green: 0.45, blue: 0.20, alpha: 1)
            case .poetry:     return NSColor(srgbRed: 0.00, green: 0.42, blue: 0.38, alpha: 1)
            case .prophets:   return NSColor(srgbRed: 0.32, green: 0.30, blue: 0.05, alpha: 1)
            case .gospels:    return NSColor(srgbRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
            case .acts:       return NSColor(srgbRed: 0.55, green: 0.20, blue: 0.05, alpha: 1)
            case .epistles:   return NSColor(srgbRed: 0.13, green: 0.25, blue: 0.62, alpha: 1)
            case .revelation: return NSColor(srgbRed: 0.45, green: 0.10, blue: 0.45, alpha: 1)
            case .other:      return NSColor.labelColor
            }
        }
    }

    /// Раздел определяем по сквозному номеру канона: он единый для обоих
    /// форматов модулей, поэтому раскраска не зависит от языка и порядка.
    static func section(for book: BookInfo) -> Section {
        guard let number = book.canonicalNumber else { return .other }
        switch number {
        case 10...50:    return .law
        case 60...190:   return .history
        case 220...260:  return .poetry
        case 290...460:  return .prophets
        case 470...500:  return .gospels
        case 510:        return .acts
        case 520...720:  return .epistles
        case 730:        return .revelation
        default:         return .other
        }
    }

    static func color(for book: BookInfo) -> NSColor { section(for: book).color }
}
