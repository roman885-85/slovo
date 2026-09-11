import AppKit
import SlovoCore

/// Замечание 4, дословная последовательность владельца (2026-09-07):
/// «запуск слайдов презентации → кнопка "Скрыть" → вкладка Библии → выбор
/// стиха → "Показать" → на проекторе вместо стиха слайд презентации,
/// который был последним перед закрытием».
///
/// Кнопка «Скрыть» внизу — это `isLive = false`, и она НЕ снимает картинку
/// показа (`media.still`): гаснет зал, а картинка остаётся «на экране» в
/// смысле `isVideoOnScreen`. Дальше показ стиха обязан убрать её с проектора.
/// Проверяем именно проектор: что в его текстовом слое (`lastScreenSlide`) и
/// стоит ли ещё кадр картинки над ним.
extension Diagnostics {

    static func projectorTypeSwitchSection(state: AppState) -> [Check] {
        let area = "Показ"
        let name = "Після «Сховати» презентації показ Біблії дає вірш, а не слайд"

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-проектор-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("проба.pdf")
        guard makePDF(at: pdf, pages: 2) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний PDF")]
        }

        let workspace = NativeShowWorkspace.presentation
        let wasMode = state.mode
        let wasLive = state.isLive
        workspace.model.close()
        defer {
            workspace.model.close()
            state.media.showStill(nil)
            state.isLive = wasLive
            state.mode = wasMode
            Signals.shared.send(.mode)
        }

        func settle(_ s: Double = 0.35) { wait(untilTrue: { false }, seconds: s) }
        var steps: [String] = []
        var faults: [String] = []
        func snapshot(_ label: String) {
            steps.append("\(label): текст залу «\(state.lastScreenSlide.mainText.prefix(16))», "
                + "кадр показу \(state.media.isVideoOnScreen ? "стоїть" : "знято"), "
                + "картинка \(state.media.still != nil ? "є" : "немає"), "
                + "показ=\(state.isLive) заборони=\(state.media.screenSuppression.rawValue) "
                + "наЕкран=\(state.media.videoToScreen) єВідео=\(state.media.hasVideo)")
        }

        // 1. Запуск слайдов презентации: открыть, выбрать первую страницу, показать.
        state.mode = .presentation
        Signals.shared.send(.mode)
        workspace.open([pdf])
        workspace.selectPage(0)
        workspace.showCurrentPage()
        settle()
        snapshot("1. презентація в залі")
        if !state.media.isVideoOnScreen { faults.append("сторінка презентації не стала в зал") }

        // 2. Кнопка «Скрыть» внизу — ровно `isLive = false`.
        state.isLive = false
        settle()
        snapshot("2. після «Сховати»")

        // 3. Вкладка Библии.
        state.mode = .bible
        Signals.shared.send(.mode)
        settle()
        // 4. Выбор стиха.
        if let first = state.currentChapter?.verses.first?.number {
            state.selectVerse(first, mode: .replace)
        }
        settle(0.2)
        let verse = state.slide.mainText
        snapshot("3–4. Біблія, вірш вибрано")
        guard !verse.isEmpty else {
            return [Check(area: area, name: name, status: .skipped, detail: "немає з чим порівнювати: вірш порожній. " + steps.joined(separator: " | "))]
        }

        // 5. «Показать».
        state.showCurrent()
        settle(Defaults.mediaFadeSeconds + 0.3)
        snapshot("5. після «Показати»")

        // 6. На проекторе — стих, а не слайд презентации.
        let hallText = state.lastScreenSlide.mainText
        if state.media.isVideoOnScreen { faults.append("над віршем на проекторі лишився кадр презентації") }
        if hallText != verse { faults.append("у текстовому шарі проектора «\(hallText.prefix(16))», а чекали вірш «\(verse.prefix(16))»") }
        if state.lastScreenSlide.isBlank { faults.append("проектор показує порожній слайд замість вірша") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "вірш вийшов на проектор, кадр презентації знято. " : faults.joined(separator: "; ") + ". ")
                          + steps.joined(separator: " | "))]
    }
}
