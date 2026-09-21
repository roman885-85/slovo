import AppKit
import SlovoCore

/// Язык интерфейса: в украинском интерфейсе не должно оставаться русских слов.
///
/// Владелец видел такие места сам. Искать их чтением кода бесполезно —
/// подписи приходят тремя путями (файл перевода, наш словарь, запасная
/// русская строка), и какой из них сработал, видно только на живом окне.
/// Поэтому обходятся настоящие окна: главное во всех режимах, строка меню,
/// все вкладки «Параметров», конструктор, редактор веб-слайдов, мастер
/// импорта, редактор нумерации — и с каждого снимаются подписи, кнопки,
/// пункты списков и подсказки.
///
/// Русское слово узнаётся по буквам, которых в украинском нет (ы, э, ъ, ё) —
/// это наверняка; слова с русскими окончаниями (-ать, -ить, -ться, -ение,
/// -ый) — «похоже», их программа лишь показывает.
extension Diagnostics {

    static func languageSection(state: AppState) -> [Check] {
        guard OurWords.language == "uk" else {
            return [Check(area: "Мова", name: "Український інтерфейс без російських слів", status: .skipped,
                          detail: "інтерфейс зараз не український (\(OurWords.language)) — перевіряти нічого")]
        }
        let found = interfaceStrings(state: state)

        // Данные — не интерфейс: названия модулей и книг, языки, шаблоны из
        // папки Templates, название ролика. Они на своём языке по праву.
        var data: Set<String> = []
        for module in state.allModules {
            data.insert(module.info.name)
            data.insert(module.info.shortName)
        }
        for book in state.books {
            data.insert(book.fullName)
            for short in book.shortNames { data.insert(short) }
        }
        for language in state.languageCatalog?.languages ?? [] { data.insert(language.displayName) }
        for scheme in state.schemes?.templates ?? [] { data.insert(scheme.name) }
        for preset in state.presets.presets { data.insert(preset.name) }
        data.insert(state.media.title)

        // Разбор: наверняка русские и похожие на русские.
        var certain: [String: String] = [:]
        var likely: [String: String] = [:]
        for (place, text) in found {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { continue }
            guard trimmed.rangeOfCharacter(from: Self.cyrillic) != nil else { continue }   // латиница, числа, пути
            guard !data.contains(trimmed), !data.contains(where: { !$0.isEmpty && trimmed.hasPrefix($0) }) else { continue }
            if trimmed.rangeOfCharacter(from: Self.russianOnly) != nil {
                if certain[trimmed] == nil { certain[trimmed] = place }
            } else if Self.looksRussian(trimmed) {
                if likely[trimmed] == nil { likely[trimmed] = place }
            }
        }
        func list(_ table: [String: String]) -> String {
            table.sorted { $0.key < $1.key }.prefix(40)
                .map { "«\($0.key.prefix(70))» (\($0.value))" }.joined(separator: "; ")
        }
        let status: Status = certain.isEmpty ? (likely.isEmpty ? .ok : .warning) : .failed
        var detail = "знято підписів: \(found.count); напевно російських: \(certain.count); схожих: \(likely.count)"
        if !certain.isEmpty { detail += ". Російські: " + list(certain) }
        if !likely.isEmpty { detail += ". Схожі: " + list(likely) }
        return [Check(area: "Мова", name: "Український інтерфейс без російських слів", status: status, detail: detail)]
    }

