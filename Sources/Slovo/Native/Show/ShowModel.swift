import AppKit
import CoreGraphics
import SlovoCore

/// Показ картинок и презентаций.
///
/// Одна машина на два режима нарочно: «открыть — выбрать — показать —
/// листать» у фотографии и у страницы презентации одно и то же, и разводить
/// это в два кода значило бы дважды чинить каждую ошибку.
///
/// Список копится, а не подменяется: на служении показывают подряд снимки из
/// разных папок и не одну презентацию, и заставлять человека собирать их в
/// одну папку заранее — значит не понимать, как идёт служение. Добавленное
/// становится в конец, а «Закрыть» убирает всё разом.
///
/// Источников у страницы три: файл с картинкой, презентация PowerPoint и PDF.
/// Ниже по течению они неразличимы: все дают кадр и уходят в зал той же
/// дорогой, что видео.
@MainActor
final class ShowModel {

    enum Kind {
        case pictures
        case presentation

        /// Расширения, которые открываем.
        var extensions: [String] {
            switch self {
            case .pictures: return ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp"]
            case .presentation: return ["pptx", "ppsx", "potx", "pptm", "ppsm", "pdf"]
            }
        }
    }

    /// Откуда берётся кадр страницы.
    enum Source {
        case picture(URL)
        case slides(document: Int, page: Int)
    }

    /// Один разобранный документ: презентация или PDF.
    private enum Document {
        case presentation(PPTXDocument)
        case portable(CGPDFDocument)

        var count: Int {
            switch self {
            case .presentation(let document): return document.count
            case .portable(let document): return document.numberOfPages
            }
        }
    }

    /// Одна страница показа: имя в списке и откуда брать картинку.
    struct Page {
        /// Полное имя — для подписи и зала: «Проповедь — Слайд 3».
        let title: String
        /// Короткое — для колонки страниц, где файл уже назван: «Слайд 3».
        let short: String
        let source: Source
    }

    /// Один открытый файл показа и его страницы подряд в `pages`.
    ///
    /// Владелец просил две колонки для презентаций: слева файлы, справа
    /// страницы выбранного. Список страниц при этом остаётся сквозным — так
    /// стрелки и зал работают как прежде, а колоды лишь размечают его.
    struct Deck {
        let name: String
        let url: URL
        var range: Range<Int>
    }

    let kind: Kind
    private(set) var pages: [Page] = []
    /// У презентаций колода — файл со страницами; у картинок каждая
    /// картинка — колода из одной страницы, чтобы колонка файлов не пустовала.
    private(set) var decks: [Deck] = []
    private(set) var index: Int?
    /// Что открыто последним — его имя видно в подписи.
    private(set) var sourceName = ""
    /// Чому показувати нічого. Зберігаємо зразок фрази і те, що в нього
    /// підставляється, а не готовий рядок: мову міняють при живій програмі,
    /// і вже зібрана фраза лишилася б попередньою мовою на екрані.
    private(set) var problemPattern: String?
    private(set) var problemValues: [String] = []
    var problem: String? {
        guard let problemPattern else { return nil }
        switch problemValues.count {
        case 0: return OurWords.t(problemPattern)
        case 1: return OurWords.t(problemPattern, problemValues[0])
        default: return OurWords.t(problemPattern, problemValues[0], problemValues[1])
        }
    }

    /// Поставити причину: зразок і підстановки окремо.
    private func note(problem pattern: String?, _ values: String...) {
        problemPattern = pattern
        problemValues = values
    }

    private var documents: [Document] = []
    /// Нарисованные страницы: рисовать их заново на каждый показ — это доли
    /// секунды на страницу, а листают их подряд и быстро.
    private var drawn: [Int: CGImage] = [:]

    init(kind: Kind) { self.kind = kind }

    // MARK: - Пам'ять між запусками

    /// Чи запам'ятовує ця модель свій список між запусками.
    ///
    /// Вмикає тільки робоче місце показу. Самоперевірка заводить свої моделі
    /// десятками, і якби вони теж писали в пам'ять, кожен прогін стирав би
    /// список, зібраний людиною до служіння.
    var remembers = false

    /// Ключ, під яким лежить список відкритих файлів.
    private var memoryKey: String {
        kind == .pictures ? "showPictureFiles" : "showPresentationFiles"
    }

    /// Запам'ятати відкрите. Власник: «после закрытия программы все
    /// добавленные презентации, минусовки, картинки и т.д. не сохраняются».
    ///
    /// Зберігаємо тільки шляхи: сторінки й розібрані документи щоразу
    /// збираються заново з тих самих файлів. Тримати в пам'яті картинки
    /// презентації немає сенсу — вони важать десятки мегабайтів, а
    /// перечитуються за мить.
    private func remember() {
        guard remembers, !SessionMemory.isSuspended else { return }
        UserDefaults.standard.set(decks.map(\.url.path), forKey: memoryKey)
    }

