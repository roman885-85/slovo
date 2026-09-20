import Foundation
import Combine

/// Веб-вивід цілком: HTTP віддає сторінки, WebSocket жене на них слайди.
///
/// Один об'єкт на весь застосунок. Він же — джерело стану для інтерфейсу:
/// операторові перед служінням треба бачити адресу, яку можна набрати на
/// телефоні, число підключених екранів і зрозумілу причину, якщо не піднялося.
@MainActor
public final class WebOutputServer: ObservableObject {

    /// Що показати в налаштуваннях виводу.
    public struct Status: Sendable, Equatable {

        public static func == (one: Status, two: Status) -> Bool {
            one.isRunning == two.isRunning && one.httpPort == two.httpPort
                && one.webSocketPort == two.webSocketPort
                && one.tcpPort == two.tcpPort && one.udpPort == two.udpPort
                && one.subscribedClients == two.subscribedClients
                && one.connectedClients == two.connectedClients
                && one.tcpClients == two.tcpClients && one.udpClients == two.udpClients
                && one.lastError == two.lastError && one.notices == two.notices
                && one.addresses == two.addresses
        }

        public var isRunning = false
        public var httpPort: Int?
        public var webSocketPort: Int?
        /// Порти решти двох транспортів Remote API — TCP і UDP.
        public var tcpPort: Int?
        public var udpPort: Int?
        /// Підписники TCP і UDP рахуються окремо від сторінок: у них немає
        /// адреси, яку можна показати, і плутати їх зі сторінками не можна.
        public var tcpClients = (connected: 0, subscribed: 0)
        public var udpClients = (connected: 0, subscribed: 0)
        /// Скільки сторінок підписано на слайди.
        public var subscribedClients = 0
        /// Скільки з'єднань відкрито взагалі (сторінка могла ще не підписатися).
        public var connectedClients = 0
        public var lastError: String?
        /// Дрібниці, про які варто сказати вголос: підмінений порт тощо.
        public var notices: [String] = []
        /// Адреси цього комп'ютера в локальній мережі.
        public var addresses: [String] = []

        /// Посилання, яке можна продиктувати або показати QR-кодом.
        public var url: String? {
            guard let httpPort else { return nil }
            let host = addresses.first ?? "localhost"
            return "http://\(host):\(httpPort)/"
        }
    }

    public struct Options: Sendable {
        /// Підписи стартової сторінки; список сторінок береться з налаштувань.
        public var index: WebIndexModel
        /// Куди йти, якщо основний порт зайнятий або вимагає root.
        public var httpFallbackPort: Int
        public var webSocketFallbackPort: Int
        public var allowsPortFallback: Bool
        public var loopbackOnly: Bool
        /// Чи підміняти у сторінках, що віддаються, вшиту адресу WebSocket.
        public var retargetsWebSocket: Bool
        /// Значок вкладки (PNG) — свій, програмний.
        public var favicon: Data?

        public init(index: WebIndexModel = WebIndexModel(),
                    httpFallbackPort: Int = 8082,
                    webSocketFallbackPort: Int = 18100,
                    allowsPortFallback: Bool = true,
                    loopbackOnly: Bool = false,
                    retargetsWebSocket: Bool = true,
                    favicon: Data? = nil) {
            self.favicon = favicon
            self.index = index
            self.httpFallbackPort = httpFallbackPort
            self.webSocketFallbackPort = webSocketFallbackPort
            self.allowsPortFallback = allowsPortFallback
            self.loopbackOnly = loopbackOnly
            self.retargetsWebSocket = retargetsWebSocket
        }
    }

    @Published public private(set) var status = Status()

    /// Режим головного вікна: від нього залежить, чи візьме сторінка текст у лапки.
    public var mode: RemoteSlidePayload.Mode = .bible
    /// Назви перекладів по порядку — основний, потім паралельні.
    public var moduleNames: [RemoteModuleName] = []

    /// Розкладка об'єктів шаблону. Міняється зі зміною шаблону, а не вірша,
    /// тому ставиться ззовні і просто прикладається до кожної події.
    public private(set) var layout: WebSlideLayout?

    /// Прийняти шаблон: перерахувати розкладку і переписати список картинок.
    ///
    /// Картинки реєструються заново на кожен шаблон: попередній міг називати
    /// файли, яких у новому немає, і тримати їх відкритими для мережі нема чого.
    ///
    /// `text` віддає готовий рядок об'єкта — той самий, що йде на проектор;
    /// `imageURL` знаходить файл картинки за записаним у шаблоні шляхом.
    public func setTemplate(_ preset: SlidePreset?,
                            withSecondTranslation: Bool,
                            text: (SlideObject) -> String,
                            imageURL: (String) -> URL?,
                            fontURL: (String) -> URL? = { _ in nil }) {
        images.removeAll()
        fonts.removeAll()
        guard let preset else { layout = nil; return }
        layout = WebSlideLayout.make(preset: preset,
                                     withSecondTranslation: withSecondTranslation,
                                     text: text,
                                     imageID: { path in
                                         guard let url = imageURL(path) else { return nil }
                                         return self.images.register(path: path, url: url)
                                     },
                                     fontID: { family in
                                         guard let url = fontURL(family) else { return nil }
                                         return self.fonts.register(path: family, url: url)
                                     })
    }