    /// Все подписи живых окон: главное окно во всех режимах, строка меню,
    /// вкладки «Параметров», конструктор, редактор веб-слайдов, стиль
    /// интерфейса, выбор языка, мастер импорта, редактор нумерации.
    /// Общий сборщик для языковой проверки и для поиска чужого имени.
    static func interfaceStrings(state: AppState) -> [(where: String, text: String)] {
        var found: [(where: String, text: String)] = []
        func note(_ place: String, _ strings: [String]) {
            for text in strings { found.append((place, text)) }
        }

        // Главное окно — во всех режимах: рабочая область у каждого своя.
        if let root = NativeMainWindowController.shared.root {
            let wasMode = state.mode
            for mode in [AppState.WorkMode.bible, .text, .songs, .media, .pictures, .presentation] {
                state.mode = mode
                NativeMainWindowController.shared.applyMode()
                note("головне вікно, \(mode.title)", strings(in: root))
            }
            state.mode = wasMode
            NativeMainWindowController.shared.applyMode()
        }
        if let menu = NSApp.mainMenu { note("рядок меню", strings(in: menu)) }

        // «Параметры» — все девять вкладок, без открытия окна.
        SettingsStore.shared.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        note("Параметри", strings(in: NativeSettingsWindow.shared.build(state: state)))

        note("Конструктор слайда", strings(in: NativeSlideConstructor(state: state, onClose: {})))
        note("Редактор веб-слайдів", strings(in: NativeWebSlideEditor(state: state)))
        note("Стиль інтерфейсу", strings(in: NativeInterfaceStyleView(state: state, onClose: {})))
        // Окно «Перевод интерфейса» раньше не обходили — и вкладка «Объекты»
        // в нём годами стояла по-русски: в uk.lng автора нет ключа TSObjects.
        let translateModel = LocalizeTranslateModel(originals: InterfaceWindows.languageDirectory(state: state),
                                                    startingCode: state.language?.code ?? "ru")
        note("Переклад інтерфейсу", strings(in: NativeLocalizeView(state: state, model: translateModel, onClose: {})))

        let importModel = ImportWizardModel(destination: .applicationLibrary)
        let wizard = NativeImportWizard(state: state, model: importModel, onClose: {})
        for page in ImportWizardModel.Page.allCases {
            importModel.page = page
            wait(untilTrue: { false }, seconds: 0.15)   // страница перестраивается следующим оборотом
            note("Майстер імпорту, \(page)", strings(in: wizard))
        }
        note("Редактор нумерації",
             strings(in: NativeNumberingEditor(state: state, model: NumberingEditorModel(state: state),
                                               onFinish: { _ in })))

        return found
    }

