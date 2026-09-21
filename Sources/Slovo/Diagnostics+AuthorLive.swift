import Foundation
import AppKit
import WebKit
import SlovoCore

/// Живая проверка страниц автора: доходит ли до них текст.
///
/// Появилась по жалобе владельца: «не подключаются базовые страницы
/// прежняя программа, ожидают подключение, не отображают текущий текст». Всё, что
/// проверялось до неё, смотрело на файл — разметку, блок настроек, ролевые
/// правила. Файл может быть безупречен, а текст не доходить: сервер не
/// поднялся, порт занят, пакет без события, страница подписалась и молчит.
///
/// Поэтому здесь ничего не пересказывается. Поднимается настоящий сервер,
/// страница открывается настоящим браузером по настоящему адресу, в зал
/// уходит настоящий стих — и мы читаем глазами браузера, что на странице
/// написано.
extension Diagnostics {

    /// Ответ одной страницы. Класс, а не структура: его заполняет замыкание
    /// браузера уже после того, как проверка ушла ждать.
    private final class Seen {
        var text: String?
        var asking = false
    }

    /// Подключиться к сокету так, как это делает страница автора: открыть,
    /// послать подписку и подождать первый пакет. Возвращает словами, что
    /// вышло.
    private static func probeSocket(host: String, port: Int) -> String {
        guard let url = URL(string: "ws://\(host):\(port)/ws") else { return "адреса не зібралася" }
        final class Outcome: @unchecked Sendable {
            var opened = false
            var packet: String?
            var failure: String?
            var done = false
        }
        let outcome = Outcome()
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        task.send(.string("{\"Cmd\":\"SubscribeToSlideChanges\",\"Params\":\"Out0\"}")) { error in
            DispatchQueue.main.async {
                if let error { outcome.failure = "відправлення: \(error.localizedDescription)"; outcome.done = true }
                else { outcome.opened = true }
            }
        }
        task.receive { result in
            DispatchQueue.main.async {
                switch result {
                case .success(.string(let text)): outcome.packet = text
                case .success(.data(let data)): outcome.packet = String(decoding: data, as: UTF8.self)
                case .success: outcome.packet = "(пакет іншого виду)"
                case .failure(let error): outcome.failure = "приймання: \(error.localizedDescription)"
                }
                outcome.done = true
            }
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !outcome.done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        task.cancel(with: .normalClosure, reason: nil)
        if let failure = outcome.failure { return failure }
        if let packet = outcome.packet {
            let event = packet.contains("ShowSlide") ? "ShowSlide" : (packet.contains("HideSlide") ? "HideSlide" : "без події")
            return "відкрився, пакет \(packet.count) знаків, \(event)"
        }
        return outcome.opened ? "відкрився, підписка пішла, пакета за 4 с немає" : "не відкрився за 4 с"
    }

    /// Что страница знает о своём сокете.
    private static func askPage(_ view: WKWebView) -> String {
        final class Reply: @unchecked Sendable { var text: String?; var done = false }
        let reply = Reply()
        let script = """
        (function () {
          var jq = (typeof $ !== 'undefined') ? 'jQuery есть' : 'jQuery нет';
          var log = (window.__slovoLog || []).join(', ');
          return jq + ' · ' + (log === '' ? 'сокет не создавался, ошибок нет' : log);
        })()
        """
        view.evaluateJavaScript(script) { value, error in
            reply.text = (value as? String) ?? "помилка: \(error?.localizedDescription ?? "нет ответа")"
            reply.done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !reply.done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return reply.text ?? "сторінка не відповіла за 3 с"
    }

    static func authorLiveSection(state: AppState) -> [Check] {
        let area = "Сторінки автора"
        let files = authorFiles(state: state)
        guard !files.isEmpty else {
            return [Check(area: area, name: "Текст доходить до сторінок автора",
                          status: .skipped, detail: "теку RemoteAPI не знайдено")]
        }

        // Сервер поднимаем свой и на своих портах: занимать те, на которых
        // работает владелец, нельзя, а проверять чужой запущенный сервер —
        // значит проверять неизвестно что.
        let wasRunning = state.web.status.isRunning
        var settings = state.outputs.web
        settings.httpEnabled = true
        settings.webSocketEnabled = true
        settings.httpPort = 18780
        settings.webSocketPort = 18781
        settings.tcpEnabled = false
        settings.udpEnabled = false
        let server = WebOutputServer()
        server.start(settings: settings,
                     dataRoot: state.modulesFolder.deletingLastPathComponent())
        defer { server.stop() }

        // Ждём портов: сервер поднимается на своей очереди, а не тут же.
        var port: Int?
        var wait = Date().addingTimeInterval(6)
        while Date() < wait, port == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            port = server.status.httpPort
        }
        guard let httpPort = port else {
            return [Check(area: area, name: "Текст доходить до сторінок автора",
                          status: .failed,
                          detail: "сервер не піднявся: "
                              + (server.status.lastError ?? "порт \(settings.httpPort) не відкрився"))]
        }

        // Стих заведомо свой: по нему и узнаём, что на странице именно он, а
        // не остаток прошлого показа.
        let mark = "Слово-\(Int(Date().timeIntervalSince1970) % 100000)"
        let slide = Slide(mainText: "Проба зв'язку \(mark).",
                          secondaryTexts: [],
                          reference: "Проба \(mark)")
        server.publish(slide: slide, kind: .web)

        var views: [WKWebView] = []
        var seen: [Seen] = []
        let configuration = WKWebViewConfiguration()
        // Перехват до загрузки страницы: что она делает с сокетом и на чём
        // спотыкается её скрипт. Без этого проверка видит только надпись
        // «Підключення…» и не может сказать, почему.
        let hook = """
        (function () {
          window.__slovoLog = [];
          var log = function (m) { window.__slovoLog.push(m); };
          window.addEventListener('error', function (e) {
            log('ошибка скрипта: ' + (e.message || e) + ' (' + (e.lineno || '?') + ')');
          });
          var Real = window.WebSocket;
          window.WebSocket = function (url, protocols) {
            log('WebSocket(' + url + ')');
            var ws = protocols === undefined ? new Real(url) : new Real(url, protocols);
            ws.addEventListener('open', function () { log('открыт'); });
            ws.addEventListener('error', function () { log('ошибка сокета'); });
            ws.addEventListener('close', function (e) { log('закрыт ' + e.code); });
            ws.addEventListener('message', function (e) { log('пакет ' + String(e.data).length); });
            return ws;
          };
          window.WebSocket.prototype = Real.prototype;
          window.WebSocket.CONNECTING = 0; window.WebSocket.OPEN = 1;
          window.WebSocket.CLOSING = 2; window.WebSocket.CLOSED = 3;
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for file in files {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                 configuration: configuration)
            let address = "http://127.0.0.1:\(httpPort)/\(file.lastPathComponent)"
            if let url = URL(string: address) { view.load(URLRequest(url: url)) }
            views.append(view)
            seen.append(Seen())
        }

        // Страница подписывается не сразу: сначала грузится jQuery, потом
        // открывается сокет, и только потом приходит слайд. Поэтому слайд
        // отправляем ещё раз по ходу ожидания — как это делает оператор,
        // листая стих, — и ждём до двадцати секунд.
        let deadline = Date().addingTimeInterval(20)
        var resent = Date()
        // Ждём не «какой-нибудь текст», а именно наш стих: стартовая надпись
        // «Підключення…» стоит на странице с первого мгновения, и по ней
        // проверка однажды решила, что ждать больше нечего.
        func showsMark(_ answer: Seen) -> Bool { (answer.text ?? "").contains(mark) }
        while Date() < deadline && seen.contains(where: { !showsMark($0) }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if Date().timeIntervalSince(resent) > 2 {
                resent = Date()
                server.publish(slide: slide, kind: .web)
            }
            for (index, view) in views.enumerated()
            where !showsMark(seen[index]) && !seen[index].asking && !view.isLoading {
                let answer = seen[index]
                answer.asking = true
                view.evaluateJavaScript("document.body.innerText") { value, _ in
                    answer.asking = false
                    if let text = value as? String { answer.text = text }
                }
            }
        }

        // Подписки считаем до прямых проб из Swift: они тоже подписываются,
        // и после них счётчик говорил бы о нас, а не о страницах.
        let subscribedByPages = server.status.subscribedClients
        let connectedByPages = server.status.connectedClients

        var trouble: [String] = []
        var good = 0
        for (index, file) in files.enumerated() {
            let text = (seen[index].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains(mark) {
                good += 1
            } else if text.isEmpty {
                trouble.append("\(file.lastPathComponent): порожньо")
            } else {
                trouble.append("\(file.lastPathComponent): «\(text.prefix(40))»")
            }
        }

        // Когда текст не дошёл, важно знать не «не дошёл», а где оборвалось:
        // отдалась ли страница, подменён ли в ней порт сокета, доехала ли
        // библиотека jQuery, на каком порту сокет и что он сказал.
        var served = ""
        if let url = URL(string: "http://127.0.0.1:\(httpPort)/\(files[0].lastPathComponent)"),
           let text = try? String(contentsOf: url, encoding: .utf8) { served = text }
        let wsLine = served.components(separatedBy: .newlines)
            .first { $0.contains("ws://") || $0.contains("wsUrl") }?
            .trimmingCharacters(in: .whitespaces) ?? "рядка ws:// у відданій сторінці немає"
        let jquerySize = (URL(string: "http://127.0.0.1:\(httpPort)/i/jquery-3.6.0.min.js")
            .flatMap { try? Data(contentsOf: $0) })?.count ?? 0
var parts: [String] = []
        parts.append("сторінку віддано: \(served.count) знаків")
        parts.append(String(wsLine.prefix(90)))
        parts.append("jQuery: \(jquerySize) байт")
        let httpText = server.status.httpPort.map(String.init) ?? "немає"
        let socketText = server.status.webSocketPort.map(String.init) ?? "немає"
        parts.append("порти http \(httpText), сокет \(socketText)")
        parts.append(server.status.lastError ?? "без помилок")
        if !server.status.notices.isEmpty { parts.append(server.status.notices.joined(separator: " · ")) }
        parts.append("мітка адреси лишилася: " + (served.contains("'{{SERVER_ADDR}}'") ? "так" : "ні"))
        // Сокет — напрямую из Swift, минуя браузер: если он отвечает нам, а
        // странице нет, беда в браузере или в адресе; если молчит и нам —
        // в самом сервере.
        parts.append("сокет напряму: " + probeSocket(host: "127.0.0.1", port: 18781))
        parts.append("сокет по localhost: " + probeSocket(host: "localhost", port: 18781))
        // И глазами страницы: до какого адреса она стучится и в каком
        // состоянии её сокет (0 соединяется, 1 открыт, 3 закрыт).
        parts.append("сторінка: " + askPage(views[0]))
        let road = parts.joined(separator: "; ")

        var checks: [Check] = []
        checks.append(Check(area: area, name: "Текст доходить до сторінок автора",
                            status: good == files.count ? .ok : (good > 0 ? .warning : .failed),
                            detail: good == files.count
                                ? "вірш побачили всі \(files.count) сторінок автора"
                                : "показали вірш \(good) із \(files.count); "
                                    + trouble.prefix(3).joined(separator: "; ") + "; " + road))

        // Отдельной строкой — подписался ли кто-нибудь вообще: если ни один,
        // причина не в разметке страниц, а в сокете.
        checks.append(Check(area: area, name: "Сторінки автора підписалися на слайди",
                            status: subscribedByPages > 0 ? .ok : .failed,
                            detail: "підписано \(subscribedByPages) із \(files.count),"
                                + " з'єднань \(connectedByPages)"))

        // Страница, открытая после показа, обязана получить текущий слайд
        // сразу: у владельца страницу открывают в середине служения.
        let late = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                             configuration: configuration)
        if let url = URL(string: "http://127.0.0.1:\(httpPort)/\(files[0].lastPathComponent)") {
            late.load(URLRequest(url: url))
        }
        let lateSeen = Seen()
        wait = Date().addingTimeInterval(12)
        while Date() < wait, !showsMark(lateSeen) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if !late.isLoading && !lateSeen.asking {
                lateSeen.asking = true
                late.evaluateJavaScript("document.body.innerText") { value, _ in
                    lateSeen.asking = false
                    if let text = value as? String { lateSeen.text = text }
                }
            }
        }
        let lateText = (lateSeen.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        checks.append(Check(area: area, name: "Сторінка, відкрита пізніше, отримує поточний вірш",
                            status: lateText.contains(mark) ? .ok : .failed,
                            detail: lateText.contains(mark)
                                ? "відкрилася посеред показу й одразу показала вірш"
                                : "показала «\(lateText.prefix(40))» замість поточного вірша"))

        if wasRunning {
            checks.append(Check(area: area, name: "Сервер власника не зачеплено",
                                status: state.web.status.isRunning ? .ok : .failed,
                                detail: state.web.status.isRunning
                                    ? "працює як працював"
                                    : "перевірка збила справжній сервер"))
        }
        return checks
    }
}
