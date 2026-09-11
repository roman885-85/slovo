import AppKit
import SlovoCore

/// Розміри кадру у двох додаткових джерелах NDI — по одному заміру на кожен
/// розмір, який людині пропонує вікно налаштувань.
///
/// Власник: «ndi hx работает только звук, ndi wifi работает только с низким
/// разрешением, при увеличении до 720 уже не работает». Слова «не работает»
/// самі по собі нічого не кажуть про те, де саме обривається дорога: кадр
/// може не закодуватися, не піти в мережу або не дійти до приймача. Тому тут
/// на кожен розмір ставиться свій приймач і рахується, що до нього дійшло.
extension Diagnostics {

    static func ndiSizesSection(state: AppState) -> [Check] {
        let area = "NDI розміри"
        guard state.outputs[.ndi].isEnabled else {
            return [Check(area: area, name: "Розміри кадру в додаткових джерелах",
                          status: .skipped, detail: "канал NDI вимкнено")]
        }
        // Додаткові джерела живуть на такті насоса основного каналу: поки
        // канал не пущено, ані відправника, ані кадрів у них не буде — і
        // замір показав би «не працює» там, де просто нічого не показують.
        let wasActive = state.ndi.isActive
        let wasLive = state.isLive
        let wasMode = state.mode
        if !wasActive {
            state.setNDIEnabled(true)
            wait(untilTrue: { state.ndi.isActive }, seconds: 10)
        }
        // У залі має стояти щось видиме: на порожньому екрані всі пікселі
        // однакові, і «картинки немає» сказало б про пробу, а не про канал.
        state.mode = .pictures
        state.isLive = true
        if let picture = makePicture(width: 1280, height: 720) {
            state.media.showStill(picture, title: "перевірка")
        }
        wait(untilTrue: { state.ndi.sentFramesNow > 0 }, seconds: 6)
        defer {
            state.media.showStill(nil)
            state.isLive = wasLive
            state.mode = wasMode
            if !wasActive { state.setNDIEnabled(false) }
        }
        guard state.ndi.isActive else {
            return [Check(area: area, name: "Розміри кадру в додаткових джерелах",
                          status: .skipped, detail: "канал NDI не піднявся")]
        }

        var checks: [Check] = []
        checks.append(contentsOf: wifiSizes(area: area, state: state))
        return checks
    }

    /// Джерело «Слово Wi-Fi» на всіх трьох розмірах вікна налаштувань.
    private static func wifiSizes(area: String, state: AppState) -> [Check] {
        let was = (SettingsStore.shared.settings.options.ndiWiFiEnabled ?? false,
                   SettingsStore.shared.settings.options.ndiWiFiHeight ?? 360,
                   SettingsStore.shared.settings.options.ndiWiFiFrameRate ?? 15)
        defer { state.ndi.setWiFi(enabled: was.0, height: was.1, fps: was.2) }

        var lines: [String] = []
        var faults: [String] = []
        for height in [270, 360, 540, 720] {
            state.ndi.setWiFi(enabled: true, height: height, fps: 15)
            wait(untilTrue: { false }, seconds: 2)
            var result: NDIRuntime.ProbeResult?
            DispatchQueue.global(qos: .userInitiated).async {
                let probe = NDIRuntime.probe(sourceContaining: "Слово Wi-Fi", seconds: 4)
                DispatchQueue.main.async { result = probe }
            }
            wait(untilTrue: { result != nil }, seconds: 14)
            let got = result ?? NDIRuntime.ProbeResult()
            lines.append("\(height)p: кадрів \(got.video)"
                + (got.video > 0 ? " (\(got.videoWidth)×\(got.videoHeight), \(fourCCText(got.videoFourCC)), розкид \(got.videoSpread))" : "")
                + ", відправлено \(state.ndi.wifi.sent)"
                + (got.found ? "" : ", джерела не знайдено"))
            if got.video == 0 { faults.append("на \(height)p приймач не отримав жодного кадру") }
            else if got.videoSpread == 0 { faults.append("на \(height)p кадр прийшов, а картинки в ньому немає") }
        }
        return [Check(area: area, name: "«Слово Wi-Fi»: кадр доходить на кожному розмірі",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + lines.joined(separator: "; "))]
    }

    /// Чотири літери формату — так, як їх пише NDI: молодшим байтом уперед.
    static func fourCCText(_ value: UInt32) -> String {
        guard value != 0 else { return "немає" }
        var text = ""
        for shift in [0, 8, 16, 24] {
            let byte = UInt8((value >> UInt32(shift)) & 0xFF)
            text.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "?")
        }
        return text
    }
}
