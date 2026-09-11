import AppKit
import SlovoCore

/// 6.1.3 «Слайд» — вкладка `TSSlide` на AppKit.
///
/// Здесь только то, что попадает на слайд подписью: вид адреса места Писания
/// (18) (19) и вид номера песни в её названии (20). Оформление текста задаёт
/// конструктор слайда, а не эта вкладка.
///
/// Примеры под каждой группой пересчитываются на месте: человек меняет вид
/// адреса и тут же видит, как он будет выглядеть в зале.
@MainActor
final class NativeSettingsSlideTab {

    private let state: AppState
    private let store: SettingsStore
    private let combined = NativeForm.label("", secondary: false)
    private let mainOnly = NativeForm.label("", secondary: false)
    private let secondOnly = NativeForm.label("", secondary: false)
    private let songLine = NativeForm.label("", secondary: false)

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        let view = NativeForm.Page([transitions, showTransitions, address, addressExample,
                                    songName, songExample, pointer])
        refresh()
        return view
    }

    // MARK: Указка (своя)

    /// Пятно, которым показывают место на слайде: мышью по зеркалу проектора
    /// или пальцем с телефона. Владелец просил цвет, размер, яркость и выбор
    /// выводов — сюда они и легли, на вкладку «Слайд».
    private var pointer: NativeForm.Group {
        let store = store
        let fallback = SlidePointer.Look()
        return NativeForm.Group(OurWords.t("Указка"), [
            NativeForm.Row(OurWords.t("Цвет:"), width: 120, [
                NativeForm.colour(NativeForm.Tie(
                    get: { SlidePointer.Look.colour(fromHex: store.settings.options.pointerColour ?? "") ?? fallback.colour },
                    set: { value in store.settings.options.pointerColour = SlidePointer.Look.hex(value) })),
            ]),
            NativeForm.Row(OurWords.t("Размер (% высоты):"), width: 120, [
                NativeForm.slider(NativeForm.Tie(
                    get: { (store.settings.options.pointerSize ?? fallback.size) * 100 },
                    set: { value in store.settings.options.pointerSize = value / 100 }),
                                  range: 3...60, format: { String(Int($0.rounded())) }, width: 160),
            ]),
            NativeForm.Row(OurWords.t("Яркость (%):"), width: 120, [
                NativeForm.slider(NativeForm.Tie(
                    get: { (store.settings.options.pointerOpacity ?? fallback.opacity) * 100 },
                    set: { value in store.settings.options.pointerOpacity = value / 100 }),
                                  range: 5...100, format: { String(Int($0.rounded())) }, width: 160),
            ]),
            NativeForm.Row(OurWords.t("Выводить:"), width: 120, [
                NativeForm.check(OurWords.t("на проектор"), NativeForm.Tie(
                    get: { store.settings.options.pointerProjector ?? true },
                    set: { value in store.settings.options.pointerProjector = value })),
                NativeForm.check(OurWords.t("в NDI"), NativeForm.Tie(
                    get: { store.settings.options.pointerNDI ?? true },
                    set: { value in store.settings.options.pointerNDI = value })),
            ]),
            NativeForm.Row("", stretch: true, [
                NativeForm.label(OurWords.t("Указку ведут мышью по зеркалу проектора в нижнем ряду или пальцем по слайду на телефоне.")),
            ]),
        ])
    }

    // MARK: (18) (19) Адрес места Писания

    /// Эффект смены слайда: двадцать шаблонов, кривая и длительность.
    /// Владелец искал их здесь, на вкладке «Слайд», а не в «Дополнительных».
    private var transitions: NativeForm.Group {
        NativeForm.Group(OurWords.t("Эффект смены слайда"), [
            NativeForm.Row(OurWords.t("Переход слайда:"), width: 200, [
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
            NativeForm.Row(OurWords.t("Кривая перехода:"), width: 200, [
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
            NativeForm.Row(state.vb("Label16", "Время плавной смены слайдов:"), width: 200, [
                NativeForm.number(NativeForm.Tie(get: { [store] in store.settings.options.crossfadeTime },
                                                 set: { [store] in store.settings.options.crossfadeTime = $0 }),
                                  range: 0...10000),
                NativeForm.label(state.vb("Label17", "мс")),
            ]),
        ])
    }

    /// Той самий вибір, але для сторінок показу і зображень.
    ///
    /// Власник: «Пункт презентация — добавить эффекты затуханий, наплывов и
    /// другие 20 с настройками». Окремо від слайда навмисно: вірші міняють
    /// щохвилини, і швидкий перехід там доречний, а сторінки показу гортають
    /// рідко — там краще виглядає повільне розчинення. На одному числі
    /// тримати їх не можна: людина не змогла б мати обидва.
    private var showTransitions: NativeForm.Group {
        NativeForm.Group(OurWords.t("Эффект смены страницы показа и картинки"), [
            NativeForm.Row(OurWords.t("Переход:"), width: 200, [
                NativeForm.popup(SlideStyle.TransitionPreset.all.map { OurWords.t($0.title) },
                                 NativeForm.Tie(get: { [store] in
                                     let raw = store.settings.options.showTransition ?? SlideStyle.Transition.fade.rawValue
                                     return SlideStyle.TransitionPreset.all.firstIndex { $0.kind.rawValue == raw } ?? 1
                                 }, set: { [store] index in
                                     let all = SlideStyle.TransitionPreset.all
                                     guard all.indices.contains(index) else { return }
                                     let preset = all[index]
                                     store.settings.options.showTransition = preset.kind.rawValue
                                     store.settings.options.showTransitionEasing = preset.easing.rawValue
                                     store.settings.options.showTransitionTime = Int(preset.duration * 1000)
                                 }), width: 220),
            ]),
            NativeForm.Row(OurWords.t("Кривая перехода:"), width: 200, [
                NativeForm.popup(SlideStyle.Easing.allCases.map { OurWords.t($0.title) },
                                 NativeForm.Tie(get: { [store] in
                                     let raw = store.settings.options.showTransitionEasing ?? SlideStyle.Easing.easeInOut.rawValue
                                     return SlideStyle.Easing.allCases.firstIndex { $0.rawValue == raw } ?? 1
                                 }, set: { [store] index in
                                     let all = SlideStyle.Easing.allCases
                                     guard all.indices.contains(index) else { return }
                                     store.settings.options.showTransitionEasing = all[index].rawValue
                                 }), width: 160),
            ]),
            NativeForm.Row(OurWords.t("Время смены:"), width: 200, [
                NativeForm.number(NativeForm.Tie(get: { [store] in store.settings.options.showTransitionTime ?? 350 },
                                                 set: { [store] in store.settings.options.showTransitionTime = $0 }),
                                  range: 0...10000),
                NativeForm.label(state.vb("Label17", "мс")),
            ]),
            NativeForm.Row("", [
                NativeForm.label(OurWords.t("Действует на страницы показа, фотографии и захваченный экран. "
                    + "На приближение точкой фокуса не действует: лупа должна ехать за рукой, а не растворяться."),
                    secondary: true),
            ]),
        ])
    }

    private var address: NativeForm.Group {
        NativeForm.Group(state.vb("GBBibleAddress", "Адрес места Писания:"), [
            NativeForm.Row(state.vb("GBAll", "Объединенный:") + " "
                           + state.vb("LRefAllMain", "Основной перевод:"), width: 260,
                           [style(\.refAllMain)]),
            NativeForm.Row(state.vb("GBAll", "Объединенный:") + " "
                           + state.vb("LRefAllSec", "Второй перевод:"), width: 260,
                           [style(\.refAllSec)]),
            NativeForm.Row(state.vb("GBSep", "Отдельный") + " "
                           + state.vb("LRefMain", "Основной перевод:"), width: 260,
                           [style(\.refMain)]),
            NativeForm.Row(state.vb("GBSep", "Отдельный") + " "
                           + state.vb("LRefSec", "Второй перевод:"), width: 260,
                           [style(\.refSec)]),
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBRefsSeparated", "Пробел между адресами"),
                                 tie(\.refsSeparated)),
            ]),
        ])
    }

    /// Длинный или короткий — два положения, как у автора.
    private func style(_ path: WritableKeyPath<ProgramOptions, ProgramOptions.AddressStyle>) -> NSView {
        NativeForm.popup([state.vb("TextMessages39", "Длинный"),
                          state.vb("TextMessages40", "Короткий")],
                         NativeForm.Tie(get: { [store] in
                             store.settings.options[keyPath: path] == .long ? 0 : 1
                         }, set: { [store, weak self] value in
                             store.settings.options[keyPath: path] = value == 0 ? .long : .short
                             self?.refresh()
                         }), width: 140)
    }

    // MARK: (21) (22) Пример адреса

    private var addressExample: NativeForm.Group {
        NativeForm.Group(state.vb("GBBibleAddressExamp", "Пример адреса:"), [
            NativeForm.Row(state.vb("LRefExamplAll", "Объединенный:"), width: 180, [combined]),
            NativeForm.Row(state.vb("LRefExamplMain", "Основной перевод:"), width: 180, [mainOnly]),
            NativeForm.Row(state.vb("LRefExamplSec", "Второй перевод:"), width: 180, [secondOnly]),
        ])
    }

    // MARK: (20) Название песни

    private var songName: NativeForm.Group {
        NativeForm.Group(state.vb("GBSongName", "Название песни:"), [
            // Запасные подписи — формулировки автора из SettingsForm, а не
            // свои: без установленного VisioBible видны именно они.
            NativeForm.Row("", [NativeForm.check(state.vb("CBNumPP", "Номер по порядку"),
                                                 tie(\.songNumberPP))]),
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBNumInCollect", "Номер в сборнике"),
                                 tie(\.songNumberInCollection)),
                NativeForm.check(state.vb("CBNumInCollectInBrackets", "(Всегда в скобках)"),
                                 tie(\.songNumberInBrackets)),
            ]),
            NativeForm.Row("", [NativeForm.check(state.vb("CBDotAfterNum", "Точка после номера"),
                                                 tie(\.songDotAfterNumber))]),
        ])
    }

    private var songExample: NativeForm.Group {
        NativeForm.Group(state.vb("GroupBox7", "Пример названия песни:"),
                         [NativeForm.Row("", [songLine])])
    }

    // MARK: - Связки и примеры

    private func tie(_ path: WritableKeyPath<ProgramOptions, Bool>) -> NativeForm.Tie<Bool> {
        NativeForm.Tie(get: { [store] in store.settings.options[keyPath: path] },
                       set: { [store, weak self] value in
                           store.settings.options[keyPath: path] = value
                           self?.refresh()
                       })
    }

    /// Названия книг для примера берём из сообщений автора: TextMessages41…44
    /// — «Бытие», «Genesis», «Быт.», «Gen.». Свои примеры тут были бы чужими.
    private func refresh() {
        let option = store.settings.options
        func main(_ style: ProgramOptions.AddressStyle) -> String {
            style == .long ? state.vb("TextMessages41", "Бытие") : state.vb("TextMessages43", "Быт.")
        }
        func second(_ style: ProgramOptions.AddressStyle) -> String {
            style == .long ? state.vb("TextMessages42", "Genesis") : state.vb("TextMessages44", "Gen.")
        }
        let space = option.refsSeparated ? " " : ""
        combined.stringValue = "\(main(option.refAllMain))\(space)(\(second(option.refAllSec))) 1:1"
        mainOnly.stringValue = "\(main(option.refMain)) 1:1"
        secondOnly.stringValue = "\(second(option.refSec)) 1:1"

        var parts: [String] = []
        if option.songNumberPP { parts.append("1") }
        if option.songNumberInCollection { parts.append(option.songNumberInBrackets ? "(1)" : "1") }
        var head = parts.joined(separator: " ")
        if !head.isEmpty, option.songDotAfterNumber { head += "." }
        let name = state.vb("TextMessages45", "Бог велик")
        songLine.stringValue = head.isEmpty ? name : head + " " + name
    }
}
