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
    /// `envelope` — гучність дихає, як у музиці: хвиля на панелі тоді має
    /// обриси, а не суцільну смугу.
    static func makeWave(seconds: Double, in folder: URL, envelope: Bool = false) -> URL? {
        let rate = 44_100
        let count = Int(Double(rate) * seconds)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let loudness = envelope ? 0.2 + 0.8 * abs(sin(2 * Double.pi * 0.4 * t)) * (0.6 + 0.4 * abs(sin(2 * Double.pi * 3.1 * t))) : 1
            let sample = Int16(sin(2 * Double.pi * 440 * t) * 6000 * loudness)
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
        backing.close()
        let music = folder.appendingPathComponent("музика")
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        checks.append(contentsOf: backingPanelChecks(state: state,
                                                     wave: makeWave(seconds: 20, in: music, envelope: true) ?? wave,
                                                     folder: folder))
        return checks
    }

    /// Власник: «размер высоты плейлиста должен регулироваться и весь блок
    /// по ширине тоже». Тягнемо обидві межі вкладки «Медіа» так, як тягне
    /// миша, і міряємо, що панель і стовпець справді змінилися й
    /// запам'яталися; наприкінці повертаємо як було.
    static func backingGripCheck(state: AppState) -> Check {
        let area = "Фонограма"
        let name = "Висоту фонограм і ширину блоку тягнуть мишею"
        let workspace = NativeMediaWorkspace.shared
        workspace.attach(state: state)
        let defaults = UserDefaults.standard
        let saved = ["backingPanelHeight", "mediaListWidth"].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }
        let host = workspace.superview
        let wasFrame = workspace.frame
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820))
        window.contentView = holder
        workspace.removeFromSuperview()
        holder.addSubview(workspace)
        workspace.frame = holder.bounds
        defer {
            workspace.removeFromSuperview()
            if let host { host.addSubview(workspace); workspace.frame = wasFrame; workspace.needsLayout = true }
            window.contentView = nil
        }
        defaults.removeObject(forKey: "backingPanelHeight")
        defaults.removeObject(forKey: "mediaListWidth")
        workspace.layoutSubtreeIfNeeded()
        guard let bar = workspace.subviews.compactMap({ $0 as? NativeBackingTrackBar }).first else {
            return Check(area: area, name: name, status: .failed, detail: "панелі фонограм у вкладці немає")
        }
        let barBefore = bar.frame.height
        let listBefore = bar.list.frame.height
        workspace.heightGrip.onDrag?(-60)
        workspace.layoutSubtreeIfNeeded()
        let grew = bar.frame.height - barBefore
        let listGrew = bar.list.frame.height - listBefore
        let remembered = defaults.object(forKey: "backingPanelHeight") != nil
        workspace.heightGrip.onDrag?(5000)
        workspace.layoutSubtreeIfNeeded()
        let floorOK = abs(bar.frame.height - NativeBackingTrackBar.minimumHeight) < 1
        let widthBefore = bar.frame.width
        workspace.grip.onDrag?(80)
        workspace.layoutSubtreeIfNeeded()
        let widened = bar.frame.width - widthBefore
        workspace.grip.onDrag?(-5000)
        workspace.layoutSubtreeIfNeeded()
        let narrowOK = abs(bar.frame.width - NativeMediaWorkspace.minimumListWidth) < 1
        workspace.heightGrip.onReset?()
        workspace.layoutSubtreeIfNeeded()
        let resetOK = defaults.object(forKey: "backingPanelHeight") == nil && abs(bar.frame.height - barBefore) < 1
        let ok = abs(grew - 60) < 1 && abs(listGrew - 60) < 1 && remembered && floorOK && abs(widened - 80) < 1 && narrowOK && resetOK
        return Check(area: area, name: name, status: ok ? .ok : .failed,
                     detail: String(format: "угору на 60 → панель +%.0f, її список +%.0f, запам'ятано: %@; униз до упору → найменша %@; "
                                        + "ширина +80 → +%.0f; вужче до упору → %.0f (межа %.0f); подвійне клацання → як було: %@",
                                    grew, listGrew, remembered ? "так" : "ні", floorOK ? "так" : "ні",
                                    widened, bar.frame.width, NativeMediaWorkspace.minimumListWidth, resetOK ? "так" : "ні"))
    }

    /// Список фонограм, хвиля, пік-метр і кнопки панелі.
    ///
    /// Власник: «для блока фонограмм нет своего плейлиста, а при
    /// перетягивании… она добавляется в общий плейлист медиа» і далі — «пик
    /// метр и графический просмотр трека (как в audacity)… играть с
    /// указанного пользователем места. Добавить кнопку паузы».
    static func backingPanelChecks(state: AppState, wave: URL, folder: URL) -> [Check] {
        let area = "Фонограма"
        var checks: [Check] = []
        let backing = state.backing
        let media = state.media
        let wasBacking = backing.playlist
        let wasMedia = media.playlist
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = NativeBackingTrackBar(player: backing)
        bar.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        window.contentView = bar
        defer {
            backing.close()
            backing.putBackPlaylist(wasBacking)
            window.contentView = nil
        }
        backing.close()
        backing.putBackPlaylist([])

        // 1. Свій список: звук, кинутий на панель, — у фонограмах, не в плеєрі.
        let movie = folder.appendingPathComponent("ролик.mp4")
        let picture = folder.appendingPathComponent("заставка.jpg")
        let tookVideo = bar.accept(urls: [movie, picture])
        let tookWave = bar.accept(urls: [wave, movie])
        wait(untilTrue: { backing.url == wave }, seconds: 2)
        let separate = !tookVideo && tookWave && backing.playlist == [wave] && media.playlist == wasMedia
            && backing.url == wave && !backing.isPlaying
        checks.append(Check(area: area, name: "Фонограми мають свій список, окремий від списку плеєра",
                            status: separate ? .ok : .failed,
                            detail: "ролик і картинка на панель: \(tookVideo ? "УЗЯТО" : "не взято"); звук: \(tookWave ? "узято" : "НЕ ВЗЯТО"); "
                                + "у фонограмах \(backing.playlist.count), у плеєрі було \(wasMedia.count) — стало \(media.playlist.count); "
                                + "перший відкрито без гри: \(backing.url == wave && !backing.isPlaying ? "так" : "ні")"))

        // 2. Хвиля будується й доходить до панелі.
        wait(untilTrue: { backing.waveform?.url == wave }, seconds: 10)
        wait(untilTrue: { false }, seconds: 0.2)
        bar.layoutSubtreeIfNeeded()
        let form = backing.waveform
        let expectedPeak: Float = 6000 / 32768
        let formOK = form.map { $0.maxs.count == 2048 && abs($0.peak - expectedPeak) < 0.03 } ?? false
            && bar.waveformView.waveform?.url == wave
        checks.append(Check(area: area, name: "Хвиля треку будується, як в Audacity",
                            status: formOK ? .ok : .failed,
                            detail: form.map { String(format: "відрізків %d, пік %.3f (чекали %.3f), на панелі: %@",
                                                      $0.maxs.count, $0.peak, expectedPeak,
                                                      bar.waveformView.waveform?.url == wave ? "так" : "ні") }
                                ?? "хвиля не побудувалася за 10 с"))

        // 3. Клацання по хвилі — грати з цього місця.
        let wasVolume = backing.volume
        backing.volume = 0.05
        bar.waveformView.clickForCheck(at: 0.5)
        wait(untilTrue: { backing.isPlaying && backing.livePosition > 10 }, seconds: 3)
        let clickedAt = backing.livePosition
        let seekOK = backing.isPlaying && abs(clickedAt - 10) < 1.5
        checks.append(Check(area: area, name: "Клацання по хвилі грає з вибраного місця",
                            status: seekOK ? .ok : .failed,
                            detail: String(format: "клацнули на середині 20-секундного треку: грає %@, позиція %.1f с",
                                           backing.isPlaying ? "так" : "НІ", clickedAt)))

        // 4. Пік-метр оживає під звуком.
        backing.volume = 0.8
        _ = backing.levels.take()
        wait(untilTrue: { (bar.meter.decibelsForCheck.max() ?? -100) > -40 }, seconds: 3)
        let loudest = bar.meter.decibelsForCheck.max() ?? -100
        checks.append(Check(area: area, name: "Пік-метр показує рівень фонограми",
                            status: loudest > -40 ? .ok : .failed,
                            detail: String(format: "найвищий рівень на індикаторі %.1f дБ (синус 0,18 — очікуємо близько −15…−25)", loudest)))
        backing.volume = wasVolume

        // 5. Окремі кнопки «Грати», «Пауза», «Стоп».
        wait(untilTrue: { bar.pauseButton.isEnabled }, seconds: 1)
        bar.pauseButton.performClick(nil)
        wait(untilTrue: { !backing.isPlaying && bar.playButton.isEnabled }, seconds: 1)
        let pausedAt = backing.position
        let paused = !backing.isPlaying && pausedAt > 9
        let pauseDisabled = !bar.pauseButton.isEnabled
        bar.playButton.performClick(nil)
        wait(untilTrue: { backing.isPlaying }, seconds: 1)
        let resumed = backing.isPlaying && backing.livePosition >= pausedAt - 0.1
        bar.stopButton.performClick(nil)
        wait(untilTrue: { !backing.isPlaying }, seconds: 1)
        let stopped = !backing.isPlaying && backing.position == 0
        checks.append(Check(area: area, name: "Кнопки «Грати», «Пауза», «Стоп»",
                            status: paused && pauseDisabled && resumed && stopped ? .ok : .failed,
                            detail: String(format: "пауза: %@ (на %.1f с, кнопка паузи вимкнулась: %@); грати далі: %@; стоп на початок: %@",
                                           paused ? "так" : "ні", pausedAt, pauseDisabled ? "так" : "ні",
                                           resumed ? "так" : "ні", stopped ? "так" : "ні")))
        // Тон: крок 0,5, межі, і звук при цьому йде.
        backing.setPitch(0)
        backing.shiftPitch(by: BackingTrackPlayer.pitchStep)
        let halfUp = backing.pitchTones == 0.5 && backing.appliedPitchCents == 100
        bar.toneDown.performClick(nil)
        bar.toneDown.performClick(nil)
        let halfDown = backing.pitchTones == -0.5 && backing.appliedPitchCents == -100
        for _ in 0..<20 { backing.shiftPitch(by: -BackingTrackPlayer.pitchStep) }
        wait(untilTrue: { !bar.toneDown.isEnabled }, seconds: 1)
        let floorOK = backing.pitchTones == -BackingTrackPlayer.pitchLimit && !bar.toneDown.isEnabled
        bar.toneLabel.performClick(nil)
        let resetOK = backing.pitchTones == 0 && backing.appliedPitchCents == 0
        backing.shiftPitch(by: 1)
        bar.playButton.performClick(nil)
        let before = backing.livePosition
        wait(untilTrue: { backing.livePosition > before + 0.5 }, seconds: 3)
        let pitchedPlays = backing.isPlaying && backing.livePosition > before + 0.4
        backing.stop()
        backing.setPitch(0)
        checks.append(Check(area: area, name: "Тон фонограми: крок 0,5, межі ±3, звук іде",
                            status: halfUp && halfDown && floorOK && resetOK && pitchedPlays ? .ok : .failed,
                            detail: "+0,5 → 100 центів: \(halfUp ? "так" : "ні"); кнопкою двічі вниз → −0,5: \(halfDown ? "так" : "ні"); "
                                + "нижче −3 не йде: \(floorOK ? "так" : "ні"); клацання по «Тон» → 0: \(resetOK ? "так" : "ні"); "
                                + "на +1 тон грає, позиція біжить: \(pitchedPlays ? "так" : "ні")"))
        backing.shiftPitch(by: 0.5)
        wait(untilTrue: { false }, seconds: 0.2)
        bar.layoutSubtreeIfNeeded()
        if let shot = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: shot)
            if let png = shot.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: NSString(string: "~/Library/Logs/slovo-фонограма-панель.png").expandingTildeInPath))
            }
        }

        backing.setPitch(0)

        // «Далі»: доіграла — пішла наступна зі списку.
        let chain = folder.appendingPathComponent("ланцюжок")
        let chainSecond = chain.appendingPathComponent("2")
        try? FileManager.default.createDirectory(at: chainSecond, withIntermediateDirectories: true)
        if let one = makeWave(seconds: 1, in: chain), let two = makeWave(seconds: 3, in: chainSecond) {
            let wasNext = backing.playsNext
            backing.close()
            backing.putBackPlaylist([])
            backing.addToPlaylist([one, two])
            bar.nextButton.performClick(nil)
            let switchedOn = backing.playsNext
            backing.volume = 0.05
            backing.openFromPlaylist(at: 0)
            backing.play()
            wait(untilTrue: { backing.url == two && backing.isPlaying }, seconds: 5)
            let advanced = backing.url == two && backing.isPlaying && backing.playlistIndex == 1
            backing.stop()
            bar.nextButton.performClick(nil)
            backing.openFromPlaylist(at: 0)
            backing.play()
            wait(untilTrue: { !backing.isPlaying }, seconds: 4)
            let stayed = backing.url == one && !backing.isPlaying
            backing.playsNext = wasNext
            backing.volume = wasVolume
            checks.append(Check(area: area, name: "Кнопка «Після кінця — наступна» грає список далі",
                                status: switchedOn && advanced && stayed ? .ok : .failed,
                                detail: "кнопка вмикає: \(switchedOn ? "так" : "ні"); секундний трек доіграв — пішов другий: \(advanced ? "так" : "НІ"); "
                                    + "без кнопки після кінця зупинилося на першому: \(stayed ? "так" : "НІ")"))
        }

        // Висоту панелі фонограм і ширину всього блоку тягнуть мишею.
        checks.append(backingGripCheck(state: state))

        // 6. Список і відкрита фонограма переживають перезапуск.
        let second = folder.appendingPathComponent("друга")
        try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let suiteName = "slovo.check.backing.\(UUID().uuidString)"
        var memoryOK = false
        var memoryDetail = "другий файл не зібрався"
        if let wave2 = makeWave(seconds: 3, in: second), let suite = UserDefaults(suiteName: suiteName) {
            let first = BackingTrackPlayer()
            first.store = suite
            first.remembers = true
            first.addToPlaylist([wave, wave2])
            first.openFromPlaylist(at: 1)
            first.close()
            first.openFromPlaylist(at: 1)
            let again = BackingTrackPlayer()
            again.store = suite
            again.remembers = true
            again.restore()
            first.setPitch(-1)
            let againPitch = BackingTrackPlayer()
            againPitch.store = suite
            againPitch.remembers = true
            againPitch.restore()
            let pitchRemembered = againPitch.pitchTones == -1
            againPitch.close()
            memoryOK = again.playlist == [wave, wave2] && again.url == wave2 && again.playlistIndex == 1 && pitchRemembered
            memoryDetail = "після «перезапуску» у списку \(again.playlist.count) з 2, відкрито \(again.url?.deletingPathExtension().lastPathComponent ?? "нічого") (пункт \(again.playlistIndex.map { String($0 + 1) } ?? "—")); тон −1 для файлу запам'ятався: \(pitchRemembered ? "так" : "ні")"
            // Прибрати зайве: пункт 2 зі списку — закриває відкрите.
            again.removeFromPlaylist(at: 1)
            memoryOK = memoryOK && again.url == nil && again.playlist == [wave]
            memoryDetail += "; прибрали відкритий — закрився: \(again.url == nil ? "так" : "ні")"
            first.close()
            again.close()
            suite.removePersistentDomain(forName: suiteName)
        }
        checks.append(Check(area: area, name: "Список фонограм пам'ятається між запусками",
                            status: memoryOK ? .ok : .failed, detail: memoryDetail))
        return checks
    }
}
