import AppKit
import SlovoCore

/// Точка фокуса: увімкнули наближення, натиснули по живому екрану — цей
/// шматок сторінки пішов у зал, а сама сторінка лишилася цілою.
extension Diagnostics {

    static func focusSection(state: AppState) -> [Check] {
        pointSection(state: state) + wheelSection(state: state)
    }

    /// Колесо миші й трекпад: наближення від того місця, де курсор.
    ///
    /// Власник: «точка масштабирования от текущего места положения мыши на
    /// координатах окна вывода лайв, исходное состояние масштаба по нажатию
    /// третьей кнопи мыши». На знімку цього не видно зовсім: наближення
    /// «кудись туди» виглядає так само, як наближення «саме туди».
    private static func wheelSection(state: AppState) -> [Check] {
        let area = "Фокус"
        let name = "Колесо і трекпад: наближення до курсора"
        guard let row = NativeBottom.row else {
            return [Check(area: area, name: name, status: .skipped, detail: "нижнього ряду немає")]
        }
        let focus = SlideFocus.shared
        let wasOn = focus.isOn, wasZoom = focus.look.zoom, wasLiveWidth = NativeBottomMetrics.liveWidth
        defer {
            focus.reset()
            focus.setOn(wasOn)
            focus.setZoom(wasZoom)
            NativeBottomMetrics.liveWidth = wasLiveWidth
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }

        if NativeBottomMetrics.liveWidth <= 0 { row.setShowsMirror(true) }
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let rect = row.mirror.frameRect
        guard rect.width > 4, rect.height > 4 else {
            return [Check(area: area, name: name, status: .skipped, detail: "живого екрана немає")]
        }

        var faults: [String] = []
        var lines: [String] = []

        // Курсор ставимо на чверть ширини й чверть висоти від лівого
        // верхнього кута: місце нічим не примітне, і потрапити в нього
        // випадково не вийде.
        let share = 0.25
        let point = CGPoint(x: rect.minX + rect.width * share,
                            y: rect.maxY - rect.height * share)

        focus.reset()
        row.mirror.wheelForCheck(by: 2, at: point)
        lines.append(String(format: "після колеса: ×%.2f, вікно %.3f %.3f",
                            focus.look.zoom, focus.rect.minX, focus.rect.minY))
        if !focus.isOn { faults.append("колесо не ввімкнуло наближення") }
        if abs(focus.look.zoom - 2) > 0.01 { faults.append(String(format: "кратність %.2f замість 2", focus.look.zoom)) }

        // Головне: точка під курсором лишилася під курсором. У вікні
        // наближення вона має стояти на тій самій чверті.
        let window = focus.rect
        let seenX = (share - window.minX) / window.width
        let seenY = (share - window.minY) / window.height
        lines.append(String(format: "точка бачиться на %.3f %.3f (була на %.3f)", seenX, seenY, share))
        if abs(seenX - share) > 0.02 || abs(seenY - share) > 0.02 {
            faults.append("точка під курсором поїхала")
        }

        // Другий поворот у тому самому місці — кратність множиться, точка
        // стоїть.
        row.mirror.wheelForCheck(by: 2, at: point)
        let second = focus.rect
        let againX = (share - second.minX) / second.width
        lines.append(String(format: "другий поворот: ×%.2f, точка на %.3f", focus.look.zoom, againX))
        if abs(focus.look.zoom - 4) > 0.02 { faults.append(String(format: "другий поворот дав ×%.2f замість 4", focus.look.zoom)) }
        if abs(againX - share) > 0.03 { faults.append("на другому повороті точка поїхала") }

        // Середня кнопка миші — вихідний стан.
        row.mirror.wheelForCheck(by: 0.0001, at: point)
        if focus.isOn { faults.append("викрутили колесо назад, а наближення лишилося") }
        row.mirror.wheelForCheck(by: 3, at: point)
        row.mirror.middleClickForCheck()
        lines.append(String(format: "після скидання: %@, ×%.1f, середина %.2f",
                            focus.isOn ? "увімкнено" : "вимкнено", focus.look.zoom, focus.look.x))
        if focus.isOn || abs(focus.look.x - 0.5) > 0.001 || abs(focus.look.y - 0.5) > 0.001 {
            faults.append("скидання не повернуло вихідний стан")
        }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + lines.joined(separator: "; "))]
    }

    private static func pointSection(state: AppState) -> [Check] {
        let area = "Фокус"
        let name = "Наближення до точки фокуса: сторінка, зал і мережа"
        guard let row = NativeBottom.row else {
            return [Check(area: area, name: name, status: .skipped, detail: "нижнього ряду немає")]
        }
        guard let picture = makePicture(width: 800, height: 600) else {
            return [Check(area: area, name: name, status: .skipped, detail: "пробна картинка не зібралася")]
        }
        let focus = SlideFocus.shared
        let wasOn = focus.isOn, wasZoom = focus.look.zoom
        let wasMode = state.mode, wasLive = state.isLive, wasLiveWidth = NativeBottomMetrics.liveWidth
        defer {
            focus.setOn(wasOn)
            focus.setZoom(wasZoom)
            focus.center()
            state.media.showStill(nil)
            state.mode = wasMode
            state.isLive = wasLive
            NativeBottomMetrics.liveWidth = wasLiveWidth
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }

        var faults: [String] = []
        var lines: [String] = []

        // Живий екран має бути на місці: точку фокуса ставлять натисканням по ньому.
        if NativeBottomMetrics.liveWidth <= 0 { row.setShowsMirror(true) }
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()

        state.mode = .pictures
        state.isLive = true
        focus.setOn(false)
        focus.center()
        state.media.showStill(picture, title: "перевірка")
        wait(untilTrue: { state.media.shownStill != nil }, seconds: 2)

        // 1. Наближення вимкнено — у зал іде вся сторінка.
        let whole = state.media.shownStill
        lines.append("без наближення: \(whole.map { "\($0.width)×\($0.height)" } ?? "немає")")
        if whole?.width != picture.width { faults.append("без наближення сторінку вже обрізано") }

        // 2. Увімкнули ×2 — шматок став удвічі меншим за сторінку.
        focus.setOn(true)
        focus.setZoom(2)
        wait(untilTrue: { false }, seconds: 0.2)
        let half = state.media.shownStill
        lines.append("×2: \(half.map { "\($0.width)×\($0.height)" } ?? "немає"), сторінка ціла: \(state.media.still?.width == picture.width ? "так" : "ні")")
        if let half {
            if abs(Double(half.width) - Double(picture.width) / 2) > 2 { faults.append("×2 дало шматок \(half.width) замість \(picture.width / 2)") }
        } else {
            faults.append("при наближенні в зал не пішло нічого")
        }
        if state.media.still?.width != picture.width { faults.append("наближення зіпсувало саму сторінку") }

        // 3. Натиснули по живому екрану в лівому верхньому куті — вікно
        // наближення поїхало туди.
        let rect = row.mirror.frameRect
        if rect.width > 0 {
            row.mirror.pressForCheck(at: CGPoint(x: rect.minX + rect.width * 0.1,
                                                 y: rect.maxY - rect.height * 0.1))
            row.mirror.releaseForCheck()
            let window = focus.rect
            lines.append(String(format: "після натискання в куток: вікно %.2f %.2f", window.minX, window.minY))
            if window.minX > 0.2 || window.minY > 0.2 {
                faults.append("натискання в лівий верхній кут не пересунуло наближення туди")
            }
        } else {
            lines.append("живого екрана немає — натискання не перевіряли")
        }

        // 4. «У центр» повертає погляд на середину.
        focus.center()
        let centred = focus.rect
        if abs(centred.midX - 0.5) > 0.01 || abs(centred.midY - 0.5) > 0.01 {
            faults.append("«У центр» не повернув погляд на середину")
        }

        // 5. Смуга наближення в ряду веде ті самі значення.
        row.focusBar.setForCheck(zoom: 3)
        lines.append(String(format: "смуга: ×%.1f, у моделі ×%.1f", row.focusBar.chosenForCheck.zoom, focus.look.zoom))
        if abs(focus.look.zoom - 3) > 0.01 { faults.append("повзунок смуги не дійшов до наближення") }

        // 6. Вимкнули — у зал знову вся сторінка.
        focus.setOn(false)
        wait(untilTrue: { false }, seconds: 0.2)
        if state.media.shownStill?.width != picture.width {
            faults.append("після вимкнення наближення сторінка не повернулася цілою")
        }
        lines.append("після вимкнення: \(state.media.shownStill.map { "\($0.width)×\($0.height)" } ?? "немає")")

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}
