import Foundation

/// Состав кнопок вида (22) — «Книги плиткой» и «Книги списком».
///
/// Сами кнопки рисует `NativeBibleColumns`; здесь только их описание,
/// общее с самопроверкой.
///
/// У кнопок оригинала нет подписей — только подсказки, и в обеих панелях их
/// ровно по две: `PngSBBookFlow` / `PngSBBookOneLine` у окна выбора Книги и
/// `PngSBmanyLines` / `PngSBOneLine` у списка стихов. Подписи пунктов меню
/// (N8…N11) сюда не годятся: это тексты другого элемента интерфейса.
enum ListStyleButtons {
    /// Одна кнопка панели (22).
    struct BookButton {
        /// Ключ подсказки в файле перевода автора, форма `MainForm`.
        let key: String
        let fallback: String
        let symbol: String
        /// Какой из двух крайних видов ставит кнопка: «плиткой» или «списком».
        let flow: Bool
    }

    /// Состав панели (22) целиком: ровно две кнопки, и обе с подсказками
    /// автора. Список открыт наружу, чтобы самопроверка читала его же, а не
    /// повторяла словами «кнопок две» — тогда лишняя кнопка сразу видна в
    /// отчёте, а не только глазами на снимке.
    static let bookButtons: [BookButton] = [
        BookButton(key: "PngSBBookFlow", fallback: "Книги плиткой",
                   symbol: "square.grid.2x2", flow: true),
        BookButton(key: "PngSBBookOneLine", fallback: "Книги списком",
                   symbol: "list.bullet", flow: false),
    ]
}
