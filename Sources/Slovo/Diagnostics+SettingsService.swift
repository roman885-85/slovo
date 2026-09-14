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
        checks.append(constructorScopesCheck(area: area, state: state))
        return checks
    }

    /// Два редактори в Конструкторі: у редакторі пісень — лише шаблони
    /// пісень, у редакторі Біблії — лише Біблії; новий шаблон у редакторі
    /// пісень несе прапорець пісень і назву пісні замість адреси; прапорець
    /// переживає запис у файл, а старий файл без нього читається як Біблія.
    /// Власник: «потрібен окремий редактор для Біблії й окремий для пісень
    /// — інакше губиться весь сенс двох розділів».
    private static func constructorScopesCheck(area: String, state: AppState) -> Check {
        let name = "Конструктор: редактори Біблії та пісень не діляться шаблонами"
        let defaults = UserDefaults.standard
        let wasScope = defaults.object(forKey: "constructorForSongs")
        defer {
            defaults.set(wasScope, forKey: "constructorForSongs")
            state.previewPreset(nil)
        }
        // Відкриваємо на Біблії: там шаблони є, і редактор не «брудний».
        // Вкладка програми — пісні: редактор Біблії все одно має показувати
        // вірш, а не куплет із «Приспівом» (скрин власника).
        let wasMode = state.mode
        defer { state.mode = wasMode }
        state.mode = .songs
        defaults.set(false, forKey: "constructorForSongs")
        let constructor = NativeSlideConstructor(state: state, onClose: {})
        // У вікні, хоч і не показаному: поза вікном шари полотна й список
        // об'єктів у знімок не потрапляють.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = constructor
        constructor.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        let model = constructor.modelForCheck
        let bibles = model.library.presets(forSongs: false).count
        let songs = model.library.presets(forSongs: true).count
        let schemes = model.schemes?.templates.count ?? 0
        var faults: [String] = []

        let onBible = constructor.scopeForCheck
        if onBible.forSongs { faults.append("відкрився на піснях, а просили Біблію") }
        if onBible.listed.count != bibles + schemes {
            faults.append("у редакторі Біблії \(onBible.listed.count) пунктів, а шаблонів Біблії \(bibles) + авторських \(schemes)")
        }
        if model.preset.forSongs { faults.append("у редакторі Біблії відкрито шаблон пісень «\(model.preset.name)»") }
        let bibleSample = constructor.sampleForCheck
        let songNow = state.slide
        if state.mode == .songs, !songNow.mainText.isEmpty, bibleSample.mainText == songNow.mainText {
            faults.append("на полотні редактора Біблії — куплет пісні з вкладки")
        }
        if bibleSample.reference.isEmpty
            || (state.mode == .songs && !songNow.reference.isEmpty && bibleSample.reference == songNow.reference) {
            faults.append("адреса на полотні редактора Біблії — «\(bibleSample.reference)» (підпис частини пісні)")
        }
        constructor.layoutSubtreeIfNeeded()
        constructor.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        constructor.displayIfNeeded()
        let biblePicture = snapshot(constructor, to: "slovo-конструктор-біблія.png")
            ? "; знімок Біблії ~/Library/Logs/slovo-конструктор-біблія.png" : ""

        guard !model.asksToSave(before: .switchPreset) else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "редактор Біблії відкрився з незбереженими правками — перемикати не можна без вікна")
        }
        constructor.chooseScopeForCheck(forSongs: true)
        let onSongs = constructor.scopeForCheck
        if !onSongs.forSongs { faults.append("не перемкнувся на пісні") }
        // Коли шаблонів пісень нема, редактор відкриває новий — він стоїть
        // у списку першим як «не збережено».
        let fresh = songs == 0
        if onSongs.listed.count != songs + schemes + (fresh ? 1 : 0) {
            faults.append("у редакторі пісень \(onSongs.listed.count) пунктів, а шаблонів пісень \(songs) + авторських \(schemes)"
                          + (fresh ? " + новий" : ""))
        }
        if !model.preset.forSongs { faults.append("у редакторі пісень відкрито шаблон Біблії «\(model.preset.name)»") }
        // Розкладка пісні: куплет і підпис частини (об'єкт адреси показує
        // «Куплет»/«Приспів»); другого перекладу нема; назви пісні в
        // розкладці за умовчанням нема — її додають окремо.
        if fresh, !model.preset.objects.contains(where: { $0.kind == .reference }) {
            faults.append("новий шаблон пісень без підпису частини (об'єкта адреси)")
        }
        if fresh, model.preset.objects.contains(where: { $0.kind == .secondaryQuote || $0.kind == .songTitle }) {
            faults.append("новий шаблон пісень з другим перекладом чи назвою пісні замість частини")
        }
        let songSample = constructor.sampleForCheck
        if songSample.reference.isEmpty || songSample.reference == songSample.songTitle {
            faults.append("підпис частини в редакторі пісень — «\(songSample.reference)» (назва пісні замість куплета)")
        }
        if songSample.mainText.isEmpty || songSample.mainText == bibleSample.mainText {
            faults.append("на полотні редактора пісень не куплет, а вірш")
        }

        // Прапорець у файлі й назад; файл без прапорця — Біблії.
        if let data = try? JSONEncoder().encode(model.preset),
           let back = try? JSONDecoder().decode(SlidePreset.self, from: data) {
            if !back.forSongs { faults.append("прапорець пісень не пережив запис у JSON") }
        } else {
            faults.append("шаблон не записався в JSON")
        }
        if var raw = try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(model.preset)) ?? Data()) as? [String: Any] {
            raw["forSongs"] = nil
            if let data = try? JSONSerialization.data(withJSONObject: raw),
               let old = try? JSONDecoder().decode(SlidePreset.self, from: data) {
                if old.forSongs { faults.append("файл без прапорця прочитано як пісенний") }
            } else {
                faults.append("файл без прапорця не прочитався")
            }
        }

        // Знімок редактора пісень — звірити на око куплет і назву на полотні.
        // Полотно малює слайд у черзі (`SlideRenderQueue`) і показує готову
        // картинку наступним кадром — даємо черзі час, інакше на знімку
        // чорне полотно з однією рамкою.
        constructor.layoutSubtreeIfNeeded()
        constructor.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        constructor.displayIfNeeded()
        let picture = snapshot(constructor, to: "slovo-конструктор-пісні.png")
            ? "; знімок ~/Library/Logs/slovo-конструктор-пісні.png" : ""
        let detail = "Біблія: \(onBible.listed.count) пунктів (\(bibles) своїх + \(schemes) авторських); "
            + "пісні: \(onSongs.listed.count) пунктів (\(songs) своїх + \(schemes) авторських)"
            + (fresh ? "; шаблонів пісень нема — редактор відкрив новий «\(model.preset.name)» з куплетом і підписом частини" : "")
            + "; Біблія показує «\(bibleSample.reference)», пісні — «\(songSample.reference)»"
            + biblePicture + picture
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? detail : faults.joined(separator: "; ") + ". " + detail)
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
        let name = "Модулі в налаштуваннях: переклади й пісенники — окремими списками"
        let tab = NativeSettingsModulesTab(state: state, store: store)
        let bibles = store.settings.modules.filter { !$0.isSongBook }.count
        let songs = store.settings.modules.filter { $0.isSongBook }.count
        var faults: [String] = []
        tab.showForCheck(songBooks: false)
        let shownBibles = tab.rowKindsForCheck
        if shownBibles.count != bibles || shownBibles.contains(true) {
            faults.append("у списку перекладів \(shownBibles.count) рядків (перекладів \(bibles)), пісенників серед них \(shownBibles.filter { $0 }.count)")
        }
        tab.showForCheck(songBooks: true)
        let shownSongs = tab.rowKindsForCheck
        if shownSongs.count != songs || shownSongs.contains(false) {
            faults.append("у списку пісенників \(shownSongs.count) рядків (пісенників \(songs)), перекладів серед них \(shownSongs.filter { !$0 }.count)")
        }
        if tab.rowCount != songs { faults.append("рядків у таблиці \(tab.rowCount), а пісенників \(songs)") }
        let detail = "перекладів \(bibles) — у своєму списку \(shownBibles.count); пісенників \(songs) — у своєму \(shownSongs.count)"
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? detail : faults.joined(separator: "; ") + ". " + detail)
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
