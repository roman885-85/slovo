import AppKit

/// Самопроверка основания нового окна.
///
/// Проверять здесь есть что, и глазами это не проверяется. «Список работает»
/// на вид одинаково и когда строк на экране двадцать, и когда их три тысячи
/// четыреста: разница видна только в задержке, а задержку на служении замечают
/// поздно. Поэтому каждая проверка ниже считает по-настоящему: сколько раз
/// список спросил источник, сколько строк перерисовалось, что осталось в
/// выделении после Shift и Ctrl.
extension Diagnostics {

    /// Источник строк для проверок: считает, о чём и сколько раз спросили.
    private final class CountingSource: NativeListSource {
        var count: Int
        private(set) var asked: [Int: Int] = [:]

        init(count: Int) { self.count = count }

        var rowCount: Int { count }

        func row(at index: Int) -> NativeRow {
            asked[index, default: 0] += 1
            return NativeRow(lead: String(index + 1),
                             text: "Рядок номер \(index + 1) — звичайної довжини, як назва пісні",
                             detail: "підзаголовок \(index % 17)")
        }

        func forget() { asked.removeAll() }
    }

    static func nativeSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: nativeSignals())
        checks.append(contentsOf: nativeWindowFrame())

        // Всё дальнейшее просит настоящее окно: без раскладки `NSTableView`
        // не заводит ни одной строки, и мерить было бы нечего.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let source = CountingSource(count: 3400)
        let list = NativeList(mode: .list, metrics: .songs, heights: .uniform(30), fontSize: 13)
        list.allowsMultipleSelection = true
        list.frame = NSRect(x: 0, y: 0, width: 420, height: 720)
        host.addSubview(list)
        list.source = source
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        checks.append(contentsOf: nativeRowCount(list, source))
        checks.append(contentsOf: nativeVirtual(list, source, host))
        checks.append(contentsOf: nativeSelection(list))
        checks.append(contentsOf: nativeScroll(list, host))
        checks.append(contentsOf: nativeScrollBeforeHeight(host))
        checks.append(nativeEditMenu(host))
        checks.append(nativeBundleLanguages())
        checks.append(contentsOf: nativeSingleRow(list, source, host))
        checks.append(contentsOf: nativeTiles(host))
        checks.append(contentsOf: nativeSpeed(list, host))

        list.source = nil
        list.removeFromSuperview()
        window.contentView = nil
        return checks
    }

    // MARK: - Число строк

    private static func nativeRowCount(_ list: NativeList, _ source: CountingSource) -> [Check] {
        let matches = list.itemCount == source.rowCount
        return [Check(area: "Вікно AppKit", name: "Список віддає потрібне число рядків",
                      status: matches ? .ok : .failed,
                      detail: "джерело обіцяло \(source.rowCount), список тримає \(list.itemCount)")]
    }

    // MARK: - Виртуальность

    private static func nativeVirtual(_ list: NativeList, _ source: CountingSource,
                                      _ host: NSView) -> [Check] {
        source.forget()
        list.reload()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let asked = source.asked.count
        let visible = list.visibleItems.count
        // Небольшой запас: `NSTableView` держит про запас строку-другую за
        // краем окна, чтобы прокрутка не дёргалась.
        let sane = visible > 0 && asked <= max(8, visible * 3)
        return [
            Check(area: "Вікно AppKit", name: "Рядків живе стільки, скільки видно",
                  status: sane ? .ok : .failed,
                  detail: "усього рядків \(list.itemCount), видно \(visible), "
                      + "джерело спитали про \(asked) рядків"),
            Check(area: "Вікно AppKit", name: "Значення не переносяться списком",
                  status: asked * 4 < list.itemCount ? .ok : .failed,
                  detail: asked * 4 < list.itemCount
                      ? "на 3400 рядків побудовано \(asked) — решти не існує зовсім"
                      : "побудовано \(asked) рядків із \(list.itemCount) — список не віртуальний"),
        ]
    }

    // MARK: - Выделение

    private static func nativeSelection(_ list: NativeList) -> [Check] {
        var checks: [Check] = []

        list.click(item: 10)
        checks.append(Check(area: "Вікно AppKit", name: "Виділення одиночним клацанням",
                            status: list.selection == IndexSet(integer: 10) ? .ok : .failed,
                            detail: "клацнули 10, вибрано \(describe(list.selection))"))

        list.click(item: 15, modifiers: .shift)
        let span = IndexSet(integersIn: 10...15)
        checks.append(Check(area: "Вікно AppKit", name: "Відрізок із Shift",
                            status: list.selection == span ? .ok : .failed,
                            detail: "10, потім Shift+15 — чекали 10…15, вибрано \(describe(list.selection))"))

        list.click(item: 12, modifiers: .shift)
        let shrunk = IndexSet(integersIn: 10...12)
        checks.append(Check(area: "Вікно AppKit", name: "Відрізок із Shift рахує від опорного рядка",
                            status: list.selection == shrunk ? .ok : .failed,
                            detail: "потім Shift+12 — чекали 10…12, вибрано \(describe(list.selection))"))

        list.click(item: 100)
        list.click(item: 200, modifiers: .control)
        list.click(item: 300, modifiers: .command)
        var scattered = IndexSet([100, 200, 300])
        checks.append(Check(area: "Вікно AppKit", name: "Виділення врозбивку Ctrl і ⌘",
                            status: list.selection == scattered ? .ok : .failed,
                            detail: "чекали 100, 200, 300 — вибрано \(describe(list.selection))"))

        list.click(item: 200, modifiers: .control)
        scattered.remove(200)
        checks.append(Check(area: "Вікно AppKit", name: "Повторний Ctrl знімає рядок",
                            status: list.selection == scattered ? .ok : .failed,
                            detail: "чекали 100, 300 — вибрано \(describe(list.selection))"))

        list.selectAll()
        checks.append(Check(area: "Вікно AppKit", name: "Виділити все",
                            status: list.selection.count == list.itemCount ? .ok : .failed,
                            detail: "вибрано \(list.selection.count) із \(list.itemCount)"))

        var activated = -1
        list.onActivate = { activated = $0 }
        list.click(item: 7, clickCount: 2)
        checks.append(Check(area: "Вікно AppKit", name: "Подвійне клацання",
                            status: activated == 7 ? .ok : .failed,
                            detail: activated == 7 ? "рядок 7 пішов на показ" : "не спрацювало"))
        list.onActivate = nil

        list.setSelection(IndexSet(integer: 0), active: 0)
        return checks
    }

    // MARK: - Прокрутка

    private static func nativeScroll(_ list: NativeList, _ host: NSView) -> [Check] {
        var checks: [Check] = []

        list.scrollTo(3399, place: .center)
        host.layoutSubtreeIfNeeded()
        let visible = list.visibleItems
        checks.append(Check(area: "Вікно AppKit", name: "Прокрутка до рядка",
                            status: visible.contains(3399) ? .ok : .failed,
                            detail: "просили 3399, видно \(visible.lowerBound)…\(max(visible.lowerBound, visible.upperBound - 1))"))

        list.scrollTo(0, place: .top)
        host.layoutSubtreeIfNeeded()
        let top = list.visibleItems
        checks.append(Check(area: "Вікно AppKit", name: "Прокрутка на початок",
                            status: top.lowerBound == 0 ? .ok : .failed,
                            detail: "перший видимий рядок \(top.lowerBound)"))

        list.scrollTo(1700, place: .center)
        host.layoutSubtreeIfNeeded()
        let middle = list.visibleItems
        let centred = middle.contains(1700)
        checks.append(Check(area: "Вікно AppKit", name: "Прокрутка до рядка посередині",
                            status: centred ? .ok : .failed,
                            detail: "просили 1700, видно \(middle.lowerBound)…\(max(middle.lowerBound, middle.upperBound - 1))"))
        return checks
    }

    /// Розділ «Редагування»: без нього ⌘V, ⌘C, ⌘X, ⌘A і ⌘Z у полях не
    /// працюють зовсім — поле отримує ці команди лише через пункти меню.
    private static func nativeEditMenu(_ host: NSView) -> Check {
        let name = "Меню «Редагування»: вставка й копіювання в полях"
        guard let main = NSApp.mainMenu else {
            return Check(area: "Вікно AppKit", name: name, status: .skipped, detail: "рядка меню немає")
        }
        let wanted: [(String, String, NSEvent.ModifierFlags)] = [
            ("undo:", "z", [.command]), ("redo:", "z", [.command, .shift]),
            ("cut:", "x", [.command]), ("copy:", "c", [.command]),
            ("paste:", "v", [.command]), ("selectAll:", "a", [.command]),
        ]
        let edit = main.items.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.action.map(NSStringFromSelector) == "paste:" }
        }
        guard let edit else {
            return Check(area: "Вікно AppKit", name: name, status: .failed,
                         detail: "у рядку меню немає розділу з «Вставити» — ⌘V у полях не працює")
        }
        var trouble: [String] = []
        // Перед показом розділ прибирає повтори системних пунктів.
        edit.delegate?.menuNeedsUpdate?(edit)
        let keys = edit.items.filter { !$0.isSeparatorItem }.map { ($0.action.map(NSStringFromSelector) ?? "") + "|" + $0.title }
        let repeated = Set(keys.filter { key in keys.filter { $0 == key }.count > 1 })
        if !repeated.isEmpty { trouble.append("пункти повторюються: \(repeated.sorted())") }
        let field = NSTextField(string: "Слово на пробу")
        field.frame = NSRect(x: 0, y: 900, width: 200, height: 22)
        host.addSubview(field)
        defer { field.removeFromSuperview() }
        host.window?.makeFirstResponder(field)
        let editor = field.currentEditor()
        if editor == nil { trouble.append("поле не дало редактора") }
        for (action, key, modifiers) in wanted {
            guard let item = edit.items.first(where: { $0.action.map(NSStringFromSelector) == action }) else {
                trouble.append("немає пункту \(action)")
                continue
            }
            if item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers {
                trouble.append("\(action) на «\(item.keyEquivalent)», а не на «\(key)»")
            }
            if item.target != nil { trouble.append("\(action) прив'язаний до цілі, а не до фокуса") }
            if item.title.isEmpty || item.title.hasPrefix("Отмен") || item.title == "Вставить" {
                trouble.append("\(action) без українського підпису: «\(item.title)»")
            }
            // Скасування веде вікно (його `undoManager`), а не редактор поля.
            if let editor, !action.hasSuffix("do:"), !editor.responds(to: NSSelectorFromString(action)) {
                trouble.append("редактор поля не знає \(action)")
            }
        }
        if let editor {
            editor.selectAll(nil)
            if editor.selectedRange.length != field.stringValue.utf16.count {
                trouble.append("«Виділити все» в полі виділило \(editor.selectedRange.length) знаків")
            }
        }
        host.window?.makeFirstResponder(nil)
        return Check(area: "Вікно AppKit", name: name, status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "розділ «\(edit.title)»: " + edit.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: ", ")
                         : trouble.joined(separator: "; "))
    }

    /// Системні підписи — мовою системи.
    ///
    /// Пакет не оголошував жодної мови, і macOS брала англійську: у вікні
    /// вибору файлу «Cancel» і «Favorites», у меню «Undo Paste», «AutoFill»,
    /// розмір «8,8 MB» — на українській системі (0.85).
    private static func nativeBundleLanguages() -> Check {
        let name = "Системні підписи мовою системи, а не англійською"
        var trouble: [String] = []
        let declared = (Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]) ?? []
        if !declared.contains("uk") { trouble.append("пакет не оголошує українську (CFBundleLocalizations: \(declared))") }
        // Основна мова пакета — англійська: її macOS бере, коли мова системи
        // не українська, не російська й не німецька (власник: інакше — англійська).
        if Bundle.main.developmentLocalization != "en" {
            trouble.append("основна мова пакета «\(Bundle.main.developmentLocalization ?? "—")», а не en")
        }
        let rule = [(["uk-UA"], "uk"), (["uk"], "uk"), (["ru-UA"], "ru"), (["ru"], "ru"),
                    (["en-US"], "en"), (["pl-PL", "uk"], "en"), (["de-DE"], "en"), ([], "en")]
        for (languages, wanted) in rule where AppState.systemDefaultLanguage(preferred: languages) != wanted {
            trouble.append("мова за умовчанням для \(languages) — \(AppState.systemDefaultLanguage(preferred: languages)), а не \(wanted)")
        }
        let system = Locale.preferredLanguages.first ?? "—"
        let chosen = Bundle.main.preferredLocalizations.first ?? "—"
        let undo = UndoManager().undoMenuTitle(forUndoActionName: "X")
        if system.hasPrefix("uk") {
            if chosen != "uk" { trouble.append("система українська, а пакет узяв «\(chosen)»") }
            if undo.hasPrefix("Undo") { trouble.append("меню скасування англійською: «\(undo)»") }
        }
        return Check(area: "Вікно AppKit", name: name, status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "система \(system), пакет \(chosen), оголошено \(declared.joined(separator: ", ")); «\(undo)»"
                         : trouble.joined(separator: "; "))
    }

    /// Прокрутка, про яку попросили, поки список ще не мав висоти.
    ///
    /// Так відкривалася вкладка «Пісні»: першу пісню ставили «по центру»
    /// видимої області заввишки нуль, список з'їжджав на пів рядка, і вибрана
    /// перша пісня стояла під полем швидкого вибору (0.84, скачана збірка).
    private static func nativeScrollBeforeHeight(_ host: NSView) -> [Check] {
        var checks: [Check] = []
        let source = CountingSource(count: 60)
        let list = NativeList(mode: .list, metrics: .songs, heights: .uniform(34), fontSize: 13)
        list.frame = NSRect(x: 900, y: 0, width: 340, height: 0)
        host.addSubview(list)
        defer {
            list.source = nil
            list.removeFromSuperview()
        }
        list.source = source
        host.layoutSubtreeIfNeeded()

        list.scrollTo(0, place: .center)
        host.layoutSubtreeIfNeeded()
        list.frame.size.height = 600
        host.layoutSubtreeIfNeeded()
        let offset = list.scrollOffsetForCheck
        checks.append(Check(area: "Вікно AppKit", name: "Перший рядок, вибраний до появи висоти, видно цілком",
                            status: abs(offset) < 0.5 ? .ok : .failed,
                            detail: "зсув від початку \(Int(offset.rounded())) пт, перший видимий рядок \(list.visibleItems.lowerBound)"))

        list.frame.size.height = 0
        host.layoutSubtreeIfNeeded()
        list.scrollTo(45, place: .center)
        list.frame.size.height = 300
        host.layoutSubtreeIfNeeded()
        let visible = list.visibleItems
        checks.append(Check(area: "Вікно AppKit", name: "Рядок посередині, вибраний до появи висоти, стає видно",
                            status: visible.contains(45) ? .ok : .failed,
                            detail: "просили 45, видно \(visible.lowerBound)…\(max(visible.lowerBound, visible.upperBound - 1))"))
        return checks
    }

    // MARK: - Одна строка

    /// Проверка считает не отрисовки, а обращения к источнику.
    ///
    /// Так вернее: отрисовка идёт через оконный сервер, и в самопроверке окно
    /// на экран не выводится — счётчик отрисовок показал бы ноль на исправном
    /// коде. А вот обращение к источнику — это ровно та работа, которой
    /// прежнее окно занималось три с половиной тысячи раз на одно нажатие.
    private static func nativeSingleRow(_ list: NativeList, _ source: CountingSource,
                                        _ host: NSView) -> [Check] {
        list.scrollTo(0, place: .top)
        host.layoutSubtreeIfNeeded()

        let visible = list.visibleItems
        guard visible.count > 3 else {
            return [Check(area: "Вікно AppKit", name: "Оновлення одного рядка",
                          status: .skipped, detail: "на екрані замало рядків")]
        }

        let target = visible.lowerBound + 2
        source.forget()
        list.reloadRow(target)
        let asked = source.asked
        let onlyTarget = asked.count == 1 && asked[target] == 1

        source.forget()
        list.reloadRow(3000)
        let offscreen = source.asked.isEmpty

        // Выбор ставится заранее и только потом сдвигается: иначе в счёт
        // попала бы ещё и строка, с которой выбор снимался в самом начале.
        list.setSelection(IndexSet(integer: target), active: target)
        source.forget()
        list.setSelection(IndexSet(integer: target + 1), active: target + 1)
        let afterSelection = source.asked.keys.sorted()
        let twoRows = afterSelection == [target, target + 1]

        list.setSelection(IndexSet())
        return [
            Check(area: "Вікно AppKit", name: "Оновлення одного рядка не чіпає сусідніх",
                  status: onlyTarget ? .ok : .failed,
                  detail: onlyTarget
                      ? "перечитано рядок \(target), і лише його"
                      : "перечитано рядки \(asked.keys.sorted().map(String.init).joined(separator: ", "))"),
            Check(area: "Вікно AppKit", name: "Невидимий рядок оновлюється задарма",
                  status: offscreen ? .ok : .failed,
                  detail: offscreen
                      ? "рядок 3000 за краєм вікна — джерело не питали зовсім"
                      : "джерело все одно спитали про \(source.asked.count) рядків"),
            Check(area: "Вікно AppKit", name: "Зміна виділення чіпає два рядки",
                  status: twoRows ? .ok : .failed,
                  detail: twoRows
                      ? "вибір пішов із \(target) на \(target + 1) — перечитано обидва, і лише їх"
                      : "перечитано рядків \(afterSelection.count) із \(list.itemCount)"),
        ]
    }

    // MARK: - Плитка

    private static func nativeTiles(_ host: NSView) -> [Check] {
        let source = CountingSource(count: 77)
        let tiles = NativeList(mode: .tiles(minItemWidth: 74, itemHeight: 46, gap: 3),
                               metrics: .books, heights: .uniform(46), fontSize: 13)
        tiles.frame = NSRect(x: 500, y: 0, width: 320, height: 400)
        host.addSubview(tiles)
        tiles.source = source
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // 320 точек ширины при клетке 74 и просвете 3 — это четыре клетки в ряд.
        let visible = tiles.visibleItems
        let manyPerRow = visible.count > 8
        tiles.click(item: 30)
        let picked = tiles.selection == IndexSet(integer: 30)

        tiles.source = nil
        tiles.removeFromSuperview()
        return [
            Check(area: "Вікно AppKit", name: "Сітка книг плиткою",
                  status: manyPerRow && picked ? .ok : .failed,
                  detail: "клітинок видно \(visible.count) на 77 книг; "
                      + (picked ? "клацання по клітинці 30 вибрало її" : "клацання по клітинці не спрацювало")),
        ]
    }

    // MARK: - Скорость

    private static func nativeSpeed(_ list: NativeList, _ host: NSView) -> [Check] {
        list.scrollTo(0, place: .top)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        func median(_ repeats: Int, _ body: (Int) -> Void) -> Double {
            var times: [Double] = []
            times.reserveCapacity(repeats)
            for pass in 0..<repeats {
                let start = DispatchTime.now().uptimeNanoseconds
                body(pass)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let sorted = times.sorted()
            return sorted[sorted.count / 2]
        }

        let base = list.visibleItems.lowerBound
        let width = max(1, list.visibleItems.count)
        let rowTime = median(60) { pass in list.reloadRow(base + pass % width) }
        let selectTime = median(60) { pass in
            list.setSelection(IndexSet(integer: base + pass % width), active: base + pass % width)
        }
        let scrollTime = median(60) { pass in
            list.scrollTo((pass * 137) % list.itemCount, place: .center)
        }
        list.setSelection(IndexSet())

        func check(_ name: String, _ value: Double) -> Check {
            Check(area: "Вікно AppKit", name: name,
                  status: value < 16 ? .ok : .failed,
                  detail: String(format: "%.3f мс на 3400 рядків (кадр — 16 мс)", value))
        }

        return [
            check("Швидкість: оновити один рядок", rowTime),
            check("Швидкість: змінити виділення", selectTime),
            check("Швидкість: прокрутка списку", scrollTime),
        ]
    }

    // MARK: - Точечные оповещения

    private static func nativeSignals() -> [Check] {
        var checks: [Check] = []
        let hub = Signals.shared

        var verses = 0
        var books = 0
        let a = hub.subscribe(.verseSelection) { verses += 1 }
        let b = hub.subscribe(.books) { books += 1 }
        hub.send(.verseSelection)
        checks.append(Check(area: "Вікно AppKit", name: "Сповіщення доходить лише до своїх",
                            status: verses == 1 && books == 0 ? .ok : .failed,
                            detail: "послали «вибір вірша»: вірші отримали \(verses), книги \(books)"))

        verses = 0
        books = 0
        hub.batch {
            hub.send(.verseSelection)
            hub.send(.verseSelection)
            hub.send(.books)
            hub.send(.verseSelection)
        }
        checks.append(Check(area: "Вікно AppKit", name: "Гуртом — по одному разу на повід",
                            status: verses == 1 && books == 1 ? .ok : .failed,
                            detail: "тричі «вибір вірша» і один «книги» — дійшло \(verses) і \(books)"))

        let before = hub.subscriberCount(.verseSelection)
        do {
            let temporary = hub.subscribe(.verseSelection) { verses += 1 }
            _ = temporary
        }
        let after = hub.subscriberCount(.verseSelection)
        checks.append(Check(area: "Вікно AppKit", name: "Підписка знімається сама",
                            status: after == before ? .ok : .warning,
                            detail: "було підписок \(before), після відпущеної — \(after)"))

        // Подписчик вправе тронуть состояние в ответ, и оно пошлёт тот же
        // повод обратно. Программа обязана это пережить, а не зациклиться.
        var loops = 0
        let c = hub.subscribe(.slide) {
            loops += 1
            if loops < 5 { hub.send(.slide) }
        }
        hub.send(.slide)
        checks.append(Check(area: "Вікно AppKit", name: "Повід сам себе не зациклює",
                            status: loops == 5 ? .ok : (loops > 0 && loops < 50 ? .warning : .failed),
                            detail: "підписник п'ять разів послав повід собі — кіл \(loops)"))

        _ = a
        _ = b
        _ = c
        return checks
    }

    // MARK: - Каркас окна

    private static func nativeWindowFrame() -> [Check] {
        var checks: [Check] = []

        let root = NativeRootView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        root.layoutSubtreeIfNeeded()

        let missing = NativeSlot.allCases.filter { root.slots[$0] == nil }
        checks.append(Check(area: "Вікно AppKit", name: "Частини вікна на місцях",
                            status: missing.isEmpty ? .ok : .failed,
                            detail: missing.isEmpty
                                ? "сім частин: меню, вкладки, робоча область, результати пошуку, "
                                    + "смуга перекладів, медіаплеєр, нижній ряд"
                                : "немає частин: \(missing.map(\.rawValue).joined(separator: ", "))"))

        let heights = NativeSlot.allCases.compactMap { slot -> String? in
            guard let view = root.slots[slot], !view.isHidden else { return nil }
            guard let expected = slot.height else { return nil }
            return abs(view.frame.height - expected) < 0.5 ? nil
                : "\(slot.rawValue): чекали \(Int(expected)), вийшло \(Int(view.frame.height))"
        }
        checks.append(Check(area: "Вікно AppKit", name: "Висоти частин як в описі",
                            status: heights.isEmpty ? .ok : .failed,
                            detail: heights.isEmpty
                                ? "вкладки 30, смуга перекладів 30, нижній ряд \(Int(NativeSlot.bottomRow.height ?? 218)) (смуги меню у вікні більше немає)"
                                : heights.joined(separator: "; ")))

        let workspace = root.slots[.workspace]?.frame.height ?? 0
        // 1000 мінус вкладки, смуга перекладів, нижній ряд і чотири
        // розділові лінії. Висоту нижнього ряду беремо не числом: її тягне
        // сам оператор, і зашите 218 сварилося б на кожне розтягування.
        // Смуги меню у вікні більше немає — меню в програми одне, в рядку macOS.
        let expected: CGFloat = 1000 - (30 + 30 + (NativeSlot.bottomRow.height ?? 218)) - 4
        checks.append(Check(area: "Вікно AppKit", name: "Робоча область забирає решту",
                            status: abs(workspace - expected) < 1 ? .ok : .failed,
                            detail: "у вікні 1000 точок робочій області дісталося \(Int(workspace)), "
                                + "чекали \(Int(expected))"))

        // Прежде плеер был отдельной полосой и отнимал место у рабочей области.
        // Теперь он четвёртый режим и занимает её целиком, как Библия и Песни:
        // отнимать не у кого, и проверять здесь нечего.

        // По-настоящему: окно обязано существовать и быть наполненным.
        // Прежняя проверка была зелёной безусловно и не поймала бы даже
        // полностью отвязанное окно — ловушку «написано, но не подключено»
        // мы уже проходили трижды.
        let controller = NativeMainWindowController.shared
        let live = controller.window != nil
        // Полосы меню в окне больше нет — меню у программы одно, в строке macOS.
        let filled = [NativeSlot.modeTabs, .workspace, .translationStrip, .bottomRow]
            .allSatisfy { !(controller.slotView($0)?.subviews.isEmpty ?? true) }
        checks.append(Check(area: "Вікно AppKit", name: "Вікно програми піднято",
                            status: live && filled ? .ok : .failed,
                            detail: live
                                ? (filled ? "вікно піднято, усі п'ять частин на місцях"
                                          : "вікно піднято, але частини не розставлено")
                                : "вікно не піднято"))
        return checks
    }

    private static func describe(_ set: IndexSet) -> String {
        guard !set.isEmpty else { return "нічого" }
        if set.count > 6 { return "\(set.count) рядків, з \(set.first ?? 0) по \(set.last ?? 0)" }
        return set.map(String.init).joined(separator: ", ")
    }
}
