import AppKit
import SlovoCore

/// 6.1.2 «Дополнительные» — вкладка `TabSheet1` оригинала, на AppKit.
///
/// Время плавной смены и скрытия слайда (10) (11), дублирование слайда на
/// мониторы (12) со своими ручными настройками, маркер конца песни (13),
/// три переключателя (14) (15) (16) и номера стихов (17).
@MainActor
final class NativeSettingsAdvancedTab: NSObject, NativeListSource, NativeSettingsRows {

    /// Перечитати свій список — після скидання або ввезення налаштувань.
    func reloadRows() { list.reload() }


    private let state: AppState
    private let store: SettingsStore
    private let list = NativeTable(detailWidth: 120)
    private var fields: [NSTextField] = []
    private var selected: Int?

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
        super.init()
        list.source = self
        list.onSelect = { [weak self] _, active, _ in
            self?.selected = active
            self?.showCoordinates()
        }
        // Двойной щелчок — включить или выключить дублирование: галочки в
        // строке у нас нет, а признак этот меняют чаще всего.
        list.onActivate = { [weak self] index in self?.toggleDuplication(at: index) }
        list.onLeadClick = { [weak self] index in self?.toggleDuplication(at: index) }
    }

    var page: NSView {
        NativeForm.Page([timings, duplication, coordinates, marker, switches, verseNumbers])
    }

    // MARK: (10) (11) Времена

    private var timings: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row(state.vb("Label16", OurWords.t("Время плавной смены слайдов:")), width: 280, [
                NativeForm.number(intTie(\.crossfadeTime), range: 0...10000),
                NativeForm.label(state.vb("Label17", "мс")),
            ]),
            // Двадцать шаблонов перехода: выбор ставит и эффект, и его
            // длительность, и кривую; длительность можно поправить выше.
            NativeForm.Row(OurWords.t("Переход слайда:"), width: 280, [
                NativeForm.popup(SlideStyle.TransitionPreset.all.map { OurWords.t($0.title) },
                                 NativeForm.Tie(get: { [store] in
                                     let raw = store.settings.options.slideTransition ?? SlideStyle.Transition.fade.rawValue
                                     return SlideStyle.TransitionPreset.all.firstIndex { $0.kind.rawValue == raw } ?? 1
                                 }, set: { [store] index in
                                     let all = SlideStyle.TransitionPreset.all
                                     guard all.indices.contains(index) else { return }
                                     let preset = all[index]
                                     store.settings.options.slideTransition = preset.kind.rawValue
                                     store.settings.options.slideTransitionEasing = preset.easing.rawValue
                                     store.settings.options.crossfadeTime = Int(preset.duration * 1000)
                                 }), width: 220),
            ]),
            NativeForm.Row(OurWords.t("Кривая перехода:"), width: 280, [
                NativeForm.popup(SlideStyle.Easing.allCases.map { OurWords.t($0.title) },
                                 NativeForm.Tie(get: { [store] in
                                     let raw = store.settings.options.slideTransitionEasing ?? SlideStyle.Easing.easeInOut.rawValue
                                     return SlideStyle.Easing.allCases.firstIndex { $0.rawValue == raw } ?? 1
                                 }, set: { [store] index in
                                     let all = SlideStyle.Easing.allCases
                                     guard all.indices.contains(index) else { return }
                                     store.settings.options.slideTransitionEasing = all[index].rawValue
                                 }), width: 160),
            ]),
            NativeForm.Row(state.vb("Label18", OurWords.t("Время скрытия слайда:")), width: 280, [
                NativeForm.number(intTie(\.hideSlideTime), range: 0...10000),
                NativeForm.label(state.vb("Label19", "мс")),
            ]),
        ])
    }

    // MARK: (12) Дублирование слайда на мониторы

    private var duplication: NativeForm.Group {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 96))
        list.frame = box.bounds
        list.autoresizingMask = [.width, .height]
        box.addSubview(list)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.spacing = 4
        buttons.addArrangedSubview(NativeForm.button("+", hint: state.vbHint("PSBAddCustomMonitor",
                                                     "Добавить монитор с ручной настройкой")) {
            [weak self] in self?.addCustom()
        })
        buttons.addArrangedSubview(NativeForm.button("−", hint: state.vbHint("PSBDelCustomMonitor",
                                                     "Удалить монитор с ручной настройкой")) {
            [weak self] in self?.removeCustom()
        })
        buttons.addArrangedSubview(NativeForm.button("✎", hint: state.vbHint("PSBChangeNameCustomMonitor",
                                                     "Изменить название монитора с ручной настройкой")) {
            [weak self] in self?.rename()
        })
        // (12.5) Координаты в списке — в записи оригинала (Y вниз), поэтому
        // вспышку ставим с переворотом оси, иначе окно появится тем выше,
        // чем больше Y.
        buttons.addArrangedSubview(NativeForm.button("☀", hint: state.vbHint("PSBShowDoubleSlideWin",
                                                     "Показать позицию монитора")) {
            [weak self] in
            guard let monitor = self?.current else { return }
            SettingsMonitorFlash.show(left: monitor.x, top: monitor.y,
                                      width: monitor.width, height: monitor.height)
        })
        return NativeForm.Group(state.vb("Label30", OurWords.t("Дублирование слайда на мониторы:")),
                                [NativeForm.Row("", stretch: true, [box, buttons])])
    }

    /// (12.4) Координаты монитора. Панель работает при любом выделенном
    /// мониторе, но у настоящего координаты задаёт система — их показываем,
    /// а менять даём только у ручной настройки.
    private var coordinates: NativeForm.Group {
        fields = [
            NativeForm.number(coordinate(\.x), range: -20000...20000),
            NativeForm.number(coordinate(\.y), range: -20000...20000),
            NativeForm.number(coordinate(\.width), range: 1...20000),
            NativeForm.number(coordinate(\.height), range: 1...20000),
        ]
        return NativeForm.Group(state.vb("GB1", OurWords.t("Координаты монитора:")), [
            NativeForm.Row("", [
                NativeForm.label(state.vb("Label36", "X =")), fields[0],
                NativeForm.label(state.vb("Label37", "Y =")), fields[1],
                NativeForm.label(state.vb("Label38", "Ширина:")), fields[2],
                NativeForm.label(state.vb("Label39", "Высота:")), fields[3],
            ]),
        ])
    }

    // MARK: (13) (14) (15) (16) (17)

    private var marker: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row(state.vb("Label46", OurWords.t("Выводить в конце последней части Песни:")), width: 300, [
                NativeForm.text(NativeForm.Tie(get: { [store] in store.settings.options.songsEndMarker },
                                               set: { [store] in store.settings.options.songsEndMarker = $0 }),
                                width: 90),
            ]),
        ])
    }

    private var switches: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row("", [NativeForm.check(
                state.vb("CBFastInputUseBackSpace", "Искать по BackSpace в \"Быстр. выборе\""),
                boolTie(\.fastInputUseBackSpace),
                hint: OurWords.t("Стирание символа в поле быстрого выбора сразу повторяет поиск"))]),
            NativeForm.Row("", [NativeForm.check(
                state.vb("CBSeparatorTenVerses", "Раздел. линией по 10 стихов"),
                boolTie(\.separatorTenVerses),
                hint: state.vbHint("CBSeparatorTenVerses",
                                   "Отображает линию после каждого 10-го стиха Библии"))]),
            NativeForm.Row(state.vb("Label34", "Цвет активного поля ввода:"), width: 280, [
                NativeForm.colour(NativeForm.Tie(
                    get: { [store] in store.settings.options.activeInputFieldColor },
                    set: { [store] in store.settings.options.activeInputFieldColor = $0 })),
            ]),
        ])
    }

    private var verseNumbers: NativeForm.Group {
        NativeForm.Group(state.vb("GroupBox6", "Показывать номера стихов"), [
            NativeForm.Row("", [NativeForm.check(
                state.vb("CBShowVersNum", "Основной перевод"), boolTie(\.showVerseNumbers),
                hint: state.vbHint("CBShowVersNum",
                                   "Показывать на слайде номера стихов в Библейском тексте основного перевода"))]),
            NativeForm.Row("", [NativeForm.check(
                state.vb("CBShowExtQuoteVersNum", "Второй перевод"), boolTie(\.showSecondaryVerseNumbers),
                hint: state.vbHint("CBShowExtQuoteVersNum",
                                   "Показывать на слайде номера стихов в Библейском тексте второго перевода"))]),
            // Власник: «было бы лучше при выводе нескольких стихов каждый с
            // новой строки, и номер рядом с ним писать». Номер при цьому
            // з'являється незалежно від галочок вище: без нього рядки на
            // вигляд однакові й незрозуміло, де кінчається вірш.
            NativeForm.Row("", [NativeForm.check(
                OurWords.t("Несколько стихов — каждый с новой строки и с номером"),
                NativeForm.Tie(get: { [store] in store.settings.options.versesOnOwnLines ?? true },
                               set: { [store] in store.settings.options.versesOnOwnLines = $0 }),
                hint: OurWords.t("Иначе стихи слипаются в один абзац через пробел"))]),
        ])
    }

    // MARK: - Связки

    private func boolTie(_ path: WritableKeyPath<ProgramOptions, Bool>) -> NativeForm.Tie<Bool> {
        NativeForm.Tie(get: { [store] in store.settings.options[keyPath: path] },
                       set: { [store] value in store.settings.options[keyPath: path] = value })
    }

    private func intTie(_ path: WritableKeyPath<ProgramOptions, Int>) -> NativeForm.Tie<Int> {
        NativeForm.Tie(get: { [store] in store.settings.options[keyPath: path] },
                       set: { [store] value in store.settings.options[keyPath: path] = value })
    }

    private func coordinate(_ path: WritableKeyPath<SettingsDuplicateMonitor, Int>) -> NativeForm.Tie<Int> {
        NativeForm.Tie(get: { [weak self] in self?.current?[keyPath: path] ?? 0 },
                       set: { [weak self] value in
                           guard var monitor = self?.current, monitor.isCustom else { return }
                           monitor[keyPath: path] = value
                           self?.write(monitor)
                       })
    }

    // MARK: - Список мониторов

    /// Системные мониторы показываем всегда — их нельзя удалить, но можно
    /// пометить для дублирования; следом идут ручные настройки из конфига.
    private var monitors: [SettingsDuplicateMonitor] {
        let stored = store.settings.options.doubleMonitors.compactMap(SettingsDuplicateMonitor.init(raw:))
        var result: [SettingsDuplicateMonitor] = []
        for screen in state.projection.availableScreens {
            let name = screen.localizedName
            let saved = stored.first { $0.name == name && !$0.isCustom }
            // Координаты настоящего монитора приводим к записи оригинала: в
            // ключе `DoubleMonitors` и в панели (12.4) ось Y идёт сверху вниз,
            // и держать в одном списке две системы координат нельзя.
            let point = SettingsCoordinates.original(screen.frame)
            result.append(SettingsDuplicateMonitor(name: name, x: point.left, y: point.top,
                                                   width: point.width, height: point.height,
                                                   isEnabled: saved?.isEnabled ?? false, isCustom: false))
        }
        result.append(contentsOf: stored.filter(\.isCustom))
        return result
    }

    private var current: SettingsDuplicateMonitor? {
        guard let index = selected, monitors.indices.contains(index) else { return nil }
        return monitors[index]
    }

    private func write(_ monitor: SettingsDuplicateMonitor) {
        var stored = store.settings.options.doubleMonitors.compactMap(SettingsDuplicateMonitor.init(raw:))
        if let index = stored.firstIndex(where: { $0.id == monitor.id }) {
            stored[index] = monitor
        } else {
            stored.append(monitor)
        }
        store.settings.options.doubleMonitors = stored.map(\.raw)
        list.reload()
    }

    private func toggleDuplication(at index: Int) {
        guard monitors.indices.contains(index) else { return }
        var monitor = monitors[index]
        monitor.isEnabled.toggle()
        write(monitor)
    }

    private func addCustom() {
        var index = 1
        var name = state.vb("TextMessages25", "Ручная настройка")
        let taken = Set(monitors.map(\.name))
        while taken.contains(name) {
            index += 1
            name = state.vb("TextMessages25", "Ручная настройка") + " \(index)"
        }
        write(SettingsDuplicateMonitor(name: name, x: 0, y: 0,
                                       width: store.settings.options.defaultWidth,
                                       height: store.settings.options.defaultHeight,
                                       isEnabled: false, isCustom: true))
        selected = monitors.count - 1
        list.setSelection(IndexSet(integer: monitors.count - 1), active: monitors.count - 1)
        showCoordinates()
    }

    private func removeCustom() {
        guard let monitor = current, monitor.isCustom else { return }
        store.settings.options.doubleMonitors = store.settings.options.doubleMonitors
            .compactMap(SettingsDuplicateMonitor.init(raw:))
            .filter { $0.id != monitor.id }
            .map(\.raw)
        selected = nil
        list.reload()
        showCoordinates()
    }

    /// TextMessages36 «Название монитора.» / TextMessages37 «Введите новое
    /// название монитора.»
    private func rename() {
        guard let monitor = current, monitor.isCustom else { return }
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages36", "Название монитора.")
        alert.informativeText = state.vb("TextMessages37", "Введите новое название монитора.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = monitor.name
        alert.accessoryView = field
        alert.addButton(withTitle: state.vb("BBOk", "Ок"))
        alert.addButton(withTitle: state.vb("BBCancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Имя — это признак строки, поэтому старую запись сначала убираем,
        // иначе в списке окажутся обе.
        store.settings.options.doubleMonitors = store.settings.options.doubleMonitors
            .compactMap(SettingsDuplicateMonitor.init(raw:))
            .filter { $0.id != monitor.id }
            .map(\.raw)
        var copy = monitor
        copy.name = field.stringValue.isEmpty ? monitor.name : field.stringValue
        write(copy)
    }

    private func showCoordinates() {
        let monitor = current
        let values = [monitor?.x ?? 0, monitor?.y ?? 0, monitor?.width ?? 0, monitor?.height ?? 0]
        for (field, value) in zip(fields, values) {
            field.stringValue = "\(value)"
            field.isEnabled = monitor?.isCustom ?? false
        }
    }

    // MARK: - Строки

    var rowCount: Int { monitors.count }

    func row(at index: Int) -> NativeRow {
        let monitor = monitors[index]
        var row = NativeRow()
        row.lead = monitor.isEnabled ? "☑" : "☐"
        row.text = monitor.name
        row.detail = "\(monitor.width) x \(monitor.height)"
        return row
    }
}
