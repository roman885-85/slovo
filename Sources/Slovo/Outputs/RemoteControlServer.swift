import AppKit
import Combine
import Network
import SlovoCore

/// Канал пульта: телефон в той же сети управляет показом.
///
/// Свой канал, а не Remote API автора. Тот протокол — про раздачу слайдов
/// страницам и микшеру: подписчики получают текст, а команд «дальше» и
/// «показать» в нём нет. Здесь наоборот: маленький HTTP с JSON, где телефон
/// спрашивает состояние и шлёт команды. HTTP взят потому, что на телефоне
/// он есть без единой библиотеки, а состояние отдаётся долгим опросом:
/// сервер держит ответ до первого изменения, и телефон узнаёт о смене
/// слайда сразу, не жгя батарею опросами.
///
/// Найти программу телефон может двумя путями: по Bonjour (`_slovo._tcp`)
/// и криком в сеть — UDP на порт 8104 со словом `SLOVO?`, на который
/// отвечаем именем и портом. Оба — потому что роутеры режут то одно, то
/// другое.
///
/// Работа с состоянием — только на главном потоке: разбор запроса идёт на
/// очереди канала, а ответ собирается там, где живёт `AppState`.
@MainActor
final class RemoteControlServer {

    static let shared = RemoteControlServer()

    /// Порт рассылки для поиска программы в сети — общий уговор с телефоном.
    static let beaconPort: UInt16 = 8104
    static let beaconQuestion = "SLOVO?"

    private(set) var port = 0
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Номер состояния: растёт на каждое изменение, телефон по нему ждёт.
    private(set) var seq = 1
    private(set) var requestCount = 0
    private(set) var beaconCount = 0

    private weak var state: AppState?
    private var pin = ""
    private var wantedPort = 8103
    private var listener: NWListener?
    /// Слухач пульта в браузері — на своєму порту, окремо від телефона.
    private var webListener: NWListener?
    private var webEnabled = false
    private var wantedWebPort = 8105
    private var webPassword = ""
    private var webName = "slovo"
    /// На якому порту справді відповідає сторінка; 0 — не відповідає.
    private(set) var webPort = 0
    private(set) var webRunning = false
    /// Чому сторінка не піднялася — словами, для вікна й параметрів.
    private(set) var webError: String?
    /// Лише перегляд: сторінка показує зал, але не керує.
    private(set) var webViewOnly = false
    /// Чи питає сторінка пароль — для вікна й параметрів, без самого пароля.
    var webHasPassword: Bool { !webPassword.isEmpty }
    /// Другий вхід сторінки — порт 80, щоб за ім'ям вистачало slovo.local без
    /// номера. Власник: «нужно, чтобы веб версия по имени открывалась без
    /// указания порта». Зайнятий на цій машині — не біда: сторінка лишається
    /// на своєму порту, і вікно скаже, що адреса — з номером.
    private var plainListener: NWListener?
    /// Чи просили відкривати й без номера порту.
    private(set) var webNoPort = true
    /// Порт 80 справді відповідає.
    private(set) var plainReady = false
    /// Чому порт 80 не відповідає — словами.
    private(set) var plainError: String?
    /// Коли кожен телефон, планшет чи браузер останній раз озивався — для
    /// журналу: «знову на зв'язку після N с тиші» показує обриви.
    private var clientsSeen: [String: Date] = [:]
    private var beacon: NWListener?
    private let queue = DispatchQueue(label: "ua.church.slovo.remote")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waiters: [Waiter] = []
    private var tokens: [Signals.Token] = []
    private var watchers: [AnyCancellable] = []
    private var fingerprint = Data()
    private var checkScheduled = false

    private struct Waiter {
        let connection: NWConnection
        let timeout: DispatchWorkItem
        /// Прийшов портом браузерного пульта: йому — стан із «лише перегляд».
        let web: Bool
    }

