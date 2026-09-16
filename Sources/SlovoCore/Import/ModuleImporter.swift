import Compression
import Foundation

// Майстер імпорту — розділ 4.2 посібника, але лише в частині даних.
//
// В оригіналі майстер сам знаходив попередню версію VisioBible і переносив
// модулі, шаблони, фони та налаштування. Тут джерелом служить будь-яка тека
// з даними або архів .zip — цим же закривається звичайне «додати модуль»:
// людина завантажила теку з bibleqt.ini чи .vbm, показала її майстру, і
// вона лягла в бібліотеку. Переносяться тільки дані: модулі й пісенники,
// шаблони слайда, фонові зображення. Налаштувань чужої програми майстер не
// переносить — у «Слова» свій файл налаштувань і свої відмінності, і чужий
// ini не має переробляти його під себе. Сам собою майстер не відкривається:
// його кличуть із меню.
//
// Розкладка — у термінах оригіналу, щоб вікно можна було звірити з
// посібником порядково: «Версія»/«Шлях» у списку версій, «Коротка
// назва»/«Повна назва» у списку модулів, «Немає»/«Застар.» у колонці стану.

// MARK: - Куди переносимо

/// Бібліотека самої програми: сюди майстер розкладає все, що переносить.
///
/// Окремий тип потрібен з однієї причини: писати в чужі дані не можна.
/// Робоча тека модулів може вказувати всередину `VisioBible.app` або в
/// пляшку CrossOver — туди майстер не пише за жодних умов, інакше імпорт
/// зіпсує встановлений оригінал.
public struct ImportDestination: Sendable, Hashable {

    public let dataRoot: URL

    public init(dataRoot: URL) { self.dataRoot = dataRoot }

    /// Дім даних програми (Application Support): перенесене лягає сюди, а
    /// бібліотека підхоплює його поіменно — через список модулів і список тек
    /// із фонами у «Параметрах».
    public static var applicationLibrary: ImportDestination {
        ImportDestination(dataRoot: DataHome.folder)
    }

    public var modulesFolder: URL { dataRoot.appendingPathComponent("Modules") }
    public var templatesFolder: URL { dataRoot.appendingPathComponent("Templates") }
    public var backgroundsFolder: URL { dataRoot.appendingPathComponent("BackGrounds") }
    public var plansFolder: URL { dataRoot.appendingPathComponent("Plans") }

    /// Дані встановленого VisioBible чіпати на запис не можна: це чужа
    /// програма й чужа копія модулів.
    public var isSafeToWrite: Bool {
        let path = dataRoot.path
        if path.contains("/VisioBible.app/") { return false }
        if path.contains("/CrossOver/Bottles/") { return false }
        if path.contains("/drive_c/") { return false }
        // Всередину будь-якої обгортки застосунку, включно з власною: файли
        // там підписані, і підкладений модуль ламає підпис усієї програми.
        if path.contains(".app/Contents/") { return false }
        return true
    }

    /// Створюємо лише корінь. Підтеки заводить саме копіювання, коли в них
    /// справді щось лягає: порожня `Modules` — пастка, бо
    /// `AppState.guessModulesFolder()` бере першу наявну теку.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }
}

// MARK: - Звідки переносимо

/// Рядок списку «Попередні версії програми» (4.2.1).
/// Колонки ті самі, що в автора: `LVVersions->Column0` «Версія»,
/// `LVVersions->Column1` «Шлях».
public struct ImportSource: Sendable, Hashable, Identifiable {

    public enum Kind: String, Sendable {
        /// Знайдена автоматично — встановлена копія програми.
        case installed
        /// Тека, вибрана руками.
        case folder
        /// Архів `.zip`, розпакований у тимчасову теку.
        case archive
    }

    /// Колонка «Версія».
    public let version: String
    /// Тека з даними: `Modules`, `Templates`, `BackGrounds`, `VisioBible.ini`.
    public let url: URL
    /// Що саме вибрав користувач. Для архіву це сам файл — його й треба
    /// показувати в колонці «Шлях», а не тимчасову теку.
    public let originURL: URL
    public let kind: Kind

    public var id: String { originURL.path }
    /// Колонка «Шлях».
    public var path: String { originURL.path }

    public init(version: String, url: URL, originURL: URL? = nil, kind: Kind) {
        self.version = version
        self.url = url
        self.originURL = originURL ?? url
        self.kind = kind
    }
}

/// Помилки майстра. Формулювання взято з `ErrorMessages0…3` форми
/// `ImportFromOldVersForm`, щоб людина, яка знає оригінал, побачила знайомий
/// текст.
public enum ImportProblem: Error, CustomStringConvertible, Sendable {
    /// `ErrorMessages0` — «В папке "%s" нет "VisioBible"». Узагальнено: у теці
    /// взагалі немає нічого, що можна перенести.
    case nothingToImport(String)
    /// `ErrorMessages1` — «В папке "%s" файл "VisioBible.ini" некорректен».
    case badConfig(String)
    /// `ErrorMessages2` — «Папка "%s" уже добавлена».
    case alreadyAdded(String)
    case unpackFailed(String, String)
    case destinationNotWritable(String)

    public var description: String {
        switch self {
        case .nothingToImport(let path):
            return OurWords.t("В папке «%s» нет ничего, что можно импортировать", "\(path)")
        case .badConfig(let path):
            return "В папке «\(path)» файл «VisioBible.ini» некорректен"
        case .alreadyAdded(let path):
            return OurWords.t("Папка «%s» уже добавлена", "\(path)")
        case .unpackFailed(let path, let reason):
            return "Не удалось распаковать «\(path)»: \(reason)"
        case .destinationNotWritable(let path):
            return OurWords.t("В папку «%s» писать нельзя: это данные установленной программы", "\(path)")
        }
    }

