import Foundation
import SlovoCore

// MARK: - Подписи из файла перевода

/// Подписи и подсказки модуля «Песни».
///
/// Почти все кнопки Песенника подписаны только всплывающей подсказкой, а она
/// лежит во второй половине строки `.lng` (`TBSave=TBSave,~Сохранить
/// Песенник (Ctrl+S)~`). `AppState.text(_:form:default:)` отдаёт лишь первую
/// половину, поэтому здесь свой доступ — к подсказке и к сообщениям
/// `TextMessagesN`, которых в интерфейсе больше, чем самих кнопок.
struct SongCaptions {

    let language: LanguageFile?

    private static let form = "MainForm"
    private static let prefix = "SongsPluginFrame->"

    /// Подпись элемента (первая половина строки перевода).
    func caption(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(Self.prefix + key, form: Self.form, default: "") ?? ""
        // У кнопок с картинкой подпись равна имени элемента — показывать её
        // нельзя, это служебное значение, а не текст для человека.
        return (text.isEmpty || text == key) ? fallback : text
    }

    /// Всплывающая подсказка (вторая половина строки перевода).
    func hint(_ key: String, _ fallback: String) -> String {
        let text = language?.hint(Self.prefix + key, form: Self.form) ?? ""
        return text.isEmpty ? fallback : text.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// `SongsPluginFrame->TextMessagesN` — тексты запросов и предупреждений.
    func message(_ number: Int, _ fallback: String) -> String {
        let text = language?.caption("\(Self.prefix)TextMessages\(number)", form: Self.form, default: "") ?? ""
        return (text.isEmpty ? fallback : text).replacingOccurrences(of: "\\n", with: "\n")
    }

    func error(_ number: Int, _ fallback: String) -> String {
        let text = language?.caption("\(Self.prefix)ErrorMessages\(number)", form: Self.form, default: "") ?? ""
        return (text.isEmpty ? fallback : text).replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Подпись пункта главного меню без приставки `SongsPluginFrame->`.
    ///
    /// Меню правой кнопки над вкладкой Песенника (5.3.7) состоит из тех же
    /// пунктов, что и меню над вкладкой перевода (5.1.7), и в файле автора
    /// они лежат прямо в `MainForm`: N_LongName, N_ShortName, NReloadModule,
    /// NOpenModuleFolder. Своих ключей у песенника для них нет.
    func mainForm(_ key: String, _ fallback: String) -> String {
        let text = language?.caption(key, form: Self.form, default: "") ?? ""
        return (text.isEmpty || text == key) ? fallback : text
    }

    /// Подписи форм редактирования песни и части.
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

    /// Названия частей из выпадающего списка окна «Часть песни»
    /// (`ChunksName0…5`): куплет, припев, запев, мост, вступление, кода.
    var chunkNames: [String] {
        let fallback = ["Куплет", "Припев", "Запев", "Мост", "Вступление", "Кода"]
        return (0..<fallback.count).map { index in
            let text = language?.caption("ChunksName\(index)", form: "SongEditChunkForm", default: "") ?? ""
            return text.isEmpty ? fallback[index] : text
        }
    }
}
