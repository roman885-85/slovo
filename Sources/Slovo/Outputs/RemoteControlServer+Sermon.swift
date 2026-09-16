import Foundation
import Network
import SlovoCore

/// План проповіді з планшета й бібліотека для нього.
///
/// Власник: «проповедник заранее выбирает стихи из писания, которые он будет
/// использовать, презентацию или другой материал. Затем прийдя на служение
/// подключается, и когда выходит за кафедру нажимает кнопку загрузки плана
/// проповеди и весь план уже в основной программе».
///
/// План складають удома, без зв'язку з програмою, тож планшету потрібні свої
/// переклади й пісенники — їх він бере тут, поки підключений
/// (`/api/library…`). На служінні файли плану приходять через
/// `upload?store=1`, а слідом одна команда `sermon-plan` кладе пункти в
/// кінець Плану програми.
extension RemoteControlServer {

    // MARK: - Бібліотека

    /// GET-запити бібліотеки. `true` — запит наш і відповідь пішла.
    func libraryGET(_ request: Request, state: AppState, on connection: NWConnection) -> Bool {
        switch request.path {
        case "/api/library":
            respond(connection, 200, libraryJSON(state: state))
        case "/api/library/bible":
            sendBible(request.query["id"] ?? "", state: state, on: connection)
        case "/api/library/songbook":
            sendSongBook(request.query["file"] ?? "", state: state, on: connection)
        default:
            return false
        }
        return true
    }

    /// Що можна забрати на планшет. У пісенника — розширення файла: планшет
    /// сам розбирає лише `.vbm`, інші він пропустить.
    private func libraryJSON(state: AppState) -> [String: Any] {
        [
            "bibles": state.allModules.map { module -> [String: Any] in
                ["id": module.identifier, "name": module.displayName,
                 "short": module.info.shortName, "books": module.books.count]
            },
            // Свій `.songbook` планшет не читає — йому збірник іде як `.vbm`,
            // зібраний на льоту; тому і ім'я, і формат називаємо йому `.vbm`.
            "songbooks": (state.songLibrary?.books ?? []).map { entry -> [String: Any] in
                let own = SongBookJSON.isSongBookFile(entry.url)
                return ["file": own ? entry.id + ".vbm" : entry.url.lastPathComponent,
                        "name": entry.displayName,
                        "format": own ? "vbm" : entry.url.pathExtension.lowercased(),
                        "songs": entry.songCount ?? -1]
            },
        ]
    }

