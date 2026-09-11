import AppKit
import SlovoCore

/// Самопроверка верха нового окна: полоса меню и вкладки режима.
///
/// Проверять здесь надо не «нарисовалось ли», а «не врёт ли». На полосе меню
/// уже дважды обжигались: раздел «Интерфейс» показывал прежний вид списков до
/// самого перезапуска, потому что барьер сравнения о такой правке не знал.
/// Поэтому ниже меню открывают по-настоящему — и сверяют то, что в нём
/// оказалось, с тем, что в этот миг записано в настройках.
extension Diagnostics {

    static func nativeTopSection(state: AppState) -> [Check] {
        var checks: [Check] = []

        // Настоящее окно: без раскладки вкладки не получат ширины, и мерить
        // было бы нечего.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let bar = NativeMenuBar(state: state)
        bar.frame = NSRect(x: 8, y: 0, width: 1584, height: 26)
        host.addSubview(bar)
        let tabs = NativeModeTabs(state: state)
        tabs.frame = NSRect(x: 8, y: 30, width: 1584, height: 30)
        host.addSubview(tabs)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        checks.append(contentsOf: topMenuComposition(bar, state))
        checks.append(contentsOf: topMenuLazy(bar, state))
        checks.append(contentsOf: topMenuLanguage(bar, state))
        checks.append(contentsOf: topMenuMarks(bar, state))
        checks.append(contentsOf: topTabs(tabs, state))
        checks.append(contentsOf: topSlider(tabs, state))
        checks.append(contentsOf: topSpeed(bar, tabs, state, host))

        bar.removeFromSuperview()
        tabs.removeFromSuperview()
        window.contentView = nil
        return checks
    }

    // MARK: - Состав полосы меню

    private static func topMenuComposition(_ bar: NativeMenuBar, _ state: AppState) -> [Check] {
        var checks: [Check] = []

        let captions = NativeMenuGroup.allCases.map { bar.caption(of: $0) }
        let empty = captions.filter(\.isEmpty).count
        checks.append(Check(area: "Верх вікна AppKit", name: "Шість розділів меню на місцях",
                            status: captions.count == 6 && empty == 0 ? .ok : .failed,
                            detail: captions.joined(separator: " · ")))

        // Состав пунктов — по описи окна: три в «Файле», двенадцать в
        // «Действиях», четыре в «Настройке», три в «Справке».
        // Опись пополнилась тем, что раньше было только в строке macOS:
        // быстрый выбор по книге, главе и стиху и шаг по стихам и главам.
        // «Настройка» і «Помощь» — по два пункти понад оригінал: «Пульт у
        // браузері…» і «Програми для Android…». Власник: «нужно, чтобы в
        // основной программе были подсказки по запуску с браузера».
        let expected: [NativeMenuGroup: Int] = [.file: 3, .actions: 19, .settings: 6, .help: 5]
        var wrong: [String] = []
        for (group, count) in expected {
            let got = bar.entries(for: group).count
            if got != count { wrong.append("\(bar.caption(of: group)): чекали \(count), вийшло \(got)") }
        }
        checks.append(Check(area: "Верх вікна AppKit", name: "Пункти розділів не загубилися",
                            status: wrong.isEmpty ? .ok : .failed,
                            // Числа — справжні, а не записані рядком: колишній
                            // рядок пережив і поповнення «Дій», і нові пункти
                            // «Налаштування» та «Довідки», і казав неправду.
                            detail: wrong.isEmpty
                                ? [NativeMenuGroup.file, .actions, .settings, .help]
                                    .map { "\(bar.caption(of: $0)) \(bar.entries(for: $0).count)" }
                                    .joined(separator: ", ") + " — як в описі"
                                : wrong.joined(separator: "; ")))

        let languages = state.languageCatalog?.languages.count ?? 0
        let inMenu = bar.entries(for: .language).count
        checks.append(Check(area: "Верх вікна AppKit", name: "У «Language/Мова» всі мови каталогу",
                            status: inMenu == languages + 1 ? .ok : .failed,
                            detail: "мов у каталозі \(languages), пунктів \(inMenu) "
                                + "(разом із «Виберіть мову…»)"))
        return checks
    }

    // MARK: - Меню собирается в миг открытия

    private static func topMenuLazy(_ bar: NativeMenuBar, _ state: AppState) -> [Check] {
        var checks: [Check] = []

        let closed = bar.menu(for: .language)?.numberOfItems ?? -1
        checks.append(Check(area: "Верх вікна AppKit", name: "Закрите меню порожнє",
                            status: closed == 0 ? .ok : .failed,
                            detail: closed == 0
                                ? "поки меню не відкрили, пунктів не існує зовсім — "
                                    + "і брехати про стан нічому"
                                : "у закритому меню вже лежить \(closed) пунктів"))

        bar.rebuild(.language)
        let opened = bar.menu(for: .language)?.numberOfItems ?? 0
        checks.append(Check(area: "Верх вікна AppKit", name: "Відкриття збирає пункти",
                            status: opened > 1 ? .ok : .failed,
                            detail: "після відкриття в «Language/Мова» \(opened) пунктів"))
        return checks
    }

