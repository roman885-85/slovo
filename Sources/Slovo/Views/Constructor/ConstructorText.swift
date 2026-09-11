import AppKit
import SlovoCore

/// Подписи формы `SlideConstructorForm` из файла перевода автора.
///
/// Отдельный маленький тип, а не метод вида: подписи нужны во всех панелях
/// конструктора, и таскать `AppState` в каждую из них только ради строк —
/// лишняя связь. Заодно так видно, что формулировки берутся у автора.
struct ConstructorText {
    let language: LanguageFile?

    func callAsFunction(_ key: String, _ fallback: String) -> String {
        // Запасний підпис — через наш словник: у файлах перекладу автора
        // частини ключів конструктора немає, і без цього вони лишалися
        // російськими за будь-якої мови.
        let spare = OurWords.t(fallback)
        return language?.caption(key, form: "SlideConstructorForm", default: spare) ?? spare
    }

    /// Підказка на кнопці — у `.lng` вона другим полем після коми.
    func hint(_ key: String, _ fallback: String = "") -> String {
        let value = language?.hint(key, form: "SlideConstructorForm") ?? ""
        return value.isEmpty ? (fallback.isEmpty ? "" : OurWords.t(fallback)) : value
    }
}
