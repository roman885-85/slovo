import AppKit
import Combine
import SlovoCore

/// Мостик между режимом окна и настройками интерфейса.
///
/// Живёт отдельным файлом нарочно: `AppState` — общий файл, и добавлять в него
/// знание про вид списков нельзя. Здесь только пересчёт одного перечисления в
/// другое и подписи вкладок (18) из файла перевода.
extension AppState {

    /// Какому набору настроек интерфейса принадлежит то, что сейчас в окне.
    ///
    /// Соответствие один в один по `rawValue`: `bible`, `text`, `songs` — те же
    /// слова, что и у секций `VisioBible.ini`.
    var listScope: InterfaceSettings.ListScope {
        InterfaceSettings.ListScope(rawValue: mode.rawValue) ?? .bible
    }
}

extension AppState.WorkMode {

    /// Подпись вкладки модуля (18) из `Language/*.lng`.
    ///
    /// У автора это `TSBible=&Библия`, `TSText=&Текст` и — потому что песенник
    /// вставлен в окно отдельной формой — `SongsPluginFrame=,&Песни`, где текст
    /// лежит не в подписи, а в подсказке. Зашитые по-русски слова показывали бы
    /// «Библия» даже при выбранном украинском переводе.
    @MainActor
    func title(in state: AppState) -> String {
        switch self {
        case .bible: return state.text("TSBible", default: title)
        case .text:  return state.text("TSText", default: title)
        // Подпись вкладки песенника у автора записана в поле подсказки —
        // берём её оттуда, а не выдумываем свою.
        case .songs: return state.hint("SongsPluginFrame", default: title)
        // Четвёртой вкладки у автора нет вовсе: `TSMedia` в его файле —
        // это вкладка окна настроек, а не режим главного окна. Значит подпись
        // наша, и переводит её наш словарь.
        case .media, .pictures, .presentation, .screen: return OurWords.t(title)
        }
    }
}
