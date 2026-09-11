import AppKit
import Combine
import SlovoCore

/// Місток між режимом вікна й налаштуваннями інтерфейсу.
///
/// Живе окремим файлом навмисно: `AppState` — спільний файл, і додавати в нього
/// знання про вигляд списків не можна. Тут тільки перерахунок одного переліку в
/// інший і підписи вкладок (18) із файла перекладу.
extension AppState {

    /// Якому набору налаштувань інтерфейсу належить те, що зараз у вікні.
    ///
    /// Відповідність один в один за `rawValue`: `bible`, `text`, `songs` — ті самі
    /// слова, що й у секцій `VisioBible.ini`.
    var listScope: InterfaceSettings.ListScope {
        InterfaceSettings.ListScope(rawValue: mode.rawValue) ?? .bible
    }
}

extension AppState.WorkMode {

    /// Підпис вкладки модуля (18) з `Language/*.lng`.
    ///
    /// В автора це `TSBible=&Библия`, `TSText=&Текст` і — бо пісенник
    /// вставлено у вікно окремою формою — `SongsPluginFrame=,&Песни`, де текст
    /// лежить не в підписі, а в підказці. Зашиті російською слова показували б
    /// «Библия» навіть за вибраного українського перекладу.
    @MainActor
    func title(in state: AppState) -> String {
        switch self {
        case .bible: return state.text("TSBible", default: title)
        case .text:  return state.text("TSText", default: title)
        // Підпис вкладки пісенника в автора записано в поле підказки —
        // беремо його звідти, а не вигадуємо свій.
        case .songs: return state.hint("SongsPluginFrame", default: title)
        // Четвертої вкладки в автора немає зовсім: `TSMedia` у його файлі —
        // це вкладка вікна налаштувань, а не режим головного вікна. Отже, підпис
        // наш, і перекладає його наш словник.
        case .media, .pictures, .presentation, .screen: return OurWords.t(title)
        }
    }
}
