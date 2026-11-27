import AppKit
import SlovoCore

/// Презентація з телефона після Біблії й пісень.
///
/// Власник 01.11: «презентация загружена и готова к показу. Во время служения
/// выводится текст Библии, песни, затем требуется вывод загруженной
/// презентации с пульта, а пульт после этого выводит только последний слайд,
/// который был показан». Перевірка йде тим самим шляхом, що телефон: файл
/// надсилається на `/api/upload`, команди — на `/api/show`, `/api/next`,
/// `/api/prev`; пісню в зал ставить «оператор» пунктом Плану.
extension Diagnostics {

    static func remoteShowSection(state: AppState) -> [Check] {
        let area = "Пульт"
        let name = "Телефон на вкладці «Показ»: презентація після пісні"
        let server = RemoteControlServer.shared
        let options = SettingsStore.shared.settings.options
        let wasEnabled = options.remoteEnabled ?? true
        let wasPin = options.remotePin ?? ""
        let wasPort = options.remotePort ?? 8103
        let wasMode = state.mode, wasLive = state.isLive
        let presentation = NativeShowWorkspace.presentation
        let wasDecks = presentation.model.decks.map(\.url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-пульт-показ-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var uploaded: [URL] = []
        defer {
            server.apply(enabled: wasEnabled, port: wasPort, pin: wasPin, state: state)
            state.media.showStill(nil)
            presentation.model.close()
            presentation.open(wasDecks)
            for file in uploaded { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: folder)
            state.isLive = wasLive
            state.mode = wasMode
            NativeBibleBridge.shared.sync()
        }
        let songs = DeskModel.shared.plan.items.filter {
            if case .song = $0.content { return true }
            return false
        }
        let pdf = folder.appendingPathComponent("проба.pdf")
        guard makePDF(at: pdf, pages: 3), let bytes = try? Data(contentsOf: pdf) else {
            return [Check(area: area, name: name, status: .skipped, detail: "немає пробного файла")]
        }
        // Без пісні в Плані кроки з піснею пропускаємо, а прибирання файлів (8) — ні.
        let song = songs.first
        server.apply(enabled: true, port: wasPort, pin: "", state: state)
        wait(untilTrue: { server.isRunning }, seconds: 5)
        guard server.isRunning, server.port > 0 else {
            return [Check(area: area, name: name, status: .failed, detail: "слухач не піднявся: \(server.lastError ?? "—")")]
        }
        let base = "http://127.0.0.1:\(server.port)"
        func settle(_ seconds: Double = 0.5) { wait(untilTrue: { false }, seconds: seconds) }
        /// Запит так, як шле телефон: JSON або сирі байти файла.
        func call(_ path: String, body: [String: Any]? = nil, raw: Data? = nil) -> Int {
            guard let url = URL(string: base + path) else { return 0 }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            if let raw {
                request.httpBody = raw
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            } else {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body ?? [:])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var code = 0
            var finished = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { code = status; finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: 22)
            return code
        }
        /// Що зараз у залі: сторінка показу (і котра) чи текст.
        func hall() -> String {
            let picture = state.isLive && state.media.still != nil
                && state.media.screenSuppression.isDisjoint(with: [.slideTookOver, .stopped])
            if picture, state.mode == .presentation, let page = presentation.model.index {
                return "сторінка \(page - presentation.model.currentRange.lowerBound + 1)"
            }
            let text = state.lastScreenSlide.mainText
            return text.isEmpty ? "порожньо" : "текст «\(text.prefix(18))»"
        }
        /// «Оператор за компʼютером» ставить у зал пісню з Плану.
        func operatorShowsSong() {
            guard let song else { return }
            DeskModel.shared.activate(song, state: state)
            settle()
        }

        var lines: [String] = []
        var faults: [String] = []
        func expect(_ wanted: String, _ step: String) {
            let seen = hall()
            lines.append("\(step): \(seen)")
            if !seen.hasPrefix(wanted) { faults.append("\(step) — у залі \(seen), чекали «\(wanted)»") }
        }

        // 1. Телефон надсилає презентацію — вона готова, але не в залі.
        presentation.model.close()
        presentation.open([])
        let name_ = "Проба пульта.pdf"
        let sent = call("/api/upload?name=" + (name_.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name_), raw: bytes)
        uploaded.append(RemoteControlServer.uploadsFolder.appendingPathComponent(name_))
        settle()
        lines.append("файл надіслано: код \(sent), сторінок у показі \(presentation.model.count)")
        if sent != 200 || presentation.model.count != 3 { faults.append("файл не відкрився (код \(sent))") }

        if song != nil {
            // 2. Служіння: пісня з Плану в залі.
            operatorShowsSong()
            expect("текст", "оператор показав пісню")

            // 3. Старий телефон (без вкладки) — як і досі, в режимі програми.
            _ = call("/api/show")
            expect("текст", "«Показати» без вкладки (телефон до 2.5)")

            // 4. Телефон на вкладці «Показ» — презентація в зал.
            _ = call("/api/show", body: ["tab": "show"])
            settle()
            expect("сторінка 1", "«Показати» з вкладки «Показ»")

            // 5. Знову пісня; «Далі» з вкладки «Показ» повертає ту саму сторінку,
            //    наступне «Далі» гортає, «Назад» — назад.
            operatorShowsSong()
            expect("текст", "оператор знову показав пісню")
            _ = call("/api/next", body: ["tab": "show"])
            settle()
            expect("сторінка 1", "«Далі» з вкладки «Показ», презентації на стіні не було")
            _ = call("/api/next", body: ["tab": "show"])
            settle()
            expect("сторінка 2", "ще «Далі»")
            _ = call("/api/prev", body: ["tab": "show"])
            settle()
            expect("сторінка 1", "«Назад»")

            // 6. Дотик до сторінки в списку телефона — як і досі.
            operatorShowsSong()
            let lower = presentation.model.currentRange.lowerBound
            _ = call("/api/page", body: ["index": lower + 2])
            settle()
            expect("сторінка 3", "дотик до 3-ї сторінки після пісні")

            // 7. Телефон на іншій вкладці — команди, як і досі, в режимі програми.
            operatorShowsSong()
            _ = call("/api/show", body: ["tab": "song"])
            expect("текст", "«Показати» з вкладки «Пісні»")

        } else {
            lines.append("пісні в Плані немає — кроки 2–7 пропущено")
        }
        let showCheck = Check(area: area, name: name, status: !faults.isEmpty ? .failed : song == nil ? .skipped : .ok,
                              detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: "; ")))

