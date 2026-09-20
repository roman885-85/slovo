import AppKit
import SlovoCore
import WebKit

/// Веб-слайди: сторінка з теки `RemoteAPI` має показувати те саме, що в залі.
///
/// Власник: «не работают веб слайды». Досі перевірялися лише редактор сторінок
/// і повзунки, а сам вивід — ніколи: програма роздавала сторінки, але те, що
/// сторінка з них малює, ніхто не дивився. Перевірка робить рівно те, що
/// робить браузер: бере `slovo-slide` по HTTP, під'єднується до WebSocket за
/// адресою з самої сторінки, шле `SubscribeToSlideChanges` і чекає пакета.
/// Пакет має нести і текст вірша (секція `Slide` — її читають сторінки
/// автора), і розкладку `Layout` — за нею малює наша сторінка.
extension Diagnostics {

    @MainActor
    static func webSlidesSection(state: AppState) -> [Check] {
        let area = "Веб-слайди"
        var checks: [Check] = []

        let options = state.programOptions
        let httpPort = options.webPort
        let wasEnabled = state.outputs[.web].isEnabled
        if !wasEnabled { state.setWebEnabled(true) }
        defer { if !wasEnabled { state.setWebEnabled(false) } }

        // Щоб було що показувати: вірш у залі, як на служінні.
        let hadLive = state.isLive
        if state.mode != .bible { state.mode = .bible }
        let book = min(42, max(0, state.books.count - 1))
        let shown = DispatchSemaphore(value: 0)
        state.openScripture(bookPosition: book, chapter: 3, verses: [16], then: {
            state.showCurrent()
            shown.signal()
        })
        _ = shown.wait(timeout: .now() + 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { if !hadLive { state.isLive = false } }

        // MARK: Сторінка віддається
        let pageURL = URL(string: "http://127.0.0.1:\(httpPort)/slovo-slide")!
        var page = ""
        var pageStatus = 0
        let gotPage = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: pageURL, timeoutInterval: 10)) { data, response, _ in
            pageStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            page = String(data: data ?? Data(), encoding: .utf8) ?? ""
            gotPage.signal()
        }.resume()
        _ = gotPage.wait(timeout: .now() + 15)

        let socketAddress = page.range(of: "ws://[^'\"]+", options: .regularExpression).map { String(page[$0]) }
        checks.append(Check(area: area, name: "Сторінка слайда віддається",
                            status: pageStatus == 200 && socketAddress != nil ? .ok : .failed,
                            detail: "http://127.0.0.1:\(httpPort)/slovo-slide → \(pageStatus)"
                                + (socketAddress.map { ", канал \($0)" } ?? ", адреси WebSocket у сторінці немає")))

        guard pageStatus == 200, let address = socketAddress, let socketURL = URL(string: address) else {
            return checks
        }

