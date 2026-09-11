import AppKit
import CoreGraphics
import SlovoCore

/// Зауваження 15: «аудио останавливается при переходе на слайды; нужен
/// независимый аудиоплеер для минусовок».
///
/// Мінусовка на служінні грає ПІД слайдами: вірш, куплет, картинка,
/// зміна вкладки — а звук іде. Перевіряємо саме це на звуковому файлі без
/// відео: відкрили, заграло, далі робимо все, що робить оператор, і
/// після кожного кроку звук мусить грати, а файл — лишатися відкритим.
extension Diagnostics {

    /// Короткий WAV із синусом: 44,1 кГц, моно, 16 біт. Власноруч, без
    /// кодеків — щоб перевірка не залежала ні від чого на машині.
    static func makeWave(seconds: Double, in folder: URL) -> URL? {
        let rate = 44_100
        let count = Int(Double(rate) * seconds)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let sample = Int16(sin(2 * Double.pi * 440 * Double(i) / Double(rate)) * 6000)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm.count)); data.append(pcm)
        let url = folder.appendingPathComponent("минусовка.wav")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    static func backingTrackSection(state: AppState) -> [Check] {
        let area = "Фонограма"
        let name = "Звук грає під слайдами, віршами, картинкою і зміною вкладки"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-фонограмма-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let wave = makeWave(seconds: 20, in: folder) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний звуковий файл")]
        }
        guard let picture = solidImage(red: 120) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний кадр")]
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        let wasVolume = media.volume
        let wasPlaylist = media.playlist
        defer {
            media.close()
            media.showStill(nil)
            // Пробні файли до списку плеєра не мають потрапити назавжди:
            // список переживає запуск, і після перевірки в ньому лишалися
            // «минусовка.wav» і «slovo-проба-…», яких уже немає на диску.
            media.clearPlaylist()
            media.putBackPlaylist(wasPlaylist)
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.volume = wasVolume
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
            Signals.shared.send(.mode)
        }

        media.autoPlay = true
        media.isMuted = false
        media.volume = 0.02
        state.mode = .media
        media.open(wave)
        wait(untilTrue: { media.isPlaying && media.mediaURL == wave }, seconds: 8)
        guard media.isPlaying else {
            return [Check(area: area, name: name, status: .failed, detail: "звуковий файл не заграв")]
        }
        var faults: [String] = []
        var steps: [String] = []
        func settle() { wait(untilTrue: { false }, seconds: 0.5) }
        func expect(_ step: String) {
            let playing = media.isPlaying
            let opened = media.mediaURL == wave
            steps.append("\(step): грає \(playing ? "так" : "НІ"), файл \(opened ? "відкрито" : "ЗАКРИТО")")
            if !playing || !opened { faults.append(step) }
        }
        if media.fileHasVideo { faults.append("файл прийнято як відео, а він звуковий") }

        // 1. Вірш у зал поверх звуку.
        state.mode = .bible
        Signals.shared.send(.mode)
        state.showCurrent()
        settle(); expect("вірш у зал")

        // 2. Гортання вірша в зал (стрілка/пульт).
        state.stepVerse(by: 1, live: true)
        settle(); expect("наступний вірш у зал")

        // 3. Картинка в зал.
        state.mode = .pictures
        Signals.shared.send(.mode)
        media.showStill(picture, title: "перевірка")
        state.isLive = true
        settle(); expect("картинка в зал")

        // 4. Зміна вкладки на Пісні й назад на Медіа.
        state.mode = .songs
        Signals.shared.send(.mode)
        settle(); expect("вкладка Пісні")
        state.mode = .media
        Signals.shared.send(.mode)
        settle(); expect("вкладка Медіа")

        // 5. «Сховати» показ — звук не чіпає.
        state.isLive = false
        settle(); expect("показ сховано")

        var checks = [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : "звук перервався на: " + faults.joined(separator: ", ") + ". ")
                                + steps.joined(separator: " | "))]

        // Незалежний програвач: мінусовка грає, поки в основному плеєрі
        // відкривають і закривають фільм.
        let backing = state.backing
        defer { backing.close() }
        var second: [String] = []
        var secondFaults: [String] = []
        media.close()
        backing.open(wave)
        backing.play()
        wait(untilTrue: { backing.isPlaying && backing.position > 0.2 }, seconds: 6)
        second.append("фонограма пішла: \(backing.isPlaying ? "так" : "НІ"), позиція \(String(format: "%.1f", backing.position)) с")
        if !backing.isPlaying { secondFaults.append("фонограма не заграла") }
        if let movie = makeMovie(withSound: true) {
            defer { try? FileManager.default.removeItem(at: movie) }
            media.open(movie)
            wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)
            let before = backing.position
            wait(untilTrue: { false }, seconds: 0.8)
            let stillGoes = backing.isPlaying && backing.position > before
            second.append("фільм у плеєрі йде: \(media.isPlaying ? "так" : "ні"); фонограма при цьому \(stillGoes ? "грає" : "СТАЛА")")
            if !stillGoes { secondFaults.append("відкриття фільму в плеєрі зупинило фонограму") }
            media.close()
            wait(untilTrue: { false }, seconds: 0.5)
            if !backing.isPlaying { secondFaults.append("закриття фільму зупинило фонограму") }
        } else {
            second.append("пробний фільм не зібрався — крок із плеєром пропущено")
        }
        backing.pause()
        let paused = !backing.isPlaying
        backing.play()
        wait(untilTrue: { false }, seconds: 0.4)
        second.append("пауза/продовження: \(paused && backing.isPlaying ? "работают" : "НЕ РАБОТАЮТ")")
        if !(paused && backing.isPlaying) { secondFaults.append("пауза або продовження не спрацювали") }
        backing.seek(to: 5)
        wait(untilTrue: { false }, seconds: 0.4)
        second.append(String(format: "перемотування на 5 с: позиція %.1f с", backing.position))
        if abs(backing.position - 5) > 1.5 { secondFaults.append("перемотування не влучило") }
        backing.stop()
        checks.append(Check(area: area, name: "Фонограма незалежна від плеєра: фільм відкрито й закрито, а вона грає",
                            status: secondFaults.isEmpty ? .ok : .failed,
                            detail: (secondFaults.isEmpty ? "" : secondFaults.joined(separator: "; ") + ". ") + second.joined(separator: " | ")))
        return checks
    }
}
