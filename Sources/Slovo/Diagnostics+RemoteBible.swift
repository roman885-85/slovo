import AppKit
import SlovoCore

/// Біблія з телефона: переклади, книги, розділ із текстом, вибір місця — у
/// передпоказ і в зал — і фото з галереї.
///
/// Власник: «добавить полноценную функцию вывода текста Библии (сейчас
/// подобие функции есть, но оно не понятное и не рабочее)». Не працювала
/// вона не через телефон: книга ставилася, а номери розділів і віршів
/// бралися ще з ПОПЕРЕДНЬОЇ книги — її розділи читаються з диска у фоні.
/// Тому тут навмисно перевіряється саме цей випадок: кеш модуля скидається,
/// і адреса з телефона має влучити туди, куди просили, а не на перший вірш.
extension Diagnostics {

    static func remoteBibleSection(state: AppState) -> [Check] {
        let area = "Пульт: Біблія"
        let server = RemoteControlServer.shared
        let wasEnabled = SettingsStore.shared.settings.options.remoteEnabled ?? true
        let wasPin = SettingsStore.shared.settings.options.remotePin ?? ""
        let wasPort = SettingsStore.shared.settings.options.remotePort ?? 8103
        let wasMode = state.mode, wasLive = state.isLive
        let wasBook = state.selectedBookIndex, wasChapter = state.selectedChapterNumber
        let wasVerses = state.selectedVerseNumbers
        defer {
            server.apply(enabled: wasEnabled, port: wasPort, pin: wasPin, state: state)
            state.openScripture(bookPosition: min(wasBook, max(0, state.books.count - 1)),
                                chapter: wasChapter, verses: wasVerses)
            state.mode = wasMode
            state.isLive = wasLive
            NativeBibleBridge.shared.sync()
        }
        server.apply(enabled: true, port: wasPort, pin: "", state: state)
        wait(untilTrue: { server.isRunning }, seconds: 5)
        guard server.isRunning, server.port > 0 else {
            return [Check(area: area, name: "Канал пульта відповідає", status: .failed,
                          detail: "слухач не піднявся: \(server.lastError ?? "без пояснення")")]
        }
        let base = "http://127.0.0.1:\(server.port)"

        /// Запит тією самою дорогою, що й телефон; відповідь — JSON.
        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                  raw: Data? = nil) -> (code: Int, json: [String: Any]) {
            guard let url = URL(string: base + path) else { return (0, [:]) }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = method
            if let raw {
                request.httpBody = raw
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            } else if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var result: (Int, [String: Any]) = (0, [:])
            var finished = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                DispatchQueue.main.async { result = (code, json); finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: 22)
            return result
        }

        var checks: [Check] = []

        // 1. Книги й переклади — щоб вибирати, а не набирати.
        let listing = call("GET", "/api/bible/books")
        let books = listing.json["books"] as? [[String: Any]] ?? []
        let translations = listing.json["translations"] as? [[String: Any]] ?? []
        let testaments = Set(books.compactMap { $0["testament"] as? String })
        do {
            var faults: [String] = []
            if listing.code != 200 { faults.append("відповідь \(listing.code)") }
            if books.count != state.books.count { faults.append("книг \(books.count) замість \(state.books.count)") }
            if translations.isEmpty { faults.append("перекладів немає") }
            if !testaments.contains("old") || !testaments.contains("new") {
                faults.append("книги не поділено на заповіти: \(testaments.sorted())")
            }
            checks.append(Check(area: area, name: "Книги й переклади для телефона",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                                    + "книг \(books.count), перекладів \(translations.count), заповіти: \(testaments.sorted().joined(separator: ", "))"))
        }

        // Книга для проб — Об'явлення: остання, а отже найімовірніше не в кеші.
        guard let module = state.primaryModule,
              let target = state.books.firstIndex(where: { $0.canonicalNumber == 730 })
                ?? (state.books.isEmpty ? nil : state.books.count - 1) else {
            checks.append(Check(area: area, name: "Розділ і вибір місця", status: .skipped, detail: "перекладу немає"))
            return checks
        }
        let targetBook = state.books[target]

