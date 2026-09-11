import AVFoundation
import AppKit
import Combine
import CoreMedia
import SlovoCore

/// «Відео по Wi-Fi»: кадр залу й звук ідуть у H.264/AAC, ріжуться на
/// секундні шматки HLS і роздаються нашим HTTP-сервером за адресою `/wifi/`.
///
/// Навіщо: клієнт власника підключений по Wi-Fi, а повна смуга NDI по Wi-Fi
/// не проходить. NDI|HX (H.264 усередині NDI) — шлях Advanced SDK з
/// тридцятихвилинним обмеженням без ліцензії, тому окремий канал.
/// Затримка 2–4 с — ціна протоколу зі шматками; власник її допустив.
///
/// Кадри приходять із насоса NDI (той самий розмір і та сама частота), звук — з
/// відводу плеєра напряму, минаючи правила NDI.
@MainActor
final class WebVideoOutput: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var status = ""
    @Published private(set) var segmentCount = 0
    @Published private(set) var height = 720
    @Published private(set) var bitrateKbps = 3000

    nonisolated let encoder = HLSEncoder()
    private var statusTimer: Timer?

    func apply(enabled: Bool, height: Int, bitrateKbps: Int) {
        let changed = enabled != isEnabled || height != self.height || bitrateKbps != self.bitrateKbps
        self.height = height
        self.bitrateKbps = bitrateKbps
        guard changed else { return }
        isEnabled = enabled
        if enabled {
            encoder.configure(height: height, bitrateKbps: bitrateKbps)
            HLSStreamRegistry.provider = encoder
            status = OurWords.t("поток заводится…")
            statusTimer?.invalidate()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
        } else {
            HLSStreamRegistry.provider = nil
            encoder.stop()
            statusTimer?.invalidate()
            statusTimer = nil
            status = ""
            segmentCount = 0
        }
    }

    private func refreshStatus() {
        let snapshot = encoder.snapshot()
        segmentCount = snapshot.segments
        if let error = snapshot.error {
            status = OurWords.t("ошибка кодера: ") + error
        } else if snapshot.segments == 0 {
            status = OurWords.t("поток заводится…")
        } else {
            status = OurWords.t("идёт: кусков ") + "\(snapshot.segments), \(snapshot.width)×\(snapshot.height), "
                + String(format: "%.1f", Double(snapshot.bytesPerSecond) * 8 / 1_000_000) + OurWords.t(" Мбит/с")
        }
    }

    /// Кадр із черги насоса NDI.
    nonisolated func submit(frame: RenderedFrame) {
        encoder.submit(frame: frame)
    }

    /// Звук із відводу плеєра (будь-який потік).
    nonisolated func submitAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        encoder.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: sampleRate)
    }
}

/// Кодер і нарізка: AVAssetWriter у профілі Apple HLS віддає шматки fMP4 сам,
/// нам лишається класти кадри й звук зі спільним годинником і зберігати останні
/// шматки для сервера.
final class HLSEncoder: NSObject, HLSStreamProvider, AVAssetWriterDelegate, @unchecked Sendable {
    struct Snapshot {
        var segments = 0
        var width = 0
        var height = 0
        var bytesPerSecond = 0
        var error: String?
    }

    private let queue = DispatchQueue(label: "slovo.webvideo", qos: .userInitiated)
    private let lock = NSLock()

    // Налаштування (під замком).
    private var wantedHeight = 720
    private var bitrate = 3_000_000
    private var fps = 25

    // Записувач — тільки на своїй черзі.
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audio: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var started = false
    private var startTime: CFTimeInterval = 0
    private var lastVideoAt: CFTimeInterval = 0
    private var audioSamplesWritten: Int64 = 0
    private var encodedWidth = 0
    private var encodedHeight = 0
    private var failure: String?

    // Шматки (під замком): сервер читає їх з іншого потоку.
    private var initData: Data?
    private var segments: [(name: String, data: Data, duration: Double)] = []
    private var nextSequence = 0
    private var bytesWindow: [(at: CFTimeInterval, bytes: Int)] = []

