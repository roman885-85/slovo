import Foundation
import Network

/// UDP-сервер Remote API (за умовчанням порт 8100).
///
/// Третій транспорт протоколу і єдиний, у якого є власне
/// господарство: в UDP немає з'єднання, і «хто підписаний» доводиться пам'ятати самим.
///
/// Як це влаштовано за специфікацією автора:
///
///  * клієнт упізнається за `SessionGUID`, і на один GUID припадає рівно одна
///    пара «адреса — порт»;
///  * відповідаємо не туди, звідки прийшов пакет, а на порт `UDPPort`, названий у
///    самому пакеті: клієнт має право слухати відповіді окремим сокетом;
///  * `CSeq` у запиті зобов'язаний рости; пакет із номером не більшим за колишній —
///    це повтор загубленого, і обробляти його вдруге не можна;
///  * сесія живе `Expires` секунд, і клієнт продовжує її повторним
///    `Register`. Мовчазній сесії сервер шле подію `CloseSession` з кодом
///    410 і забуває її — інакше список підписників ріс би до кінця служіння.
///
/// Підтвердження (`Ack`) приймаємо і мовчимо у відповідь: вони потрібні клієнту, щоб
/// знати про доставку, а нам — щоб бачити, що він живий.
public final class RemoteAPIUDPServer {

    public struct Configuration: Sendable {
        public var listener: WebListenerOptions
        public var instanceGUID: String
        public var installGUID: String
        /// Час життя сесії в секундах — те саме `Expires` з відповіді.
        public var expires: Int

        public init(listener: WebListenerOptions,
                    instanceGUID: String = RemoteAPIIdentity.makeGUID(),
                    installGUID: String = RemoteAPIIdentity.makeGUID(),
                    expires: Int = 600) {
            self.listener = listener
            self.instanceGUID = instanceGUID
            self.installGUID = installGUID
            self.expires = expires
        }
    }

