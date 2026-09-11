import Foundation

/// Пульт на зв'язку — програма не дрімає, а комп'ютер не засинає.
///
/// Власник: «андроид программа постоянно теряет связь с программой».
/// macOS присипляє програму, чиє вікно не на виду (App Nap): таймери й
/// відповіді відкладаються на десятки секунд. Телефон тримає «довге
/// опитування» — програма відповідає за 15 с, телефон чекає 40, — і під
/// App Nap відповідь запізнювалася: двічі поспіль нема відповіді — телефон
/// пише «немає зв'язку», а потім зв'язок сам повертається. Звідси
/// «постійно губить».
///
/// Тому: поки слухає канал пульта (телефон чи браузер), App Nap вимкнено.
/// Поки пульт справді на зв'язку — запити за останні 10 хвилин, — не
/// засинає й сам комп'ютер: інакше зв'язок рветься разом зі сном. Без пульта
/// комп'ютер засинає як завжди.
@MainActor
final class RemoteWakefulness {

    static let shared = RemoteWakefulness()

    private var noNap: NSObjectProtocol?
    private var noSleep: NSObjectProtocol?
    private var lastRequest = Date.distantPast
    private var watch: Timer?

    /// Комп'ютер зараз не засинає, бо пульт на зв'язку.
    private(set) var keepsAwake = false
    /// App Nap вимкнено, бо слухає канал пульта.
    var noNapHeld: Bool { noNap != nil }

    /// Як довго після останнього запиту пульт вважаємо «на зв'язку».
    static let quietAfter: TimeInterval = 600
    static let sleepReason = "Пульт «Слова» на зв'язку"

    private init() {}

    /// Канал пульта почав або перестав слухати.
    func listening(_ on: Bool) {
        if on, noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Канал пульта «Слова»: відповідати телефону без затримок")
            NativeTrace.say("пульт: App Nap вимкнено, поки слухає канал")
        } else if !on, let token = noNap {
            ProcessInfo.processInfo.endActivity(token)
            noNap = nil
            release()
        }
    }

    /// Прийшов запит від телефона, планшета чи браузера.
    func request() {
        lastRequest = Date()
        guard noSleep == nil else { return }
        noSleep = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: Self.sleepReason)
        keepsAwake = true
        NativeTrace.say("пульт на зв'язку — комп'ютер не засинає")
        watch = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfQuiet() }
        }
    }

    private func expireIfQuiet() {
        if Date().timeIntervalSince(lastRequest) > Self.quietAfter { release() }
    }

    private func release() {
        watch?.invalidate()
        watch = nil
        guard let token = noSleep else { return }
        ProcessInfo.processInfo.endActivity(token)
        noSleep = nil
        keepsAwake = false
        NativeTrace.say("пульт мовчить 10 хвилин — комп'ютер знову може засинати")
    }
}
