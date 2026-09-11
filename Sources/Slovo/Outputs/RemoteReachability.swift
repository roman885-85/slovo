import Foundation
import Network
import SlovoCore

/// Чи бачить пульт цю машину — очима самого телефона.
///
/// Власник: пульт «работает только с данной машиной, а с другими не
/// соединяется», на другому комп'ютері телефон пише «нічого не знайдено».
///
/// Такий відмову не видно зсередини програми: слухач піднявся, порт
/// зайнято, все ніби гаразд — а телефон нічого не бачить. Тому що між ними
/// стоїть не програма, а система: на macOS 15 застосунок мусить дістати
/// дозвіл «Локальна мережа», інакше його не чути в мережі зовсім, і жодної
/// помилки при цьому не буває; окремо може заважати брандмауер.
///
/// Тут програма ходить до себе тією самою дорогою, що й телефон: не через
/// `127.0.0.1`, а по своїй адресі в мережі, і питає розсилкою, як питає
/// телефон. Якщо власною адресою достукатися не вдалося, а через петлю —
/// вдалося, значить справа не в програмі, і сказати про це треба словами.
enum RemoteReachability {

    struct Result {
        var loopback = false
        var loopbackNote = ""
        /// Адреса → чи відповіла.
        var addresses: [(address: String, answered: Bool, note: String)] = []
        var beacon = false
        var beaconNote = ""

        /// Головний висновок — тим, хто дивиться на екран, а не в код.
        var verdict: String {
            if !loopback {
                return OurWords.t("Канал пульта не поднялся в самой программе: ") + loopbackNote
            }
            let reachable = addresses.filter(\.answered).map(\.address)
            if addresses.isEmpty {
                return OurWords.t("У этой машины нет сетевого адреса, кроме внутреннего: "
                    + "телефон подключиться не сможет. Включите Wi-Fi или сеть по проводу.")
            }
            if reachable.isEmpty {
                return OurWords.t("Программа отвечает сама себе, но по своему сетевому адресу — нет. "
                    + "Так бывает, когда система не пустила её в локальную сеть: "
                    + "Системные настройки → Конфиденциальность и безопасность → Локальная сеть — "
                    + "и «Слово» должно быть включено. Второе место — брандмауэр: "
                    + "Системные настройки → Сеть → Брандмауэр → Параметры — «Слово» должно принимать входящие.")
            }
            if !beacon {
                return OurWords.t("Программа доступна по адресу %s, но на общий вызов по сети не отвечает. "
                    + "Телефон её не найдёт сам — введите адрес в пульте руками. "
                    + "Обычная причина — «изоляция клиентов» в настройках роутера или гостевая сеть.",
                    reachable.joined(separator: ", "))
            }
            return OurWords.t("Всё в порядке: программа отвечает по адресу %s и откликается на поиск. "
                + "Если телефон её не находит — он в другой сети.", reachable.joined(separator: ", "))
        }
    }

    /// Пройти дорогою телефона. Кличеться з головного потоку, відповідь —
    /// туди ж; сама робота йде в фоні, бо чекає на мережу.
    static func probe(port: Int, pin: String, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = Result()
            let (ok, note) = ask(host: "127.0.0.1", port: port, pin: pin)
            result.loopback = ok
            result.loopbackNote = note
            for address in SettingsNetworkInterfaces.addresses() {
                let (answered, why) = ask(host: address, port: port, pin: pin)
                result.addresses.append((address, answered, why))
            }
            let (heard, beaconNote) = shout()
            result.beacon = heard
            result.beaconNote = beaconNote
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Один запит `/api/state` — рівно те, чим пульт перевіряє зв'язок.
    private static func ask(host: String, port: Int, pin: String) -> (Bool, String) {
        guard let url = URL(string: "http://\(host):\(port)/api/state") else { return (false, "адреса не зібралася") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if !pin.isEmpty { request.setValue(pin, forHTTPHeaderField: "X-Slovo-Pin") }
        let semaphore = DispatchSemaphore(value: 0)
        var answered = false
        var note = ""
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, error in
            if let error { note = error.localizedDescription }
            if let code = (response as? HTTPURLResponse)?.statusCode {
                answered = code == 200
                if code == 401 { note = OurWords.t("не подошёл PIN") }
                else if code != 200 { note = "код \(code)" }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        task.cancel()
        return (answered, note)
    }

    /// Крикнути «SLOVO?» так, як кричить телефон, — і послухати відповідь.
    private static func shout() -> (Bool, String) {
        let socketHandle = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketHandle >= 0 else { return (false, "не відкрився сокет") }
        defer { close(socketHandle) }
        var yes: Int32 = 1
        setsockopt(socketHandle, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketHandle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = RemoteControlServer.beaconPort.bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        let question = Array(RemoteControlServer.beaconQuestion.utf8)
        let sent = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                sendto(socketHandle, question, question.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return (false, "розсилку не пустила система") }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(socketHandle, &buffer, buffer.count, 0)
        guard received > 0 else { return (false, "відповіді на розсилку немає") }
        let text = String(decoding: buffer[0..<received], as: UTF8.self)
        return (text.contains("Slovo"), text.contains("Slovo") ? "" : "відповідь не наша: \(text.prefix(40))")
    }
}
