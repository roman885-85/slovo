import AppKit
import Combine
import SlovoCore

/// Разделы полосы меню внутри окна — те же шесть, что у автора, и в том же
/// порядке. Подписи берутся из файла перевода формы `MainForm`.
enum NativeMenuGroup: String, CaseIterable {
    case file, actions, settings, interface, language, help

    var captionKey: String {
        switch self {
        case .file:      return "N1"
        case .actions:   return "N18"
        case .settings:  return "N13"
        case .interface: return "N39"
        case .language:  return "N14"
        case .help:      return "N4"
        }
    }

    var captionFallback: String {
        switch self {
        case .file:      return OurWords.t("Файл")
        case .actions:   return OurWords.t("Действия")
        case .settings:  return OurWords.t("Настройка")
        case .interface: return OurWords.t("Интерфейс")
        case .language:  return OurWords.t("Language/Язык")
        case .help:      return OurWords.t("Справка")
        }
    }

    var symbol: String {
        switch self {
        case .file:      return "folder"
        case .actions:   return "play.rectangle"
        case .settings:  return "gearshape"
        case .interface: return "square.grid.2x2"
        case .language:  return "globe"
        case .help:      return "questionmark.circle"
        }
    }
}

/// Пункт меню: подпись, галочка и что делать.
struct NativeMenuEntry {
    var title: String
    /// Галочка слева. У автора отмечены выбранный вид списков, «Память» и
    /// текущий язык.
    var isOn = false
    /// Горячая клавиша — та же, что была в строке меню macOS. Держим её в
    /// описи, а не в одном из двух меню: опись одна, и клавиша к пункту
    /// приписана раз и навсегда.
    var key: String?
    var modifiers: NSEvent.ModifierFlags = []
    /// Черта перед пунктом.
    var startsGroup = false
    var action: (() -> Void)?
}

/// Полоса меню внутри окна (часть `menuBar`).
///
/// Главное здесь — когда собираются пункты. Прежняя полоса на SwiftUI строила
/// все шесть разделов, три десятка пунктов и список из двух десятков языков
/// на каждую перерисовку окна, то есть на каждое нажатие; чтобы это унять, её
/// закрыли барьером `Equatable` по счётчикам правок — и дважды получили меню,
/// которое врёт о собственном состоянии: галочка вида списков оставалась на
/// прежнем месте до перезапуска, потому что счётчик про эту правку не знал.
///
/// Здесь ни того, ни другого. Пункты не существуют, пока меню закрыто, и
/// собираются в тот самый миг, когда человек его открыл (`menuNeedsUpdate`).
/// Врать им не о чем: они рождаются позже всякой правки, о которой могли бы
/// соврать. И работы на нажатие нет вовсе — меню закрыто.
///
/// За языком интерфейса полоса следит сама: шесть подписей на верхнем уровне
/// видны всегда, и их приходится держать наготове.
@MainActor
final class NativeMenuBar: NSView, NSMenuDelegate {

