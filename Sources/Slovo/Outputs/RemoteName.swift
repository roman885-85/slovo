import Foundation
import Network
import dnssd

/// Ім'я «Слова» в мережі: slovo.local.
///
/// Власник: «может сделать для запуска не переход по ай пи адресу, а вход по
/// имени, для удобства» — і «запуск не только с этой машины, а с любого
/// устройства». Тому ім'я оголошує сама програма, а не macOS: хоч який
/// комп'ютер веде служіння, у мережі він — slovo.local, і планшет, телефон
/// чи інший комп'ютер відкривають ту саму адресу. Ім'я комп'ютера
/// («MacBook-Pro-admin.local») для цього не годиться: воно в кожної машини
/// своє, і його треба знати.
///
/// Оголошення — записи A у Bonjour (mDNS), по одному на кожен живий
/// інтерфейс. Друге «Слово» в тій самій мережі отримає відповідь «ім'я
/// зайняте» і візьме slovo-2.local. Мережа змінилася (інший Wi-Fi, кабель) —
/// записи оголошуються наново, з новими адресами.
@MainActor
final class RemoteName {

    static let shared = RemoteName()

    /// Оголошене ім'я без крапки в кінці: «slovo.local». `nil` — ще не
    /// оголошено або не вдалося.
    private(set) var name: String?
    /// Адреси, на які вказує ім'я, — цифрами.
    private(set) var addresses: [String] = []
    /// Щось змінилося — ім'я чи адреси. Для вікна «Пульт у браузері».
    var onChange: (() -> Void)?

    private var connection: DNSServiceRef?
    /// 0 — slovo.local, 1 — slovo-2.local і далі.
    private var attempt = 0
    private var offered: [String] = []
    private var monitor: NWPathMonitor?
    private var pending: DispatchWorkItem?
    private var running = false

    private init() {}

    /// Ім'я без «.local» — з налаштувань: slovo, або своє для другого залу.
    private var base = "slovo"

    private var candidate: String { attempt == 0 ? "\(base).local" : "\(base)-\(attempt + 1).local" }

