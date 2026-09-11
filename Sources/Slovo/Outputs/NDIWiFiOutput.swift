import AppKit
import SlovoCore

/// Второй источник NDI — «Слово Wi-Fi»: тот же кадр зала, но уменьшенный и
/// реже, чтобы клиент по Wi-Fi выбирал его, а не полный.
///
/// Владелец: основной NDI оставить как есть, а для Wi-Fi — отдельный
/// источник с настройкой качества. У NDI в полной полосе других рычагов
/// качества нет: только размер кадра и частота — ими и управляем.
///
/// Живёт на очереди насоса кадров: кадры и звук приходят оттуда, там же
/// создаётся и закрывается отправитель. Снаружи — только счётчики под
/// замком.
final class NDIWiFiSender: @unchecked Sendable {
    private let lock = NSLock()
    private var sender: NDISender?
    private var height = 360
    private var fps = 15
    private var lastSentAt: CFTimeInterval = 0
    private var lastIdentity: Int?
    private var lastRepeatAt: CFTimeInterval = 0
    /// Уменьшенный кадр для нынешнего отпечатка: слайд не масштабируем
    /// заново на каждый такт.
    private var scaled: (identity: Int, frame: RenderedFrame)?
    private var poll = 0

    private var sentStorage = 0
    private var connectionsStorage = 0
    private var stateStorage = ""

    var sent: Int { lock.lock(); defer { lock.unlock() }; return sentStorage }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return connectionsStorage }
    var state: String { lock.lock(); defer { lock.unlock() }; return stateStorage }

    /// На очереди насоса.
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

    /// На очереди насоса.
    func stop() {
        if sender != nil { NDITrace.say("джерело Wi-Fi: закрито") }
        sender?.close()
        sender = nil
        scaled = nil
        lock.lock(); stateStorage = ""; lock.unlock()
    }

    /// На очереди насоса: приходит каждый такт, отправляем не чаще своей
    /// частоты, неизменный кадр — раз в секунду, как и основной.
    func submit(frame: RenderedFrame) {
        guard let sender else { return }
        let now = CACurrentMediaTime()
        guard now - lastSentAt >= 1.0 / Double(fps) - 0.002 else { return }
        // Ровный поток: неизменный слайд уходит на той же частоте, а не раз в
        // секунду. Владелец: «для Wi-Fi тормозит больше основного» — клиент,
        // не получая кадров, считает поток остановившимся и заново копит
        // буфер; при 640×360 повторы стоят единицы мегабит.
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

    /// На очереди насоса.
    func submitAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        _ = sender?.sendAudio(planar: planar, channels: channels, samples: samples, sampleRate: sampleRate)
    }
}
