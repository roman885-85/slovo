import AppKit
import SlovoCore

/// Пункты меню «Интерфейс» (N39) и «Language/Язык» (N14).
///
/// Состав взят из перечня пунктов оригинала: N8 «Значки», N9 «Мал. значки»,
/// N10 «Список», N11 «Таблица», N17 «Память», N41 «Перевод интерфейса».
/// Пункт «Стиль интерфейса программы» — раздел 7.2 руководства; своего ключа
/// в файле перевода у него нет, поэтому подпись наша.
///
/// Здесь только список пар «подпись — действие», а не готовый `Commands`, и
/// это нарочно. Меню в программе рисуется дважды: своей полосой внутри окна
/// (как в оригинале) и системной строкой macOS через `SlovoCommands`. Обе
/// берут пункты отсюда — иначе они разошлись бы составом, а собственный вид
/// `Commands` рядом с уже готовым разделом в `SlovoCommands` дал бы в строке
/// меню два раздела «Интерфейс».
@MainActor
enum InterfaceMenuItems {

    static func interface(state: AppState) -> [(title: String, action: () -> Void)] {
        let interface = InterfaceSettings.shared
        let scope = state.listScope
        var items: [(title: String, action: () -> Void)] = InterfaceSettings.BookViewMode.allCases.map { mode in
            (title: mark(interface.bookView(scope) == mode,
                         state.text(mode.captionKey, default: mode.captionFallback)),
             action: { interface.setBookView(mode, in: scope) })
        }
        items.append((title: mark(interface.remembersLayout, state.text("N17", default: "Память")),
                      action: { interface.remembersLayout.toggle() }))
        items.append((title: OurWords.t("Стиль интерфейса программы…"),
                      action: { InterfaceWindows.showStyle(state: state) }))
        items.append((title: state.text("N41", default: "Перевод интерфейса") + "…",
                      action: { InterfaceWindows.showTranslate(state: state) }))
        return items
    }

    static func language(state: AppState) -> [(title: String, action: () -> Void)] {
        var items: [(title: String, action: () -> Void)] = [
            (title: state.text("Label1", form: "SelectLangForm",
                               default: "Выберите язык интерфейса программы") + "…",
             action: { InterfaceWindows.showLanguagePicker(state: state) })
        ]
        let files = state.languageCatalog?.languages ?? []
        for language in files {
            items.append((title: mark(state.languageCode == language.code, language.displayName),
                          action: { state.setLanguage(code: language.code) }))
        }
        // Убудовані мови — і тоді, коли файлів перекладу старої програми немає зовсім.
        let known = Set(files.map { $0.code.lowercased() })
        for builtIn in AppState.builtInLanguages where !known.contains(builtIn.code) {
            items.append((title: mark(state.languageCode == builtIn.code, builtIn.name),
                          action: { state.setLanguage(code: builtIn.code) }))
        }
        return items
    }

    private static func mark(_ isOn: Bool, _ title: String) -> String {
        (isOn ? "✓ " : "   ") + title
    }
}
