import AppKit
import SlovoCore

/// Вкладка «Обновление» (`TSUpdate`) на AppKit.
///
/// У автора здесь один переключатель — как часто проверять обновления.
/// Проверять пока нечего: своего сервера обновлений у программы нет, поэтому
/// значение только хранится, и сказано об этом прямо, а не спрятано за
/// неработающей кнопкой.
@MainActor
final class NativeSettingsUpdateTab {

    private let state: AppState
    private let store: SettingsStore

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        // Значения — дни: так их и пишет оригинал в настройки.
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
        ])

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let about = NativeForm.Group("", [
            NativeForm.Row("", [NativeForm.label(OurWords.t("Версия %s (%s)", short, build), secondary: false)]),
            NativeForm.Row("", [NativeForm.label(OurWords.t(
                "Сервера обновлений у «Слова» нет — значение хранится для совместимости со старым файлом настроек."))]),
        ])
        return NativeForm.Page([interval, about])
    }
}
