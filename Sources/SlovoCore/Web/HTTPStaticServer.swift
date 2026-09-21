import Foundation
import Network

/// HTTP-сервер веб-слайдів: віддає теку `RemoteAPI` як є.
///
/// Свого HTML ми не пишемо — сторінки вже написав автор старої програми, і лежать вони
/// поруч із модулями. Задача сервера рівно одна: віддати їх без правок, підставивши
/// адресу цього комп'ютера, щоб сторінка знайшла WebSocket, і зібрати
/// стартовий список за `index.tpl`.
///
/// Реалізація навмисно проста: HTTP/1.0-подібна відповідь з `Connection: close` на
/// кожен запит. Файли тут маленькі і статичні, keep-alive виграє
/// мілісекунди, а коштує окремого стану на з'єднання і цілого класу
/// помилок із «завислими» сокетами посеред служіння.
public final class HTTPStaticServer {

    public struct Configuration: Sendable {
        /// Тека з авторськими сторінками (зазвичай `<data>/RemoteAPI`).
        public var root: URL
        /// Свої теки, які теж треба віддавати: сторінки, намальовані в
        /// майстерні, лежать окремо від авторських — чіпати чужу теку ми
        /// не маємо права. Без цього сервер їх просто не знаходив, і слайд,
        /// зроблений власником, показати в залі було нічим.
        public var extraRoots: [URL] = []
        public var listener: WebListenerOptions
        public var index: WebIndexModel
        /// Куди сторінкам стукатися за слайдами.
        public var webSocketPort: Int
        /// Чи підміняти вшиті в сторінки адреси WebSocket.
        public var retargetsWebSocket: Bool
        /// Картинки нинішнього шаблону: їх просить наша сторінка слайда.
        /// Список закритий — що не названо в шаблоні, того сервер не віддасть.
        public var images: WebSlideImages?
        /// Шрифти нинішнього шаблону — тим самим закритим списком.
        public var fonts: WebSlideImages?
        /// Значок вкладки (PNG). У теці авторських сторінок лежить
        /// `favicon.ico` від старої програми, і браузер брав саме його — у вкладці
        /// з нашим слайдом світився чужий значок (власник: «в веб слайдах
        /// фавикон от visiobible остался»). Свій значок сильніший за файл на
        /// диску: сторінки тут наші.
        public var favicon: Data?

        public init(root: URL,
                    extraRoots: [URL] = [],
                    listener: WebListenerOptions,
                    index: WebIndexModel = WebIndexModel(),
                    webSocketPort: Int = 8100,
                    retargetsWebSocket: Bool = true,
                    images: WebSlideImages? = nil,
                    fonts: WebSlideImages? = nil,
                    favicon: Data? = nil) {
            self.favicon = favicon
            self.images = images
            self.fonts = fonts
            self.root = root
            self.extraRoots = extraRoots
            self.listener = listener
            self.index = index
            self.webSocketPort = webSocketPort
            self.retargetsWebSocket = retargetsWebSocket
        }
    }

    /// Більше за це в заголовках запиту бути не може — отже, це не браузер.
    private static let maxRequestSize = 64 * 1024
    /// Браузери люблять відкрити сокет заздалегідь і нічого в нього не написати.
    private static let requestTimeout: TimeInterval = 15

    private let queue = DispatchQueue(label: "ua.slovo.web.http")
    private var configuration: Configuration
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var startCompletion: ((Result<Int, WebServerError>) -> Void)?
    /// Читається з чужих потоків, тому під замком, а не через `queue.sync`:
    /// синхронний захід на власну чергу з її ж обробника — глухий кут.
    private let portLock = NSLock()
    private var reportedPort: Int?

