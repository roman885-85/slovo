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
        checks.append(contentsOf: slideWindowButtonChecks(state: state))
        return checks
    }

    /// Кнопки вікна слайда: закрити, згорнути, розгорнути.
    ///
    /// Власник: «в окне нет функций закрыть, свернуть и развернуть окно». На
    /// машині з одним екраном слайд іде звичайним вікном, і людина мусить
    /// могти прибрати його з-перед очей. Хрестик при цьому не вбиває показ:
    /// ховає вікно, а наступний слайд вертає його.
    static func slideWindowButtonChecks(state: AppState) -> [Check] {
        let area = "Проектор"
        let projection = state.projection
        var checks: [Check] = []
        guard projection.isSlideWindowFramed else {
            return [Check(area: area, name: "У вікна слайда є всі три кнопки", status: .skipped,
                          detail: "слайд іде безрамковим вікном на окремий екран")]
        }
        let buttons = projection.slideWindowButtons
        let all = buttons.map { $0.close && $0.miniaturize && $0.zoom } ?? false
        checks.append(Check(area: area, name: "У вікна слайда є всі три кнопки",
                            status: all ? .ok : .failed,
                            detail: buttons.map {
                                "закрити \($0.close ? "є" : "немає"), згорнути \($0.miniaturize ? "є" : "немає"), "
                                    + "розгорнути \($0.zoom ? "є" : "немає")"
                            } ?? "вікна слайда немає"))

        // Хрестик: вікно ховається, показ живий, наступний слайд вертає вікно.
        projection.hideSlideWindowByHand()
        wait(untilTrue: { !projection.isSlideWindowVisible }, seconds: 2)
        let hidden = !projection.isSlideWindowVisible
        state.showCurrent()
        wait(untilTrue: { projection.isSlideWindowVisible }, seconds: 3)
        let returned = projection.isSlideWindowVisible
        checks.append(Check(area: area, name: "Хрестик ховає вікно слайда, наступний слайд вертає",
                            status: hidden && returned ? .ok : .failed,
                            detail: "сховалося \(hidden ? "так" : "ні"), повернулося \(returned ? "так" : "ні")"))
        return checks
    }
}