    private static let audioRate = 48_000
    private static let audioChannels = 2

    func configure(height: Int, bitrateKbps: Int) {
        lock.lock()
        wantedHeight = max(180, height)
        bitrate = max(300, bitrateKbps) * 1000
        lock.unlock()
        // Нові налаштування — новий записувач з наступного кадру.
        queue.async { [self] in tearDown(resetSegments: true) }
    }

    func stop() {
        queue.async { [self] in tearDown(resetSegments: true) }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let recent = bytesWindow.filter { now - $0.at <= 5 }
        let perSecond = recent.isEmpty ? 0 : recent.map(\.bytes).reduce(0, +) / 5
        return Snapshot(segments: segments.count, width: encodedWidth, height: encodedHeight,
                        bytesPerSecond: perSecond, error: failure)
    }

    // MARK: - HLSStreamProvider

    func playlist() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard initData != nil, !segments.isEmpty else { return nil }
        let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
        var list = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(max(1, target))\n"
        list += "#EXT-X-MEDIA-SEQUENCE:\(nextSequence - segments.count)\n"
        list += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        for segment in segments {
            list += String(format: "#EXTINF:%.3f,\n", segment.duration) + segment.name + "\n"
        }
        return list
    }

    func initSegment() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return initData
    }

    func segment(named name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return segments.first { $0.name == name }?.data
    }

    // MARK: - Кадри й звук

    func submit(frame: RenderedFrame) {
        queue.async { [self] in
            let now = CACurrentMediaTime()
            // Не частіше за заявлену частоту: насос NDI тікає й на 60.
            if started, now - lastVideoAt < 1.0 / Double(fps) - 0.002 { return }
            if writer == nil { setUp(for: frame) }
            guard let writer, let video, let adaptor, writer.status == .writing else { return }
            if !started {
                startTime = now
                started = true
            }
            guard video.isReadyForMoreMediaData else { return }
            let time = CMTime(seconds: now - startTime, preferredTimescale: 90_000)
            guard let buffer = pixelBuffer(from: frame, adaptor: adaptor) else { return }
            if !adaptor.append(buffer, withPresentationTime: time) {
                noteFailure(writer.error?.localizedDescription ?? OurWords.t("кадр не принят"))
                return
            }
            lastVideoAt = now
            fillSilence(upTo: now - startTime)
        }
    }

    func submitAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        guard channels > 0, samples > 0, sampleRate > 0 else { return }
        queue.async { [self] in
            guard started, let audio, audio.isReadyForMoreMediaData else { return }
            // Зводимо до 48 кГц стерео: у записувача один формат на весь потік.
            let ratio = Double(Self.audioRate) / Double(sampleRate)
            let outSamples = max(1, Int(Double(samples) * ratio))
            var interleaved = [Float](repeating: 0, count: outSamples * Self.audioChannels)
            planar.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: Float.self)
                guard source.count >= channels * samples else { return }
                for i in 0..<outSamples {
                    let position = Double(i) / ratio
                    let index = min(samples - 1, Int(position))
                    let next = min(samples - 1, index + 1)
                    let fraction = Float(position - Double(index))
                    for channel in 0..<Self.audioChannels {
                        let sourceChannel = min(channels - 1, channel)
                        let a = source[sourceChannel * samples + index]
                        let b = source[sourceChannel * samples + next]
                        interleaved[i * Self.audioChannels + channel] = a + (b - a) * fraction
                    }
                }
            }
            // Живий звук не має втікати вперед відео більше ніж на третину
            // секунди — інакше шматки розсинхронізуються; відсталий підтягується
            // тишею в fillSilence.
            let videoClock = CACurrentMediaTime() - startTime
            let audioClock = Double(audioSamplesWritten) / Double(Self.audioRate)
            if audioClock - videoClock > 0.35 { return }
            appendAudio(interleaved, frames: outSamples)
        }
    }

    // MARK: - Внутрішнє

    private func setUp(for frame: RenderedFrame) {
        lock.lock()
        let height = min(wantedHeight, frame.height)
        let bitrate = self.bitrate
        lock.unlock()
        let width = max(2, Int((Double(frame.width) * Double(height) / Double(max(1, frame.height))).rounded() / 2) * 2)
        let evenHeight = max(2, height / 2 * 2)

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: evenHeight,
        ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.audioRate,
            AVNumberOfChannelsKey: Self.audioChannels,
            AVEncoderBitRateKey: 128_000,
        ]
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(Self.audioRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * Self.audioChannels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * Self.audioChannels), mChannelsPerFrame: UInt32(Self.audioChannels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: format)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audio) else {
            noteFailure(OurWords.t("писатель не принял дорожки"))
            return
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            noteFailure(writer.error?.localizedDescription ?? OurWords.t("писатель не запустился"))
            return
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.video = video
        self.adaptor = adaptor
        self.audio = audio
        self.audioFormat = format
        started = false
        audioSamplesWritten = 0
        lock.lock()
        encodedWidth = width
        encodedHeight = evenHeight
        failure = nil
        lock.unlock()
    }

    private func tearDown(resetSegments: Bool) {
        if let writer, writer.status == .writing {
            video?.markAsFinished()
            audio?.markAsFinished()
            writer.finishWriting {}
        }
        writer = nil
        video = nil
        adaptor = nil
        audio = nil
        started = false
        if resetSegments {
            lock.lock()
            initData = nil
            segments.removeAll()
            bytesWindow.removeAll()
            lock.unlock()
        }
    }

    private func noteFailure(_ text: String) {
        lock.lock(); failure = text; lock.unlock()
        tearDown(resetSegments: false)
    }

    private func pixelBuffer(from frame: RenderedFrame, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        if width == frame.width, height == frame.height, stride == frame.bytesPerRow {
            frame.pixels.withUnsafeBytes { raw in
                if let source = raw.baseAddress { memcpy(base, source, min(raw.count, stride * height)) }
            }
            return buffer
        }
        // Інший розмір — малюємо через Core Graphics: масштаб і порядковий
        // крок закриваються одним викликом.
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Поки звуку немає (слайди), доріжку заповнює тиша — інакше плеєр чекає
    /// звук і стоїть.
    private func fillSilence(upTo videoClock: Double) {
        guard let audio, audio.isReadyForMoreMediaData else { return }
        let audioClock = Double(audioSamplesWritten) / Double(Self.audioRate)
        let gap = videoClock - audioClock
        guard gap > 0.08 else { return }
        let frames = min(Int(gap * Double(Self.audioRate)), Self.audioRate / 2)
        guard frames > 0 else { return }
        appendAudio([Float](repeating: 0, count: frames * Self.audioChannels), frames: frames)
    }

    private func appendAudio(_ interleaved: [Float], frames: Int) {
        guard let audio, let audioFormat, let writer, writer.status == .writing else { return }
        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copied = interleaved.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return }
        var sample: CMSampleBuffer?
        let time = CMTime(value: audioSamplesWritten, timescale: CMTimeScale(Self.audioRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if audio.append(sample) {
            audioSamplesWritten += Int64(frames)
        }
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        defer { lock.unlock() }
        switch segmentType {
        case .initialization:
            initData = segmentData
        case .separable:
            let duration = segmentReport?.trackReports.first.map { CMTimeGetSeconds($0.duration) } ?? 1
            let name = "seg\(nextSequence).m4s"
            nextSequence += 1
            segments.append((name, segmentData, duration > 0 ? duration : 1))
            // Тримаємо шість останніх: клієнтові вистачає для старту, пам'ять не росте.
            if segments.count > 6 { segments.removeFirst(segments.count - 6) }
            let now = CACurrentMediaTime()
            bytesWindow.append((now, segmentData.count))
            bytesWindow.removeAll { now - $0.at > 5 }
        @unknown default:
            break
        }
    }
}
