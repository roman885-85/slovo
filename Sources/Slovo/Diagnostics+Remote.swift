import AppKit
import Network
import SlovoCore

/// Пульт на телефоні — перевірка каналу без телефона: тим самим HTTP, що й
/// застосунок, з цієї ж машини. Стан, команда, довгий опит, PIN,
/// відповідь на розсилку й пошук пісень — по кроку на кожне.
extension Diagnostics {

    static func remoteSection(state: AppState) -> [Check] {
        let area = "Пульт"
        let server = RemoteControlServer.shared
        let wasEnabled = SettingsStore.shared.settings.options.remoteEnabled ?? true
        let wasPin = SettingsStore.shared.settings.options.remotePin ?? ""
        let wasPort = SettingsStore.shared.settings.options.remotePort ?? 8103
        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            server.apply(enabled: wasEnabled, port: wasPort, pin: wasPin, state: state)
            state.mode = wasMode
            state.isLive = wasLive
            NativeBibleBridge.shared.sync()
        }
        server.apply(enabled: true, port: wasPort, pin: "", state: state)
        wait(untilTrue: { server.isRunning }, seconds: 5)
        guard server.isRunning, server.port > 0 else {
            return [Check(area: area, name: "Канал пульта відповідає", status: .failed,
                          detail: "слухач не піднявся: \(server.lastError ?? "без объяснения")")]
        }
        let base = "http://127.0.0.1:\(server.port)"
        var lines: [String] = ["порт \(server.port)"]
        var faults: [String] = []

        /// Запит із цієї ж машини; відповідь приходить, поки крутиться цикл подій.
        /// Відповідь як є — код, заголовок типу й байти.
        func fetch(_ method: String, _ path: String, body: [String: Any]? = nil, raw: Data? = nil,
                   pin: String? = nil, timeout: Double = 8) -> (code: Int, type: String, data: Data)? {
            guard let url = URL(string: base + path) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            if let pin { request.setValue(pin, forHTTPHeaderField: "X-Slovo-Pin") }
            if let raw {
                request.httpBody = raw
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            } else if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var result: (Int, String, Data)?
            var finished = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                DispatchQueue.main.async { result = (code, type, data ?? Data()); finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: timeout + 2)
            return result
        }
        func call(_ method: String, _ path: String, body: [String: Any]? = nil, pin: String? = nil,
                  timeout: Double = 8) -> (code: Int, json: [String: Any])? {
            guard let got = fetch(method, path, body: body, pin: pin, timeout: timeout) else { return nil }
            let json = (try? JSONSerialization.jsonObject(with: got.data) as? [String: Any]) ?? [:]
            return (got.code, json)
        }

        // 1. Стан.
        state.mode = .bible
        state.isLive = false
        NativeBibleBridge.shared.sync()
        guard let first = call("GET", "/api/state"), first.code == 200 else {
            faults.append("GET /api/state не відповів")
            return [Check(area: area, name: "Канал пульта відповідає", status: .failed, detail: faults.joined(separator: "; "))]
        }
        let seq0 = (first.json["seq"] as? NSNumber)?.intValue ?? -1
        let preview0 = (first.json["preview"] as? [String: Any])?["text"] as? String ?? ""
        lines.append("стан: seq \(seq0), режим \(first.json["mode"] ?? "?"), передпоказ «\(preview0.prefix(20))»")
        if first.json["mode"] as? String != "bible" { faults.append("режим у стані не bible") }

        // 2. Команда «далі»: вірш змінився, номер стану виріс.
        guard let stepped = call("POST", "/api/next"), stepped.code == 200 else {
            faults.append("POST /api/next не відповів 200")
            return [Check(area: area, name: "Канал пульта відповідає", status: .failed, detail: faults.joined(separator: "; "))]
        }
        wait(untilTrue: { false }, seconds: 0.3)
        let after = call("GET", "/api/state")
        let seq1 = (after?.json["seq"] as? NSNumber)?.intValue ?? -1
        let live1 = (after?.json["slide"] as? [String: Any])?["text"] as? String ?? ""
        lines.append("після «далі»: seq \(seq1), у залі «\(live1.prefix(20))», показ \(after?.json["live"] ?? "?")")
        if seq1 <= seq0 { faults.append("номер стану не виріс після команди") }
        if live1.isEmpty { faults.append("після «далі» у залі порожньо") }

