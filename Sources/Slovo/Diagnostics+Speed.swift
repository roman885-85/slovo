import AppKit
import SlovoCore

/// Замір відгуку на рух повзунків і на зміну вірша — у мілісекундах.
///
/// Власник: «плохая оптимизация скорости всего рабочего меню и настроек,
/// ползунки работают с фризами». Сперечатися про це словами не можна: міряємо
/// кожен рух так, як його відчуває людина, — від виклику до того, як
/// вікно домалювалося і відкладене на цикл подій дороблено. Медіана по
/// десятку рухів, щоб перше прогрівання не псувало картину.
extension Diagnostics {

    static func speedSection(state: AppState) -> [Check] {
        var lines: [String] = []
        var slow: [String] = []

        /// Медіана часу одного «руху» разом із домальовуванням вікон.
        func median(_ repeats: Int, _ body: () -> Void) -> Double {
            var samples: [Double] = []
            for _ in 0..<repeats {
                let started = DispatchTime.now().uptimeNanoseconds
                body()
                // Відкладене на чергу й цикл подій — частина того самого
                // руху: полотно залу перемальовується саме так.
                for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date()) }
                for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            samples.sort()
            return samples[samples.count / 2]
        }
        func note(_ name: String, _ ms: Double, limit: Double) {
            lines.append(String(format: "%@ — %.1f мс", name, ms))
            if ms > limit { slow.append(String(format: "%@ %.0f мс (поріг %.0f)", name, ms, limit)) }
        }

        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            state.mode = wasMode
            Signals.shared.send(.mode)
            state.isLive = wasLive
        }
        state.mode = .bible
        Signals.shared.send(.mode)
        wait(untilTrue: { false }, seconds: 0.3)

        // 1. Зміна вірша — увесь ланцюжок: слайд, попередній перегляд, зал, мережа.
        var step = 1
        note("зміна вірша (передпоказ)", median(20) {
            state.stepVerse(by: step, live: false)
            step = -step
        }, limit: 40)
        state.isLive = true
        note("зміна вірша з показом у залі", median(20) {
            state.stepVerse(by: step, live: true)
            step = -step
        }, limit: 60)

        // 2. Живе застосування вікна «Параметри» — те, що йде за кожним
        // рухом його повзунків із затримкою в чверть секунди.
        note("живе застосування налаштувань", median(10) {
            state.applyProgramOptions(SettingsStore.shared.settings.options)
        }, limit: 40)

        // 3. Кадр попереднього перегляду у вікні «Параметри» — малюється своїм
        // малювальником на кожну зміну стану.
        let renderer = SlideFrameRenderer(size: CGSize(width: 560, height: 315))
        let first = state.slide
        state.stepVerse(by: 1, live: false)
        let second = state.slide
        var flip = false
        note("кадр передпоказу налаштувань", median(10) {
            flip.toggle()
            _ = renderer.snapshot(slide: flip ? first : second, style: state.previewStyle,
                                  preset: state.preset(for: .preview), texts: state.previewTexts,
                                  backgroundOverride: state.backgroundOverride,
                                  imageURL: { state.presetImageURL($0) })
        }, limit: 40)

        // 4. Повзунок прозорості в Конструкторі — справжній повзунок
        // справжньої панелі, через той самий приймач дій, що й миша.
        let constructor = NativeSlideConstructor(state: state, onClose: {})
        let stand = bench(for: constructor, size: NSSize(width: 1240, height: 780))
        wait(untilTrue: { false }, seconds: 0.5)
        if let slider = firstSlider(in: constructor, maxValue: 255) {
            var value = 200.0
            note("Конструктор: повзунок прозорості", median(10) {
                value = value == 200 ? 255 : 200
                slider.doubleValue = value
                NativeForm.Trampoline.shared.fire(slider)
            }, limit: 50)
        } else {
            lines.append("Конструктор: повзунок прозорості не знайшовся")
        }
        stand.orderOut(nil)
        state.previewPreset(nil)

        // 5. Повзунок кегля списків — перечитує всі списки вікна. Тут і
        // далі підписники міряються поіменно: одне число винуватця не назве.
        Signals.shared.profiling = true
        var size = 13.0
        note("повзунок кегля списків", median(6) {
            size = size == 13 ? 14 : 13
            state.listFontSize = size
            NativeBibleBridge.shared.sync()
        }, limit: 80)
        state.listFontSize = 13
        NativeBibleBridge.shared.sync()
        lines.append("кегль, винуватці: " + Signals.shared.slowReport())
        Signals.shared.profiling = false

        // 6. Перемикання вкладки — тим самим шляхом, що натискання на вкладку.
        Signals.shared.profiling = true
        var toSongs = true
        note("перемикання вкладки Біблія ↔ Пісні", median(6) {
            state.mode = toSongs ? .songs : .bible
            NativeBibleBridge.shared.sync()
            toSongs.toggle()
        }, limit: 80)
        lines.append("вкладка, винуватці: " + Signals.shared.slowReport())
        Signals.shared.profiling = false

        return [Check(area: "Швидкість", name: "Відгук на рух — медіани",
                      status: slow.isEmpty ? .ok : .warning,
                      detail: (slow.isEmpty ? "" : "повільно: " + slow.joined(separator: "; ") + ". ")
                          + lines.joined(separator: "; "))]
    }

    /// Довгий прогін двох найважчих дій — під `sample` ззовні.
    ///
    /// Замір каже «260 мс», але не каже, де. Профіль процесу знімає
    /// системна утиліта `sample`, а їй треба, щоб дія тривала секунди:
    /// крутимо кегль списків і вкладки по вісім секунд кожне.
    static func profileSection(state: AppState) -> [Check] {
        let wasMode = state.mode
        defer {
            state.mode = wasMode
            NativeBibleBridge.shared.sync()
        }
        func spin(seconds: Double, _ body: () -> Void) -> Int {
            let until = Date().addingTimeInterval(seconds)
            var count = 0
            while Date() < until {
                body()
                for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date()) }
                for window in NSApp.windows where window.isVisible { window.displayIfNeeded() }
                count += 1
            }
            return count
        }
        state.mode = .bible
        NativeBibleBridge.shared.sync()
        var size = 13.0
        NativeTrace.say("профіль: кегль — старт")
        let fontTicks = spin(seconds: 8) {
            size = size == 13 ? 14 : 13
            state.listFontSize = size
            NativeBibleBridge.shared.sync()
        }
        state.listFontSize = 13
        NativeBibleBridge.shared.sync()
        NativeTrace.say("профіль: вкладки — старт")
        var toSongs = true
        let tabTicks = spin(seconds: 8) {
            state.mode = toSongs ? .songs : .bible
            NativeBibleBridge.shared.sync()
            toSongs.toggle()
        }
        return [Check(area: "Профіль", name: "Довгий прогін під sample", status: .ok,
                      detail: "кегль: \(fontTicks) рухів за 8 с; вкладки: \(tabTicks) перемикань за 8 с")]
    }

    /// Перший повзунок із такою межею в дереві видів.
    private static func firstSlider(in view: NSView, maxValue: Double) -> NSSlider? {
        if let slider = view as? NSSlider, abs(slider.maxValue - maxValue) < 0.5 { return slider }
        for child in view.subviews {
            if let found = firstSlider(in: child, maxValue: maxValue) { return found }
        }
        return nil
    }
}