    /// Ім'я, придатне для мережі: латиниця, цифри й дефіс. Кирилицю mDNS
    /// переніс би, а браузери — ні; порожнє — «slovo».
    nonisolated static func clean(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let text = String(name.lowercased().filter { allowed.contains($0) }.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return text.isEmpty ? "slovo" : text
    }

    func start(name: String) {
        let wanted = Self.clean(name)
        if running, wanted == base { return }
        if running { stop() }
        base = wanted
        running = true
        attempt = 0
        let watcher = NWPathMonitor()
        watcher.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.republishSoon() } }
        }
        watcher.start(queue: .main)
        monitor = watcher
        publish()
    }

    func stop() {
        running = false
        monitor?.cancel()
        monitor = nil
        pending?.cancel()
        pending = nil
        withdraw()
        update(name: nil, addresses: [])
    }

    /// Мережа ворухнулася — зачекати, поки вона вляжеться, і оголосити знову:
    /// при зміні Wi-Fi подій приходить кілька поспіль.
    private func republishSoon() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.publish() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func withdraw() {
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }

    private func publish() {
        withdraw()
        guard running else { return }
        let interfaces = Self.interfaces()
        guard !interfaces.isEmpty else {
            update(name: nil, addresses: [])
            return
        }
        var created: DNSServiceRef?
        guard DNSServiceCreateConnection(&created) == DNSServiceErrorType(kDNSServiceErr_NoError), let created else {
            NativeTrace.say("ім'я: mDNS недоступний")
            update(name: nil, addresses: [])
            return
        }
        connection = created
        DNSServiceSetDispatchQueue(created, .main)
        let fullName = candidate + "."
        var registered = 0
        for interface in interfaces {
            var record: DNSRecordRef?
            var bytes = interface.bytes
            let error = DNSServiceRegisterRecord(created, &record, DNSServiceFlags(kDNSServiceFlagsUnique),
                                                 interface.index, fullName,
                                                 UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                                 UInt16(bytes.count), &bytes, 120, Self.reply, nil)
            if error == DNSServiceErrorType(kDNSServiceErr_NoError) { registered += 1 }
        }
        offered = interfaces.map(\.text)
        if registered == 0 {
            NativeTrace.say("ім'я: не вдалося оголосити \(candidate)")
            update(name: nil, addresses: [])
        }
    }

    /// Відповідь mDNS на кожен запис: оголошено — або ім'я зайняте.
    private static let reply: DNSServiceRegisterRecordReply = { _, _, _, error, _ in
        MainActor.assumeIsolated { RemoteName.shared.replied(error) }
    }

    private func replied(_ error: DNSServiceErrorType) {
        guard running else { return }
        if error == DNSServiceErrorType(kDNSServiceErr_NoError) {
            if name != candidate || addresses != offered {
                NativeTrace.say("ім'я: \(candidate) → \(offered.joined(separator: ", "))")
                update(name: candidate, addresses: offered)
            }
        } else if error == DNSServiceErrorType(kDNSServiceErr_NameConflict), attempt < 8 {
            let busy = candidate
            attempt += 1
            NativeTrace.say("ім'я: \(busy) уже зайняте в мережі — беру \(candidate)")
            // Не зсередини відповіді: з'єднання, що її принесло, зараз буде
            // закрите.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.publish() } }
        } else {
            NativeTrace.say("ім'я: оголосити не вдалося — помилка \(error)")
            update(name: nil, addresses: [])
        }
    }

    private func update(name: String?, addresses: [String]) {
        guard name != self.name || addresses != self.addresses else { return }
        self.name = name
        self.addresses = addresses
        onChange?()
    }

    // MARK: - Інтерфейси

    struct Interface {
        let index: UInt32
        let bytes: [UInt8]
        let text: String
    }

    /// Живі інтерфейси з адресою IPv4, крім петлі, тунелів VPN і службових
    /// каналів Apple (AWDL та інші): через них планшет «Слова» не побачить.
    nonisolated static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        let skipped = ["lo", "utun", "awdl", "llw", "anpi", "gif", "stf", "ipsec", "ppp"]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let interfaceName = String(cString: current.pointee.ifa_name)
            guard !skipped.contains(where: { interfaceName.hasPrefix($0) }) else { continue }
            let bytes: [UInt8] = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                withUnsafeBytes(of: inet.pointee.sin_addr.s_addr) { Array($0) }
            }
            guard bytes.count == 4, !(bytes[0] == 169 && bytes[1] == 254) else { continue }
            let text = bytes.map(String.init).joined(separator: ".")
            result.append(Interface(index: if_nametoindex(current.pointee.ifa_name), bytes: bytes, text: text))
        }
        return result
    }
}

/// Посилання на пульт у браузері — одне правило для вікна, параметрів і
/// самоперевірки: ім'я чи адреса і власний порт браузерного пульта
/// (нестандартний, 8105 за умовчанням — його можна змінити в параметрах).
@MainActor
enum RemoteWebAddress {

    static var port: Int {
        let server = RemoteControlServer.shared
        if server.webRunning { return server.webPort }
        return SettingsStore.shared.settings.options.remoteWebPort ?? 8105
    }

    /// Без номера — коли сторінка відповідає й на порту 80.
    static func link(host: String) -> String {
        RemoteControlServer.shared.webRunning && RemoteControlServer.shared.plainReady
            ? "http://\(host)/" : "http://\(host):\(port)/"
    }

    /// За ім'ям — якщо ім'я вже оголошено.
    static var named: String? { RemoteName.shared.name.map(link(host:)) }

    /// Цифрами — за першою живою адресою комп'ютера.
    static var numeric: String? {
        (RemoteName.shared.addresses.first ?? RemoteName.interfaces().first?.text).map(link(host:))
    }
}