    /// Повідомлення про зміну стану приходять на черзі сервера, не на головній.
    public var onStateChange: ((WebServerRunState) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { listener?.cancel() }

    // MARK: - Життєвий цикл

    /// Відповідь приходить після того, як слухач справді зайняв порт:
    /// поки `NWListener` не повідомив `.ready`, обіцяти операторові робочу
    /// адресу не можна.
    public func start(completion: @escaping (Result<Int, WebServerError>) -> Void) {
        queue.async { [self] in
            guard listener == nil else {
                completion(.failure(.network(OurWords.t("HTTP-сервер уже запущен"))))
                return
            }
            // Теки сторінок може не бути зовсім — і це НЕ привід не вмикатися.
            //
            // Власник: «не работают веб слайды, даже локально», «смена порта
            // не сработала». На його машині тека `RemoteAPI` не з'явилася
            // ніколи (вона приходила з даними старої програми, а він ставив
            // «Слово» начисто), і сервер мовчки не піднімався: канал 8100
            // працював, а сторінок не було. Свої сторінки — слайд і
            // перелік — ми малюємо кодом, файли для них не потрібні. Тому
            // теку просто заводимо й слухаємо далі.
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: configuration.root.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue {
                try? FileManager.default.createDirectory(at: configuration.root,
                                                         withIntermediateDirectories: true)
            }

            let options = configuration.listener
            let parameters = WebListenerFactory.parameters(loopbackOnly: options.loopbackOnly, port: options.port)
            let created: NWListener
            do {
                created = try NWListener(using: parameters, on: WebListenerFactory.endpointPort(options.port))
            } catch let error as NWError {
                completion(.failure(.from(error, port: options.port, suggestion: options.fallbackPort)))
                return
            } catch {
                completion(.failure(.network(error.localizedDescription)))
                return
            }

            startCompletion = completion
            listener = created
            onStateChange?(.starting)

            created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            created.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
            created.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            setBoundPort(nil)
            for session in sessions.values { session.close() }
            sessions.removeAll()
            startCompletion = nil
            onStateChange?(.stopped)
        }
    }

    /// Порт, який сервер зайняв насправді (при `port: 0` його призначає система).
    public var boundPort: Int? {
        portLock.lock(); defer { portLock.unlock() }
        return reportedPort
    }

    private func setBoundPort(_ port: Int?) {
        portLock.lock(); reportedPort = port; portLock.unlock()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port.map { Int($0.rawValue) } ?? configuration.listener.port
            setBoundPort(port)
            finishStart(.success(port))
            onStateChange?(.running(port: port))

        case let .failed(error):
            let described = WebServerError.from(error,
                                                port: configuration.listener.port,
                                                suggestion: configuration.listener.fallbackPort)
            fail(described)

        case let .waiting(error):
            // Зайнятий або привілейований порт сам не звільниться: чекати
            // тут нічого, інакше сервер мовчки «стартує» назавжди.
            let described = WebServerError.from(error,
                                                port: configuration.listener.port,
                                                suggestion: configuration.listener.fallbackPort)
            if described.isFatal { fail(described) }

        case .cancelled:
            onStateChange?(.stopped)

        default:
            break
        }
    }

    private func fail(_ error: WebServerError) {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        setBoundPort(nil)
        finishStart(.failure(error))
        onStateChange?(.failed(error.description))
    }

    private func finishStart(_ result: Result<Int, WebServerError>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(result)
    }

    // MARK: - З'єднання

    private final class Session {
        let connection: NWConnection
        var buffer = Data()
        var isFinished = false

        init(connection: NWConnection) { self.connection = connection }

        func close() {
            guard !isFinished else { return }
            isFinished = true
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        // Режим «лише локально»: слухач приймає всіх, тому чужих
        // відсікаємо тут — інакше сторінка зі слайдом виявиться видна всій мережі.
        if configuration.listener.loopbackOnly,
           !WebListenerFactory.isLoopback(connection.endpoint) {
            connection.cancel()
            return
        }

        let session = Session(connection: connection)
        sessions[ObjectIdentifier(session)] = session

        connection.stateUpdateHandler = { [weak self, weak session] state in
            switch state {
            case .failed, .cancelled:
                guard let session else { return }
                self?.forget(session)
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Мовчазне з'єднання — не привід тримати дескриптор до кінця служіння.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak session] in
            guard let self, let session, !session.isFinished else { return }
            session.close()
            self.forget(session)
        }
        receive(session)
    }

    private func forget(_ session: Session) {
        session.isFinished = true
        session.connection.stateUpdateHandler = nil
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !session.isFinished else { return }

            if let data, !data.isEmpty {
                session.buffer.append(data)
                if session.buffer.count > Self.maxRequestSize {
                    self.respond(to: session, status: 431, reason: "Request Header Fields Too Large",
                                 contentType: "text/plain; charset=utf-8",
                                 body: Data("Слишком большой запрос".utf8), headOnly: false)
                    return
                }
                if let request = HTTPRequestHead(buffer: session.buffer) {
                    self.serve(request, on: session)
                    return
                }
            }
            if isComplete || error != nil {
                session.close()
                self.forget(session)
                return
            }
            self.receive(session)
        }
    }