    /// Полная ревизия языка: ни одна подпись в окнах и ни один текст на
    /// наших веб-страницах не должен остаться русским, когда выбран
    /// украинский. Ловим двумя способами: строка совпадает с РУССКИМ ключом
    /// словаря (значит перевод есть, но не применился) и русские буквы,
    /// которых в украинском нет.
    static func russianLeftoversSection(state: AppState) -> [Check] {
        guard OurWords.language == "uk" else {
            return [Check(area: "Мова", name: "Російської не лишилося: вікна й веб-сторінки", status: .skipped,
                          detail: "інтерфейс зараз не український (\(OurWords.language))")]
        }
        // Назви книг і модулів — це ДАНІ перекладу, а не наші написи. У
        // Синодальному книга називається «Бытие», і в редакторі нумерації
        // вона так і має стояти, хоч би якою була мова інтерфейсу. Без цього
        // списку перевірка сварилася на дані користувача.
        var data: Set<String> = []
        for module in state.allModules {
            data.insert(module.info.name); data.insert(module.info.shortName); data.insert(module.displayName)
            for book in module.books { data.insert(book.fullName); for short in book.shortNames { data.insert(short) } }
        }
        for book in state.books { data.insert(book.fullName); for short in book.shortNames { data.insert(short) } }
        for name in state.numbering.modules.keys { data.insert(name) }
        data.remove("")

        var untranslated: [String: String] = [:]
        for (place, text) in interfaceStrings(state: state) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Короткие подписи вроде «Ок» приходят из перевода автора и
            // по-украински выглядят так же — это не наша недоработка.
            guard trimmed.count > 3, OurWords.hasRussianKey(trimmed) else { continue }
            guard !data.contains(trimmed) else { continue }
            if untranslated[trimmed] == nil { untranslated[trimmed] = place }
        }
        // Наши страницы: заготовки и «слайд по шаблону».
        var pages: [String: String] = [:]
        let folder = WebOutputServer.userPagesFolder
        for template in WebSlideTemplates.all {
            let file = folder.appendingPathComponent(template.id + ".html")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let s = String(line)
                guard s.rangeOfCharacter(from: Self.russianOnly) != nil else { continue }
                // Пропускаем блок настроек (имена и числа).
                guard !s.contains("--sl-") else { continue }
                if pages[template.id] == nil { pages[template.id] = s.trimmingCharacters(in: .whitespaces) }
            }
        }
        var faults: [String] = []
        if !untranslated.isEmpty {
            faults.append("у вікнах лишилося російським (переклад є, але не застосований): "
                + untranslated.sorted { $0.key < $1.key }.prefix(20)
                    .map { "«\($0.key.prefix(60))» (\($0.value))" }.joined(separator: "; "))
        }
        if !pages.isEmpty {
            faults.append("на сторінках: " + pages.sorted { $0.key < $1.key }.prefix(10)
                .map { "\($0.key): «\($0.value.prefix(60))»" }.joined(separator: "; "))
        }
        return [Check(area: "Мова", name: "Російської не лишилося: вікна й веб-сторінки",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: faults.isEmpty ? "підписи вікон перекладено, на посіяних сторінках російських слів немає"
                                             : faults.joined(separator: ". "))]
    }

    /// «В настройках нашёл кнопку без надписи»: обходим окна и ищем кнопки
    /// без названия и без картинки.
    static func unlabeledButtonsSection(state: AppState) -> [Check] {
        var found: [String] = []
        func walk(_ view: NSView, _ place: String) {
            if let button = view as? NSButton, !(button is NSPopUpButton) {
                let title = button.title.trimmingCharacters(in: .whitespaces)
                let hasLetters = title.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                if !hasLetters, button.image == nil, button.alternateTitle.isEmpty, !button.isHidden {
                    found.append(place + " (" + (button.toolTip ?? "без підказки") + ")")
                }
            }
            for child in view.subviews { walk(child, place) }
        }
        SettingsStore.shared.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        walk(NativeSettingsWindow.shared.build(state: state), "Параметри")
        walk(NativeSlideConstructor(state: state, onClose: {}), "Конструктор")
        walk(NativeWebSlideEditor(state: state), "Веб-редактор")
        return [Check(area: "Мова", name: "Кнопок без напису й без картинки немає",
                      status: found.isEmpty ? .ok : .failed,
                      detail: found.isEmpty ? "обійдено Параметри, Конструктор, веб-редактор" : found.joined(separator: "; "))]
    }

    /// Заготовки для Библии и песен лежат готовыми страницами и стоят в
    /// списке «Web слайды» — владелец ждал их там, а не в диалоге.
    static func seededPagesSection(state: AppState) -> [Check] {
        let created = WebSlideSeeder.seed(store: SettingsStore.shared)
        let present = WebSlideSeeder.presentCount()
        let listed = SettingsStore.shared.settings.webSlides.filter { entry in
            WebSlideSeeder.prefixes.contains { entry.fileName.hasPrefix($0) }
        }.count
        let expected = WebSlideTemplates.all.filter { t in WebSlideSeeder.prefixes.contains { t.id.hasPrefix($0) } }.count
        let ok = present == expected && listed == expected
        return [Check(area: "Веб-слайди", name: "Заготовки для Біблії й пісень — готовими сторінками в списку",
                      status: ok ? .ok : .failed,
                      detail: "заготовок \(expected), файлів на місці \(present), у списку «Web слайди» \(listed), створено зараз \(created); тека \(WebOutputServer.userPagesFolder.path)")]
    }

    /// Снимки редакторов — веб-слайдов и Конструктора — чтобы судить о
    /// «стройности» по картинке, а не по коду.
    static func editorSnapshotsSection(state: AppState) -> [Check] {
        var lines: [String] = []
        let editor = NativeWebSlideEditor(state: state)
        editor.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        editor.layoutSubtreeIfNeeded()
        wait(untilTrue: { false }, seconds: 0.4)
        lines.append("веб-редактор: " + (snapshot(editor, to: "slovo-веб-редактор.png") ? "знято" : "не знято"))
        let constructor = NativeSlideConstructor(state: state, onClose: {})
        constructor.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        constructor.layoutSubtreeIfNeeded()
        wait(untilTrue: { false }, seconds: 0.4)
        lines.append("Конструктор: " + (snapshot(constructor, to: "slovo-конструктор.png") ? "знято" : "не знято"))
        return [Check(area: "Знімки", name: "Редактори знято для огляду", status: .ok,
                      detail: lines.joined(separator: "; ") + " — ~/Library/Logs/")]
    }

    /// «Изменены ли все текстовые упоминания прежней программы внутри?» — владелец
    /// закончил копирование оригинала, и в наших окнах чужому имени не
    /// место. Исключения — по делу: имена файлов и папок оригинала
    /// (VisioBible.ini, .app, .chm) и слова о переносе данных ИЗ VisioBible.
    static func originalNameSection(state: AppState) -> [Check] {
        let found = interfaceStrings(state: state)
        var stray: [String: String] = [:]
        var factual: [String: String] = [:]
        for (place, text) in found {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: "visiobible", options: .caseInsensitive) != nil else { continue }
            let lower = trimmed.lowercased()
            let isFile = [".ini", ".app", ".chm", ".html", ".exe", ".json", "/", "\\"].contains { lower.contains($0) }
            let isImport = ["данными visiobible", "даними visiobible", "из visiobible", "із visiobible",
                            "з visiobible", "from visiobible"].contains { lower.contains($0) }
            if isFile || isImport {
                if factual[trimmed] == nil { factual[trimmed] = place }
            } else if stray[trimmed] == nil {
                stray[trimmed] = place
            }
        }
        func list(_ table: [String: String]) -> String {
            table.sorted { $0.key < $1.key }.prefix(30)
                .map { "«\($0.key.prefix(80))» (\($0.value))" }.joined(separator: "; ")
        }
        var detail = "знято підписів: \(found.count); чужого імені не по суті: \(stray.count); по суті (файли, перенесення даних): \(factual.count)"
        if !stray.isEmpty { detail += ". Зайві: " + list(stray) }
        if !factual.isEmpty { detail += ". По суті: " + list(factual) }
        return [Check(area: "Мова", name: "Імені оригіналу у вікнах немає — крім файлів і перенесення даних",
                      status: stray.isEmpty ? .ok : .failed, detail: detail)]
    }

    /// Каждая вкладка «Параметров» — с содержимым и на снимке.
    ///
    /// Владелец видел пустые вкладки «Дополнительные» и «Модули». Проверка
    /// ставит окно настроек на подставку, переключает вкладки по очереди,
    /// считает живые элементы управления и снимает каждую в файл — чтобы
    /// пустоту было видно глазами, а не по счётчику.
    static func settingsTabsSection(state: AppState) -> [Check] {
        SettingsStore.shared.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        let root = NativeSettingsWindow.shared.build(state: state)
        let stand = bench(for: root, size: NSSize(width: 880, height: 640))
        defer { stand.orderOut(nil) }
        guard let tabs = root.subviews.compactMap({ $0 as? NSTabView }).first else {
            return [Check(area: "Параметри", name: "Вкладки на місці", status: .failed, detail: "у вікні немає вкладок")]
        }
        var lines: [String] = []
        var empty: [String] = []
        for (index, item) in tabs.tabViewItems.enumerated() {
            tabs.selectTabViewItem(at: index)
            root.layoutSubtreeIfNeeded()
            stand.displayIfNeeded()
            guard let view = item.view else { empty.append(item.label + " (немає виду)"); continue }
            view.layoutSubtreeIfNeeded()
            let controls = liveControls(in: view)
            let body = (view as? NativeForm.Page)?.bodyHeight ?? view.bounds.height
            let pictured = snapshot(view, to: "slovo-параметры-\(index + 1).png")
            let lists = nativeLists(in: view)
            let listNote = lists.isEmpty ? "" : "; списки: " + lists.map(\.describedForCheck).joined(separator: " | ")
            lines.append("\(item.label): елементів \(controls), висота вмісту \(Int(body))"
                         + (pictured ? "" : ", знімок не записався") + listNote)
            if controls < 3 || body < 40 { empty.append(item.label) }
            // Список без источника или без строк при живом источнике — та
            // самая пустота: объект вкладки умер, и строки спрашивать не у кого.
            for list in lists {
                if !list.hasSource { empty.append(item.label + " (список без джерела)") }
                else if list.rowsInTable == 0 && list.sourceRowCount > 0 { empty.append(item.label + " (список без рядків)") }
            }
        }

        // И настоящее окно — тем путём, каким его открывает человек.
        // Подставку убираем раньше: она тоже видима и с вкладками, и первый
        // прогон принял её за настоящее окно.
        stand.orderOut(nil)
        NativeSettingsWindow.shared.show(state: state)
        wait(untilTrue: { false }, seconds: 0.5)
        if let window = NSApp.windows.first(where: { $0.delegate === NativeSettingsWindow.shared && $0.isVisible }),
           let content = window.contentView,
           let liveTabs = content.subviews.compactMap({ $0 as? NSTabView }).first {
            for (index, item) in liveTabs.tabViewItems.enumerated() where index == 6 || index == 7 {
                liveTabs.selectTabViewItem(at: index)
                wait(untilTrue: { false }, seconds: 0.3)
                let lists = item.view.map { nativeLists(in: $0) } ?? []
                _ = snapshot(content, to: "slovo-параметры-окно-\(index + 1).png")
                lines.append("вікно, \(item.label): " + (lists.isEmpty ? "списків немає" : lists.map(\.describedForCheck).joined(separator: " | ")))
                for list in lists {
                    if !list.hasSource { empty.append("вікно: " + item.label + " (список без джерела)") }
                    else if list.rowsInTable == 0 && list.sourceRowCount > 0 { empty.append("вікно: " + item.label + " (список без рядків)") }
                }
            }
        } else {
            lines.append("справжнє вікно не знайшлося")
        }
        NativeSettingsWindow.shared.discard()
        return [Check(area: "Параметри", name: "Вкладки з вмістом",
                      status: empty.isEmpty ? .ok : .failed,
                      detail: (empty.isEmpty ? "усі \(tabs.tabViewItems.count) вкладок живі; "
                                : "порожні: " + empty.joined(separator: ", ") + "; ")
                          + lines.joined(separator: "; ") + "; знімки в ~/Library/Logs/slovo-параметры-N.png")]
    }

    static func nativeLists(in view: NSView) -> [any NativeListChecking] {
        var out: [any NativeListChecking] = []
        func walk(_ view: NSView) {
            if let list = view as? NativeList { out.append(list); return }
            if let list = view as? NativeTable { out.append(list); return }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return out
    }

    /// Элементы управления с настоящим местом на экране.
    private static func liveControls(in view: NSView) -> Int {
        var count = 0
        func walk(_ view: NSView) {
            if view is NSControl, !view.isHidden, view.frame.width > 1, view.frame.height > 1 { count += 1 }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return count
    }

    private static let cyrillic = CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяіїєґАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯІЇЄҐ")
    private static let russianOnly = CharacterSet(charactersIn: "ыэъёЫЭЪЁ")

    /// Окончания, которых в украинском не бывает.
    private static func looksRussian(_ text: String) -> Bool {
        // Только то, чего в украинском не бывает: «-ить», «-ять», «-уть»,
        // «-ать» и «-ться» у него свои («робить», «стоять», «будуть»,
        // «лежать», «дивиться»).
        let endings = ["еть", "ение", "ание"]
        for raw in text.split(whereSeparator: { !$0.isLetter }) {
            let word = raw.lowercased()
            guard word.count > 3 else { continue }
            if endings.contains(where: { word.hasSuffix($0) }) { return true }
        }
        return false
    }

    /// Всё, что человек может прочитать в дереве видов.
    static func strings(in view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ view: NSView) {
            if let tip = view.toolTip { out.append(tip) }
            switch view {
            case let field as NSTextField:
                // Те, що людина ввела сама (назва документа, адреса, порт), —
                // дані, а не підпис програми; підказка-заповнювач — підпис.
                if !field.isEditable { out.append(field.stringValue) }
                if let holder = field.placeholderString { out.append(holder) }
            case let popup as NSPopUpButton:
                out.append(contentsOf: popup.itemTitles)
            case let button as NSButton:
                out.append(button.title)
            case let segments as NSSegmentedControl:
                for index in 0..<segments.segmentCount {
                    if let label = segments.label(forSegment: index) { out.append(label) }
                    if let tip = segments.toolTip(forSegment: index) { out.append(tip) }
                }
            case let tabs as NSTabView:
                for item in tabs.tabViewItems {
                    out.append(item.label)
                    if let inner = item.view { walk(inner) }
                }
            case let box as NSBox:
                out.append(box.title)
            case let table as NSTableView:
                for column in table.tableColumns { out.append(column.title) }
            default:
                break
            }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return out
    }

    static func strings(in menu: NSMenu) -> [String] {
        var out: [String] = []
        for item in menu.items {
            // Пункти-вікна в розділі «Вікно» додає сама система за назвами
            // вікон — це не підписи меню.
            if item.target is NSWindow { continue }
            out.append(item.title)
            if let tip = item.toolTip { out.append(tip) }
            if let submenu = item.submenu { out.append(contentsOf: strings(in: submenu)) }
        }
        return out
    }
}