    /// Переклад цілком, рядками. Формат свій і простий: так на планшет
    /// потрапляє будь-який переклад, який читає «Слово», а не лише ті
    /// формати, які вміє розібрати сам планшет. Рядками — щоб планшет писав
    /// вірші у свою базу одразу, не тримаючи в пам'яті весь файл.
    ///
    ///     SLOVO-BIBLE 1
    ///     M ⇥ id ⇥ назва ⇥ коротка назва
    ///     B ⇥ номер у модулі ⇥ канонічний номер або порожньо ⇥ назва ⇥ скорочення ⇥ розділів
    ///     V ⇥ розділ ⇥ вірш ⇥ текст
    private func sendBible(_ id: String, state: AppState, on connection: NWConnection) {
        guard let module = state.module(id) else {
            respond(connection, 404, ["error": OurWords.t("нет такого перевода")]); return
        }
        let name = module.displayName
        let isPrimary = module.identifier == state.primaryModuleID
        NativeTrace.say("пульт: переклад «\(name)» на планшет")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out = "SLOVO-BIBLE 1\n"
            out += "M\t\(Self.field(module.identifier))\t\(Self.field(name))\t\(Self.field(module.info.shortName))\n"
            for book in module.books {
                let canon = book.canonicalNumber.map(String.init) ?? ""
                out += "B\t\(book.index)\t\(canon)\t\(Self.field(book.fullName))\t"
                    + "\(Self.field(book.shortNames.joined(separator: " ")))\t\(book.chapterCount)\n"
                for chapter in (try? module.chapters(ofBook: book)) ?? [] {
                    for verse in chapter.verses {
                        out += "V\t\(chapter.number)\t\(verse.number)\t\(Self.field(verse.text))\n"
                    }
                }
            }
            // Увесь переклад щойно ліг у кеш модуля. Для основного він і так
            // потрібен, а чужий тримати в пам'яті заради одного завантаження
            // нема чого.
            if !isPrimary { module.releaseCache() }
            let data = Data(out.utf8)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.respondData(connection, 200, data, contentType: "text/plain; charset=utf-8")
                }
            }
        }
    }

    /// Табуляція й переноси всередині поля зламали б рядок.
    nonisolated static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Пісенник — самим файлом: `.vbm` планшет розбирає сам, як і той, що
    /// людина скопіювала на нього руками.
    private func sendSongBook(_ file: String, state: AppState, on connection: NWConnection) {
        guard let library = state.songLibrary, let entry = library.entry(fileName: file) else {
            respond(connection, 404, ["error": OurWords.t("нет такого песенника")]); return
        }
        // Свій формат — у `.vbm` на льоту: планшет розбирає лише його.
        let data: Data?
        if SongBookJSON.isSongBookFile(entry.url) {
            data = library.book(entry.id).flatMap { try? SongBookWriter.data(for: $0) }
        } else {
            data = try? Data(contentsOf: entry.url)
        }
        guard let data else {
            respond(connection, 404, ["error": OurWords.t("нет такого песенника")]); return
        }
        NativeTrace.say("пульт: пісенник «\(entry.displayName)» на планшет")
        respondData(connection, 200, data, contentType: "application/octet-stream")
    }

    // MARK: - Файли плану

    /// Файл плану проповіді: лише зберегти в теці пульта, нічого не
    /// відкриваючи. Відкриє його пункт «Файл», коли до нього дійде черга.
    func storeUpload(name: String, body: Data, state: AppState) -> Result<[String: Any], Error> {
        let url = Self.uploadsFolder.appendingPathComponent(name)
        let ext = url.pathExtension.lowercased()
        let known = ShowModel.Kind.presentation.extensions.contains(ext)
            || ShowModel.Kind.pictures.extensions.contains(ext)
            || state.media.filters.accepts(url)
        guard known else {
            return .failure(UploadRefused(reason: OurWords.t("такой файл не открывают ни показ, ни плеер: .%s", "\(ext)")))
        }
        do {
            try FileManager.default.createDirectory(at: Self.uploadsFolder, withIntermediateDirectories: true)
            try body.write(to: url, options: .atomic)
        } catch {
            return .failure(error)
        }
        NativeTrace.say("пульт: файл плану «\(name)» (\(body.count) байт)")
        return .success(["file": name])
    }

    // MARK: - План проповіді

    /// План проповіді стає головним на час проповіді: план служіння
    /// відкладається цілим і повертається командою `sermon-end` (див.
    /// `DeskModel.beginSermon`). Відповідь — скільки пунктів лягло.
    func acceptSermonPlan(_ body: [String: Any], state: AppState) -> [String: Any] {
        let raw = body["items"] as? [[String: Any]] ?? []
        var notes: [String] = []
        let items = raw.compactMap { sermonItem($0, state: state, notes: &notes) }
        let title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DeskModel.shared.beginSermon(items, title: title)
        NativeTrace.say("пульт: план проповіді «\(title)» — \(items.count) пунктів із \(raw.count)")
        return ["added": items.count, "first": 0, "notes": notes]
    }

    /// Бібліотека щойно перечитується (після імпорту модуля з планшета) —
    /// план розбираємо, коли вона дочитається, інакше новий переклад ще
    /// не знайшовся б. Більше пів хвилини не чекаємо.
    func whenLibraryReady(_ state: AppState, waited: Int = 0, _ body: @escaping () -> Void) {
        guard state.isLoadingLibrary, waited < 60 else { body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.whenLibraryReady(state, waited: waited + 1, body) }
        }
    }

    // MARK: - Модуль із планшета

    /// Переклад чи пісенник, якого в програмі немає: планшет привозить сам
    /// файл модуля, і програма ставить його тим самим майстром імпорту, що й
    /// людина з меню, та одразу вмикає. Власник: «выполнить автоматический
    /// импорт этого модуля и его включение в программе».
    ///
    /// Кожен файл — у свою тимчасову теку: джерелом імпорту служить тека, і
    /// сусіди з попередніх завантажень потрапили б в опис разом із ним.
    func importModule(_ request: Request, state: AppState, on connection: NWConnection) {
        let name = ((request.query["name"] ?? "") as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "..", !request.body.isEmpty else {
            respond(connection, 400, ["error": OurWords.t("нет имени файла (name=)")]); return
        }
        let folder = Self.uploadsFolder.appendingPathComponent("Модулі", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try request.body.write(to: file, options: .atomic)
        } catch {
            respond(connection, 400, ["error": error.localizedDescription]); return
        }
        NativeTrace.say("пульт: модуль із планшета «\(name)» (\(request.body.count) байт)")
        let destination = ImportDestination.applicationLibrary
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome: ImportOutcome?
            var problem: String?
            do {
                let source = try ModuleImporter.source(at: file)
                var inventory = ModuleImporter.inventory(of: source, destination: destination)
                // Лише модулі й пісенники: шаблонам і фонам із планшета взятися нізвідки.
                inventory.templates = []
                inventory.images = []
                outcome = ModuleImporter.run(inventory, destination: destination)
            } catch {
                problem = "\(error)"
            }
            try? FileManager.default.removeItem(at: folder)
            let imported = outcome?.importedModules ?? []
            let modules = outcome?.modules ?? []
            let failures = outcome?.failures.map(\.reason) ?? []
            let failure = problem
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let failure {
                        self.respond(connection, 400, ["error": failure]); return
                    }
                    if !imported.isEmpty {
                        state.adoptImported(modules: imported, backgroundsFolder: nil)
                    }
                    NativeTrace.say("пульт: імпорт «\(name)» — \(modules.count) модулів, помилок \(failures.count)")
                    self.respond(connection, 200, [
                        "modules": imported.map(\.lastPathComponent),
                        "imported": modules,
                        "failures": failures,
                    ])
                }
            }
        }
    }

    /// Один пункт плану проповіді.
    ///
    /// Планшет везе з собою не лише посилання, а й сам текст: у програмі
    /// може не виявитися того перекладу чи пісенника, з яким працював
    /// проповідник, і тоді пункт стає текстом, а не губиться.
    private func sermonItem(_ entry: [String: Any], state: AppState, notes: inout [String]) -> PlanItem? {
        func string(_ key: String) -> String { (entry[key] as? String) ?? "" }
        func number(_ key: String) -> Int? {
            (entry[key] as? NSNumber)?.intValue ?? Int(string(key).trimmingCharacters(in: .whitespaces))
        }
        let title = string("title").trimmingCharacters(in: .whitespacesAndNewlines)

        switch string("type") {
        case "scripture":
            let chapter = number("chapter") ?? 1
            let verses = (entry["verses"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            let module = sermonModule(id: string("module"), name: string("moduleName"), state: state)
            if let module, let book = sermonBook(canon: number("canon"), name: string("bookName"), in: module) {
                return PlanItem.scripture(moduleID: module.identifier, book: book, chapter: chapter,
                                          verses: verses, quote: string("text"))
            }
            notes.append(OurWords.t("«%s»: такой книги нет в переводах программы — пункт стал текстом", title))
            return PlanItem.text(PlainTextDocument(title: title, body: string("text")))

        case "song":
            let file = string("songBook")
            let index = number("song") ?? -1
            // Пісенник упізнається за основою імені: `/api/library` досі
            // називає його «englishworship.vbm» (планшет розбирає лише .vbm),
            // а в бібліотеці він давно «englishworship.songbook». Порівняння
            // повного імені не знаходило його, і пісня ставала текстом.
            let stem = ((file as NSString).deletingPathExtension as String).lowercased()
            if let library = state.songLibrary,
               let found = library.books.first(where: {
                   $0.url.lastPathComponent.caseInsensitiveCompare(file) == .orderedSame
                       || $0.url.deletingPathExtension().lastPathComponent.lowercased() == stem
               }),
               let book = library.book(found.id), book.songs.indices.contains(index),
               title.isEmpty || book.songs[index].title == title {
                return PlanItem.song(bookFileName: found.url.lastPathComponent, song: book.songs[index])
            }
            // Такого пісенника в програмі немає (або пісня в ньому інша) —
            // слова привіз планшет, їх і показуємо текстом.
            let parts = entry["parts"] as? [[String: Any]] ?? []
            let lyrics = parts.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            notes.append(OurWords.t("«%s»: песенника нет в программе — песня стала текстом", title))
            return PlanItem.text(PlainTextDocument(title: title, body: lyrics))

        case "text":
            let heading = string("heading")
            let text = string("body")
            guard !heading.isEmpty || !text.isEmpty else { return nil }
            return PlanItem.text(PlainTextDocument(title: heading, body: text))

        case "file":
            // Лише ім'я: шлях будуємо самі, щоб пункт не вказав за межі теки пульта.
            let name = (string("file") as NSString).lastPathComponent
            let url = Self.uploadsFolder.appendingPathComponent(name)
            guard !name.isEmpty, name != "..", FileManager.default.fileExists(atPath: url.path) else {
                notes.append(OurWords.t("«%s»: файл не дошёл до программы", title.isEmpty ? name : title))
                return nil
            }
            return PlanItem.file(url, title: title)

        default:
            return nil
        }
    }

    /// Переклад пункту: той самий за ідентифікатором, потім за назвою, а
    /// без них — основний. Модуль із GitHub на планшеті зветься інакше, ніж
    /// тека того самого перекладу на комп'ютері, тож назва тут рятує часто.
    private func sermonModule(id: String, name: String, state: AppState) -> TextModule? {
        if let exact = state.module(id) { return exact }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty, let named = state.allModules.first(where: {
            $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame
                || $0.info.name.caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return named
        }
        return state.primaryModule
    }

    /// Книга за наскрізним номером канону, а без нього — за назвою.
    private func sermonBook(canon: Int?, name: String, in module: TextModule) -> BookInfo? {
        if let canon, let book = module.books.first(where: { $0.canonicalNumber == canon }) { return book }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return module.books.first { $0.fullName.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}