        // 7б. Дотик у списку пульта лише вибирає (`live: false`), у зал — «Показати». Власник
        //     27.11: «показ слайдов и текстов происходить должен исключительно по кнопке показа».
        lines = []
        faults = []
        let first = presentation.model.currentRange.lowerBound
        _ = call("/api/page", body: ["index": first])
        settle()
        expect("сторінка 1", "старий пульт (без live) — одразу в зал")
        // `hall()` бачить вибрану сторінку списку, а тут вибране й показане навмисно різні —
        // тож зал звіряємо самою картинкою, що стоїть на стіні, і її підписом.
        let stillBefore = state.media.still
        let titleBefore = state.media.title
        _ = call("/api/page", body: ["index": first + 2, "live": false])
        settle()
        let untouched = stillBefore != nil && state.media.still === stillBefore && state.media.title == titleBefore
        lines.append("дотик по 3-й сторінці (live: false): у залі «\(state.media.title)»\(untouched ? ", та сама картинка" : " — ЗМІНИЛОСЯ")")
        if !untouched { faults.append("дотик (live: false) змінив зал") }
        if presentation.model.index != first + 2 { faults.append("3-ю сторінку не вибрано") }
        _ = call("/api/show", body: ["tab": "show"])
        settle()
        expect("сторінка 3", "«Показати»")
        if state.media.still === stillBefore { faults.append("«Показати» не змінило зал") }
        lines.append("у залі «\(state.media.title)»")
        let touchCheck = Check(area: area, name: "Дотик на пульті вибирає, у зал — «Показати»",
                               status: faults.isEmpty ? .ok : .failed,
                               detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: "; ")))

        // 8. Файл презентації з пульта: «⋮ → Прибрати зі списку» і «Очистити список».
        //    Власник: «документ pdf pptx и другие тоже должны иметь опции для удаления
        //    из списка». Файл не в залі — зал не чіпаємо (у ньому лишається сторінка
        //    іншого файла); файл у залі — зал бере сторінку, на якій тепер стоїть
        //    список; очищення гасить зал зі сторінкою.
        lines = []
        faults = []
        let second = "Проба пульта 2.pdf"
        let secondPath = "/api/upload?name=" + (second.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? second)
        let deckNames = { presentation.model.decks.map { $0.url.lastPathComponent }.joined(separator: " + ") }
        let sentSecond = call(secondPath, raw: bytes)
        uploaded.append(RemoteControlServer.uploadsFolder.appendingPathComponent(second))
        settle()
        lines.append("файли: \(deckNames())")
        if sentSecond != 200 || presentation.model.decks.count != 2 { faults.append("другий файл не відкрився (код \(sentSecond))") }

        _ = call("/api/page", body: ["index": 0])
        settle()
        expect("сторінка 1", "у залі сторінка першого файла")
        let quiet = call("/api/deck-remove", body: ["index": 1])
        settle()
        expect("сторінка 1", "прибрали другий файл, а в залі — перший")
        if presentation.model.decks.first?.url.lastPathComponent != name_ { faults.append("лишився не той файл: \(deckNames())") }
        lines.append("прибрали другий (\(quiet)) → \(deckNames())")
        if quiet != 200 || presentation.model.decks.count != 1 { faults.append("другий файл не прибрався (код \(quiet))") }

        _ = call(secondPath, raw: bytes)
        settle()
        _ = call("/api/page", body: ["index": 0])
        settle()
        expect("сторінка 1", "перша сторінка першого файла в залі")
        let shown = call("/api/deck-remove", body: ["index": 0])
        settle()
        expect("сторінка 1", "прибрали файл, що стояв у залі")
        lines.append("прибрали той, що в залі (\(shown)) → \(deckNames())")
        if shown != 200 || presentation.model.decks.map({ $0.url.lastPathComponent }) != [second] {
            faults.append("після «прибрати» лишилося не те: \(deckNames())")
        }

        let missing = call("/api/deck-remove", body: ["index": 99_999])
        lines.append("чужий номер → \(missing)")
        if missing != 404 { faults.append("чужий номер файла → \(missing), чекали 404") }

        let cleared = call("/api/decks-clear")
        settle()
        let dark = state.media.still == nil
        lines.append("очистити (\(cleared)): файлів \(presentation.model.decks.count), зал \(dark ? "погас" : "світить")")
        if cleared != 200 || !presentation.model.isEmpty || !dark { faults.append("очищення не спрацювало") }

        let deckCheck = Check(area: area, name: "Прибрати файл презентації з пульта", status: faults.isEmpty ? .ok : .failed,
                              detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: "; ")))
        return [showCheck, touchCheck, deckCheck]
    }
}
