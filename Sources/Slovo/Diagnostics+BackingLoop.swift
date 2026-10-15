import AppKit
import SlovoCore

/// Фонограма «по колу» і пауза посеред гри.
///
/// Власник 15.10: «при проигрывании фонограммы в режиме повторения, полоса
/// воспроизведения отсутствует, кнопки воспроизведения становятся не
/// активными». Перевіряємо саме друге й третє коло: позицію, смугу ходу,
/// напис часу, кнопки — і паузу посеред кола. Окремо — пауза без повтору:
/// після «Грати» трек має дограти рівно залишок, а не залишок двічі.
extension Diagnostics {

    static func backingLoopSection(state: AppState) -> [Check] {
        let area = "Фонограма"
        let name = "«По колу»: на кожному колі смуга йде, кнопки живі; пауза продовжує з місця"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-коло-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let length = 2.0
        guard let wave = makeWave(seconds: length, in: folder) else {
            return [Check(area: area, name: name, status: .skipped, detail: "пробна фонограма не зібралася")]
        }
        let backing = state.backing
        let wasList = backing.playlist, wasVolume = backing.volume
        let wasLoops = backing.loops, wasNext = backing.playsNext
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = NativeBackingTrackBar(player: backing)
        bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 260)
        window.contentView = bar
        defer {
            backing.stop()
            backing.close()
            backing.putBackPlaylist(wasList)
            backing.volume = wasVolume
            backing.loops = wasLoops
            backing.playsNext = wasNext
            window.contentView = nil
        }
        backing.close()
        backing.putBackPlaylist([])
        backing.addToPlaylist([wave])
        backing.volume = 0.05
        backing.playsNext = false
        backing.loops = false

        var faults: [String] = []
        var lines: [String] = []
        func settle(_ seconds: Double) { wait(untilTrue: { false }, seconds: seconds) }
        /// Рядок стану панелі: що грає, де позиція, смуга, напис, кнопки.
        func look(_ label: String) -> (position: Double, progress: Double) {
            let position = backing.livePosition
            let progress = bar.waveformView.progress
            lines.append(String(format: "%@: грає %@, позиція %.2f с, смуга %.0f %%, напис «%@», кнопки — грати %@, пауза %@, стоп %@",
                                label, backing.isPlaying ? "так" : "ні", position, progress * 100,
                                bar.timeTextForCheck,
                                bar.playButton.isEnabled ? "є" : "—", bar.pauseButton.isEnabled ? "є" : "—",
                                bar.stopButton.isEnabled ? "є" : "—"))
            return (position, progress)
        }
        /// Посеред кола: грає, позиція не впирається в кінець, смуга не повна,
        /// пауза й стоп доступні.
        func expectMidLap(_ label: String, near expected: Double) {
            let seen = look(label)
            let good = backing.isPlaying && abs(seen.position - expected) < 0.6
                && seen.progress < 0.95 && bar.pauseButton.isEnabled && bar.stopButton.isEnabled
            if !good { faults.append(label) }
        }

        // 1. «По колу» натиснуто рукою, грає з початку.
        bar.clickLoopForCheck()
        bar.playButton.performClick(nil)
        wait(untilTrue: { backing.isPlaying }, seconds: 1)
        let started = Date()
        func at(_ seconds: Double) { settle(max(0, seconds - Date().timeIntervalSince(started))) }
        lines.append("«по колу» натиснуто: \(backing.loops ? "так" : "НІ")")
        if !backing.loops { faults.append("кнопка «по колу» не ввімкнула повтор") }

        at(0.5)
        backing.levels.resetSilentForCheck()
        at(1.0)
        expectMidLap("перше коло, 1 с", near: 1.0)
        at(length + 1.0)
        expectMidLap("друге коло, 1 с", near: 1.0)
        at(2 * length + 1.0)
        expectMidLap("третє коло, 1 с", near: 1.0)
        // Між 0,5 с і цією миттю — два стики кіл. Тиша у відводі за цей час
        // і є щілина між колами (у синусі без пауз тиші майже немає).
        let gap = Double(backing.levels.silentFramesForCheck) / 2 / 44_100 * 1000
        lines.append(String(format: "щілина на стику кіл: %.0f мс", gap))

