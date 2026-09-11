import AppKit
import SlovoCore

// MARK: - Порядок кнопок конструктора

/// Кнопки шаблона в верхней строке (6.3.1).
///
/// Порядок и место взяты со снимка работающей программы
/// (`Docs/Окно-настроек.md`): кнопка создания стоит слева от подписи
/// «Шаблон:», а сохранить, сохранить с новым именем и удалить — справа от
/// выпадающего списка. Держим порядок отдельным списком, а не раскладываем по
/// телу окна: так самопроверка сверяет ровно то, что нарисовано, а не
/// отдельно заведённую копию порядка.
enum TemplateButton: String, CaseIterable {
    case new = "SBNewSheme"
    case save = "SBSaveSheme"
    case saveAs = "SBAddSheme"
    case delete = "SBDelSheme"

    /// Слева от подписи «Шаблон:».
    static let beforeList: [TemplateButton] = [.new]
    /// Справа от выпадающего списка.
    static let afterList: [TemplateButton] = [.save, .saveAs, .delete]

    /// Знак на кнопке. Не значок SF: полоса собрана из обычных кнопок
    /// AppKit, и один знак читается одинаково при любом оформлении.
    /// Слово, а не значок: владелец не нашёл «⤓» — «нет кнопки сохранить».
    var mark: String {
        switch self {
        case .new:    return OurWords.t("Новый")
        case .save:   return OurWords.t("Сохранить")
        case .saveAs: return OurWords.t("Сохранить как…")
        case .delete: return OurWords.t("Удалить")
        }
    }

    /// Запасная подсказка — на случай, если файла перевода нет вовсе.
    var fallbackHint: String {
        switch self {
        case .new:    return OurWords.t("Новый шаблон слайда")
        case .save:   return OurWords.t("Сохранить шаблон")
        case .saveAs: return OurWords.t("Сохранить шаблон с новым именем")
        case .delete: return OurWords.t("Удалить шаблон")
        }
    }
}

/// Кнопки справа от списка «Объекты слайда» (6.3.4).
///
/// Руководство перечисляет их так: «можно добавлять, удалять, копировать и
/// менять позицию», и снимок окна даёт тот же порядок.
enum ObjectListButton: String, CaseIterable {
    case add = "SBObjAdd"
    case delete = "SBObjDel"
    case copy = "SBObjCopy"
    case up = "SBObjUp"
    case down = "SBObjDown"

    var mark: String {
        switch self {
        case .add:    return "+"
        case .delete: return "−"
        case .copy:   return "⧉"
        case .up:     return "↑"
        case .down:   return "↓"
        }
    }

    var fallbackHint: String {
        switch self {
        case .add:    return OurWords.t("Добавить объект")
        case .delete: return OurWords.t("Удалить объект")
        case .copy:   return OurWords.t("Скопировать объект")
        case .up:     return OurWords.t("Переместить объект выше")
        case .down:   return OurWords.t("Переместить объект ниже")
        }
    }
}