    /// Повернути те, що було відкрито минулого разу.
    ///
    /// Зниклі файли просто пропускаємо: людина могла прибрати флешку, і
    /// скарга про це на запуску була б докучливою — у списку їх просто не
    /// буде.
    func restore() {
        guard remembers, pages.isEmpty else { return }
        let saved = UserDefaults.standard.stringArray(forKey: memoryKey) ?? []
        let alive = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !alive.isEmpty else { return }
        open(alive)
        note(problem: nil)
        // Показ починають самі: після запуску нічого не має стояти вибраним
        // у залі, а от у списку все має бути на місці.
        index = nil
        sourceName = ""
        remember()
    }

    var isEmpty: Bool { pages.isEmpty }
    var count: Int { pages.count }

    /// Колода, в которой стоит текущая страница.
    var currentDeck: Int? {
        guard let index else { return nil }
        return decks.firstIndex { $0.range.contains(index) }
    }

    /// Страницы, которые показывает вторая колонка: у презентаций — выбранная
    /// колода, у картинок — весь список.
    ///
    /// У картинок каждая — своя колода из одной страницы, и без этой отсечки
    /// «колода текущей страницы» сводила список к одной строке: владелец
    /// видел в списке только первое имя файла, остальные пропадали.
    var currentRange: Range<Int> {
        if kind == .pictures { return 0..<pages.count }
        if let deck = currentDeck { return decks[deck].range }
        if let first = decks.first, index == nil { return first.range }
        return decks.isEmpty ? 0..<pages.count : 0..<0
    }

    /// Выбрать файл: страницей становится его первая, если текущая не его.
    func selectDeck(_ position: Int) {
        guard decks.indices.contains(position) else { return }
        let range = decks[position].range
        if let index, range.contains(index) { return }
        index = range.lowerBound
    }

    /// Убрать файл со всеми его страницами — ошиблись презентацией.
    func removeDeck(at position: Int) {
        guard decks.indices.contains(position) else { return }
        let range = decks[position].range
        pages.removeSubrange(range)
        drawn.removeAll()
        decks.remove(at: position)
        for later in decks.indices where decks[later].range.lowerBound >= range.upperBound {
            decks[later].range = (decks[later].range.lowerBound - range.count)..<(decks[later].range.upperBound - range.count)
        }
        if let current = index {
            if range.contains(current) {
                index = pages.isEmpty ? nil : min(range.lowerBound, pages.count - 1)
            } else if current >= range.upperBound {
                index = current - range.count
            }
        }
        if pages.isEmpty { sourceName = "" }
        remember()
    }

    /// Что показывать в зале. `nil` — показывать нечего.
    var currentImage: CGImage? {
        guard let index, pages.indices.contains(index) else { return nil }
        return image(at: index)
    }

    var currentTitle: String {
        guard let index, pages.indices.contains(index) else { return "" }
        return pages[index].title
    }

    // MARK: - Открытие

    /// Добавить выбранное к тому, что уже открыто.
    ///
    /// Папка раскрывается целиком: на служении показывают подряд всё, что в
    /// ней лежит. Повторно брошенный файл не удваивается — в списке он уже
    /// есть, и второй такой же строкой только сбивал бы счёт.
    func open(_ urls: [URL]) {
        note(problem: nil)
        let first = pages.count
        for url in expand(urls) {
            switch kind {
            case .pictures:
                add(picture: url)
            case .presentation:
                add(document: url)
            }
        }
        if pages.count > first {
            // Показ ведут с первой добавленной страницы: её и выбираем, а
            // прежний выбор трогаем только если его не было.
            if index == nil { index = first }
            sourceName = urls.count == 1
                ? urls[0].lastPathComponent
                : OurWords.t("%s из %s", "\(pages.count - first)", "\(pages.count)")
        } else if problemPattern == nil {
            note(problem: kind == .pictures
                 ? "В выбранном нет ни одной картинки"
                 : "В выбранном нет ни одной презентации")
        }
        remember()
    }

