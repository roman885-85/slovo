import Foundation
import Network

/// TCP-сервер Remote API (за умовчанням порт 8101).
///
/// Другий із трьох транспортів протоколу. Команди і пакети ті самі, що в
/// WebSocket, — розходяться лише рамки повідомлення: у WebSocket їх ставить сам
/// транспорт, а тут пакет зобов'язаний іти одним рядком і закінчуватися двома
/// байтами 0x0D 0x0A. Усередині пакета цих байтів бути не повинно; про те, щоб
/// перенос рядка в тексті вірша поїхав послідовністю «\r\n», дбає
/// серіалізація JSON.
///
/// Навіщо він потрібен, коли є WebSocket: WebSocket уміє браузер, а
/// відеомікшери, світлові пульти і саморобні приставки на мікроконтролері —
/// ні. Їм потрібен звичайний сокет.
public final class RemoteAPITCPServer {

    public struct Configuration: Sendable {
        public var listener: WebListenerOptions
        public var instanceGUID: String
        public var installGUID: String

        public init(listener: WebListenerOptions,
                    instanceGUID: String = RemoteAPIIdentity.makeGUID(),
                    installGUID: String = RemoteAPIIdentity.makeGUID()) {
            self.listener = listener
            self.instanceGUID = instanceGUID
            self.installGUID = installGUID
        }
    }

    /// Роздільник пакетів зі специфікації.
    private static let terminator = Data([0x0D, 0x0A])
    /// Межа накопиченого без роздільника. Клієнт, який шле сміття без
    /// «\r\n», не має з'їсти всю пам'ять програми посеред служіння.
    private static let bufferLimit = 1 << 20

    private let queue = DispatchQueue(label: "ua.slovo.web.tcp")
    private let configuration: Configuration
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var startCompletion: ((Result<Int, WebServerError>) -> Void)?
    private var lastPayload: RemoteSlidePayload?

    private let counterLock = NSLock()
    private var counters = (connected: 0, subscribed: 0)

