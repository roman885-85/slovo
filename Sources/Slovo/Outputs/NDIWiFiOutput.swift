import AppKit
import SlovoCore

/// Друге джерело NDI — «Слово Wi-Fi»: той самий кадр залу, але зменшений і
/// рідше, щоб клієнт по Wi-Fi вибирав його, а не повний.
///
/// Власник: основний NDI лишити як є, а для Wi-Fi — окреме
/// джерело з налаштуванням якості. У NDI в повній смузі інших важелів
/// якості немає: тільки розмір кадру й частота — ними й керуємо.
///
/// Живе на черзі насоса кадрів: кадри й звук приходять звідти, там же
/// створюється й закривається відправник. Ззовні — тільки лічильники під
/// замком.
final class NDIWiFiSender: @unchecked Sendable {
    private let lock = NSLock()
    private var sender: NDISender?
    private var height = 360
    private var fps = 15
    private var lastSentAt: CFTimeInterval = 0
    private var lastIdentity: Int?
    private var lastRepeatAt: CFTimeInterval = 0
    /// Зменшений кадр для теперішнього відбитка: слайд не масштабуємо
    /// заново на кожен такт.
    private var scaled: (identity: Int, frame: RenderedFrame)?
    private var poll = 0

    private var sentStorage = 0
    private var connectionsStorage = 0
    private var stateStorage = ""

    var sent: Int { lock.lock(); defer { lock.unlock() }; return sentStorage }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return connectionsStorage }
    var state: String { lock.lock(); defer { lock.unlock() }; return stateStorage }

    /// На черзі насоса.
    func start(name: String, height: Int, fps: Int) {
        self.height = max(90, height)
        self.fps = max(1, min(60, fps))
        if sender != nil { NDITrace.say("джерело Wi-Fi: попереднє закрито перед новим запуском") }
        sender?.close()
        sender = NDIRuntime.makeSender(name: name)
        NDITrace.say("источник Wi-Fi: " + (sender == nil ? "НЕ создан" : "создан «\(name)»") + ", \(self.height)p \(self.fps) к/с")
        lastIdentity = nil
        scaled = nil
        lock.lock()
        sentStorage = 0
        connectionsStorage = 0
        stateStorage = sender == nil ? OurWords.t("NDI не дал создать источник") : OurWords.t("источник создан")
        lock.unlock()
    }

    /// На черзі насоса.
    func stop() {
        if sender != nil { NDITrace.say("джерело Wi-Fi: закрито") }
        sender?.close()
        sender = nil
        scaled = nil
        lock.lock(); stateStorage = ""; lock.unlock()
    }

    /// На черзі насоса: приходить кожен такт, надсилаємо не частіше за свою
    /// частоту, незмінний кадр — раз на секунду, як і основний.
    func submit(frame: RenderedFrame) {
        guard let sender else { return }
        let now = CACurrentMediaTime()
        guard now - lastSentAt >= 1.0 / Double(fps) - 0.002 else { return }
        // Рівний потік: незмінний слайд іде на тій самій частоті, а не раз на
        // секунду. Власник: «для Wi-Fi тормозит больше основного» — клієнт,
        // не отримуючи кадрів, вважає потік зупиненим і заново накопичує
        // буфер; за 640×360 повтори коштують одиниці мегабіт.
        let changed = lastIdentity != frame.identity

        if scaled?.identity != frame.identity {
            // Зменшуємо vImage по готових байтах, а не перемальовуванням
            // CoreGraphics: на фільмі відпечаток міняється щокадру, і
            // перемальовування 1280×720 з'їдало такт насоса — від цього
            // «тормозив» і Wi-Fi, і основне джерело.
            //
            // Без альфа-каналу: слабкому клієнту 4:2:2 без площини прозорості
            // декодувати вдвічі легше, а прозорість по Wi-Fi нікому не потрібна.
            guard let small = NDIOutput.downscaled(frame, height: height,
                                                   identity: frame.identity) else { return }
            scaled = (frame.identity, small)
        }
        guard let small = scaled?.frame else { return }
        sender.send(small, frameRate: fps, opaque: true)
        lastSentAt = now
        lastIdentity = frame.identity
        if changed { lastRepeatAt = now }

        poll += 1
        let refresh = poll % max(1, fps) == 0
        lock.lock()
        sentStorage &+= 1
        if refresh { connectionsStorage = sender.connectionCount() }
        stateStorage = OurWords.t("идёт: ") + "\(small.width)×\(small.height), \(fps) " + OurWords.t("к/с")
            + OurWords.t(", приёмников ") + "\(connectionsStorage)"
        lock.unlock()
    }

    /// На черзі насоса.
    func submitAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        _ = sender?.sendAudio(planar: planar, channels: channels, samples: samples, sampleRate: sampleRate)
    }
}
