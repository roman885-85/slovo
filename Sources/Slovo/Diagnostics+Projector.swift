import AppKit
import SlovoCore

/// Вікно слайда й сповіщення «змінилися параметри екранів».
///
/// Власник: «открываю, сворачиваю или разворачиваю окно других программ или
/// просто окно finder и на проекторе пропадает изображение (на ndi все
/// работает), если нажать переключение слайда — изображение появляется».
/// macOS шле це сповіщення і тоді, коли згортають чи розгортають чуже вікно
/// (міняються Dock і рядок меню), а програма щоразу перебудовувала вікно
/// слайда й лишала його чорним до наступного слайда.
extension Diagnostics {

    static func projectorScreenNoticeSection(state: AppState) -> [Check] {
        let area = "Проектор"
        let projection = state.projection
        let wasVisible = projection.isVisible
        let wasLive = state.isLive
        defer {
            state.isLive = wasLive
            if !wasVisible { projection.setVisible(false) }
        }
        projection.setVisible(true)
        state.showCurrent()
        wait(untilTrue: { projection.hallImage != nil }, seconds: 5)
        guard projection.hallImage != nil, let before = projection.slideWindowNumber else {
            return [Check(area: area, name: "Згорнули чуже вікно — картинка в залі лишається", status: .skipped,
                          detail: "у вікні слайда нічого не намалювалося")]
        }
        var checks: [Check] = []

        // 1. Сповіщення без справжньої зміни екранів: вікно те саме, картинка на місці.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        wait(untilTrue: { false }, seconds: 0.5)
        let kept = projection.slideWindowNumber == before
        let stays = projection.hallImage != nil
        checks.append(Check(area: area, name: "Згорнули чуже вікно — картинка в залі лишається",
                            status: kept && stays ? .ok : .failed,
                            detail: "вікно слайда \(kept ? "те саме" : "перебудоване"), картинка \(stays ? "на місці" : "зникла")"))

        // 2. Екрани справді змінилися: вікно нове, а картинка вертається сама.
        projection.rebuildAsIfScreensChanged()
        let rebuilt = projection.slideWindowNumber != before
        wait(untilTrue: { projection.hallImage != nil }, seconds: 3)
        let back = projection.hallImage != nil
        checks.append(Check(area: area, name: "Екрани змінилися — картинка вертається без нового слайда",
                            status: rebuilt && back ? .ok : .failed,
                            detail: "вікно \(rebuilt ? "перебудоване" : "не перебудоване"), картинка \(back ? "повернулася" : "не повернулася")"))
        return checks
    }
}