    public var onStateChange: ((WebServerRunState) -> Void)?
    public var onClientsChanged: ((_ connected: Int, _ subscribed: Int) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { listener?.cancel() }

    // MARK: - Життєвий цикл

    public func start(completion: @escaping (Result<Int, WebServerError>) -> Void) {
        queue.async { [self] in
            guard listener == nil else {
                completion(.failure(.network(OurWords.t("TCP-сервер уже запущен"))))
                return
            }
            let options = configuration.listener
            let parameters = WebListenerFactory.parameters(loopbackOnly: options.loopbackOnly,
                                                           port: options.port)
            do {
                let fresh = try NWListener(using: parameters,
                                           on: WebListenerFactory.endpointPort(options.port))
                listener = fresh
                startCompletion = completion
                onStateChange?(.starting)
                fresh.stateUpdateHandler = { [weak self] state in
                    self?.queue.async { self?.listenerStateChanged(state) }
                }
                fresh.newConnectionHandler = { [weak self] connection in
                    self?.queue.async { self?.accept(connection) }
                }
                fresh.start(queue: queue)
            } catch let error as NWError {
                fail(.from(error, port: options.port, suggestion: options.fallbackPort))
            } catch {
                fail(.network("Не удалось поднять TCP-сервер: \(error.localizedDescription)"))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            for client in clients.values { client.close() }
            clients.removeAll()
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            lastPayload = nil
            startCompletion = nil
            publishCounters()
            onStateChange?(.stopped)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = Int(listener?.port?.rawValue ?? 0)
            onStateChange?(.running(port: port))
            finishStart(.success(port))
        case .failed(let error):
            fail(.from(error, port: configuration.listener.port,
                       suggestion: configuration.listener.fallbackPort))
        case .cancelled:
            onStateChange?(.stopped)
        default:
            break
        }
    }

    private func fail(_ error: WebServerError) {
        listener?.cancel()
        listener = nil
        onStateChange?(.failed(error.description))
        finishStart(.failure(error))
    }

    private func finishStart(_ result: Result<Int, WebServerError>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(result)
    }

    // MARK: - Видача слайдів

    public func broadcast(_ payload: RemoteSlidePayload) {
        queue.async { [self] in
            lastPayload = payload
            for client in clients.values where client.isSubscribed { send(payload, to: client) }
        }
    }

    public func broadcastHidden() {
        queue.async { [self] in
            var payload = lastPayload ?? RemoteSlidePayload()
            payload.isVisible = false
            lastPayload = payload
            for client in clients.values where client.isSubscribed { send(payload, to: client) }
        }
    }

    private func send(_ payload: RemoteSlidePayload, to client: Client) {
        let data = RemoteAPIPacket.slideEvent(payload,
                                              instance: configuration.instanceGUID,
                                              session: client.sessionGUID,
                                              sequence: client.nextSequence(),
                                              includeOut0: client.wantsProjectorContent)
        send(data, to: client)
    }

    /// Пакет іде одним рядком і закінчується «\r\n» — так вимагає протокол.
    private func send(_ data: Data, to client: Client) {
        guard !client.isFinished else { return }
        var framed = data
        framed.append(Self.terminator)
        client.connection.send(content: framed, completion: .contentProcessed { [weak self, weak client] error in
            guard error != nil, let self, let client else { return }
            self.drop(client)
        })
    }

    // MARK: - Клієнти

    private final class Client {
        let connection: NWConnection
        let sessionGUID = RemoteAPIIdentity.makeGUID()
        var sequence = 0
        var isSubscribed = false
        var wantsProjectorContent = false
        var wantsNextSlide = false
        var isFinished = false
        /// Прочитане, але ще не розібране: TCP віддає потік, а не пакети,
        /// і одне повідомлення легко приїжджає двома порціями.
        var buffer = Data()

        init(connection: NWConnection) { self.connection = connection }

        func nextSequence() -> Int {
            sequence += 1
            return sequence
        }

        func close() {
            guard !isFinished else { return }
            isFinished = true
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        if configuration.listener.loopbackOnly,
           !WebListenerFactory.isLoopback(connection.endpoint) {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        clients[ObjectIdentifier(client)] = client
        publishCounters()

        connection.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                guard let client else { return }
                self?.queue.async { self?.drop(client) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func drop(_ client: Client) {
        client.isFinished = true
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        publishCounters()
    }

    private func publishCounters() {
        let connected = clients.count
        let subscribed = clients.values.filter(\.isSubscribed).count
        counterLock.lock()
        counters = (connected, subscribed)
        counterLock.unlock()
        onClientsChanged?(connected, subscribed)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak client] content, _, isComplete, error in
            guard let self, let client, !client.isFinished else { return }
            if let content, !content.isEmpty {
                self.queue.async { self.append(content, to: client) }
            }
            if isComplete || error != nil {
                self.queue.async { self.drop(client) }
                return
            }
            self.receive(client)
        }
    }

    /// Набрати потік і розібрати з нього закінчені пакети.
    ///
    /// Самотній 0x0A теж вважаємо кінцем пакета: клієнта на мікроконтролері
    /// легко написати з одним `\n`, а відмова розбирати такий рядок виглядала б
    /// як «сервер мовчить» — і шукати причину довелося б аналізатором пакетів.
    private func append(_ data: Data, to client: Client) {
        client.buffer.append(data)
        if client.buffer.count > Self.bufferLimit {
            client.buffer.removeAll(keepingCapacity: false)
            drop(client)
            return
        }
        while let range = client.buffer.range(of: Data([0x0A])) {
            var line = client.buffer.subdata(in: client.buffer.startIndex..<range.lowerBound)
            client.buffer.removeSubrange(client.buffer.startIndex..<range.upperBound)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            handle(line, from: client)
            if client.isFinished { return }
        }
    }

    private func handle(_ data: Data, from client: Client) {
        guard let request = RemoteAPIRequest(data: data) else {
            send(RemoteAPIPacket.answer(command: "",
                                        instance: configuration.instanceGUID,
                                        session: client.sessionGUID,
                                        sequence: client.nextSequence(),
                                        code: RemoteAPICode.badRequest), to: client)
            return
        }

        switch request.command.lowercased() {
        case "subscribetoslidechanges":
            client.isSubscribed = true
            client.wantsProjectorContent = request.wantsProjectorContent
            client.wantsNextSlide = request.wantsNextSlide
            publishCounters()
            send(RemoteAPIPacket.answer(command: request.command,
                                        instance: configuration.instanceGUID,
                                        session: client.sessionGUID,
                                        sequence: client.nextSequence()), to: client)
            // Тому, хто підключився посеред служіння, віддаємо те, що вже на екрані.
            if let payload = lastPayload { send(payload, to: client) }

        case "unsubscribefromslidechanges":
            client.isSubscribed = false
            publishCounters()
            send(RemoteAPIPacket.answer(command: request.command,
                                        instance: configuration.instanceGUID,
                                        session: client.sessionGUID,
                                        sequence: client.nextSequence()), to: client)

        case "getsenderinfo":
            let sender = RemoteAPIIdentity.senderInfo(installGUID: configuration.installGUID)
            send(RemoteAPIPacket.answer(command: request.command,
                                        instance: configuration.instanceGUID,
                                        session: client.sessionGUID,
                                        sequence: client.nextSequence(),
                                        extra: ["Sender": sender]), to: client)

        default:
            send(RemoteAPIPacket.answer(command: request.command,
                                        instance: configuration.instanceGUID,
                                        session: client.sessionGUID,
                                        sequence: client.nextSequence(),
                                        code: RemoteAPICode.notAllowed), to: client)
        }
    }
}
