import AppKit
import IOSurface
import SlovoCore

/// Захоплення екрана: список джерел, показ монітора в зал і в NDI,
/// наближення до ділянки.
extension Diagnostics {

    static func screenSection(state: AppState) -> [Check] {
        captureSection(state: state) + yieldSection(state: state) + legacySection(state: state)
    }

    /// Той самий показ, але старим двигуном — тим, який працює на macOS 11
    /// і 12. Власник: «захват экрана работает только начиная с 13 macos, а
    /// нужно с 11».
    ///
    /// Перевірити його інакше нічим: розробка йде на свіжій системі, де
    /// завжди вибирається новий спосіб, і код для Big Sur лишався б
    /// написаним наосліп. Тому на час перевірки старий двигун вмикається
    /// примусово — і питається те саме, що й у нового: чи є список, чи йдуть
    /// кадри, чи доходять вони до залу.
    private static func legacySection(state: AppState) -> [Check] {
        let area = "Екран"
        let name = "Старий двигун (macOS 11 і 12): список, кадри, зал"
        let capture = state.screenCapture
        let wasMode = state.mode, wasLive = state.isLive
        ScreenCaptureModel.forcesLegacy = true
        defer {
            state.stopCapturedScreen()
            ScreenCaptureModel.forcesLegacy = false
            state.mode = wasMode
            state.isLive = wasLive
        }

        var listed = false
        Task { @MainActor in
            await capture.reload()
            listed = true
        }
        wait(untilTrue: { listed }, seconds: 15)
        guard !capture.needsPermission else {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "немає дозволу «Запис екрана»")]
        }
        var faults: [String] = []
        var lines: [String] = ["двигун: \(capture.usesLegacyEngine ? "старий" : "новий")",
                               "джерел: \(capture.sources.count)"]
        if !capture.usesLegacyEngine { faults.append("не вдалося ввімкнути старий двигун") }
        guard let display = capture.sources.first(where: { $0.kind == .display }) else {
            return [Check(area: area, name: name, status: .skipped, detail: "монітора в списку немає")]
        }
        // Вікно теж має бути в списку: на старих системах їх дає інший
        // засіб, ніж монітори, і мовчазний порожній список — звична біда.
        if !capture.sources.contains(where: { $0.kind == .window }) {
            faults.append("жодного вікна в списку — на старій системі це означало б порожню вкладку")
        }

        state.mode = .screen
        state.isLive = true
        state.showCapturedScreen(display)
        wait(untilTrue: { capture.frameCount > 2 }, seconds: 8)
        lines.append("кадрів за показ: \(capture.frameCount), у залі: \(state.media.isVideoOnScreen ? "так" : "ні")")
        if capture.frameCount == 0 { faults.append("старий двигун не дав жодного кадру") }
        if !state.media.isVideoOnScreen { faults.append("кадр старого двигуна не вважається кадром у залі") }

        // Наближення на старому двигуні має працювати так само.
        let before = capture.frameCount
        SlideFocus.shared.setOn(true)
        SlideFocus.shared.setZoom(2)
        wait(untilTrue: { capture.frameCount > before }, seconds: 5)
        lines.append("із наближенням кадрів: +\(capture.frameCount - before)")
        if capture.frameCount <= before { faults.append("з наближенням кадри старого двигуна стали") }
        SlideFocus.shared.setOn(false)

        state.stopCapturedScreen()
        wait(untilTrue: { !capture.isRunning }, seconds: 3)
        if capture.isRunning { faults.append("старий двигун не зупинився") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + lines.joined(separator: "; "))]
    }

    /// Показане замість захоплення не має затиратися кадрами екрана.
    ///
    /// Власник: «если открыть захват экрана, выполнить вывод захвата, потом
    /// закрыть, то презентации и изображения вместо показа своих слайдов
    /// выдают захват экрана». «Закрити» для людини — це піти зі вкладки, а
    /// потік захоплення від цього не зупинявся й далі сипав кадри в ті самі
    /// шари. На знімку цього не спіймати: сторінка встигає лягти й через мить
    /// зникає під наступним кадром екрана.
    ///
    /// Тому дивимося не на вигляд, а на те, що лежить у шарі приймача через
    /// секунду після показу картинки: якщо там картинка — захоплення
    /// поступилося, якщо кадр екрана — ні.
    private static func yieldSection(state: AppState) -> [Check] {
        let area = "Екран"
        let name = "Показане замінює захоплення, а не ховається під ним"
        let capture = state.screenCapture
        guard let picture = makePicture(width: 640, height: 360) else {
            return [Check(area: area, name: name, status: .skipped, detail: "пробна картинка не зібралася")]
        }
        let wasMode = state.mode, wasLive = state.isLive
        let layer = CALayer()
        state.media.attach(layer)
        defer {
            state.media.detach(layer)
            state.stopCapturedScreen()
            state.media.showStill(nil)
            state.mode = wasMode
            state.isLive = wasLive
        }

        var listed = false
        Task { @MainActor in
            await capture.reload()
            listed = true
        }
        wait(untilTrue: { listed }, seconds: 15)
        if capture.needsPermission {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "немає дозволу «Запис екрана» — дайте його в системних налаштуваннях "
                              + "і повторіть перевірку")]
        }
        guard let display = capture.sources.first(where: { $0.kind == .display }) else {
            return [Check(area: area, name: name, status: .skipped, detail: "монітора в списку немає")]
        }

        var faults: [String] = []
        var lines: [String] = []

        state.mode = .screen
        state.showCapturedScreen(display)
        wait(untilTrue: { capture.frameCount > 2 }, seconds: 6)
        lines.append("захоплення: кадрів \(capture.frameCount), у шарі \(layer.contents == nil ? "порожньо" : "кадр")")
        guard capture.frameCount > 0 else {
            return [Check(area: area, name: name, status: .skipped, detail: "кадри захоплення не пішли")]
        }

        // Головне: людина не тисне «Сховати», а просто йде показувати
        // сторінку. Вкладку міняємо, кнопку не чіпаємо.
        state.mode = .pictures
        state.media.showStill(picture, title: "перевірка")
        let after = capture.frameCount
        wait(untilTrue: { false }, seconds: 1)

        lines.append("після показу картинки: захоплення \(capture.isRunning ? "йде" : "стоїть")"
            + ", плеєр вважає захоплення \(state.media.isCapturing ? "показаним" : "знятим")"
            + ", кадрів за секунду +\(capture.frameCount - after)")
        if state.media.isCapturing { faults.append("плеєр досі вважає екран показаним") }
        if capture.isRunning { faults.append("потік захоплення не зупинився") }

        // Те, що лежить у шарі приймача, і є те, що бачить зал.
        // Кадр екрана лягає в шар як `IOSurface`, показана картинка — як
        // `CGImage`. Питаємо саме це: що за річ зараз у шарі і якого вона
        // розміру. Розмір теж важить — картинка 640×360, а монітор більший.
        var what = "порожньо"
        var isPicture = false
        if let shown = layer.contents {
            let kind = CFGetTypeID(shown as CFTypeRef)
            if kind == CGImage.typeID {
                let image = unsafeBitCast(shown as AnyObject, to: CGImage.self)
                isPicture = image.width == picture.width && image.height == picture.height
                what = "картинка \(image.width)×\(image.height)"
            } else if kind == IOSurfaceGetTypeID() {
                what = "кадр екрана (IOSurface)"
            } else {
                what = "щось інше"
            }
        }
        lines.append("у шарі: " + what)
        if !isPicture { faults.append("у залі стоїть не показана картинка, а \(what)") }
        if state.media.shownStill == nil { faults.append("картинка не дійшла до виводів зовсім") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + lines.joined(separator: "; "))]
    }

    private static func captureSection(state: AppState) -> [Check] {
        let area = "Екран"
        let name = "Захоплення екрана: список, показ у зал, наближення"
        let capture = state.screenCapture
        let wasMode = state.mode, wasLive = state.isLive
        let wasFocus = SlideFocus.shared.isOn
        defer {
            state.stopCapturedScreen()
            SlideFocus.shared.setOn(wasFocus)
            state.mode = wasMode
            state.isLive = wasLive
        }

        var faults: [String] = []
        var lines: [String] = []

        // 1. Список джерел. Без дозволу на запис екрана він порожній — це не
        // поломка програми, а незаданий дозвіл, і сказати про це треба
        // словами, а не «помилкою».
        var done = false
        Task { @MainActor in
            await capture.reload()
            done = true
        }
        wait(untilTrue: { done }, seconds: 15)
        lines.append("джерел: \(capture.sources.count); \(capture.state.prefix(80))")
        if capture.needsPermission {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "немає дозволу «Запис екрана» — дайте його в системних налаштуваннях "
                              + "і повторіть перевірку")]
        }
        if capture.sources.isEmpty {
            return [Check(area: area, name: name, status: .skipped, detail: "система не назвала жодного джерела")]
        }
        guard let display = capture.sources.first(where: { $0.kind == .display }) else {
            return [Check(area: area, name: name, status: .skipped, detail: "монітора в списку немає")]
        }

        // 2. Показ монітора: кадри йдуть, плеєр вважає їх кадром у залі.
        state.mode = .screen
        // Питаємо справжній лічильник каналу, а не той, що доїжджає до вікна
        // головною чергою: перевірка сама сидить у головній черзі, і той
        // лічильник під час перевірки просто стоїть.
        let ndiBefore = state.ndi.sentFramesNow
        state.showCapturedScreen(display)
        wait(untilTrue: { capture.frameCount > 2 }, seconds: 6)
        lines.append("кадрів за показ: \(capture.frameCount), у залі: \(state.media.isVideoOnScreen ? "так" : "ні")")
        if capture.frameCount == 0 { faults.append("кадри захоплення не пішли") }
        if !state.media.isVideoOnScreen { faults.append("захоплений екран не вважається кадром у залі") }
        if !state.media.hasMedia { faults.append("плеєр не бачить захоплення показаним") }

        // 3. Наближення: кадр іде далі, розмір той самий — приймач NDI не
        // любить, коли розмір стрибає.
        SlideFocus.shared.setOn(true)
        SlideFocus.shared.setZoom(2)
        let beforeZoom = capture.frameCount
        wait(untilTrue: { capture.frameCount > beforeZoom + 2 }, seconds: 5)
        lines.append("із наближенням кадрів: +\(capture.frameCount - beforeZoom)")
        if capture.frameCount <= beforeZoom { faults.append("з наближенням кадри перестали йти") }
        SlideFocus.shared.setOn(false)

        // 4. Трансляція: канал узяв кадри захоплення.
        if state.ndi.isActive {
            wait(untilTrue: { state.ndi.sentFramesNow > ndiBefore }, seconds: 3)
            lines.append("NDI: кадрів +\(state.ndi.sentFramesNow - ndiBefore)")
            if state.ndi.sentFramesNow <= ndiBefore { faults.append("захоплення не дійшло до трансляції") }
        }

        // 5. «Сховати» знімає захоплення повністю.
        state.stopCapturedScreen()
        wait(untilTrue: { !capture.isRunning }, seconds: 3)
        lines.append("після зупинки: захоплення \(capture.isRunning ? "йде" : "стоїть"), у залі \(state.media.isVideoOnScreen ? "є" : "немає")")
        if capture.isRunning { faults.append("захоплення не зупинилося") }
        if state.media.isVideoOnScreen { faults.append("після зупинки кадр лишився в залі") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}
