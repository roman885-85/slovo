import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SlovoCore

/// Самопроверка того самого порядка действий, на котором владелец видел
/// путаницу:
///
/// «если после изображений переключиться на видео и добавить несколько
/// файлов, то начинается путаница с воспроизведением: то отображается
/// последнее изображение вместо видео, то видео не отображается на
/// проекторе, то в плеере воспроизводится, а на проекторе нет, то путает
/// очередность файлов».
///
/// Поэтому проверка идёт не по частям, а подряд, по живому состоянию
/// программы и настоящему окну слайда: картинка в зал → стих в зал → режим
/// «Медиа» → три файла разом → выбор третьего. Каждый шаг смотрит и на
/// плеер, и на проектор: «в плеере играет, а на проекторе нет» иначе не
/// поймать вовсе.
extension Diagnostics {

    static func mediaFlowSection(state: AppState) -> [Check] {
        let area = "Показ"
        let name = "Картинки → відео: плутанини немає"
        guard let picture = solidImage(red: 200) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний кадр")]
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-поток-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Имена нарочно не в том порядке, в каком файлы добавляются: список
        // обязан встать по именам, как в окне выбора.
        let movies = ["в.mov", "а.mov", "б.mov"].compactMap { makeMovie(named: $0, in: folder) }
        guard movies.count == 3 else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібралися пробні фільми")]
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasToScreen = media.videoToScreen
        let wasPlaylist = media.playlist
        let wasSuppression = media.screenSuppression
        defer {
            media.clearPlaylist()
            media.showStill(nil)
            media.putBackPlaylist(wasPlaylist)
            media.autoPlay = wasAutoPlay
            media.videoToScreen = wasToScreen
            media.screenSuppression = wasSuppression
            state.mode = wasMode
            state.isLive = wasLive
        }

        media.clearPlaylist()
        media.autoPlay = true
        media.videoToScreen = true
        media.screenSuppression = []

        var faults: [String] = []
        var story: [String] = []
        let fade = Defaults.mediaFadeSeconds

        // 1. Картинка в зал — как из режима «Изображения».
        state.mode = .pictures
        media.showStill(picture, title: "перевірка")
        state.isLive = true
        wait(untilTrue: { state.projection.isVideoShown }, seconds: fade + 1)
        if !state.projection.isVideoShown { faults.append("картинка не дійшла до проектора") }
        story.append("картинка в залі")

        // 2. Стих в зал — картинка обязана уйти.
        state.mode = .bible
        state.showCurrent()
        wait(untilTrue: { !state.projection.isVideoShown }, seconds: fade + 0.5)
        if state.projection.isVideoShown { faults.append("картинка лишилася поверх вірша") }
        story.append("вірш у залі")

        // 3. Режим «Медиа», три файла разом — как из окна выбора, где щёлкают
        //    вразнобой.
        state.mode = .media
        media.addToPlaylist([movies[0], movies[1], movies[2]])
        let order = media.playlist.map(\.lastPathComponent)
        if order != ["а.mov", "б.mov", "в.mov"] {
            faults.append("порядок списку: \(order.joined(separator: ", "))")
        }
        if media.mediaURL?.lastPathComponent != "а.mov" {
            faults.append("відкрився не перший за ім'ям, а \(media.mediaURL?.lastPathComponent ?? "ничего")")
        }
        story.append("список: \(order.joined(separator: ", "))")

        // 4. Автозапуск включён: фильм обязан пойти сам и дойти до проектора,
        //    а прежняя картинка — уйти из плеера совсем.
        wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)
        wait(untilTrue: { state.projection.isVideoShown }, seconds: fade + 2)
        wait(untilTrue: { state.projection.shownContents != nil }, seconds: 3)
        if media.still != nil { faults.append("картинка лишилася в плеєрі") }
        if !media.isPlaying { faults.append("фільм не пішов сам") }
        if !media.isVideoOnScreen {
            faults.append("правило виводу проти: \(describe(media.screenSuppression))")
        }
        if !state.projection.isVideoShown { faults.append("фільм не дійшов до проектора") }
        if let shown = state.projection.shownContents,
           (shown as AnyObject) === (picture as AnyObject) {
            faults.append("на проекторі попередня картинка замість фільму")
        }
        story.append("фільм на проекторі")

        // 5. Выбор третьего файла в списке — как двойным щелчком по строке.
        media.openFromPlaylist(at: 2)
        wait(untilTrue: { media.mediaURL?.lastPathComponent == "в.mov" && media.isPlaying }, seconds: 8)
        wait(untilTrue: { state.projection.isVideoShown }, seconds: fade + 2)
        if media.mediaURL?.lastPathComponent != "в.mov" {
            faults.append("вибір рядка відкрив \(media.mediaURL?.lastPathComponent ?? "ничего")")
        }
        if media.playlistIndex != 2 { faults.append("позначка рядка \(media.playlistIndex.map(String.init) ?? "немає")") }
        if !state.projection.isVideoShown { faults.append("після зміни файлу проектор згас") }
        story.append("третій файл у залі")

        // 6. И обратно: из фильма в картинку. Слой тот же, и застрявший кадр
        //    фильма вместо картинки — та же беда с другого конца.
        state.mode = .pictures
        media.showStill(picture, title: "перевірка")
        wait(untilTrue: { state.projection.isVideoShown }, seconds: fade + 2)
        if media.mediaURL != nil { faults.append("фільм не закрився під картинкою") }
        if let shown = state.projection.shownContents,
           (shown as AnyObject) !== (picture as AnyObject) {
            faults.append("на проекторі не картинка, а попередній кадр фільму")
        }
        if state.projection.shownContents == nil { faults.append("проектор порожній замість картинки") }
        story.append("картинка повернулася в зал")

        var checks = [Check(area: area, name: name,
                            status: faults.isEmpty ? .ok : .failed,
                            detail: faults.isEmpty ? story.joined(separator: " → ")
                                                   : faults.joined(separator: "; "))]
        checks.append(picturesStayOutOfPlaylist(folder: folder, movie: movies[0], picture: picture))
        return checks
    }

    /// Картинке и презентации в списке плеера не место: дорожки видео у них
    /// нет, открываются они пустотой, и на проекторе от этого ничего.
    private static func picturesStayOutOfPlaylist(folder: URL, movie: URL,
                                                  picture: CGImage) -> Check {
        let area = "Показ"
        let name = "Картинки до списку плеєра не потрапляють"
        let png = folder.appendingPathComponent("снимок.png")
        guard let destination = CGImageDestinationCreateWithURL(
            png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний файл")
        }
        CGImageDestinationAddImage(destination, picture, nil)
        CGImageDestinationFinalize(destination)
        let pdf = folder.appendingPathComponent("лист.pdf")
        let hasPDF = makePDF(at: pdf, pages: 1)

        let player = MediaPlayerModel()
        player.addToPlaylist(hasPDF ? [png, movie, pdf] : [png, movie])
        let names = player.playlist.map(\.lastPathComponent)
        player.clearPlaylist()

        return Check(area: area, name: name,
                     status: names == [movie.lastPathComponent] ? .ok : .failed,
                     detail: "у списку: " + (names.isEmpty ? "порожньо" : names.joined(separator: ", "))
                         + "; пропонували картинку, фільм" + (hasPDF ? " і PDF" : ""))
    }

    /// Что именно держит кадр вне зала — иначе «правило вывода против»
    /// ничего не объясняет.
    private static func describe(_ suppression: MediaPlayerModel.ScreenSuppression) -> String {
        var parts: [String] = []
        if suppression.contains(.blackout) { parts.append("затемнення") }
        if suppression.contains(.hiddenSlide) { parts.append("слайд сховано") }
        if suppression.contains(.blankSlide) { parts.append("порожній слайд") }
        if suppression.contains(.slideTookOver) { parts.append("зал зайнятий текстом") }
        return parts.isEmpty ? "ніщо не заважає" : parts.joined(separator: ", ")
    }
}

// MARK: - Остальные жалобы владельца по медиа

/// Проверки того, что владелец перечислил вслед за путаницей режимов:
/// презентация не должна оставаться в зале при переходе к тексту, кнопка
/// «Отображать видео на экране» обязана срабатывать с первого нажатия, а
/// появление и уход кадра — идти плавно, как он и просил.
extension Diagnostics {

