import AppKit
import SlovoCore

/// 6.1.1 «Основні» на AppKit.
///
/// Порядок і склад — як на вкладці `TSBasic` оригіналу: реакція на кнопки,
/// вибір монітора для слайда зі схемою розташування, розміри за умовчанням,
/// що виносити на передній план, відсоток заповнення сторінки й частота
/// анімації.
///
/// Вікно проєкції звідси не чіпаємо. Раніше вибір зі списку одразу рухав
/// слайд, і «Скасувати» його вже не повертало: у файлі лишалося старе
/// значення, а слайд висів на новому моніторі. Значення доїжджає до вікна
/// слайда через `AppState.applyProgramOptions`, тобто за «Ок».
@MainActor
final class NativeSettingsBasicTab {

    private let state: AppState
    private let store: SettingsStore
    private let connection = NativeForm.label("")
    private let placement = NativeForm.label("", secondary: false)
    private let map = MonitorMap()
    private var manualFields: [NSTextField] = []

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        let view = NativeForm.Page([buttonAction, monitor, sizes, foreground, pageAndAnimation])
        refresh()
        return view
    }

    private var screens: [NSScreen] { state.projection.availableScreens }

    // MARK: (1) Реакція на кнопки

    private var buttonAction: NativeForm.Group {
        NativeForm.Group(state.vb("RGButAction", "Реакция на кнопки:"), [
            NativeForm.Row("", [
                NativeForm.choice([state.vb("RGButAction->Item0", "По нажатию"),
                                   state.vb("RGButAction->Item1", "По отпусканию")],
                                  NativeForm.Tie(get: { [store] in
                                      store.settings.options.buttonAction == .onPress ? 0 : 1
                                  }, set: { [store] value in
                                      store.settings.options.buttonAction = value == 0 ? .onPress : .onRelease
                                  })),
            ]),
        ])
    }

    // MARK: (5)…(9) Монітор для відображення слайда

    private var monitor: NativeForm.Group {
        // Нульовий пункт — «Ручная настройка»: в оригіналі це єдиний
        // спосіб вивести слайд туди, де монітора зараз немає, але він з'явиться
        // до служіння.
        let titles = [state.vb("TextMessages25", "Ручная настройка")] + screens.map(\.slovoTitle)
        manualFields = [
            NativeForm.number(intTie(\.customLeft), range: -20000...20000, width: 70),
            NativeForm.number(intTie(\.customTop), range: -20000...20000, width: 70),
            NativeForm.number(intTie(\.customWidth), range: 1...20000, width: 70),
            NativeForm.number(intTie(\.customHeight), range: 1...20000, width: 70),
        ]
        map.screens = screens
        map.selected = store.settings.options.monitorIndex - 1

        let mapBox = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
        map.frame = mapBox.bounds
        map.autoresizingMask = [.width, .height]
        mapBox.addSubview(map)
        mapBox.translatesAutoresizingMaskIntoConstraints = false
        mapBox.heightAnchor.constraint(equalToConstant: 96).isActive = true
        mapBox.widthAnchor.constraint(equalToConstant: 480).isActive = true

        return NativeForm.Group(state.vb("GroupBox1", "Монитор для отображения слайда:"), [
            NativeForm.Row(state.vb("Label3", "Монитор:"), width: 110, [
                NativeForm.popup(titles, NativeForm.Tie(get: { [store] in store.settings.options.monitorIndex },
                                                        set: { [store, weak self] value in
                                                            store.settings.options.monitorIndex = value
                                                            self?.refresh()
                                                        }), width: 320),
                connection,
                NativeForm.button("☀", hint: state.vbHint("PSBMainSlideWin", "Показать позицию дисплея")) {
                    [weak self] in self?.flash()
                },
            ]),
            // (9) Панель ручних налаштувань: слайд виводиться за цими координатами,
            // навіть коли монітора з таким номером немає.
            NativeForm.Row(state.vb("Label40", "Левый:") + " / " + state.vb("Label42", "Верх:")
                           + " / " + state.vb("Label41", "Ширина:") + " / " + state.vb("Label43", "Высота:"),
                           width: 300, manualFields),
            NativeForm.Row(state.vb("Label4", "Расположение:") + " / " + state.vb("Label5", "Размер:"),
                           width: 300, [placement]),
            NativeForm.Row("", [mapBox]),
        ])
    }

    // MARK: (7) Розміри за умовчанням, (2) На передній план

    private var sizes: NativeForm.Group {
        NativeForm.Group(state.vb("GroupBox2", "Размеры по умолчанию"), [
            NativeForm.Row(state.vb("Label7", "Ширина:"), width: 110,
                           [NativeForm.number(intTie(\.defaultWidth), range: 1...20000)]),
            NativeForm.Row(state.vb("Label8", "Высота:"), width: 110,
                           [NativeForm.number(intTie(\.defaultHeight), range: 1...20000)]),
        ])
    }

    private var foreground: NativeForm.Group {
        NativeForm.Group(state.vb("Label9", "При показе слайда") + " "
                         + state.vb("RGForeground", "на передний план"), [
            NativeForm.Row("", [
                NativeForm.choice([state.vb("RGForeground->Item0", "Главное окно"),
                                   state.vb("RGForeground->Item1", "Окно слайда")],
                                  NativeForm.Tie(get: { [store] in
                                      store.settings.options.foreground == .mainWindow ? 0 : 1
                                  }, set: { [store] value in
                                      store.settings.options.foreground = value == 0 ? .mainWindow : .slideWindow
                                  })),
            ]),
        ])
    }

    // MARK: (3) і (4)

    private var pageAndAnimation: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row(state.vb("Label6", "Минимальный процент заполнения для создания новой страницы:"),
                           width: 340, [
                NativeForm.number(intTie(\.percentFillingPage), range: 0...100, width: 56),
                NativeForm.label(state.vb("Label10", "%")),
            ]),
            NativeForm.Row(state.vb("Label11", "Частота обновления анимации:"), width: 340, [
                NativeForm.number(intTie(\.animationFrequency), range: 1...240, width: 56),
                NativeForm.label(state.vb("Label12", "Герц")),
            ]),
        ])
    }

    // MARK: -

    private func intTie(_ path: WritableKeyPath<ProgramOptions, Int>) -> NativeForm.Tie<Int> {
        NativeForm.Tie(get: { [store] in store.settings.options[keyPath: path] },
                       set: { [store, weak self] value in
                           store.settings.options[keyPath: path] = value
                           self?.refresh()
                       })
    }

    private var selectedScreen: NSScreen? {
        let index = store.settings.options.monitorIndex - 1
        return screens.indices.contains(index) ? screens[index] : nil
    }

    private func refresh() {
        let manual = store.settings.options.monitorIndex == 0
        for field in manualFields { field.isEnabled = manual }

        if manual {
            connection.stringValue = state.vb("TextMessages25", "Ручная настройка")
            connection.textColor = .secondaryLabelColor
        } else if let screen = selectedScreen {
            connection.stringValue = screen == NSScreen.main
                ? state.vb("TextMessages2", "Основной")
                : state.vb("TextMessages3", "Не основной")
            connection.textColor = .secondaryLabelColor
        } else {
            connection.stringValue = state.vb("TextMessages26", "Не подключен")
            connection.textColor = .systemOrange
        }

        // Координати показуємо так само, як оригінал: зсув верхнього
        // лівого кута монітора від кута головного, вісь Y донизу.
        if let frame = selectedScreen?.frame {
            let point = SettingsCoordinates.original(frame)
            placement.stringValue = "\(point.left), \(point.top)   "
                + "\(Int(frame.width)) x \(Int(frame.height))"
        } else {
            placement.stringValue = "\(store.settings.options.customLeft), "
                + "\(store.settings.options.customTop)   "
                + "\(store.settings.options.defaultWidth) x \(store.settings.options.defaultHeight)"
        }
        map.selected = store.settings.options.monitorIndex - 1
        map.needsDisplay = true
    }

    private func flash() {
        if let frame = selectedScreen?.frame {
            let point = SettingsCoordinates.original(frame)
            SettingsMonitorFlash.show(left: point.left, top: point.top,
                                      width: point.width, height: point.height)
        } else {
            SettingsMonitorFlash.show(left: store.settings.options.customLeft,
                                      top: store.settings.options.customTop,
                                      width: store.settings.options.customWidth,
                                      height: store.settings.options.customHeight)
        }
    }

    /// (6) Схема розташування моніторів: прямокутники в масштабі, у кожного
    /// координати й розмір — рівно те, що малює оригінал.
    final class MonitorMap: NSView {
        var screens: [NSScreen] = []
        var selected = -1

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            // Фарбуємо тільки свою площу: `dirtyRect` буває більшим за вид, і
            // заливка по ньому стирає намальоване сусідами.
            NSColor.clear.setFill()
            bounds.fill()
            let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
            guard union.width > 0, union.height > 0 else { return }
            let scale = min(bounds.width / union.width, bounds.height / union.height) * 0.92
            let offsetX = (bounds.width - union.width * scale) / 2
            let offsetY = (bounds.height - union.height * scale) / 2

            for (index, screen) in screens.enumerated() {
                let frame = screen.frame
                // Екрани в AppKit рахуються знизу вгору, а малюємо згори донизу
                // — інакше схема виявиться дзеркальною по вертикалі.
                let rect = NSRect(x: (frame.minX - union.minX) * scale + offsetX,
                                  y: (union.maxY - frame.maxY) * scale + offsetY,
                                  width: max(frame.width * scale, 1),
                                  height: max(frame.height * scale, 1))
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                (index == selected ? NSColor.controlAccentColor.withAlphaComponent(0.3)
                                   : NSColor.gray.withAlphaComponent(0.15)).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()

                // Підписи — у координатах оригіналу (Y донизу), як і поле
                // «Расположение» поруч.
                let point = SettingsCoordinates.original(frame)
                let lines = ["\(index + 1)", "\(point.left), \(point.top)",
                             "\(Int(frame.width)) x \(Int(frame.height))"]
                var top = rect.midY - 20
                for (line, size) in zip(lines, [11.0, 8.0, 8.0] as [CGFloat]) {
                    let text = NSAttributedString(string: line, attributes: [
                        .font: NSFont.systemFont(ofSize: size,
                                                 weight: size > 9 ? .bold : .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    let width = text.size().width
                    text.draw(at: NSPoint(x: rect.midX - width / 2, y: top))
                    top += size + 3
                }
            }
        }
    }
}
