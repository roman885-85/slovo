import AppKit
import SlovoCore

/// Замечания владельца от 12 сентября: «в настройках модулей нет разделения на
/// песенники и библии, при отключении или включении модуля в программе ничего
/// не происходит», «добавить функцию сброса всех настроек по умолчанию и также
/// для каждого пункта настроек отдельный сброс», «функция экспорта настроек и
/// импорта», «сделать настройку теней и контура более мягкой и вариативной».
///
/// Проверяем тем же путём, каким идёт рука: щелчок по галочке во вкладке
/// «Модули» — и полоса переводов обязана измениться сразу, без «Ок».
extension Diagnostics {

    static func settingsServiceSection(state: AppState) -> [Check] {
        let area = "Налаштування"
        let store = SettingsStore.shared
        let before = store.settings
        var checks: [Check] = []
        defer {
            store.settings = before
            state.applyModuleRoster(before.modules)
        }

        checks.append(modulesSplitCheck(area: area, state: state, store: store))
        checks.append(liveToggleCheck(area: area, state: state, store: store))
        checks.append(songBookToggleCheck(area: area, state: state, store: store))
        checks.append(resetCheck(area: area, store: store))
        checks.append(transferCheck(area: area, store: store))
        checks.append(shadowAngleCheck(area: area))
        checks.append(returnKeyCheck(area: area))
        checks.append(songTemplateCheck(area: area, state: state))
        return checks
    }

    /// Шаблон пісень окремий від шаблону Біблії.
    private static func songTemplateCheck(area: String, state: AppState) -> Check {
        let name = "Пісні беруть свій шаблон, Біблія — спільний"
        guard let own = state.presets.presets.first else {
            return Check(area: area, name: name, status: .skipped, detail: "своїх шаблонів немає")
        }
        let wasMode = state.mode
        let wasSongs = state.presets.preset(for: .screen, songs: true)
        defer {
            state.applyPreset(wasSongs, forSongs: true)
            state.mode = wasMode
        }
        let common = state.presets.preset(for: .screen)?.name ?? "авторський"
        state.applyPreset(own, forSongs: true)
        state.mode = .songs
        let onSongs = state.slidePreset?.id
        state.mode = .bible
        let onBible = state.slidePreset?.id
        state.applyPreset(nil, forSongs: true)
        state.mode = .songs
        let afterReset = state.slidePreset?.id
        let detail = "призначили пісням «\(own.name)»; на піснях: \(onSongs == own.id ? "він" : "інший"),"
            + " на Біблії: \(onBible == own.id && state.presets.preset(for: .screen)?.id != own.id ? "теж він (зайве)" : "спільний (\(common))"),"
            + " після «як для Біблії»: \(afterReset == state.presets.preset(for: .screen)?.id ? "спільний" : "інший")"
        let ok = onSongs == own.id
            && (onBible == state.presets.preset(for: .screen)?.id)
            && afterReset == state.presets.preset(for: .screen)?.id
        return Check(area: area, name: name, status: ok ? .ok : .failed, detail: detail)
    }