    /// Ключ повідомлення у формі `ImportFromOldVersForm` файла перекладу автора.
    /// У двох останніх випадків свого ключа в автора немає — їх в оригіналі
    /// не буває (майстер там не розпаковує архівів і завжди пише в теку
    /// самої програми).
    public var messageKey: String? {
        switch self {
        case .nothingToImport: return "ErrorMessages0"
        case .badConfig:       return "ErrorMessages1"
        case .alreadyAdded:    return "ErrorMessages2"
        default:               return nil
        }
    }

    /// Шлях, який підставляється на місце `%s`.
    public var path: String {
        switch self {
        case .nothingToImport(let path), .badConfig(let path),
             .alreadyAdded(let path), .destinationNotWritable(let path):
            return path
        case .unpackFailed(let path, _):
            return path
        }
    }

    /// Текст мовою інтерфейсу.
    ///
    /// Раніше тут були свої російські рядки, і за будь-якої іншої мови
    /// майстер усе одно лаявся російською. Беремо формулювання автора і
    /// підставляємо шлях на місце `%s` — так само, як це робить Delphi.
    public func localized(_ language: LanguageFile?) -> String {
        guard let key = messageKey else { return description }
        let pattern = language?.caption(key, form: "ImportFromOldVersForm", default: "") ?? ""
        guard !pattern.isEmpty else { return description }
        return Self.format(pattern, path: path)
    }

    /// Підстановка `%s` (і Delphi-варіанта `%0:s`) плюс розгортка `\n`.
    static func format(_ pattern: String, path: String) -> String {
        var text = pattern
        for placeholder in ["%0:s", "%s"] where text.contains(placeholder) {
            text = text.replacingOccurrences(of: placeholder, with: path)
            break
        }
        return text.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Будь-яка помилка майстра у вигляді тексту для людини: своя — словами
    /// автора, чужа (файлова система, розпакування) — як є.
    public static func text(for error: Error, language: LanguageFile?) -> String {
        (error as? ImportProblem)?.localized(language) ?? "\(error)"
    }
}

// MARK: - Що переносимо

/// Рядок будь-якого зі списків майстра.
public struct ImportItem: Sendable, Hashable, Identifiable {

    public enum Category: String, Sendable, CaseIterable {
        case module        // тека «Цитата з Біблії» або файл MyBible
        case songBook      // пісенник .vbm
        case template      // шаблон слайда Templates/*.sch
        case image         // фонове зображення
    }

    /// Стан того, що вже є в програмі. Підписи авторські:
    /// `TextMessages4` «Нет» і `TextMessages2` «Устар.».
    public enum Condition: String, Sendable {
        case missing       // у поточній версії цього немає
        case outdated      // те, що є, старіше за джерело
        case upToDate      // те саме або свіжіше
    }

    public let id: String
    public let category: Category
    /// Колонка «Коротка назва».
    public let title: String
    /// Колонка «Повна назва».
    public let subtitle: String
    public let sourceURL: URL
    public let destinationURL: URL
    /// Файли-супутники: `.vbi` поруч із `.vbm`, словники поруч із MyBible,
    /// тека шаблону поруч із `.sch`.
    public let companions: [URL]
    public let condition: Condition
    public let byteSize: Int64
    public let modified: Date?
    /// Чи позначено рядок. Автоматично позначаються відсутні й новіші
    /// — так написано в 4.2.2, 4.2.3 і 4.2.4.
    public var isSelected: Bool

    public init(id: String,
                category: Category,
                title: String,
                subtitle: String,
                sourceURL: URL,
                destinationURL: URL,
                companions: [URL] = [],
                condition: Condition,
                byteSize: Int64 = 0,
                modified: Date? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.companions = companions
        self.condition = condition
        self.byteSize = byteSize
        self.modified = modified
        // 4.2.2 і 4.2.3 кажуть «відсутні … або новіші», а 4.2.4 про
        // фони — лише «відсутні в поточній версії шляхи та/або
        // зображення». Різниця видна на справжніх даних: картинка, яка
        // в бібліотеці вже є, але на секунду старша за вихідну, потрапляла в
        // позначені й переносилася заново.
        switch category {
        case .image:
            self.isSelected = condition == .missing
        default:
            self.isSelected = condition != .upToDate
        }
    }
}

/// Усе, що знайшлося в джерелі, розкладене за сторінками майстра.
public struct ImportInventory: Sendable {
    public let source: ImportSource
    public var modules: [ImportItem]
    public var templates: [ImportItem]
    public var images: [ImportItem]

    /// Опис збирає `ModuleImporter.inventory(of:destination:)`, але вікно
    /// майстра перезбирає його зі своїх списків перед самим перенесенням:
    /// галочки живуть у них, і передати треба саме те, що людина позначила.
    public init(source: ImportSource,
                modules: [ImportItem],
                templates: [ImportItem],
                images: [ImportItem]) {
        self.source = source
        self.modules = modules
        self.templates = templates
        self.images = images
    }

    public var isEmpty: Bool {
        modules.isEmpty && templates.isEmpty && images.isEmpty
    }

    public var selected: [ImportItem] {
        (modules + templates + images).filter(\.isSelected)
    }