    private let queue = DispatchQueue(label: "ua.slovo.web.udp")
    private let configuration: Configuration
    private var listener: NWListener?
    /// З'єднання, які нам віддав слухач. Тримаємо їх, щоб читати
    /// подальші пакети того самого відправника.
    private var inbound: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: Session] = [:]
    /// Канали для відповідей: ключ — «адреса:порт», куди клієнт просив відповідати.
    private var outbound: [String: NWConnection] = [:]
    private var startCompletion: ((Result<Int, WebServerError>) -> Void)?
    private var lastPayload: RemoteSlidePayload?
    private var reaper: DispatchSourceTimer?

    private let counterLock = NSLock()
    private var counters = (connected: 0, subscribed: 0)

    public var onStateChange: ((WebServerRunState) -> Void)?
    public var onClientsChanged: ((_ connected: Int, _ subscribed: Int) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { listener?.cancel() }

    // MARK: - Сесія

    private final class Session {
        let guid: String
        var host: NWEndpoint.Host
        var port: NWEndpoint.Port
        var sequence = 0
        /// Останній прийнятий номер запиту — за ним відсіюємо повтори.
        var lastRequestSequence = 0
        var isSubscribed = false
        var wantsProjectorContent = false
        var wantsNextSlide = false
        var lastSeen = Date()

        init(guid: String, host: NWEndpoint.Host, port: NWEndpoint.Port) {
            self.guid = guid
            self.host = host
            self.port = port
        }

        func nextSequence() -> Int {
            sequence += 1
            return sequence
        }

        var addressKey: String { "\(host):\(port.rawValue)" }
    }

    // MARK: - Життєвий цикл

    public func start(completion: @escaping (Result<Int, WebServerError>) -> Void) {
        queue.async { [self] in
            guard listener == nil else {
                completion(.failure(.network(OurWords.t("UDP-сервер уже запущен"))))
                return
            }
            let options = configuration.listener
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
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
                startReaper()
            } catch let error as NWError {
                fail(.from(error, port: options.port, suggestion: options.fallbackPort))
            } catch {
                fail(.network("Не удалось поднять UDP-сервер: \(error.localizedDescription)"))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            reaper?.cancel()
            reaper = nil
            for connection in inbound.values { connection.cancel() }
            inbound.removeAll()
            for connection in outbound.values { connection.cancel() }
            outbound.removeAll()
            sessions.removeAll()
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

    // MARK: - Приймання

    private func accept(_ connection: NWConnection) {
        if configuration.listener.loopbackOnly,
           !WebListenerFactory.isLoopback(connection.endpoint) {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        inbound[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.inbound.removeValue(forKey: key) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.queue.async { self.handle(content, from: connection) }
            }
            guard error == nil else {
                self.queue.async { self.inbound.removeValue(forKey: ObjectIdentifier(connection)) }
                return
            }
            self.receive(connection)
        }
    }

    /// Звідки прийшов пакет — потрібна адреса відправника, а порт відповіді він назве сам.
    private func senderHost(_ connection: NWConnection) -> NWEndpoint.Host? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        return host
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        guard let host = senderHost(connection) else { return }
        guard let request = RemoteAPIRequest(data: data) else { return }

        // Порт відповіді обов'язковий в усіх командах протоколу: без нього відповідати
        // просто нікуди, і мовчання тут чесніше за вигадану адресу.
        guard let replyPort = request.udpPort,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: replyPort)) else { return }

        let command = request.command.lowercased()

        if command == "register" {
            handleRegister(request, host: host, port: port)
            return
        }

        // Усе інше — лише для зареєстрованої сесії.
        guard let guid = request.sessionGUID, let session = sessions[guid] else {
            let packet = RemoteAPIPacket.answer(command: request.command,
                                                instance: configuration.instanceGUID,
                                                session: request.sessionGUID ?? "",
                                                sequence: 0,
                                                code: RemoteAPICode.notFound,
                                                extra: requestEcho(request))
            send(packet, host: host, port: port)
            return
        }

        session.host = host
        session.port = port
        session.lastSeen = Date()

        // Підтвердження приймання відповіді не вимагає нічого, крім позначки про життя.
        if command == "ack" { return }

        // Повтор загубленого пакета: номер не виріс — удруге не виконуємо.
        if let sequence = request.sequence {
            guard sequence > session.lastRequestSequence else { return }
            session.lastRequestSequence = sequence
        }

        switch command {
        case "unregister":
            reply(request, session: session, code: RemoteAPICode.ok)
            sessions.removeValue(forKey: session.guid)
            publishCounters()

        case "subscribetoslidechanges":
            session.isSubscribed = true
            session.wantsProjectorContent = request.wantsProjectorContent
            session.wantsNextSlide = request.wantsNextSlide
            publishCounters()
            reply(request, session: session, code: RemoteAPICode.ok)
            if let payload = lastPayload { send(payload, to: session) }

        case "unsubscribefromslidechanges":
            session.isSubscribed = false
            publishCounters()
            reply(request, session: session, code: RemoteAPICode.ok)

        case "getsenderinfo":
            let sender = RemoteAPIIdentity.senderInfo(installGUID: configuration.installGUID)
            reply(request, session: session, code: RemoteAPICode.ok, extra: ["Sender": sender])

        default:
            reply(request, session: session, code: RemoteAPICode.notAllowed)
        }
    }

    /// `Register` — єдина команда, яку приймаємо без сесії.
    private func handleRegister(_ request: RemoteAPIRequest,
                                host: NWEndpoint.Host,
                                port: NWEndpoint.Port) {
        if let guid = request.sessionGUID, !guid.isEmpty {
            guard let session = sessions[guid] else {
                // Названої сесії немає — клієнту потрібна нова реєстрація.
                let packet = RemoteAPIPacket.answer(command: request.command,
                                                    instance: configuration.instanceGUID,
                                                    session: guid,
                                                    sequence: 0,
                                                    code: RemoteAPICode.notFound,
                                                    extra: requestEcho(request))
                send(packet, host: host, port: port)
                return
            }
            session.host = host
            session.port = port
            session.lastSeen = Date()
            if let sequence = request.sequence { session.lastRequestSequence = sequence }
            reply(request, session: session, code: RemoteAPICode.ok,
                  extra: ["Expires": configuration.expires])
            return
        }

        // Реєстрація без GUID: заводимо нову сесію, а колишні з тією самою парою
        // «адреса — порт» закриваємо — так велить специфікація, і так не копичаться
        // привиди після перезапуску клієнта.
        let session = Session(guid: RemoteAPIIdentity.makeGUID(), host: host, port: port)
        let key = session.addressKey
        for (guid, existing) in sessions where existing.addressKey == key {
            sessions.removeValue(forKey: guid)
        }
        if let sequence = request.sequence { session.lastRequestSequence = sequence }
        sessions[session.guid] = session
        publishCounters()
        reply(request, session: session, code: RemoteAPICode.ok,
              extra: ["Expires": configuration.expires])
    }

    /// Відповідь на команду: з луною номера запиту, як вимагає протокол.
    private func reply(_ request: RemoteAPIRequest,
                       session: Session,
                       code: (code: Int, text: String),
                       extra: [String: Any] = [:]) {
        var fields = extra
        for (key, value) in requestEcho(request) { fields[key] = value }
        let packet = RemoteAPIPacket.answer(command: request.command,
                                            instance: configuration.instanceGUID,
                                            session: session.guid,
                                            sequence: session.nextSequence(),
                                            code: code,
                                            extra: fields)
        send(packet, host: session.host, port: session.port)
    }

    private func requestEcho(_ request: RemoteAPIRequest) -> [String: Any] {
        guard let sequence = request.sequence else { return [:] }
        return ["RequestCSeq": sequence]
    }

    // MARK: - Видача слайдів

    public func broadcast(_ payload: RemoteSlidePayload) {
        queue.async { [self] in
            lastPayload = payload
            for session in sessions.values where session.isSubscribed { send(payload, to: session) }
        }
    }

    public func broadcastHidden() {
        queue.async { [self] in
            var payload = lastPayload ?? RemoteSlidePayload()
            payload.isVisible = false
            lastPayload = payload
            for session in sessions.values where session.isSubscribed { send(payload, to: session) }
        }
    }

    private func send(_ payload: RemoteSlidePayload, to session: Session) {
        let data = RemoteAPIPacket.slideEvent(payload,
                                              instance: configuration.instanceGUID,
                                              session: session.guid,
                                              sequence: session.nextSequence(),
                                              includeOut0: session.wantsProjectorContent)
        send(data, host: session.host, port: session.port)
    }

    /// Відправлення на названий клієнтом порт. Канал тримаємо відкритим: в одного
    /// підписника слайд міняється десятки разів за служіння, і заводити сокет
    /// заново на кожен вірш — зайва робота.
    private func send(_ data: Data, host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let key = "\(host):\(port.rawValue)"
        let connection: NWConnection
        if let existing = outbound[key] {
            connection = existing
        } else {
            let fresh = NWConnection(host: host, port: port, using: .udp)
            fresh.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.queue.async { self?.outbound.removeValue(forKey: key) }
                default:
                    break
                }
            }
            fresh.start(queue: queue)
            outbound[key] = fresh
            connection = fresh
        }
        connection.send(content: data, completion: .idempotent)
    }

    // MARK: - Тайм-аут сесій

    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Раз на десять секунд: сесія живе хвилинами, частіше перевіряти нема чого.
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.reapExpired() }
        timer.resume()
        reaper = timer
    }

    private func reapExpired() {
        let deadline = Date().addingTimeInterval(-Double(configuration.expires))
        let expired = sessions.values.filter { $0.lastSeen < deadline }
        guard !expired.isEmpty else { return }
        for session in expired {
            // Мовчазному клієнтові кажемо, чому він більше нічого не отримає:
            // без цієї події він чекав би слайдів до кінця служіння.
            let packet = RemoteAPIPacket.sessionClosed(instance: configuration.instanceGUID,
                                                       session: session.guid,
                                                       sequence: session.nextSequence())
            send(packet, host: session.host, port: session.port)
            sessions.removeValue(forKey: session.guid)
        }
        publishCounters()
    }

    private func publishCounters() {
        let connected = sessions.count
        let subscribed = sessions.values.filter(\.isSubscribed).count
        counterLock.lock()
        counters = (connected, subscribed)
        counterLock.unlock()
        onClientsChanged?(connected, subscribed)
    }
}
