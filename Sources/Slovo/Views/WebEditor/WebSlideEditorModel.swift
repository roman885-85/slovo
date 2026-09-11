import Foundation
import AppKit
import CoreGraphics
import SlovoCore

/// Состояние редактора веб-слайдов.
///
/// Страницы бывают двух родов. Авторские лежат в папке `RemoteAPI` рядом с
/// модулями — их мы не трогаем: это чужие файлы, и портить их нельзя.
/// Свои живут отдельно, в папке поддержки приложения, и правятся свободно.
/// Открыть авторскую можно только на чтение, но с неё легко начать свою —
/// кнопкой «Взять за основу».
///
/// Правка идёт двумя путями сразу, и это главное, что здесь устроено.
/// Ползунки и перетаскивание пишут в ту же строку `source`, что показывает
/// вкладка «Разметка», — второго хранилища значений нет нигде. Ползунок
/// меняет ровно одну строку блока настроек, всё прочее в файле остаётся
/// байт в байт; правка руками при следующем разборе становится показанием
/// ползунка. Затереть друг друга им нечем: у них один исходник.
@MainActor
final class WebSlideEditorModel: ObservableObject {

    struct Page: Identifiable, Hashable {
        let url: URL
        let isEditable: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        /// Заголовок из `<title>` — в списке читается лучше имени файла.
        var title: String { WebSlideEditorModel.pageTitle(of: url) ?? name }
    }

    nonisolated(unsafe) private static var titleCache: [String: (date: Date, title: String?)] = [:]
    nonisolated private static let titleLock = NSLock()

