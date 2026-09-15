import AppKit
import SlovoCore

/// Вкладка «Оновлення» (`TSUpdate`): програма й ресурси з GitHub.
///
/// Власник: «в последствии они (ресурсы) будут обновляться и можно
/// выполнять обновления с программы, также при обновлении самой программы
/// также выполнять обновление с того же ресурса». Перемикач «як часто
/// перевіряти» — автора; кнопки — наші: перевірити випуск на GitHub,
/// відкрити ресурси.
@MainActor
final class NativeSettingsUpdateTab {

    private let state: AppState
    private let store: SettingsStore
    private let versionLabel = NativeForm.label("", secondary: false)
    private let checkResult = NativeForm.label("", secondary: true)

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        // Значення — дні: так їх і пише оригінал у налаштування.
        let days = [0, 7, 30, 365]
        let titles = [state.vb("RGUpdateIntervals->Item0", "Никогда (отключить проверку)"),
                      state.vb("RGUpdateIntervals->Item1", "Неделя"),
                      state.vb("RGUpdateIntervals->Item2", "Месяц"),
                      state.vb("RGUpdateIntervals->Item3", "Год")]
        let interval = NativeForm.Group(state.vb("RGUpdateIntervals", "Интервал проверки обновлений"), [
            NativeForm.Row("", [
                NativeForm.choice(titles, NativeForm.Tie(get: { [store] in
                    days.firstIndex(of: store.settings.options.updateInterval) ?? 0
                }, set: { [store] index in
                    store.settings.options.updateInterval = days[min(index, days.count - 1)]
                })),
            ]),
            NativeForm.Row("", [NativeForm.label(OurWords.t("При запуске программа спрашивает GitHub, вышла ли новая версия, не чаще выбранного срока."), secondary: true)]),
        ])

        versionLabel.stringValue = OurWords.t("Версия %s (%s)", AppUpdater.currentVersion,
                                              Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
        let program = NativeForm.Group(OurWords.t("Программа"), [
            NativeForm.Row("", [versionLabel]),
            NativeForm.Row("", [
                NativeForm.button(OurWords.t("Проверить обновление на GitHub"),
                                  hint: OurWords.t("Спросить GitHub сейчас, вышла ли новая версия, и предложить её установить")) { [weak self] in self?.check() },
                checkResult,
            ]),
        ])

        let resources = NativeForm.Group(OurWords.t("Ресурсы"), [
            NativeForm.Row("", [
                NativeForm.button(OurWords.t("Ресурсы с GitHub…"), hint: OurWords.t("Переводы, песенники, фоны, шаблоны: загрузить новые или обновить")) { [state] in
                    NativeResourcesWindow.show(state: state)
                },
                NativeForm.button(OurWords.t("Обновить ресурсы…"), hint: OurWords.t("Отметить всё, что обновилось в каталоге")) { [state] in
                    NativeResourcesWindow.show(state: state, updatesOnly: true)
                },
            ]),
            NativeForm.Row("", [NativeForm.label(OurWords.t("Каталог: github.com/roman885-85/slovo-resources; переводы также из «Цитаты из Библии» на GitHub."), secondary: true)]),
        ])
        return NativeForm.Page([interval, program, resources])
    }

    private func check() {
        checkResult.stringValue = OurWords.t("Спрашиваю GitHub…")
        AppUpdater.fetchLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.checkResult.stringValue = "\(error)"
            case .success(let release):
                if AppUpdater.isNewer(release.version, than: AppUpdater.currentVersion) {
                    self.checkResult.stringValue = OurWords.t("Есть новая версия: %s", release.version)
                    AppUpdater.offer(release, state: self.state)
                } else {
                    self.checkResult.stringValue = OurWords.t("У вас последняя версия (%s)", release.version)
                }
            }
        }
    }
}