    public func selected(_ category: ImportItem.Category) -> [ImportItem] {
        selected.filter { $0.category == category }
    }
}

/// Підсумок імпорту — те, що показується після натискання «Імпортувати».
public struct ImportOutcome: Sendable {

    public struct Failure: Sendable, Hashable, Identifiable {
        public let title: String
        public let reason: String
        public var id: String { title + reason }
    }

    public var modules: [String] = []
    public var templates: [String] = []
    public var images: [String] = []
    public var failures: [Failure] = []
    /// Куди лягли перенесені модулі й пісенники — щоб програма підключила
    /// їх до списку перекладів поіменно, не перемикаючи всієї бібліотеки.
    public var importedModules: [URL] = []

    public var total: Int { modules.count + templates.count + images.count }
}

// MARK: - Сам майстер

public enum ModuleImporter {

    // MARK: 4.2.1 Пошук версій

    /// Встановлені копії програми. Шукаємо там, де вони реально лежать на
    /// macOS: у пляшці CrossOver, у теці застосунків і в підтримці застосунків.
    public static func installedVersions() -> [ImportSource] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        // Пляшки CrossOver: і дані (ProgramData), і сама установка.
        let bottles = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        for bottle in (try? fm.contentsOfDirectory(atPath: bottles.path)) ?? [] {
            let drive = bottles.appendingPathComponent(bottle).appendingPathComponent("drive_c")
            for parent in ["ProgramData", "Program Files", "Program Files (x86)", "users/crossover/Documents"] {
                let folder = drive.appendingPathComponent(parent)
                for entry in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                where entry.lowercased().hasPrefix("visiobible") {
                    candidates.append(folder.appendingPathComponent(entry))
                }
            }
        }

        // Обгортка застосунку й особиста підтримка.
        for base in [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            for entry in (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
            where entry.lowercased().hasPrefix("visiobible") {
                candidates.append(base.appendingPathComponent(entry)
                    .appendingPathComponent("Contents/Resources/app"))
            }
        }
        let support = home.appendingPathComponent("Library/Application Support")
        for entry in (try? fm.contentsOfDirectory(atPath: support.path)) ?? []
        where entry.lowercased().hasPrefix("visiobible") {
            candidates.append(support.appendingPathComponent(entry))
        }

        var seen: Set<String> = []
        var found: [ImportSource] = []
        for url in candidates {
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted, looksLikeDataFolder(resolved) else { continue }
            found.append(ImportSource(version: versionName(of: resolved), url: resolved, kind: .installed))
        }
        return found.sorted { $0.version.localizedStandardCompare($1.version) == .orderedAscending }
    }

    /// Тека, вибрана руками («Вибрати теку з попередньою версією»).
    /// Приймаємо і теку з даними, і теку одного модуля, і теку, всередині
    /// якої лежать модулі без обгортки `Modules`.
    public static func source(atFolder url: URL, existing: [ImportSource] = []) throws -> ImportSource {
        let resolved = url.resolvingSymlinksInPath()
        if existing.contains(where: { $0.url.path == resolved.path || $0.originURL.path == resolved.path }) {
            throw ImportProblem.alreadyAdded(resolved.path)
        }
        guard looksLikeDataFolder(resolved, archives: true) else { throw ImportProblem.nothingToImport(resolved.path) }
        if let config = configURL(in: resolved), (try? IniSettings(fileAt: config))?.sections.isEmpty ?? true {
            throw ImportProblem.badConfig(resolved.path)
        }
        return ImportSource(version: versionName(of: resolved), url: resolved, kind: .folder)
    }

    /// Архів `.zip`. Розпаковуємо в тимчасову теку і далі працюємо з нею
    /// як зі звичайною текою джерела.
    ///
    /// Розпакування робить системна `ditto` — вона є в будь-якій macOS, знає
    /// про кодування імен і про ресурсні вилки. Свого розпакувальника тут не
    /// потрібно: сторонніх бібліотек у проєкті немає, а Foundation zip не вміє.
    public static func source(atArchive url: URL, existing: [ImportSource] = []) throws -> ImportSource {
        if existing.contains(where: { $0.originURL.path == url.path }) {
            throw ImportProblem.alreadyAdded(url.path)
        }
        let unpacked = try unpack(url)
        // Архіви майже завжди обгорнуті в одну теку з ім'ям модуля —
        // розгортаємо її, інакше модуль ляже на рівень глибше, ніж треба.
        let root = descendIntoSingleFolder(unpacked)
        guard looksLikeDataFolder(root) else { throw ImportProblem.nothingToImport(url.path) }
        return ImportSource(version: url.deletingPathExtension().lastPathComponent,
                            url: root, originURL: url, kind: .archive)
    }

    /// Те, що вибрали у вікні вибору: тека, архів `.zip` або один файл
    /// модуля. Розбір за тим, чим це виявилося насправді, а не за
    /// розширенням в імені: користувач тягне в майстер що завгодно.
    ///
    /// Одиночний файл (`.vbm`, `.SQLite3`) джерелом сам по собі бути не
    /// може — опис будується за текою. Беремо теку, де він лежить; сам файл
    /// у ній усе одно виявиться позначеним, а заразом підхопляться сусідні.
    public static func source(at url: URL, existing: [ImportSource] = []) throws -> ImportSource {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory { return try source(atFolder: url, existing: existing) }
        if url.pathExtension.lowercased() == "zip" { return try source(atArchive: url, existing: existing) }
        return try source(atFolder: url.deletingLastPathComponent(), existing: existing)
    }