    /// Простой разобранный запрос HTTP.
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        /// Прийшов портом браузерного пульта.
        var web = false
    }

    private init() {}

    // MARK: - Включение

    /// Применить настройки: включить, перезапустить на другом порту или
    /// остановить. Зовётся из `applyProgramOptions` — на «Ок» и при запуске.
    func apply(enabled: Bool, port: Int, pin: String, state: AppState) {
        self.state = state
        self.pin = pin
        guard enabled else { stop(); return }
        if isRunning, port == wantedPort { return }
        stop()
        wantedPort = port
        start()
    }

    private func start() {
        guard let state else { return }
        subscribe(state: state)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, wantedPort)))) else { return }
        do {
            let created = try NWListener(using: parameters, on: endpointPort)
            // Объявление в Bonjour: телефон видит «Слово» в списке без адресов.
            let host = Host.current().localizedName ?? "Mac"
            created.service = NWListener.Service(name: "Слово (\(host))", type: "_slovo._tcp")
            created.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }
            created.stateUpdateHandler = { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.listenerChanged(status, listener: created) }
                }
            }
            listener = created
            created.start(queue: queue)
        } catch {
            lastError = "\(error)"
            NativeTrace.say("пульт: слухач не піднявся — \(error)")
        }
        startBeacon()
    }

    // MARK: - Пульт у браузері

    /// Увімкнути, перезапустити на іншому порту чи з іншим ім'ям, або
    /// вимкнути сторінку для браузера. Власник: «взять нестандартный порт,
    /// т.к. на другой машине он может быть занят» і «включение и отключение,
    /// вход с паролем или без, выбор порта». Вимкнули — порт закритий зовсім.
    func applyWeb(enabled: Bool, port: Int, password: String, name: String, viewOnly: Bool, noPort: Bool = true) {
        webPassword = password
        webViewOnly = viewOnly
        let clean = RemoteName.clean(name)
        let unchanged = enabled == webEnabled && port == wantedWebPort && clean == webName
            && noPort == webNoPort && (webListener != nil) == enabled
        webEnabled = enabled
        wantedWebPort = port
        webName = clean
        webNoPort = noPort
        if unchanged { noteChange(); return }
        stopWeb()
        if enabled { startWeb() }
    }

    private func startWeb() {
        guard let state else { return }
        subscribe(state: state)
        guard wantedWebPort != wantedPort || !isRunning else {
            webError = OurWords.t("этот порт уже занят пультом телефона — выберите другой")
            RemoteName.shared.onChange?()
            return
        }
        guard let endpoint = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, wantedWebPort)))) else { return }
        // Без `allowLocalEndpointReuse`: зайнятий іншою програмою порт має
        // відмовити одразу, а не тихо ділити з нею з'єднання.
        do {
            let created = try NWListener(using: .tcp, on: endpoint)
            created.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection, web: true) }
            }
            created.stateUpdateHandler = { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.webChanged(status, listener: created) }
                }
            }
            webListener = created
            created.start(queue: queue)
        } catch {
            webError = "\(error)"
            NativeTrace.say("пульт у браузері: слухач не піднявся — \(error)")
            RemoteName.shared.onChange?()
        }
    }

    private func webChanged(_ status: NWListener.State, listener created: NWListener) {
        guard created === webListener else { return }
        switch status {
        case .ready:
            webPort = Int(created.port?.rawValue ?? 0)
            webRunning = true
            webError = nil
            NativeTrace.say("пульт у браузері: порт \(webPort)")
            RemoteName.shared.start(name: webName)
            if webNoPort, wantedWebPort != 80, wantedPort != 80, plainListener == nil { startPlain() }
        case .failed(let error):
            webRunning = false
            webPort = 0
            webError = Self.portProblem(error, port: wantedWebPort)
            NativeTrace.say("пульт у браузері: \(error)")
            created.cancel()
            webListener = nil
            RemoteName.shared.stop()
        case .cancelled:
            webRunning = false
        default:
            break
        }
        RemoteName.shared.onChange?()
        updateWakefulness()
    }

    /// Порт 80 — щоб у браузері вистачало імені без номера.
    private func startPlain() {
        guard let port80 = NWEndpoint.Port(rawValue: 80) else { return }
        do {
            let created = try NWListener(using: .tcp, on: port80)
            created.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection, web: true) }
            }
            created.stateUpdateHandler = { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.plainChanged(status, listener: created) }
                }
            }
            plainListener = created
            created.start(queue: queue)
        } catch {
            plainError = OurWords.t("порт 80 занят — адрес с номером порта")
            NativeTrace.say("пульт у браузері: порт 80 — \(error)")
        }
    }

    private func plainChanged(_ status: NWListener.State, listener created: NWListener) {
        guard created === plainListener else { return }
        switch status {
        case .ready:
            plainReady = true
            plainError = nil
            NativeTrace.say("пульт у браузері: і без номера порту — порт 80")
        case .failed(let error):
            plainReady = false
            plainError = OurWords.t("порт 80 занят — адрес с номером порта")
            NativeTrace.say("пульт у браузері: порт 80 зайнятий — \(error)")
            created.cancel()
            plainListener = nil
        case .cancelled:
            plainReady = false
        default:
            break
        }
        RemoteName.shared.onChange?()
    }

    /// App Nap і сон — за тим, чи слухає хоч один канал пульта.
    private func updateWakefulness() {
        RemoteWakefulness.shared.listening(isRunning || webRunning)
    }

    /// Журнал: хто на зв'язку і після якої тиші повернувся.
    private func noteClient(_ connection: NWConnection, web: Bool) {
        guard case .hostPort(let host, _) = connection.endpoint else { return }
        let address = "\(host)"
        let now = Date()
        if let last = clientsSeen[address] {
            let quiet = now.timeIntervalSince(last)
            if quiet > 90 { NativeTrace.say("пульт: \(address) знову на зв'язку після \(Int(quiet)) с тиші") }
        } else {
            NativeTrace.say("пульт: на зв'язку \(address) — \(web ? "браузер" : "телефон чи планшет")")
        }
        clientsSeen[address] = now
    }

    private func stopWeb() {
        plainListener?.cancel()
        plainListener = nil
        plainReady = false
        plainError = nil
        webListener?.cancel()
        webListener = nil
        webRunning = false
        webPort = 0
        webError = nil
        RemoteName.shared.stop()
        updateWakefulness()
    }

    /// Відмову мережі — словами: найчастіше порт зайнятий іншою програмою.
    private static func portProblem(_ error: NWError, port: Int) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return OurWords.t("порт %s занят другой программой — выберите другой", "\(port)")
        }
        return "\(error)"
    }

    func stop() {
        listener?.cancel()
        listener = nil
        beacon?.cancel()
        beacon = nil
        for waiter in waiters { waiter.timeout.cancel(); waiter.connection.cancel() }
        waiters.removeAll()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isRunning = false
        port = 0
        updateWakefulness()
    }

    private func listenerChanged(_ status: NWListener.State, listener created: NWListener) {
        guard created === listener else { return }
        switch status {
        case .ready:
            port = Int(created.port?.rawValue ?? 0)
            isRunning = true
            lastError = nil
            NativeTrace.say("пульт: слушаю порт \(port)")
            updateWakefulness()
        case .failed(let error):
            isRunning = false
            lastError = "\(error)"
            NativeTrace.say("пульт: ошибка — \(error)")
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    /// Следить за состоянием: любое изменение поднимает номер и будит
    /// телефоны, которые ждут.
    private func subscribe(state: AppState) {
        guard tokens.isEmpty else { return }
        tokens.append(Signals.shared.subscribe([.slide, .mode, .live, .plan, .history, .songSelection,
                                                .songPart, .verseSelection, .translations]) { [weak self] _ in
            self?.scheduleCheck()
        })
        watchers.append(DeskModel.shared.objectWillChange.sink { [weak self] _ in self?.scheduleCheck() })
        watchers.append(state.media.objectWillChange.sink { [weak self] _ in self?.scheduleCheck() })
        watchers.append(NativeSongsWorkspace.shared.model.objectWillChange.sink { [weak self] _ in self?.scheduleCheck() })
        // Указка теж будить телефони: пляму, яку ведуть мишею з комп'ютера,
        // телефон малює в себе на картинці. Але не частіше ~12 разів на
        // секунду — миша дає до сотні подій, і кожна тягла б повний стан.
        watchers.append(NotificationCenter.default.publisher(for: SlidePointer.changed)
            .sink { [weak self] _ in self?.pointerChanged() })
    }

    private var pointerWakeAt = Date.distantPast
    private var pointerWakePending = false

    /// Пляма посунулася: підняти номер стану, але з проріджуванням — і з
    /// «хвостовим» викликом, щоб останнє положення і «прибрано» дійшли завжди.
    private func pointerChanged() {
        let now = Date()
        let gap = now.timeIntervalSince(pointerWakeAt)
        if gap >= 0.08 {
            pointerWakeAt = now
            scheduleCheck()
            return
        }
        guard !pointerWakePending else { return }
        pointerWakePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.08 - gap)) { [weak self] in
            guard let self else { return }
            self.pointerWakePending = false
            self.pointerWakeAt = Date()
            self.scheduleCheck()
        }
    }

    func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        // Значения ещё не записаны, когда приходит `objectWillChange`; сверяем
        // в конце текущего оборота цикла событий.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.checkScheduled = false
            self?.noteChange()
        }
    }

    /// Сверить отпечаток состояния и, если он другой, поднять номер и
    /// ответить ждущим.
    func noteChange() {
        guard isRunning || webRunning || !waiters.isEmpty else { return }
        var snapshot = stateJSON()
        snapshot["seq"] = nil
        // Указка входить у відбиток: телефон показує її в себе. Частоту
        // пробуджень обмежує `pointerChanged`, а не викидання з відбитка.
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        // Сравниваем снимок целиком, а не его hashValue. У Data в Foundation
        // хеш считается по длине и первым 80 байтам: перелистывание страницы
        // («Сторінка 1» → «Сторінка 2») или смена файла («проба-1» →
        // «проба-2») длину не меняют, и хеш совпадал — номер состояния не
        // рос, телефон не будили. Владелец видел это как «при перелистывании
        // презентаций на пульте ничего не меняется».
        guard data != fingerprint else { return }
        fingerprint = data
        seq += 1
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.timeout.cancel()
            respond(waiter.connection, 200, stateJSON(web: waiter.web))
        }
    }

    // MARK: - Рассылка

    private func startBeacon() {
        guard let endpointPort = NWEndpoint.Port(rawValue: Self.beaconPort) else { return }
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let created = try NWListener(using: parameters, on: endpointPort)
            created.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.answerBeacon(connection) }
            }
            beacon = created
            created.start(queue: queue)
        } catch {
            NativeTrace.say("пульт: розсилка не піднялася — \(error)")
        }
    }

    /// Каждая пришедшая датаграмма — своё «соединение»: читаем вопрос и
    /// отвечаем туда же.
    nonisolated private func answerBeacon(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                  text.hasPrefix(Self.beaconQuestion) else { connection.cancel(); return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.beaconCount += 1
                    let reply: [String: Any] = [
                        "app": "Slovo",
                        "name": Host.current().localizedName ?? "Слово",
                        "port": self.port,
                    ]
                    let bytes = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                    connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    // MARK: - HTTP

    nonisolated private func accept(_ connection: NWConnection, web: Bool = false) {
        let key = ObjectIdentifier(connection)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.connections[key] = connection } }
        connection.stateUpdateHandler = { [weak self] status in
            if case .cancelled = status {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connections[key] = nil } }
            } else if case .failed = status {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connections[key] = nil } }
            }
        }
        connection.start(queue: queue)
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if let parsed = Self.parse(buffer) {
                    var routed = parsed
                    routed.web = web
                    let request = routed
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.handle(request, on: connection) }
                    }
                    return
                }
                // Командам хватает 256 КБ; загрузка презентации с телефона
                // объявляет длину заранее — ей даём столько, сколько сказано,
                // но не больше 256 МБ.
                let allowed = max(262_144, min(268_435_456, (Self.declaredLength(buffer) ?? 0) + 65_536))
                if complete || error != nil || buffer.count > allowed { connection.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    /// Объявленная длина тела — из заголовков, как только они пришли целиком.
    nonisolated private static func declaredLength(_ data: Data) -> Int? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Разобрать запрос, когда он пришёл целиком. Пока не целиком — `nil`.
    nonisolated private static func parse(_ data: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = requestLine[1]
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
                query[name] = value
            }
        }
        return Request(method: requestLine[0].uppercased(), path: path, query: query, headers: headers, body: Data(body))
    }

    func respond(_ connection: NWConnection, _ status: Int, _ json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        respondData(connection, status, body, contentType: "application/json; charset=utf-8")
    }

    /// Ответ произвольными байтами — картинка страницы для телефона.
    func respondData(_ connection: NWConnection, _ status: Int, _ body: Data, contentType: String,
                     headers extra: [String: String] = [:]) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 400: reason = "Bad Request"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Разбор команд

    private func handle(_ request: Request, on connection: NWConnection) {
        requestCount += 1
        RemoteWakefulness.shared.request()
        noteClient(connection, web: request.web)
        guard let state else { respond(connection, 400, ["error": OurWords.t("нет состояния")]); return }
        // Сторінка й програми для Android — лише на порту браузерного пульта
        // і до перевірки пароля: секретів у них немає, а браузер при першому
        // відкритті заголовка з паролем прислати не може. Пароль сторінка
        // спитає сама, щойно канал відповість «pin».
        if request.web, request.method == "GET" {
            if request.path == "/" || request.path == "/index.html" {
                respondData(connection, 200, Data(RemoteWebPage.html.utf8), contentType: "text/html; charset=utf-8")
                return
            }
            if request.path == "/api/apps" { respond(connection, 200, Self.androidAppsJSON()); return }
            if request.path.hasPrefix("/download/") { serveAndroidApp(request.path, on: connection); return }
        }
        // Пароль — свій у кожного каналу: PIN телефона і пароль браузера.
        let secret = request.web ? webPassword : pin
        if !secret.isEmpty {
            let given = request.headers["x-slovo-pin"] ?? request.query["pin"] ?? ""
            guard given == secret else { respond(connection, 401, ["error": "pin"]); return }
        }
        // «Лише перегляд»: сторінка бачить зал, але нічого не змінює.
        if request.web, webViewOnly, request.method != "GET" {
            respond(connection, 403, ["error": OurWords.t("только просмотр — управление выключено в Параметры → Remote API")])
            return
        }

        if request.method == "GET", request.path == "/api/state" {
            let since = Int(request.query["since"] ?? "") ?? -1
            let web = request.web
            if since < seq { respond(connection, 200, stateJSON(web: web)); return }
            // Долгий опрос: ответ уйдёт с первым изменением или по сроку.
            let timeout = DispatchWorkItem { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.waiters.removeAll { $0.connection === connection }
                self.respond(connection, 200, self.stateJSON(web: web))
            }
            waiters.append(Waiter(connection: connection, timeout: timeout, web: web))
            // 15 с, а не 25: телефон чекає 40, і запас утричі більший — навіть
            // якщо програма на мить загальмує, відповідь дійде вчасно.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            return
        }
        // Картинка страницы показа — телефон рисует её и водит по ней указкой.
        if request.method == "GET", request.path == "/api/page" {
            let show = (request.query["kind"] == "pictures"
                ? NativeShowWorkspace.pictures : NativeShowWorkspace.presentation).model
            let index = Int(request.query["index"] ?? "") ?? show.index ?? -1
            let width = min(1600, max(160, Int(request.query["w"] ?? "") ?? 720))
            guard show.pages.indices.contains(index), let image = show.image(at: index),
                  let jpeg = Self.jpeg(image, width: width) else {
                respond(connection, 404, ["error": OurWords.t("нет такой страницы")]); return
            }
            respondData(connection, 200, jpeg, contentType: "image/jpeg")
            return
        }
        // Біблія для телефона: переклади, книги, глави й вірші. Власник:
        // «добавить полноценную функцию вывода текста Библии (сейчас подобие
        // функции есть, но оно не понятное и не рабочее)». Доти телефон
        // умів лише набрати адресу руками — вибирати не було з чого.
        if request.method == "GET", request.path == "/api/bible/books" {
            respond(connection, 200, bibleBooksJSON(state: state))
            return
        }
        if request.method == "GET", request.path == "/api/bible/chapter" {
            answerChapter(request, state: state, on: connection)
            return
        }
        // Планшет: плеєр, картинки, екран, текст, Історія, пошук, зал.
        if request.method == "GET", tabletGET(request, state: state, on: connection) { return }
        // Бібліотека для плану проповіді: переклади й пісенники на планшет.
        if request.method == "GET", libraryGET(request, state: state, on: connection) { return }
        guard request.method == "POST", request.path.hasPrefix("/api/") else {
            respond(connection, 404, ["error": OurWords.t("нет такого пути")])
            return
        }
        let command = String(request.path.dropFirst("/api/".count))
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let index = (body["index"] as? NSNumber)?.intValue ?? Int((body["index"] as? String) ?? "")
        let text = (body["text"] as? String) ?? ""

        NativeTrace.say("пульт: команда \(command)\(index.map { " \($0)" } ?? "")\(text.isEmpty ? "" : " «\(text)»")")
        var answer: [String: Any] = ["ok": true]
        switch command {
        case "next": step(1, state: state)
        case "prev": step(-1, state: state)
        case "show": state.showCurrent()
        case "hide": state.isLive = false
        case "black": state.showBlackScreen()
        case "blank": state.showBlankSlide()
        case "next-chapter": state.stepChapter(by: 1, live: false)
        case "prev-chapter": state.stepChapter(by: -1, live: false)
        case "plan":
            let items = DeskModel.shared.plan.items
            guard let index, items.indices.contains(index) else { respond(connection, 404, ["error": OurWords.t("нет такого пункта")]); return }
            DeskModel.shared.activate(items[index], state: state)
        case "part":
            let songs = NativeSongsWorkspace.shared
            guard let index, let song = songs.model.songIndex else { respond(connection, 404, ["error": OurWords.t("песня не выбрана")]); return }
            if state.mode != .songs { state.mode = .songs }
            songs.reveal(song: song, part: index, live: true)
        case "song":
            guard let index else { respond(connection, 400, ["error": "нужен index"]); return }
            if state.mode != .songs { state.mode = .songs }
            NativeSongsWorkspace.shared.reveal(song: index, part: nil, live: false)
        case "page":
            // Страницу листают с телефона и тогда, когда программа стоит на
            // другой вкладке: переключаемся на показ сами — телефону не видно,
            // что открыто на компьютере.
            guard let index else { respond(connection, 400, ["error": "нужен index"]); return }
            if state.mode != .pictures && state.mode != .presentation { state.mode = .presentation }
            let workspace = state.mode == .pictures ? NativeShowWorkspace.pictures : NativeShowWorkspace.presentation
            workspace.selectPage(index)
            workspace.showCurrentPage()
        case "deck":
            guard let index else { respond(connection, 400, ["error": "нужен index"]); return }
            if state.mode != .presentation { state.mode = .presentation }
            NativeShowWorkspace.presentation.selectDeck(index)
        case "pointer":
            if let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue {
                // Колір «#RRGGBB», розмір (частка висоти кадру) і яскравість —
                // з налаштувань пульта; старий пульт їх не шле, і тоді діють
                // налаштування програми.
                let phone = SlidePointer.PhoneLook(
                    colour: (body["colour"] as? String).flatMap(SlidePointer.Look.colour(fromHex:)),
                    size: (body["size"] as? NSNumber)?.doubleValue,
                    opacity: (body["opacity"] as? NSNumber)?.doubleValue)
                let empty = phone.colour == nil && phone.size == nil && phone.opacity == nil
                SlidePointer.shared.move(to: x, y, from: SlidePointer.phoneSource,
                                         phone: empty ? nil : phone)
            } else {
                SlidePointer.shared.hide(from: SlidePointer.phoneSource)
            }
        case "pointer-off":
            SlidePointer.shared.hide(from: SlidePointer.phoneSource)
        case "zoom":
            // Наближення з телефона. Власник: «еще в пульте добавить
            // увеличение (точка фокуса)». Палець показує, куди дивитися, —
            // це ті самі частки показаного кадру, що й в указки; кратність
            // приходить окремо, а нуль знімає наближення зовсім.
            let focus = SlideFocus.shared
            let zoom = (body["zoom"] as? NSNumber)?.doubleValue ?? 0
            if zoom <= SlideFocus.minZoom + 0.001 {
                focus.reset()
            } else {
                if let x = (body["x"] as? NSNumber)?.doubleValue,
                   let y = (body["y"] as? NSNumber)?.doubleValue {
                    // Спершу ведемо погляд, потім вмикаємо: поки наближення
                    // вимкнено, частки міряються від цілої сторінки — саме
                    // від того, що людина бачить на телефоні.
                    focus.zoom(to: zoom, aroundShown: x, y)
                    if !focus.isOn { focus.setOn(true) }
                } else {
                    if !focus.isOn { focus.setOn(true) }
                    focus.setZoom(zoom)
                }
            }
            answer["zoom"] = focus.isOn ? focus.look.zoom : 1
        case "upload":
            switch saveUpload(request, state: state) {
            case .success(let result): for (key, value) in result { answer[key] = value }
            case .failure(let error): respond(connection, 400, ["error": error.localizedDescription]); return
            }
        case "sermon-plan":
            whenLibraryReady(state) { [weak self] in
                guard let self else { return }
                self.respond(connection, 200, self.acceptSermonPlan(body, state: state))
                self.noteChange()
            }
            return
        case "sermon-end":
            DeskModel.shared.endSermon()
        case "module-import":
            importModule(request, state: state, on: connection)
            return
        case "goto":
            if state.mode != .bible { state.mode = .bible }
            // Показ — коли глави справді прочитано. Раніше адреса з телефона
            // йшла в зал одразу, і в зал потрапляв вірш попередньої книги.
            guard DeskModel.shared.applyAddress(text, state: state, then: { [weak self] in
                state.showCurrent()
                NativeBibleBridge.shared.sync()
                self?.noteChange()
            }) else {
                respond(connection, 404, ["error": OurWords.t("адрес не найден")]); return
            }
        case "bible-select":
            // Місце, вибране на телефоні: книга — позицією у списку книг,
            // глава, вірші; `live` — одразу в зал, інакше лише в передпоказ.
            let position = (body["book"] as? NSNumber)?.intValue ?? state.selectedBookIndex
            let chapter = (body["chapter"] as? NSNumber)?.intValue ?? state.selectedChapterNumber
            let verses = (body["verses"] as? [NSNumber])?.map(\.intValue) ?? []
            let live = (body["live"] as? NSNumber)?.boolValue ?? false
            guard state.books.indices.contains(position) else {
                respond(connection, 404, ["error": OurWords.t("нет такой книги")]); return
            }
            if state.mode != .bible { state.mode = .bible }
            // Відповідь іде одразу, а показ — коли місце стало: глави могли
            // ще читатися з диска, і показ одразу вивів би попередній вірш.
            state.openScripture(bookPosition: position, chapter: chapter, verses: verses, then: { [weak self] in
                if live { state.showCurrent() }
                NativeBibleBridge.shared.sync()
                self?.noteChange()
            })
        case "bible-translation":
            guard state.module(text) != nil else {
                respond(connection, 404, ["error": OurWords.t("нет такого перевода")]); return
            }
            state.primaryModuleID = text
        case "mode":
            guard let mode = AppState.WorkMode(rawValue: text) else { respond(connection, 400, ["error": OurWords.t("нет такой вкладки")]); return }
            state.mode = mode
        case "songs":
            answer["songs"] = searchSongs(text)
        default:
            switch tabletCommand(command, body: body, index: index, text: text, state: state, answer: &answer) {
            case .handled:
                break
            case .unknown:
                respond(connection, 404, ["error": OurWords.t("нет такой команды: %s", "\(command)")])
                return
            case .failed(let code, let message):
                respond(connection, code, ["error": message])
                return
            }
        }
        NativeBibleBridge.shared.sync()
        noteChange()
        respond(connection, 200, answer)
    }

    /// «Дальше» и «назад» — то же, что стрелки в главном окне, но всегда с
    /// показом в зале: пульт в руках проповедника листает то, что на стене.
    private func step(_ delta: Int, state: AppState) {
        if NativeShowWorkspace.handleStep(mode: state.mode, delta: delta) { return }
        switch state.mode {
        case .songs:
            state.stepSongPart(by: delta, live: true)
        case .bible:
            state.stepVerse(by: delta, live: true)
        default:
            return
        }
        // Показ был скрыт (Esc на компьютере) — с телефона этого не видно, а
        // «Далі» жмут, чтобы стих ПОЯВИЛСЯ на стене. Иначе стих менялся лишь
        // внутри программы, а зал оставался пустым, и на телефоне так и
        // висело «У залі порожньо». Делаем, как кнопка «Показати».
        if !state.isLive { state.showCurrent() }
    }

    /// Книги відкритого перекладу — телефону, щоб вибирати, а не набирати.
    private func bibleBooksJSON(state: AppState) -> [String: Any] {
        let books = state.books.enumerated().map { position, book -> [String: Any] in
            ["position": position, "name": book.fullName, "short": book.buttonTitle,
             "chapters": book.chapterCount, "testament": Self.testament(of: book)]
        }
        return [
            "translation": ["id": state.primaryModuleID, "name": state.primaryModule?.displayName ?? ""],
            "translations": state.allModules.map { ["id": $0.identifier, "name": $0.displayName] },
            "current": ["book": state.selectedBookIndex, "chapter": state.selectedChapterNumber,
                        "verses": state.selectedVerseNumbers],
            "books": books,
        ]
    }

    /// Старий, Новий чи інше — за наскрізним номером канону (Малахія — 460,
    /// Матвій — 470, Об'явлення — 730). Книга без номера — «інше».
    private static func testament(of book: BookInfo) -> String {
        guard let number = book.canonicalNumber else { return "other" }
        if number <= 460 { return "old" }
        return number <= 730 ? "new" : "other"
    }

    /// Вірші глави. Книгу, якої ще немає в пам'яті, читаємо у фоні: розбір
    /// займає сотні мілісекунд, і вікно програми на цей час не має замирати.
    private func answerChapter(_ request: Request, state: AppState, on connection: NWConnection) {
        let position = Int(request.query["book"] ?? "") ?? state.selectedBookIndex
        let number = Int(request.query["chapter"] ?? "") ?? state.selectedChapterNumber
        guard let module = state.primaryModule, state.books.indices.contains(position) else {
            respond(connection, 404, ["error": OurWords.t("нет такой книги")]); return
        }
        let book = state.books[position]
        let reply: ([Chapter]) -> Void = { [weak self] chapters in
            guard let self else { return }
            guard let chapter = chapters.first(where: { $0.number == number }) else {
                self.respond(connection, 404, ["error": OurWords.t("нет такой главы")]); return
            }
            self.respond(connection, 200, [
                "book": position, "name": book.fullName, "chapter": number,
                "chapters": book.chapterCount,
                "verses": chapter.verses.map { ["number": $0.number, "text": $0.text] },
            ])
        }
        if let ready = module.cachedChapters(ofBook: book) { reply(ready); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = (try? module.chapters(ofBook: book)) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { reply(parsed) } }
        }
    }

    /// Песни по слову из названия — для вкладки «Пошук» на телефоне.
    private func searchSongs(_ query: String) -> [[String: Any]] {
        let needle = NativeSongFold.bytes(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty, let songs = NativeSongsWorkspace.shared.model.book?.songs else { return [] }
        var found: [[String: Any]] = []
        for song in songs {
            guard NativeSongFold.contains(NativeSongFold.bytes(song.title), needle)
                || NativeSongFold.contains(NativeSongFold.bytes(song.alternateTitle), needle)
                || String(song.index + 1) == query.trimmingCharacters(in: .whitespaces) else { continue }
            found.append(["index": song.index, "title": "\(song.index + 1). \(song.title)",
                          "subtitle": song.subtitle ?? ""])
            if found.count >= 60 { break }
        }
        return found
    }

    // MARK: - Картинка и файлы с телефона

    /// Страница показа в JPEG нужной ширины — телефону.
    nonisolated static func jpeg(_ image: CGImage, width: Int) -> Data? {
        let scale = Double(width) / Double(max(1, image.width))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var source = image
        if scale < 1, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let small = context.makeImage() { source = small }
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Куда складываются файлы, присланные с телефона.
    static var uploadsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo/Пульт", isDirectory: true)
    }

    struct UploadRefused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Файл с телефона: сохранить и открыть в показе — презентацию во
    /// вкладку «Презентация», картинку — в «Изображения».
    private func saveUpload(_ request: Request, state: AppState) -> Result<[String: Any], Error> {
        let rawName = (request.query["name"] ?? "").components(separatedBy: "/").last ?? ""
        let name = rawName.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(UploadRefused(reason: OurWords.t("нет имени файла (name=)"))) }
        guard !request.body.isEmpty else { return .failure(UploadRefused(reason: "пустой файл")) }
        // Файл плану проповіді — лише зберегти: відкриє його пункт «Файл».
        if request.query["store"] == "1" { return storeUpload(name: name, body: request.body, state: state) }
        let ext = (name as NSString).pathExtension.lowercased()
        let kind: ShowModel.Kind
        if ShowModel.Kind.presentation.extensions.contains(ext) { kind = .presentation }
        else if ShowModel.Kind.pictures.extensions.contains(ext) { kind = .pictures }
        else { return .failure(UploadRefused(reason: OurWords.t("такой файл показ не открывает: .%s", "\(ext)"))) }

        let folder = Self.uploadsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try request.body.write(to: url, options: .atomic)
            let workspace = kind == .pictures ? NativeShowWorkspace.pictures : NativeShowWorkspace.presentation
            let before = workspace.model.count
            workspace.open([url])
            state.mode = kind == .pictures ? .pictures : .presentation
            if kind == .presentation, !workspace.model.decks.isEmpty {
                workspace.selectDeck(workspace.model.decks.count - 1)
            } else if kind == .pictures, workspace.model.count > before {
                workspace.selectPage(before)
            }
            if let problem = workspace.model.problem, workspace.model.count == before {
                return .failure(UploadRefused(reason: problem))
            }
            // Фото з телефона — одразу в зал: людина вибрала його саме для
            // показу. Власник: «добавить функцию вывода изображений (из
            // библиотеки телефона)». Файл презентації так не показуємо — з
            // нього ще треба вибрати сторінку.
            if kind == .pictures, request.query["show"] == "1", workspace.model.count > before {
                workspace.showCurrentPage()
            }
            NativeTrace.say("пульт: принят файл «\(name)» (\(request.body.count) байт), страниц \(workspace.model.count - before)")
            // `page` — наскрізний номер першої надісланої картинки: телефон,
            // надіславши кілька фото, показує саме перше, а не останнє.
            return .success(["name": name, "pages": workspace.model.count - before,
                             "deck": workspace.model.currentDeck ?? -1,
                             "page": kind == .pictures && workspace.model.count > before ? before : -1])
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Состояние для телефона

    func stateJSON(web: Bool = false) -> [String: Any] {
        guard let state else { return ["seq": seq] }
        var json: [String: Any] = [
            "seq": seq,
            "app": "Slovo",
            "name": Host.current().localizedName ?? "Слово",
            "mode": state.mode.rawValue,
            "live": state.isLive,
            "black": state.isBlackedOut,
            "blank": state.isTextBlank,
        ]
        json["slide"] = ["reference": state.liveSlide.reference, "text": state.liveSlide.mainText,
                         "secondary": state.liveSlide.secondaryTexts]
        json["preview"] = ["reference": state.slide.reference, "text": state.slide.mainText]
        if let book = state.currentBook {
            json["bible"] = ["book": book.fullName, "position": state.selectedBookIndex,
                             "chapter": state.selectedChapterNumber,
                             "verses": state.selectedVerseNumbers.map(String.init).joined(separator: ","),
                             "translation": state.primaryModule?.displayName ?? ""]
        }
        let songs = NativeSongsWorkspace.shared
        if let song = songs.model.song {
            json["song"] = ["title": song.title, "number": song.index + 1,
                            "partIndex": songs.model.partIndex ?? -1,
                            "parts": song.parts.map { ["kind": $0.kind, "text": $0.text] }]
        }
        if state.mode == .pictures || state.mode == .presentation {
            let workspace = state.mode == .pictures ? NativeShowWorkspace.pictures : NativeShowWorkspace.presentation
            json["show"] = ["title": workspace.model.currentTitle, "index": workspace.model.index ?? -1,
                            "count": workspace.model.count]
        }
        // Презентация — всегда, на какой бы вкладке ни стояла программа:
        // главная работа пульта — листать её с телефона.
        let show = NativeShowWorkspace.presentation.model
        let range = show.currentRange
        let onWall = state.isLive && state.media.isVideoOnScreen && state.media.still != nil
            && state.mode == .presentation
        json["presentation"] = [
            "decks": show.decks.enumerated().map { ["index": $0.offset, "name": $0.element.name,
                                                    "count": $0.element.range.count] },
            "deck": show.currentDeck ?? (show.decks.isEmpty ? -1 : 0),
            "pages": range.filter { show.pages.indices.contains($0) }
                .map { ["index": $0, "title": show.pages[$0].short] },
            "index": show.index ?? -1,
            "local": show.index.map { $0 - range.lowerBound } ?? -1,
            "count": range.count,
            "total": show.count,
            "title": show.currentTitle,
            "onWall": onWall,
        ]
        // Указку телефон малює і в себе на картинці — тому разом із місцем
        // віддаємо вигляд і хто її веде: чужу (мишею з комп'ютера) він
        // показує кольором і розміром програми.
        let pointer = SlidePointer.shared
        json["pointer"] = ["on": pointer.mark != nil, "x": pointer.mark?.x ?? 0.5, "y": pointer.mark?.y ?? 0.5,
                           "colour": SlidePointer.Look.hex(pointer.look.colour), "size": pointer.look.size,
                           "opacity": pointer.look.opacity,
                           "source": pointer.mark == nil ? "" : pointer.source]
        // Наближення: телефон показує ним, у скільки разів зараз наближено і
        // куди дивиться вікно, — щоб повзунок на телефоні стояв там, де
        // правда, навіть коли наближення змінили мишею.
        let focus = SlideFocus.shared
        json["zoom"] = ["on": focus.isOn, "zoom": focus.isOn ? focus.look.zoom : 1,
                        "x": focus.look.x, "y": focus.look.y,
                        "least": SlideFocus.minZoom, "most": SlideFocus.maxZoom]
        json["hall"] = hallJSON(state: state)
        // Відкритий пісенник: змінили на комп'ютері — планшет перечитує пісні.
        json["songBook"] = state.songBookID
        let desk = DeskModel.shared
        json["plan"] = desk.plan.items.map { item -> [String: Any] in
            ["title": item.title, "subtitle": item.subtitle ?? "", "kind": item.kind.rawValue,
             "current": desk.planSelection.contains(item.id)]
        }
        // План проповіді заступив план служіння — планшет показує, чий
        // план перед ним, і дає повернути план служіння.
        json["sermon"] = ["on": desk.isSermon, "title": desk.isSermon ? desk.plan.title : ""]
        // Сторінці в режимі «лише перегляд» — щоб сховала кнопки керування.
        if web { json["viewOnly"] = webViewOnly }
        return json
    }
}
