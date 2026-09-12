import Foundation

/// Сторож головного потоку.
///
/// Власник: «пропадает изображение на проекторе… отзывчивость может пропасть
/// и не реагировать ни на что, а со временем все накопившиеся нажатия
/// начинают последовательно срабатывать». Щоденник пульта показував паузи по
/// 5–12 с, але не казав, чиї вони: програми чи перевантаженої машини. Тепер
/// кожна затримка головного потоку, довша за секунду, лягає в
/// `slovo-start.txt` — скільки тривала і яке було навантаження Mac, — і її
/// видно поруч із командами пульта та подіями проектора.
///
/// Міряємо не «скільки мовчав», а скільки чекав виклик, поставлений у
/// головну чергу: таймер сторожа на перевантаженій машині й сам буває
/// пізнім, і тоді «мовчання» вийшло б і без вини головного потоку.
final class MainThreadWatchdog: @unchecked Sendable {

    static let shared = MainThreadWatchdog()

    /// Від скількох секунд затримка варта запису.
    private let threshold: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "ua.church.slovo.watchdog", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var sentAt: TimeInterval = 0

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 2, repeating: 0.25, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.ping() }
        timer = source
        source.resume()
    }

    private func ping() {
        lock.lock()
        guard !waiting else { lock.unlock(); return }
        waiting = true
        sentAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.answer() }
    }

    private func answer() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        waiting = false
        let delay = now - sentAt
        lock.unlock()
        guard delay >= threshold else { return }
        NativeTrace.say(String(format: "головний потік не відповідав %.1f с (навантаження Mac %.0f)",
                               delay, Self.loadAverage()))
    }

    /// Середнє навантаження машини за хвилину — те саме число, що в `uptime`.
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : -1
    }
}
