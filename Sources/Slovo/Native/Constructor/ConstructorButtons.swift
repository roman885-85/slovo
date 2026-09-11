import AppKit
import SlovoCore

// MARK: - Порядок кнопок конструктора

/// Кнопки шаблону у верхньому рядку (6.3.1).
///
/// Порядок і місце взято зі знімка працюючої програми
/// (`Docs/Окно-настроек.md`): кнопка створення стоїть ліворуч від підпису
/// «Шаблон:», а зберегти, зберегти з новим ім'ям і видалити — праворуч від
/// випадного списку. Тримаємо порядок окремим списком, а не розкладаємо по
/// тілу вікна: так самоперевірка звіряє рівно те, що намальовано, а не
/// окремо заведену копію порядку.
enum TemplateButton: String, CaseIterable {
    case new = "SBNewSheme"
    case save = "SBSaveSheme"
    case saveAs = "SBAddSheme"
    case delete = "SBDelSheme"

    /// Ліворуч від підпису «Шаблон:».
    static let beforeList: [TemplateButton] = [.new]
    /// Праворуч від випадного списку.
    static let afterList: [TemplateButton] = [.save, .saveAs, .delete]

    /// Знак на кнопці. Не значок SF: смугу зібрано зі звичайних кнопок
    /// AppKit, і один знак читається однаково за будь-якого оформлення.
    /// Слово, а не значок: власник не знайшов «⤓» — «нет кнопки сохранить».
    var mark: String {
        switch self {
        case .new:    return OurWords.t("Новый")
        case .save:   return OurWords.t("Сохранить")
        case .saveAs: return OurWords.t("Сохранить как…")
        case .delete: return OurWords.t("Удалить")
        }
    }

    /// Запасна підказка — на випадок, якщо файла перекладу немає зовсім.
    var fallbackHint: String {
        switch self {
        case .new:    return OurWords.t("Новый шаблон слайда")
        case .save:   return OurWords.t("Сохранить шаблон")
        case .saveAs: return OurWords.t("Сохранить шаблон с новым именем")
        case .delete: return OurWords.t("Удалить шаблон")
        }
    }
}

/// Кнопки праворуч від списку «Объекты слайда» (6.3.4).
///
/// Посібник перелічує їх так: «можно добавлять, удалять, копировать и
/// менять позицию», і знімок вікна дає той самий порядок.
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
