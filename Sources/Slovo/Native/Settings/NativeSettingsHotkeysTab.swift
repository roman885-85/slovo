import AppKit
import SlovoCore

/// 6.1.6 «Горячие клавиши» на AppKit.
///
/// Розкладка читається з `hotkeys.ini` програми — там кілька іменованих
/// наборів (`[VB Version 2.2]`, `2.3`, `2.4`), і випадний список (36)
/// показує саме їх. Порядок функцій той самий, що у двох стовпцях звичної
/// форми: перші дев'ять зліва, решта справа.
///
/// Занятая комбинация не подменяется молча: спрашиваем словами автора
/// (TextMessages21…23), и только по согласию снимаем её с прежней функции.
@MainActor
final class NativeSettingsHotkeysTab {

    private let state: AppState
    private let store: SettingsStore
    private var setsPopup: NSPopUpButton!
    private var pickers: [String: NSPopUpButton] = [:]

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        NativeForm.Page([sets, columns, pointer])
    }

    // MARK: (36) (37) (38) и (35)

    private var sets: NativeForm.Group {
        let names = store.settings.hotkeySets.order
        setsPopup = NativeForm.popup(names, NativeForm.Tie(get: { [store] in
            names.firstIndex(of: store.settings.hotkeySetName) ?? 0
        }, set: { [store, weak self] index in
            guard names.indices.contains(index) else { return }
            store.settings.hotkeySetName = names[index]
            self?.reloadPickers()
        }), width: 240)
        setsPopup.toolTip = state.vbHint("CBHotKeys", "Наборы горячих клавиш")

        return NativeForm.Group("", [
            NativeForm.Row("", [
                setsPopup,
                NativeForm.button("⤓", hint: state.vbHint("PSBSaveHotKeys",
                                                          "Сохранить/добавить набор горячих клавиш")) {
                    [weak self] in self?.saveSet()
                },
                NativeForm.button("🗑", hint: state.vbHint("PSBDelHotKeys",
                                                           "Удалить набор горячих клавиш")) {
                    [weak self] in self?.deleteSet()
                },
                NativeForm.button(state.vb("PngSBDefaultHotKey", OurWords.t("По умолчанию")),
                                  hint: state.vbHint("PngSBDefaultHotKey",
                                                     "Установить горячие клавиши по умолчанию")) {
                    [weak self] in
                    self?.store.resetHotkeysToDefault()
                    self?.reloadPickers()
                },
            ]),
        ])
    }

    // MARK: Функции

    private var columns: NativeForm.Group {
        NativeForm.Group("", HotkeyAction.all.map { action in
            let picker = NativeForm.popup(choices(for: action), NativeForm.Tie(get: { [store] in
                let current = store.hotkeys[action.iniKey]?.text ?? ""
                return self.choices(for: action).firstIndex(of: current) ?? 0
            }, set: { [weak self] index in
                self?.assign(self?.choices(for: action)[index] ?? "", to: action)
            }), width: 140)
            pickers[action.iniKey] = picker
            // Подписи Label21…Label51 — те же, что в форме оригинала;
            // хвостовое двоеточие в столбце не нужно.
            var caption = state.vb(action.captionKey, action.fallback)
            if caption.hasSuffix(":") { caption.removeLast() }
            return NativeForm.Row(caption, width: 300, [picker])
        })
    }

    private var pointer: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBUseRCPointer", "Использовать Wireless Presenter R400"),
                                 NativeForm.Tie(get: { [store] in store.settings.options.useRCPointer },
                                                set: { [store] in store.settings.options.useRCPointer = $0 })),
            ]),
        ])
    }

    // MARK: - Назначение

    private func assign(_ text: String, to action: HotkeyAction) {
        guard !text.isEmpty, text != "—", let hotkey = Hotkey(text: text) else {
            store.setHotkey(nil, for: action.iniKey)
            return
        }
        guard let taken = store.actionUsing(hotkey, excluding: action.iniKey) else {
            store.setHotkey(hotkey, for: action.iniKey)
            return
        }
        // TextMessages21…23: комбинация занята — спрашиваем, забирать ли её.
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages24", "Внимание")
        alert.informativeText = "\(state.vb("TextMessages21", "Комбинация")) \(hotkey.text) "
            + "\(state.vb("TextMessages22", "занята в")) «\(caption(taken))»\n"
            + state.vb("TextMessages23", "Использовать для новой функции?")
        alert.addButton(withTitle: state.yesCaption)
        alert.addButton(withTitle: state.noCaption)
        if alert.runModal() == .alertFirstButtonReturn {
            store.setHotkey(hotkey, for: action.iniKey, clearing: taken.iniKey)
        }
        reloadPickers()
    }

    private func caption(_ action: HotkeyAction) -> String {
        var text = state.vb(action.captionKey, action.fallback)
        if text.hasSuffix(":") { text.removeLast() }
        return text
    }

    private func saveSet() {
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages20", "Сохранение набора горячих клавиш")
        alert.informativeText = state.vb("TextMessages19", "Сохранить набор:")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = store.settings.hotkeySetName
        alert.accessoryView = field
        alert.addButton(withTitle: state.vb("BBOk", "Ок"))
        alert.addButton(withTitle: state.vb("BBCancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.saveHotkeySet(named: name)
        rebuildSets()
    }

    private func deleteSet() {
        guard store.settings.hotkeySets.order.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages18", "Удаление набора горячих клавиш")
        alert.informativeText = "\(state.vb("TextMessages17", "Удалить набор:")) "
            + store.settings.hotkeySetName
        alert.addButton(withTitle: state.yesCaption)
        alert.addButton(withTitle: state.noCaption)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteHotkeySet(named: store.settings.hotkeySetName)
        rebuildSets()
    }

    private func rebuildSets() {
        setsPopup.removeAllItems()
        setsPopup.addItems(withTitles: store.settings.hotkeySets.order)
        setsPopup.selectItem(withTitle: store.settings.hotkeySetName)
        reloadPickers()
    }

    /// Список доступных комбинаций. Текущая добавляется всегда: файл мог
    /// прийти из другой сборки, и терять назначение из-за того, что его нет
    /// в нашем списке, нельзя.
    private func choices(for action: HotkeyAction) -> [String] {
        var result = ["—"] + Self.candidates
        if let current = store.hotkeys[action.iniKey]?.text, !result.contains(current) {
            result.insert(current, at: 1)
        }
        return result
    }

    private func reloadPickers() {
        for action in HotkeyAction.all {
            guard let picker = pickers[action.iniKey] else { continue }
            let list = choices(for: action)
            picker.removeAllItems()
            picker.addItems(withTitles: list)
            let current = store.hotkeys[action.iniKey]?.text ?? "—"
            picker.selectItem(at: list.firstIndex(of: current) ?? 0)
        }
    }

    private static let candidates: [String] = {
        var result: [String] = []
        let functions = (1...12).map { "F\($0)" }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        let extras = ["Esc", "Space", "Ins", "Del", "Home", "End", "PgUp", "PgDn"]

        result += functions
        result += extras
        result += functions.map { "Ctrl+" + $0 }
        result += letters.map { "Ctrl+" + $0 }
        result += functions.map { "Ctrl+Shift+" + $0 }
        result += letters.map { "Ctrl+Alt+" + $0 }
        return result
    }()
}
