import AppKit
import SlovoCore

/// Строка меню macOS — своими руками, средствами AppKit.
///
/// Прежде её собирал SwiftUI (`Commands`): собирать напрямую было нельзя,
/// потому что сцена переписывала `NSApp.mainMenu` при каждом обновлении.
/// Сцены больше нет — и меню теперь просто меню: пункты берутся из той же
/// описи `SlovoMenu`, что и полоса внутри окна, а сочетания клавиш из окна
/// «Параметры» (6.1.6) попадают в него сами.
///
/// Пункты пересобираются в тот миг, когда человек открыл раздел
/// (`menuNeedsUpdate`): галочки и подписи тогда не могут отстать от
/// состояния, а работы на нажатие клавиши нет вовсе — меню закрыто.
@MainActor
final class NativeAppMenu: NSObject, NSMenuDelegate {

    private let state: AppState
    private var groups: [ObjectIdentifier: NativeMenuGroup] = [:]

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// Собрать и поставить строку меню.
    func install() {
        let main = NSMenu()

        // Раздел с именем программы: у macOS он первый и обязателен, иначе
        // «Скрыть» и «Выйти» человеку взять негде.
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

        // Дальше — разделы описи, в том же порядке, что и в окне.
        for group in NativeMenuGroup.allCases {
            let item = NSMenuItem()
            let menu = NSMenu(title: caption(of: group))
            menu.delegate = self
            menu.autoenablesItems = false
            groups[ObjectIdentifier(menu)] = group
            item.title = menu.title
            item.submenu = menu
            main.addItem(item)
            // Наполняем сразу, а не только при открытии: пункты меню ищет и
            // сама система — в «Справке» по строке меню, — а самопроверка
            // сверяет по ним опись. Пустое до первого открытия меню и для
            // того, и для другого выглядит как «пунктов нет вовсе».
            menuNeedsUpdate(menu)
        }

        // «Окно» — системный раздел: свернуть, развернуть, список окон.
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

    // MARK: - Наполнение

    func menuNeedsUpdate(_ menu: NSMenu) {
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

/// Действие пункта, завёрнутое в объект: `representedObject` хранит только
/// ссылочные величины, а замыкание — величина значения.
final class MenuActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}