    /// «Знайти інші версії автоматично» — обхід дисків.
    ///
    /// Глибину обмежуємо: без неї обхід домашньої теки з чужими проєктами
    /// іде хвилинами, а дані програми ніколи не лежать на десятому рівні.
    /// `shouldStop` опитується на кожній теці — це кнопка «Зупинити».
    public static func searchAllDisks(shouldStop: @escaping () -> Bool = { false },
                                      progress: @escaping (String) -> Void = { _ in },
                                      found: @escaping (ImportSource) -> Void = { _ in }) -> [ImportSource] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = [home, URL(fileURLWithPath: "/Applications")]
        for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            roots.append(URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume))
        }

        var seen: Set<String> = []
        var result: [ImportSource] = []

        for root in roots {
            walk(root, depth: 0, limit: 6, shouldStop: shouldStop) { folder in
                progress(folder.path)
                guard looksLikeDataFolder(folder) else { return false }
                let resolved = folder.resolvingSymlinksInPath()
                guard seen.insert(resolved.path).inserted else { return true }
                let source = ImportSource(version: versionName(of: resolved), url: resolved, kind: .installed)
                result.append(source)
                found(source)
                // Усередину знайденої теки з даними спускатися нема чого.
                return true
            }
            if shouldStop() { break }
        }
        return result
    }

    // MARK: 4.2.2–4.2.4 Опис джерела

    /// Що можна перенести з джерела і в якому стані воно в нас.
    public static func inventory(of source: ImportSource,
                                 destination: ImportDestination) -> ImportInventory {
        ImportInventory(source: source,
                        modules: scanModules(source: source, destination: destination),
                        templates: scanTemplates(source: source, destination: destination),
                        images: scanImages(source: source, destination: destination))
    }

    // MARK: 4.2.6 Імпорт

    /// Перенесення позначеного. Кожен модуль перед копіюванням відкривається —
    /// до бібліотеки не має потрапити те, чого програма потім не прочитає.
    public static func run(_ inventory: ImportInventory,
                           destination: ImportDestination,
                           progress: @escaping (String, Double) -> Void = { _, _ in }) -> ImportOutcome {
        var outcome = ImportOutcome()

        guard destination.isSafeToWrite else {
            outcome.failures.append(.init(title: destination.dataRoot.path,
                                          reason: ImportProblem.destinationNotWritable(destination.dataRoot.path).description))
            return outcome
        }
        do { try destination.prepare() } catch {
            outcome.failures.append(.init(title: destination.dataRoot.path, reason: "\(error)"))
            return outcome
        }

        let items = inventory.selected
        let total = max(items.count, 1)

        for (index, item) in items.enumerated() {
            progress(item.title, Double(index) / Double(total))

            switch item.category {
            case .module, .songBook:
                if let reason = validate(item) {
                    outcome.failures.append(.init(title: item.title, reason: reason))
                    continue
                }
                if let error = copy(item) {
                    outcome.failures.append(.init(title: item.title, reason: error))
                } else {
                    outcome.modules.append(item.title)
                    outcome.importedModules.append(item.destinationURL)
                }

            case .template:
                if let error = copy(item) {
                    outcome.failures.append(.init(title: item.title, reason: error))
                } else {
                    outcome.templates.append(item.title)
                }

            case .image:
                if let error = copy(item) {
                    outcome.failures.append(.init(title: item.title, reason: error))
                } else {
                    outcome.images.append(item.title)
                }

            }
        }

        progress("", 1)
        return outcome
    }

    /// Перевірка, що модуль читається. Повертає причину відмови або `nil`.
    ///
    /// Читаємо не лише заголовок: заголовок цілий і в модуля, у якого немає
    /// жодного файлу книги. Справжня перевірка — відкрити перший розділ.
    public static func validate(_ item: ImportItem) -> String? {
        let url = item.sourceURL
        do {
            switch item.category {
            case .songBook:
                let book = try SongBook(fileAt: url)
                guard !book.songs.isEmpty else { return OurWords.t("в песеннике нет ни одной песни") }
                return nil

            case .module:
                let module: TextModule
                if url.hasDirectoryPath {
                    module = try BibleModule(directory: url)
                } else if MySwordModule.isBibleModuleName(url.lastPathComponent) {
                    module = try MySwordModule(fileAt: url)
                } else {
                    module = try MyBibleModule(fileAt: url)
                }
                guard let first = module.books.first else { return OurWords.t("в модуле нет ни одной книги") }
                let chapters = try module.chapters(ofBook: first)
                guard let chapter = chapters.first, !chapter.verses.isEmpty else {
                    return "первая глава книги «\(first.fullName)» пуста"
                }
                module.releaseCache()
                return nil

            default:
                return nil
            }
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Опис за розділами

    private static func scanModules(source: ImportSource, destination: ImportDestination) -> [ImportItem] {
        let fm = FileManager.default
        var items: [ImportItem] = []

        // Сама вибрана тека може бути одним модулем — так виглядає
        // завантажений окремо переклад і розпакований архів.
        if let single = moduleItem(at: source.url, destination: destination) {
            return [single]
        }

        let folder = modulesFolder(in: source.url)
        let entries = (try? fm.contentsOfDirectory(at: folder,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if let item = moduleItem(at: entry, destination: destination) {
                items.append(item)
            } else if entry.pathExtension.lowercased() == "zip" {
                items.append(contentsOf: archivedModuleItems(at: entry, destination: destination))
            }
        }
        return items
    }

    /// Модулі з архівів `.zip`, що лежать у теці джерела.
    ///
    /// Так виглядає тека завантажень: модулі «Цитати з Біблії» з GitHub
    /// приходять архівами, і людина вибирає теку, де їх кілька. Раніше майстер
    /// показував лише розпаковані модулі, а архіви мовчки пропускав
    /// (0.84, перевірка скачаної збірки). Розпаковуємо лише ті архіви, у
    /// переліку файлів яких видно модуль, — тека завантажень повна чужих zip.
    private static func archivedModuleItems(at zip: URL, destination: ImportDestination) -> [ImportItem] {
        guard archiveMentionsModule(zip), let unpacked = try? unpackedOnce(zip) else { return [] }
        let root = descendIntoSingleFolder(unpacked)
        if let single = moduleItem(at: root, destination: destination) { return [single] }
        let folder = modulesFolder(in: root)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { moduleItem(at: $0, destination: destination) }
    }

    /// Чи згадано в переліку файлів архіву модуль або пісенник. Перелік
    /// читає системна `zipinfo` — без розпакування.
    static func archiveMentionsModule(_ zip: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let listing = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).lowercased()
        let marks = ["bibleqt.ini", ".vbm", ".\(SongBookJSON.pathExtension)", ".sqlite3", ".sqlite", ".bbl.mybible"]
        return listing.split(whereSeparator: \.isNewline).contains { line in
            marks.contains { line.hasSuffix($0) }
        }
    }

    /// Розпаковані архіви цього запуску: опис джерела будується не раз
    /// (відкрили майстер, повернулися «Назад»), а розпаковувати той самий
    /// архів щоразу в нову тимчасову теку ні до чого.
    nonisolated(unsafe) private static var unpackedArchives: [String: URL] = [:]
    private static let unpackedLock = NSLock()

    private static func unpackedOnce(_ zip: URL) throws -> URL {
        let modified = (try? zip.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = zip.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        unpackedLock.lock()
        let known = unpackedArchives[key]
        unpackedLock.unlock()
        if let known, FileManager.default.fileExists(atPath: known.path) { return known }
        let fresh = try unpack(zip)
        unpackedLock.lock()
        unpackedArchives[key] = fresh
        unpackedLock.unlock()
        return fresh
    }

    /// Один рядок списку модулів — або `nil`, якщо це не модуль.
    private static func moduleItem(at url: URL, destination: ImportDestination) -> ImportItem? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

        if isDirectory {
            guard let ini = iniURL(inModule: url) else { return nil }
            // Читаємо лише шапку: повний розбір усіх книг у 96 модулів
            // займає секунди, а для списку потрібні дві назви.
            let header = moduleHeader(at: ini)
            let target = destination.modulesFolder.appendingPathComponent(name)
            return ImportItem(id: "module:" + name,
                              category: .module,
                              title: header.short.isEmpty ? name : header.short,
                              subtitle: header.full.isEmpty ? name : header.full,
                              sourceURL: url,
                              destinationURL: target,
                              condition: condition(source: ini, destination: iniURL(inModule: target) ?? target),
                              byteSize: folderSize(url),
                              modified: modificationDate(ini))
        }

        switch url.pathExtension.lowercased() {
        case "vbm":
            // Пісенник VisioBible при імпорті перетворюється у свій формат:
            // лягає як `<ім'я>.songbook`; `.vbi` (покажчик VisioBible) не
            // потрібен і не переноситься.
            let base = url.deletingPathExtension()
            let target = destination.modulesFolder
                .appendingPathComponent(base.lastPathComponent)
                .appendingPathExtension(SongBookJSON.pathExtension)
            let header = songBookHeader(at: url)
            return ImportItem(id: "song:" + name,
                              category: .songBook,
                              title: header.short.isEmpty ? base.lastPathComponent : header.short,
                              subtitle: header.full.isEmpty ? name : header.full,
                              sourceURL: url,
                              destinationURL: target,
                              condition: condition(source: url, destination: target),
                              byteSize: fileSize(url),
                              modified: modificationDate(url))

        case SongBookJSON.pathExtension:
            let target = destination.modulesFolder.appendingPathComponent(name)
            let parsed = try? SongBook(fileAt: url)
            let stem = url.deletingPathExtension().lastPathComponent
            return ImportItem(id: "song:" + name,
                              category: .songBook,
                              title: (parsed?.shortName).flatMap { $0.isEmpty ? nil : $0 } ?? stem,
                              subtitle: (parsed?.title).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                              sourceURL: url,
                              destinationURL: target,
                              condition: condition(source: url, destination: target),
                              byteSize: fileSize(url),
                              modified: modificationDate(url))

        case "sqlite3", "sqlite":
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            // Супутники MyBible віршів не містять — окремим рядком вони не
            // потрібні, але переїхати разом із модулем мають.
            let companionKinds = ["commentaries", "dictionary", "crossreferences", "subheadings", "plan", "notes"]
            guard !companionKinds.contains(where: { stem.hasSuffix(".\($0)") }) else { return nil }
            let target = destination.modulesFolder.appendingPathComponent(name)
            let siblings = (try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                        includingPropertiesForKeys: nil)) ?? []
            let companions = siblings.filter { candidate in
                let other = candidate.deletingPathExtension().lastPathComponent.lowercased()
                return other != stem && companionKinds.contains { other == "\(stem).\($0)" }
            }
            let header = myBibleHeader(at: url)
            return ImportItem(id: "mybible:" + name,
                              category: .module,
                              title: header.short.isEmpty ? url.deletingPathExtension().lastPathComponent : header.short,
                              subtitle: header.full.isEmpty ? name : header.full,
                              sourceURL: url,
                              destinationURL: target,
                              companions: companions,
                              condition: condition(source: url, destination: target),
                              byteSize: fileSize(url),
                              modified: modificationDate(url))

        case "mybible":
            // Тип модуля MySword стоїть розширенням ПЕРЕД `.mybible`. Вірші
            // є лише в `.bbl`; коментарі, словники, щоденники й особисті
            // нотатки окремим рядком не потрібні — переносити нічого.
            guard MySwordModule.isBibleModuleName(name) else { return nil }
            let target = destination.modulesFolder.appendingPathComponent(name)
            let header = mySwordHeader(at: url)
            let stem = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            return ImportItem(id: "mysword:" + name,
                              category: .module,
                              title: header.short.isEmpty ? stem : header.short,
                              subtitle: header.full.isEmpty ? name : header.full,
                              sourceURL: url,
                              destinationURL: target,
                              condition: condition(source: url, destination: target),
                              byteSize: fileSize(url),
                              modified: modificationDate(url))

        default:
            return nil
        }
    }

    private static func scanTemplates(source: ImportSource, destination: ImportDestination) -> [ImportItem] {
        let fm = FileManager.default
        let folder = source.url.appendingPathComponent("Templates")
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        return entries
            .filter { $0.pathExtension.lowercased() == "sch" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { file in
                let name = file.deletingPathExtension().lastPathComponent
                // Поруч із `<Ім'я>.sch` лежить однойменна тека з картинками —
                // без неї шаблон приїде порожнім.
                let assets = folder.appendingPathComponent(name)
                let target = destination.templatesFolder.appendingPathComponent(file.lastPathComponent)
                return ImportItem(id: "template:" + name,
                                  category: .template,
                                  title: name,
                                  subtitle: schemeDescription(of: file),
                                  sourceURL: file,
                                  destinationURL: target,
                                  companions: fm.fileExists(atPath: assets.path) ? [assets] : [],
                                  condition: condition(source: file, destination: target),
                                  byteSize: fileSize(file) + folderSize(assets),
                                  modified: modificationDate(file))
            }
    }

    /// 4.2.4: фонові зображення з тек джерела (`TextMessages7` «Файл»);
    /// шляхи самі по собі не переносяться — їх заводить програма.
    private static func scanImages(source: ImportSource, destination: ImportDestination) -> [ImportItem] {
        let fm = FileManager.default
        var items: [ImportItem] = []
        var folders: [(raw: String, url: URL?)] = []

        // Шляхи з [PicturePath] вихідного ini.
        if let config = configURL(in: source.url), let ini = try? IniSettings(fileAt: config) {
            let section = ini.sections["PicturePath"] ?? [:]
            for key in section.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                guard let raw = section[key], let entry = PicturePathEntry(rawValue: raw) else { continue }
                folders.append((entry.path, resolve(windowsPath: entry.path, relativeTo: source.url)))
            }
        }
        // Тека BackGrounds є навіть там, де ini немає.
        let backgrounds = source.url.appendingPathComponent("BackGrounds")
        if fm.fileExists(atPath: backgrounds.path),
           !folders.contains(where: { $0.url?.path == backgrounds.path }) {
            folders.append(("BackGrounds\\", backgrounds))
        }

        let allowed: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "heic", "webp"]
        var seen: Set<String> = []
        for folder in folders {
            guard let url = folder.url else { continue }
            let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard allowed.contains(file.pathExtension.lowercased()),
                      seen.insert(file.lastPathComponent.lowercased()).inserted else { continue }
                let target = destination.backgroundsFolder.appendingPathComponent(file.lastPathComponent)
                items.append(ImportItem(id: "image:" + file.lastPathComponent,
                                        category: .image,
                                        title: file.lastPathComponent,
                                        subtitle: folder.raw,
                                        sourceURL: file,
                                        destinationURL: target,
                                        condition: condition(source: file, destination: target),
                                        byteSize: fileSize(file),
                                        modified: modificationDate(file)))
            }
        }
        return items
    }

    // MARK: - Копіювання

    /// Копіювання із заміною. Спершу в тимчасове ім'я поруч, потім підміна —
    /// інакше перерваний імпорт лишить на місці робочого модуля половину.
    private static func copy(_ item: ImportItem) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: item.destinationURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if item.category == .songBook, item.sourceURL.pathExtension.lowercased() == "vbm" {
                try convertSongBook(from: item.sourceURL, to: item.destinationURL)
                return nil
            }
            try replace(from: item.sourceURL, to: item.destinationURL)

            for companion in item.companions {
                let target = item.destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(companion.lastPathComponent)
                try replace(from: companion, to: target)
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Пісенник VisioBible → свій формат: розібрати `.vbm` і записати
    /// `.songbook`. Відкрито — щоб перевірка йшла тим самим шляхом, що й
    /// майстер.
    public static func convertSongBook(from source: URL, to destination: URL) throws {
        let book = try SongBook(fileAt: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try SongBookJSON.write(book, to: destination)
    }

    private static func replace(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        // Шлях до самого себе — джерело вже лежить там, куди його переносять.
        guard source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path else { return }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".slovo-import-" + UUID().uuidString)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try? fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Дрібниці

    /// Чи схоже на теку з даними: є модулі, шаблони, фони або ini.
    /// - Parameter archives: зважати й на архіви `.zip` із модулями. Лише для
    ///   теки, вибраної руками: обхід дисків відкривав би кожен zip у домашній
    ///   теці.
    public static func looksLikeDataFolder(_ url: URL, archives: Bool = false) -> Bool {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false else { return false }
        if iniURL(inModule: url) != nil { return true }
        for name in ["Modules", "Templates", "BackGrounds", "VisioBible.ini", "VisioBible.exe"]
        where fm.fileExists(atPath: url.appendingPathComponent(name).path) { return true }
        // Гола тека з модулями чи пісенниками — теж джерело.
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        // `.songbook` — свій формат пісенника: тека лише з ними раніше
        // відкидалася як «нічого імпортувати».
        let fileKinds = ["vbm", SongBookJSON.pathExtension, "sqlite3", "sqlite", "mybible"]
        if entries.contains(where: { fileKinds.contains($0.pathExtension.lowercased()) || iniURL(inModule: $0) != nil }) {
            return true
        }
        guard archives else { return false }
        return entries.contains { $0.pathExtension.lowercased() == "zip" && archiveMentionsModule($0) }
    }

    /// Ім'я версії для колонки «Версія»: з ini, інакше з імені теки.
    private static func versionName(of url: URL) -> String {
        var name = url.lastPathComponent
        // В обгортки застосунку ім'я даних беззмістовне — беремо ім'я програми.
        if name == "app" || name == "Resources" || name == "Contents" {
            name = url.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingPathExtension().lastPathComponent
        }
        if let config = configURL(in: url), let ini = try? IniSettings(fileAt: config),
           let version = ini.string("Version", in: "settings") ?? ini.string("ProgramVersion", in: "settings") {
            return "\(name) \(version)"
        }
        return name
    }

    private static func configURL(in root: URL) -> URL? {
        let url = root.appendingPathComponent("VisioBible.ini")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func modulesFolder(in root: URL) -> URL {
        let nested = root.appendingPathComponent("Modules")
        return FileManager.default.fileExists(atPath: nested.path) ? nested : root
    }

    private static func iniURL(inModule directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let name = contents.first(where: { $0.lowercased() == "bibleqt.ini" }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Дві назви модуля без розбору всіх книг.
    private static func moduleHeader(at ini: URL) -> (short: String, full: String) {
        guard let data = try? Data(contentsOf: ini) else { return ("", "") }
        // Вистачає перших кілобайтів: BibleName і BibleShortName стоять у шапці,
        // а далі йдуть сотні рядків зі списком книг.
        let text = CodePage.decode(data.prefix(4096), declared: String(data: data.prefix(4096), encoding: .utf8) != nil ? .utf8 : nil)
        var short = "", full = ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "bibleshortname" { short = value }
            if key == "biblename" { full = value }
        }
        return (short, full)
    }

    /// Дві назви пісенника без розбору самих пісень.
    ///
    /// Повний `SongBook(fileAt:)` по 23 збірниках із теки оригіналу працює
    /// понад шість секунд: у «Піснях Відродження» три тисячі пісень, і всі вони
    /// розбираються заради двох рядків у колонках списку. Тут розпаковується
    /// лише початок потоку — `compression_decode_buffer` заповнює буфер і
    /// зупиняється, — а з нього читаються п'ять перших рядків і число пісень.
    /// На тих самих файлах це 13 мілісекунд замість 6,6 секунди.
    private static func songBookHeader(at url: URL) -> (short: String, full: String) {
        guard let head = songBookHead(of: url) else { return ("", "") }
        var reader = HeadReader(head)
        let title = reader.string()
        let short = reader.string()
        _ = reader.string()          // видавець
        _ = reader.string()          // дата правки
        _ = reader.string()          // примітка
        let count = Int(reader.uint32())

        guard !title.isEmpty || !short.isEmpty else { return ("", "") }
        // Числу пісень довіряємо лише правдоподібному: якщо початок потоку
        // прочитався не так, краще показати одну назву, ніж «пісень 4 млрд».
        let sane = count > 0 && count < 100_000
        let full = title.isEmpty ? url.lastPathComponent : title
        return (short, sane ? "\(full) — песен \(count)" : full)
    }

    /// Початок розпакованого потоку пісенника (не більше 16 КБ).
    private static func songBookHead(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count > 24,
              data.prefix(16) == Data("VisioBibleModule".utf8) else { return nil }

        // Розкладка шапки та сама, що читає `SongBook`: за зсувом 20 —
        // довжина стиснутого блоку, сам блок лежить у хвості перед контрольною
        // сумою і починається двома байтами заголовка zlib.
        let compressedSize = Int(littleEndian32(data, at: 20))
        let start = data.count - 4 - compressedSize
        guard start > 16, start < data.count else { return nil }
        let raw = Data(data[(data.startIndex + start)...]).dropFirst(2)

        let capacity = 1 << 14
        return raw.withUnsafeBytes { input -> Data? in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = compression_decode_buffer(destination, capacity,
                                                    source, raw.count, nil, COMPRESSION_ZLIB)
            // Обрізаний вивід тут не біда — шапка вкладається в перші
            // сотні байтів, а хвіст потоку нам і не потрібен.
            guard written > 0 else { return nil }
            return Data(bytes: destination, count: written)
        }
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }

    /// Читання шапки пісенника: рядки в UTF-16LE із довжиною в UInt16 попереду.
    /// Свій, бо `BinaryReader` із `SongBook.swift` закритий файлом.
    private struct HeadReader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func uint32() -> UInt32 {
            guard offset + 4 <= bytes.count else { offset = bytes.count; return 0 }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        mutating func string() -> String {
            guard offset + 2 <= bytes.count else { offset = bytes.count; return "" }
            let characters = Int(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            offset += 2
            let length = characters * 2
            guard characters > 0, offset + length <= bytes.count else {
                offset = min(offset + max(0, length), bytes.count)
                return ""
            }
            var units: [UInt16] = []
            units.reserveCapacity(characters)
            for step in stride(from: offset, to: offset + length, by: 2) {
                units.append(UInt16(bytes[step]) | UInt16(bytes[step + 1]) << 8)
            }
            offset += length
            return String(decoding: units, as: UTF16.self)
        }
    }

    private static func myBibleHeader(at url: URL) -> (short: String, full: String) {
        guard let module = try? MyBibleModule(fileAt: url) else { return ("", "") }
        defer { module.releaseCache() }
        return (module.info.shortName, module.info.name)
    }

    private static func mySwordHeader(at url: URL) -> (short: String, full: String) {
        guard let module = try? MySwordModule(fileAt: url) else { return ("", "") }
        defer { module.releaseCache() }
        return (module.info.shortName, module.info.name)
    }

    /// Короткий опис шаблону для колонки «Повна назва».
    private static func schemeDescription(of file: URL) -> String {
        guard let scheme = try? SchemeParser.scheme(contentsOf: file) else { return file.lastPathComponent }
        return OurWords.t("объектов %s", "\(scheme.elements.count)")
    }

    private static func condition(source: URL, destination: URL) -> ImportItem.Condition {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return .missing }
        guard let left = modificationDate(source), let right = modificationDate(destination) else { return .upToDate }
        // Секунда допуску: копіювання не зберігає часу з точністю до
        // мікросекунд, і без допуску все виглядає «новішим».
        return left.timeIntervalSince(right) > 1 ? .outdated : .upToDate
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in items { total += fileSize(item) }
        return total
    }

    /// Шлях з ini у наш: `BackGrounds\` поруч із джерелом, `Z:\…` — корінь
    /// диска під CrossOver, усе інше — як є, якщо таке є на диску.
    private static func resolve(windowsPath raw: String, relativeTo root: URL) -> URL? {
        let fm = FileManager.default
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/")
        if cleaned.count > 2, cleaned.dropFirst().hasPrefix(":/") {
            let tail = String(cleaned.dropFirst(3))
            let candidates = [URL(fileURLWithPath: "/" + tail),
                              fm.homeDirectoryForCurrentUser.appendingPathComponent(tail)]
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }
        let url = cleaned.hasPrefix("/") ? URL(fileURLWithPath: cleaned) : root.appendingPathComponent(cleaned)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Обхід дерева з обмеженням глибини і правом зупинитися.
    /// `visit` повертає `true`, якщо всередину цієї теки заходити не треба.
    private static func walk(_ url: URL, depth: Int, limit: Int,
                             shouldStop: () -> Bool, visit: (URL) -> Bool) {
        if shouldStop() || depth > limit { return }
        if depth > 0, visit(url) { return }

        let skipped: Set<String> = ["Library", "node_modules", ".git", ".build", "System",
                                    "Photos Library.photoslibrary", "Music", "Pictures"]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        for entry in entries {
            if shouldStop() { return }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            // Обгортки застосунків пропускаємо як теки, але всередину VisioBible.app
            // зазирнути треба — там і лежать його дані.
            let name = entry.lastPathComponent
            if entry.pathExtension == "app", !name.lowercased().hasPrefix("visiobible") { continue }
            if depth == 0, skipped.contains(name), !name.lowercased().hasPrefix("visiobible") {
                // Домашня Library — єдиний виняток: там пляшки.
                if name == "Library" {
                    walk(entry.appendingPathComponent("Application Support"), depth: depth + 1,
                         limit: limit, shouldStop: shouldStop, visit: visit)
                }
                continue
            }
            walk(entry, depth: depth + 1, limit: limit, shouldStop: shouldStop, visit: visit)
        }
    }

    // MARK: - Архів

    private static func unpack(_ archive: URL) throws -> URL {
        let fm = FileManager.default
        // Усередині тимчасової теки — тека з ім'ям архіву: архів без обгортки
        // (bibleqt.ini одразу в корені) інакше ліг би модулем з ім'ям
        // «slovo-import-<UUID>».
        let target = fm.temporaryDirectory
            .appendingPathComponent("slovo-import-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--sequesterRsrc", archive.path, target.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        do { try process.run() } catch {
            throw ImportProblem.unpackFailed(archive.lastPathComponent, "\(error)")
        }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportProblem.unpackFailed(archive.lastPathComponent,
                                             message.isEmpty ? "код \(process.terminationStatus)" : message)
        }
        return target
    }

    /// Архів майже завжди обгорнутий в одну теку — спускаємося всередину, поки
    /// вкладення єдине і саме не є модулем.
    private static func descendIntoSingleFolder(_ url: URL) -> URL {
        var current = url
        for _ in 0..<4 {
            if iniURL(inModule: current) != nil { return current }
            let entries = ((try? FileManager.default.contentsOfDirectory(at: current,
                                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.lastPathComponent != "__MACOSX" }
            guard entries.count == 1,
                  (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false else { return current }
            current = entries[0]
        }
        return current
    }
}