        // MARK: Пакет слайда
        var packets: [[String: Any]] = []
        let gotPacket = DispatchSemaphore(value: 0)
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: socketURL)
        task.resume()
        let subscribe = #"{"Cmd":"SubscribeToSlideChanges","Params":"Out0"}"#
        task.send(.string(subscribe)) { _ in }

        func listen() {
            task.receive { result in
                guard case .success(let message) = result else { gotPacket.signal(); return }
                var text = ""
                switch message {
                case .string(let value): text = value
                case .data(let value): text = String(data: value, encoding: .utf8) ?? ""
                @unknown default: break
                }
                if let data = text.data(using: .utf8),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    packets.append(json)
                    if json["Slide"] != nil { gotPacket.signal(); return }
                }
                listen()
            }
        }
        listen()
        _ = gotPacket.wait(timeout: .now() + 12)
        task.cancel(with: .goingAway, reason: nil)

        let slidePacket = packets.first { $0["Slide"] != nil }
        let variant = ((slidePacket?["Slide"] as? [String: Any])?["Var0"] as? [String: Any])
        let verse = (variant?["Text"] as? String) ?? ((variant?["Out0"] as? [String: Any])?["Pages"] as? [String])?.first ?? ""
        checks.append(Check(area: area, name: "Сторінці приходить текст залу",
                            status: verse.contains("возлюбил") ? .ok : .failed,
                            detail: packets.isEmpty ? "жодного пакета за 12 с"
                                : "пакетів \(packets.count), у слайді «\(verse.prefix(40))»"))

        // Наша сторінка малює за розкладкою: без неї вона лишається чорною,
        // хоч текст у пакеті й є (саме це й побачив власник).
        let layout = slidePacket?["Layout"] as? [String: Any]
        let objects = (layout?["objects"] as? [[String: Any]]) ?? (layout?["Objects"] as? [[String: Any]]) ?? []
        let drawnText = objects.compactMap { $0["text"] as? String ?? $0["Text"] as? String }.joined(separator: " ")
        checks.append(Check(area: area, name: "У пакеті є розкладка, за якою сторінка малює",
                            status: !objects.isEmpty && drawnText.contains("возлюбил") ? .ok : .failed,
                            detail: layout == nil ? "секції Layout у пакеті немає — сторінка лишиться порожньою"
                                : "об'єктів \(objects.count), у них «\(drawnText.prefix(40))»"))

        // MARK: Сторінка справді малює
        //
        // Пакет може бути бездоганним, а сторінка — чорною: саме так і було,
        // коли в її скрипті лишилася неоголошена змінна й `draw()` падав на
        // першому ж рядку. Тому дивимося не на пакет, а на те, що в сторінці
        // намалювалося: відкриваємо її справжнім рушієм браузера й питаємо,
        // скільки об'єктів у сцені та що в них написано.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.load(URLRequest(url: pageURL, timeoutInterval: 15))
        var drawn = ""
        var errors = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let asked = DispatchSemaphore(value: 0)
            let script = """
            (function () {
              var stage = document.getElementById('stage');
              if (!stage) return 'нема сцени';
              var texts = [];
              for (var i = 0; i < stage.children.length; i++) {
                texts.push(stage.children[i].innerText || '');
              }
              return stage.children.length + '|' + texts.join(' ');
            })()
            """
            view.evaluateJavaScript(script) { value, error in
                if let error { errors = "\(error)" }
                drawn = (value as? String) ?? drawn
                asked.signal()
            }
            _ = asked.wait(timeout: .now() + 5)
            if drawn.contains("возлюбил") { break }
        }
        let parts = drawn.split(separator: "|", maxSplits: 1).map(String.init)
        let boxes = Int(parts.first ?? "") ?? 0
        checks.append(Check(area: area, name: "Сторінка малює вірш у браузері",
                            status: boxes > 0 && drawn.contains("возлюбил") ? .ok : .failed,
                            detail: drawn.isEmpty ? "сторінка нічого не відповіла\(errors.isEmpty ? "" : ": " + errors)"
                                : "об'єктів на сцені \(boxes), текст «\((parts.count > 1 ? parts[1] : "").prefix(40))»"))

        // MARK: Значок вкладки
        //
        // У теці авторських сторінок лежить favicon.ico від VisioBible, і
        // браузер брав саме його: у вкладці з нашим слайдом світився чужий
        // знак (власник: «в веб слайдах фавикон от visiobible остался»).
        var icon = Data()
        var iconType = ""
        let gotIcon = DispatchSemaphore(value: 0)
        let iconURL = URL(string: "http://127.0.0.1:\(httpPort)/favicon.ico")!
        URLSession.shared.dataTask(with: URLRequest(url: iconURL, timeoutInterval: 10)) { data, response, _ in
            icon = data ?? Data()
            iconType = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")) ?? ""
            gotIcon.signal()
        }.resume()
        _ = gotIcon.wait(timeout: .now() + 12)
        // PNG починається з \u{89}PNG; значок VisioBible — .ico (00 00 01 00).
        let isPNG = icon.count > 8 && icon.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47])
        checks.append(Check(area: area, name: "Значок вкладки — свій, не від VisioBible",
                            status: isPNG ? .ok : .failed,
                            detail: icon.isEmpty ? "значок не віддається"
                                : "\(icon.count) байт, \(iconType), \(isPNG ? "наш PNG" : "чужий файл із теки")"))

        return checks
    }
}