    /// Записати картинку показу й отримати її коротке ім'я.
    ///
    /// Картинки шаблону реєструє `setTemplate`, але фотографія і сторінка
    /// презентації приходять не з шаблону, а з показу, — і їм потрібна та сама
    /// коротка дорога: браузеру шляхів з диска не віддаємо.
    @discardableResult
    public func registerImage(path: String, url: URL) -> String {
        images.register(path: path, url: url)
    }

    private let instanceGUID = RemoteAPIIdentity.makeGUID()
    private let installGUID = RemoteAPIIdentity.makeGUID()
    private var http: HTTPStaticServer?
    private var socket: WebSlideSocketServer?
    private var tcp: RemoteAPITCPServer?
    private var udp: RemoteAPIUDPServer?
    /// Картинки нинішнього шаблону — їх просить наша сторінка слайда.
    private let images = WebSlideImages()
    /// Шрифти шаблону: у браузера їх немає, і без файла він підставить свій.
    private let fonts = WebSlideImages()
    private var options = Options()
    private var nextVariants: [RemoteSlideVariant] = []
    private var lastPayload: RemoteSlidePayload?
    /// Слухачі піднімаються асинхронно. Якщо оператор устиг вимкнути вивід
    /// або перезапустити його, відповідь минулого запуску не має воскрешати
    /// стан: звіряємося з номером покоління.
    private var generation = 0

    public init() {}

    // MARK: - Запуск і зупинка

    /// Піднімає те, що ввімкнено в налаштуваннях. Повернення миттєве: слухачі
    /// стартують асинхронно, результат приїжджає в `status`.
    ///
    /// WebSocket піднімається першим: HTTP має знати його справжній порт,
    /// щоб підставити в сторінки правильну адресу.
    public func start(settings: WebOutputSettings, dataRoot: URL, options: Options? = nil) {
        stop()

        var resolved = options ?? self.options
        if resolved.index.entries.isEmpty {
            resolved.index = WebIndexModel(pages: settings.pages,
                                           title: resolved.index.title,
                                           languageCode: resolved.index.languageCode)
        }
        self.options = resolved

        var fresh = Status()
        fresh.addresses = LocalNetwork.addresses()
        if !settings.webSocketEnabled && settings.httpEnabled {
            fresh.notices.append(OurWords.t("WebSocket выключен в настройках — страницы откроются, но текст на них не пойдёт."))
        }
        status = fresh

        guard settings.httpEnabled || settings.webSocketEnabled
                || settings.tcpEnabled || settings.udpEnabled else {
            status.lastError = OurWords.t("Веб-вывод и Remote API выключены в настройках.")
            return
        }

        let root = dataRoot.appendingPathComponent("RemoteAPI")
        let era = generation

        // TCP і UDP не пов'язані ні зі сторінками, ні одне з одним: піднімаємо
        // їх одразу і не чекаємо, поки домовляться HTTP з WebSocket.
        if settings.tcpEnabled { startTCP(port: settings.tcpPort, era: era) }
        if settings.udpEnabled { startUDP(port: settings.udpPort, era: era) }

        if settings.webSocketEnabled {
            startSocket(port: settings.webSocketPort, era: era) { [weak self] port in
                guard let self, era == self.generation, settings.httpEnabled else { return }
                self.startHTTP(port: settings.httpPort,
                               root: root,
                               webSocketPort: port ?? settings.webSocketPort,
                               era: era)
            }
        } else if settings.httpEnabled {
            startHTTP(port: settings.httpPort, root: root, webSocketPort: settings.webSocketPort, era: era)
        }
    }

    public func stop() {
        generation &+= 1
        http?.stop()
        socket?.stop()
        tcp?.stop()
        udp?.stop()
        http = nil
        socket = nil
        tcp = nil
        udp = nil
        lastPayload = nil
        status = Status()
    }

    public var isRunning: Bool { status.isRunning }

    // MARK: - Видача слайдів

