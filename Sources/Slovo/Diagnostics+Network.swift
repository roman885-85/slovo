import Foundation
import Network
import SlovoCore

/// Мережа цієї машини: хто слухає, на яких портах і чому не піднявся.
///
/// Власник: «локальная машина с программой — 192.168.1.33, не работают веб
/// слайды, даже локально», «отключение/включение не сработало, смена порта
/// не сработала», «логов нет в библиотеке». З цього боку не видно нічого:
/// тут усе піднімається. Тому програма мусить сама сказати про себе —
/// розділ читає ЖИВИЙ стан слухачів і стукає в кожен порт із самої себе.
///
/// Нічого не вмикає й не вимикає: людина відкриває «Довідка → Перевірка
/// сумісності» просто під час роботи, і зал чіпати не можна.
extension Diagnostics {

    /// Чи відповідає порт на цій машині. Швидко: 1,5 с на спробу.
    private static func answers(port: Int) -> Bool {
        guard port > 0, let number = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: number, using: .tcp)
        var ready = false
        let done = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready = true; done.signal()
            case .failed, .cancelled: done.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "ua.church.slovo.probe"))
        _ = done.wait(timeout: .now() + 1.5)
        connection.cancel()
        return ready
    }

    @MainActor
    static func networkSection(state: AppState) -> [Check] {
        let area = "Мережа"
        var checks: [Check] = []

        // MARK: Пульт (телефон, планшет, «Проповідник»)
        let remote = RemoteControlServer.shared
        let remoteAnswers = answers(port: remote.port)
        checks.append(Check(area: area, name: "Пульт слухає",
                            status: remote.isRunning && remoteAnswers ? .ok : .failed,
                            detail: "порт \(remote.port), \(remote.isRunning ? "піднято" : "не піднято")"
                                + ", стукіт у себе — \(remoteAnswers ? "відповідає" : "тиша")"
                                + (remote.lastError.map { "; \($0)" } ?? "")))

        // MARK: Пульт у браузері
        checks.append(Check(area: area, name: "Пульт у браузері слухає",
                            status: remote.webRunning ? (answers(port: remote.webPort) ? .ok : .failed) : .skipped,
                            detail: remote.webRunning
                                ? "порт \(remote.webPort)"
                                    + (remote.plainReady ? " і 80" : "; 80 — " + (remote.plainError ?? "не відкрито"))
                                : "вимкнено в налаштуваннях"
                                    + (remote.webError.map { "; \($0)" } ?? "")))

        // MARK: Веб-слайди й Remote API
        //
        // Саме цей блок мовчав на машині власника: сторінки не віддавалися й
        // канал не приймав — при ввімкненому виводі. Показуємо все, що знає
        // сам сервер: порти, підміни, скарги й скільки сторінок підписано.
        let web = state.web.status
        let enabled = state.outputs[.web].isEnabled
        let httpAnswers = answers(port: web.httpPort ?? 0)
        let socketAnswers = answers(port: web.webSocketPort ?? 0)
        checks.append(Check(area: area, name: "Веб-слайди роздаються",
                            status: !enabled ? .skipped : (web.isRunning && httpAnswers ? .ok : .failed),
                            detail: !enabled ? "вивід «Сторінки» вимкнено в налаштуваннях"
                                : "сторінки — порт \(web.httpPort.map(String.init) ?? "немає")"
                                    + " (\(httpAnswers ? "відповідає" : "тиша"))"
                                    + ", канал — порт \(web.webSocketPort.map(String.init) ?? "немає")"
                                    + " (\(socketAnswers ? "відповідає" : "тиша"))"
                                    + (web.lastError.map { "; \($0)" } ?? "")))
        if !web.notices.isEmpty {
            checks.append(Check(area: area, name: "Сервер сторінок має що сказати",
                                status: .warning, detail: web.notices.joined(separator: "; ")))
        }
        checks.append(Check(area: area, name: "Remote API: TCP і UDP",
                            status: !enabled ? .skipped : (web.tcpPort != nil && web.udpPort != nil ? .ok : .warning),
                            detail: !enabled ? "вивід «Сторінки» вимкнено"
                                : "TCP \(web.tcpPort.map(String.init) ?? "немає"), "
                                    + "UDP \(web.udpPort.map(String.init) ?? "немає"), "
                                    + "підписано сторінок \(web.subscribedClients) з \(web.connectedClients)"))

        // MARK: Адреси цієї машини
        checks.append(Check(area: area, name: "Адреси в локальній мережі",
                            status: web.addresses.isEmpty ? .warning : .ok,
                            detail: web.addresses.isEmpty ? "мережевих адрес не видно"
                                : web.addresses.joined(separator: ", ")
                                    + (web.url.map { "; сторінка — \($0)" } ?? "")))

        // MARK: Тека сторінок
        //
        // Сторінки віддаються з теки даних. Немає теки — немає й слайда, хоч
        // сервер і слухає.
        let pages = state.modulesFolder.deletingLastPathComponent()
            .appendingPathComponent("RemoteAPI")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pages.path)) ?? []
        checks.append(Check(area: area, name: "Тека сторінок на місці",
                            status: files.isEmpty ? .failed : .ok,
                            detail: files.isEmpty ? "порожньо чи немає: \(pages.path)"
                                : "\(files.count) файлів у \(pages.path)"))
        return checks
    }
}
