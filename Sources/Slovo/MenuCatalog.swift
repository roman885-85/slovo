import AppKit
import SlovoCore

/// Опись меню — один список на оба места, где меню показывают.
///
/// Пока список жил внутри оконной полосы, системная строка macOS набиралась
/// отдельно и своими словами: часть пунктов туда так и не попала, и человек
/// не находил их в привычном месте. Теперь список один; кто его показывает —
/// дело десятое.
@MainActor
enum SlovoMenu {

    /// Пункт с сочетанием из окна «Параметры» (6.1.6).
    ///
    /// Зашитая клавиша осталась запасной: пока `hotkeys.ini` не прочитан,
    /// меню обязано работать привычными сочетаниями.
    private static func menu(_ title: String, _ action: String,
                             _ fallback: String,
                             _ fallbackModifiers: NSEvent.ModifierFlags = [],
                             startsGroup: Bool = false,
                             action body: @escaping () -> Void) -> NativeMenuEntry {
        let (key, modifiers) = Keys.assigned(action, fallback: fallback,
                                             fallbackModifiers: fallbackModifiers)
        return NativeMenuEntry(title: title, key: key, modifiers: modifiers,
                               startsGroup: startsGroup, action: body)
    }

    /// Пункты раздела. Состав снят с описи окна: те же ключи подписей и тот
    /// же порядок, что и у автора.
    static func entries(for group: NativeMenuGroup, state: AppState) -> [NativeMenuEntry] {
        let actions = state.menuActions
        let language = state.language
        func caption(_ key: String, _ fallback: String) -> String {
            NativeTopCaptions.caption(key, default: fallback, in: language)
        }

        switch group {
        case .file:
            return [
                NativeMenuEntry(title: OurWords.t("Импорт модулей, шаблонов и фонов…"),
                                action: { ImportWizardWindow.show(state: state) }),
                NativeMenuEntry(title: OurWords.t("Перечитать настройки"),
                                action: { actions.rereadSettings() }),
                NativeMenuEntry(title: OurWords.t("Выбрать папку с модулями…"),
                                key: "o", modifiers: .command,
                                action: { actions.chooseModules() }),
            ]

        case .actions:
            return [
                menu(caption("N24", "Показать слайд"), "ShowSlide",
                     Keys.function(5), action: { actions.showSlide() }),
                menu(caption("N25", "Скрыть слайд"), "HideSlide",
                     Keys.hideSlide, action: { actions.hideSlide() }),
                menu(caption("N35", "Показать пустой слайд"), "ShowBlankSlide",
                     Keys.function(5), .control, action: { actions.blankSlide() }),
                menu(caption("N34", "Показать/скрыть затемнение экрана"), "ShowBlackScreen",
                     Keys.function(12), action: { actions.blackScreen() }),
                menu(caption("N30", "Отображать Общий фон (Вкл/Выкл)"), "ShowBackGrOnSlide",
                     Keys.function(9), .control,
                     startsGroup: true, action: { actions.toggleBackground() }),
                menu(caption("N28", "Сделать снимок экрана слайда"), "ScreenShot",
                     Keys.function(11), action: { actions.screenshot() }),
                // Медиаплеер и результаты поиска меняют саму раскладку окна:
                // без повода `.layout` полосы останутся спрятанными.
                NativeMenuEntry(title: OurWords.t("Медиаплеер"), isOn: state.isMediaOpen,
                                startsGroup: true, action: {
                    state.isMediaOpen.toggle()
                    Signals.shared.send(.layout)
                }),
                menu(caption("N22", "Установить фокус на Стихи/Текст"), "MainWin",
                     Keys.function(6), startsGroup: true,
                     action: { actions.focusVerses() }),
                NativeMenuEntry(title: caption("N19", "Установить фокус на План"),
                                action: { DeskModel.shared.focusPlan() }),
                NativeMenuEntry(title: caption("N20", "Поиск"),
                                startsGroup: true,
                                action: { DeskModel.shared.focusSearchField() }),
                NativeMenuEntry(title: caption("N29", "Показать/скрыть результаты поиска"),
                                isOn: DeskModel.shared.isSearchResultsShown,
                                action: {
                                    DeskModel.shared.toggleSearchResults()
                                    Signals.shared.send(.layout)
                                }),
                NativeMenuEntry(title: caption("N21", "Быстрый выбор"),
                                action: { DeskModel.shared.focusAddressField() }),
                NativeMenuEntry(title: caption("N31", "Быстрый выбор Книги/Песни вводом её названия"),
                                action: { DeskModel.shared.focusQuickField(.book) }),
                NativeMenuEntry(title: caption("N32", "Быстрый выбор Главы вводом её номера"),
                                action: { DeskModel.shared.focusQuickField(.chapter) }),
                NativeMenuEntry(title: caption("N33", "Быстрый выбор Стиха/Текста вводом части текста"),
                                action: { DeskModel.shared.focusQuickField(.verse) }),
                NativeMenuEntry(title: OurWords.t("Следующий стих"), key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command,
                                startsGroup: true, action: { state.stepVerse(by: 1) }),
                NativeMenuEntry(title: OurWords.t("Предыдущий стих"), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: .command,
                                action: { state.stepVerse(by: -1) }),
                NativeMenuEntry(title: OurWords.t("Следующая глава"), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .command,
                                action: { state.stepChapter(by: 1) }),
                NativeMenuEntry(title: OurWords.t("Предыдущая глава"), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: .command,
                                action: { state.stepChapter(by: -1) }),
            ]

        case .settings:
            return [
                // За этими четырьмя пунктами стоят отдельные окна. Их не
                // трогаем вовсе: доли секунды в них не важны, а переписывать
                // работающее — терять чужой труд.
                NativeMenuEntry(title: OurWords.t("Настройки…"), key: ",", modifiers: .command,
                                action: { NativeSettingsSheet.open() }),
                // Власник: «нужно, чтобы в основной программе были подсказки
                // по запуску с браузера». Пункт стоїть і тут, поруч із
                // налаштуваннями, і в «Помощи» — де людина його шукатиме.
                NativeMenuEntry(title: OurWords.t("Пульт в браузере…"),
                                action: { NativeBrowserRemoteWindow.show(state: state) }),
                NativeMenuEntry(title: OurWords.t("Программы для Android…"),
                                action: { NativeAndroidAppsWindow.show() }),
                NativeMenuEntry(title: caption("N42", "Конструктор слайда"),
                                action: { SlideConstructorWindow.show(state: state) }),
                NativeMenuEntry(title: OurWords.t("Редактор веб-слайдов…"),
                                action: { WebSlideEditorWindow.show(state: state) }),
                NativeMenuEntry(title: caption("N40", "Редактор несоответствий нумерации переводов Библии"),
                                action: { NumberingEditorWindow.show(state: state) }),
            ]

        case .interface:
            // Состав берём у `InterfaceMenuItems` — того же, что кормит
            // системную строку macOS. Порознь они разошлись бы составом, и
            // одно и то же меню показывало бы разное в двух местах окна.
            return InterfaceMenuItems.interface(state: state).map { item in
                let (isOn, title) = unmark(item.title)
                return NativeMenuEntry(title: title, isOn: isOn, action: {
                    // Повод шлём, только если вид списков и правда сменился:
                    // в этом же разделе стоят пункты, которые просто
                    // открывают окно, и заставлять из-за них перечитываться
                    // все списки окна незачем.
                    let before = InterfaceSettings.shared.revision
                    item.action()
                    if InterfaceSettings.shared.revision != before {
                        Signals.shared.send(.listKind)
                    }
                })
            }

        case .language:
            return InterfaceMenuItems.language(state: state).map { item in
                let (isOn, title) = unmark(item.title)
                return NativeMenuEntry(title: title, isOn: isOn, action: {
                    let before = state.languageCode
                    item.action()
                    if state.languageCode != before { Signals.shared.send(.language) }
                })
            }

        case .help:
            return [
                NativeMenuEntry(title: caption("N6", "Помощь"), action: { actions.openHelp() }),
                NativeMenuEntry(title: OurWords.t("Пульт в браузере…"),
                                action: { NativeBrowserRemoteWindow.show(state: state) }),
                NativeMenuEntry(title: OurWords.t("Программы для Android…"),
                                action: { NativeAndroidAppsWindow.show() }),
                NativeMenuEntry(title: OurWords.t("Диагностика…"), action: { actions.showDiagnostics() }),
                NativeMenuEntry(title: caption("N5", "О программе..."), action: { actions.about() }),
            ]
        }
    }


    /// Снять отметку, набранную текстом: `InterfaceMenuItems` помечает
    /// выбранное знаком «✓ » впереди подписи.
    static func unmark(_ title: String) -> (isOn: Bool, title: String) {
        if title.hasPrefix("✓ ") { return (true, String(title.dropFirst(2))) }
        if title.hasPrefix("   ") { return (false, String(title.dropFirst(3))) }
        return (false, title)
    }
}