        // 2. Пауза посеред кола і «Грати» — далі з того самого місця.
        bar.pauseButton.performClick(nil)
        let pausedAt = backing.position
        let pausedOK = !backing.isPlaying && bar.playButton.isEnabled && abs(pausedAt - 1.0) < 0.6
        lines.append(String(format: "пауза на третьому колі: позиція %.2f с, «Грати» %@", pausedAt, bar.playButton.isEnabled ? "є" : "—"))
        if !pausedOK { faults.append("пауза посеред кола") }
        bar.playButton.performClick(nil)
        let resumed = Date()
        settle(0.3)
        let afterResume = look("після «Грати», 0,3 с")
        let expectedAfter = pausedAt + Date().timeIntervalSince(resumed)
        if !(backing.isPlaying && abs(afterResume.position - expectedAfter) < 0.35) {
            faults.append(String(format: "після паузи позиція %.2f замість %.2f", afterResume.position, expectedAfter))
        }
        // Слідом — наступне коло, як і мало бути.
        let lapStart = Date()
        wait(untilTrue: { backing.livePosition < 0.5 && Date().timeIntervalSince(lapStart) > 0.2 }, seconds: length + 1)
        settle(0.6)
        expectMidLap("коло після паузи, ~0,6 с", near: 0.6)

        // 3. Вимкнули «по колу» посеред кола — трек дограє й зупиниться.
        bar.clickLoopForCheck()
        wait(untilTrue: { !backing.isPlaying }, seconds: length + 1)
        // Панель оновлюється наступним ходом головної черги — дати їй його.
        settle(0.3)
        let stoppedAtEnd = !backing.isPlaying && bar.playButton.isEnabled
        _ = look("«по колу» вимкнули — дограв")
        if !stoppedAtEnd { faults.append("без «по колу» трек не зупинився в кінці") }

        // 4. Без повтору: пауза на 0,8 с і «Грати» — дограє залишок, а не
        //    залишок двічі (старий відрізок у програвачі лишався після паузи).
        bar.stopButton.performClick(nil)
        bar.playButton.performClick(nil)
        wait(untilTrue: { backing.isPlaying }, seconds: 1)
        settle(0.8)
        bar.pauseButton.performClick(nil)
        let pausedPlain = backing.position
        bar.playButton.performClick(nil)
        let resumedPlain = Date()
        wait(untilTrue: { !backing.isPlaying }, seconds: 3 * length)
        let tail = Date().timeIntervalSince(resumedPlain)
        let expectedTail = length - pausedPlain
        lines.append(String(format: "без повтору: пауза на %.2f с, після «Грати» дограло за %.2f с (залишок %.2f с)",
                            pausedPlain, tail, expectedTail))
        if backing.isPlaying || tail > expectedTail + 0.5 || tail < expectedTail - 0.4 {
            faults.append(String(format: "після паузи дограло за %.2f с замість %.2f", tail, expectedTail))
        }

        // 5. «Грати» ще раз, поки грає (так шле пульт), — нічого не змінює:
        //    трек дограє в свій час, а не ще раз від місця натискання.
        bar.stopButton.performClick(nil)
        bar.playButton.performClick(nil)
        wait(untilTrue: { backing.isPlaying }, seconds: 1)
        settle(0.5)
        backing.play()
        let secondPress = Date()
        wait(untilTrue: { !backing.isPlaying }, seconds: 3 * length)
        let rest = Date().timeIntervalSince(secondPress)
        lines.append(String(format: "«грати» вдруге на 0,5 с, поки грає: дограло за %.2f с (залишок ~%.2f с)", rest, length - 0.5))
        if backing.isPlaying || rest > length - 0.5 + 0.5 {
            faults.append(String(format: "повторне «грати» подвоїло звук: дограло за %.2f с", rest))
        }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: lines.joined(separator: "; ")
                        + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: ", ")))]
    }
}
