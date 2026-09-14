import AppKit
import SlovoCore

/// Рядок меню macOS — власноруч, засобами AppKit.
///
/// Раніше його збирав SwiftUI (`Commands`): збирати напряму було не можна,
/// бо сцена переписувала `NSApp.mainMenu` при кожному оновленні.
/// Сцени більше немає — і меню тепер просто меню: пункти беруться з того самого
/// опису `SlovoMenu`, що й смуга всередині вікна, а сполучення клавіш із вікна
/// «Параметри» (6.1.6) потрапляють у нього самі.
///
/// Пункти перезбираються тієї миті, коли людина відкрила розділ
/// (`menuNeedsUpdate`): галочки й підписи тоді не можуть відстати від
/// стану, а роботи на натискання клавіші немає зовсім — меню закрите.
@MainActor
final class NativeAppMenu: NSObject, NSMenuDelegate {

    private let state: AppState
    private var groups: [ObjectIdentifier: NativeMenuGroup] = [:]

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// Зібрати й поставити рядок меню.
    func install() {
        let main = NSMenu()

        // Розділ з іменем програми: у macOS він перший і обов'язковий, інакше
        // «Приховати» й «Вийти» людині взяти ніде.
        let app = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: state.text("N5", default: "О программе..."),
                                        action: #selector(about), keyEquivalent: "")
        aboutItem.target = self
        relabelers.append { [weak aboutItem, weak self] in
            guard let self else { return }
            aboutItem?.title = self.state.text("N5", default: "О программе...")
        }
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: OurWords.t("Скрыть «Слово»"),
                                       action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        relabelers.append { [weak hideItem] in hideItem?.title = OurWords.t("Скрыть «Слово»") }
        let others = appMenu.addItem(withTitle: OurWords.t("Скрыть остальные"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        relabelers.append { [weak others] in others?.title = OurWords.t("Скрыть остальные") }
        let showAll = appMenu.addItem(withTitle: OurWords.t("Показать все"),
                                      action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        relabelers.append { [weak showAll] in showAll?.title = OurWords.t("Показать все") }
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: OurWords.t("Завершить «Слово»"),
                                       action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        relabelers.append { [weak quitItem] in quitItem?.title = OurWords.t("Завершить «Слово»") }
        app.submenu = appMenu
        main.addItem(app)

        // Далі — розділи опису, у тому самому порядку, що й у вікні.
        for group in NativeMenuGroup.allCases {
            let item = NSMenuItem()
            let menu = NSMenu(title: caption(of: group))
            menu.delegate = self
            menu.autoenablesItems = false
            groups[ObjectIdentifier(menu)] = group
            item.title = menu.title
            item.submenu = menu
            main.addItem(item)
            // Наповнюємо одразу, а не тільки при відкритті: пункти меню шукає і
            // сама система — у «Довідці» по рядку меню, — а самоперевірка
            // звіряє за ними опис. Порожнє до першого відкриття меню і для
            // того, і для іншого виглядає як «пунктів немає зовсім».
            menuNeedsUpdate(menu)
            if group == .file { main.addItem(editItem()) }
        }

        // «Вікно» — системний розділ: згорнути, розгорнути, список вікон.
        let windows = NSMenuItem()
        let windowsMenu = NSMenu(title: OurWords.t("Окно"))
        let minimize = windowsMenu.addItem(withTitle: OurWords.t("Свернуть"),
                                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let zoom = windowsMenu.addItem(withTitle: OurWords.t("Развернуть"),
                                       action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.submenu = windowsMenu
        windows.title = windowsMenu.title
        relabelers.append { [weak windows, weak windowsMenu, weak minimize, weak zoom] in
            windowsMenu?.title = OurWords.t("Окно")
            windows?.title = OurWords.t("Окно")
            minimize?.title = OurWords.t("Свернуть")
            zoom?.title = OurWords.t("Развернуть")
        }
        main.addItem(windows)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowsMenu
    }

    /// «Редагування» — стандартні команди тексту: скасувати, вирізати,
    /// копіювати, вставити, виділити все.
    ///
    /// У macOS ⌘C, ⌘V, ⌘X, ⌘A і ⌘Z поле введення отримує не саме, а через
    /// пункти цього розділу. Поки розділу не було, у жодному полі програми —
    /// пошук, назва пісні, текст оголошення, «Перейти до теки» у вікні вибору
    /// файлу — не працювали ні вставка, ні копіювання (0.84, перевірка
    /// скачаної збірки). Ціль у пунктів порожня: команду бере той, хто зараз
    /// у фокусі, а коли взяти нікому, пункт гасне сам і клавіша йде далі.
    private func editItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: OurWords.t("Правка"))
        // Системні пункти («Автозаповнення», «Почати диктування…», «Емодзі та
        // символи») macOS дописує в цей розділ сама — і, бувало, не раз: на
        // стенді «Емодзі» стояли тричі. Повтори прибираємо перед показом.
        menu.delegate = self
        editMenu = menu
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Отменить действие", Selector(("undo:")), "z", [.command]),
            ("Повторить действие", Selector(("redo:")), "z", [.command, .shift]),
            ("", Selector(("separator")), "", []),
            ("Вырезать", #selector(NSText.cut(_:)), "x", [.command]),
            ("Копировать", #selector(NSText.copy(_:)), "c", [.command]),
            ("Вставить", #selector(NSText.paste(_:)), "v", [.command]),
            ("Выделить всё", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        var labelled: [(NSMenuItem, String)] = []
        for (title, action, key, modifiers) in entries {
            guard !title.isEmpty else {
                menu.addItem(.separator())
                continue
            }
            let entry = menu.addItem(withTitle: OurWords.t(title), action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            labelled.append((entry, title))
        }
        item.title = menu.title
        item.submenu = menu
        relabelers.append { [weak item, weak menu] in
            menu?.title = OurWords.t("Правка")
            item?.title = OurWords.t("Правка")
            for (entry, title) in labelled { entry.title = OurWords.t(title) }
        }
        return item
    }

    private weak var editMenu: NSMenu?

    /// Прибрати пункти, що стоять удруге з тією самою дією й підписом, і
    /// роздільники, що опинилися поруч.
    func removeRepeatedItems(in menu: NSMenu) {
        var seen: Set<String> = []
        for item in menu.items.reversed() {
            guard !item.isSeparatorItem, let action = item.action else { continue }
            let key = NSStringFromSelector(action) + "|" + item.title
            if !seen.insert(key).inserted { menu.removeItem(item) }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item); continue }
            previousWasSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Пункти, побудовані раз і назавжди (розділ програми та «Вікно»): з
    /// опису вони не збираються, тому при зміні мови перепідписуються тут.
    private var relabelers: [() -> Void] = []

    /// Перебрати підписи розділів — мову інтерфейсу змінили.
    func relabel() {
        relabelers.forEach { $0() }
        guard let main = NSApp.mainMenu else { return }
        for item in main.items {
            guard let submenu = item.submenu,
                  let group = groups[ObjectIdentifier(submenu)] else { continue }
            item.title = caption(of: group)
            submenu.title = item.title
        }
    }

    private func caption(of group: NativeMenuGroup) -> String {
        state.text(group.captionKey, default: group.captionFallback)
    }

    // MARK: - Наповнення

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === editMenu {
            removeRepeatedItems(in: menu)
            return
        }
        guard let group = groups[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        for entry in SlovoMenu.entries(for: group, state: state) {
            if entry.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key ?? "")
            item.keyEquivalentModifierMask = entry.modifiers
            item.state = entry.isOn ? .on : .off
            if let action = entry.action {
                item.target = self
                item.action = #selector(run(_:))
                item.representedObject = MenuActionBox(action)
                item.isEnabled = true
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuActionBox)?.action()
    }

    @objc private func about() { state.menuActions.about() }
}

/// Дія пункту, загорнута в об'єкт: `representedObject` зберігає тільки
/// посилальні величини, а замикання — величина значення.
final class MenuActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}