    /// Відправляє слайд на веб-сторінки.
    ///
    /// `kind` тут — це канал, чий вміст іде у веб: і звичайні
    /// сторінки, і екран служителя живляться однією й тією самою подією протоколу,
    /// тому осмислені лише `.web` і `.stage`; усе інше ігнорується,
    /// щоб проектор випадково не почав дублюватися в мережу.
    public func publish(slide: Slide, kind: OutputKind = .web) {
        guard kind == .web || kind == .stage else { return }
        let payload = RemoteSlidePayload(slide: slide,
                                         mode: mode,
                                         moduleNames: moduleNames,
                                         next: nextVariants)
        publish(payload)
    }

    /// Повний контроль над пакетом: назви модулів, розбиття на сторінки,
    /// наступний слайд — усе, чого немає в `Slide`.
    /// Розіслати сторінкам змінені налаштування — вони застосуються на льоту.
    public func publishStyle(_ values: [String: String]) {
        socket?.broadcastStyle(values)
    }

    public func publish(_ payload: RemoteSlidePayload) {
        var outgoing = payload
        outgoing.next = payload.next.isEmpty ? nextVariants : payload.next
        if outgoing.layout == nil { outgoing.layout = layout }
        lastPayload = outgoing
        socket?.broadcast(outgoing)
        tcp?.broadcast(outgoing)
        udp?.broadcast(outgoing)
    }

    /// Сховати слайд, лишивши вміст: `HideSlide` протоколу.
    public func hide() {
        lastPayload?.isVisible = false
        socket?.broadcastHidden()
        tcp?.broadcastHidden()
        udp?.broadcastHidden()
    }

    /// Наступний слайд для екрана служителя (секція `NextSlide`).
    public func setNextSlide(_ slide: Slide?) {
        guard let slide, !slide.isBlank else {
            nextVariants = []
            return
        }
        let texts = [slide.mainText] + slide.secondaryTexts
        nextVariants = texts.enumerated().map { index, text in
            let name = moduleNames.indices.contains(index) ? moduleNames[index] : RemoteModuleName(short: "")
            return RemoteSlideVariant(moduleShortName: name.short,
                                      moduleName: name.full,
                                      title: slide.reference,
                                      text: text)
        }
    }

    // MARK: - Підняття слухачів

    private func startSocket(port: Int, era: Int, then: @escaping (Int?) -> Void) {
        let listener = WebListenerOptions(port: port,
                                          fallbackPort: options.webSocketFallbackPort,
                                          allowsFallback: options.allowsPortFallback,
                                          loopbackOnly: options.loopbackOnly)
        launchSocket(listener: listener, isRetry: false, era: era, then: then)
    }

