import Foundation

/// Завантаження ресурсів із мережі й розкладання їх на місце.
///
/// Каталог — свій (`slovo-resources`) або «Цитата з Біблії»; кожен ресурс
/// — zip, який `ditto -x -k` кладе в теку модулів (переклад чи пісенник) або
/// в корінь даних (фони, шаблони, шрифти, сторінки). Після кожного — запис у
/// журнал `resources.json` з версією з каталогу: за нею потім видно
/// оновлення. Усе тут без головного потоку: викликається з фону, хід
/// повідомляється замиканням.
public final class ResourceHub: @unchecked Sendable {

    public static let ownCatalogURL = URL(string: "https://raw.githubusercontent.com/roman885-85/slovo-resources/main/catalog.json")!
    public static let bibleQuoteBase = "https://raw.githubusercontent.com/BibleQuote/BibleQuote-Modules/master/"

    public enum Source: String, CaseIterable, Sendable {
        case slovo, bibleQuote, myBible
    }

    public static let myBibleRegistryURL = URL(string: "https://mybible.zone/repository/registry/registry.zip")!

    public let layout: ResourceLayout
    private let session: URLSession

    public init(layout: ResourceLayout) {
        self.layout = layout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    // MARK: - Каталог

    /// Каталог джерела — з мережі. Помилка — рядком, як просив власник бачити
    /// причини, а не «не вдалося».
    public func fetchCatalog(_ source: Source, completion: @escaping @Sendable (Result<ResourceCatalog, ResourceError>) -> Void) {
        let url: URL
        switch source {
        case .slovo:      url = Self.ownCatalogURL
        case .bibleQuote: url = URL(string: Self.bibleQuoteBase + "modules.ini")!
        case .myBible:    url = Self.myBibleRegistryURL
        }
        let task = session.dataTask(with: url) { data, response, error in
            if let error { completion(.failure(.network(error.localizedDescription))); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? (url.isFileURL ? 200 : 0)
            guard let data, status == 200 else {
                completion(.failure(.network(OurWords.t("сервер ответил %s", "\(status)"))))
                return
            }
            switch source {
            case .slovo:
                do { completion(.success(try ResourceCatalog.decode(data))) } catch { completion(.failure(.badCatalog)) }
            case .bibleQuote:
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                completion(.success(ResourceCatalog.bibleQuote(ini: text, base: Self.bibleQuoteBase)))
            case .myBible:
                // Реєстр — zip з одним registry.json.
                guard let json = Self.unzipFirst(data, named: "registry.json"),
                      let catalog = ResourceCatalog.myBible(registry: json) else {
                    completion(.failure(.badCatalog)); return
                }
                completion(.success(catalog))
            }
        }
        task.resume()
    }

    /// Перший файл з потрібним ім'ям (або просто перший) із zip-а в пам'яті.
    static func unzipFirst(_ data: Data, named wanted: String) -> Data? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("slovo-zip-" + UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let zip = folder.appendingPathComponent("in.zip")
            try data.write(to: zip)
            let out = folder.appendingPathComponent("out")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, out.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let files = (fm.enumerator(at: out, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { !$0.hasDirectoryPath }
            let file = files.first { $0.lastPathComponent == wanted } ?? files.first
            return file.flatMap { try? Data(contentsOf: $0) }
        } catch {
            return nil
        }
    }

    // MARK: - Установлення

    public struct Progress: Sendable {
        public var item: ResourceItem
        public var index: Int
        public var total: Int
        /// Частка завантаження цього ресурсу, 0…1; `nil` — розмір невідомий.
        public var fraction: Double?
    }

    public struct Outcome: Sendable {
        public var installed: [ResourceItem] = []
        public var failures: [(ResourceItem, String)] = []
    }

    /// Завантажити й поставити вибране, по черзі. `progress` і `completion`
    /// приходять у фоні — кому треба головний потік, той сам перейде.
    public func install(_ items: [ResourceItem],
                        progress: @escaping @Sendable (Progress) -> Void,
                        completion: @escaping @Sendable (Outcome) -> Void) {
        let queue = DispatchQueue(label: "slovo.resources", qos: .userInitiated)
        queue.async {
            var outcome = Outcome()
            var ledger = ResourceLedger.load()
            for (index, item) in items.enumerated() {
                progress(Progress(item: item, index: index, total: items.count, fraction: 0))
                switch self.download(item, progress: { fraction in
                    progress(Progress(item: item, index: index, total: items.count, fraction: fraction))
                }) {
                case .failure(let error):
                    outcome.failures.append((item, "\(error)"))
                case .success(let zip):
                    defer { try? FileManager.default.removeItem(at: zip) }
                    if let error = self.place(zip: zip, for: item) {
                        outcome.failures.append((item, "\(error)"))
                    } else {
                        ledger.installed[item.id] = item.version
                        ledger.save()
                        outcome.installed.append(item)
                    }
                }
            }
            completion(outcome)
        }
    }

    /// Завантажити zip у тимчасовий файл. Синхронно — ми вже у фоні.
    private func download(_ item: ResourceItem, progress: @escaping @Sendable (Double?) -> Void) -> Result<URL, ResourceError> {
        guard let url = URL(string: item.url) else { return .failure(.network(item.url)) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<URL, ResourceError> = .failure(.network(""))
        let watcher = DownloadWatcher(progress: progress)
        let session = URLSession(configuration: self.session.configuration, delegate: watcher, delegateQueue: nil)
        let task = session.downloadTask(with: url) { location, response, error in
            defer { done.signal() }
            if let error { result = .failure(.network(error.localizedDescription)); return }
            // Файл із диска (`file://`) відповідає не HTTP — і це теж успіх:
            // так ставлять ресурси з теки, і так їх перевіряє самоперевірка.
            let status = (response as? HTTPURLResponse)?.statusCode ?? (url.isFileURL ? 200 : 0)
            guard let location, status == 200 else {
                result = .failure(.network(OurWords.t("сервер ответил %s", "\(status)")))
                return
            }
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent("slovo-resource-" + UUID().uuidString + ".zip")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                result = .success(kept)
            } catch {
                result = .failure(.network(error.localizedDescription))
            }
        }
        task.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return result
    }

    /// Розпакувати й покласти на місце: переклад і пісенник — у теку
    /// модулів (стара версія прибирається), фони/шаблони/шрифти/сторінки —
    /// у корінь даних, поверх наявних.
    private func place(zip: URL, for item: ResourceItem) -> ResourceError? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("slovo-unpack-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) } catch { return .unpack("\(error)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, staging.path]
        do { try process.run(); process.waitUntilExit() } catch { return .unpack("\(error)") }
        guard process.terminationStatus == 0 else { return .unpack("ditto \(process.terminationStatus)") }

        // Приховані файли не пропускаємо: у zip-і MyBible модуль лежить як
        // «.SQLite3» — без імені. Відкидаємо лише службове macOS.
        let unpacked = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        // Архів «Цитати з Біблії» містить теку модуля або самі файли модуля;
        // свій — теку чи файл під власним ім'ям.
        let destination = layout.destination(for: item)
        do {
            switch item.kind {
            case .bible, .songbook:
                let payload: URL
                if unpacked.count == 1 {
                    payload = unpacked[0]
                } else if unpacked.contains(where: { $0.lastPathComponent.lowercased() == "bibleqt.ini" }) {
                    payload = staging      // файли модуля без теки — кладемо всі під ім'ям ресурсу
                } else {
                    return .unpack(OurWords.t("в архиве нет модуля"))
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                if payload == staging {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    for file in unpacked { try fm.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent)) }
                } else {
                    try fm.moveItem(at: payload, to: destination)
                }
                // Пісенник VisioBible — одразу у свій формат, старий двійник геть.
                if item.kind == .songbook {
                    let stem = destination.deletingPathExtension()
                    let own = stem.appendingPathExtension(SongBookJSON.pathExtension)
                    if destination.pathExtension.lowercased() == "vbm" {
                        let book = try SongBook(fileAt: destination)
                        try SongBookJSON.write(book, to: own)
                        try fm.removeItem(at: destination)
                    } else {
                        let twin = stem.appendingPathExtension("vbm")
                        if fm.fileExists(atPath: twin.path) { try? fm.removeItem(at: twin) }
                    }
                }
            case .backgrounds, .templates, .fonts, .web:
                // Тека під власним ім'ям усередині архіву; зливаємо поверх.
                let source = unpacked.count == 1 && (try? unpacked[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    ? unpacked[0] : staging
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                    let target = destination.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: file, to: target)
                }
            }
        } catch {
            return .place("\(error)")
        }
        return nil
    }
}

/// Хід завантаження — у частках, коли сервер сказав розмір.
private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double?) -> Void
    init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }
}