    // MARK: - Полоса идёт за языком

    private static func topMenuLanguage(_ bar: NativeMenuBar, _ state: AppState) -> [Check] {
        // Берём не первый попавшийся язык, а тот, у которого подпись раздела
        // и вправду другая. У белорусского «Файл» пишется так же, как у
        // русского, — на нём проверка проходила бы и в том случае, если бы
        // полоса за языком не шла вовсе.
        guard let catalog = state.languageCatalog, let current = state.language else {
            return [Check(area: "Верх вікна AppKit", name: "Підписи йдуть за мовою інтерфейсу",
                          status: .skipped, detail: "мови інтерфейсу немає")]
        }
        let mine = current.caption("N1", form: "MainForm", default: "Файл")
        let differing = catalog.languages.first {
            $0.code != current.code && $0.caption("N1", form: "MainForm", default: "Файл") != mine
        }
        guard let other = differing ?? catalog.languages.first(where: { $0.code != current.code })
        else {
            return [Check(area: "Верх вікна AppKit", name: "Підписи йдуть за мовою інтерфейсу",
                          status: .skipped, detail: "у каталозі менше двох мов")]
        }

        state.setLanguage(code: other.code)
        let afterCaption = bar.caption(of: .file)
        let wanted = other.caption("N1", form: "MainForm", default: "Файл")
        let menuFollows = afterCaption == wanted

        // Галочка языка обязана переехать вместе с подписями.
        bar.rebuild(.language)
        let marked = (0..<(bar.menu(for: .language)?.numberOfItems ?? 0))
            .compactMap { bar.menu(for: .language)?.item(at: $0) }
            .filter { $0.state == .on }
            .map(\.title)
        let markFollows = marked == [other.displayName]

        state.setLanguage(code: current.code)
        let back = bar.caption(of: .file) == current.caption("N1", form: "MainForm", default: "Файл")

        return [
            Check(area: "Верх вікна AppKit", name: "Підписи йдуть за мовою інтерфейсу",
                  status: menuFollows && back ? .ok : .failed,
                  detail: menuFollows && back
                      ? "було «\(mine)»; перемкнули на «\(other.displayName)» — розділ став "
                          + "«\(afterCaption)», повернули — став «\(bar.caption(of: .file))»"
                      : "чекали «\(wanted)», намальовано «\(afterCaption)»"),
            Check(area: "Верх вікна AppKit", name: "Галочка мови стоїть біля вибраної",
                  status: markFollows ? .ok : .failed,
                  detail: markFollows
                      ? "позначено одну мову — «\(other.displayName)»"
                      : "позначено: \(marked.isEmpty ? "ничего" : marked.joined(separator: ", "))"),
        ]
    }

    // MARK: - Галочки видов списков

    private static func topMenuMarks(_ bar: NativeMenuBar, _ state: AppState) -> [Check] {
        let interface = InterfaceSettings.shared
        let scope = state.listScope
        let was = interface.bookView(scope)
        let other: InterfaceSettings.BookViewMode = was == .table ? .list : .table

        interface.setBookView(other, in: scope)
        bar.rebuild(.interface)
        let title = state.text(other.captionKey, default: other.captionFallback)
        let items = (0..<(bar.menu(for: .interface)?.numberOfItems ?? 0))
            .compactMap { bar.menu(for: .interface)?.item(at: $0) }
        let marked = items.filter { $0.state == .on }.map(\.title)
        let right = marked.contains(title)
        interface.setBookView(was, in: scope)

        // И обратно: галочка обязана переехать назад без перезапуска.
        bar.rebuild(.interface)
        let backTitle = state.text(was.captionKey, default: was.captionFallback)
        let backMarked = (0..<(bar.menu(for: .interface)?.numberOfItems ?? 0))
            .compactMap { bar.menu(for: .interface)?.item(at: $0) }
            .filter { $0.state == .on }
            .map(\.title)
        let backRight = backMarked.contains(backTitle)

        return [Check(area: "Верх вікна AppKit", name: "Галочка вигляду списків не бреше",
                      status: right && backRight ? .ok : .failed,
                      detail: right && backRight
                          ? "вибрали «\(title)» — позначка там само; повернули «\(backTitle)» — "
                              + "переїхала назад, без перезапуску"
                          : "після вибору «\(title)» позначено: "
                              + (marked.isEmpty ? "нічого" : marked.joined(separator: ", ")))]
    }

    // MARK: - Вкладки режима