    // MARK: - Відповіді

    private func serve(_ request: HTTPRequestHead, on session: Session) {
        let headOnly = request.method == "HEAD"
        guard request.method == "GET" || headOnly else {
            respond(to: session, status: 405, reason: "Method Not Allowed",
                    contentType: "text/plain; charset=utf-8",
                    body: Data(OurWords.t("Поддерживаются только GET и HEAD").utf8), headOnly: false)
            return
        }

        let host = Self.sanitizedHost(request.host)
        // Рядок запиту відрізаємо одразу: браузер додає його і до «/», і до
        // картинок, а на диску йому відповідності немає.
        let path = String(request.path.split(separator: "?", maxSplits: 1,
                                             omittingEmptySubsequences: false)[0]).lowercased()

        // Значок вкладки: свій, а не той, що лишився в теці від старої програми.
        if path == "/favicon.ico" || path == "/favicon.png" || path == "/apple-touch-icon.png"
            || path == "/apple-touch-icon-precomposed.png" {
            if let icon = configuration.favicon, !icon.isEmpty {
                respond(to: session, status: 200, reason: "OK", contentType: "image/png",
                        body: icon, headOnly: headOnly)
                return
            }
        }

        // «Відео по Wi-Fi»: живий потік HLS (H.264/AAC) з кадром залу.
        // Власник: клієнт по Wi-Fi, повна смуга NDI не проходить, затримка
        // в пару секунд припустима.
        if path == "/wifi" || path == "/wifi/" || path == "/wifi/index.html" {
            let hlsJs = configuration.extraRoots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("hls.min.js").path) }
                || FileManager.default.fileExists(atPath: Self.programFolder.appendingPathComponent("hls.min.js").path)
            respond(to: session, status: 200, reason: "OK", contentType: "text/html; charset=utf-8",
                    body: Data(WebVideoPage.html(hasHlsJs: hlsJs).utf8), headOnly: headOnly)
            return
        }
        if path == "/wifi/hls.min.js" {
            let candidates = configuration.extraRoots.map { $0.appendingPathComponent("hls.min.js") }
                + [Self.programFolder.appendingPathComponent("hls.min.js")]
            if let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let data = try? Data(contentsOf: file) {
                respond(to: session, status: 200, reason: "OK",
                        contentType: "application/javascript; charset=utf-8", body: data, headOnly: headOnly)
            } else {
                respond(to: session, status: 404, reason: "Not Found", contentType: "text/plain; charset=utf-8",
                        body: Data(OurWords.t("hls.min.js не положен в папку программы").utf8), headOnly: headOnly)
            }
            return
        }
        if path.hasPrefix("/wifi/") {
            let name = String(path.dropFirst("/wifi/".count))
            guard let provider = HLSStreamRegistry.provider else {
                respond(to: session, status: 503, reason: "Service Unavailable",
                        contentType: "text/plain; charset=utf-8",
                        body: Data(OurWords.t("Видео по Wi-Fi выключено").utf8), headOnly: headOnly)
                return
            }
            if name == "stream.m3u8" {
                if let list = provider.playlist() {
                    respond(to: session, status: 200, reason: "OK",
                            contentType: "application/vnd.apple.mpegurl", body: Data(list.utf8), headOnly: headOnly)
                } else {
                    respond(to: session, status: 503, reason: "Service Unavailable",
                            contentType: "text/plain; charset=utf-8",
                            body: Data(OurWords.t("Поток ещё не завёлся").utf8), headOnly: headOnly)
                }
                return
            }
            if name == "init.mp4", let data = provider.initSegment() {
                respond(to: session, status: 200, reason: "OK", contentType: "video/mp4", body: data, headOnly: headOnly)
                return
            }
            if name.hasSuffix(".m4s"), let data = provider.segment(named: name) {
                respond(to: session, status: 200, reason: "OK", contentType: "video/iso.segment", body: data, headOnly: headOnly)
                return
            }
            respond(to: session, status: 404, reason: "Not Found", contentType: "text/plain; charset=utf-8",
                    body: Data("Нет такого куска потока".utf8), headOnly: headOnly)
            return
        }

