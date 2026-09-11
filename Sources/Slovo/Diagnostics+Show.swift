import AppKit
import AVFoundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SlovoCore

/// Самопроверка показа картинок и презентаций.
///
/// Разборщик презентаций проверять глазами дороже всего: слайд «выглядит
/// похоже» и когда всё разобрано верно, и когда половина надписей легла одна
/// на другую. Поэтому здесь собирается настоящий файл `.pptx` — архив с XML,
/// какой делает и сам PowerPoint, — и по нему проверяется то, на чём разбор
/// уже один раз ломался: съеденный пробел между отрывками и цвет обводки,
/// заливший фигуру целиком.
///
/// Файл собирается на месте, а не лежит в поставке: чужие презентации в
/// программу не кладём, а свою в двадцать строк собрать честнее, чем хранить.
extension Diagnostics {

    static func showSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: showPresentation())
        checks.append(contentsOf: showPictures())
        checks.append(contentsOf: showOutputs())
        checks.append(contentsOf: showModes(state))
        checks.append(contentsOf: showInHall(state))
        checks.append(contentsOf: showVideo())
        checks.append(contentsOf: showAround(state))
        checks.append(contentsOf: ndiVideoSection(state: state))
        checks.append(contentsOf: showListSection(state: state))
        return checks
    }

    // MARK: - Вокруг показа

    /// Замечания владельца, проверенные кодом: пустота под кадром, страница
    /// в браузере вместо стиха, ссылка на YouTube и брошенный в окно файл.
    private static func showAround(_ state: AppState) -> [Check] {
        var checks: [Check] = []

        // Ссылка на видеосайт. Ролик YouTube идёт встроенному проигрывателю;
        // страница другого сайта отклоняется словами, а не общей «Ошибка при
        // открытии медиа-файла», как было, когда она уходила в AVFoundation.
        // yt-dlp на машине может быть — тогда ссылка ушла бы ему; здесь
        // проверяется встроенный проигрыватель, и yt-dlp на время убираем.
        let wasTool = Defaults.youTubeToolPath
        Defaults.youTubeToolPath = "/нет/такого/yt-dlp"
        defer { Defaults.youTubeToolPath = wasTool; _ = YouTubeResolver.locate(fresh: true) }
        let probe = MediaPlayerModel()
        let youTube = probe.openStream(text: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
            && probe.isYouTube
        probe.close()
        let channel = !probe.openStream(text: "https://www.youtube.com/@jawed")
            && probe.failure == .pageLink("www.youtube.com")
        let refused = !probe.openStream(text: "https://vimeo.com/76979871")
        let named = probe.failure == .pageLink("vimeo.com")
        let stillWorks = probe.openStream(text: "https://example.com/поток.m3u8")
        probe.close()
        checks.append(Check(area: "Показ", name: "Посилання YouTube — програвачеві, чужа сторінка — словами",
                            status: youTube && channel && refused && named && stillWorks ? .ok : .failed,
                            detail: "ролик YouTube прийнято: \(youTube ? "так" : "ні"); канал без ролика "
                                + "відхилено: \(channel ? "так" : "ні"); сторінку Vimeo відхилено: "
                                + "\(refused ? "так" : "ні"), названо причину: \(named ? "так" : "ні"); "
                                + "прямий потік як і раніше відкривається: " + (stillWorks ? "так" : "ні")))

        // Разбор брошенного в окно.
        let folder = URL(fileURLWithPath: "/tmp/снимки", isDirectory: true)
        let picture = URL(fileURLWithPath: "/tmp/фото.jpg")
        let slides = URL(fileURLWithPath: "/tmp/проповедь.pptx")
        let film = URL(fileURLWithPath: "/tmp/фильм.mp4")
        let text = URL(fileURLWithPath: "/tmp/заметка.txt")
        func route(_ urls: [URL]) -> NativeWindowDrop.Target {
            NativeWindowDrop.route(urls, isFolder: { $0 == folder },
                                   playable: { $0.pathExtension == "mp4" })
        }
        let cases: [(String, Bool)] = [
            ("презентація", route([picture, slides]) == .presentation(slides)),
            ("картинки", route([picture, text]) == .pictures([picture])),
            ("тека", route([folder]) == .pictures([folder])),
            ("фільм", route([film, text]) == .media(film)),
            ("чуже", route([text]) == .nothing),
        ]
        let wrong = cases.filter { !$0.1 }.map(\.0)
        checks.append(Check(area: "Показ", name: "Кинутий у вікно файл іде своїй вкладці",
                            status: wrong.isEmpty ? .ok : .failed,
                            detail: wrong.isEmpty
                                ? "розібрано всі п'ять випадків: презентація, картинки, тека, фільм, чуже"
                                : "розійшлися: " + wrong.joined(separator: ", ")))

        // Пустота под кадром и картинка в браузере.
        guard let image = solidImage(red: 210) else { return checks }
        let mode = state.mode
        let live = state.isLive
        state.media.showStill(image, title: "перевірка")
        state.isLive = true
        let underMedia = state.lastScreenSlide.isBlank
        checks.append(Check(area: "Показ", name: "Під кадром у залі нічого не малюється",
                            status: underMedia ? .ok : .failed,
                            detail: underMedia
                                ? "на проектор пішов порожній слайд — блимнути при закритті нічим"
                                : "під кадром лишився текст: він покажеться при закритті показу"))

        let web = state.outputs[.web]
        if web.isEnabled {
            let page = state.lastWebPayload
            let showsPicture = page?.layout?.background.imageID != nil
            // Текст в пакете лежит по вариантам — их страница и рисует.
            let showsText = page?.variants.contains { !$0.text.isEmpty } ?? false
            checks.append(Check(area: "Показ", name: "У браузері картинка, а не вірш",
                                status: showsPicture && !showsText ? .ok : .failed,
                                detail: "сторінка отримала картинку: \(showsPicture ? "так" : "ні"), "
                                    + "текст на ній: \(showsText ? "є" : "немає")"))
        } else {
            checks.append(Check(area: "Показ", name: "У браузері картинка, а не вірш",
                                status: .skipped, detail: "веб-вивід вимкнено"))
        }

        state.media.showStill(nil)
        state.mode = mode
        state.isLive = live
        return checks
    }

    // MARK: - Настоящее видео

    /// Кадр фильма проверяется настоящим фильмом.
    ///
    /// Картинка и видео дальше идут одной дорогой, но приходят на неё
    /// по-разному: картинку кладут разом, а кадры фильма тянет часовой. На
    /// снимке экрана разницы не видно, а в зале — видно.
    private static func showVideo() -> [Check] {
        guard let movie = makeMovie() else {
            return [Check(area: "Показ", name: "Кадр фільму доходить до вікна слайда",
                          status: .skipped, detail: "не зібрався пробний фільм")]
        }
        defer { try? FileManager.default.removeItem(at: movie) }

        let media = MediaPlayerModel()
        var toNetwork = 0
        media.onNetworkFrame = { _ in toNetwork += 1 }
        media.sendsToNetwork = true
        media.open(movie)
        wait(untilTrue: { media.hasVideo }, seconds: 5)

        let layer = CALayer()
        media.attach(layer)
        media.play()
        // Ждём не первый кадр, а несколько: одиночный кадр бывает и от
        // «показать текущее место», а нам нужен идущий фильм.
        wait(untilTrue: { layer.contents != nil && toNetwork >= 3 }, seconds: 6)
        let gotFrame = layer.contents != nil
        let sent = toNetwork
        let onScreen = media.isVideoOnScreen
        let opened = media.hasVideo
        media.close()

        return [
            Check(area: "Показ", name: "Кадр фільму доходить до вікна слайда",
                  status: gotFrame && onScreen && opened ? .ok : .failed,
                  detail: "фільм відкрився: \(opened ? "так" : "ні"), кадр у шарі: "
                      + "\(gotFrame ? "так" : "ні"), правило виводу визнає: "
                      + (onScreen ? "так" : "ні")),
            Check(area: "Показ", name: "Кадр фільму йде в трансляцію",
                  status: sent >= 3 ? .ok : (sent > 0 ? .warning : .failed),
                  detail: "кадрів віддано в мережу: \(sent) (чекали не менше трьох)"),
        ]
    }

    /// Подождать, не отпуская главную очередь насовсем: плеер живёт на ней же.
    static func wait(untilTrue condition: () -> Bool, seconds: Double) {
        let finish = Date().addingTimeInterval(seconds)
        while !condition(), Date() < finish {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Короткий фильм своими руками: чужих файлов в самопроверке быть не
    /// должно, а проверять видео без видео — самообман.
    static func makeMovie(named name: String? = nil, in folder: URL? = nil, withSound: Bool = false) -> URL? {
        let base = folder ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(name ?? "slovo-проба-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        // Звуковая дорожка — тон 440 Гц на всю длину: без звука проверять
        // трансляцию звука нечем.
        var sound: AVAssetWriterInput?
        if withSound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); sound = input }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240,
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<24 {
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<240 {
                    for x in 0..<320 {
                        let at = y * stride + x * 4
                        bytes[at] = 40                       // синий
                        bytes[at + 1] = UInt8(10 * index)    // зелёный — кадры разные
                        bytes[at + 2] = 200                  // красный
                        bytes[at + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 12))
        }
        if let sound {
            // 2 секунды тона порциями по 1024 отсчёта.
            var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
                                                     mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                     mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                     mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &description)
            var position = 0
            let total = 44_100 * 2
            while position < total, let description {
                let count = min(1024, total - position)
                var samples = [Float](repeating: 0, count: count)
                for index in 0..<count {
                    samples[index] = sinf(Float(position + index) * 2 * .pi * 440 / 44_100) * 0.3
                }
                var block: CMBlockBuffer?
                let bytes = count * 4
                guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                         blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                         dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
                      let block else { break }
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                }
                var sample: CMSampleBuffer?
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                                presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: 44_100),
                                                decodeTimeStamp: .invalid)
                guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                           refcon: nil, formatDescription: description, sampleCount: count,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: [4],
                                           sampleBufferOut: &sample) == noErr, let sample else { break }
                while !sound.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                sound.append(sample)
                position += count
            }
            sound.markAsFinished()
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success, writer.status == .completed else { return nil }
        return url
    }

    // MARK: - Что попадает в зал

    /// Самое дорогое место: кнопка «Показать» и порядок кадра со слайдом.
    ///
    /// Здесь уже случилось обе беды разом: слой кадра AppKit молча переставил
    /// ПОД слайд, и в зале поверх видео стоял текст; а кнопка «Показать» в
    /// любом режиме уносила в зал последний стих Библии. Обе видны только на
    /// проекторе, и обе проверяются отсюда — по настоящему окну.
    private static func showInHall(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        guard let image = solidImage(red: 220) else {
            return [Check(area: "Показ", name: "Кадр у залі", status: .skipped,
                          detail: "не зібрався пробний кадр")]
        }

        let mode = state.mode
        let live = state.isLive
        let liveSlide = state.liveSlide

        // 1. Картинка в зал — кадр обязан оказаться ПОВЕРХ слайда.
        state.media.showStill(image, title: "перевірка")
        state.isLive = true
        let onScreen = state.media.isVideoOnScreen
        let over = state.projection.isVideoOverSlide
        let shown = state.projection.isVideoShown
        checks.append(Check(area: "Показ", name: "Кадр стоїть поверх слайда",
                            status: onScreen && over && shown ? .ok : .failed,
                            detail: "кадр у залі: \(onScreen ? "так" : "ні"), "
                                + "поверх слайда: \(over ? "так" : "ні"), "
                                + "видно: \(shown ? "так" : "ні")"))

        // 2. Трансляция: пока кадр в зале, слайд её не перебивает.
        let network = state.outputs[.ndi]
        if network.isEnabled, network.sendsVideo {
            checks.append(Check(area: "Показ", name: "Кадр іде в трансляцію замість слайда",
                                status: state.media.sendsToNetwork ? .ok : .failed,
                                detail: state.media.sendsToNetwork
                                    ? "канал віддано кадру, слайд його не перебиває"
                                    : "канал лишився за слайдом — на мікшері буде текст"))
        } else {
            checks.append(Check(area: "Показ", name: "Кадр іде в трансляцію замість слайда",
                                status: .skipped,
                                detail: network.isEnabled
                                    ? "«Відображати Відео» (NdiSendVideo) вимкнено в налаштуваннях"
                                    : "трансляцію вимкнено"))
        }

        // 3. Текст в зал — кадр обязан уйти с экрана, а не остаться поверх.
        state.mode = .bible
        state.showCurrent()
        // Решение принимается сразу, а уход кадра идёт плавно: ждём ровно
        // столько, сколько длится затухание, и ни секунды сверх — иначе
        // проверка перестанет замечать застрявший кадр.
        let decided = !state.media.isVideoOnScreen
        wait(untilTrue: { !state.projection.isVideoShown },
             seconds: Defaults.mediaFadeSeconds + 0.5)
        let cleared = decided && !state.projection.isVideoShown
        checks.append(Check(area: "Показ", name: "Текст у зал знімає кадр",
                            status: cleared ? .ok : .failed,
                            detail: cleared
                                ? "вірш вийшов у зал, кадр пішов плавно за "
                                    + String(format: "%.2f с", Defaults.mediaFadeSeconds)
                                : "кадр лишився поверх — вірша в залі не побачать"))

        // 4. «Показать» в показе выводит страницу, а не последний стих.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-hall-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("страница.png")
        if let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        let workspace = NativeShowWorkspace.pictures
        workspace.model.open([folder])
        workspace.model.select(0)
        state.mode = .pictures
        let before = state.liveSlide
        state.showCurrent()
        let showsPage = state.media.still != nil
        // «Стих не полез в зал» — значит на экране его нет. Картинка кадром
        // накрывает зал, а живой слайд под ней гасится (onScreenChanged),
        // чтобы после снятия картинки не вынырнул прежний стих — ровно этого
        // и просил владелец. Поэтому годится и прежний слайд без изменений,
        // и погашенный: важно, что нового стиха под картинкой не появилось.
        let noVerseUnder = state.liveSlide == before || state.liveSlide.isBlank
        checks.append(Check(area: "Показ", name: "«Показати» виводить сторінку, а не вірш",
                            status: showsPage && noVerseUnder ? .ok : .failed,
                            detail: "у зал пішла сторінка: \(showsPage ? "так" : "ні"), "
                                + "вірш у зал не поліз: \(noVerseUnder ? "так" : "ні") "
                                + "(живий слайд \(state.liveSlide.isBlank ? "погашен" : "прежний"))"))

        // Возвращаем всё, как было: самопроверку запускают и на служении.
        state.media.showStill(nil)
        workspace.model.close()
        try? FileManager.default.removeItem(at: folder)
        state.mode = mode
        state.isLive = live
        _ = liveSlide
        return checks
    }

    // MARK: - Презентация

    private static func showPresentation() -> [Check] {
        var checks: [Check] = []
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-show-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("проба.pptx")
        do {
            try zip(fixtureParts()).write(to: file)
        } catch {
            return [Check(area: "Показ", name: "Пробна презентація зібралася",
                          status: .failed, detail: "\(error)")]
        }

        let document: PPTXDocument
        do {
            document = try PPTXDocument(fileAt: file)
        } catch {
            return [Check(area: "Показ", name: "Презентація відкривається",
                          status: .failed, detail: "\(error)")]
        }

        let byRelations = document.slideParts == ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml"]
        checks.append(Check(area: "Показ", name: "Презентація відкривається",
                            status: document.count == 2 && byRelations ? .ok : .failed,
                            detail: "слайдів \(document.count), порядок узято зі зв'язків: "
                                + document.slideParts.map { ($0 as NSString).lastPathComponent }
                                    .joined(separator: ", ")))

        let ratio = document.canvasSize.width / max(document.canvasSize.height, 1)
        checks.append(Check(area: "Показ", name: "Полотно береться з файлу",
                            status: abs(ratio - 16.0 / 9.0) < 0.01 ? .ok : .failed,
                            detail: String(format: "%.0f×%.0f EMU, это %.2f:1",
                                           document.canvasSize.width, document.canvasSize.height, ratio)))

        // Второй слайд лежит в архиве сжатым — как в настоящем файле. Если бы
        // распаковка молчала об ошибке, он просто оказался бы пустым.
        let second = document.slides.count > 1 ? document.slides[1] : nil
        checks.append(Check(area: "Показ", name: "Стиснуті частини архіву читаються",
                            status: (second?.shapes.count ?? 0) == 1 ? .ok : .failed,
                            detail: "другий слайд стиснуто DEFLATE, фігур у ньому \((second?.shapes.count ?? 0))"))

        // Пробел на конце отрывка. XMLDocument отдаёт «» для `<a:t> </a:t>`
        // даже с сохранением пробелов — на этом «розсіялися по околицях»
        // однажды слиплось в одно слово.
        let first = document.slides.first
        let text = (first?.shapes ?? []).flatMap { $0.paragraphs }.flatMap { $0.runs }
            .map(\.text).joined()
        checks.append(Check(area: "Показ", name: "Пробіл між уривками цілий",
                            status: text == "Слово життя" ? .ok : .failed,
                            detail: "у файлі два уривки, «Слово » і «життя»; вийшло «\(text)»"))

        // Цвет обводки лежит внутри `<a:ln>`. Пока его искали «где-то внутри»,
        // им закрашивалась вся фигура: кружок вокруг слова становился залитым
        // пятном поверх строки.
        var fillIsEmpty = false
        var stroke = "ні"
        var isEllipse = false
        if let shape = second?.shapes.first {
            if case .none = shape.fill { fillIsEmpty = true }
            isEllipse = shape.outline == .ellipse
            if let color = shape.strokeColor, let parts = color.components, parts.count >= 3 {
                stroke = String(format: "R%.0f G%.0f B%.0f", parts[0] * 255, parts[1] * 255, parts[2] * 255)
            }
        }
        let strokeIsGreen = stroke.hasPrefix("R0 G176 B80")
        checks.append(Check(area: "Показ", name: "Колір обведення не заливає фігуру",
                            status: fillIsEmpty && strokeIsGreen && isEllipse ? .ok : .failed,
                            detail: "овал без заливки, обведення \(stroke); "
                                + "заливки немає: \(fillIsEmpty ? "так" : "ні"), форма: "
                                + (isEllipse ? "овал" : "не овал")))

        // Кадр. Ради него всё и затевалось: разобранный слайд, который не
        // рисуется, на служении ничем не лучше неразобранного.
        guard let slide = first,
              let image = PPTXRenderer.image(of: slide, in: document, size: CGSize(width: 640, height: 360)),
              let pixels = readable(image) else {
            checks.append(Check(area: "Показ", name: "Слайд малюється", status: .failed,
                                detail: "кадр не вийшов"))
            return checks
        }
        checks.append(Check(area: "Показ", name: "Слайд малюється", status: .ok,
                            detail: "кадр \(image.width)×\(image.height) точок"))

        let corner = pixel(pixels, x: 6, y: 6)
        let backgroundIsRed = corner.red > 150 && corner.green < 80 && corner.blue < 80
        checks.append(Check(area: "Показ", name: "Фон слайда потрапив у кадр",
                            status: backgroundIsRed ? .ok : .failed,
                            detail: "у файлі фон C00000, у кутку кадру "
                                + "R\(corner.red) G\(corner.green) B\(corner.blue)"))

        // Тёмные точки в средней полосе — это и есть буквы. Считаем их: одна
        // точка могла бы оказаться и случайной.
        var dark = 0
        for y in 140..<220 {
            for x in 80..<560 where pixel(pixels, x: x, y: y).red < 90 {
                dark += 1
            }
        }
        checks.append(Check(area: "Показ", name: "Текст ліг на кадр",
                            status: dark > 300 ? .ok : .failed,
                            detail: "темних точок у середній смузі \(dark) (чекали понад 300)"))
        return checks
    }

    // MARK: - Картинки

    private static func showPictures() -> [Check] {
        var checks: [Check] = []
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-pics-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Имена нарочно с числами: «10» после «9», а не после «1» — так их
        // видит человек, и так должен листать показ.
        for name in ["снимок-2", "снимок-10", "снимок-1"] {
            guard let image = solidImage(red: 200) else { continue }
            let file = folder.appendingPathComponent(name + ".png")
            if let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        // Чужой файл рядом: в папке со снимками всегда лежит что-нибудь ещё.
        try? Data("не картинка".utf8).write(to: folder.appendingPathComponent("заметка.txt"))

        let model = ShowModel(kind: .pictures)
        model.open([folder])
        let names = model.pages.map(\.title)
        checks.append(Check(area: "Показ", name: "Тека з картинками розкривається",
                            status: names == ["снимок-1", "снимок-2", "снимок-10"] ? .ok : .failed,
                            detail: "у теці три знімки й нотатка; вийшло: "
                                + (names.isEmpty ? "порожньо" : names.joined(separator: ", "))))

        model.select(0)
        checks.append(Check(area: "Показ", name: "Картинка читається з диска",
                            status: model.currentImage != nil ? .ok : .failed,
                            detail: model.currentImage.map { "кадр \($0.width)×\($0.height)" }
                                ?? "не відкрилася"))

        // По кругу показ не ходит: «дальше» в конце должно означать конец, а
        // не начало заново — иначе на служении показ уходит на второй круг.
        model.select(model.count - 1)
        let stepped = model.step(by: 1)
        let back = model.step(by: -1)
        checks.append(Check(area: "Показ", name: "Гортання не ходить по колу",
                            status: !stepped && back ? .ok : .failed,
                            detail: "з останньої вперед: \(stepped ? "ушло" : "осталось"), "
                                + "назад: \(back ? "ушло" : "осталось")"))

        let old = ShowModel(kind: .presentation)
        old.open([folder.appendingPathComponent("проба.ppt")])
        checks.append(Check(area: "Показ", name: "Старий .ppt відповідає словами",
                            status: (old.problem?.isEmpty == false) && old.isEmpty ? .ok : .failed,
                            detail: old.problem ?? "промовчав — людина побачила б порожній список"))
        return checks
    }

    // MARK: - Выводы

    private static func showOutputs() -> [Check] {
        // Свой плеер, не общий: подменять закладки работающей программы
        // посреди самопроверки нельзя — они держат зал.
        let media = MediaPlayerModel()
        var screenCalls = 0
        var sentToNetwork: [Bool] = []
        media.onScreenChanged = { screenCalls += 1 }
        media.onNetworkStill = { sentToNetwork.append($0 != nil) }

        guard let image = solidImage(red: 240) else {
            return [Check(area: "Показ", name: "Показ іде тими самими виводами",
                          status: .skipped, detail: "не зібрався пробний кадр")]
        }
        media.showStill(image, title: "Слайд 1")
        let shown = media.still != nil && media.hasVideo
        media.showStill(nil)
        let cleared = media.still == nil && !media.hasVideo
        screenCalls = 0
        sentToNetwork.removeAll()

        // Приёмник кадра может появиться позже самой картинки: окно слайда
        // подключает свой слой уже после того, как показ начался. Без этой
        // проверки картинка молча оставалась бы только в предпросмотре.
        media.showStill(image, title: "Слайд 1")
        let late = CALayer()
        media.attach(late)
        let reached = late.contents.map { ($0 as AnyObject) === (image as AnyObject) } ?? false
        let onScreen = media.isVideoOnScreen
        media.showStill(nil)

        return [
            Check(area: "Показ", name: "Вікно слайда бере картинку й пізніше",
                  status: reached ? .ok : .failed,
                  detail: reached
                      ? "шар підключено після показу, і він одразу отримав кадр"
                      : "шар підключився порожнім — у залі лишилася б чорнота"),
            Check(area: "Показ", name: "Картинка вважається тим, що можна показати",
                  status: onScreen ? .ok : .failed,
                  detail: "у показаної картинки немає файлу в плеєрі; правило виводу "
                      + (onScreen ? "визнає її" : "її не визнає")),
            Check(area: "Показ", name: "Показ іде тими самими виводами",
                  status: shown && cleared && sentToNetwork == [true, false] && screenCalls == 2
                      ? .ok : .failed,
                  detail: "вікно слайда сповіщено \(screenCalls) рази, у трансляцію пішло "
                      + "\(sentToNetwork.map { $0 ? "кадр" : "пусто" }.joined(separator: ", "))"),
        ]
    }

    // MARK: - Режимы окна

    private static func showModes(_ state: AppState) -> [Check] {
        var checks: [Check] = []

        let titles = [AppState.WorkMode.pictures, .presentation].map { $0.title }
        let translated = titles.map { OurWords.t($0) }
        checks.append(Check(area: "Показ", name: "Вкладки показу названо",
                            status: translated.allSatisfy { !$0.isEmpty } ? .ok : .failed,
                            detail: "\(titles.joined(separator: ", ")) → "
                                + translated.joined(separator: ", ")))

        // Стрелки в показе листают страницы, а не стихи.
        let takesArrows = NativeShowWorkspace.handleStep(mode: .pictures, delta: 1)
            && NativeShowWorkspace.handleStep(mode: .presentation, delta: 1)
        let leavesBible = !NativeShowWorkspace.handleStep(mode: .bible, delta: 1)
        checks.append(Check(area: "Показ", name: "Стрілки гортають показ",
                            status: takesArrows && leavesBible ? .ok : .failed,
                            detail: "у показі стрілку бере показ: \(takesArrows ? "так" : "ні"); "
                                + "у Біблії лишається віршу: \(leavesBible ? "так" : "ні")"))

        guard let slot = NativeMainWindowController.shared.slotView(.workspace) else {
            checks.append(Check(area: "Показ", name: "Режим ставить свою робочу область",
                                status: .skipped, detail: "вікно ще не заведено"))
            return checks
        }
        let before = state.mode
        var installed: [String] = []
        for mode in [AppState.WorkMode.pictures, .presentation] {
            state.mode = mode
            NativeMainWindowController.shared.applyMode()
            let wanted = mode == .pictures ? NativeShowWorkspace.pictures : NativeShowWorkspace.presentation
            if slot.subviews.contains(where: { $0 === wanted }) { installed.append(mode.title) }
        }
        state.mode = before
        NativeMainWindowController.shared.applyMode()
        checks.append(Check(area: "Показ", name: "Режим ставить свою робочу область",
                            status: installed.count == 2 ? .ok : .failed,
                            detail: installed.isEmpty
                                ? "робоча область не змінилася в жодному режимі"
                                : "стали: " + installed.joined(separator: ", ")))
        return checks
    }

    // MARK: - Пробный файл

    /// Части пробной презентации. Второй слайд помечен к сжатию — настоящий
    /// PowerPoint пишет так все части, и путь распаковки должен быть пройден.
    private static func fixtureParts() -> [(name: String, data: Data, deflate: Bool)] {
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let presentation = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="\(relationships)" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="\(relationships)">
        <Relationship Id="rId1" Type="\(relationships)/slide" Target="slides/slide1.xml"/>
        <Relationship Id="rId2" Type="\(relationships)/slide" Target="slides/slide2.xml"/>
        </Relationships>
        """
        let header = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="\(relationships)" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld>
        """
        let one = header + """
        <p:bg><p:bgPr><a:solidFill><a:srgbClr val="C00000"/></a:solidFill></p:bgPr></p:bg>
        <p:spTree><p:sp><p:spPr>
        <a:xfrm><a:off x="1219200" y="2057400"/><a:ext cx="9753600" cy="2743200"/></a:xfrm>
        <a:prstGeom prst="rect"/><a:noFill/></p:spPr>
        <p:txBody><a:bodyPr anchor="ctr"/><a:p><a:pPr algn="ctr"/>
        <a:r><a:rPr lang="uk" sz="4400" b="1"><a:solidFill><a:srgbClr val="101010"/></a:solidFill></a:rPr>\
        <a:t>Слово </a:t></a:r>
        <a:r><a:rPr lang="uk" sz="4400" b="1"><a:solidFill><a:srgbClr val="101010"/></a:solidFill></a:rPr>\
        <a:t>життя</a:t></a:r>
        </a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
        let two = header + """
        <p:spTree><p:sp><p:spPr>
        <a:xfrm><a:off x="3048000" y="1714500"/><a:ext cx="6096000" cy="3429000"/></a:xfrm>
        <a:prstGeom prst="ellipse"/><a:noFill/>
        <a:ln w="38100"><a:solidFill><a:srgbClr val="00B050"/></a:solidFill></a:ln></p:spPr>
        <p:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="2000"/><a:t>Коло</a:t></a:r></a:p></p:txBody>
        </p:sp></p:spTree></p:cSld></p:sld>
        """
        return [
            (".rels-корень", Data(), false),
            ("ppt/presentation.xml", Data(presentation.utf8), false),
            ("ppt/_rels/presentation.xml.rels", Data(rels.utf8), false),
            ("ppt/slides/slide1.xml", Data(one.utf8), false),
            ("ppt/slides/slide2.xml", Data(two.utf8), true),
        ].filter { $0.0 != ".rels-корень" }
    }

    /// Сборка архива ZIP из частей — ровно то, что умеет читать наш читатель.
    private static func zip(_ parts: [(name: String, data: Data, deflate: Bool)]) -> Data {
        var file = Data()
        var directory = Data()

        func put(_ value: UInt32, _ bytes: Int, into target: inout Data) {
            for shift in 0..<bytes { target.append(UInt8((value >> (8 * UInt32(shift))) & 0xFF)) }
        }

        for part in parts {
            let name = Data(part.name.utf8)
            let payload = part.deflate ? (deflate(part.data) ?? part.data) : part.data
            let method: UInt32 = (part.deflate && payload.count != part.data.count) ? 8 : 0
            let sum = crc32(part.data)
            let offset = UInt32(file.count)

            put(0x0403_4B50, 4, into: &file)                 // подпись локальной записи
            put(20, 2, into: &file)                          // нужная версия
            put(1 << 11, 2, into: &file)                     // имена в UTF-8
            put(method, 2, into: &file)
            put(0, 2, into: &file); put(0, 2, into: &file)   // время и дата
            put(sum, 4, into: &file)
            put(UInt32(payload.count), 4, into: &file)
            put(UInt32(part.data.count), 4, into: &file)
            put(UInt32(name.count), 2, into: &file)
            put(0, 2, into: &file)                           // дополнительного поля нет
            file.append(name)
            file.append(payload)

            put(0x0201_4B50, 4, into: &directory)            // подпись записи каталога
            put(20, 2, into: &directory); put(20, 2, into: &directory)
            put(1 << 11, 2, into: &directory)
            put(method, 2, into: &directory)
            put(0, 2, into: &directory); put(0, 2, into: &directory)
            put(sum, 4, into: &directory)
            put(UInt32(payload.count), 4, into: &directory)
            put(UInt32(part.data.count), 4, into: &directory)
            put(UInt32(name.count), 2, into: &directory)
            put(0, 2, into: &directory); put(0, 2, into: &directory)
            put(0, 2, into: &directory); put(0, 2, into: &directory)
            put(0, 4, into: &directory)
            put(offset, 4, into: &directory)
            directory.append(name)
        }

        let start = UInt32(file.count)
        file.append(directory)
        put(0x0605_4B50, 4, into: &file)                     // конец каталога
        put(0, 2, into: &file); put(0, 2, into: &file)
        put(UInt32(parts.count), 2, into: &file)
        put(UInt32(parts.count), 2, into: &file)
        put(UInt32(directory.count), 4, into: &file)
        put(start, 4, into: &file)
        put(0, 2, into: &file)                               // примечания нет
        return file
    }

    /// «Сырой» DEFLATE — тот же, что лежит в настоящем `.pptx`.
    private static func deflate(_ raw: Data) -> Data? {
        guard !raw.isEmpty else { return nil }
        return raw.withUnsafeBytes { input -> Data? in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let room = raw.count + 128
            let target = UnsafeMutablePointer<UInt8>.allocate(capacity: room)
            defer { target.deallocate() }
            let written = compression_encode_buffer(target, room, source, raw.count, nil, COMPRESSION_ZLIB)
            guard written > 0 else { return nil }
            return Data(bytes: target, count: written)
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        var sum: UInt32 = 0xFFFF_FFFF
        for byte in data { sum = table[Int((sum ^ UInt32(byte)) & 0xFF)] ^ (sum >> 8) }
        return sum ^ 0xFFFF_FFFF
    }

    // MARK: - Точки кадра

    /// Перерисовка кадра в известную раскладку байт: читать точки прямо из
    /// чужого кадра нельзя — порядок каналов у него может быть любым.
    private static func readable(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = bytes.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    private static func pixel(_ frame: (bytes: [UInt8], width: Int, height: Int),
                              x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        let at = (y * frame.width + x) * 4
        guard at + 2 < frame.bytes.count else { return (0, 0, 0) }
        return (Int(frame.bytes[at]), Int(frame.bytes[at + 1]), Int(frame.bytes[at + 2]))
    }
}

// MARK: - Видео в трансляции

extension Diagnostics {

    /// Что остаётся в трансляции, когда показ убрали.
    ///
    /// Владелец увидел это первым: на проекторе видео исчезает, а на микшере
    /// остаётся последний кадр и замирает. Проверка идёт по живому каналу и
    /// смотрит на отпечаток кадра: у видео он лежит в своём диапазоне.
    static func ndiVideoSection(state: AppState) -> [Check] {
        let network = state.outputs[.ndi]
        guard network.isEnabled, network.sendsVideo else {
            return [Check(area: "Показ", name: "Після «Сховати» у трансляції не лишається кадр відео",
                          status: .skipped,
                          detail: network.isEnabled ? "«Відображати Відео» вимкнено" : "трансляцію вимкнено")]
        }
        guard let image = solidImage(red: 250) else {
            return [Check(area: "Показ", name: "Після «Сховати» у трансляції не лишається кадр відео",
                          status: .skipped, detail: "не зібрався пробний кадр")]
        }

        let live = state.isLive
        let mode = state.mode
        var checks: [Check] = []

        // Сперва картинка: у неё нет своего хода, и канал обязан вернуться
        // к слайду сразу.
        state.media.showStill(image, title: "перевірка")
        state.showMediaInHall()
        wait(untilTrue: { NDIOutput.isVideoIdentity(state.ndi.channelIdentity) }, seconds: 3)
        let onAir = state.ndi.channelIdentity
        let tookChannel = NDIOutput.isVideoIdentity(onAir)

        state.isLive = false
        wait(untilTrue: { !NDIOutput.isVideoIdentity(state.ndi.channelIdentity) },
             seconds: Defaults.mediaFadeSeconds + 2)
        let after = state.ndi.channelIdentity
        let stuck = NDIOutput.isVideoIdentity(after)
        state.media.showStill(nil)

        // А теперь настоящий фильм — то, на что и жаловался владелец: у него
        // свой ход кадров, и он продолжается, когда показ уже убрали.
        if let movie = makeMovie() {
            defer { try? FileManager.default.removeItem(at: movie) }
            // Нарочно НЕ зовём «Показать»: фильм обязан выйти в зал сам,
            // как только пошёл, — на это и жаловался владелец.
            state.isLive = false
            state.media.showStill(nil)
            state.media.open(movie)
            wait(untilTrue: { state.media.hasVideo && state.media.isPlaying }, seconds: 6)
            wait(untilTrue: { state.media.isVideoOnScreen }, seconds: 3)
            checks.append(Check(area: "Показ", name: "Відкритий фільм виходить у зал сам",
                                status: state.media.isVideoOnScreen && state.isLive ? .ok : .failed,
                                detail: "показ увімкнено: \(state.isLive ? "так" : "ні"), "
                                    + "кадр у залі: \(state.media.isVideoOnScreen ? "так" : "ні")"))
            wait(untilTrue: { NDIOutput.isVideoIdentity(state.ndi.channelIdentity) }, seconds: 5)
            let filmOnAir = NDIOutput.isVideoIdentity(state.ndi.channelIdentity)

            state.isLive = false
            wait(untilTrue: { !NDIOutput.isVideoIdentity(state.ndi.channelIdentity) },
                 seconds: Defaults.mediaFadeSeconds + 3)
            let filmAfter = state.ndi.channelIdentity
            let filmStuck = NDIOutput.isVideoIdentity(filmAfter)
            state.media.close()

            checks.append(Check(area: "Показ", name: "Фільм займає канал трансляції",
                                status: filmOnAir ? .ok : .failed,
                                detail: filmOnAir ? "кадри фільму йдуть на мікшер"
                                    : "кадри фільму до каналу не дійшли"))
            checks.append(Check(area: "Показ", name: "Після «Сховати» фільм не завмирає на мікшері",
                                status: filmStuck ? .failed : .ok,
                                detail: filmStuck
                                    ? "канал завмер на останньому кадрі фільму"
                                    : "канал повернувся до слайда або згас (відбиток "
                                        + "\(filmAfter.map(String.init) ?? "немає") )"))
        }

        state.isLive = live
        state.mode = mode

        return checks + [
            Check(area: "Показ", name: "Кадр показу займає канал трансляції",
                  status: tookChannel ? .ok : .failed,
                  detail: "відбиток кадру в каналі: \(onAir.map(String.init) ?? "немає")"),
            Check(area: "Показ", name: "Після «Сховати» у трансляції не лишається кадр відео",
                  status: stuck ? .failed : .ok,
                  detail: stuck
                      ? "канал завмер на кадрі показу — на мікшері лишиться картинка"
                      : "канал повернувся до слайда або згас (відбиток \(after.map(String.init) ?? "немає"))"),
        ]
    }
}

// MARK: - Список показа, PDF и пульт докладчика

extension Diagnostics {

    static func showListSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-список-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Список копится, а не подменяется.
        var files: [URL] = []
        for name in ["первый", "второй"] {
            let file = folder.appendingPathComponent(name + ".png")
            if let image = solidImage(red: 180),
               let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
                files.append(file)
            }
        }
        let pictures = ShowModel(kind: .pictures)
        pictures.open([files[0]])
        let afterFirst = pictures.count
        pictures.open([files[1]])
        let afterSecond = pictures.count
        pictures.open([files[1]])                 // тот же файл второй раз
        let afterRepeat = pictures.count
        pictures.select(0)
        pictures.remove(at: 0)
        let afterRemove = pictures.count
        checks.append(Check(area: "Показ", name: "Список картинок накопичується, а не підмінюється",
                            status: afterFirst == 1 && afterSecond == 2 && afterRepeat == 2
                                && afterRemove == 1 ? .ok : .failed,
                            detail: "після першого \(afterFirst), після другого \(afterSecond), "
                                + "після повтору того самого файлу \(afterRepeat), після «прибрати» \(afterRemove)"))

        // PDF.
        let pdf = folder.appendingPathComponent("проба.pdf")
        if makePDF(at: pdf, pages: 3) {
            let deck = ShowModel(kind: .presentation)
            deck.open([pdf])
            deck.select(1)
            let page = deck.currentImage
            checks.append(Check(area: "Показ", name: "PDF відкривається і малюється",
                                status: deck.count == 3 && page != nil ? .ok : .failed,
                                detail: "сторінок \(deck.count) із трьох; друга сторінка "
                                    + (page.map { "намальована \($0.width)×\($0.height)" } ?? "не намалювалася")))
        } else {
            checks.append(Check(area: "Показ", name: "PDF відкривається і малюється",
                                status: .skipped, detail: "не зібрався пробний PDF"))
        }

        // Список плеера — на фильмах, а не на картинках: картинки в него
        // теперь не берутся вовсе, у них свой режим.
        let movies = ["первый.mov", "второй.mov"].compactMap { makeMovie(named: $0, in: folder) }
        if movies.count == 2 {
            let media = MediaPlayerModel()
            media.addToPlaylist(movies)
            let inList = media.playlist.count
            media.addToPlaylist([movies[0]])
            let noDouble = media.playlist.count
            media.removeFromPlaylist(at: 0)
            let afterDrop = media.playlist.count
            media.clearPlaylist()
            checks.append(Check(area: "Показ", name: "Список файлів плеєра накопичується",
                                status: inList == 2 && noDouble == 2 && afterDrop == 1
                                    && media.playlist.isEmpty ? .ok : .failed,
                                detail: "додано \(inList), повтор не подвоїв: "
                                    + "\(noDouble == 2 ? "так" : "ні"), після «прибрати» \(afterDrop), "
                                    + "після «очистити» \(media.playlist.count)"))
        } else {
            checks.append(Check(area: "Показ", name: "Список файлів плеєра накопичується",
                                status: .skipped, detail: "не зібралися пробні фільми"))
        }

        checks.append(contentsOf: presenterRemote())
        checks.append(contentsOf: pictureAndFilm())
        return checks
    }

    /// Картинка и фильм не должны жить в плеере разом.
    ///
    /// Владелец описал это так: «то отображается последнее изображение вместо
    /// видео». Так и было: показанная картинка оставалась в плеере, и каждый
    /// новый приёмник кадра получал именно её — в панели шёл фильм, а на
    /// проекторе стояло изображение.
    private static func pictureAndFilm() -> [Check] {
        guard let image = solidImage(red: 190), let movie = makeMovie() else {
            return [Check(area: "Показ", name: "Фільм витісняє показану картинку",
                          status: .skipped, detail: "не зібрався пробний фільм")]
        }
        defer { try? FileManager.default.removeItem(at: movie) }

        let media = MediaPlayerModel()
        media.showStill(image, title: "картинка")
        let hadStill = media.still != nil
        media.open(movie)
        wait(untilTrue: { media.hasVideo }, seconds: 5)
        let clearedStill = media.still == nil

        // Приёмник, подключённый после открытия фильма, обязан получить кадр
        // фильма, а не прежнюю картинку.
        let layer = CALayer()
        media.attach(layer)
        media.play()
        wait(untilTrue: { layer.contents != nil }, seconds: 5)
        let shown = layer.contents.map { ($0 as AnyObject) !== (image as AnyObject) } ?? false
        media.close()

        return [Check(area: "Показ", name: "Фільм витісняє показану картинку",
                      status: hadStill && clearedStill && shown ? .ok : .failed,
                      detail: "картинка була: \(hadStill ? "так" : "ні"), після відкриття фільму знята: "
                          + "\(clearedStill ? "так" : "ні"), у шарі кадр фільму: \(shown ? "так" : "ні")")]
    }

    /// Пульт докладчика: он притворяется клавиатурой, и проверить его можно
    /// только подделанным нажатием — самого пульта в проверке нет.
    private static func presenterRemote() -> [Check] {
        var stepped: [Int] = []
        var live: [Bool] = []
        var blackouts = 0
        let actions = ArrowNavigator.Actions(
            stepVerse: { delta, isLive in stepped.append(delta); live.append(isLive) },
            extendSelection: { _, _ in },
            selectAll: {},
            isLinked: { true },
            show: {},
            blackout: { blackouts += 1 })

        func press(_ code: UInt16, _ characters: String) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: [], timestamp: 0, windowNumber: 0,
                                               context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return false }
            return ArrowNavigator.handle(event, actions: actions)
        }

        let forward = press(121, "\u{F72D}")     // PageDown
        let back = press(116, "\u{F72C}")        // PageUp
        let dot = press(47, ".")
        let letter = press(11, "b")
        let ok = forward && back && dot && letter
            && stepped == [1, -1] && live == [true, true] && blackouts == 2
        return [Check(area: "Показ", name: "Пульт доповідача гортає й затемнює",
                      status: ok ? .ok : .failed,
                      detail: "PageDown і PageUp: \(stepped.map(String.init).joined(separator: ", ")); "
                          + "у зал: \(live.allSatisfy { $0 } ? "так" : "ні"); "
                          + "кнопка затемнення спрацювала \(blackouts) рази з двох")]
    }

    /// Пробный PDF своими руками — чужих файлов в самопроверке быть не должно.
    static func makePDF(at url: URL, pages: Int) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 720, height: 540)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 60, y: 60 + Double(page) * 40, width: 600, height: 120))
            context.endPDFPage()
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }
}