    private static func topTabs(_ tabs: NativeModeTabs, _ state: AppState) -> [Check] {
        var checks: [Check] = []

        let chosen = tabs.chosenMode
        checks.append(Check(area: "Верх вікна AppKit", name: "Вибрано ту вкладку, що й режим",
                            status: chosen == state.mode ? .ok : .failed,
                            detail: "режим \(state.mode.rawValue), вибрано вкладку "
                                + "\(chosen?.rawValue ?? "ни одна")"))

        let was = state.mode
        var came = 0
        let token = Signals.shared.subscribe(.mode) { came += 1 }
        let other: AppState.WorkMode = was == .text ? .bible : .text
        tabs.select(other)
        let moved = tabs.chosenMode == other
        tabs.select(was)
        _ = token

        checks.append(Check(area: "Верх вікна AppKit", name: "Натискання вкладки перефарбовує вкладки",
                            status: moved && tabs.chosenMode == was ? .ok : .failed,
                            detail: moved
                                ? "натиснули «\(other.rawValue)» — позначка переїхала, повернули — повернулася"
                                : "натиснули «\(other.rawValue)», вибраною лишилася "
                                    + "\(tabs.chosenMode?.rawValue ?? "ни одна")"))
        checks.append(Check(area: "Верх вікна AppKit", name: "Зміна режиму шле повід «mode»",
                            status: came == 2 ? .ok : .failed,
                            detail: "два перемикання — поводів \(came)"))
        return checks
    }

    // MARK: - Ползунок кегля списков

    private static func topSlider(_ tabs: NativeModeTabs, _ state: AppState) -> [Check] {
        var checks: [Check] = []

        let wasSize = state.listFontSize
        let wasSlide = state.style.main.fontSize
        var came = 0
        let token = Signals.shared.subscribe(.listFontSize) { came += 1 }

        tabs.drag(to: 17)
        let listMoved = abs(state.listFontSize - 17) < 0.001
        let slideKept = abs(state.style.main.fontSize - wasSlide) < 0.0001

        // Ctrl с колесом двигает ту же величину — ползунок обязан пойти следом.
        state.zoomLists(by: 1)
        let follows = abs(tabs.fontSize - state.listFontSize) < 0.001

        tabs.drag(to: wasSize)
        _ = token

        checks.append(Check(area: "Верх вікна AppKit", name: "Повзунок веде кегль списків",
                            status: listMoved ? .ok : .failed,
                            detail: listMoved
                                ? "зрушили на 17 — списки стали 17"
                                : "зрушили на 17, а в списках \(state.listFontSize)"))
        checks.append(Check(area: "Верх вікна AppKit", name: "Повзунок не чіпає кегля слайда",
                            status: slideKept ? .ok : .failed,
                            detail: slideKept
                                ? String(format: "кегль слайда як був, %.3f", wasSlide)
                                : String(format: "кегль слайда поїхав із %.3f на %.3f",
                                         wasSlide, state.style.main.fontSize)))
        checks.append(Check(area: "Верх вікна AppKit", name: "Повзунок іде за колесом із Ctrl",
                            status: follows ? .ok : .failed,
                            detail: String(format: "у стані %.1f, на повзунку %.1f",
                                           state.listFontSize, tabs.fontSize)))
        checks.append(Check(area: "Верх вікна AppKit", name: "Рух повзунка шле повід «кегль»",
                            status: came >= 2 ? .ok : .failed,
                            detail: "два рухи — поводів \(came)"))
        return checks
    }

    // MARK: - Скорость

    private static func topSpeed(_ bar: NativeMenuBar, _ tabs: NativeModeTabs,
                                 _ state: AppState, _ host: NSView) -> [Check] {
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

        let groups = NativeMenuGroup.allCases
        let menuTime = median(60) { pass in bar.rebuild(groups[pass % groups.count]) }

        let was = state.mode
        let order: [AppState.WorkMode] = [.text, .bible]
        let modeTime = median(40) { pass in tabs.select(order[pass % order.count]) }
        tabs.select(was)

        let wasSize = state.listFontSize
        let sliderTime = median(60) { pass in tabs.drag(to: 9 + Double(pass % 13)) }
        tabs.drag(to: wasSize)

        func check(_ name: String, _ value: Double, _ what: String) -> Check {
            Check(area: "Верх вікна AppKit", name: name,
                  status: value < 16 ? .ok : .failed,
                  detail: String(format: "%.3f мс — %@ (кадр — 16 мс)", value, what))
        }

        return [
            check("Швидкість: відкрити розділ меню", menuTime, "збирання пунктів, розкладка й малювання"),
            check("Швидкість: перемкнути режим", modeTime, "натискання вкладки з усією роботою стану"),
            check("Швидкість: зрушити повзунок кегля", sliderTime, "ступінь повзунка"),
        ]
    }
}
