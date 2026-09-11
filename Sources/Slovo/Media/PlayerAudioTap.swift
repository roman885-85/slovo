import AVFoundation
import MediaToolbox

/// Звуковой отвод плеера — звук фильма для трансляции NDI без разрешений.
///
/// Снимать звук с выхода программы (ScreenCaptureKit) macOS позволяет только
/// после согласия в Системных настройках, и оно привязано к подписи сборки:
/// у владельца разрешение стояло, а программа спрашивала его при каждом
/// запуске. Для файлов с диска есть путь без разрешений вовсе — отвод
/// AVFoundation (`MTAudioProcessingTap`): плеер отдаёт нам те же отсчёты,
/// что играет. У потоков HLS дорожек ресурса нет, отвод к ним не цепляется —
/// там остаётся системный захват, если разрешение уже дано.
///
/// Обратные вызовы отвода идут в звуковом потоке: здесь ничего не ждём и
/// ничего не трогаем из интерфейса — только копируем отсчёты и отдаём дальше.
///
/// Кому принадлежит то, что видит звуковой поток, — вопрос жизни программы.
/// Раньше отводу отдавали неудержанный указатель на сам `PlayerAudioTap`;
/// плеер при смене файла снимал микс и тут же освобождал объект, а звуковой
/// поток ещё успевал вызвать `process` — и программа падала (три отчёта
/// `EXC_BAD_ACCESS` в `PlayerAudioTap.init` за один день). Теперь у отвода
/// своё хранилище: он его удерживает, и отпускает сам в `finalize`, когда
/// звуковой поток с ним уже точно закончил. Владелец отвода может исчезнуть
/// в любой момент — хранилище это переживёт.
final class PlayerAudioTap {

    /// То, к чему обращается звуковой поток. Живёт столько, сколько сам
    /// отвод, а не столько, сколько `PlayerAudioTap`.
    private final class Storage: @unchecked Sendable {
        /// Формат приходит в `prepare`, читается в `process` — оба в звуковом
        /// потоке, замок ему не нужен.
        var format = AudioStreamBasicDescription()

        private let lock = NSLock()
        private var sink: ((_ planar: Data, _ channels: Int, _ samples: Int, _ sampleRate: Int) -> Void)?

        func set(_ sink: ((Data, Int, Int, Int) -> Void)?) {
            lock.lock(); self.sink = sink; lock.unlock()
        }

        /// Отсчёты — в плоский вид, как хочет NDI. Плеер отдаёт float32;
        /// каналы либо врозь, либо вперемешку — смотря по формату.
        func deliver(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            lock.lock()
            let onSamples = sink
            lock.unlock()
            guard let onSamples, frames > 0 else { return }
            let channels = max(1, Int(format.mChannelsPerFrame))
            let rate = Int(format.mSampleRate)
            guard rate > 0 else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var planar = Data(count: channels * frames * 4)
            planar.withUnsafeMutableBytes { raw in
                guard let out = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
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
            onSamples(planar, channels, frames, rate)
        }
    }

    private let storage = Storage()

    /// Плоские отсчёты: каналы подряд, в каждом `samples` float32.
    var onSamples: ((_ planar: Data, _ channels: Int, _ samples: Int, _ sampleRate: Int) -> Void)? {
        get { nil }
        set { storage.set(newValue) }
    }

    /// Микс, который ставится элементу плеера: `item.audioMix = tap.mix`.
    private(set) var mix: AVMutableAudioMix?
    private var tap: MTAudioProcessingTap?

    init?(track: AVAssetTrack) {
        // Отвод удерживает хранилище сам: `passRetained` здесь, `release` в
        // `finalize`. Замыкания ниже — функции C, захватывать им нечего, и
        // всё нужное они берут из хранилища отвода.
        let retained = Unmanaged.passRetained(storage).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let storage = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                storage.format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let storage = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                storage.deliver(buffers, frames: Int(framesOut.pointee))
            })
        var created: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &created) == noErr,
              let created else {
            // Отвода не вышло — `finalize` не позовут, отпускаем сами.
            Unmanaged<Storage>.fromOpaque(retained).release()
            return nil
        }
        tap = created
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        self.mix = mix
    }

    deinit {
        // Владелец ушёл — отсчёты больше некому отдавать. Сам отвод при этом
        // может ещё жить в плеере: он дозвонится в пустое хранилище, а не в
        // освобождённую память.
        storage.set(nil)
    }
}