    /// Поділ списку на переклади й пісенники.
    private static func modulesSplitCheck(area: String, state: AppState,
                                          store: SettingsStore) -> Check {
        let name = "Список модулів поділено на Біблії та пісенники"
        let tab = NativeSettingsModulesTab(state: state, store: store)
        var headers: [String] = []
        for index in 0..<tab.rowCount {
            let row = tab.row(at: index)
            if row.lead.isEmpty && !row.text.isEmpty { headers.append(row.text) }
        }
        let bibles = store.settings.modules.filter { !$0.isSongBook }.count
        let songs = store.settings.modules.filter { $0.isSongBook }.count
        let wanted = (bibles > 0 ? 1 : 0) + (songs > 0 ? 1 : 0)
        let detail = "рядків \(tab.rowCount), заголовків \(headers.count): "
            + headers.joined(separator: " | ") + "; перекладів \(bibles), пісенників \(songs)"
        guard headers.count == wanted, tab.rowCount == store.settings.modules.count + wanted else {
            return Check(area: area, name: name, status: .failed,
                         detail: "очікували \(wanted) заголовки; " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Галочка перекладу діє одразу, без «Ок».
    private static func liveToggleCheck(area: String, state: AppState,
                                        store: SettingsStore) -> Check {
        let name = "Галочка перекладу міняє смугу одразу, без «Ок»"
        let known = Set(state.allModules.map { $0.identifier.lowercased() })
        guard let entry = store.settings.modules.first(where: {
            $0.isEnabled && !$0.isSongBook && known.contains($0.libraryIdentifier.lowercased())
        }) else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "немає ввімкненого перекладу, який бібліотека відкрила")
        }
        let before = state.orderedModules.count
        store.setModule(entry.id, enabled: false)
        state.applyModuleRoster(store.settings.modules)
        let off = state.orderedModules.count
        store.setModule(entry.id, enabled: true)
        state.applyModuleRoster(store.settings.modules)
        let on = state.orderedModules.count
        // І окремо — знята остання галочка: смуга має спорожніти, а не
        // лишитися такою, як була.
        let all = store.settings.modules.filter { $0.isEnabled && !$0.isSongBook }
        for item in all { store.setModule(item.id, enabled: false) }
        state.applyModuleRoster(store.settings.modules)
        let empty = state.orderedModules.count
        for item in all { store.setModule(item.id, enabled: true) }
        state.applyModuleRoster(store.settings.modules)
        let back = state.orderedModules.count
        let detail = "«\(entry.name)»: було \(before), без галочки \(off), з галочкою \(on);"
            + " без жодної галочки \(empty), назад \(back)"
        guard off == before - 1, on == before, empty == 0, back == before else {
            return Check(area: area, name: name, status: .failed,
                         detail: "смуга не пішла за галочкою; " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Те саме для пісенника.
    private static func songBookToggleCheck(area: String, state: AppState,
                                            store: SettingsStore) -> Check {
        let name = "Галочка пісенника міняє список пісенників одразу"
        let known = Set(state.allSongBooks.map { $0.url.lastPathComponent.lowercased() })
        guard let entry = store.settings.modules.first(where: {
            $0.isEnabled && $0.isSongBook && known.contains($0.name.lowercased())
        }) else {
            return Check(area: area, name: name, status: .skipped, detail: "немає ввімкненого пісенника")
        }
        let before = state.songBooks.count
        store.setModule(entry.id, enabled: false)
        state.applyModuleRoster(store.settings.modules)
        let off = state.songBooks.count
        store.setModule(entry.id, enabled: true)
        state.applyModuleRoster(store.settings.modules)
        let on = state.songBooks.count
        let detail = "«\(entry.name)»: було \(before), без галочки \(off), з галочкою \(on)"
        guard off == before - 1, on == before else {
            return Check(area: area, name: name, status: .failed,
                         detail: "список пісенників не пішов за галочкою; " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Скидання вкладки й скидання всього.
    private static func resetCheck(area: String, store: SettingsStore) -> Check {
        let name = "Скидання: окрема вкладка і всі налаштування"
        let fresh = store.factorySettings()
        var faults: [String] = []
        var lines: [String] = []

        // Правимо по значенню з двох різних вкладок.
        store.settings.options.crossfadeTime = 4321
        store.settings.options.remotePort = 8199
        store.reset(.slide)
        lines.append("після скидання «Слайд»: час зміни \(store.settings.options.crossfadeTime)"
                     + " (умовчання \(fresh.options.crossfadeTime)), порт пульта \(store.settings.options.remotePort)")
        if store.settings.options.crossfadeTime != fresh.options.crossfadeTime {
            faults.append("скидання вкладки не повернуло її значення")
        }
        if store.settings.options.remotePort != 8199 {
            faults.append("скидання вкладки зачепило чуже значення")
        }

        store.resetAll()
        lines.append("після скидання всього: порт пульта \(store.settings.options.remotePort)"
                     + " (умовчання \(fresh.options.remotePort))")
        if store.settings.options.remotePort != fresh.options.remotePort {
            faults.append("скидання всього не повернуло значення інших вкладок")
        }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                         + lines.joined(separator: "; "))
    }

    /// Вивезення у файл і ввезення назад.
    private static func transferCheck(area: String, store: SettingsStore) -> Check {
        let name = "Налаштування вивозяться у файл і вертаються з нього"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-settings-check.json")
        defer { try? FileManager.default.removeItem(at: url) }
        store.settings.options.crossfadeTime = 777
        do {
            try store.export(to: url)
        } catch {
            return Check(area: area, name: name, status: .failed,
                         detail: "не вдалося записати файл: \(error.localizedDescription)")
        }
        let size = (try? Data(contentsOf: url).count) ?? 0
        store.settings.options.crossfadeTime = 111
        do {
            try store.importSettings(from: url)
        } catch {
            return Check(area: area, name: name, status: .failed,
                         detail: "не вдалося прочитати файл: \(error.localizedDescription)")
        }
        let detail = "файл \(size) байтів; час зміни після ввезення \(store.settings.options.crossfadeTime)"
        guard store.settings.options.crossfadeTime == 777 else {
            return Check(area: area, name: name, status: .failed,
                         detail: "ввезене значення не стало на місце; " + detail)
        }
        // Чужий файл не має нічого міняти.
        let alien = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-settings-alien.json")
        try? Data("{\"це\":\"не налаштування\"}".utf8).write(to: alien)
        defer { try? FileManager.default.removeItem(at: alien) }
        let kept = store.settings.options.crossfadeTime
        let refused = (try? store.importSettings(from: alien)) == nil
        guard refused, store.settings.options.crossfadeTime == kept else {
            return Check(area: area, name: name, status: .failed,
                         detail: "чужий файл прийнято як свій; " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail + "; чужий файл відхилено")
    }

    /// Напрямок тіні: 45° — точно як було, інші кути повертають тінь.
    private static func shadowAngleCheck(area: String) -> Check {
        let name = "Тінь: напрямок з’явився, а старі шаблони не змінилися"
        let classic = ObjectShadow(isEnabled: true, offsetPercent: 5, blurPercent: 3, opacity: 1)
        let old = classic.metrics(fontSize: 100, objectHeight: 100)
        var down = classic
        down.angleDegrees = 90
        let vertical = down.metrics(fontSize: 100, objectHeight: 100)
        let detail = String(format: "45°: %.2f×%.2f; 90°: %.2f×%.2f",
                            old.offset.width, old.offset.height,
                            vertical.offset.width, vertical.offset.height)
        guard abs(old.offset.width - 5) < 0.01, abs(old.offset.height - 5) < 0.01,
              abs(vertical.offset.width) < 0.01, abs(vertical.offset.height - 7.07) < 0.05 else {
            return Check(area: area, name: name, status: .failed, detail: detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Enter у полі не натискає кнопку вікна.
    private static func returnKeyCheck(area: String) -> Check {
        let name = "Enter у полі закінчує правку, а не закриває вікно"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(string: "12")
        field.frame = NSRect(x: 10, y: 10, width: 100, height: 22)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editing = window.firstResponder is NSTextView
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else {
            return Check(area: area, name: name, status: .skipped, detail: "не вдалося зібрати подію клавіші")
        }
        let caught = NativeForm.endsFieldEditing(on: event, in: window)
        let released = !(window.firstResponder is NSTextView)
        let idle = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r",
                                    isARepeat: false, keyCode: 36)
        let passes = idle.map { !NativeForm.endsFieldEditing(on: $0, in: window) } ?? false
        let detail = "правили поле: \(editing), Enter перехоплено: \(caught),"
            + " правку закінчено: \(released), поза полем Enter іде далі: \(passes)"
        guard editing, caught, released, passes else {
            return Check(area: area, name: name, status: .failed, detail: detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }
}
