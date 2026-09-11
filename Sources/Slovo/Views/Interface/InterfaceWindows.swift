import AppKit
import SlovoCore

/// Окна раздела 7: «Перевод интерфейса» (7.1), «Стиль интерфейса программы»
/// (7.2) и «Выбор языка» (7.3).
///
/// Все три сделаны отдельными окнами `NSWindow`, а не листами поверх главного:
/// в оригинале это самостоятельные окна, и перекрывать ими главное окно во
/// время служения нельзя — оператор должен видеть текст и продолжать листать.
/// `isReleasedWhenClosed = false` держит окно и его правку между открытиями.
@MainActor
enum InterfaceWindows {

    // MARK: - 7.1 Перевод интерфейса

    private static var translateController: NSWindowController?
    private static var translateDelegate: TranslateWindowDelegate?
    private static var translateModel: LocalizeTranslateModel?

    static func showTranslate(state: AppState) {
        if let window = translateController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let originals = languageDirectory(state: state)
        let model = LocalizeTranslateModel(originals: originals,
                                           startingCode: state.language?.code ?? "ru")
        translateModel = model

        let window = makeWindow(width: 1180, height: 820,
                                title: state.text("LocalizeTranslateForm",
                                                  form: "LocalizeTranslateForm",
                                                  default: "Перевод языка интерфейса"),
                                autosave: "LocalizeTranslateWindow")
        window.minSize = NSSize(width: 1060, height: 700)

        window.contentView = NativeLocalizeView(state: state, model: model) { [weak window] in
            window?.performClose(nil)
        }

        let delegate = TranslateWindowDelegate(model: model, state: state)
        translateDelegate = delegate
        window.delegate = delegate

        let controller = NSWindowController(window: window)
        translateController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 7.2 Стиль интерфейса программы

    private static var styleController: NSWindowController?

    static func showStyle(state: AppState) {
        if let window = styleController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(width: 460, height: 430,
                                title: OurWords.t("Стиль интерфейса программы"),
                                autosave: "InterfaceStyleWindow")
        window.contentView = NativeInterfaceStyleView(state: state) { [weak window] in
            window?.performClose(nil)
        }

        let controller = NSWindowController(window: window)
        styleController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 7.3 Выбор языка

    private static var languageController: NSWindowController?

    static func showLanguagePicker(state: AppState) {
        if let window = languageController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(width: 340, height: 460,
                                title: state.text("N14", default: "Language/Язык"),
                                autosave: "SelectLangWindow")
        window.contentView = NativeSelectLangView(state: state,
                                                  originals: languageDirectory(state: state)) {
            [weak window] in window?.performClose(nil)
        }

        let controller = NSWindowController(window: window)
        languageController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Общее

    /// Папка `Language` рядом с модулями — там же, откуда читает `AppState`.
    static func languageDirectory(state: AppState) -> URL {
        state.modulesFolder.deletingLastPathComponent().appendingPathComponent("Language")
    }

    private static func makeWindow(width: CGFloat, height: CGFloat,
                                   title: String, autosave: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(autosave)
        window.center()
        return window
    }
}

/// «Тексты перевода изменены. Сохранить?» — TextMessages3 оригинала.
///
/// Делегат вынесен из `InterfaceWindows` наружу: `windowShouldClose` в
/// `NSWindowDelegate` объявлен вне актора, и метод типа, помеченного
/// `@MainActor`, требование протокола не удовлетворяет.
final class TranslateWindowDelegate: NSObject, NSWindowDelegate {
    private let model: LocalizeTranslateModel
    private let state: AppState

    init(model: LocalizeTranslateModel, state: AppState) {
        self.model = model
        self.state = state
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard model.isDirty else { return true }
            let alert = NSAlert()
            alert.messageText = state.text("TextMessages4", form: "LocalizeTranslateForm",
                                           default: "Сохранение переводов")
            alert.informativeText = state.text("TextMessages3", form: "LocalizeTranslateForm",
                                               default: "Тексты перевода изменены. Сохранить?")
            alert.addButton(withTitle: OurWords.t("Да"))
            alert.addButton(withTitle: OurWords.t("Нет"))
            alert.addButton(withTitle: OurWords.t("Отмена"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard model.save() else { return false }
                InterfaceLanguageStore.announceChange(originals: model.originals)
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
    }
}
