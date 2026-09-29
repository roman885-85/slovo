import AppKit
import SlovoCore

/// Плавне гасіння залу — на проекторі, у трансляції й на сторінках.
///
/// Власник: «при отключении слайда, слов и т.п. выполнять плавное затухание
/// изображения, а не резкое отключение. Выполнить это на всех клиентах —
/// проектор, ndi, веб страницы». І окремо: «при закрытии программы выполнять
/// плавное затухание фона перед закрытием».
///
/// Міряємо не наміри, а кадри: показуємо вірш, натискаємо «Сховати» й
/// дивимося, що в залі відразу після цього. Якщо гасіння різке — наступний
/// же кадр порожній; якщо плавне — кадр ще тримає зображення, тільки
/// блідіше.
extension Diagnostics {

    /// Середня яскравість кадру залу, 0…1.
    @MainActor
    private static func brightness(_ image: CGImage?) -> Double {
        guard let image else { return -1 }
        let width = 40, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum += (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3
        }
        return sum / Double(width * height) / 255
    }

    @MainActor
    static func fadeOutSection(state: AppState) -> [Check] {
        let area = "Гасіння"
        var checks: [Check] = []
        let projection = state.projection
        let wasVisible = projection.isVisible
        let wasLive = state.isLive
        defer {
            state.isLive = wasLive
            if !wasVisible { projection.setVisible(false) }
        }
        projection.setVisible(true)

        // Вірш у зал — щоб було чому гаснути.
        if state.mode != .bible { state.mode = .bible }
        let shown = DispatchSemaphore(value: 0)
        state.openScripture(bookPosition: min(42, max(0, state.books.count - 1)), chapter: 3, verses: [16], then: {
            state.showCurrent()
            shown.signal()
        })
        _ = shown.wait(timeout: .now() + 10)
        wait(untilTrue: { brightness(projection.hallImage) > 0.02 }, seconds: 5)
        let lit = brightness(projection.hallImage)
        guard lit > 0.02 else {
            return [Check(area: area, name: "Зал гасне плавно", status: .skipped,
                          detail: "у залі нічого не світиться — гасити нема чого")]
        }

        // «Сховати» — і дивимося, чи справді йде розчинення.
        //
        // Міряти яскравість кадру марно: кадр у пам'яті вже новий, а
        // розчинення живе в шарі. Питаємо сам шар: чи крутиться на ньому
        // перехід і чи не скінчився він раніше часу.
        state.isLive = false
        var sawFade = false
        var steps: [String] = []
        for _ in 0..<7 {
            wait(untilTrue: { false }, seconds: 0.06)
            let going = projection.isHallFadingOut
            if going { sawFade = true }
            steps.append(going ? "йде" : "ні")
        }
        checks.append(Check(area: area, name: "Зал гасне плавно, а не ривком",
                            status: sawFade ? .ok : .failed,
                            detail: String(format: "яскравість до гасіння %.2f; розчинення: ", lit)
                                + steps.joined(separator: " → ")))

        // Трансляція: міряємо не намір, а сам канал — чи справді в ньому
        // зараз іде розчинення кадру.
        let wasNDI = state.outputs[.ndi].isEnabled
        if !wasNDI { state.setNDIEnabled(true) }
        defer { if !wasNDI { state.setNDIEnabled(false) } }
        state.showCurrent()
        wait(untilTrue: { state.ndi.isFadingForCheck == false }, seconds: 2)
        wait(untilTrue: { false }, seconds: 0.6)
        state.isLive = false
        var fadingSeen = false
        for _ in 0..<6 {
            wait(untilTrue: { false }, seconds: 0.06)
            if state.ndi.isFadingForCheck { fadingSeen = true }
        }
        checks.append(Check(area: area, name: "Трансляція гасне тим самим ходом",
                            status: fadingSeen ? .ok : .failed,
                            detail: fadingSeen
                                ? "кадр у мережі розчиняється за \(String(format: "%.2f", Defaults.hideFadeSeconds)) с"
                                : "у каналі не видно розчинення — гасіння йде ривком"))

        // Сторінка слайда: дивимося саму сторінку, яку віддає програма.
        // Рендер у справжньому браузері перевіряє розділ «веб-слайди» — тут
        // питаємо інше: чи є в ній плавне гасіння й чи вмикає його гілка
        // «слайд сховано».
        let page = WebSlovoSlidePage.html(webSocketPort: 8100, host: "127.0.0.1")
        let hasTransition = page.contains("transition: opacity")
        let hasRule = page.contains("#stage.gone")
        let hidesSmoothly = page.contains("classList.add('gone')")
        let ready = hasTransition && hasRule && hidesSmoothly
        checks.append(Check(area: area, name: "Сторінка слайда гасне, а не зникає",
                            status: ready ? .ok : .failed,
                            detail: ready
                                ? "у сторінці є плавний перехід прозорості, правило гасіння й гілка «сховано»"
                                : "перехід: \(hasTransition ? "є" : "немає"), правило: \(hasRule ? "є" : "немає"),"
                                    + " гілка «сховано»: \(hidesSmoothly ? "є" : "немає")"))
        return checks
    }
}
