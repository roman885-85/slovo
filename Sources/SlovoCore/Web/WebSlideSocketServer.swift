import Foundation
import Network

/// WebSocket-сервер Remote API: роздає слайд сторінкам із теки `RemoteAPI`.
///
/// Сторінки автора підключаються до `ws://<адреса>:8100/ws`, одразу шлють
/// `SubscribeToSlideChanges` і далі лише слухають. Шлях `/ws` вони вимагають в
/// адресі, але сервер його не перевіряє — оригінал цього теж не робить, а
/// причіпка до шляху зламала б клієнтів, які ходять на корінь.
public final class WebSlideSocketServer {

    public struct Configuration: Sendable {
        public var listener: WebListenerOptions
        /// GUID інстанції: один на весь час роботи програми, як в оригіналі.
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

    private let queue = DispatchQueue(label: "ua.slovo.web.ws")
    private let configuration: Configuration
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var startCompletion: ((Result<Int, WebServerError>) -> Void)?
    /// Останній стан слайда: сторінці, що підключилася посеред служіння,
    /// треба показати те, що вже на екрані, а не чекати наступного вірша.
    private var lastPayload: RemoteSlidePayload?

    private let counterLock = NSLock()
    private var counters = (connected: 0, subscribed: 0)

    /// Обидва обробники кличуться на внутрішній черзі сервера.
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
                completion(.failure(.network(OurWords.t("WebSocket-сервер уже запущен"))))
                return
            }
            let options = configuration.listener
            let parameters = WebListenerFactory.parameters(loopbackOnly: options.loopbackOnly, port: options.port)

            let websocket = NWProtocolWebSocket.Options()
            // Пінги від браузера мають отримувати відповідь без нашої участі,
            // інакше браузер вважатиме з'єднання мертвим.
            websocket.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

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
            for client in clients.values { client.close() }
            clients.removeAll()
            lastPayload = nil
            startCompletion = nil
            publishCounters()
            onStateChange?(.stopped)
        }
    }

    public var connectedClients: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return counters.connected
    }

    public var subscribedClients: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return counters.subscribed
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port.map { Int($0.rawValue) } ?? configuration.listener.port
            finishStart(.success(port))
            onStateChange?(.running(port: port))

        case let .failed(error):
            fail(WebServerError.from(error,
                                     port: configuration.listener.port,
                                     suggestion: configuration.listener.fallbackPort))

        case let .waiting(error):
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
        finishStart(.failure(error))
        onStateChange?(.failed(error.description))
    }

    private func finishStart(_ result: Result<Int, WebServerError>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        completion(result)
    }

    // MARK: - Розсилка

    /// Віддає слайд усім підписникам. Можна кликати з будь-якого потоку.
    public func broadcast(_ payload: RemoteSlidePayload) {
        queue.async { [self] in
            lastPayload = payload
            for client in clients.values where client.isSubscribed {
                send(payload, to: client)
            }
        }
    }

    /// Сховати слайд, не міняючи його вмісту (F12 і «порожній слайд»).
    /// Розіслати значення налаштувань усім сторінкам.
    ///
    /// Правка повзунка доходила до залу лише після перезавантаження сторінки, а
    /// сторінка зазвичай відкрита в OBS. Тепер вона слухає ті самі кадри, що й
    /// текст слайда, і застосовує надіслане тут же.
    public func broadcastStyle(_ values: [String: String]) {
        guard !values.isEmpty else { return }
        var pairs: [String] = []
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            let safe = value.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("\"\(name)\":\"\(safe)\"")
        }
        let json = "{\"SlovoVars\":{" + pairs.joined(separator: ",") + "}}"
        let data = Data(json.utf8)
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values { self.send(data, to: client) }
        }
    }

    public func broadcastHidden() {
        queue.async { [self] in
            var payload = lastPayload ?? RemoteSlidePayload()
            payload.isVisible = false
            lastPayload = payload
            for client in clients.values where client.isSubscribed {
                send(payload, to: client)
            }
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

    private func send(_ data: Data, to client: Client) {
        guard !client.isFinished else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "slovo", metadata: [metadata])
        client.connection.send(content: data,
                               contentContext: context,
                               isComplete: true,
                               completion: .contentProcessed { [weak self, weak client] error in
            guard error != nil, let self, let client else { return }
            // Помилка запису — клієнт уже пішов; чекати від нього закриття нема чого.
            self.drop(client)
        })
    }

    // MARK: - Клієнти

    private final class Client {
        let connection: NWConnection
        /// Живе до закриття каналу — за ним сторінки відрізняють наш потік від чужого.
        let sessionGUID = RemoteAPIIdentity.makeGUID()
        var sequence = 0
        var isSubscribed = false
        var wantsProjectorContent = false
        var wantsNextSlide = false
        var isFinished = false

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
        // Режим «лише локально»: слухач приймає всіх, тому чужих
        // відсікаємо тут — інакше сторінка зі слайдом виявиться видна всій мережі.
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
                self?.drop(client)
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
        client.connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, !client.isFinished else { return }

            if let error {
                _ = error
                self.drop(client)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata

            switch metadata?.opcode {
            case .close:
                self.drop(client)
                return
            case .text, .binary, .some(.cont), .none:
                if let content, !content.isEmpty { self.handle(content, from: client) }
            default:
                break   // ping/pong відпрацьовує сам транспорт
            }
            self.receive(client)
        }
    }

    private func handle(_ data: Data, from client: Client) {
        guard let request = RemoteAPIRequest(data: data) else {
            let packet = RemoteAPIPacket.answer(command: "",
                                                instance: configuration.instanceGUID,
                                                session: client.sessionGUID,
                                                sequence: client.nextSequence(),
                                                code: RemoteAPICode.badRequest)
            send(packet, to: client)
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
            // Доганяємо сторінку поточним слайдом — інакше до наступного вірша
            // вона стоїть порожня, хоча на проекторі вже щось є.
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
