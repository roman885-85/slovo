import AppKit
import SlovoCore

// MARK: - Подписи

extension AppState {
    /// Подпись элемента формы `SettingsForm` из файла перевода автора.
    /// Запасной текст — русская формулировка того же автора, поэтому своих
    /// слов здесь нет даже тогда, когда перевода на выбранный язык нет.
    func vb(_ key: String, _ fallback: String) -> String {
        text(key, form: "SettingsForm", default: fallback)
    }

    /// Подсказка (hint) того же элемента — в оригинале она всплывает над
    /// кнопкой, у нас это `.help()`.
    func vbHint(_ key: String, _ fallback: String) -> String {
        language?.hint(key, form: "SettingsForm") ?? OurWords.t(fallback)
    }

    /// Подпись из другой формы — например `SongColorsetForm` для 6.4.
    func vb(_ key: String, form: String, _ fallback: String) -> String {
        text(key, form: form, default: fallback)
    }

    func vbHint(_ key: String, form: String, _ fallback: String) -> String {
        language?.hint(key, form: form) ?? OurWords.t(fallback)
    }

    /// Кнопка согласия в вопросах окна «Параметры».
    ///
    /// Своего ключа у автора нет: вопросы он задаёт системным `MessageBox`
    /// Windows, а тот подписывает кнопки сам. Брать вместо этого
    /// `TextMessages7`/`TextMessages8` нельзя — это «Есть» и «Нет» колонки
    /// «Индекс» списка модулей: с украинским переводом пользователя кнопка
    /// согласия прочтётся как «Є», а отказа — как «Немає».
    var yesCaption: String { "Да" }
    var noCaption: String { "Нет" }
}