        // Своя сторінка «як на проекторі». Живе в коді, а не файлом у чужій
        // теці з даними: класти туди свої файли ми не маємо права.
        if path == "/slovo-slide-overlay.html" || path == "/slovo-slide-overlay" {
            // Той самий слайд, але без фону — для накладання поверх відео.
            let page = WebSlovoSlidePage.html(webSocketPort: configuration.webSocketPort, host: host)
                .replacingOccurrences(of: "<html lang=\"uk\">", with: "<html lang=\"uk\" class=\"overlay\">")
            respond(to: session, status: 200, reason: "OK",
                    contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly)
            return
        }
        if path == "/" + WebSlovoSlidePage.fileName || path == "/slovo-slide" {
            let page = WebSlovoSlidePage.html(webSocketPort: configuration.webSocketPort,
                                              host: host)
            respond(to: session, status: 200, reason: "OK",
                    contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly)
            return
        }

        // Картинки шаблону: ім'я коротке, і віддаємо лише ті, що названі в
        // нинішньому шаблоні. Шляхів з диска браузеру не показуємо зовсім.
        if path.hasPrefix("/slide-image/") {
            let id = String(path.dropFirst("/slide-image/".count))
            guard let url = configuration.images?.url(forID: id),
                  let data = try? Data(contentsOf: url) else {
                respond(to: session, status: 404, reason: "Not Found",
                        contentType: "text/plain; charset=utf-8",
                        body: Data(OurWords.t("Такой картинки в шаблоне нет").utf8), headOnly: headOnly)
                return
            }
            respond(to: session, status: 200, reason: "OK",
                    contentType: Self.contentType(for: url), body: data, headOnly: headOnly)
            return
        }

        if path.hasPrefix("/slide-font/") {
            let id = String(path.dropFirst("/slide-font/".count))
            guard let url = configuration.fonts?.url(forID: id),
                  let data = try? Data(contentsOf: url) else {
                respond(to: session, status: 404, reason: "Not Found",
                        contentType: "text/plain; charset=utf-8",
                        body: Data(OurWords.t("Такого шрифта в шаблоне нет").utf8), headOnly: headOnly)
                return
            }
            respond(to: session, status: 200, reason: "OK",
                    contentType: "font/ttf", body: data, headOnly: headOnly)
            return
        }

        if path.isEmpty || path == "/" || path == "/index.html" || path == "/index.htm" || path == "/index.tpl" {
            let page = renderIndex(host: host)
            respond(to: session, status: 200, reason: "OK",
                    contentType: "text/html; charset=utf-8", body: Data(page.utf8), headOnly: headOnly)
            return
        }

        guard let url = resolve(path: request.path) else {
            respond(to: session, status: 404, reason: "Not Found",
                    contentType: "text/html; charset=utf-8",
                    body: Data(Self.notFoundPage.utf8), headOnly: headOnly)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            respond(to: session, status: 404, reason: "Not Found",
                    contentType: "text/html; charset=utf-8",
                    body: Data(Self.notFoundPage.utf8), headOnly: headOnly)
            return
        }

