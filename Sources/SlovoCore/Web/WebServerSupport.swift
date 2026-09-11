import Foundation
import Network

/// Помилки мережевих виводів, перекладені з мови errno на людську.
///
/// Операторові в залі марне «POSIXErrorCode: 13», йому треба знати, що
/// робити: змінити порт або закрити чужу програму.
public enum WebServerError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Порт менший за 1024 — на macOS такі слухає лише root.
    case portRequiresRoot(Int, suggestion: Int)
    case portBusy(Int, suggestion: Int)
    case addressUnavailable(String)
    case missingContentFolder(String)
    case network(String)

    public var description: String {
        switch self {
        case let .portRequiresRoot(port, suggestion):
            return OurWords.t("Порт %s на macOS доступен только с правами root. Укажите порт выше 1024 — например, %s.", "\(port)", "\(suggestion)")
        case let .portBusy(port, suggestion):
            return OurWords.t("Порт %s уже занят другой программой. Освободите его или укажите другой — например, %s.", "\(port)", "\(suggestion)")
        case let .addressUnavailable(text):
            return OurWords.t("Не удалось занять сетевой адрес: %s.", "\(text)")
        case let .missingContentFolder(path):
            return OurWords.t("Папка веб-страниц не найдена: %s.", "\(path)")
        case let .network(text):
            return text
        }
    }

    /// Такі помилки самі не розсмокчуться: слухачеві немає сенсу чекати у `.waiting`.
    var isFatal: Bool {
        switch self {
        case .portRequiresRoot, .portBusy, .addressUnavailable, .missingContentFolder: return true
        case .network: return false
        }
    }

    /// Чи можна для цієї помилки мовчки перейти на запасний порт.
    var allowsPortFallback: Bool {
        switch self {
        case .portRequiresRoot, .portBusy: return true
        default: return false
        }
    }

    static func from(_ error: NWError, port: Int, suggestion: Int) -> WebServerError {
        guard case let .posix(code) = error else {
            return .network(OurWords.t("Сетевая ошибка на порту %s: %s", "\(port)", "\(error.localizedDescription)"))
        }
        switch code {
        case .EACCES, .EPERM:
            return .portRequiresRoot(port, suggestion: suggestion)
        case .EADDRINUSE:
            return .portBusy(port, suggestion: suggestion)
        case .EADDRNOTAVAIL:
            return .addressUnavailable(OurWords.t("адрес не принадлежит этому компьютеру (порт %s)", "\(port)"))
        default:
            return .network(OurWords.t("Сетевая ошибка на порту %s: %s", "\(port)", "\(error.localizedDescription)"))
        }
    }
}

/// Стан одного слухача.
public enum WebServerRunState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)

    public var isRunning: Bool { if case .running = self { return true }; return false }

    public var port: Int? { if case let .running(port) = self { return port }; return nil }

    public var errorText: String? { if case let .failed(text) = self { return text }; return nil }
}

/// Спільні налаштування слухача: на якому порту і кого пускати.
public struct WebListenerOptions: Sendable, Hashable {
    /// 0 — «будь-який вільний порт»: так зручно піднімати сервер у тестах.
    public var port: Int
    /// Порт, який запропонуємо (і займемо при `allowsFallback`), якщо основний не дали.
    public var fallbackPort: Int
    public var allowsFallback: Bool
    /// Лише для цього комп'ютера. За умовчанням вимкнено: сенс веб-виводу
    /// в тому, щоб сторінку відкрили з телефона в залі.
    public var loopbackOnly: Bool

    public init(port: Int, fallbackPort: Int, allowsFallback: Bool = true, loopbackOnly: Bool = false) {
        self.port = port
        self.fallbackPort = fallbackPort
        self.allowsFallback = allowsFallback
        self.loopbackOnly = loopbackOnly
    }
}

/// Заготовка параметрів TCP для обох серверів.
enum WebListenerFactory {

    static func parameters(loopbackOnly: Bool, port: Int) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Без затримки Нейгла: слайд — це один короткий пакет, копити нічого.
        tcp.noDelay = true
        // З'єднання оператора не має висіти вічно, якщо ноутбук винесли з мережі.
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30

        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Перезапуск виводу не має впиратися в TIME_WAIT минулого слухача.
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        // Обмежити слухача петльовою адресою через `requiredLocalEndpoint`
        // не можна: з ним `NWListener` узагалі не створюється — перевірено на цій
        // машині для кількох портів. Тому режим «лише локально»
        // реалізовано відбором вхідних з'єднань (див. `isLoopback`).
        _ = loopbackOnly
        return parameters
    }

    static func endpointPort(_ port: Int) -> NWEndpoint.Port {
        NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
    }

    /// З'єднання прийшло з цього самого комп'ютера?
    static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default:        return false
        }
    }
}

/// IPv4-адреси комп'ютера в локальній мережі — щоб показати операторові посилання,
/// яке можна набрати на телефоні, і не змушувати його лізти в налаштування.
public enum LocalNetwork {

    public static func addresses() -> [String] {
        var found: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let text = String(cString: host)
            // 169.254.* — самопризначена адреса, нею в зал не потрапиш.
            if !text.isEmpty, !text.hasPrefix("169.254."), !found.contains(text) { found.append(text) }
        }
        return found
    }

    /// Найімовірніша адреса для телефонів у залі.
    public static func preferredAddress() -> String? { addresses().first }
}