    private let state: AppState
    private var buttons: [NativeMenuGroup: TitleButton] = [:]
    private var menus: [NativeMenuGroup: NSMenu] = [:]
    private var tokens: [Signals.Token] = []
    private var watch: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)

        for group in NativeMenuGroup.allCases {
            let button = TitleButton(symbol: group.symbol)
            button.onPress = { [weak self] in self?.open(group) }
            addSubview(button)
            buttons[group] = button

            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            menus[group] = menu
        }

        applyTitles(state.language)

        // Язык меняют из этой же полосы, из системного меню и из окна выбора
        // языка. Слушаем само свойство, а не свои нажатия: иначе подписи
        // отстали бы при любом другом пути.
        state.$language
            .sink { [weak self] language in self?.applyTitles(language) }
            .store(in: &watch)
        // Повод `.language` шлют, когда файл перевода перечитан на месте, —
        // тогда `language` тем же и остаётся, а подписи в нём уже другие.
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self else { return }
            self.applyTitles(self.state.language)
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Раскладка и вид

    override func layout() {
        super.layout()
        // Поля слева и справа даёт сам ящик части (8 точек по описи), внутри
        // разделы идут подряд с просветом 2.
        var x: CGFloat = 0
        for group in NativeMenuGroup.allCases {
            guard let button = buttons[group] else { continue }
            let width = button.fittingWidth
            button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        NativeTopIcon.flush()
        for button in buttons.values { button.refresh() }
        needsLayout = true
    }

    private func applyTitles(_ language: LanguageFile?) {
        for group in NativeMenuGroup.allCases {
            buttons[group]?.title = NativeTopCaptions.caption(group.captionKey,
                                                              default: group.captionFallback,
                                                              in: language)
        }
        needsLayout = true
    }

    // MARK: - Открытие

    private func open(_ group: NativeMenuGroup) {
        guard let button = buttons[group], let menu = menus[group] else { return }
        button.isOpen = true
        button.displayIfNeeded()
        // Меню опускается из-под раздела, как в оригинале. `popUp` держит
        // мышь у себя до закрытия — поэтому перевод на соседний раздел
        // движением, как в системной строке, здесь не делается: перехватить
        // это движение всё равно не у кого.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
        button.isOpen = false
    }

    // MARK: - Состав пунктов

    /// Собрать раздел заново. Зовётся при открытии меню — и из самопроверки
    /// с замером.
    func rebuild(_ group: NativeMenuGroup) {
        guard let menu = menus[group] else { return }
        menu.removeAllItems()
        for entry in entries(for: group) {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key ?? "")
            item.keyEquivalentModifierMask = entry.modifiers
            item.state = entry.isOn ? .on : .off
            if let action = entry.action {
                item.target = self
                item.action = #selector(run(_:))
                item.representedObject = ActionBox(action)
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
    }

    /// Готовое меню раздела. Пока его не открывали, пунктов в нём нет вовсе.
    func menu(for group: NativeMenuGroup) -> NSMenu? { menus[group] }

    /// Подпись раздела, как она сейчас нарисована.
    func caption(of group: NativeMenuGroup) -> String { buttons[group]?.title ?? "" }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let group = menus.first(where: { $0.value === menu })?.key else { return }
        rebuild(group)
    }

    /// Обёртка вокруг замыкания: `NSMenuItem` умеет носить только объект.
    private final class ActionBox: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.body()
    }

    /// Пункты раздела. Список один на оба меню — см. `SlovoMenu`.
    func entries(for group: NativeMenuGroup) -> [NativeMenuEntry] {
        SlovoMenu.entries(for: group, state: state)
    }

    /// Снять отметку, набранную текстом.
    ///
    /// `InterfaceMenuItems` помечает выбранное знаком «✓ » впереди подписи —
    /// так пришлось делать в меню SwiftUI. У `NSMenuItem` галочка своя,
    /// настоящая: она стоит в отдельной колонке и не сдвигает текст.
    private static func unmark(_ title: String) -> (isOn: Bool, title: String) {
        if title.hasPrefix("✓ ") { return (true, String(title.dropFirst(2))) }
        if title.hasPrefix("   ") { return (false, String(title.dropFirst(3))) }
        return (false, title)
    }

    // MARK: - Заголовок раздела

    /// Значок с подписью. Рисует себя сам: `NSButton` на такой мелочи держит
    /// ячейку, слой и три прохода отрисовки там, где хватает двух вызовов.
    private final class TitleButton: NSView {

        var title = "" {
            didSet { guard title != oldValue else { return }; refresh() }
        }
        var isOpen = false { didSet { needsDisplay = true } }
        var onPress: (() -> Void)?
        private(set) var fittingWidth: CGFloat = 0

        private let symbol: String
        private var line = NSAttributedString()
        private var lineWhite = NSAttributedString()
        private var lineSize = NSSize.zero

        private let iconSize: CGFloat = 12
        private let gap: CGFloat = 4
        private let padding: CGFloat = 6

        init(symbol: String) {
            self.symbol = symbol
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        override var isFlipped: Bool { true }

        func refresh() {
            let ready = NativeTopDraw.label(title, size: 12, weight: .regular, color: .labelColor)
            line = ready.line
            // Обе краски готовятся заранее: строку меню перерисовывают в тот
            // же миг, когда открывают, — считать там нечего.
            lineWhite = NativeTopDraw.label(title, size: 12, weight: .regular, color: .white).line
            lineSize = ready.size
            fittingWidth = (padding * 2 + iconSize + gap + lineSize.width).rounded(.up)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let white = isOpen
            if white {
                NativeTopDraw.pill(bounds.insetBy(dx: 0, dy: 3), color: NativeTopDraw.selectionFill)
            }
            let color: NSColor = white ? .white : .labelColor
            let role = white ? "белый" : "обычный"

            var x = padding
            if let icon = NativeTopIcon.symbol(symbol, size: iconSize, weight: .regular,
                                               tint: color, role: role) {
                let box = NSRect(x: x, y: ((bounds.height - icon.size.height) / 2).rounded(),
                                 width: icon.size.width, height: icon.size.height)
                icon.draw(in: box)
                x += iconSize + gap
            }
            let text = white ? lineWhite : line
            text.draw(at: NSPoint(x: x, y: ((bounds.height - lineSize.height) / 2).rounded()))
        }

        override func mouseDown(with event: NSEvent) { onPress?() }
    }
}