        let type = Self.contentType(for: url)
        if Self.isMarkup(url) {
            // Сторінки автора бувають і в UTF-8, і у Windows-1251 — декодуємо
            // тим самим способом, що й решту файлів старої програми.
            let text = CodePage.decode(data, declared: String(data: data, encoding: .utf8) != nil ? .utf8 : nil)
            var page = WebTemplate.renderPage(text, model: configuration.index, serverAddress: host)
            page = WebTemplate.replaceAuthorPhrases(page)
            if configuration.retargetsWebSocket {
                page = WebTemplate.retargetWebSocket(page, host: host, port: configuration.webSocketPort)
            }
            respond(to: session, status: 200, reason: "OK", contentType: type,
                    body: Data(page.utf8), headOnly: headOnly)
        } else {
            respond(to: session, status: 200, reason: "OK", contentType: type, body: data, headOnly: headOnly)
        }
    }

    private func renderIndex(host: String) -> String {
        // Своя сторінка стоїть у списку першою: по неї приходять найчастіше —
        // вона одна показує те саме, що й проектор.
        var model = configuration.index
        // У переліку — лише те, що програма справді віддасть. У налаштуваннях
        // довго живуть імена чужих сторінок, а самих файлів на чистій машині
        // немає: посилання вели в 404. Свої сторінки малюються кодом — вони
        // лишаються завжди, решта — тільки якщо файл на місці.
        let mineNames = Set([WebSlovoSlidePage.fileName, "slovo-slide-overlay.html"])
        model.entries = model.entries.filter { entry in
            if mineNames.contains(entry.name) { return true }
            let short = entry.name.replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: ".htm", with: "")
            return resolve(path: "/" + entry.name) != nil || resolve(path: "/" + short.lowercased()) != nil
        }
        let mine = WebIndexModel.Entry(name: WebSlovoSlidePage.fileName,
                                       description: OurWords.t("Слово: как на проекторе — объекты шаблона, фон и шрифты"))
        if !model.entries.contains(where: { $0.name == mine.name }) {
            model.entries.insert(mine, at: 0)
        }
        let templateURL = configuration.root.appendingPathComponent("index.tpl")
        guard let data = try? Data(contentsOf: templateURL) else {
            return Self.fallbackIndex(model: model)
        }
        let text = CodePage.decode(data, declared: String(data: data, encoding: .utf8) != nil ? .utf8 : nil)
        return WebTemplate.renderIndex(template: text, model: model, serverAddress: host)
    }

    /// Тека програми (поруч із пакетом): туди власник кладе hls.min.js.
    private static var programFolder: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
    }

    private func respond(to session: Session,
                         status: Int,
                         reason: String,
                         contentType: String,
                         body: Data,
                         headOnly: Bool) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Server: Slovo\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Слайд міняється щохвилини — кеш браузера тут лише шкодить.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var response = Data(head.utf8)
        if !headOnly { response.append(body) }

        session.connection.send(content: response, completion: .contentProcessed { [weak self, weak session] _ in
            guard let session else { return }
            session.close()
            self?.forget(session)
        })
    }

    // MARK: - Файли

    /// Зводить шлях запиту до файла всередині кореня — або відмовляє.
    private func resolve(path: String) -> URL? {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let decoded = String(withoutQuery).removingPercentEncoding ?? String(withoutQuery)

        let components = decoded.split(separator: "/").map(String.init)
        // «..» і порожні частини — єдиний спосіб вийти з теки RemoteAPI.
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        guard !components.isEmpty else { return nil }

        // Авторська тека йде першою: її сторінки головніші, і однойменний
        // файл у своїй теці не має підміняти чужий.
        for base in [configuration.root] + configuration.extraRoots {
            var url = base
            for component in components { url.appendPathComponent(component) }
            url = url.standardizedFileURL

            let root = base.standardizedFileURL.path
            guard url.path == root || url.path.hasPrefix(root + "/") else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return url
        }
        // Імені файлу в адресі не знайшлося — шукаємо за коротким ім'ям.
        // Заради нього все й затівалося: «/vbwebslide-kopiya» замість
        // «/VBWebSlide%20%D0%BA%D0%BE%D0%BF%D0%B8%D1%8F.html».
        return byShortName(components)
    }

    /// Сторінка за коротким ім'ям — і за ім'ям файлу без розширення.
    private func byShortName(_ components: [String]) -> URL? {
        guard components.count == 1 else { return nil }
        let wanted = components[0].lowercased()
        let slug = WebPageAddress.slug(of: components[0])
        for base in [configuration.root] + configuration.extraRoots {
            let files = (try? FileManager.default.contentsOfDirectory(at: base,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for file in files where Self.isMarkup(file) {
                let name = file.lastPathComponent
                let stem = (name as NSString).deletingPathExtension
                if stem.lowercased() == wanted || WebPageAddress.slug(of: name) == slug {
                    return file
                }
            }
        }
        return nil
    }

    private static func isMarkup(_ url: URL) -> Bool {
        ["html", "htm", "tpl"].contains(url.pathExtension.lowercased())
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm", "tpl": return "text/html; charset=utf-8"
        case "js", "mjs":          return "application/javascript; charset=utf-8"
        case "css":                return "text/css; charset=utf-8"
        case "json", "map":        return "application/json; charset=utf-8"
        case "txt":                return "text/plain; charset=utf-8"
        case "ico":                return "image/x-icon"
        case "png":                return "image/png"
        case "jpg", "jpeg":        return "image/jpeg"
        case "gif":                return "image/gif"
        case "svg":                return "image/svg+xml"
        case "webp":               return "image/webp"
        case "woff":               return "font/woff"
        case "woff2":              return "font/woff2"
        case "ttf":                return "font/ttf"
        case "otf":                return "font/otf"
        case "mp3":                return "audio/mpeg"
        case "mp4":                return "video/mp4"
        default:                   return "application/octet-stream"
        }
    }

    /// Заголовок `Host` приходить від клієнта, а ми вставляємо його просто в
    /// JavaScript сторінки. Тому пропускаємо лише те, з чого взагалі
    /// складаються імена й адреси.
    static func sanitizedHost(_ raw: String?) -> String {
        guard var host = raw?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return "localhost" }

        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {   // IPv6
            host = String(host[host.startIndex...close])
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[host.startIndex..<colon])
        }
        guard !host.isEmpty, host.count <= 253 else { return "localhost" }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "localhost" }
        return host
    }

    private static let notFoundPage = """
    <!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title>404</title></head>
    <body style="font-family: -apple-system, sans-serif; padding: 40px">
    <h1>404</h1><p>Такой страницы в папке RemoteAPI нет.</p>
    <p><a href="/">К списку страниц</a></p></body></html>
    """

    /// Якщо авторського `index.tpl` поруч немає, список усе одно має відкритися.
    private static func fallbackIndex(model: WebIndexModel) -> String {
        let rows = model.entries.map { entry in
            let address = WebTemplate.escape(WebPageAddress.slug(of: entry.name))
            return "<li><a href=\"\(address)\">\(WebTemplate.escape(entry.name))</a> — "
                + WebTemplate.escape(entry.description)
                + " <code>/\(address)</code></li>"
        }.joined()
        return """
        <!DOCTYPE html><html lang="\(WebTemplate.escape(model.languageCode))"><head><meta charset="UTF-8">
        <title>\(WebTemplate.escape(model.title))</title></head>
        <body style="font-family: -apple-system, sans-serif; padding: 40px">
        <h1>\(WebTemplate.escape(model.title))</h1><ul>\(rows)</ul></body></html>
        """
    }
}

/// Початок HTTP-запиту. Тіло нам не потрібне: сервер віддає файли і тільки.
struct HTTPRequestHead {
    let method: String
    let path: String
    let host: String?

    /// `nil` — заголовки ще не дочитано; чекаємо наступну порцію байтів.
    init?(buffer: Data) {
        guard let separator = HTTPRequestHead.headerEnd(in: buffer) else { return nil }
        let headData = buffer.prefix(upTo: separator)
        guard let text = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            return nil
        }

        var lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        lines.removeAll { $0.isEmpty }
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()
        path = parts[1]

        host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst("host:".count)).trimmingCharacters(in: .whitespaces) }
    }

    private static func headerEnd(in buffer: Data) -> Data.Index? {
        let bytes = [UInt8](buffer)
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, index + 3 < bytes.count,
               bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return buffer.startIndex + index
            }
            if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                return buffer.startIndex + index
            }
            index += 1
        }
        return nil
    }
}
