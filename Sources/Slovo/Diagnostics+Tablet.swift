import AppKit
import SlovoCore

/// Пульт для планшета: кожен новий маршрут сервера — тією самою дорогою, що
/// й планшет, і з наслідком у програмі, а не лише з відповіддю 200.
///
/// Власник: «далее сделать пульт для планшета, где будет полный функционал
/// программы». Планшет бачить списки програми, набирає текст, веде План,
/// шукає за словами і показує, що зараз на стіні.
extension Diagnostics {

    static func tabletSection(state: AppState) -> [Check] {
        let area = "Пульт: планшет"
        let server = RemoteControlServer.shared
        let options = SettingsStore.shared.settings.options
        let wasEnabled = options.remoteEnabled ?? true
        let wasPin = options.remotePin ?? ""
        let wasPort = options.remotePort ?? 8103
        let desk = DeskModel.shared
        let text = TextModuleModel.shared
        let media = state.media
        let wasMode = state.mode, wasLive = state.isLive
        let wasSlide = state.slide, wasLiveSlide = state.liveSlide
        let wasBook = state.selectedBookIndex, wasChapter = state.selectedChapterNumber
        let wasVerses = state.selectedVerseNumbers
        let wasDocument = text.document
        let wasVolume = media.volume
        let wasPlan = desk.plan
        defer {
            server.apply(enabled: wasEnabled, port: wasPort, pin: wasPin, state: state)
            server.applyWeb(enabled: options.remoteWebEnabled ?? true, port: options.remoteWebPort ?? 8105,
                            password: options.remoteWebPassword ?? "", name: options.remoteWebName ?? "slovo",
                            viewOnly: options.remoteWebViewOnly ?? false, noPort: options.remoteWebNoPort ?? true)
            text.document = wasDocument
            text.savesToSettings = true
            media.volume = wasVolume
            // Перевірка плану проповіді могла лишити план служіння відкладеним.
            if desk.isSermon { desk.endSermon() }
            desk.plan = wasPlan
            state.mode = wasMode
            state.openScripture(bookPosition: min(wasBook, max(0, state.books.count - 1)),
                                chapter: wasChapter, verses: wasVerses)
            state.present(wasLiveSlide, live: true)
            state.present(wasSlide, live: false)
            state.isLive = wasLive
            NativeBibleBridge.shared.sync()
        }
        // Набраний на планшеті текст не має лягати в пам'ять модуля «Текст».
        text.savesToSettings = false
        server.apply(enabled: true, port: wasPort, pin: "", state: state)
        wait(untilTrue: { server.isRunning }, seconds: 5)
        guard server.isRunning, server.port > 0 else {
            return [Check(area: area, name: "Канал пульта відповідає", status: .failed,
                          detail: "слухач не піднявся: \(server.lastError ?? "без пояснення")")]
        }
        let base = "http://127.0.0.1:\(server.port)"

        /// Запит тією самою дорогою, що й планшет.
        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (code: Int, data: Data) {
            guard let url = URL(string: base + path) else { return (0, Data()) }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = method
            if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var result: (Int, Data) = (0, Data())
            var finished = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { result = (code, data ?? Data()); finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: 22)
            return result
        }
        func json(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> (code: Int, json: [String: Any]) {
            let answer = call(method, path, body)
            return (answer.code, (try? JSONSerialization.jsonObject(with: answer.data)) as? [String: Any] ?? [:])
        }
        func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

        var checks: [Check] = []

        // 1. Списки — стільки ж, скільки в програмі.
        do {
            let songBooks = json("GET", "/api/songs/books")
            let songs = json("GET", "/api/songs/list")
            let player = json("GET", "/api/media")
            let pictures = json("GET", "/api/pictures")
            let history = json("GET", "/api/history")
            let screen = json("GET", "/api/screen")
            let libraryBooks = state.songLibrary?.books.count ?? 0
            let bookSongs = NativeSongsWorkspace.shared.model.book?.songs.count ?? 0
            let pictureCount = NativeShowWorkspace.pictures.model.count
            var faults: [String] = []
            if songBooks.code != 200 || rows(songBooks.json["books"]).count != libraryBooks {
                faults.append("пісенників \(rows(songBooks.json["books"]).count) із \(libraryBooks) (\(songBooks.code))")
            }
            if songs.code != 200 || rows(songs.json["songs"]).count != bookSongs {
                faults.append("пісень \(rows(songs.json["songs"]).count) із \(bookSongs) (\(songs.code))")
            }
            if player.code != 200 || rows(player.json["playlist"]).count != media.playlist.count {
                faults.append("файлів плеєра \(rows(player.json["playlist"]).count) із \(media.playlist.count)")
            }
            if pictures.code != 200 || rows(pictures.json["pages"]).count != pictureCount {
                faults.append("картинок \(rows(pictures.json["pages"]).count) із \(pictureCount)")
            }
            if history.code != 200 || rows(history.json["records"]).count != desk.history.count {
                faults.append("Історії \(rows(history.json["records"]).count) із \(desk.history.count)")
            }
            if screen.code != 200 || screen.json["sources"] == nil { faults.append("екран: відповідь \(screen.code)") }
            // Відкритий пісенник — своєю назвою, а не іменем файла.
            let openTitle = NativeSongsWorkspace.shared.model.book?.title ?? ""
            let current = rows(songBooks.json["books"]).first { ($0["id"] as? String) == state.songBookID }
            if !openTitle.isEmpty, (current?["title"] as? String) != openTitle {
                faults.append("відкритий пісенник зветься «\(current?["title"] as? String ?? "")» замість «\(openTitle)»")
            }
            checks.append(Check(area: area, name: "Списки для планшета — ті самі, що в програмі",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty
                                    ? "пісенників \(libraryBooks), пісень \(bookSongs), файлів \(media.playlist.count), "
                                        + "картинок \(pictureCount), Історії \(desk.history.count)"
                                    : faults.joined(separator: "; ")))
        }

        // 2. Текст із планшета — у передпоказ, потім у зал; і картинка залу.
        do {
            let typed = "Перевірка планшета\nДругий рядок"
            let set = json("POST", "/api/text-set", ["text": typed, "title": "планшет"])
            let back = json("GET", "/api/text")
            let shown = json("POST", "/api/text-show")
            wait(untilTrue: { state.isLive && state.liveSlide.mainText.contains("Перевірка планшета") }, seconds: 3)
            let hall = (json("GET", "/api/state").json["hall"] as? [String: Any])?["kind"] as? String ?? ""
            let picture = call("GET", "/api/hall.jpg?w=480")
            let isJPEG = picture.data.starts(with: [0xFF, 0xD8])
            var faults: [String] = []
            if set.code != 200 { faults.append("text-set \(set.code)") }
            if (back.json["body"] as? String) != typed { faults.append("текст не дійшов до модуля") }
            if shown.code != 200 || state.mode != .text || !state.liveSlide.mainText.contains("Перевірка планшета") {
                faults.append("у залі «\(state.liveSlide.mainText.prefix(30))», режим \(state.mode.rawValue)")
            }
            if hall != "text" { faults.append("зал у стані — «\(hall)»") }
            if picture.code != 200 || !isJPEG { faults.append("картинка залу: \(picture.code), \(picture.data.count) байт") }
            checks.append(Check(area: area, name: "Текст із планшета йде в зал, і планшет бачить зал",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty
                                    ? "у залі набраний текст, картинка залу \(picture.data.count) байт"
                                    : faults.joined(separator: "; ")))
        }

        // 3. План: додати поточне місце і прибрати його.
        do {
            state.mode = .bible
            let before = desk.plan.count
            let added = json("POST", "/api/plan-add")
            let afterAdd = desk.plan.count
            let removed = json("POST", "/api/plan-remove", ["index": max(0, afterAdd - 1)])
            let ok = added.code == 200 && afterAdd == before + 1 && removed.code == 200 && desk.plan.count == before
            checks.append(Check(area: area, name: "План із планшета: додати й прибрати",
                                status: ok ? .ok : .failed,
                                detail: "було \(before), після додавання \(afterAdd), після прибирання \(desk.plan.count)"))
        }

        // 4. Пошук за словами і вибір знайденого. Слово беремо з тексту
        // відкритого розділу — так проверка не залежить від мови модуля.
        do {
            let chapter = json("GET", "/api/bible/chapter")
            let verses = rows(chapter.json["verses"])
            let word = verses.lazy.compactMap { $0["text"] as? String }
                .flatMap { $0.split(whereSeparator: { !$0.isLetter }) }
                .first { $0.count >= 5 }.map(String.init)
            if let word {
                let asked = json("POST", "/api/bible-search", ["text": word])
                wait(untilTrue: { !desk.isSearching && !desk.hits.isEmpty }, seconds: 20)
                let found = rows(json("GET", "/api/search").json["hits"])
                var ok = asked.code == 200 && !found.isEmpty
                var detail = "«\(word)»: знайдено \(found.count)"
                if ok, let first = desk.hits.first {
                    let picked = json("POST", "/api/search-hit", ["index": 0])
                    ok = picked.code == 200 && state.selectedChapterNumber == first.chapter
                        && state.selectedVerseNumbers == [first.verse]
                    detail += "; вибрано \(first.bookName) \(first.chapter):\(first.verse) → розділ "
                        + "\(state.selectedChapterNumber), вірші \(state.selectedVerseNumbers)"
                }
                checks.append(Check(area: area, name: "Пошук за словами з планшета",
                                    status: ok ? .ok : .failed, detail: detail))
            } else {
                checks.append(Check(area: area, name: "Пошук за словами з планшета", status: .skipped,
                                    detail: "у розділі не знайшлося слова для пошуку"))
            }
        }

        // 5. «Чорний екран», потім «Показати» на вкладці картинок: зал мусить
        // повернути картинку. Раніше затемнення знімалось лише на Біблії й
        // піснях, і з пульта чорний зал на вкладках показу було не зняти.
        if let png = makePicture(width: 320, height: 200).flatMap({ image -> Data? in
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }) {
            let pictures = NativeShowWorkspace.pictures.model
            let before = pictures.count
            let name = "slovo-планшет.png"
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            var sent = (code: 0, data: Data())
            if let url = URL(string: base + "/api/upload?name=\(encoded)&show=1") {
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.httpBody = png
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                var finished = false
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async { sent = (code, data ?? Data()); finished = true }
                }.resume()
                wait(untilTrue: { finished }, seconds: 22)
            }
            let blacked = json("POST", "/api/black")
            let wasBlack = state.isBlackedOut
            let shown = json("POST", "/api/show")
            wait(untilTrue: { !state.isBlackedOut }, seconds: 3)
            let hall = (json("GET", "/api/state").json["hall"] as? [String: Any])?["kind"] as? String ?? ""
            let ok = sent.code == 200 && blacked.code == 200 && wasBlack && shown.code == 200
                && !state.isBlackedOut && state.mode == .pictures && hall == "still"
            checks.append(Check(area: area, name: "«Показати» після «Чорного» повертає картинку",
                                status: ok ? .ok : .failed,
                                detail: "фото \(sent.code), затемнено \(wasBlack ? "так" : "ні"), після «Показати» — "
                                    + "затемнення \(state.isBlackedOut ? "лишилося" : "знято"), вкладка \(state.mode.rawValue), "
                                    + "у залі «\(hall)»"))
            if pictures.count > before { NativeShowWorkspace.pictures.removePageForCheck(at: before) }
            try? FileManager.default.removeItem(at: RemoteControlServer.uploadsFolder.appendingPathComponent(name))
        }

        // 6. Гучність плеєра і незнана команда.
        do {
            let volume = json("POST", "/api/media-volume", ["x": 0.4])
            let unknown = json("POST", "/api/такої-немає")
            let ok = volume.code == 200 && abs(media.volume - 0.4) < 0.001 && unknown.code == 404
            checks.append(Check(area: area, name: "Гучність із планшета і відмова на чужу команду",
                                status: ok ? .ok : .failed,
                                detail: "гучність \(volume.code) → \(media.volume); чужа команда → \(unknown.code)"))
        }
        // 7. Пульт у браузері — свій порт і свій пароль. Власник: «взять
        // нестандартный порт… вход с паролем или без». Сторінка відкривається
        // й із паролем (його вона спитає сама), канал без пароля відповідає
        // «pin», з паролем — пускає; на порту телефона сторінки немає.
        let webPort = options.remoteWebPort ?? 8105
        let webName = options.remoteWebName ?? "slovo"
        func webCall(_ method: String, _ path: String, password: String = "",
                     body: [String: Any]? = nil) -> (code: Int, data: Data) {
            let port = server.webPort > 0 ? server.webPort : webPort
            guard let url = URL(string: "http://127.0.0.1:\(port)" + path) else { return (0, Data()) }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = method
            if !password.isEmpty { request.setValue(password, forHTTPHeaderField: "X-Slovo-Pin") }
            if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            var result: (Int, Data) = (0, Data())
            var finished = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { result = (code, data ?? Data()); finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: 12)
            return result
        }
        do {
            server.applyWeb(enabled: true, port: webPort, password: "4321", name: webName, viewOnly: false)
            wait(untilTrue: { server.webRunning }, seconds: 5)
            let page = webCall("GET", "/")
            let html = String(data: page.data, encoding: .utf8) ?? ""
            let locked = webCall("GET", "/api/state")
            let opened = webCall("GET", "/api/state", password: "4321")
            let phonePage = call("GET", "/")
            let ok = server.webRunning && page.code == 200 && html.contains("Слово — пульт у браузері")
                && locked.code == 401 && opened.code == 200 && phonePage.code == 404
            checks.append(Check(area: area, name: "Пульт у браузері: свій порт і пароль",
                                status: ok ? .ok : .failed,
                                detail: server.webRunning
                                    ? "порт \(server.webPort): сторінка \(page.code), без пароля → \(locked.code), "
                                        + "з паролем → \(opened.code); на порту телефона сторінка → \(phonePage.code)"
                                    : "сторінка не піднялася: \(server.webError ?? "без пояснення")"))
        }

        // 8. Вхід за ім'ям. Власник: «вход по имени, для удобства» і «с
        // любого устройства». Програма сама оголошує slovo.local (друге
        // «Слово» в мережі — slovo-2.local), і сторінка відкривається за ним
        // тим самим шляхом, що в браузері планшета: ім'я → mDNS → адреса.
        do {
            server.applyWeb(enabled: true, port: webPort, password: "", name: webName, viewOnly: false)
            wait(untilTrue: { server.webRunning && RemoteName.shared.name != nil }, seconds: 8)
            let name = RemoteName.shared.name
            var faults: [String] = []
            var detail = ""
            if let name, let url = URL(string: RemoteWebAddress.link(host: name)) {
                var answer: (code: Int, bytes: Int, html: String) = (0, 0, "")
                var finished = false
                URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { data, response, _ in
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    DispatchQueue.main.async { answer = (code, data?.count ?? 0, html); finished = true }
                }.resume()
                wait(untilTrue: { finished }, seconds: 12)
                if answer.code != 200 || !answer.html.contains("Слово — пульт у браузері") {
                    faults.append("за \(url.absoluteString) відповідь \(answer.code)")
                }
                detail = "\(url.absoluteString) → \(RemoteName.shared.addresses.joined(separator: ", ")), "
                    + "сторінка \(answer.code), \(answer.bytes) байт"
            } else {
                faults.append("ім'я не оголошено за 8 с")
                detail = "адреси: \(RemoteName.interfaces().map(\.text).joined(separator: ", "))"
            }
            checks.append(Check(area: area, name: "Вхід за ім'ям: \(webName).local",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty ? detail : faults.joined(separator: "; ") + ". " + detail))
        }

        // 9. Вікно «Пульт у браузері»: крупно — адреса за ім'ям, QR-код
        // читається назад у ту саму адресу цифрами, яку відкриє камера
        // планшета. Знімок вікна — у Logs, щоб його можна було побачити.
        do {
            let view = NativeBrowserRemoteView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.refresh()
            view.layoutSubtreeIfNeeded()
            NativeTrace.snapshot(view, to: "slovo-browser-remote.png")
            let shown = view.shown
            var decoded = ""
            if let image = shown.code, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil) {
                decoded = (detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString ?? ""
            }
            let numeric = RemoteWebAddress.numeric ?? ""
            let main = RemoteWebAddress.named ?? numeric
            let ok = !numeric.isEmpty && decoded == numeric && shown.name == main && shown.number == numeric
            checks.append(Check(area: area, name: "Вікно «Пульт у браузері»: адреса й QR-код",
                                status: ok ? .ok : .failed,
                                detail: "крупно «\(shown.name)», цифрами «\(shown.number)», QR читається як «\(decoded)»; "
                                    + shown.status.replacingOccurrences(of: "\n", with: " ")))
        }
        // 10. «Лише перегляд»: сторінка бачить зал, але будь-яка команда —
        // відмова; телефон при цьому керує, як і керував.
        do {
            server.applyWeb(enabled: true, port: webPort, password: "", name: webName, viewOnly: true)
            wait(untilTrue: { server.webRunning }, seconds: 5)
            let refused = webCall("POST", "/api/hide", body: [:])
            let seen = (try? JSONSerialization.jsonObject(with: webCall("GET", "/api/state").data)) as? [String: Any] ?? [:]
            let phone = call("GET", "/api/state")
            let ok = refused.code == 403 && (seen["viewOnly"] as? Bool) == true && phone.code == 200
            checks.append(Check(area: area, name: "«Лише перегляд»: зал видно, керувати не можна",
                                status: ok ? .ok : .failed,
                                detail: "команда → \(refused.code), позначка viewOnly: \(seen["viewOnly"] as? Bool ?? false), "
                                    + "телефон → \(phone.code)"))
        }

        // 11. Програми для Android — зі сторінки, навіть коли заданий пароль:
        // це лише інсталятор, а браузер телефона пароля ще не знає.
        do {
            server.applyWeb(enabled: true, port: webPort, password: "4321", name: webName, viewOnly: false)
            wait(untilTrue: { server.webRunning }, seconds: 5)
            let listing = (try? JSONSerialization.jsonObject(with: webCall("GET", "/api/apps").data)) as? [String: Any]
            let apps = listing?["apps"] as? [[String: Any]] ?? []
            var faults: [String] = []
            if apps.count != 2 { faults.append("програм \(apps.count) із 2") }
            for app in apps {
                let id = app["id"] as? String ?? ""
                let file = webCall("GET", "/download/\(id).apk")
                let size = (app["size"] as? NSNumber)?.intValue ?? -1
                if file.code != 200 || !file.data.starts(with: [0x50, 0x4B]) || file.data.count != size {
                    faults.append("\(id): відповідь \(file.code), \(file.data.count) байт із \(size)")
                }
            }
            let names = apps.map { "\($0["title"] as? String ?? "") \($0["version"] as? String ?? "") (Android \($0["minAndroid"] as? String ?? "?")+)" }
            checks.append(Check(area: area, name: "Програми для Android: список і завантаження",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty ? names.joined(separator: "; ") : faults.joined(separator: "; ")))
        }

        // 13. Встановлення за QR-кодом. Власник: «добавить функцию установки
        // программ для андроид по qr коду». У вікні «Програми для Android» код
        // кожної програми читається в адресу завантаження, і за нею справді
        // приходить установочний файл — те, що побачить камера телефона.
        do {
            server.applyWeb(enabled: true, port: webPort, password: "", name: webName, viewOnly: false)
            wait(untilTrue: { server.webRunning }, seconds: 5)
            let view = NativeAndroidAppsView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.refresh()
            view.layoutSubtreeIfNeeded()
            NativeTrace.snapshot(view, to: "slovo-android-apps.png")
            var faults: [String] = []
            var seen: [String] = []
            for card in view.shown {
                var decoded = ""
                if let image = card.code, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil) {
                    decoded = (detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString ?? ""
                }
                guard let link = card.link, decoded == link, let url = URL(string: decoded) else {
                    faults.append("\(card.id): код «\(decoded)», чекали «\(card.link ?? "—")»")
                    continue
                }
                var answer: (code: Int, data: Data) = (0, Data())
                var finished = false
                URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { data, response, _ in
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    DispatchQueue.main.async { answer = (code, data ?? Data()); finished = true }
                }.resume()
                wait(untilTrue: { finished }, seconds: 12)
                if answer.code != 200 || !answer.data.starts(with: [0x50, 0x4B]) {
                    faults.append("\(card.id): за кодом відповідь \(answer.code)")
                }
                seen.append("\(card.id) → \(decoded) (\(answer.data.count) байт)")
            }
            if view.shown.isEmpty { faults.append("програм у вікні немає") }
            checks.append(Check(area: area, name: "Встановлення за QR-кодом: код веде до файла",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty ? seen.joined(separator: "; ") : faults.joined(separator: "; ")))
        }

        // 14. Вкладка «Remote API» — нічого не сховано за краєм. Власник про
        // інше вікно: «если не знать что они там есть … часть функционала
        // теряется — это недопустимо». Вкладка будується шириною вікна
        // параметрів, і жоден підпис не має вилазити за край своєї групи.
        // Знімок — усієї вкладки, а не лише видимого верху.
        do {
            let tab = NativeSettingsRemoteTab(state: state, store: SettingsStore.shared)
            let page = tab.page
            // Та сама підставка, що й у знімків інших вкладок: без вікна з
            // тлом підписи на знімку виходили невидимими — чорне по чорному.
            // Підкладка, що сама заливає свої межі: прозорий вид знімок
            // пише чорним, і темні підписи на ньому зникають.
            let paper = PaperView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
            paper.addSubview(page)
            page.frame = paper.bounds
            let stand = bench(for: paper, size: NSSize(width: 880, height: 640))
            defer { stand.orderOut(nil) }
            page.layoutSubtreeIfNeeded()
            let full = (page as? NativeForm.Page)?.bodyHeight ?? page.fittingSize.height
            stand.setContentSize(NSSize(width: 880, height: full))
            paper.frame = NSRect(x: 0, y: 0, width: 880, height: full)
            page.frame = paper.bounds
            page.layoutSubtreeIfNeeded()
            stand.displayIfNeeded()
            let body = (page.subviews.first as? NSScrollView)?.documentView ?? page
            body.layoutSubtreeIfNeeded()
            _ = snapshot(paper, to: "slovo-remote-api.png")
            var clipped: [String] = []
            func visit(_ view: NSView, group: NSView?) {
                // Рядки таблиць (список веб-сторінок) скорочуються трьома
                // крапками навмисно — повністю їх видно при виборі.
                if view is NSTableView { return }
                let owner = view is NativeForm.Group ? view : group
                if let label = view as? NSTextField, !label.isEditable, !label.stringValue.isEmpty,
                   let owner, !label.isHidden {
                    let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.preferredMaxLayoutWidth > 0
                        ? label.preferredMaxLayoutWidth : 10_000, height: 10_000)).width ?? label.intrinsicContentSize.width
                    let frame = label.convert(label.bounds, to: owner)
                    let right = owner.bounds.width - 4
                    if frame.maxX > right + 1 || needed > frame.width + 2 {
                        clipped.append("«\(label.stringValue.prefix(40))»")
                    }
                }
                for child in view.subviews { visit(child, group: owner) }
            }
            visit(body, group: nil)
            checks.append(Check(area: area, name: "Вкладка «Remote API»: нічого не обрізано",
                                status: clipped.isEmpty ? .ok : .failed,
                                detail: clipped.isEmpty
                                    ? "усі підписи в межах груп при ширині 880; висота вкладки \(Int(full)); знімок — ~/Library/Logs/slovo-remote-api.png"
                                    : "обрізано: " + clipped.joined(separator: ", ")))
        }

        // 15. За ім'ям — без номера порту. Власник: «нужно, чтобы веб версия
        // по имени открывалась без указания порта». Сторінка відповідає й на
        // порту 80; зайнятий він на цій машині — це не поломка, а стан, і
        // перевірка тоді лише попереджає.
        do {
            server.applyWeb(enabled: true, port: webPort, password: "", name: webName, viewOnly: false, noPort: true)
            wait(untilTrue: { server.webRunning }, seconds: 5)
            wait(untilTrue: { server.plainReady || server.plainError != nil }, seconds: 3)
            if server.plainReady, let url = URL(string: "http://127.0.0.1/") {
                var answer: (code: Int, html: String) = (0, "")
                var finished = false
                URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { data, response, _ in
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    DispatchQueue.main.async { answer = (code, html); finished = true }
                }.resume()
                wait(untilTrue: { finished }, seconds: 12)
                let link = RemoteWebAddress.named ?? RemoteWebAddress.numeric ?? ""
                let ok = answer.code == 200 && answer.html.contains("Слово — пульт у браузері") && !link.contains(":\(server.webPort)")
                checks.append(Check(area: area, name: "За ім'ям — без номера порту",
                                    status: ok ? .ok : .failed,
                                    detail: "порт 80 → \(answer.code); посилання «\(link)»"))
            } else {
                checks.append(Check(area: area, name: "За ім'ям — без номера порту", status: .warning,
                                    detail: "порт 80 на цій машині зайнятий — адреса з номером \(server.webPort): \(server.plainError ?? "без пояснення")"))
            }
        }

        // 16. Пульт на зв'язку — програма не дрімає й комп'ютер не засинає.
        // Власник: «андроид программа постоянно теряет связь». Після запиту
        // програма тримає «не засинати» — його видно в `pmset -g assertions`.
        do {
            _ = call("GET", "/api/state?since=-1")
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["-g", "assertions"]
            let pipe = Pipe()
            pmset.standardOutput = pipe
            try? pmset.run()
            pmset.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Назву діяльності pmset не показує (named: ""), тож шукаємо сам
            // запрет сну від цього процесу — за його номером.
            let pid = ProcessInfo.processInfo.processIdentifier
            let seen = text.split(separator: "\n").contains {
                $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep")
            }
            let wake = RemoteWakefulness.shared
            let ok = wake.keepsAwake && wake.noNapHeld && seen
            checks.append(Check(area: area, name: "Пульт на зв'язку: без App Nap і без сну",
                                status: ok ? .ok : .failed,
                                detail: "App Nap вимкнено: \(wake.noNapHeld ? "так" : "ні"); не засинати: \(wake.keepsAwake ? "так" : "ні"); "
                                    + "у pmset: \(seen ? "є PreventUserIdleSystemSleep від цього процесу" : "немає")"))
        }

        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }
        /// Тіло запиту — сирими байтами, як планшет шле файл.
        func send(_ path: String, _ bytes: Data) -> (code: Int, json: [String: Any]) {
            guard let url = URL(string: base + path) else { return (0, [:]) }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = bytes
            var result: (Int, Data) = (0, Data())
            var finished = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { result = (code, data ?? Data()); finished = true }
            }.resume()
            wait(untilTrue: { finished }, seconds: 22)
            return (result.0, (try? JSONSerialization.jsonObject(with: result.1)) as? [String: Any] ?? [:])
        }

        // 17. Бібліотека для плану проповіді: планшет забирає переклади рядками й
        // пісенники файлами, щоб складати план без зв'язку з програмою.
        do {
            let library = json("GET", "/api/library")
            let bibles = rows(library.json["bibles"])
            let songbooks = rows(library.json["songbooks"])
            var faults: [String] = []
            if library.code != 200 || bibles.count != state.allModules.count {
                faults.append("перекладів \(bibles.count) із \(state.allModules.count) (\(library.code))")
            }
            if songbooks.count != (state.songLibrary?.books.count ?? 0) {
                faults.append("пісенників \(songbooks.count) із \(state.songLibrary?.books.count ?? 0)")
            }
            var detail = "перекладів \(bibles.count), пісенників \(songbooks.count)"
            if let primary = state.primaryModule {
                let export = call("GET", "/api/library/bible?id=" + encoded(primary.identifier))
                let text = String(decoding: export.data, as: UTF8.self)
                let books = text.components(separatedBy: "\nB\t").count - 1
                let verses = text.components(separatedBy: "\nV\t").count - 1
                if export.code != 200 || !text.hasPrefix("SLOVO-BIBLE") || books != primary.books.count || verses == 0 {
                    faults.append("переклад «\(primary.identifier)»: \(export.code), книг \(books) із \(primary.books.count), віршів \(verses)")
                }
                detail += "; «\(primary.identifier)» рядками: книг \(books), віршів \(verses)"
            }
            if let file = songbooks.first(where: { ($0["format"] as? String) == "vbm" })?["file"] as? String {
                let book = call("GET", "/api/library/songbook?file=" + encoded(file))
                if book.code != 200 || book.data.prefix(16) != Data("VisioBibleModule".utf8) {
                    faults.append("пісенник «\(file)»: \(book.code), \(book.data.count) байт")
                }
                detail += "; пісенник «\(file)» файлом: \(book.data.count) байт"
            }
            checks.append(Check(area: area, name: "Бібліотека для плану проповіді",
                                status: faults.isEmpty ? .ok : .failed,
                                detail: faults.isEmpty ? detail : faults.joined(separator: "; ")))
        }

        // 18. План проповіді. Власник: «план проповедника не добавляется в конец
        // существующего или не заменяет его, а становится просто приоритетным на
        // время проповеди». Файл плану — лише зберегти; план — головний; після
        // `sermon-end` — той самий план служіння.
        do {
            let name = "slovo-проба-план.png"
            let stored = RemoteControlServer.uploadsFolder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: stored) }
            let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .representation(using: .png, properties: [:]) ?? Data()
            let upload = send("/api/upload?store=1&name=" + encoded(name), pixel)
            let saved = FileManager.default.fileExists(atPath: stored.path)
            let before = desk.plan.items.map(\.id)
            let canon = state.primaryModule?.books.first?.canonicalNumber ?? 10
            let answer = json("POST", "/api/sermon-plan", [
                "title": "Проба плану проповіді",
                "items": [
                    ["type": "scripture", "title": "уривок", "module": state.primaryModuleID, "canon": canon,
                     "chapter": 1, "verses": [1], "text": "з планшета"],
                    ["type": "text", "title": "оголошення", "heading": "Оголошення", "body": "Проба"],
                    ["type": "file", "title": "слайд", "file": (upload.json["file"] as? String) ?? name],
                    ["type": "song", "title": "пісня", "songBook": "немає-такого.vbm", "song": 0,
                     "parts": [["kind": "Куплет", "text": "рядок"]]],
                ] as [[String: Any]],
            ])
            let kinds = desk.plan.items.map(\.kind.rawValue)
            let flag = json("GET", "/api/state").json["sermon"] as? [String: Any]
            let wasSermon = desk.isSermon
            let ended = json("POST", "/api/sermon-end", [:])
            let after = desk.plan.items.map(\.id)
            let fine = upload.code == 200 && saved && answer.code == 200
                && kinds == ["scripture", "text", "file", "text"]
                && (flag?["on"] as? Bool) == true && wasSermon
                && ended.code == 200 && !desk.isSermon && after == before
            checks.append(Check(area: area, name: "План проповіді: головний на час проповіді",
                                status: fine ? .ok : .failed,
                                detail: "файл → \(upload.code) (\(saved ? "лежить у теці пульта" : "не збережено")); "
                                    + "план → \(answer.code), пункти: \(kinds.joined(separator: ", ")); "
                                    + "у стані проповідь: \((flag?["on"] as? Bool) == true ? "так" : "ні"); "
                                    + "після повернення план служіння \(after == before ? "той самий (\(after.count))" : "інший")"))
        }

        // 12. Вимкнули пульт у браузері — порт закритий зовсім, ім'я знято.
        do {
            server.applyWeb(enabled: false, port: webPort, password: "", name: webName, viewOnly: false)
            wait(untilTrue: { !server.webRunning }, seconds: 3)
            let closed = webCall("GET", "/")
            let ok = !server.webRunning && closed.code == 0 && RemoteName.shared.name == nil
            checks.append(Check(area: area, name: "Вимкнений пульт у браузері: порт закритий",
                                status: ok ? .ok : .failed,
                                detail: "сторінка → \(closed.code == 0 ? "немає з'єднання" : "\(closed.code)"), "
                                    + "ім'я: \(RemoteName.shared.name ?? "знято")"))
        }
        return checks
    }
}

/// Підкладка для знімків: заливає свої межі кольором вікна (правило
/// `bounds.fill()` — без нього прозорий вид на знімку чорний).
private final class PaperView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
