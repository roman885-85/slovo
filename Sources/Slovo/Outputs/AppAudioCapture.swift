import Foundation
import SlovoCore
import ScreenCaptureKit
import CoreMedia
import AVFoundation

/// Звук самой программы — для трансляции NDI.
///
/// Владелец писал: «по NDI не передаётся звук». Его и не было: в сеть уходила
/// одна картинка. Взять звук у плеера напрямую нельзя: у потоков HLS (так
/// идут ролики YouTube) дорожек ресурса нет, и звуковой отвод AVFoundation к
/// ним не цепляется. Поэтому звук снимается с выхода самой программы —
/// системным захватом (ScreenCaptureKit), только для нашего процесса: всё,
/// что программа играет, — фильм, поток, ролик, — попадает в трансляцию
/// тем же путём. Встроенный проигрыватель YouTube — исключение: его звук
/// играет отдельный процесс WebKit, и сюда он не попадает.
///
/// Разрешение «Запись звука системы» спрашивает macOS один раз; без него
/// захват не стартует, и об этом видно в «Параметрах».
@available(macOS 13.0, *)
final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Готовые плоские отсчёты: каналы подряд, в каждом `samples` чисел.
    var onSamples: ((_ planar: Data, _ channels: Int, _ samples: Int, _ sampleRate: Int) -> Void)?
    var onState: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ua.church.slovo.ndi.audio", qos: .userInitiated)
    private(set) var isRunning = false
    /// Сколько звуковых буферов система реально отдала — для самопроверки:
    /// «звук: идёт», но приёмник пуст — значит захват не поставляет ничего.
    private(set) var deliveredCount = 0
    /// Сколько буферов не удалось разобрать.
    private(set) var failedCount = 0
    /// Сколько порций реально отдано наружу.
    private(set) var passedCount = 0

    func start() {
        guard stream == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let pid = ProcessInfo.processInfo.processIdentifier
                guard let me = content.applications.first(where: { $0.processID == pid }),
                      let display = content.displays.first else {
                    self.onState?(OurWords.t("звук: программа не нашла себя среди источников"))
                    return
                }
                let filter = SCContentFilter(display: display, including: [me], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = false
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                // Картинка не нужна — минимальная, раз в секунду.
                // Ноль-размер кадра SCK не принимает; но и 2×2 иногда мешает
                // старту звука. Держим маленький, но не крохотный.
                configuration.width = 16
                configuration.height = 16
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.stream = stream
                self.isRunning = true
                self.onState?(OurWords.t("звук: идёт"))
            } catch {
                self.isRunning = false
                let failure = error as NSError
                // Отказ в разрешении macOS называет по-своему (код −3801,
                // «пользователь отклонил TCC»); человеку нужнее сказать, где
                // его дать.
                let declined = failure.code == -3801 || failure.code == -3802
                    || failure.localizedDescription.contains("TCC")
                    || failure.localizedDescription.lowercased().contains("declined")
                self.onState?(declined
                    ? OurWords.t("звук: нет разрешения на запись звука системы — Системные настройки → Конфиденциальность → Запись экрана и звука системы → «Слово»")
                    : OurWords.t("звук: не стартовал — ") + failure.localizedDescription)
            }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        isRunning = false
        Task { try? await stream?.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let onSamples else { return }
        deliveredCount += 1
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let rate = Int(asbd.mSampleRate)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return }

        // Список буферов надо просить по числу каналов: у стерео их два, а
        // `AudioBufferList` вмещает один — вызов молча отказывал с
        // «массив мал», и звук системы не разбирался НИ РАЗУ. Владелец
        // видел это как «звука с YouTube по NDI нет»: захват шёл, буферы
        // приходили, а дальше не проходило ничего. Флаг выравнивания —
        // обязательный по документации.
        let listSize = AudioBufferList.sizeInBytes(maximumBuffers: channels)
        let listPointer = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(listPointer.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: listSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else {
            failedCount += 1
            if failedCount == 1 || failedCount % 200 == 0 {
                onState?(OurWords.t("звук: система не отдала буферы (%s)", "\(status)"))
            }
            return
        }
        // Отсчёты — float32; система отдаёт их либо по каналам врозь, либо
        // вперемешку. NDI хочет по каналам врозь.
        let planarAlready = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var planar = Data(count: channels * frames * 4)
        planar.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let buffers = listPointer
            if planarAlready {
                for (channel, buffer) in buffers.enumerated() where channel < channels {
                    guard let source = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let count = min(frames, Int(buffer.mDataByteSize) / 4)
                    (out + channel * frames).update(from: source, count: count)
                }
            } else if let first = buffers.first, let source = first.mData?.assumingMemoryBound(to: Float.self) {
                let count = min(frames, Int(first.mDataByteSize) / 4 / channels)
                for frame in 0..<count {
                    for channel in 0..<channels {
                        out[channel * frames + frame] = source[frame * channels + channel]
                    }
                }
            }
        }
        passedCount += 1
        onSamples(planar, channels, frames, rate)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        onState?("звук: остановлен — " + error.localizedDescription)
    }
}
