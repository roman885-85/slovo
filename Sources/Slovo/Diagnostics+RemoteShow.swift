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
        var uploaded: URL?
        defer {
            server.apply(enabled: wasEnabled, port: wasPort, pin: wasPin, state: state)
            state.media.showStill(nil)
            presentation.model.close()
            presentation.open(wasDecks)
            if let uploaded { try? FileManager.default.removeItem(at: uploaded) }
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
        guard let song = songs.first, makePDF(at: pdf, pages: 3), let bytes = try? Data(contentsOf: pdf) else {
            return [Check(area: area, name: name, status: .skipped, detail: "немає пісні в Плані або пробного файла")]
        }
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
        uploaded = RemoteControlServer.uploadsFolder.appendingPathComponent(name_)
        settle()
        lines.append("файл надіслано: код \(sent), сторінок у показі \(presentation.model.count)")
        if sent != 200 || presentation.model.count != 3 { faults.append("файл не відкрився (код \(sent))") }

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

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: "; ")))]
    }
}