    static func mediaComplaintsSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(presentationLeavesHall(state))
        checks.append(toScreenWorksAtOnce(state))
        checks.append(stillFades(state))
        checks.append(listSurvivesVanishedRow())
        checks.append(dropReachesWorkspace(state))
        checks.append(streamPlays(state))
        checks.append(youTubeLinksParse())
        checks.append(youTubePlays(state))
        checks.append(youTubeToolFound())
        checks.append(youTubeViaToolPlays(state))
        checks.append(youTubeRealToolFetches(state))
        checks.append(youTubeRemuxFallback(state))
        checks.append(decksSeparateFromPages(state))
        checks.append(wholeSongInPlan(state))
        checks.append(verseAfterStop(state))
        checks.append(slideFollowsTab(state))
        checks.append(transitionsRender(state))
        checks.append(transitionsPlayOnProjector(state))
        checks.append(servedPagesAreOurs(state))
        checks.append(seededPagesOverlay(state))
        checks.append(songGroupsListed(state))
        checks.append(projectionAboveMenuBar(state))
        checks.append(settingsApplyLive(state))
        checks.append(settingsLivePreview(state))
        checks.append(songPaletteLive(state))
        checks.append(contentsOf: webVideoStreams(state))
        checks.append(contentsOf: ndiLoadAndSound(state))
        checks.append(ndiAudioSelfCheck())
        checks.append(contentsOf: ndiLoopback(state))
        return checks
    }

    /// Наш код отправки звука — сам по себе: свой отправитель, свой
    /// приёмник, тридцать порций тона. Без плеера и без каналов вывода: если
    /// здесь звук не доходит, дело в нашей отправке, а не в цепочке.
    static func ndiAudioSelfCheck() -> Check {
        let area = "NDI"
        let name = "Наш код шле звук так, що приймач його чує"
        guard NDIRuntime.availability.isReady else {
            return Check(area: area, name: name, status: .skipped, detail: NDIRuntime.availability.summary)
        }
        guard let sender = NDIRuntime.makeSender(name: "Слово-звук") else {
            return Check(area: area, name: name, status: .failed, detail: "не створився пробний відправник")
        }
        let channels = 2, samples = 480, rate = 48_000
        var tone = [Float](repeating: 0, count: channels * samples)
        for channel in 0..<channels {
            for sample in 0..<samples { tone[channel * samples + sample] = sinf(Float(sample) * 0.05) * 0.2 }
        }
        let planar = tone.withUnsafeBytes { Data($0) }

        var result: NDIRuntime.ProbeResult?
        let sending = DispatchQueue(label: "slovo.selftest.audio")
        var keepSending = true
        sending.async {
            while keepSending {
                _ = sender.sendAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = NDIRuntime.probe(sourceContaining: "Слово-звук", seconds: 3, audioOnly: true)
            DispatchQueue.main.async { result = probe }
        }
        wait(untilTrue: { result != nil }, seconds: 12)
        keepSending = false
        sending.sync {}
        sender.close()
        let probe = result ?? NDIRuntime.ProbeResult()
        return Check(area: area, name: name,
                     status: probe.audio > 0 ? .ok : .failed,
                     detail: probe.found
                         ? "порцій звуку \(probe.audio), відліків \(probe.audioSamples), \(probe.audioRate) Гц, каналів \(probe.audioChannels), пік " + String(format: "%.2f", probe.audioPeak) + " (тон 0,2 с еталоном +20 дБ → близько 2,0)"
                         : "приймач не знайшов пробного джерела: \(probe.note)")
    }

    /// Свой приёмник NDI на этой же машине: доходит ли до него картинка и
    /// звук фильма, и как быстро — смена слайда.
    ///
    /// Владелец по Wi-Fi видит обрывы и не слышит звука, а проверить звук
    /// локально ему нечем. Приёмник в самопроверке отделяет наше от сети:
    /// если сюда доходит всё, дальше вопрос к каналу.
    private static func ndiLoopback(_ state: AppState) -> [Check] {
        let area = "NDI"
        let network = state.outputs[.ndi]
        guard network.isEnabled, state.ndi.isActive, NDIRuntime.availability.isReady else {
            return [Check(area: area, name: "Свій приймач отримує кадри і звук", status: .skipped,
                          detail: "трансляцію вимкнено або NDI не готовий")]
        }
        guard let movie = makeMovie(withSound: true) else {
            return [Check(area: area, name: "Свій приймач отримує кадри і звук", status: .skipped,
                          detail: "не зібрався пробний фільм зі звуком")]
        }
        defer { try? FileManager.default.removeItem(at: movie) }
        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        let wasVolume = media.volume
        let wasRepeats = media.repeats
        let wasToScreen = media.videoToScreen
        defer {
            media.close()
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.volume = wasVolume
            media.repeats = wasRepeats
            media.videoToScreen = wasToScreen
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }
        media.autoPlay = true
        media.isMuted = false
        media.volume = 0.05
        // «Відображати відео на екрані проектора» вмикаємо самі і повертаємо
        // назад. Без цього перевірка міряла не канал, а положення кнопки:
        // варто операторові вимкнути показ відео — і «канал віддав лише
        // п'ять кадрів», хоча канал у цьому не винен.
        media.videoToScreen = true
        // Пробный фильм — одна секунда; без повтора он кончается раньше
        // замера, и «дошло пять кадров» говорит лишь о том, что фильм давно
        // доиграл. С повтором меряется настоящая пропускная способность.
        media.repeats = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)

        // Приёмник живёт в фоне; главный поток крутит цикл событий — иначе
        // отправитель и плеер стоят.
        var filmResult: NDIRuntime.ProbeResult?
        let sentBefore = state.ndi.sentFramesNow
        let slowBefore = state.ndi.slowSendCount
        let convertedBefore = state.ndi.convertedFrameCount
        let droppedBefore = state.ndi.droppedFrameCount
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NDIRuntime.probe(sourceContaining: "Слово", seconds: 4)
            DispatchQueue.main.async { filmResult = result }
        }
        wait(untilTrue: { filmResult != nil }, seconds: 12)
        let film = filmResult ?? NDIRuntime.ProbeResult()
        let sentDuring = state.ndi.sentFramesNow - sentBefore
        let slowDuring = state.ndi.slowSendCount - slowBefore
        // Скільки кадрів фільму встигли перерахувати і скільки викинули, не
        // дочекавшись відправлення. Без цих двох чисел «дійшло п'ять кадрів»
        // не відрізнити від «фільм узагалі не дійшов до каналу».
        let convertedDuring = state.ndi.convertedFrameCount - convertedBefore
        let droppedDuring = state.ndi.droppedFrameCount - droppedBefore
        let onAirNow = NDIOutput.isVideoIdentity(state.ndi.channelIdentity)

        // Звук — отдельным приёмником: тот, что берёт и кадры 1080p, тонет
        // в них и теряет звук (так же ведёт себя чужой клиент на слабом
        // канале — владелец видел ровно это).
        var soundResult: NDIRuntime.ProbeResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NDIRuntime.probe(sourceContaining: "Слово", seconds: 3, audioOnly: true)
            DispatchQueue.main.async { soundResult = result }
        }
        wait(untilTrue: { soundResult != nil }, seconds: 10)
        let sound = soundResult ?? NDIRuntime.ProbeResult()

        // Уменьшенный поток — то, что клиент по Wi-Fi должен просить сам
        // («Low bandwidth»): проверяем, что наш источник его отдаёт.
        var lowResult: NDIRuntime.ProbeResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NDIRuntime.probe(sourceContaining: "Слово", seconds: 3, lowestBandwidth: true)
            DispatchQueue.main.async { lowResult = result }
        }
        wait(untilTrue: { lowResult != nil }, seconds: 10)
        let low = lowResult ?? NDIRuntime.ProbeResult()

        // Второй источник «Слово Wi-Fi»: включаем на время проверки,
        // подключаемся к нему и меряем размер и частоту.
        let wasWiFi = (SettingsStore.shared.settings.options.ndiWiFiEnabled ?? false,
                       SettingsStore.shared.settings.options.ndiWiFiHeight ?? 360,
                       SettingsStore.shared.settings.options.ndiWiFiFrameRate ?? 15)
        state.ndi.setWiFi(enabled: true, height: 360, fps: 15)
        wait(untilTrue: { false }, seconds: 1.5)
        var wifiResult: NDIRuntime.ProbeResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NDIRuntime.probe(sourceContaining: "Слово Wi-Fi", seconds: 3)
            DispatchQueue.main.async { wifiResult = result }
        }
        wait(untilTrue: { wifiResult != nil }, seconds: 10)
        let wifi = wifiResult ?? NDIRuntime.ProbeResult()
        state.ndi.setWiFi(enabled: wasWiFi.0, height: wasWiFi.1, fps: wasWiFi.2)


        var checks: [Check] = []
        var faults: [String] = []
        if !film.found { faults.append("приймач не знайшов джерела: \(film.note)") }
        if low.found, low.video == 0 { faults.append("зменшений потік (режим низької смуги) не прийшов") }
        if !wifi.found { faults.append("джерело «Слово Wi-Fi» не знайдено: \(wifi.note)") }
        if wifi.found, wifi.video < 5 { faults.append("від «Слово Wi-Fi» дійшло \(wifi.video) кадрів за 3 с") }
        if wifi.found, wifi.video > 0, wifi.videoHeight != 360 { faults.append("«Слово Wi-Fi» віддає \(wifi.videoWidth)×\(wifi.videoHeight), а задано 360 за висотою") }
        // Половина отправленного должна дойти: приёмник на этой же машине.
        if film.found, sentDuring > 8, film.video * 2 < sentDuring {
            faults.append("надіслано \(sentDuring), дійшло \(film.video) за 4 с")
        }
        if film.found, sentDuring < 20 {
            faults.append("канал віддав лише \(sentDuring) кадрів за 4 с — фільм іде ривками"
                + " (перераховано \(convertedDuring), викинуто \(droppedDuring), на каналі"
                + " \(onAirNow ? "кадр фільму" : "слайд"), відео в мережу \(state.media.sendsToNetwork ? "увімкнено" : "вимкнено"))")
        }
        if film.found, network.sendsAudio, film.audio == 0, sound.audio == 0 {
            faults.append("звук не дійшов жодного разу — ні разом із кадрами, ні окремим приймачем")
        }
        // Настоящий клиент берёт кадры И звук: если звук доходит только
        // приёмнику без видео — это и есть «звука по NDI нет» у владельца.
        if film.found, network.sendsAudio, film.audio == 0, sound.audio > 0 {
            faults.append("звук доходить лише приймачеві без відео: разом із кадрами порцій 0 при \(sound.audio) окремо")
        }
        if wifi.found, network.sendsAudio, wifi.video > 0, wifi.audio == 0 {
            faults.append("«Слово Wi-Fi» віддає кадри, але не звук")
        }
        // Настоящий клиент строит поток по меткам времени: нули — беда.
        if film.found, film.video > 0, film.videoTimecode <= 0 || film.videoTimestamp <= 0 {
            faults.append("у кадру немає міток часу: timecode \(film.videoTimecode), timestamp \(film.videoTimestamp)")
        }
        if sound.found, sound.audio > 0, sound.audioTimecode <= 0 || sound.audioTimestamp <= 0 {
            faults.append("у звуку немає міток часу: timecode \(sound.audioTimecode), timestamp \(sound.audioTimestamp)")
        }
        if sound.found, sound.audio > 0, sound.audioPeak < 0.01 {
            faults.append("звук іде тишею: порцій \(sound.audio), пік \(sound.audioPeak)")
        }
        if sound.found, sound.audio > 0, sound.audioRate != 48_000 || sound.audioChannels != 2 {
            faults.append("звук пішов як \(sound.audioRate) Гц, каналів \(sound.audioChannels), а NDI чекає 48 000 Гц стерео")
        }
        checks.append(Check(area: area, name: "Свій приймач отримує кадри і звук",
                            status: faults.isEmpty ? .ok : .failed,
                            detail: faults.isEmpty
                                ? "за 4 с: надіслано \(sentDuring), дійшло кадрів \(film.video) (\(film.videoWidth)×\(film.videoHeight)); звук окремим приймачем: порцій \(sound.audio), відліків \(sound.audioSamples), \(sound.audioRate) Гц, каналів \(sound.audioChannels), пік " + String(format: "%.2f", sound.audioPeak) + "; режим низької смуги: за 3 с кадрів \(low.video), звуку \(low.audio), \(low.videoWidth)×\(low.videoHeight); джерело «Слово Wi-Fi»: за 3 с кадрів \(wifi.video), звуку \(wifi.audio), \(wifi.videoWidth)×\(wifi.videoHeight); разом із кадрами звуку \(film.audio); мітки: кадр \(film.videoTimecode)/\(film.videoTimestamp), звук \(sound.audioTimecode)/\(sound.audioTimestamp); повільних відправлень \(slowDuring)"
                                : faults.joined(separator: "; ") + "; звук окремо: порцій \(sound.audio) \(sound.note); повільних відправлень \(slowDuring)"
                                    + (film.note.isEmpty ? "" : "; " + film.note)))

        // Смена слайда: закрыть фильм, вернуть стих, сменить его посреди
        // приёма — и засечь, через сколько дошёл следующий кадр.
        media.close()
        state.mode = .bible
        state.showCurrent()
        wait(untilTrue: { false }, seconds: 0.5)
        var slideResult: NDIRuntime.ProbeResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NDIRuntime.probe(sourceContaining: "Слово", seconds: 4, after: {
                DispatchQueue.main.async { MainActor.assumeIsolated { state.stepVerse(by: 1); state.showCurrent() } }
            })
            DispatchQueue.main.async { slideResult = result }
        }
        wait(untilTrue: { slideResult != nil }, seconds: 12)
        let slide = slideResult ?? NDIRuntime.ProbeResult()
        let latency = slide.firstVideoAfter
        checks.append(Check(area: area, name: "Зміна слайда доходить до приймача одразу",
                            status: !slide.found ? .skipped : (latency.map { $0 < 1.5 } == true ? .ok : .failed),
                            detail: !slide.found ? "джерело не знайдено"
                                : (latency.map { String(format: "наступний кадр після зміни вірша — через %.2f с; кадрів за 4 с: %d", $0, slide.video) }
                                   ?? "після зміни вірша кадр не прийшов зовсім (кадрів за 4 с: \(slide.video))")))
        return checks
    }

    /// «Редакторы — с предпросмотром в реальном времени и показом на
    /// проекторе на лету»: правка в «Параметрах» доходит до программы без
    /// «Ок», а «Отмена» возвращает и значение, и экран.
    private static func settingsApplyLive(_ state: AppState) -> Check {
        let area = "Параметри"
        let name = "Правки застосовуються на льоту, «Скасувати» повертає"
        let window = NativeSettingsWindow.shared
        let store = SettingsStore.shared
        let wasNumbers = store.settings.options.showVerseNumbers
        let wasFade = store.settings.options.crossfadeTime
        window.show(state: state)
        defer { if window.isOpen { window.discard() } }
        guard window.isOpen else {
            return Check(area: area, name: name, status: .failed, detail: "вікно «Параметри» не відкрилося")
        }
        store.settings.options.showVerseNumbers = !wasNumbers
        store.settings.options.crossfadeTime = wasFade == 700 ? 900 : 700
        let expectedFade = Double(store.settings.options.crossfadeTime) / 1000
        wait(untilTrue: { state.outputs[.screen].showsVerseNumbers == !wasNumbers }, seconds: 2)
        var faults: [String] = []
        if state.outputs[.screen].showsVerseNumbers != !wasNumbers { faults.append("номери віршів не застосувалися без «Ок»") }
        if abs(state.style.transitionDuration - expectedFade) > 0.001 {
            faults.append(String(format: "перехід не застосувався: %.3f замість %.3f", state.style.transitionDuration, expectedFade))
        }
        window.discard()
        wait(untilTrue: { state.outputs[.screen].showsVerseNumbers == wasNumbers }, seconds: 2)
        if state.outputs[.screen].showsVerseNumbers != wasNumbers { faults.append("після «Скасувати» номери віршів не повернулися") }
        if store.settings.options.showVerseNumbers != wasNumbers || store.settings.options.crossfadeTime != wasFade {
            faults.append("після «Скасувати» значення у сховищі не повернулися")
        }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "номери віршів і час переходу застосувалися без «Ок» і повернулися по «Скасувати»"
                         : faults.joined(separator: "; "))
    }

    /// Предпросмотр в окне «Параметры» живой: рисуется при открытии и
    /// перерисовывается, когда правка меняет слайд.
    private static func settingsLivePreview(_ state: AppState) -> Check {
        let area = "Параметри"
        let name = "У вікні є живий передпоказ слайда"
        let window = NativeSettingsWindow.shared
        let store = SettingsStore.shared
        let wasNumbers = store.settings.options.showVerseNumbers
        window.show(state: state)
        defer { if window.isOpen { window.discard() } }
        wait(untilTrue: { window.previewDrawCount > 0 }, seconds: 3)
        let first = window.previewDrawCount
        guard first > 0 else {
            return Check(area: area, name: name, status: .failed, detail: "передпоказ не намалювався за 3 с (лічильник \(first))")
        }
        store.settings.options.showVerseNumbers = !wasNumbers
        wait(untilTrue: { window.previewDrawCount > first }, seconds: 3)
        let second = window.previewDrawCount
        window.discard()
        return Check(area: area, name: name, status: second > first ? .ok : .failed,
                     detail: second > first
                         ? "намальовано при відкритті, перемальовано після правки (малювань \(second))"
                         : "після правки не перемальовано (малювань \(second))")
    }

    /// Цвет части песни, изменённый в окне «Цвета частей», доходит до
    /// списка частей без «Ок», а «Отмена» его возвращает.
    private static func songPaletteLive(_ state: AppState) -> Check {
        let area = "Пісні"
        let name = "Палітра частин застосовується на льоту, «Скасувати» повертає"
        let store = SettingsStore.shared
        let workspace = NativeSongsWorkspace.shared
        guard let key = store.settings.songChunks.first?.key else {
            return Check(area: area, name: name, status: .skipped, detail: "у налаштуваннях немає частин пісні")
        }
        func current() -> SlideStyle.RGBA? { workspace.model.palette.chunks.first { $0.key == key }?.color }
        let was = current()
        let target: SlideStyle.RGBA = was == .black ? .white : .black
        let session = store.beginEditing()
        store.setChunkColor(key, target)
        wait(untilTrue: { current() == target }, seconds: 2)
        var faults: [String] = []
        if current() != target { faults.append("колір «\(key)» не дійшов до списку частин без «Ок»") }
        store.cancel(session)
        wait(untilTrue: { current() == was }, seconds: 2)
        if current() != was { faults.append("після «Скасувати» колір не повернувся") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? "колір «\(key)» застосувався без «Ок» і повернувся по «Скасувати»"
                                            : faults.joined(separator: "; "))
    }

    /// «Видео по Wi-Fi»: поток HLS раздаётся нашим сервером и играет.
    /// Проверка ходит на сервер по HTTP, как клиент, и открывает поток
    /// обычным плеером — если он пошёл, кодер, нарезка и раздача целы.
    private static func webVideoStreams(_ state: AppState) -> [Check] {
        let area = "Відео по Wi-Fi"
        let name = "Потік H.264 роздається і грає"
        guard state.web.isRunning, let port = state.web.status.httpPort else {
            return [Check(area: area, name: name, status: .skipped, detail: "веб-сервер вимкнено")]
        }
        guard let movie = makeMovie(withSound: true) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний фільм")]
        }
        defer { try? FileManager.default.removeItem(at: movie) }
        let store = SettingsStore.shared
        var options = store.settings.options
        let wasEnabled = options.webVideoEnabled ?? false
        options.webVideoEnabled = true
        options.webVideoHeight = 360
        options.webVideoKbps = 1500
        state.applyWebVideo(options)
        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasRepeats = media.repeats
        let wasVolume = media.volume
        let wasMuted = media.isMuted
        defer {
            media.close()
            media.repeats = wasRepeats
            media.volume = wasVolume
            media.isMuted = wasMuted
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
            var back = store.settings.options
            back.webVideoEnabled = wasEnabled
            state.applyWebVideo(back)
        }
        media.autoPlay = true
        media.repeats = true
        media.isMuted = false
        media.volume = 0.05
        state.mode = .media
        state.isLive = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)

        func fetch(_ path: String) -> Data? {
            var result: Data?
            var done = false
            let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async { result = data; done = true }
            }.resume()
            wait(untilTrue: { done }, seconds: 5)
            return result
        }
        // Куски идут по секунде: ждём, пока их наберётся два.
        var playlist = ""
        wait(untilTrue: {
            if let data = fetch("/wifi/stream.m3u8"), let text = String(data: data, encoding: .utf8) {
                playlist = text
            }
            return playlist.components(separatedBy: ".m4s").count - 1 >= 2
        }, seconds: 12)
        var faults: [String] = []
        let segments = playlist.components(separatedBy: ".m4s").count - 1
        if segments < 2 { faults.append("у списку \(segments) шматків за 12 с; стан: \(state.webVideo.status)") }
        if let head = fetch("/wifi/init.mp4") {
            if head.count < 100 || !(String(data: head.prefix(12), encoding: .isoLatin1)?.contains("ftyp") ?? false) {
                faults.append("заголовок init.mp4 не схожий на MP4 (\(head.count) байт)")
            }
        } else { faults.append("init.mp4 не віддано") }
        let page = fetch("/wifi/").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if !page.contains("<video") { faults.append("сторінку плеєра не віддано") }

        // Играет ли поток обычным плеером — как на телефоне.
        media.close()
        wait(untilTrue: { false }, seconds: 0.3)
        var played = false
        if faults.isEmpty, let url = URL(string: "http://127.0.0.1:\(port)/wifi/stream.m3u8") {
            media.open(url)
            wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 12)
            played = media.hasVideo && media.isPlaying
            if !played { faults.append("плеєр не заграв потік за 12 с: \(media.failure.map { String(describing: $0) } ?? "без ошибки")") }
        }
        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: faults.isEmpty
                          ? "шматків у списку \(segments), заголовок MP4 на місці, сторінка плеєра є, потік заграв звичайним плеєром; \(state.webVideo.status)"
                          : faults.joined(separator: "; "))]
    }

    /// «На проекторе не должно быть видно системной строки меню — просто
    /// окно вывода, как в оригинале»: окно слайда стоит на уровне экрана
    /// презентации, выше меню и Dock.
    private static func projectionAboveMenuBar(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Вікно слайда вище за рядок меню і Dock"
        let wasLive = state.isLive
        defer { state.isLive = wasLive }
        state.isLive = true
        state.showCurrent()
        wait(untilTrue: { false }, seconds: 0.3)
        // На одном дисплее слайд идёт в обычном окне — меряем пробное
        // полноэкранное, собранное тем же кодом.
        let level = state.projection.probeFullScreenWindowLevel()
        let shielding = Int(CGShieldingWindowLevel())
        let menu = Int(CGWindowLevelForKey(.mainMenuWindow))
        let ok = level >= shielding && level > menu
        return Check(area: area, name: name, status: ok ? .ok : .failed,
                     detail: "рівень повноекранного вікна \(level), рядок меню \(menu), екран презентації \(shielding); живе вікно: рівень \(state.projection.slideWindowLevel ?? -1), екранів \(NSScreen.screens.count)")
    }

    /// «После остановки видео при попытке вывести текст Библии на экран
    /// выводится последний кадр видео вместо слайда»: после «Стоп» фильм
    /// снят с экрана, и стих выходит в зал и по «Показать», и стрелками.
    private static func verseAfterStop(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Після «Стоп» вірш виходить у зал, а не останній кадр фільму"
        guard let movie = makeMovie(withSound: false) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний фільм")
        }
        defer { try? FileManager.default.removeItem(at: movie) }
        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            media.close()
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }
        media.autoPlay = true
        media.repeats = true
        state.mode = .media
        state.isLive = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)
        _ = state.showMediaInHall()
        wait(untilTrue: { state.projection.isVideoShown }, seconds: 3)
        var faults: [String] = []
        if !state.projection.isVideoShown { faults.append("фільм не дійшов до залу — перевіряти нічого") }
        media.stop()
        wait(untilTrue: { !media.isVideoOnScreen }, seconds: 2)
        if media.isVideoOnScreen { faults.append("після «Стоп» фільм досі вважається «на екрані»") }
        wait(untilTrue: { !state.projection.isVideoShown }, seconds: 2)
        if state.projection.isVideoShown { faults.append("після «Стоп» кадр фільму лишився в залі") }
        // Стрелками, как оператор: связанные стрелки выводят стих в зал.
        state.mode = .bible
        state.stepVerse(by: 1, live: true)
        wait(untilTrue: { !state.projection.isVideoShown && media.screenSuppression.contains(.slideTookOver) }, seconds: 2)
        if state.projection.isVideoShown { faults.append("після стрілки в залі знову кадр фільму, а не вірш") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? "«Стоп» зняв фільм з екрана, вірш вийшов стрілкою і по «Показати»" : faults.joined(separator: "; "))
    }

    /// Переходы на проекторе — прямой прогон аниматора: у каждого из
    /// двадцати `play` кладёт на слой отдельный уходящий слой и задаёт ему
    /// движение (сдвиг/прозрачность/маска/фильтр) или чёрную прослойку.
    /// Владелец: «половина эффектов перехода не работают».
    private static func transitionsPlayOnProjector(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Аніматор переходів на шарі: у кожного свій шар, що йде, з рухом"
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage? {
            guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            return context.makeImage()
        }
        guard let red = solid(1, 0, 0), let blue = solid(0, 0, 1) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібралися пробні кадри")
        }
        var dead: [String] = []
        for preset in SlideStyle.TransitionPreset.all where preset.kind != .none {
            let host = CALayer()
            host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            host.contents = red
            SlideTransitionAnimator.play(on: host, from: red, to: blue,
                                         kind: preset.kind, duration: 0.8, easing: preset.easing)
            let subs = host.sublayers ?? []
            let outgoing = subs.first { $0.name == "уходящий" }
            let incoming = subs.first { $0.name == "входящий" }
            let black = subs.first { $0.name == "чёрное" }
            // Движение — это заведённые анимации: у нас они все явные.
            // У шторок движется маска, а не сам слой.
            let animated = [outgoing, incoming, black, incoming?.mask, outgoing?.mask].compactMap { $0 }
                .contains { ($0.animationKeys() ?? []).isEmpty == false }
            if outgoing == nil || incoming == nil { dead.append(preset.kind.title + " (немає шарів)") }
            else if !animated { dead.append(preset.kind.title + " (шари без анімації)") }
        }
        var faults: [String] = []
        if !dead.isEmpty { faults.append("не грають: " + dead.joined(separator: ", ")) }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? "усі двадцять: у кожного свій шар, що йде, з рухом або чорний прошарок" : faults.joined(separator: "; "))
    }

    /// Страницы автора отдаются без его имени: подмена фраз работает на выдаче.
    private static func servedPagesAreOurs(_ state: AppState) -> Check {
        let area = "Веб"
        let name = "Чужа сторінка віддається без назви старої програми в написах"
        guard state.web.isRunning, let port = state.web.status.httpPort else {
            return Check(area: area, name: name, status: .skipped, detail: "веб-сервер вимкнено")
        }
        var body: String?
        var done = false
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/VBWebSlideStage.html")!) { data, _, _ in
            DispatchQueue.main.async { body = data.flatMap { String(data: $0, encoding: .utf8) }; done = true }
        }.resume()
        wait(untilTrue: { done }, seconds: 6)
        guard let page = body, !page.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "сторінку не віддано")
        }
        let stray = page.contains("VisioBible WS-Server") || page.contains("VisioBible Web Slide")
        return Check(area: area, name: name, status: stray ? .failed : .ok,
                     detail: stray ? "у виданій сторінці лишилося ім'я автора" : "написи підмінено, імені автора немає")
    }

    /// Посеянные заготовки — наложение: страница прозрачна, плашка под
    /// текстом. Владелец: «страница полностью закрывает слой видео под
    /// собой, фон непрозрачный».
    private static func seededPagesOverlay(_ state: AppState) -> Check {
        let area = "Веб"
        let name = "Посіяні заготовки Біблії й пісень — накладення (сторінка прозора)"
        let folder = WebOutputServer.userPagesFolder
        var opaque: [String] = []
        var checked = 0
        for template in WebSlideTemplates.all where template.id.hasPrefix("bible-") || template.id.hasPrefix("song-") {
            let file = folder.appendingPathComponent(template.id + ".html")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            checked += 1
            // Своя тёмная страница субтитров — единственная, где фон нарочно есть.
            if template.id == "bible-sub-dark" { continue }
            if !text.contains("--sl-bg-opacity: 0;") { opaque.append(template.id) }
        }
        return Check(area: area, name: name, status: opaque.isEmpty ? .ok : .failed,
                     detail: opaque.isEmpty ? "перевірено сторінок \(checked): у всіх фон сторінки прозорий, колір — у плашці"
                                            : "непрозорий фон у: " + opaque.joined(separator: ", "))
    }

    /// Двадцать переходов: у каждого середина отличается и от старого
    /// кадра, и от нового — значит, эффект действительно рисуется (в
    /// трансляции кадры считаем сами; проектор и предпросмотр играют те же
    /// правила Core Animation).
    private static func transitionsRender(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Переходів двадцять, і кожен малює середину"
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage? {
            let size = 96
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            return context.makeImage()
        }
        guard let red = solid(1, 0, 0), let blue = solid(0, 0, 1) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібралися пробні кадри")
        }
        // Отпечаток — по всему кадру: пять точек сдвиг с замедлением
        // проскакивал, и проверка зря ругалась на живой эффект.
        func fingerprint(_ frame: RenderedFrame?) -> [Int] {
            guard let frame else { return [] }
            return frame.pixels.withUnsafeBytes { raw -> [Int] in
                let p = raw.bindMemory(to: UInt8.self)
                var sums = [Int](repeating: 0, count: 4)
                var i = 0
                while i + 3 < p.count {
                    sums[0] += Int(p[i]); sums[1] += Int(p[i + 1]); sums[2] += Int(p[i + 2]); sums[3] += Int(p[i + 3])
                    i += 4
                }
                return sums
            }
        }
        let start = fingerprint(SlideFrameRenderer.blend(from: red, to: blue, progress: 0, transition: .fade, identity: 1, alpha: .straight))
        let finish = fingerprint(SlideFrameRenderer.blend(from: red, to: blue, progress: 1, transition: .fade, identity: 1, alpha: .straight))
        var flat: [String] = []
        var count = 0
        for preset in SlideStyle.TransitionPreset.all where preset.kind != .none {
            count += 1
            let middle = fingerprint(SlideFrameRenderer.blend(from: red, to: blue, progress: 0.5, transition: preset.kind,
                                                              easing: preset.easing, identity: 1, alpha: .straight))
            if middle.isEmpty || middle == start || middle == finish { flat.append(preset.kind.title) }
        }
        var faults: [String] = []
        if count != 20 { faults.append("ефектів \(count), а має бути двадцять") }
        if !flat.isEmpty { faults.append("середина не відрізняється від країв у: " + flat.joined(separator: ", ")) }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? "ефектів \(count), у кожного своя тривалість і крива; середина кожного — свій кадр" : faults.joined(separator: "; "))
    }

    /// «После вывода на проектор нажимаю «Скрыть», перехожу на другую
    /// вкладку, нажимаю «Показать» — в зале прежнее изображение»: слайд
    /// обязан пересобираться под открытую вкладку.
    private static func slideFollowsTab(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Слайд іде за вкладкою: після «Сховати» і зміни вкладки «Показати» виводить її вміст"
        guard let library = state.songLibrary, let entry = library.books.first,
              let book = library.book(entry.id), let song = book.songs.first(where: { !$0.parts.isEmpty }),
              let part = song.parts.first else {
            return Check(area: area, name: name, status: .skipped, detail: "немає пісенника")
        }
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasBook = state.songBookID
        defer { state.mode = wasMode; state.isLive = wasLive; state.songBookID = wasBook }
        var faults: [String] = []
        // 1. Библия: стих готов и выведен.
        state.mode = .bible
        state.showCurrent()
        let verse = state.liveSlide.mainText
        if verse.isEmpty { faults.append("вірш Біблії не вийшов у зал") }
        // 2. Песни: часть песни выведена, затем «Скрыть».
        state.mode = .songs
        state.songBookID = entry.id
        state.showSongPart(song, part)
        state.showCurrent()
        let sung = state.liveSlide.mainText
        if sung == verse { faults.append("частина пісні не вийшла в зал (у залі лишився вірш)") }
        state.isLive = false
        // 3. Назад в Библию — предпросмотр обязан показывать стих, а «Показать» — вывести его.
        state.mode = .bible
        if state.slide.mainText != verse { faults.append("після зміни вкладки передпоказ тримає пісню, а не вірш") }
        state.showCurrent()
        if state.liveSlide.mainText != verse { faults.append("«Показати» вивело «\(state.liveSlide.mainText.prefix(30))», а не вірш") }
        if !state.isLive { faults.append("після «Показати» показ не ввімкнувся") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? "вірш → пісня → «Сховати» → вкладка «Біблія» → «Показати»: у залі вірш" : faults.joined(separator: "; "))
    }

    /// Группы песен по песенникам — факт для владельца: «в разделе группа
    /// всегда «все песни», кроме одного песенника».
    private static func songGroupsListed(_ state: AppState) -> Check {
        guard let library = state.songLibrary else {
            return Check(area: "Пісні", name: "Групи в пісенниках", status: .skipped, detail: "немає пісенників")
        }
        var lines: [String] = []
        for entry in library.books {
            guard let book = library.book(entry.id) else { continue }
            if !book.groups.isEmpty {
                lines.append("\(entry.url.deletingPathExtension().lastPathComponent): \(book.groups.count) — " + book.groups.map(\.name).joined(separator: ", "))
            }
        }
        return Check(area: "Пісні", name: "Групи в пісенниках", status: .ok,
                     detail: lines.isEmpty ? "у жодному пісеннику груп немає (це дані файлів .vbm, а не наша втрата)"
                                          : "з групами \(lines.count) із \(library.books.count): " + lines.joined(separator: "; "))
    }

    /// «В плане при добавлении песни вместо песни добавляются куплеты»:
    /// песня кладётся одним пунктом и переживает файл плана как песня.
    private static func wholeSongInPlan(_ state: AppState) -> Check {
        let area = "План"
        let name = "Пісня в плані — одним пунктом"
        guard let library = state.songLibrary, let entry = library.books.first,
              let book = library.book(entry.id),
              let song = book.songs.first(where: { $0.parts.count > 1 }) else {
            return Check(area: area, name: name, status: .skipped, detail: "немає пісенника з багаточастинною піснею")
        }
        let wasBook = state.songBookID
        state.songBookID = entry.id
        defer { state.songBookID = wasBook }
        let items = DeskModel.shared.planItems(forSong: song, state: state)
        var faults: [String] = []
        if items.count != 1 { faults.append("пунктів \(items.count) на \(song.parts.count) частин") }
        if let reference = items.first?.songPart, !reference.isWholeSong { faults.append("пункт вказує на частину, а не на пісню") }
        var plan = ServicePlan(title: "Перевірка")
        for item in items { plan.append(item) }
        let back = ServicePlan(journal: plan.journal())
        if back.items.first?.songPart?.isWholeSong != true {
            faults.append("після запису у файл пункт став частиною: \(back.items.first?.songPart?.partIndex.map(String.init) ?? "нет пункта")")
        }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "«\(song.title)» (частин \(song.parts.count)) — один пункт «\(items.first?.title ?? "")», файл плану зберігає пісню без частини"
                         : faults.joined(separator: "; "))
    }

    /// «По NDI не передаётся звук и очень тормозит». Две вещи: кадры фильма
    /// не должны пересчитываться чаще, чем уходят в сеть, а звук программы
    /// должен доходить до канала — если macOS дала на него разрешение.
    private static func ndiLoadAndSound(_ state: AppState) -> [Check] {
        let area = "NDI"
        let network = state.outputs[.ndi]
        guard network.isEnabled, state.ndi.isActive else {
            return [Check(area: area, name: "Кадри фільму не перераховуються марно", status: .skipped,
                          detail: "трансляцію вимкнено"),
                    Check(area: area, name: "Звук програми йде в трансляцію", status: .skipped,
                          detail: "трансляцію вимкнено")]
        }
        guard let movie = makeMovie(withSound: true) else {
            return [Check(area: area, name: "Звук програми йде в трансляцію", status: .skipped,
                          detail: "не зібрався пробний фільм зі звуком")]
        }
        defer { try? FileManager.default.removeItem(at: movie) }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        let wasVolume = media.volume
        let wasToScreen = media.videoToScreen
        defer {
            media.close()
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.volume = wasVolume
            media.videoToScreen = wasToScreen
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }
        media.autoPlay = true
        media.isMuted = false
        media.volume = 0.05                      // тихо, но не ноль: захвату нужен звук
        // Кнопку «відео на екран» вмикаємо самі: інакше міряли б її
        // положення, а не роботу каналу.
        media.videoToScreen = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo && media.isPlaying }, seconds: 8)
        let sentBefore = state.ndi.sentFramesNow
        let convertedBefore = state.ndi.convertedFrameCount
        let audioBefore = state.ndi.audioFrameCount
        wait(untilTrue: { false }, seconds: 2.0)
        let sent = state.ndi.sentFramesNow - sentBefore
        let converted = state.ndi.convertedFrameCount - convertedBefore
        let audio = state.ndi.audioFrameCount - audioBefore
        let audioState = state.ndi.audioState

        var checks: [Check] = []
        let onAir = NDIOutput.isVideoIdentity(state.ndi.channelIdentity)
        let wasteful = converted > sent + 4
        checks.append(Check(area: area, name: "Кадри фільму не перераховуються марно",
                            status: !onAir ? .skipped : (wasteful ? .failed : .ok),
                            detail: !onAir ? "фільм не зайняв канал (відео в трансляцію вимкнено?)"
                                : "за 2 с: перераховано \(converted), надіслано \(sent), викинуто без перерахунку \(state.ndi.droppedFrameCount)"))
        // Отвод плеера даёт звук файла без разрешений — значит порции быть
        // обязаны и без системного захвата. Дошли ли они до приёмника —
        // отдельная проверка «Свой приёмник получает кадры и звук».
        checks.append(Check(area: area, name: "Звук програми віддається каналу",
                            status: !network.sendsAudio ? .skipped : (audio > 0 ? .ok : .failed),
                            detail: !network.sendsAudio ? "звук вимкнено налаштуванням («Параметри» → «Медіа»)"
                                : (audio > 0 ? "порцій звуку за 2 с: \(audio); \(audioState)"
                                   : "звуку в мережі немає; \(audioState.isEmpty ? "захват не сообщил о себе" : audioState)")))
        return checks
    }

    /// Запасной путь — склейка ffmpeg на лету: ролик идёт, а по закрытию
    /// ffmpeg останавливается. Он нужен роликам без HLS-дорожек, и без этой
    /// проверки его поломку никто бы не заметил до служения.
    private static func youTubeRemuxFallback(_ state: AppState) -> Check {
        let area = "Медіаплеєр"
        let name = "Запасний шлях через ffmpeg: грає і зупиняється по закриттю"
        guard YouTubeResolver.locate(fresh: true).tool != nil else {
            return Check(area: area, name: name, status: .skipped, detail: "yt-dlp не знайдено")
        }
        guard YouTubeResolver.ffmpeg != nil else {
            return Check(area: area, name: name, status: .skipped, detail: "ffmpeg не знайдено")
        }
        var reachable: Bool?
        var request = URLRequest(url: URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=Ky2WYZg1Gm4&format=json")!)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { reachable = (200 ..< 400).contains(code) }
        }.resume()
        wait(untilTrue: { reachable != nil }, seconds: 8)
        guard reachable == true else {
            return Check(area: area, name: name, status: .skipped, detail: "YouTube не відповідає — схоже, немає мережі")
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        YouTubeResolver.preferRemuxForTests = true
        defer {
            YouTubeResolver.preferRemuxForTests = false
            media.close()
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }
        media.autoPlay = true
        media.isMuted = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        let started = Date()
        media.openStream(text: "https://www.youtube.com/watch?v=Ky2WYZg1Gm4")
        wait(untilTrue: { media.hasVideo || media.youTubeToolProblem != nil || media.failure != nil }, seconds: 120)
        let seconds = Date().timeIntervalSince(started)
        let opened = media.hasVideo && !media.isYouTube
        let problem = media.youTubeToolProblem ?? media.failure.map { "\($0)" } ?? ""
        if opened, !media.isPlaying { media.play() }
        let start = media.position
        wait(untilTrue: { media.position > start + 0.5 }, seconds: 10)
        let moving = media.position > start
        let remuxing = media.isRemuxingYouTube
        media.close()
        wait(untilTrue: { !media.isRemuxingYouTube }, seconds: 5)
        let stopped = !media.isRemuxingYouTube

        var faults: [String] = []
        if !opened { faults.append("ролик не відкрився" + (problem.isEmpty ? "" : ": " + problem)) }
        if opened, !remuxing { faults.append("ішов не через ffmpeg") }
        if opened, !moving { faults.append("час стоїть") }
        if !stopped { faults.append("після закриття ffmpeg не зупинено") }
        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? String(format: "склейка ffmpeg на льоту: пішов через %.0f с, іде; закрили — ffmpeg зупинено", seconds)
                         : faults.joined(separator: "; "))
    }

    /// «В презентациях — несколько файлов: первая колонка с файлами, вторая
    /// со страницами выбранного файла».
    private static func decksSeparateFromPages(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Презентації: файли окремо від сторінок"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-колоды-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Имена — в порядке, в каком программа их и откроет: список
        // сортируется по имени, как его видит человек.
        let first = folder.appendingPathComponent("а — первая.pdf")
        let second = folder.appendingPathComponent("б — вторая.pdf")
        guard makePDF(at: first, pages: 2), makePDF(at: second, pages: 3) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібралися пробні PDF")
        }

        let workspace = NativeShowWorkspace.presentation
        let model = workspace.model
        defer { model.close(); workspace.open([]) }
        model.close()
        workspace.open([first, second])

        var faults: [String] = []
        if model.decks.count != 2 { faults.append("файлів у першій колонці \(model.decks.count), чекали 2") }
        if model.decks.map(\.range) != [0..<2, 2..<5] {
            faults.append("сторінки файлів лягли не підряд: \(model.decks.map { "\($0.range)" })")
        }
        if model.index != 0 { faults.append("після відкриття вибрано не першу сторінку") }
        if workspace.fileRows != 2 || workspace.pageRows != 2 {
            faults.append("рядків: файлів \(workspace.fileRows), сторінок \(workspace.pageRows); чекали 2 і 2")
        }

        workspace.chooseDeck(1)
        // Снимок раскладки — владельцу: колонка файлов, колонка страниц,
        // предпросмотр. Вид рисуется только стоя в окне, поэтому ставим его в
        // главное окно, как при выборе вкладки.
        let wasMode = state.mode
        state.mode = .presentation
        NativeMainWindowController.shared.applyMode()
        workspace.layoutSubtreeIfNeeded()
        workspace.window?.displayIfNeeded()
        let pictured = snapshot(workspace, to: "slovo-презентации.png")
        state.mode = wasMode
        NativeMainWindowController.shared.applyMode()
        if !pictured { faults.append("знімок розкладки не записався") }
        if model.index != 2 { faults.append("вибір другого файлу не став на його першу сторінку (index \(model.index ?? -1))") }
        if model.currentRange != 2..<5 { faults.append("друга колонка показує не другий файл: \(model.currentRange)") }
        if workspace.pageRows != 3 { faults.append("у другій колонці \(workspace.pageRows) рядків, чекали 3") }
        if workspace.row(at: 0).text != OurWords.t("Страница %s", "1") {
            faults.append("рядок сторінки названо «\(workspace.row(at: 0).text)», а не «Сторінка 1»")
        }

        // Стрелка с конца первого файла переходит во второй — и колонки за ней.
        workspace.chooseDeck(0)
        workspace.step(by: 1)
        workspace.step(by: 1)
        if model.index != 2 || model.currentDeck != 1 { faults.append("стрілка не перейшла в другий файл (index \(model.index ?? -1))") }
        if workspace.pageRows != 3 { faults.append("після переходу стрілкою друга колонка не змінилася") }

        // Убрать первый файл — второй сдвигается на его место.
        workspace.chooseDeck(0)
        workspace.removeCurrentEntry()
        if model.decks.count != 1 || model.decks.first?.range != 0..<3 {
            faults.append("після видалення першого файлу колоди: \(model.decks.map { "\($0.name) \($0.range)" })")
        }
        if model.index != 0 { faults.append("після видалення вибрано сторінку \(model.index ?? -1), чекали 0") }
        if workspace.fileRows != 1 || workspace.pageRows != 3 {
            faults.append("після видалення рядків: файлів \(workspace.fileRows), сторінок \(workspace.pageRows)")
        }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "два PDF (2 і 3 сторінки): колонка файлів — 2, сторінок вибраного — 2 і 3; стрілка переходить між файлами; видалення файлу зсуває решту; знімок у ~/Library/Logs/slovo-презентации.png"
                         : faults.joined(separator: "; "))
    }

    /// Настоящий yt-dlp, если он есть: проповедь с канала владельца идёт
    /// обычным плеером по ссылке, а перемотка на середину — без ожидания,
    /// как в плеере YouTube. Нет yt-dlp или сети — пропуск.
    private static func youTubeRealToolFetches(_ state: AppState) -> Check {
        let area = "Медіаплеєр"
        let name = "Справжній yt-dlp: ролик грає за посиланням, перемотування без очікування"
        guard let tool = YouTubeResolver.locate(fresh: true).tool else {
            return Check(area: area, name: name, status: .skipped, detail: "yt-dlp не знайдено")
        }
        var reachable: Bool?
        var request = URLRequest(url: URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=jNQXAC9IVRw&format=json")!)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { reachable = (200 ..< 400).contains(code) }
        }.resume()
        wait(untilTrue: { reachable != nil }, seconds: 8)
        guard reachable == true else {
            return Check(area: area, name: name, status: .skipped, detail: "YouTube не відповідає — схоже, немає мережі")
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        defer {
            media.close()
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }
        // Проповедь на три четверти часа: на коротком ролике склейка кончается
        // раньше, чем плеер стартует, и «на лету» ничем не доказать.
        let sermon = "https://www.youtube.com/watch?v=Ky2WYZg1Gm4"
        media.autoPlay = true
        media.isMuted = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        let started = Date()
        let accepted = media.openStream(text: sermon)
        wait(untilTrue: { media.hasVideo || media.youTubeToolProblem != nil || media.failure != nil }, seconds: 120)
        let seconds = Date().timeIntervalSince(started)
        let opened = media.hasVideo && !media.isYouTube
        let problem = media.youTubeToolProblem ?? media.failure.map { "\($0)" } ?? ""
        if opened, !media.isPlaying { media.play() }
        let start = media.position
        wait(untilTrue: { media.position > start + 0.5 }, seconds: 10)
        let moving = media.position > start
        let paired = !media.isRemuxingYouTube      // свои дорожки YouTube, без ffmpeg
        let knowsLength = media.duration > 2000
        wait(untilTrue: { state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 5)
        let inHall = state.projection.isVideoShown

        // Перемотка на середину: как в плеере YouTube — без ожидания, пока
        // дотянется всё до неё.
        let middle = media.duration / 2
        let seekStarted = Date()
        media.seek(to: middle)
        wait(untilTrue: { media.position > middle + 0.5 }, seconds: 15)
        let seekSeconds = Date().timeIntervalSince(seekStarted)
        let sought = media.position > middle + 0.5 && media.position < middle + 20

        // Название и время — до закрытия: оно их стирает.
        // Звук ролика в NDI: владелец — «NDI с YouTube не передаёт звук».
        // У потока нет дорожки для отвода, звук берётся системным захватом
        // — и это надо мерить, а не предполагать.
        var networkAudio = -1
        var audioNote = ""
        if opened, state.ndi.isActive {
            media.isMuted = false
            media.volume = 0.6
            wait(untilTrue: { false }, seconds: 1.5)
            let sentBefore = state.ndi.audioFrameCount
            let inBefore = state.ndi.audioInCount
            let noSenderBefore = state.ndi.audioNoSenderCount
            let capturedBefore = state.ndi.capturedAudioCount
            var probeResult: NDIRuntime.ProbeResult?
            DispatchQueue.global(qos: .userInitiated).async {
                let r = NDIRuntime.probe(sourceContaining: "Слово", seconds: 3, audioOnly: true)
                DispatchQueue.main.async { probeResult = r }
            }
            wait(untilTrue: { probeResult != nil }, seconds: 10)
            networkAudio = probeResult?.audio ?? -1
            let sentDuring = state.ndi.audioFrameCount - sentBefore
            let capturedDuring = state.ndi.capturedAudioCount - capturedBefore
            audioNote = "за замір: захоплення дало \(capturedDuring), розібрало \(state.ndi.capturedPassedCount), не розібрало \(state.ndi.capturedFailedCount), "
                + "у насос прийшло \(state.ndi.audioInCount - inBefore), "
                + "без відправника \(state.ndi.audioNoSenderCount - noSenderBefore), надіслано \(sentDuring), прийнято \(networkAudio); "
                + "потік: \(media.isStream ? "так" : "ні"), відвід: \(media.hasAudioTap ? "є" : "немає"), "
                + "потрібне захоплення: \(state.ndi.audioNeedsSystemCapture ? "так" : "ні"), дозвіл: \(CGPreflightScreenCaptureAccess() ? "є" : "немає"), "
                + "буферів захоплення: \(state.ndi.capturedAudioCount), стан: \(state.ndi.audioState)"
            media.isMuted = true
        }
        let shownTitle = media.title
        let reached = media.position
        media.close()
        let stopped = !media.isRemuxingYouTube

        var faults: [String] = []
        if !accepted { faults.append("посилання не прийняли") }
        if !opened { faults.append("ролик не відкрився звичайним плеєром" + (problem.isEmpty ? "" : ": " + problem)) }
        if opened, !moving { faults.append("час стоїть") }
        if opened, !knowsLength { faults.append("тривалість не відома плеєру (\(Int(media.duration)) с)") }
        if opened, !inHall { faults.append("кадр не дійшов до залу") }
        // Захват отдаёт буферы, а приёмник пуст — это наша беда.
        if opened, networkAudio == 0, state.ndi.isActive, CGPreflightScreenCaptureAccess() {
            faults.append("звук ролика не дійшов до приймача NDI (" + audioNote + ")")
        }
        if opened, !sought { faults.append(String(format: "перемотування на середину не пішло за %.0f с (стоїмо на %.0f с)", seekSeconds, reached)) }
        if !stopped { faults.append("після закриття ffmpeg не зупинено") }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? String(format: "%@; «%@» пішов через %.0f с (%@), кадр у залі; перемотування на %.0f-ту секунду пішло за %.1f с",
                                  tool.description, shownTitle, seconds,
                                  paired ? "своїми HLS-доріжками YouTube, без ffmpeg" : "склейкою ffmpeg на льоту",
                                  middle, seekSeconds)
                             + "; звук у NDI: порцій \(networkAudio) (" + audioNote + ")"
                         : faults.joined(separator: "; "))
    }

    /// Нашёлся ли yt-dlp — и что именно программа скажет владельцу, если нет.
    private static func youTubeToolFound() -> Check {
        let found = YouTubeResolver.locate(fresh: true)
        return Check(area: "Медіаплеєр", name: "yt-dlp знайдено",
                     status: found.tool == nil ? .skipped : .ok, detail: found.note)
    }

    /// Путь через yt-dlp проверяется подставным yt-dlp: он отвечает так же,
    /// как настоящий, только вместо ролика YouTube даёт открытый пробный
    /// поток Apple. Так проверяется всё наше — запуск, разбор ответа, передача
    /// потока плееру, зал и трансляция, — и не нужен ни сам yt-dlp, ни
    /// согласие YouTube. Настоящий yt-dlp, если он есть, проверяется отдельно.
    private static func youTubeViaToolPlays(_ state: AppState) -> Check {
        let area = "Медіаплеєр"
        let name = "Ролик YouTube через yt-dlp іде звичайним плеєром"
        let stream = "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
            + "img_bipbop_adv_example_fmp4/master.m3u8"

        var reachable: Bool?
        var request = URLRequest(url: URL(string: stream)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { reachable = (200 ..< 400).contains(code) }
        }.resume()
        wait(untilTrue: { reachable != nil }, seconds: 8)
        guard reachable == true else {
            return Check(area: area, name: name, status: .skipped, detail: "пробний потік не відповідає — схоже, немає мережі")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-ytdlp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stub = folder.appendingPathComponent("yt-dlp")
        // Подставной отвечает как yt-dlp на трансляцию: один поток со звуком и
        // картинкой. Номер ролика — выдуманный, чтобы кэш настоящего прогона
        // не подменил ответ подставного.
        let script = "#!/bin/sh\nprintf '%s' '{\"id\":\"ProbaSlovo1\",\"title\":\"Проба yt-dlp\",\"is_live\":false,"
            + "\"vcodec\":\"avc1\",\"acodec\":\"mp4a\",\"url\":\"\(stream)\"}'\n"
        guard (try? script.write(to: stub, atomically: true, encoding: .utf8)) != nil else {
            return Check(area: area, name: name, status: .skipped, detail: "не записався підставний yt-dlp")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let media = state.media
        let wasPath = Defaults.youTubeToolPath
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        defer {
            media.close()
            Defaults.youTubeToolPath = wasPath
            _ = YouTubeResolver.locate(fresh: true)
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }

        Defaults.youTubeToolPath = stub.path
        guard YouTubeResolver.locate(fresh: true).tool != nil else {
            return Check(area: area, name: name, status: .failed, detail: "підставного yt-dlp за вказаним шляхом не знайдено")
        }
        media.autoPlay = true
        media.isMuted = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        let accepted = media.openStream(text: "https://www.youtube.com/watch?v=ProbaSlovo1")
        wait(untilTrue: { media.hasVideo || media.failure != nil || media.youTubeToolProblem != nil }, seconds: 30)
        let opened = media.hasVideo && !media.isYouTube
        let problem = media.youTubeToolProblem ?? media.failure.map { "\($0)" } ?? ""
        if opened, !media.isPlaying { media.play() }
        let start = media.position
        wait(untilTrue: { media.position > start + 0.3 }, seconds: 8)
        let moving = media.position > start
        wait(untilTrue: { state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 5)
        let inHall = state.projection.isVideoShown
        let titled = media.title.contains("Проба yt-dlp")

        var faults: [String] = []
        if !accepted { faults.append("посилання не прийняли") }
        if !opened { faults.append("потік від yt-dlp не відкрився звичайним плеєром" + (problem.isEmpty ? "" : ": " + problem)) }
        if opened, !titled { faults.append("назву від yt-dlp не підхоплено: «\(media.title)»") }
        if opened, !moving { faults.append("час стоїть") }
        if opened, !inHall { faults.append("кадр не дійшов до залу") }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? String(format: "підставний yt-dlp віддав потік і назву; відкрито звичайним плеєром, іде (%.1f с), кадр у залі", media.position)
                         : faults.joined(separator: "; "))
    }

    /// Все виды ссылок на ролик дают один и тот же номер; ссылки без ролика
    /// и чужие сайты — ничего.
    private static func youTubeLinksParse() -> Check {
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=jNQXAC9IVRw", "jNQXAC9IVRw"),
            ("https://youtube.com/watch?v=jNQXAC9IVRw&t=5s&list=PL123", "jNQXAC9IVRw"),
            ("https://youtu.be/jNQXAC9IVRw?si=abc", "jNQXAC9IVRw"),
            ("https://m.youtube.com/watch?v=jNQXAC9IVRw", "jNQXAC9IVRw"),
            ("https://www.youtube.com/live/jNQXAC9IVRw?feature=share", "jNQXAC9IVRw"),
            ("https://www.youtube.com/shorts/jNQXAC9IVRw", "jNQXAC9IVRw"),
            ("https://www.youtube.com/embed/jNQXAC9IVRw", "jNQXAC9IVRw"),
            ("https://www.youtube.com/@jawed", nil),
            ("https://www.youtube.com/", nil),
            ("https://www.youtube.com/watch?v=short", nil),
            ("https://vimeo.com/76979871", nil),
        ]
        var wrong: [String] = []
        for (text, expected) in cases {
            let got = URL(string: text).flatMap(YouTubeLink.videoID(from:))
            if got != expected { wrong.append("\(text) → \(got ?? "немає")") }
        }
        return Check(area: "Медіаплеєр", name: "Посилання YouTube розбираються в номер ролика",
                     status: wrong.isEmpty ? .ok : .failed,
                     detail: wrong.isEmpty
                         ? "\(cases.count) видів посилань: watch, youtu.be, m., live, shorts, embed; без ролика — відмова"
                         : "розійшлися: " + wrong.joined(separator: "; "))
    }

    /// «Добавь возможность воспроизведения из YouTube через ссылку» —
    /// проверяется на настоящем ролике: первом, что был выложен на YouTube,
    /// он открыт для всех и никуда не денется. Нет сети — пропуск.
    private static func youTubePlays(_ state: AppState) -> Check {
        let area = "Медіаплеєр"
        let name = "Ролик YouTube грає і доходить до залу"
        let link = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

        var reachable: Bool?
        var request = URLRequest(url: URL(string: "https://www.youtube.com/oembed?url=\(link)&format=json")!)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { reachable = (200 ..< 400).contains(code) }
        }.resume()
        wait(untilTrue: { reachable != nil }, seconds: 8)
        guard reachable == true else {
            return Check(area: area, name: name, status: .skipped, detail: "YouTube не відповідає — схоже, немає мережі")
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        let wasMuted = media.isMuted
        // Проверяется встроенный проигрыватель: yt-dlp, если он есть, на
        // время убираем — иначе ролик ушёл бы ему, и проверять было бы нечего.
        let wasTool = Defaults.youTubeToolPath
        Defaults.youTubeToolPath = "/немає/такого/yt-dlp"
        defer {
            media.close()
            Defaults.youTubeToolPath = wasTool
            _ = YouTubeResolver.locate(fresh: true)
            media.autoPlay = wasAutoPlay
            media.isMuted = wasMuted
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }

        media.autoPlay = true
        media.isMuted = true                 // самопроверка не должна звучать на весь дом
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        let accepted = media.openStream(text: link)
        wait(untilTrue: { media.hasVideo || media.failure != nil }, seconds: 30)
        let ready = media.hasVideo
        let refusal = media.failure.map { "\($0)" } ?? ""

        wait(untilTrue: { media.isPlaying }, seconds: 12)
        let playing = media.isPlaying
        let start = media.position
        wait(untilTrue: { media.position > start + 0.4 }, seconds: 8)
        let moving = media.position > start

        wait(untilTrue: { state.projection.isWebShown }, seconds: Defaults.mediaFadeSeconds + 4)
        let inHall = state.projection.isWebShown
        wait(untilTrue: { state.projection.shownContents != nil }, seconds: 6)
        let snapshots = state.projection.shownContents != nil
        wait(untilTrue: { NDIOutput.isVideoIdentity(state.ndi.channelIdentity) }, seconds: 6)
        let onAir = NDIOutput.isVideoIdentity(state.ndi.channelIdentity)
        let titled = media.title.contains("zoo")

        var faults: [String] = []
        if !accepted { faults.append("посилання не прийняли") }
        if !media.isYouTube { faults.append("відкрито не вбудованим програвачем") }
        if !ready { faults.append("програвач не повідомив про готовність" + (refusal.isEmpty ? "" : ": " + refusal)) }
        if ready, !playing { faults.append("ролик не пішов") }
        if playing, !moving { faults.append("час стоїть") }
        if ready, !inHall { faults.append("програвач не став у зал") }
        if ready, !snapshots { faults.append("знімки не дійшли до шару кадру") }
        if ready, !onAir { faults.append("кадр не зайняв канал трансляції") }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? String(format: "«%@»: готовий, іде (%.1f с), у залі, знімки в панелі й на мікшері",
                                  titled ? media.title : "ролик без назви", media.position)
                         : faults.joined(separator: "; "))
    }

    /// «Открытие видео с потока не работает».
    ///
    /// Ролик YouTube идёт встроенному проигрывателю (см. ниже), а страница
    /// чужого сайта отклоняется словами — это проверено отдельно. А вот
    /// настоящий поток обязан
    /// играть, и словами это не проверить: берём открытый пробный поток
    /// Apple — он живёт годами ровно для такой проверки — и смотрим, дошёл
    /// ли кадр до зала. Ничего не сохраняем, только смотрим.
    ///
    /// Нет сети — проверка пропускается: у зала на служении её может не быть,
    /// и краснеть на исправном коде она не должна.
    private static func streamPlays(_ state: AppState) -> Check {
        let area = "Медіаплеєр"
        let name = "Потік грає і доходить до залу"
        let address = "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
            + "img_bipbop_adv_example_fmp4/master.m3u8"
        guard let link = URL(string: address) else {
            return Check(area: area, name: name, status: .skipped, detail: "адресу пробного потоку не розібрано")
        }

        var reachable: Bool?
        var request = URLRequest(url: link)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { reachable = (200 ..< 400).contains(code) }
        }.resume()
        wait(untilTrue: { reachable != nil }, seconds: 8)
        guard reachable == true else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "пробний потік не відповідає — схоже, немає мережі")
        }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasAutoPlay = media.autoPlay
        defer {
            media.close()
            media.autoPlay = wasAutoPlay
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }

        media.autoPlay = true
        media.screenSuppression = []
        state.mode = .media
        state.isLive = true
        let accepted = media.openStream(text: address)
        wait(untilTrue: { media.hasVideo || media.failure != nil }, seconds: 25)
        let opened = media.hasVideo
        let refusal = media.failure.map { "\($0)" } ?? ""

        if opened, !media.isPlaying { media.play() }
        let start = media.position
        wait(untilTrue: { media.position > start + 0.3 }, seconds: 8)
        let moving = media.position > start

        wait(untilTrue: { state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 5)
        let inHall = state.projection.isVideoShown
        wait(untilTrue: { NDIOutput.isVideoIdentity(state.ndi.channelIdentity) }, seconds: 5)
        let onAir = NDIOutput.isVideoIdentity(state.ndi.channelIdentity)

        var faults: [String] = []
        if !accepted { faults.append("посилання не прийняли") }
        if !opened { faults.append("потік не відкрився" + (refusal.isEmpty ? "" : ": " + refusal)) }
        if opened, !moving { faults.append("час стоїть — картинка не йде") }
        if opened, !inHall { faults.append("кадр не дійшов до залу") }
        if opened, !onAir { faults.append("кадр не зайняв канал трансляції") }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? String(format: "пробний потік HLS: відкрився, пішов на %.1f с, кадр у залі й на мікшері",
                                  media.position)
                         : faults.joined(separator: "; "))
    }

    /// «Презентация не добавляется перетягиванием в окно».
    ///
    /// Разбор брошенного проверяется отдельно; здесь важно другое — доходит
    /// ли файл до вкладки и принимает ли окно вообще файлы.
    private static func dropReachesWorkspace(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Кинута презентація доходить до вкладки"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-бросок-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("брошенная.pdf")
        guard makePDF(at: pdf, pages: 2) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібралася пробна презентація")
        }

        let workspace = NativeShowWorkspace.presentation
        let wasMode = state.mode
        defer { workspace.model.close(); state.mode = wasMode }

        workspace.model.close()
        let accepted = NativeWindowDrop.shared.accept(urls: [pdf])
        let pages = workspace.model.count
        let modeSwitched = state.mode == .presentation
        // Окно должно ещё и принимать файлы: без регистрации типа бросок не
        // дойдёт до нас вовсе.
        let registered = NativeMainWindowController.shared.root?
            .registeredDraggedTypes.contains(.fileURL) ?? false

        var faults: [String] = []
        if !accepted { faults.append("кидок не прийнято") }
        if pages != 2 { faults.append("сторінок у списку \(pages), чекали 2") }
        if !modeSwitched { faults.append("вкладка не змінилася на «Презентації»") }
        if !registered { faults.append("вікно не приймає файлів (тип не зареєстровано)") }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "PDF на дві сторінки дійшов до вкладки «Презентації», вікно приймає файли"
                         : faults.joined(separator: "; "))
    }

    /// Список переживает строку, которой уже нет.
    ///
    /// Так упала вся программа во время самопроверки: список плеера очистили,
    /// `NSTableView` держал прежнее число строк и спросил третью — источник
    /// полез в массив из одного файла. На служении это тот же щелчок
    /// «Очистить» в панели плеера при открытой вкладке «Медиа».
    private static func listSurvivesVanishedRow() -> Check {
        final class Source: NativeListSource {
            var titles = ["один", "два", "три"]
            var rowCount: Int { titles.count }
            func row(at index: Int) -> NativeRow { NativeRow(text: titles[index], singleLine: true) }
            func menu(at index: Int) -> NSMenu? { nil }
        }

        let source = Source()
        let list = NativeList(mode: .list, metrics: NativeListMetrics(), heights: .uniform(22))
        list.source = source
        let stand = bench(for: list, size: NSSize(width: 320, height: 200))
        defer { stand.orderOut(nil) }
        list.reload()
        stand.contentView?.layoutSubtreeIfNeeded()

        // Состав изменился мимо списка — таблице об этом ещё не сказали.
        source.titles = ["один"]
        list.reloadRow(2)
        list.reloadRows(IndexSet(integersIn: 0..<3))
        stand.contentView?.layoutSubtreeIfNeeded()
        list.reload()

        return Check(area: "Показ", name: "Список переживає зниклий рядок",
                     status: list.itemCount == 1 ? .ok : .failed,
                     detail: "рядок, якого вже немає, список віддає порожнім; "
                         + "після перезавантаження рядків \(list.itemCount)")
    }

    /// «После презентации если перейти в Библию или песни, то первый вывод на
    /// экран вместо текста — презентация».
    private static func presentationLeavesHall(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Після презентації першим у зал іде текст"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-показ-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("проповедь.pdf")
        guard makePDF(at: pdf, pages: 2) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібралася пробна презентація")
        }

        let workspace = NativeShowWorkspace.presentation
        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            state.media.showStill(nil)
            workspace.model.close()
            state.mode = wasMode
            state.isLive = wasLive
        }

        workspace.model.open([pdf])
        workspace.model.select(0)
        state.mode = .presentation
        state.isLive = true
        // Показываем страницу тем же путём, что и кнопка «Показать» (13.1).
        state.showCurrent()
        guard state.media.still != nil else {
            return Check(area: area, name: name, status: .failed,
                         detail: "сторінка презентації не пішла в зал зовсім")
        }
        wait(untilTrue: { state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 2)
        let pageInHall = state.projection.isVideoShown && state.media.still != nil

        // А теперь — Библия, как это делает оператор: вкладка и «Показать».
        state.mode = .bible
        state.showCurrent()
        wait(untilTrue: { !state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 1)

        var faults: [String] = []
        if !pageInHall { faults.append("сторінка не дійшла до залу") }
        if state.projection.isVideoShown { faults.append("сторінка лишилася поверх вірша") }
        if state.lastScreenSlide.isBlank { faults.append("у зал пішов порожній слайд замість вірша") }
        if state.media.isVideoOnScreen { faults.append("правило виводу досі за показом") }
        // Що саме бачить перевірка — інакше «сторінка лишилася» нічого не
        // каже про те, ЧОМУ: вірш порожній, розділи не прочитані чи плеєр
        // досі вважає кадр показаним.
        let media = state.media
        let seen = "режим \(state.mode.rawValue), зал \(state.isLive ? "увімкнено" : "вимкнено")"
            + "; слайд «\(state.slide.reference)», порожній \(state.slide.isBlank)"
            + "; у залі «\(state.lastScreenSlide.reference)»"
            + "; книга \(state.selectedBookIndex), розділ \(state.selectedChapterNumber), вірші \(state.selectedVerseNumbers)"
            + ", розділів \(state.chapters.count), читаються \(state.isLoadingChapters)"
            + "; плеєр: картинка \(media.still != nil), hasVideo \(media.hasVideo), hasMedia \(media.hasMedia)"
            + ", відео на екран \(media.videoToScreen), поступки \(media.screenSuppression)"
            + "; проектор показує кадр \(state.projection.isVideoShown)"

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "сторінка була в залі, після вкладки «Біблія» її змінив вірш «"
                             + state.lastScreenSlide.reference + "»"
                         : faults.joined(separator: "; ") + ". Бачу: " + seen)
    }

    /// «Не работает кнопка показа в окне видео»: `PngSBVideoToScreen`
    /// (16.5) обязана возвращать кадр в зал с первого нажатия — даже когда
    /// перед этим в зал уходил текст.
    private static func toScreenWorksAtOnce(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "«Відео на екран» спрацьовує з першого натискання"
        guard let movie = makeMovie() else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний фільм")
        }
        defer { try? FileManager.default.removeItem(at: movie) }

        let media = state.media
        let wasMode = state.mode
        let wasLive = state.isLive
        let wasToScreen = media.videoToScreen
        let wasAutoPlay = media.autoPlay
        let wasPlaylist = media.playlist
        defer {
            media.autoPlay = wasAutoPlay
            media.clearPlaylist()
            media.putBackPlaylist(wasPlaylist)
            media.videoToScreen = wasToScreen
            media.screenSuppression = []
            state.mode = wasMode
            state.isLive = wasLive
        }

        media.clearPlaylist()
        // Автозапуск выключаем нарочно: пошедший сам фильм просит зал и сам
        // ставит галочку «Видео на экран» — проверять после этого нечего.
        media.autoPlay = false
        state.mode = .media
        state.isLive = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo }, seconds: 8)

        // Галочка снята, и зал занят текстом: ровно то состояние, в котором
        // кнопка «помогала лишь со второго раза».
        media.videoToScreen = false
        media.screenSuppression.insert(.slideTookOver)
        wait(untilTrue: { !state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 1)
        let hiddenBefore = !state.projection.isVideoShown

        media.videoToScreen = true           // одно нажатие
        wait(untilTrue: { state.projection.isVideoShown }, seconds: Defaults.mediaFadeSeconds + 2)
        let shown = state.projection.isVideoShown
        let cleared = !media.screenSuppression.contains(.slideTookOver)
        media.close()

        return Check(area: area, name: name,
                     status: hiddenBefore && shown && cleared ? .ok : .failed,
                     detail: "до натискання кадру в залі немає: \(hiddenBefore ? "так" : "ні"), "
                         + "після одного натискання видно: \(shown ? "так" : "ні"), "
                         + "поступку тексту знято: \(cleared ? "так" : "ні")")
    }

    /// «Появление и остановка презентаций без эффектов — резкое».
    private static func stillFades(_ state: AppState) -> Check {
        let area = "Показ"
        let name = "Картинка з'являється і йде плавно"
        let seconds = Defaults.mediaFadeSeconds
        guard seconds > 0 else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "плавність вимкнено в налаштуваннях («Медіа», 0 с)")
        }
        guard let image = solidImage(red: 170) else {
            return Check(area: area, name: name, status: .skipped, detail: "не зібрався пробний кадр")
        }

        let wasLive = state.isLive
        defer { state.media.showStill(nil); state.isLive = wasLive }

        state.media.showStill(nil)
        state.isLive = true
        state.media.showStill(image, title: "перевірка")
        let appearing = state.projection.isFading
        wait(untilTrue: { !state.projection.isFading }, seconds: seconds + 1)

        state.media.showStill(nil)
        let leaving = state.projection.isFading

        return Check(area: area, name: name,
                     status: appearing && leaving ? .ok : .failed,
                     detail: "поява плавна: \(appearing ? "так" : "ні"), "
                         + "відхід плавний: \(leaving ? "так" : "ні"); "
                         + String(format: "тривалість %.2f с", seconds))
    }
}
