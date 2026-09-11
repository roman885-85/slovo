import Foundation
import SlovoCore

// MARK: - Підписи з файла перекладу

/// Підписи й підказки модуля «Пісні».
///
/// Майже всі кнопки Пісенника підписано тільки спливною підказкою, а вона
/// лежить у другій половині рядка `.lng` (`TBSave=TBSave,~Сохранить
/// Песенник (Ctrl+S)~`). `AppState.text(_:form:default:)` віддає лише першу
/// половину, тому тут свій доступ — до підказки й до повідомлень
/// `TextMessagesN`, яких в інтерфейсі більше, ніж самих кнопок.
struct SongCaptions {

    let language: LanguageFile?

    private static let form = "MainForm"
    private static let prefix = "SongsPluginFrame->"

    /// Підпис елемента (перша половина рядка перекладу).
    func caption(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(Self.prefix + key, form: Self.form, default: "") ?? ""
        // У кнопок із картинкою підпис дорівнює імені елемента — показувати його
        // не можна, це службове значення, а не текст для людини.
        return (text.isEmpty || text == key) ? fallback : text
    }

    /// Спливна підказка (друга половина рядка перекладу).
    func hint(_ key: String, _ fallback: String) -> String {
        let text = language?.hint(Self.prefix + key, form: Self.form) ?? ""
        return text.isEmpty ? fallback : text.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// `SongsPluginFrame->TextMessagesN` — тексти запитів і попереджень.
    func message(_ number: Int, _ fallback: String) -> String {
        let text = language?.caption("\(Self.prefix)TextMessages\(number)", form: Self.form, default: "") ?? ""
        return (text.isEmpty ? fallback : text).replacingOccurrences(of: "\\n", with: "\n")
    }

    func error(_ number: Int, _ fallback: String) -> String {
        let text = language?.caption("\(Self.prefix)ErrorMessages\(number)", form: Self.form, default: "") ?? ""
        return (text.isEmpty ? fallback : text).replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Підпис пункту головного меню без префікса `SongsPluginFrame->`.
    ///
    /// Меню правої кнопки над вкладкою Пісенника (5.3.7) складається з тих самих
    /// пунктів, що й меню над вкладкою перекладу (5.1.7), і у файлі автора
    /// вони лежать просто в `MainForm`: N_LongName, N_ShortName, NReloadModule,
    /// NOpenModuleFolder. Своїх ключів у пісенника для них немає.
    func mainForm(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(key, form: Self.form, default: "") ?? ""
        return (text.isEmpty || text == key) ? fallback : text
    }

    /// Підписи форм редагування пісні й частини.
    func songForm(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(key, form: "SongEditNameForm", default: "") ?? ""
        return text.isEmpty ? fallback : text
    }

    func chunkForm(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(key, form: "SongEditChunkForm", default: "") ?? ""
        return text.isEmpty ? fallback : text
    }

    func copyForm(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(key, form: "ImportSongsDialogForm", default: "") ?? ""
        return text.isEmpty ? fallback : text
    }

    /// Назви частин із випадного списку вікна «Частина пісні»
    /// (`ChunksName0…5`): куплет, приспів, заспів, міст, вступ, кода.
    var chunkNames: [String] {
        let fallback = ["Куплет", "Припев", "Запев", "Мост", "Вступление", "Кода"]
        return (0..<fallback.count).map { index in
            let text = language?.caption("ChunksName\(index)", form: "SongEditChunkForm", default: "") ?? ""
            return text.isEmpty ? fallback[index] : text
        }
    }
}