    nonisolated static func pageTitle(of url: URL) -> String? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        titleLock.lock(); defer { titleLock.unlock() }
        if let cached = titleCache[url.path], cached.date == date { return cached.title }
        var title: String?
        if let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251),
           let open = html.range(of: "<title>", options: .caseInsensitive),
           let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) {
            var text = html[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            // Наши заготовки пишут «Слайд — Библия: лес»: в узком списке
            // видно только «Слайд — Биб…», а слово одно на всех.
            for prefix in ["Слайд — ", "Слово — "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
            if !text.isEmpty { title = OurWords.t(text) }
        }
        titleCache[url.path] = (date, title)
        return title
    }

    /// Одноразовая команда предпросмотру — то, что нельзя выразить значением
    /// переменной: повторить показ, погасить экран в зале.
    struct PreviewCommand: Equatable {
        var tick: Int
        var script: String
    }

    @Published private(set) var authorPages: [Page] = []
    @Published private(set) var myPages: [Page] = []
    @Published private(set) var current: Page?
    @Published private(set) var message: String?

    /// Текст страницы — единственный источник правды.
    @Published var source = "" {
        didSet {
            guard source != oldValue else { return }
            sheet = WebSlideSheet.read(html: source)
            isModified = source != savedSource
            scheduleSave()
        }
    }

    @Published private(set) var isModified = false
    /// Разобранное оформление открытой страницы.
    @Published private(set) var sheet = WebSlideSheet.read(html: "")

    /// Человек тронул ручку на странице из комплекта — предлагаем копию.
    @Published var offersCopy = false

    /// Куда отдать изменённые значения, чтобы они легли на трансляцию тут же.
    ///
    /// Правка ползунка доходила до зала только с перезагрузкой страницы, а
    /// страница обычно открыта в OBS и трогать её во время служения некому.
    var broadcast: (([String: String]) -> Void)?

    // MARK: Предпросмотр

    /// Чем наполнен слайд в предпросмотре.
    @Published var sample = WebSlideSample.all[0] {
        didSet {
            guard sample != oldValue else { return }
            scheduleSampleApply()
        }
    }
    /// Та же проба, но применённая: между нажатием клавиши и перезагрузкой
    /// страницы держим паузу, иначе предпросмотр моргает на каждую букву.
    @Published private(set) var appliedSample = WebSlideSample.all[0]
    /// Показать, что видит зал при пустом экране.
    @Published var isBlankScreen = false {
        didSet {
            guard isBlankScreen != oldValue else { return }
            // Пустой экран страница умеет показывать сама — перезагружать её
            // ради этого незачем.
            send("if (window.slovoPreview) window.slovoPreview.hide(\(isBlankScreen ? "true" : "false"));")
        }
    }
    @Published private(set) var command = PreviewCommand(tick: 0, script: "")

    /// Откуда предпросмотр берёт вспомогательные файлы страницы.
    ///
    /// Страницы автора тянут jQuery по относительному пути `i/`. Строка
    /// разметки, загруженная «из ниоткуда», такого пути не имеет: скрипт
    /// падает на первой же строке, и предпросмотр показывает пустой экран —
    /// то самое «в редакторе красиво, на проекторе пусто», только наоборот.
    /// Поэтому рядом заводится временная папка, куда переписано всё
    /// невидимое хозяйство страницы: картинки, значок, папка `i`. В саму
    /// папку автора при этом не пишется ни байта.
    @Published private(set) var previewFolder: URL?
    /// Путь к своему jQuery в папке предпросмотра, если он там есть.
    @Published private(set) var localJQuery: String?

    private var savedSource = ""
    private var authorFolder: URL?
    private var saveTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?

    /// Куда складываются свои страницы.
    /// Та же папка, которую отдаёт веб-сервер. Держим её в одном месте:
    /// пока их было два, мастерская писала страницы туда, где сервер их не
    /// искал, и «Открыть в браузере» отвечало 404.
    static var myFolder: URL { WebOutputServer.userPagesFolder }

    // MARK: - Список страниц

    func reload(dataRoot: URL) {
        let folder = dataRoot.appendingPathComponent("RemoteAPI")
        authorFolder = folder
        try? FileManager.default.createDirectory(at: Self.myFolder, withIntermediateDirectories: true)

        authorPages = html(in: folder).map { Page(url: $0, isEditable: false) }
        myPages = html(in: Self.myFolder).map { Page(url: $0, isEditable: true) }

        if current == nil { open(myPages.first ?? authorPages.first) }
    }

    private func html(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "html" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Открыть, сохранить, создать

    func open(_ page: Page?) {
        guard let page else { return }
        guard let text = try? String(contentsOf: page.url, encoding: .utf8) else {
            message = OurWords.t("Не удалось прочитать %s", page.name)
            return
        }
        // Переключение страницы не должно тянуть за собой отложенное
        // сохранение прежней в новый файл.
        flushSave()
        current = page
        savedSource = text
        source = text
        isModified = false
        message = nil
        prepareResources(for: page)
        refreshBlocksIfOld()
    }

    /// Обновить наши блоки, если страницу настраивал прежний выпуск.
    ///
    /// Привязка и живой блок правятся вместе с программой: в них чинятся
    /// наложение слайдов, высота сцены, применение на лету. Значения при этом
    /// не трогаются — переписывается только то, что пишем мы сами. Без этого
    /// человеку пришлось бы заводить свои страницы заново после каждой правки.
    /// Обновить наши блоки, если страницу настраивал прежний выпуск.
    ///
    /// Переписывается только привязка и живой блок — то, что пишем мы сами.
    /// Значения не трогаются: в блоке лежит ровно то, что человек тронул, и
    /// перемерять их заново значило бы решать за него.
    private func refreshBlocksIfOld() {
        guard current?.isEditable == true else { return }
        let document = WebSlideParameters.parse(html: source)
        guard case .present(let version, _) = document.block, version < WebSlideParameters.version else { return }
        switch WebSlideParameters.write(html: source, settings: document.settings) {
        case .written(let text):
            source = text
            message = OurWords.t("Страница обновлена под новый выпуск — ваши настройки остались как были.")
        case .refused:
            break
        }
    }

    private func prepareResources(for page: Page) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Слово-предпросмотр", isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            previewFolder = nil
            localJQuery = nil
            return
        }

        // Сперва хозяйство автора, потом своё: своя копия чужой страницы
        // лежит в другой папке, где никакого `i/jquery` нет и в помине, а
        // страница его всё равно требует. Без этого «Взять за основу»
        // оборачивалось пустым предпросмотром: скрипт падал на первой
        // строке, и человек правил вслепую.
        var sources: [URL] = []
        if let authorFolder { sources.append(authorFolder) }
        let own = page.url.deletingLastPathComponent()
        if own != authorFolder { sources.append(own) }

        var copied = 0
        for folder in sources {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
            for item in items where item.pathExtension.lowercased() != "html" {
                let target = temp.appendingPathComponent(item.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.copyItem(at: item, to: target)) != nil { copied += 1 }
            }
        }

        previewFolder = temp
        localJQuery = Self.jQuery(in: temp)
        _ = copied
    }

    /// Свой jQuery в папке предпросмотра — путём относительно страницы.
    ///
    /// Три авторские страницы тянут jQuery с `code.jquery.com`. На служении
    /// интернета в зале может не быть вовсе, а в предпросмотре его нет почти
    /// никогда: страница молча остаётся пустой, потому что весь её показ
    /// написан на jQuery. Рядом, в папке `i`, лежит ровно та же библиотека —
    /// на неё и переводим, и только в предпросмотре: в файле страницы не
    /// меняется ни байта.
    private static func jQuery(in folder: URL) -> String? {
        let inner = folder.appendingPathComponent("i", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: inner,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        guard let file = items.first(where: {
            $0.lastPathComponent.lowercased().hasPrefix("jquery")
                && $0.pathExtension.lowercased() == "js"
        }) else { return nil }
        return "i/" + file.lastPathComponent
    }

    @discardableResult
    func save() -> Bool {
        flushApply()
        saveTask?.cancel()
        saveTask = nil
        guard let page = current else { return false }
        guard isModified else {
            // Автосохранение уже записало файл — скажем об этом, а не молчим.
            message = OurWords.t("Уже сохранено: %s", page.name)
            return true
        }
        guard page.isEditable else {
            message = OurWords.t("Это страница из комплекта программы, её нельзя менять. Нажмите «Взять за основу».")
            return false
        }
        do {
            try source.write(to: page.url, atomically: true, encoding: .utf8)
            savedSource = source
            isModified = false
            message = OurWords.t("Сохранено: %s", page.name)
            return true
        } catch {
            message = OurWords.t("Не удалось сохранить: %s", error.localizedDescription)
            return false
        }
    }

    /// Сохранение с задержкой.
    ///
    /// Ползунок за одно движение мыши меняет строку десятки раз; писать файл
    /// на каждый шаг — значит стучать по диску впустую. Но и оставлять
    /// человека без сохранения нельзя: он двигает ползунки, а не следит за
    /// кнопкой. Поэтому пишем через паузу после того, как правки утихли.
    private func scheduleSave() {
        guard current?.isEditable == true else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self?.save() }
        }
    }

    /// Дописать отложенное немедленно — перед сменой страницы и закрытием окна.
    func flushSave() {
        flushApply()
        if saveTask != nil { save() }
    }

    /// Новая страница из заготовки.
    func create(from template: WebSlideTemplates.Template, name: String) {
        let safe = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? template.id : name.trimmingCharacters(in: .whitespaces)
        var file = Self.myFolder.appendingPathComponent(safe).appendingPathExtension("html")
        var index = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = Self.myFolder.appendingPathComponent("\(safe) \(index)").appendingPathExtension("html")
            index += 1
        }
        do {
            try template.html.write(to: file, atomically: true, encoding: .utf8)
            reloadMine()
            open(Page(url: file, isEditable: true))
            message = OurWords.t("Создана страница %s", file.lastPathComponent)
        } catch {
            message = OurWords.t("Не удалось создать: %s", error.localizedDescription)
        }
    }

    /// Скопировать открытую страницу в свои и продолжить править копию.
    @discardableResult
    func duplicateCurrent() -> Bool {
        guard let page = current else { return false }
        let base = page.url.deletingPathExtension().lastPathComponent
        var file = Self.myFolder.appendingPathComponent("\(base) копия").appendingPathExtension("html")

        var index = 2
        while FileManager.default.fileExists(atPath: file.path) {
            // Слово «копия» здесь нарочно не переводится: это ИМЯ ФАЙЛА на
            // диске, а не подпись на экране. Переведи его — и одна и та же
            // страница называлась бы по-разному в зависимости от выбранного
            // языка, а прежние копии перестали бы находиться.
            file = Self.myFolder.appendingPathComponent("\(base) копия \(index)").appendingPathExtension("html")
            index += 1
        }
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
            reloadMine()
            open(Page(url: file, isEditable: true))
            // Никаких блоков в копию не добавляем. Копия обязана быть копией:
            // человек берёт страницу за основу и должен получить её же, до
            // последней точки. Настройки заведутся сами, когда он тронет
            // первую ручку, — и только та, которую тронул.
            message = OurWords.t("Теперь правится своя копия: %s", file.lastPathComponent)
            return true
        } catch {
            message = OurWords.t("Не удалось скопировать: %s", error.localizedDescription)
            return false
        }
    }

    func delete(_ page: Page) {
        guard page.isEditable else { return }
        try? FileManager.default.removeItem(at: page.url)
        if current?.id == page.id {
            saveTask?.cancel()
            saveTask = nil
            current = nil
            savedSource = ""
            source = ""
        }
        reloadMine()
        open(myPages.first ?? authorPages.first)
    }

    private func reloadMine() {
        myPages = html(in: Self.myFolder).map { Page(url: $0, isEditable: true) }
    }

    // MARK: - Ползунки

    /// Можно ли править открытую страницу; если нет — предлагаем копию.
    @discardableResult
    func requireEditable() -> Bool {
        guard current != nil else { return false }
        if current?.isEditable == true { return true }
        offersCopy = true
        return false
    }

    func change(_ knob: WebSlideKnob, to value: String) {
        apply([(knob.name, value)])
    }

    /// Значения ползунков, ещё не вписанные в текст страницы.
    private var pendingChanges: [String: String] = [:]
    private var applyTask: Task<Void, Never>?

    /// Записать пачку значений разом — так ложится перетаскивание, где
    /// меняются сразу и прижим, и сдвиг.
    ///
    /// Одно движение ползунка шлёт сюда десятки шагов. Раньше каждый шаг
    /// целиком переписывал HTML страницы и тут же разбирал его заново
    /// (`source` didSet → `WebSlideSheet.read`), да ещё перезаливал текстовый
    /// редактор — на большой странице это складывалось в рывки. Теперь на
    /// трансляцию значение уходит сразу (это дёшево — пара строк по сокету,
    /// и OBS тянется плавно), а тяжёлую перезапись самого текста откладываем
    /// и склеиваем: пишем один раз, последними значениями, когда ползунок
    /// замер.
    func apply(_ changes: [(name: String, value: String)]) {
        guard !changes.isEmpty else { return }
        guard requireEditable() else { return }
        for change in changes { pendingChanges[change.name] = change.value }
        // Сразу — на трансляцию: страницы в браузере и в OBS применят
        // присланное без перезагрузки и без ожидания.
        broadcast?(Dictionary(changes.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new }))
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushApply() }
        }
    }

    /// Вписать накопленные значения ползунков в текст страницы одним заходом.
    /// Зовётся по затиханию ползунка, а также перед сохранением и закрытием.
    func flushApply() {
        applyTask?.cancel()
        applyTask = nil
        guard !pendingChanges.isEmpty else { return }
        let changes = pendingChanges.map { (name: $0.key, value: $0.value) }
        pendingChanges.removeAll()
        // Ползунок на странице без настроек заводит их сам — но заводит ровно
        // то, что тронули. Пока сюда попадал полный набор заводских значений,
        // страница разом переставала быть похожей на себя.
        if case .missing = sheet.block {
            var only = WebSlideSettings()
            for change in changes { only.set(change.name, change.value) }
            switch WebSlideParameters.write(html: source, settings: only) {
            case .written(let text): source = text
            case .refused(let reason): message = reason
            }
            return
        }
        switch sheet.writing(changes, into: source) {
        case .done(let text): source = text
        case .refused(let reason): message = reason
        }
    }

    /// Вернуть ручку к тому, что стоит в заготовке.
    func reset(_ knob: WebSlideKnob) {
        guard let parameter = WebSlideParameters.parameter(named: knob.name),
              sheet.dialect == .parameters else { return }
        apply([(knob.name, parameter.defaultValue)])
    }

    /// Надеть на страницу общий блок настроек.
    ///
    /// Значения для блока спрашиваем у самой страницы — грузим её в невидимый
    /// браузер и снимаем `getComputedStyle`. Разбирать чужой CSS своими силами
    /// оказалось мало: у автора вид собирается из наследования, нескольких
    /// правил и атрибута `style`, и всякая наша выборка была то беднее, то
    /// полнее настоящей. Оттого копия и открывалась «с другими настройками».
    /// Браузер отвечает точно; не ответит — обойдёмся разбором.
    /// Завести в странице пустой блок настроек.
    ///
    /// Пустой — и это главное. Раньше сюда сыпался полный набор значений, и
    /// страница разом становилась чужой самой себе. Теперь блок заводится
    /// пустым, а строки в нём появляются по одной, когда двигают ручки.
    func addSettingsBlock() {
        guard requireEditable() else { return }
        switch WebSlideParameters.write(html: source, settings: WebSlideSettings()) {
        case .written(let text):
            source = text
            message = OurWords.t("Настройки заведены. Двигайте ползунки — в страницу ляжет только то, что вы тронули.")
        case .refused(let reason):
            message = reason
        }
    }

    /// Переписать повреждённый блок заново.
    func repairSettingsBlock() {
        guard requireEditable() else { return }
        switch WebSlideSheet.repairing(source) {
        case .done(let text):
            source = text
            message = OurWords.t("Блок настроек переписан заново.")
        case .refused(let reason):
            message = reason
        }
    }

    // MARK: - Перетаскивание

    /// Где блок стоит сейчас, в долях кадра.
    var placementPoint: CGPoint { sheet.placementPoint }

    /// Отпустили мышь в этой точке кадра.
    func place(at point: CGPoint) {
        let changes = sheet.placing(at: point)
        guard !changes.isEmpty else {
            if current?.isEditable == true {
                message = OurWords.t("Эту страницу нельзя двигать мышью: в ней нет ручки расположения.")
            }
            return
        }
        apply(changes)
    }

    /// Как назвать человеку место, куда встанет блок.
    func placementTitle(at point: CGPoint) -> String {
        let drop = WebSlidePlacement.drop(at: point)
        let rows = ["сверху", "посередине", "снизу"]
        let columns = ["слева", "по центру", "справа"]
        var title = rows[drop.row] + " " + columns[drop.column]
        if drop.offsetX != 0 || drop.offsetY != 0 {
            title += ", " + OurWords.t("сдвиг %s / %s",
                                       WebSlideKnob.digits(drop.offsetX),
                                       WebSlideKnob.digits(drop.offsetY))
        }
        return title
    }

    // MARK: - Предпросмотр

    /// Страница с подменённым соединением: показывает придуманный слайд
    /// сразу, без сервера и без проектора.
    var previewHTML: String {
        let shim = appliedSample.shim(hidden: isBlankScreen)
        let page = Self.withLocalJQuery(source, path: localJQuery)
        // Подмену вставляем как можно раньше — до того, как страница успеет
        // создать своё соединение.
        if let range = page.range(of: "<head>", options: .caseInsensitive) {
            return page.replacingCharacters(in: range, with: "<head>\n" + shim)
        }
        return shim + page
    }

    /// Перевести ссылки на jQuery из интернета на свою копию.
    ///
    /// Только для показа: правится строка, которая уходит в предпросмотр, а
    /// не та, что лежит в файле. Возвращаем исходник как есть, когда своей
    /// копии нет, — рвать рабочую ссылку ради красоты было бы хуже.
    static func withLocalJQuery(_ html: String, path: String?) -> String {
        guard let path, !path.isEmpty else { return html }
        var result = html
        for prefix in ["https://", "http://", "//"] {
            var search = result.startIndex..<result.endIndex
            while let hit = result.range(of: prefix + "code.jquery.com/", range: search) {
                // Дочитываем до конца адреса: он кончается той же кавычкой,
                // какой открыт атрибут, — до неё и заменяем.
                let tail = result[hit.upperBound...]
                let stop = tail.firstIndex(where: { $0 == "\"" || $0 == "'" || $0 == " " || $0 == ">" })
                    ?? tail.endIndex
                result.replaceSubrange(hit.lowerBound..<stop, with: path)
                let next = result.index(hit.lowerBound, offsetBy: path.count)
                search = next..<result.endIndex
            }
        }
        return result
    }

    /// Перезагружать предпросмотр только тогда, когда изменилось что-то,
    /// кроме значений переменных: значения доезжают скриптом, без мигания.
    var previewReloadKey: String {
        sheet.structureKey + "\u{1}" + appliedSample.id + "\u{1}"
            + appliedSample.text + "\u{1}" + appliedSample.second + "\u{1}"
            + appliedSample.reference + "\u{1}" + appliedSample.next + "\u{1}"
            + appliedSample.songTitle + "\u{1}" + appliedSample.mode + "\u{1}"
            + String(appliedSample.pageCurrent) + "/" + String(appliedSample.pageCount)
    }

    var previewValues: [String: String] { sheet.values }

    /// Повторить показ — видно плавную смену слайда.
    func replay() {
        send("if (window.slovoPreview) window.slovoPreview.replay();")
    }

    private func send(_ script: String) {
        command = PreviewCommand(tick: command.tick + 1, script: script)
    }

    private func scheduleSampleApply() {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.appliedSample = self.sample
            }
        }
    }

    /// Взять текст с живого слайда программы.
    func takeSample(text: String, second: String, reference: String) {
        var next = WebSlideSample.fromSlide(text: text, second: second, reference: reference)
        next.next = sample.next
        sample = next
        appliedSample = next
        sampleTask?.cancel()
    }

    /// Открыть страницу в браузере — как есть, через работающий сервер.
    func openInBrowser(port: Int) {
        guard let page = current else { return }
        // Свои страницы сервер отдаёт из своей папки, авторские — из RemoteAPI.
        guard let url = URL(string: WebPageAddress.url(host: "localhost", port: port,
                                                      fileName: page.name)) else { return }
        NSWorkspace.shared.open(url)
    }
}