    private func launchSocket(listener: WebListenerOptions, isRetry: Bool, era: Int, then: @escaping (Int?) -> Void) {
        let server = WebSlideSocketServer(configuration: .init(listener: listener,
                                                               instanceGUID: instanceGUID,
                                                               installGUID: installGUID))
        server.onClientsChanged = { [weak self] connected, subscribed in
            Task { @MainActor in
                guard let self, era == self.generation else { return }
                self.status.connectedClients = connected
                self.status.subscribedClients = subscribed
            }
        }
        socket = server
        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard era == self.generation else {
                    // Поки слухач піднімався, вивід устигли зупинити.
                    server.stop()
                    return
                }
                switch result {
                case let .success(port):
                    self.status.webSocketPort = port
                    self.status.isRunning = true
                    if port != listener.port {
                        self.status.notices.append("WebSocket слушает порт \(port) вместо \(listener.port).")
                    }
                    // Сторінка, що підключилася до перезапуску, має отримати
                    // те, що зараз на екрані.
                    if let payload = self.lastPayload { server.broadcast(payload) }
                    then(port)

                case let .failure(error):
                    if !isRetry, error.allowsPortFallback, listener.allowsFallback,
                       listener.fallbackPort != listener.port {
                        var retry = listener
                        retry.port = listener.fallbackPort
                        self.status.notices.append(error.description)
                        self.launchSocket(listener: retry, isRetry: true, era: era, then: then)
                    } else {
                        self.socket = nil
                        self.status.lastError = error.description
                        then(nil)
                    }
                }
            }
        }
    }

    /// TCP-сервер протоколу. Запасний порт — той самий, що й основний, плюс
    /// десять тисяч: так само йде із зайнятого порту WebSocket.
    private func startTCP(port: Int, era: Int) {
        let listener = WebListenerOptions(port: port,
                                          fallbackPort: port + 10_000,
                                          allowsFallback: options.allowsPortFallback,
                                          loopbackOnly: options.loopbackOnly)
        launchTCP(listener: listener, isRetry: false, era: era)
    }

    private func launchTCP(listener: WebListenerOptions, isRetry: Bool, era: Int) {
        let server = RemoteAPITCPServer(configuration: .init(listener: listener,
                                                             instanceGUID: instanceGUID,
                                                             installGUID: installGUID))
        server.onClientsChanged = { [weak self] connected, subscribed in
            Task { @MainActor in
                guard let self, era == self.generation else { return }
                self.status.tcpClients = (connected, subscribed)
            }
        }
        tcp = server
        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard era == self.generation else { server.stop(); return }
                switch result {
                case let .success(port):
                    self.status.tcpPort = port
                    self.status.isRunning = true
                    if port != listener.port {
                        self.status.notices.append("TCP слушает порт \(port) вместо \(listener.port).")
                    }
                    if let payload = self.lastPayload { server.broadcast(payload) }
                case let .failure(error):
                    if !isRetry, error.allowsPortFallback, listener.allowsFallback,
                       listener.fallbackPort != listener.port {
                        var retry = listener
                        retry.port = listener.fallbackPort
                        self.status.notices.append(error.description)
                        self.launchTCP(listener: retry, isRetry: true, era: era)
                    } else {
                        self.tcp = nil
                        self.status.notices.append(OurWords.t("TCP-сервер не поднялся: %s", "\(error.description)"))
                    }
                }
            }
        }
    }

    private func startUDP(port: Int, era: Int) {
        let listener = WebListenerOptions(port: port,
                                          fallbackPort: port + 10_000,
                                          allowsFallback: options.allowsPortFallback,
                                          loopbackOnly: options.loopbackOnly)
        launchUDP(listener: listener, isRetry: false, era: era)
    }

    private func launchUDP(listener: WebListenerOptions, isRetry: Bool, era: Int) {
        let server = RemoteAPIUDPServer(configuration: .init(listener: listener,
                                                             instanceGUID: instanceGUID,
                                                             installGUID: installGUID))
        server.onClientsChanged = { [weak self] connected, subscribed in
            Task { @MainActor in
                guard let self, era == self.generation else { return }
                self.status.udpClients = (connected, subscribed)
            }
        }
        udp = server
        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard era == self.generation else { server.stop(); return }
                switch result {
                case let .success(port):
                    self.status.udpPort = port
                    self.status.isRunning = true
                    if port != listener.port {
                        self.status.notices.append("UDP слушает порт \(port) вместо \(listener.port).")
                    }
                case let .failure(error):
                    if !isRetry, error.allowsPortFallback, listener.allowsFallback,
                       listener.fallbackPort != listener.port {
                        var retry = listener
                        retry.port = listener.fallbackPort
                        self.status.notices.append(error.description)
                        self.launchUDP(listener: retry, isRetry: true, era: era)
                    } else {
                        self.udp = nil
                        self.status.notices.append(OurWords.t("UDP-сервер не поднялся: %s", "\(error.description)"))
                    }
                }
            }
        }
    }

    private func startHTTP(port: Int, root: URL, webSocketPort: Int, era: Int) {
        let listener = WebListenerOptions(port: port,
                                          fallbackPort: options.httpFallbackPort,
                                          allowsFallback: options.allowsPortFallback,
                                          loopbackOnly: options.loopbackOnly)
        launchHTTP(listener: listener, root: root, webSocketPort: webSocketPort, isRetry: false, era: era)
    }

    /// Куди майстерня кладе сторінки власника.
    ///
    /// Окремо від авторської теки навмисно: та лежить усередині чужого
    /// застосунку і належить не нам. Сервер віддає обидві, авторську першою.
    public nonisolated static var userPagesFolder: URL {
        DataHome.folder.appendingPathComponent("WebSlides")
    }

    private func launchHTTP(listener: WebListenerOptions, root: URL, webSocketPort: Int, isRetry: Bool, era: Int) {
        let configuration = HTTPStaticServer.Configuration(root: root,
                                                           extraRoots: [Self.userPagesFolder],
                                                           listener: listener,
                                                           index: options.index,
                                                           webSocketPort: webSocketPort,
                                                           retargetsWebSocket: options.retargetsWebSocket,
                                                           images: images,
                                                           fonts: fonts,
                                                           favicon: options.favicon)
        let server = HTTPStaticServer(configuration: configuration)
        http = server
        server.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard era == self.generation else {
                    server.stop()
                    return
                }
                switch result {
                case let .success(port):
                    self.status.httpPort = port
                    self.status.isRunning = true
                    if port != listener.port {
                        self.status.notices.append(OurWords.t("Страницы отдаются на порту %s вместо %s.", "\(port)", "\(listener.port)"))
                    }

                case let .failure(error):
                    if !isRetry, error.allowsPortFallback, listener.allowsFallback,
                       listener.fallbackPort != listener.port {
                        var retry = listener
                        retry.port = listener.fallbackPort
                        self.status.notices.append(error.description)
                        self.launchHTTP(listener: retry, root: root, webSocketPort: webSocketPort,
                                        isRetry: true, era: era)
                    } else {
                        self.http = nil
                        self.status.lastError = error.description
                    }
                }
            }
        }
    }
}