        // 2. Текст розділу — з незакешованої книги.
        module.releaseCache()
        let chapter = call("GET", "/api/bible/chapter?book=\(target)&chapter=3")
        let verses = chapter.json["verses"] as? [[String: Any]] ?? []
        let firstText = (verses.first?["text"] as? String) ?? ""
        checks.append(Check(area: area, name: "Розділ із текстом — і з книги, якої ще немає в пам'яті",
                            status: chapter.code == 200 && !verses.isEmpty && !firstText.isEmpty ? .ok : .failed,
                            detail: "\(targetBook.fullName) 3: відповідь \(chapter.code), віршів \(verses.count), "
                                + "перший: «\(firstText.prefix(40))»"))

        // 3. Вибір із телефона: спершу передпоказ, потім зал — і саме туди.
        module.releaseCache()
        state.isLive = false
        state.mode = .songs
        let preview = call("POST", "/api/bible-select", ["book": target, "chapter": 21, "verses": [1, 2], "live": false])
        wait(untilTrue: { state.selectedChapterNumber == 21 && state.selectedVerseNumbers == [1, 2] }, seconds: 6)
        let previewOK = preview.code == 200 && state.mode == .bible
            && state.selectedBookIndex == target && state.selectedChapterNumber == 21
            && state.selectedVerseNumbers == [1, 2] && !state.isLive
        let live = call("POST", "/api/bible-select", ["book": target, "chapter": 21, "verses": [4], "live": true])
        wait(untilTrue: { state.isLive && state.selectedVerseNumbers == [4] }, seconds: 6)
        let liveOK = live.code == 200 && state.isLive && state.selectedVerseNumbers == [4]
            && state.liveSlide.reference.contains("21")
        checks.append(Check(area: area, name: "Вибір місця з телефона: передпоказ і зал",
                            status: previewOK && liveOK ? .ok : .failed,
                            detail: "передпоказ: \(previewOK ? "так" : "ні") (розділ \(state.selectedChapterNumber)); "
                                + "зал: \(liveOK ? "так" : "ні"), у залі «\(state.liveSlide.reference)»"))

        // 4. Адреса руками — тепер туди, куди просили, навіть з холодною книгою.
        module.releaseCache()
        state.isLive = false
        let short = targetBook.shortNames.first ?? targetBook.fullName
        let typed = call("POST", "/api/goto", ["text": "\(short) 3:20"])
        wait(untilTrue: { state.isLive && state.selectedChapterNumber == 3 && state.selectedVerseNumbers == [20] },
             seconds: 6)
        let gotoOK = typed.code == 200 && state.selectedBookIndex == target
            && state.selectedChapterNumber == 3 && state.selectedVerseNumbers == [20] && state.isLive
        checks.append(Check(area: area, name: "Адреса з телефона влучає і в книгу, ще не прочитану з диска",
                            status: gotoOK ? .ok : .failed,
                            detail: "«\(short) 3:20» → розділ \(state.selectedChapterNumber), вірші \(state.selectedVerseNumbers), "
                                + "у залі «\(state.liveSlide.reference)»"))

        // 5. Фото з галереї: відповідь несе номер сторінки — телефон
        // показує перше надіслане, а не останнє.
        if let png = makePicture(width: 320, height: 200).flatMap({ image -> Data? in
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .png, properties: [:])
        }) {
            let pictures = NativeShowWorkspace.pictures.model
            let before = pictures.count
            let sent = call("POST", "/api/upload?name=slovo-перевірка.png", raw: png)
            let page = (sent.json["page"] as? NSNumber)?.intValue ?? -2
            let ok = sent.code == 200 && page == before && pictures.count == before + 1
            checks.append(Check(area: area, name: "Фото з телефона: номер сторінки у відповіді",
                                status: ok ? .ok : .failed,
                                detail: "відповідь \(sent.code), сторінка \(page), було \(before), стало \(pictures.count)"))
            // Прибрати пробу зі списку й з пам'яті людини.
            if pictures.count > before { NativeShowWorkspace.pictures.removePageForCheck(at: before) }
            try? FileManager.default.removeItem(at: RemoteControlServer.uploadsFolder
                .appendingPathComponent("slovo-перевірка.png"))
        }
        return checks
    }
}
