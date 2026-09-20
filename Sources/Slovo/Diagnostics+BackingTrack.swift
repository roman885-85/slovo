import AppKit
import AVFoundation
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
        checks.append(songsBackingShot(state: state))
        checks.append(contentsOf: backingPanelChecks(state: state,
                                                     wave: makeWave(seconds: 20, in: music, envelope: true) ?? wave,
                                                     folder: folder))
        checks.append(backingFallbackCheck(wave: wave, folder: music))
        return checks
    }

    /// Власник 16.09.2026: «блок фонограм перенести в песни, поместить над
    /// закладками названий песенников и сделать на всю длину окна, с
    /// возможностью растягивания по высоте». Тягнемо межу так, як тягне миша,
    /// і міряємо: панель на всю ширину, стоїть останньою (під нею — сама
    /// смуга закладок), висота міняється, пам'ятається й вертається.
    static func backingGripCheck(state: AppState) -> Check {
        let area = "Фонограма"
        let name = "Фонограма в піснях: на всю ширину, висота тягнеться"
        NativeSongsWorkspace.shared.attach(state: state)
        guard let root = NativeSongsWorkspace.shared.rootForCheck else {
            return Check(area: area, name: name, status: .failed, detail: "робочої області пісень немає")
        }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "backingPanelHeight")
        // Ширину списку теж беремо на час перевірки: збережене число з
        // минулого разу перетворювало широку раскладку на вузьку.
        let savedWidth = defaults.object(forKey: "backingListWidth")
        defaults.removeObject(forKey: "backingListWidth")
        defer {
            defaults.set(saved, forKey: "backingPanelHeight")
            if let savedWidth { defaults.set(savedWidth, forKey: "backingListWidth") }
            else { defaults.removeObject(forKey: "backingListWidth") }
        }
        let host = root.superview
        let wasFrame = root.frame
        // Вид малюється лише у вікні: знімок із голої підставки виходив
        // білим аркушем. Тому — те саме віконце за краєм екрана, що й скрізь.
        root.removeFromSuperview()
        let window = bench(for: root, size: NSSize(width: 1200, height: 820))
        defer {
            window.contentView = nil
            root.removeFromSuperview()
            if let host { host.addSubview(root); root.frame = wasFrame; root.needsLayout = true }
            window.orderOut(nil)
        }
        defaults.removeObject(forKey: "backingPanelHeight")
        // Без цього раскладка лишалася від збереженої висоти (підставка вже
        // розклала область), і «як було» міряли від чужого числа.
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        guard let bar = root.subviews.compactMap({ $0 as? NativeBackingTrackBar }).first else {
            return Check(area: area, name: name, status: .failed, detail: "панелі фонограм у піснях немає")
        }
        var faults: [String] = []
        // На всю ширину вікна й останньою знизу: під нею вже смуга закладок.
        if abs(bar.frame.width - root.bounds.width) > 1 { faults.append("не на всю ширину: \(Int(bar.frame.width)) з \(Int(root.bounds.width))") }
        if abs(bar.frame.maxY - root.bounds.height) > 1 { faults.append("не в самому низу області") }
        let columns = root.subviews.first { $0 !== bar && $0.frame.height > 100 }
        if let columns, columns.frame.maxY > bar.frame.minY { faults.append("стовпці залазять на панель") }
        // Широка раскладка: список ліворуч, картка треку праворуч від нього.
        bar.layoutSubtreeIfNeeded()
        if bar.list.frame.maxX > bar.frame.width * 0.55 {
            faults.append(String(format: "список зайняв усю ширину — раскладка не широка (список до %.0f, панель %.0f×%.0f)",
                                 bar.list.frame.maxX, bar.frame.width, bar.frame.height))
        }
        // Власник: «полоса громкости слишком длинная» — смуга сталої ширини.
        if let slider = bar.subviews.compactMap({ $0 as? NSSlider }).first,
           slider.frame.width > NativeBackingTrackBar.volumeWidth + 0.5 {
            faults.append("смуга гучності завдовжки \(Int(slider.frame.width)) — довша за \(Int(NativeBackingTrackBar.volumeWidth))")
        }

        let barBefore = bar.frame.height
        let listBefore = bar.list.frame.height
        root.heightGrip.onDrag?(-60)
        root.layoutSubtreeIfNeeded()
        let grew = bar.frame.height - barBefore
        let listGrew = bar.list.frame.height - listBefore
        let remembered = defaults.object(forKey: "backingPanelHeight") != nil
        if abs(grew - 60) > 1 { faults.append(String(format: "угору на 60 — панель змінилася на %.0f", grew)) }
        if abs(listGrew - 60) > 1 { faults.append(String(format: "список змінився на %.0f", listGrew)) }
        if !remembered { faults.append("висоту не запам'ятано") }
        // Власник: «блок с фонограммами невозможно сжать до одной строки» і
        // «при схлопывании плеера минусовок, полоса прокрутки должна
        // остаться». Тягнемо донизу до упору: панель стає смужкою, у якій
        // лишаються кнопки, назва, час, смуга перемотування й гучність.
        root.heightGrip.onDrag?(5000)
        root.layoutSubtreeIfNeeded()
        if abs(bar.frame.height - NativeBackingTrackBar.collapsedHeight) > 6 {
            faults.append(String(format: "униз до упору — %.0f замість %.0f",
                                 bar.frame.height, NativeBackingTrackBar.collapsedHeight))
        }
        if bar.waveformView.isHidden { faults.append("у стиснутій смужці немає смуги перемотування") }
        // Знімок смужки: на ньому видно, що саме лишилося в один ряд.
        NativeTrace.snapshot(bar, to: "slovo-фонограма-смужка.png")
        if bar.playButton.isHidden { faults.append("у стиснутій смужці немає кнопки «грати»") }
        if !bar.list.isHidden { faults.append("у стиснутій смужці лишився список") }
        // І назад: нижня межа тягне так само, тільки навпаки.
        root.bottomGrip.onDrag?(300)
        root.layoutSubtreeIfNeeded()
        if bar.frame.height < NativeBackingTrackBar.minimumHeight - 1 {
            faults.append(String(format: "нижня межа не повернула панель: %.0f", bar.frame.height))
        }
        if bar.list.isHidden { faults.append("після повернення список не з'явився") }
        root.heightGrip.onReset?()
        root.layoutSubtreeIfNeeded()
        if defaults.object(forKey: "backingPanelHeight") != nil || abs(bar.frame.height - barBefore) > 1 {
            faults.append(String(format: "подвійне клацання не вернуло як було: %.0f замість %.0f, ключ %@, область %.0f×%.0f",
                                 bar.frame.height, barBefore,
                                 defaults.object(forKey: "backingPanelHeight") == nil ? "стерто" : "лишився",
                                 root.bounds.width, root.bounds.height))
        }

        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                        ? String(format: "ширина %.0f (уся область), угору на 60 → панель і її список +60, запам'ятано; униз до упору → смужка %.0f зі смугою перемотування; нижня межа повертає; подвійне клацання → як було",
                                 bar.frame.width, NativeBackingTrackBar.collapsedHeight)
                        : faults.joined(separator: "; "))
    }

    /// Знімок справжнього вікна на вкладці «Пісні»: очима видно те, чого не
    /// видно числами, — чи стоїть панель над закладками пісенників і чи не
    /// порожня вона. Знімаємо саме вікно: вид, вийнятий у підставку, у
    /// знімок не малюється (шари), і виходив білий аркуш.
    static func songsBackingShot(state: AppState) -> Check {
        let area = "Фонограма"
        let name = "Знімок вкладки «Пісні» з панеллю фонограм"
        let wasMode = state.mode
        state.mode = .songs
        Signals.shared.send(.mode)
        wait(untilTrue: { false }, seconds: 0.6)
        defer {
            state.mode = wasMode
            Signals.shared.send(.mode)
        }
        guard let content = NativeMainWindowController.shared.window?.contentView else {
            return Check(area: area, name: name, status: .skipped, detail: "головного вікна немає")
        }
        content.layoutSubtreeIfNeeded()
        let saved = snapshot(content, to: "slovo-пісні-фонограма.png")
        let bar = NativeSongsWorkspace.shared.rootForCheck?.subviews.compactMap { $0 as? NativeBackingTrackBar }.first
        let placed = bar.map { $0.window === NativeMainWindowController.shared.window && $0.frame.width > 400 } ?? false
        return Check(area: area, name: name, status: saved && placed ? .ok : .failed,
                     detail: saved ? (placed ? "знімок ~/Library/Logs/slovo-пісні-фонограма.png; панель у вікні, ширина \(Int(bar?.frame.width ?? 0))"
                                             : "панель не стала у вікно")
                                   : "знімок не записався")
    }

    /// Запасні шляхи відкриття: файл, який `AVAudioFile` не бере, має
    /// відкритися розкодуванням засобами системи. Власник: «иногда программа
    /// не воспроизводит файл минуса, несмотря на известный формат mp3».
    static func backingFallbackCheck(wave: URL, folder: URL) -> Check {
        let area = "Фонограма"
        let name = "Файл, якого не бере звичайний шлях, відкривається обхідним"
        // Робимо «важкий» випадок: той самий звук під чужим розширенням.
        let odd = folder.appendingPathComponent("минусовка.mp3")
        try? FileManager.default.removeItem(at: odd)
        try? FileManager.default.copyItem(at: wave, to: odd)
        let direct = (try? AVAudioFile(forReading: odd)) != nil
        guard let ready = BackingTrackPlayer.decoded(odd) else {
            return Check(area: area, name: name,
                         status: direct ? .ok : .failed,
                         detail: direct
                            ? "звичайний шлях упорався сам — обхідний не знадобився"
                            : "обхідний шлях не дав файла")
        }
        let opened = try? AVAudioFile(forReading: ready)
        let frames = opened?.length ?? 0
        return Check(area: area, name: name,
                     status: frames > 0 ? .ok : .failed,
                     detail: "розкодовано в \(ready.lastPathComponent), кадрів \(frames)"
                        + (direct ? "; звичайний шлях теж брав цей файл" : "; звичайний шлях не брав"))
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
        // Панель тепер стоїть на всю ширину вікна — і міряємо її такою.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = NativeBackingTrackBar(player: backing)
        bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 260)
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
        //
        // Міряємо ДВА числа: що бачить відвід звуку й що показує смуга. Поки
        // друге було саме по собі, не було видно, де губиться рівень —
        // у звуці чи в смузі; тепер це видно з одного рядка звіту.
        backing.volume = 0.8
        _ = backing.levels.take()
        backing.levels.resetLoudestForCheck()
        wait(untilTrue: { (bar.meter.decibelsForCheck.max() ?? -100) > -40 }, seconds: 3)
        let loudest = bar.meter.decibelsForCheck.max() ?? -100
        let tapped = backing.levels.loudestForCheck
        let tappedDecibels = tapped > 0 ? 20 * log10(tapped) : -100
        checks.append(Check(area: area, name: "Пік-метр показує рівень фонограми",
                            status: loudest > -40 ? .ok : .failed,
                            detail: String(format: "найвищий рівень на індикаторі %.1f дБ; у відводі звуку %.3f (%.1f дБ); "
                                            + "синус 0,18 при гучності 0,8 дає 0,117 (−18,6 дБ)",
                                           loudest, tapped, tappedDecibels)))

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
        checks.append(meterSmoothnessCheck(bar: bar, backing: backing, folder: folder))
        return checks
    }

    /// Власник 16.09.2026: «пик метр более сделай мягким и плавным». На рівному
    /// тоні смуга стоїть рівно — не смикається між порціями звуку (досі між
    /// ними приходив нуль, і вона падала й підскакувала); після паузи
    /// опускається поступово, а не падає на дно за кадр.
    static func meterSmoothnessCheck(bar: NativeBackingTrackBar, backing: BackingTrackPlayer, folder: URL) -> Check {
        let area = "Фонограма"
        let name = "Пік-метр м'який і плавний"
        let steadyFolder = folder.appendingPathComponent("рівний")
        try? FileManager.default.createDirectory(at: steadyFolder, withIntermediateDirectories: true)
        guard let steady = makeWave(seconds: 6, in: steadyFolder) else {
            return Check(area: area, name: name, status: .skipped, detail: "не вдалося зробити пробний тон")
        }
        let wasVolume = backing.volume
        defer { backing.stop(); backing.volume = wasVolume }
        backing.close()
        backing.putBackPlaylist([])
        _ = bar.accept(urls: [steady])
        wait(untilTrue: { backing.url == steady }, seconds: 2)
        backing.volume = 0.8
        backing.play()
        wait(untilTrue: { backing.isPlaying }, seconds: 1)
        // Звук іде не з першої миті, а м'який підйом займає частку секунди:
        // міряємо рівність, коли смуга вже піднялася, а не сам підйом.
        wait(untilTrue: { (bar.meter.decibelsForCheck.max() ?? -48) > -40 }, seconds: 3)
        wait(untilTrue: { false }, seconds: 0.8)
        var samples: [(time: TimeInterval, level: Float)] = []
        for _ in 0..<60 {
            wait(untilTrue: { false }, seconds: 1.0 / 60)
            samples.append((ProcessInfo.processInfo.systemUptime, bar.meter.decibelsForCheck.max() ?? -48))
        }
        // Скільки смуга має право пройти між двома кадрами.
        //
        // Раніше тут стояло глухе «0,5 дБ», і перевірка падала на живій,
        // справній смузі: стала підйому індикатора — 0,07 с, тобто за кадр
        // (1/60 с) він законно проходить п'яту частину розриву до цілі, а
        // ціль між порціями звуку сповзає на 6 дБ/с. Тому міряємо не сталим
        // числом, а часом: 1,2 дБ на звичайний кадр і пропорційно більше,
        // якщо головний потік стояв довше. Смикання, заради якого перевірка
        // й писалася (смуга падала на дно між порціями), давало десятки
        // децибел і не пролізе.
        var stalls = 0
        var jitter: Float = 0
        var allowed: Float = 1.2
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let gap = next.time - previous.time
            if gap > 0.1 { stalls += 1; continue }
            let step = abs(next.level - previous.level)
            let limit = Float(max(1, gap / (1.0 / 60))) * 1.2
            if step > limit { jitter = max(jitter, step); allowed = min(allowed, limit) }
        }
        let level = samples.last?.level ?? -48
        let engineWasRunning = backing.engineRunningForCheck
        let pausedAt = ProcessInfo.processInfo.systemUptime
        backing.pause()
        wait(untilTrue: { false }, seconds: 0.1)
        let afterPause = bar.meter.decibelsForCheck.max() ?? -48
        let elapsed = ProcessInfo.processInfo.systemUptime - pausedAt
        wait(untilTrue: { bar.meter.isQuiet }, seconds: 3)
        let settled = bar.meter.isQuiet
        let falls = level - afterPause
        // Скільки впала б смуга зі сталою 0,2 с за той самий час: плавний спад
        // повільніший. Час міряємо, а не беремо «0,1 с» на віру — під
        // навантаженням пауза перевірки буває вдвічі довшою.
        let sharp = Double(level + 48) * (1 - exp(-elapsed / 0.2))
        let ok = level > -40 && jitter == 0 && falls > 0.3 && Double(falls) < sharp && settled
        return Check(area: area, name: name, status: ok ? .ok : .failed,
                     detail: String(format: "рівний тон: рівень %.1f дБ, зайвих стрибків між кадрами: "
                                        + (jitter == 0 ? "немає" : String(format: "%.2f дБ понад межу %.2f", jitter, allowed))
                                        + " (пауз потоку пропущено: \(stalls)); "
                                        + "за %.2f с після паузи опустився на %.1f дБ (різкий спад дав би %.1f); опустився до кінця: %@; двигун звуку крутився: %@",
                                    level, elapsed, falls, sharp, settled ? "так" : "ні", engineWasRunning ? "так" : "НІ"))
    }
}