    /// Раскрыть папки и отсеять чужое. Порядок — как видит человек: «10»
    /// после «9», а не после «1».
    private func expand(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                // Файла нет вовсе — сказать об этом честнее, чем промолчать.
                if kind == .presentation, url.pathExtension.lowercased() == "ppt" { add(document: url) }
                continue
            }
            if isDirectory.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found.append(contentsOf: inside.filter {
                    kind.extensions.contains($0.pathExtension.lowercased())
                })
            } else if kind.extensions.contains(url.pathExtension.lowercased())
                        || url.pathExtension.lowercased() == "ppt" {
                found.append(url)
            }
        }
        found.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return found
    }

    private func add(picture url: URL) {
        guard !pages.contains(where: {
            if case .picture(let known) = $0.source { return known == url }
            return false
        }) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        pages.append(Page(title: name, short: name, source: .picture(url)))
        // Каждая картинка — своя «колода» из одной страницы: тогда в колонке
        // файлов видны все добавленные картинки. Владелец: «при добавлении
        // нескольких изображений список добавленных файлов пуст».
        decks.append(Deck(name: url.lastPathComponent, url: url, range: (pages.count - 1)..<pages.count))
    }

    private func add(document url: URL) {
        // Старый двоичный `.ppt` — совсем другой формат, не архив с XML.
        // Сказать об этом прямо честнее, чем показать пустой список.
        if url.pathExtension.lowercased() == "ppt" {
            note(problem: "Старый формат .ppt программа не читает — "
                 + "пересохраните презентацию как .pptx")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
                note(problem: "PDF не открылся: %s", url.lastPathComponent)
                return
            }
            documents.append(.portable(document))
            let at = documents.count - 1
            let first = pages.count
            for page in 0..<document.numberOfPages {
                let short = OurWords.t("Страница %s", "\(page + 1)")
                pages.append(Page(title: name + " — " + short, short: short,
                                  source: .slides(document: at, page: page)))
            }
            decks.append(Deck(name: url.lastPathComponent, url: url, range: first..<pages.count))
            return
        }
        do {
            let document = try PPTXDocument(fileAt: url)
            documents.append(.presentation(document))
            let at = documents.count - 1
            let first = pages.count
            for page in 0..<document.count {
                let short = OurWords.t("Слайд %s", "\(page + 1)")
                pages.append(Page(title: name + " — " + short, short: short,
                                  source: .slides(document: at, page: page)))
            }
            decks.append(Deck(name: url.lastPathComponent, url: url, range: first..<pages.count))
        } catch {
            // Чуже повідомлення про помилку перекладати нічим — лишаємо як є.
            note(problem: "\(error)")
        }
    }

    func close() {
        pages = []
        decks = []
        index = nil
        drawn.removeAll()
        documents.removeAll()
        sourceName = ""
        note(problem: nil)
        remember()
    }

    /// Убрать одну страницу — ошиблись файлом. У презентаций страницы
    /// живут колодами, и убирается колода целиком (`removeDeck`).
    func remove(at position: Int) {
        guard pages.indices.contains(position) else { return }
        if let deck = decks.firstIndex(where: { $0.range.contains(position) }) {
            removeDeck(at: deck)
            return
        }
        pages.remove(at: position)
        drawn.removeAll()
        if let current = index {
            if current == position { index = pages.indices.contains(position) ? position : (pages.isEmpty ? nil : pages.count - 1) }
            else if current > position { index = current - 1 }
        }
    }

    // MARK: - Выбор и листание

    func select(_ position: Int?) {
        guard let position, pages.indices.contains(position) else { index = nil; return }
        index = position
    }

    /// Следующая или предыдущая страница. По кругу не ходим: на служении
    /// «дальше» в конце показа должно означать конец, а не начало заново.
    @discardableResult
    func step(by delta: Int) -> Bool {
        guard let index else {
            guard !pages.isEmpty else { return false }
            self.index = delta > 0 ? 0 : pages.count - 1
            return true
        }
        let next = index + delta
        guard pages.indices.contains(next) else { return false }
        self.index = next
        return true
    }

    // MARK: - Картинки

    /// Картинка страницы в полном размере.
    func image(at position: Int) -> CGImage? {
        guard pages.indices.contains(position) else { return nil }
        switch pages[position].source {
        case .picture(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case let .slides(document, page):
            if let ready = drawn[position] { return ready }
            guard documents.indices.contains(document) else { return nil }
            let image: CGImage?
            switch documents[document] {
            case .presentation(let deck):
                image = render(slide: page, of: deck)
            case .portable(let pdf):
                image = render(page: page, of: pdf)
            }
            if let image { drawn[position] = image }
            return image
        }
    }

    /// Страница презентации. Рисуем в высоту зала: меньше — и на проекторе
    /// будет мыло, больше — впустую, экран всё равно не покажет.
    private func render(slide: Int, of document: PPTXDocument) -> CGImage? {
        let height = 1080.0
        let width = height * (document.canvasSize.width / max(document.canvasSize.height, 1))
        guard document.slides.indices.contains(slide) else { return nil }
        return PPTXRenderer.image(of: document.slides[slide], in: document,
                                  size: CGSize(width: width, height: height))
    }

    /// Страница PDF. Рисуем сами, а не через `NSImage`: у PDF своя система
    /// координат и свой поворот страницы, и «просто картинка» из него
    /// приходит то боком, то в четверть размера.
    private func render(page number: Int, of document: CGPDFDocument) -> CGImage? {
        guard let page = document.page(at: number + 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let turned = page.rotationAngle % 180 != 0
        let source = CGSize(width: turned ? box.height : box.width,
                            height: turned ? box.width : box.height)
        let height = 1080.0
        let scale = height / source.height
        let width = max(1, Int((source.width * scale).rounded()))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: nil, width: width, height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info.rawValue) else { return nil }
        // Белым, а не прозрачным: страница PDF всегда на белом листе, и
        // чёрный экран под текстом читался бы как поломка.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(width), height: height))
        context.drawPDFPage(page, fitting: CGSize(width: Double(width), height: height))
        return context.makeImage()
    }
}

private extension CGContext {

    /// Вписать страницу PDF в кадр — с её собственным поворотом.
    func drawPDFPage(_ page: CGPDFPage, fitting size: CGSize) {
        saveGState()
        let transform = page.getDrawingTransform(.cropBox,
                                                 rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true)
        concatenate(transform)
        drawPDFPage(page)
        restoreGState()
    }
}
