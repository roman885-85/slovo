import AppKit
import SlovoCore

/// Замечание 12: «переводы Библии при включении не появляются, при отключении
/// не исчезают из списка переводов».
///
/// Проверяем не косвенно, а тем самым путём, каким идёт рука владельца:
/// открыть «Параметры», щёлкнуть галочку модуля во вкладке «Модули», нажать
/// «Ок». Ровно эти вызовы и повторяем — `beginEditing` (открытие окна),
/// `setModule` (щелчок галочки), `save(session)` + `applyProgramOptions`
/// (кнопка «Ок»). Если полоса переводов не меняет число вкладок — поломка
/// воспроизведена.
extension Diagnostics {

    static func modulesWindowSection(state: AppState) -> [Check] {
        let area = "Модулі"
        let name = "Галочка перекладу в «Параметрах» міняє смугу по «Ок»"
        let store = SettingsStore.shared
        let dataRoot = state.modulesFolder.deletingLastPathComponent()

        // Строка на полосе — это библиотечный модуль-Библия, не песенник.
        // Ищем среди роспиcи включённый (его отключим) и, если есть,
        // выключенный, который библиотека уже открыла (его включим).
        func strip() -> Int { NativeBibleWorkspace.shared.strip?.translationTabCount ?? -1 }
        guard strip() >= 0 else {
            return [Check(area: area, name: name, status: .skipped, detail: "смуги перекладів немає (головне вікно не зібрано)")]
        }
        let known = Set(state.allModules.map { $0.identifier.lowercased() })
        let roster = store.settings.modules
        guard let enabledEntry = roster.first(where: {
            $0.isEnabled && !$0.isSongBook && known.contains($0.libraryIdentifier.lowercased())
        }) else {
            return [Check(area: area, name: name, status: .skipped, detail: "немає ввімкненого перекладу Біблії, який можна вимкнути")]
        }

        let original = try? Data(contentsOf: SettingsStore.storageURL)
        var faults: [String] = []
        var lines: [String] = []

        defer {
            // Возвращаем файл настроек и список ровно как было.
            if let original { try? original.write(to: SettingsStore.storageURL, options: .atomic) }
            store.reload(dataRoot: dataRoot)
            state.applyModuleRoster(store.settings.modules)
            if state.rosterNeedsLibraryReload { state.reloadLibrary() }
            wait(untilTrue: { !state.isLoadingLibrary }, seconds: 30)
        }

        // Как «Ок»: последнее закрывшееся окно правки пишет на диск и шлёт
        // повод, по которому перестраивается полоса.
        func clickOk(_ session: SettingsStore.EditSession) {
            store.save(session)
            state.applyProgramOptions(store.settings.options)
        }

        // 1. Отключаем включённый перевод и «жмём Ок» — вкладок должно стать
        //    меньше.
        let before = strip()
        let s1 = store.beginEditing()
        store.setModule(enabledEntry.id, enabled: false)
        clickOk(s1)
        wait(untilTrue: { strip() < before }, seconds: 20)
        let afterOff = strip()
        lines.append("вимкнули «\(enabledEntry.name)»: вкладок було \(before), стало \(afterOff)")
        if afterOff >= before { faults.append("після вимкнення перекладу вкладок на смузі не поменшало") }

        // 2. Включаем обратно — вкладок должно стать столько же, сколько было.
        let s2 = store.beginEditing()
        store.setModule(enabledEntry.id, enabled: true)
        clickOk(s2)
        wait(untilTrue: { strip() >= before }, seconds: 20)
        let afterOn = strip()
        lines.append("увімкнули назад: стало \(afterOn)")
        if afterOn < before { faults.append("після ввімкнення переклад не повернувся на смугу") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}