        // 3. Довгий опит: відповідь приходить із першою зміною, а не за строком.
        var polled: (code: Int, json: [String: Any])?
        var pollDone = false
        let started = Date()
        if let url = URL(string: base + "/api/state?since=\(seq1)") {
            URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 40)) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                DispatchQueue.main.async { polled = (code, json); pollDone = true }
            }.resume()
        }
        wait(untilTrue: { false }, seconds: 0.6)
        _ = call("POST", "/api/prev")
        wait(untilTrue: { pollDone }, seconds: 10)
        let waited = Date().timeIntervalSince(started)
        let seq2 = (polled?.json["seq"] as? NSNumber)?.intValue ?? -1
        lines.append(String(format: "довге опитування: відповідь через %.1f с, seq %d", waited, seq2))
        if !pollDone { faults.append("довге опитування не відповіло на зміну") }
        else if waited > 5 { faults.append("довге опитування відповіло лише за терміном") }
        if seq2 <= seq1 { faults.append("довге опитування повернуло старий номер") }

        // 4. PIN: без нього — відмова, з ним — відповідь.
        server.apply(enabled: true, port: wasPort, pin: "2468", state: state)
        let denied = call("GET", "/api/state")
        let allowed = call("GET", "/api/state", pin: "2468")
        lines.append("PIN: без нього \(denied?.code ?? 0), з ним \(allowed?.code ?? 0)")
        if denied?.code != 401 { faults.append("без PIN сервер не відмовив") }
        if allowed?.code != 200 { faults.append("з правильним PIN сервер не відповів") }
        server.apply(enabled: true, port: wasPort, pin: "", state: state)

        // 5. Розсилка «SLOVO?» — відповідь із портом.
        var beaconReply: [String: Any]?
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: RemoteControlServer.beaconPort)!,
                                      using: .udp)
        connection.start(queue: .global())
        connection.send(content: Data(RemoteControlServer.beaconQuestion.utf8), completion: .contentProcessed { _ in })
        connection.receiveMessage { data, _, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { beaconReply = json ?? [:] }
        }
        wait(untilTrue: { beaconReply != nil }, seconds: 5)
        connection.cancel()
        let beaconPort = (beaconReply?["port"] as? NSNumber)?.intValue ?? 0
        lines.append("розсилка: відповідь \(beaconReply == nil ? "не прийшов" : "прийшов"), порт \(beaconPort), ім'я «\(beaconReply?["name"] ?? "")»")
        if beaconPort != server.port { faults.append("на розсилку не прийшов правильний порт") }

        // 6. Пошук пісень.
        let songs = call("POST", "/api/songs", body: ["text": "Бог"])
        let foundSongs = (songs?.json["songs"] as? [[String: Any]])?.count ?? 0
        lines.append("пошук пісень «Бог»: \(foundSongs)")
        if NativeSongsWorkspace.shared.model.book != nil, foundSongs == 0 { faults.append("пошук пісень нічого не знайшов") }

        // 7. Презентація з телефона: файл → показ; картинка сторінки; гортання; указка.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-пульт-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deckName = "проба-пульт.pdf"
        let pdf = folder.appendingPathComponent(deckName)
        let uploadsCopy = RemoteControlServer.uploadsFolder.appendingPathComponent(deckName)
        defer {
            let workspace = NativeShowWorkspace.presentation
            workspace.model.close()
            workspace.open([])
            state.media.showStill(nil)
            SlidePointer.shared.hide()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: uploadsCopy)
        }
        if makePDF(at: pdf, pages: 2), let bytes = try? Data(contentsOf: pdf) {
            let encoded = deckName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deckName
            let uploaded = call("POST", "/api/upload?name=\(encoded)", timeout: 20)
            // `call` шле JSON; файл — сирими байтами.
            let sent = fetch("POST", "/api/upload?name=\(encoded)", raw: bytes, timeout: 20)
            let sentJSON = sent.flatMap { try? JSONSerialization.jsonObject(with: $0.data) as? [String: Any] } ?? [:]
            _ = uploaded
            let pagesGot = (sentJSON["pages"] as? NSNumber)?.intValue ?? -1
            lines.append("завантаження PDF: код \(sent?.code ?? 0), сторінок \(pagesGot), вкладка \(state.mode.rawValue)")
            if sent?.code != 200 { faults.append("завантаження файлу не прийнято: \(sentJSON["error"] ?? "код \(sent?.code ?? 0)")") }
            if pagesGot != 2 { faults.append("після завантаження відкрилося \(pagesGot) сторінок, а у файлі 2") }
            if state.mode != .presentation { faults.append("після завантаження програма не перейшла на вкладку презентації") }

            let after = call("GET", "/api/state")
            let presentation = after?.json["presentation"] as? [String: Any] ?? [:]
            let count = (presentation["count"] as? NSNumber)?.intValue ?? -1
            let pagesList = presentation["pages"] as? [[String: Any]] ?? []
            lines.append("стан: сторінок \(count), у списку \(pagesList.count), колод \((presentation["decks"] as? [Any])?.count ?? -1)")
            if count != 2 || pagesList.count != 2 { faults.append("у стані для телефона немає двох сторінок презентації") }

            let picture = fetch("GET", "/api/page?index=0&w=320", timeout: 10)
            let isJPEG = (picture?.data.count ?? 0) > 500 && picture?.data.prefix(2) == Data([0xFF, 0xD8])
            lines.append("картинка сторінки: код \(picture?.code ?? 0), \(picture?.type ?? ""), \(picture?.data.count ?? 0) байт")
            if picture?.code != 200 || !isJPEG { faults.append("картинка сторінки для телефона не прийшла як JPEG") }

            _ = call("POST", "/api/page", body: ["index": 1])
            wait(untilTrue: { false }, seconds: 0.4)
            let flipped = call("GET", "/api/state")
            let shown = flipped?.json["presentation"] as? [String: Any] ?? [:]
            let index = (shown["index"] as? NSNumber)?.intValue ?? -1
            let onWall = (shown["onWall"] as? Bool) ?? false
            lines.append("після «page 1»: index \(index), у залі \(onWall)")
            if index != 1 { faults.append("команда «page» не перегорнула на другу сторінку") }
            if !onWall { faults.append("після «page» сторінка не вийшла в зал") }

            // Гортання назад міняє стан, не міняючи довжини JSON
            // («Сторінка 2» → «Сторінка 1»): номер стану мусить вирости —
            // інакше телефон не дізнається про зміну сторінки (так і було: відбиток
            // рахувався hashValue-ом Data, а той дивиться на довжину й 80 байт).
            let seqBeforeBack = (flipped?.json["seq"] as? NSNumber)?.intValue ?? -1
            _ = call("POST", "/api/page", body: ["index": 0])
            wait(untilTrue: { false }, seconds: 0.4)
            let back = call("GET", "/api/state")
            let seqAfterBack = (back?.json["seq"] as? NSNumber)?.intValue ?? -1
            let backIndex = ((back?.json["presentation"] as? [String: Any])?["index"] as? NSNumber)?.intValue ?? -1
            lines.append("назад на сторінку 1: index \(backIndex), seq \(seqBeforeBack) → \(seqAfterBack)")
            if backIndex != 0 { faults.append("команда «page 0» не повернула першу сторінку") }
            if seqAfterBack <= seqBeforeBack { faults.append("номер стану не виріс при перегортанні тієї самої довжини — телефон не прокинеться") }

            // Скільки кадрів канал шле сам по собі: незмінний слайд він
            // повторює раз на секунду. Якщо не шле нічого — у каналі просто
            // немає кадру, і указці нема що змінювати.
            let ndiIdleBefore = state.ndi.sentFramesNow
            wait(untilTrue: { false }, seconds: 1)
            let ndiIdleFlow = state.ndi.sentFramesNow - ndiIdleBefore
            let ndiBefore = state.ndi.sentFramesNow
            let seqBeforePointer = (call("GET", "/api/state")?.json["seq"] as? NSNumber)?.intValue ?? -1
            _ = call("POST", "/api/pointer", body: ["x": 0.25, "y": 0.75])
            wait(untilTrue: { false }, seconds: 0.3)
            // Телефон малює указку в себе, тому її рух — це зміна стану:
            // номер має вирости, інакше пляму з миші телефон не побачить.
            let seqAfterPointer = (call("GET", "/api/state")?.json["seq"] as? NSNumber)?.intValue ?? -1
            if seqAfterPointer <= seqBeforePointer { faults.append("указка не підняла номер стану — телефон не побачить її") }
            let mark = SlidePointer.shared.mark
            lines.append("указка: \(mark.map { String(format: "%.2f %.2f", $0.x, $0.y) } ?? "немає")")
            if mark == nil || abs((mark?.x ?? 0) - 0.25) > 0.001 || abs((mark?.y ?? 0) - 0.75) > 0.001 {
                faults.append("указка з телефона не стала в 0,25/0,75")
            }
            if state.projection.isVisible {
                wait(untilTrue: { state.projection.pointerShown }, seconds: 1)
                if !state.projection.pointerShown { faults.append("указка не з'явилася на проекторі") }
                lines.append("на проекторі: \(state.projection.pointerShown ? "є" : "немає")")
            }
            if state.ndi.isActive {
                wait(untilTrue: { state.ndi.sentFramesNow > ndiBefore }, seconds: 2)
                let afterPointer = state.ndi.sentFramesNow - ndiBefore
                lines.append("NDI після указки: кадрів +\(afterPointer) (до неї за секунду +\(ndiIdleFlow))")
                // Сварити є за що лише тоді, коли канал і без указки щось шле.
                // У прогоні одного розділу зал ще нічого не малював, кадру в
                // каналі немає зовсім, і «указка не дійшла» сказало б неправду.
                if afterPointer <= 0, ndiIdleFlow > 0 {
                    faults.append("після указки в трансляцію не пішов новий кадр")
                }
            }
            _ = call("POST", "/api/pointer-off")
            if SlidePointer.shared.mark != nil { faults.append("«pointer-off» не прибрав указку") }

            // Колір і розмір з пульта: пляма в залі стає такою, як вибрав
            // оператор на телефоні, а після «прибрати» повертається до
            // налаштувань програми. Старий пульт без цих полів — як і раніше.
            let baseLook = SlidePointer.shared.look
            _ = call("POST", "/api/pointer", body: ["x": 0.5, "y": 0.5, "colour": "#00FF40",
                                                     "size": 0.22, "opacity": 0.8])
            let tinted = SlidePointer.shared.look
            let tintedState = (call("GET", "/api/state")?.json["pointer"] as? [String: Any]) ?? [:]
            lines.append("з телефона: колір \(SlidePointer.Look.hex(tinted.colour)), розмір \(String(format: "%.2f", tinted.size)), яскравість \(String(format: "%.2f", tinted.opacity)); у стані \(tintedState["colour"] ?? "—"), \(tintedState["source"] ?? "—")")
            if SlidePointer.Look.hex(tinted.colour) != "#00FF40" || abs(tinted.size - 0.22) > 0.001 {
                faults.append("колір і розмір указки з телефона не застосувалися")
            }
            if abs(tinted.opacity - 0.8) > 0.001 { faults.append("яскравість указки з телефона не застосувалася") }
            if tintedState["colour"] as? String != "#00FF40" || tintedState["source"] as? String != SlidePointer.phoneSource {
                faults.append("у стані для телефона немає кольору і джерела указки")
            }
            _ = call("POST", "/api/pointer", body: ["x": 0.5, "y": 0.6])
            if SlidePointer.shared.look != baseLook { faults.append("точка без кольору не повернула вигляд програми") }
            _ = call("POST", "/api/pointer-off")
            if SlidePointer.shared.look != baseLook { faults.append("після «pointer-off» вигляд указки не повернувся до налаштувань") }
        } else {
            lines.append("пробний PDF не зібрався — завантаження не перевіряли")
        }

        lines.append("запитів прийнято \(server.requestCount), розсилок \(server.beaconCount)")
        // Дорога телефона — не петля. Усе вище перевірено через
        // «127.0.0.1», а телефон іде по адресі машини в мережі, і саме там
        // його зупиняє те, чого зсередини не видно: недозволена локальна
        // мережа на macOS 15 або брандмауер. Власник: на іншому комп'ютері
        // телефон пише «нічого не знайдено».
        var reach: RemoteReachability.Result?
        RemoteReachability.probe(port: server.port, pin: "") { answer in reach = answer }
        wait(untilTrue: { reach != nil }, seconds: 20)
        if let reach {
            let reachable = reach.addresses.filter(\.answered).map(\.address)
            lines.append("дорогою телефона: адрес \(reach.addresses.count)"
                + ", відповіли \(reachable.isEmpty ? "жодна" : reachable.joined(separator: ", "))"
                + ", розсилка \(reach.beacon ? "відповіла" : "мовчить")")
            if reach.addresses.isEmpty {
                lines.append("мережевої адреси немає — перевіряти нічого")
            } else if reachable.isEmpty {
                faults.append("своєю мережевою адресою програма недосяжна — телефон її не побачить")
            } else if !reach.beacon {
                faults.append("на розсилку по мережі відповіді немає — телефон не знайде програму сам")
            }
        } else {
            lines.append("дорогою телефона: перевірка не встигла")
        }

        return [Check(area: area, name: "Канал пульта відповідає: стан, команди, довге опитування, PIN, розсилка",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}
