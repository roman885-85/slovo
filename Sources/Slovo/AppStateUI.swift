import Foundation
import AppKit
import Combine
import SlovoCore

/// Состояние, которого требует раскладка оригинала: режим работы, класс книг,
/// история, песни, план и два поля ввода над нижним рядом.
extension AppState {

    /// Вкладки «Библия | Текст | Песни» из второй строки окна.
    enum WorkMode: String, CaseIterable, Identifiable {
        /// Четвёртый режим — медиаплеер. У автора для него заведена та же
        /// подпись, что и у трёх остальных: `TSMedia=&Медиа`. Плеер должен
        /// открываться так же, как Библия и Песенник, — своей кнопкой в ряду,
        /// а не одним лишь пунктом меню.
        ///
        /// Порядок — порядок вкладок в окне, и его задал владелец: Библия,
        /// Песни, Презентация, Медиа, Изображения, Текст. Так стоят самые
        /// частые на служении вкладки первыми, а набор текста — последним.
        /// `rawValue` от перестановки не меняется, и запомненный режим
        /// прошлого запуска читается как прежде.
        /// Сьомий режим — «Екран»: монітор або вікно чужої програми на
        /// проекторі і в NDI. Стоїть після Зображень: беруть його рідше, ніж
        /// презентацію, але частіше, ніж набір тексту.
        case bible, songs, presentation, media, pictures, screen, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bible: return OurWords.t("Библия")
            case .text:  return OurWords.t("Текст")
            case .songs: return OurWords.t("Песни")
            case .media: return OurWords.t("Медиа")
            case .pictures: return OurWords.t("Картинки")
            case .presentation: return OurWords.t("Презентация")
            case .screen: return OurWords.t("Экран")
            }
        }
        var icon: String {
            switch self {
            case .bible: return "book.closed"
            case .text:  return "doc.text"
            case .songs: return "music.note.list"
            case .media: return "play.rectangle"
            case .pictures: return "photo"
            case .presentation: return "rectangle.on.rectangle"
            case .screen: return "macwindow.on.rectangle"
            }
        }
    }

    /// Колонка «Класс:» — Вся Библия / Ветх.Завет / Нов.Завет.
    enum BookClass: String, CaseIterable, Identifiable {
        case all, old, new, apocrypha
        var id: String { rawValue }

        /// Ключ подписи у автора: `TextMessages0…3` формы `MainForm`.
        var captionKey: String {
            switch self {
            case .all:       return "TextMessages0"
            case .old:       return "TextMessages1"
            case .new:       return "TextMessages2"
            case .apocrypha: return "TextMessages3"
            }
        }

        var title: String {
            switch self {
            case .all:       return OurWords.t("Вся Библия")
            case .old:       return OurWords.t("Ветх.Завет")
            case .new:       return OurWords.t("Нов.Завет")
            case .apocrypha: return OurWords.t("Неканон.")
            }
        }

        /// Подпись из открытого перевода. Запасное слово — русское, как было.
        @MainActor
        func title(in state: AppState) -> String {
            state.text(captionKey, default: title)
        }
    }

    /// Строка списка «История:».
    struct HistoryEntry: Identifiable, Hashable {
        let id = UUID()
        let reference: String
        let snippet: String
        let bookIndex: Int
        let chapter: Int
        let verses: [Int]
    }
}
