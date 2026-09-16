import AppKit
import SlovoCore

/// Стан вікна «Параметри» (розділ 6.1 посібника).
///
/// Початкові значення читаємо з файлів умовчань програми — `Slovo.ini` і
/// `hotkeys.ini` у пакеті, — а пишемо у свій файл у особистій теці. Пакет
/// підписаний і на запис закритий, та й умовчання мають лишатися умовчаннями:
/// те, що людина обрала, живе окремо й переживає будь-яке оновлення пакета.
/// Формат свого файла повторює модель `SlovoSettings`.
///
/// Сховище спільне на всю програму (`shared`), бо колірною легендою частин
/// пісень (6.4) користується список пісень у головному вікні, а не лише
/// вікно налаштувань.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    @Published var settings: SlovoSettings
    /// Снимки на момент открытия окон правки: «Отмена» возвращает верхний.
    ///
    /// Не одно значение, а стопка: 6.4 «Цветовая легенда частей песен» —
    /// самостоятельное окно с собственными «Ок» и «Отмена», и его отмена не
    /// должна откатывать правки, сделанные в открытом рядом окне «Параметры».
    private var snapshots: [SlovoSettings] = []

    /// Тека з даними програми — та, де лежать Modules, Templates і BackGrounds.
    private(set) var dataRoot: URL
    /// Звідки прочитано файл умовчань `Slovo.ini`; nil — файла немає.
    @Published private(set) var configPath: String?

    // Поиск совместимых текстов (кнопка 29 на вкладке «Модули»).
    @Published private(set) var isSearching = false
    @Published private(set) var scannedFolders = 0
    @Published private(set) var foundTexts: [ModuleRosterEntry] = []
    private var searchTask: Task<Void, Never>?

    private init() {
        let root = (Defaults.modulesFolder ?? AppState.guessModulesFolder()).deletingLastPathComponent()
        dataRoot = root
        settings = SettingsStore.read(dataRoot: root)
        configPath = IniSettings.locateConfig()?.path
    }

    // MARK: - Чтение и запись

    /// Власний файл налаштувань. У теці даних йому не місце — вона може бути
    /// всередині пакета програми або взагалі закрита на запис.
    static var storageURL: URL {
        DataHome.folder.appendingPathComponent("settings.json")
    }

    private static func read(dataRoot: URL) -> SlovoSettings {
        if let data = try? Data(contentsOf: storageURL),
           var saved = try? JSONDecoder().decode(SlovoSettings.self, from: data) {
            // Список веб-сторінок одного разу зберігся порожнім (файл із BOM
            // не читався) — і відтоді був би порожнім назавжди. Порожньо —
            // перечитуємо з теки даних, а немає й там — беремо комплект.
            if saved.webSlides.isEmpty {
                saved.webSlides = SlovoSettings.readWebSlides(dataRoot: dataRoot)
            }
            if saved.webSlides.isEmpty { saved.webSlides = SlovoSettings.builtInWebSlides }
            return saved
        }
        // Першого разу — з файла умовчань програми: він привозить шрифти,
        // кольори, порядок перекладів і порти так, як їх вивірено під зал.
        let config = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }
        var fresh = SlovoSettings(config: config, hotkeySets: HotkeySets.load(), dataRoot: dataRoot)
        if fresh.webSlides.isEmpty { fresh.webSlides = SlovoSettings.builtInWebSlides }
        return fresh
    }

    /// Перечитать настройки для другой папки данных — например, когда
    /// пользователь сменил папку с модулями.
    func reload(dataRoot root: URL) {
        guard root != dataRoot || settings.modules.isEmpty else { return }
        dataRoot = root
        settings = SettingsStore.read(dataRoot: root)
        snapshots.removeAll()
        configPath = IniSettings.locateConfig()?.path
    }

    /// Идёт ли сейчас правка — по ней окно понимает, надо ли откатывать при
    /// закрытии крестиком.
    var isEditing: Bool { !snapshots.isEmpty }

    /// Метка открытой правки.
    ///
    /// Ею окно доказывает, что откатывает свой снимок, а не чужой. Окна 6.1
    /// «Параметры» и 6.4 «Цветовая легенда» открываются независимо друг от
    /// друга, и без метки «Ок» в одном снимал слой другого: цвета сохранялись,
    /// а закрытие окна следом откатывало заодно и все правки в «Параметрах».
    struct EditSession: Equatable {
        fileprivate let depth: Int
    }

    /// Запомнить состояние на входе в окно — чтобы «Отмена» было чем откатить.
    @discardableResult
    func beginEditing() -> EditSession {
        snapshots.append(settings)
        return EditSession(depth: snapshots.count)
    }

    /// «Отмена» (BBCancel): вернуть всё, как было при открытии окна.
    func cancel(_ session: EditSession? = nil) {
        guard let previous = pop(session) else { return }
        settings = previous
    }

    /// Окно закрыли крестиком — считаем это отменой: незаписанные правки в
    /// оригинале тоже пропадают, а лишний слой снимков остался бы навсегда.
    func cancelIfEditing(_ session: EditSession? = nil) {
        guard isOpen(session) else { return }
        cancel(session)
    }

    /// Жив ли ещё слой этого окна.
    private func isOpen(_ session: EditSession?) -> Bool {
        guard let session else { return !snapshots.isEmpty }
        return snapshots.count >= session.depth
    }

    /// Снять слой окна вместе со всем, что легло поверх.
    ///
    /// Поверх может лежать слой окна, открытого позже: если закрывают то, что
    /// снизу, верхнему слою всё равно не к чему возвращаться.
    private func pop(_ session: EditSession?) -> SlovoSettings? {
        guard let session else { return snapshots.popLast() }
        guard snapshots.count >= session.depth else { return nil }
        while snapshots.count > session.depth { snapshots.removeLast() }
        return snapshots.popLast()
    }

    /// «Ок» (BBOk): записать настройки и разослать их тем, кто на них живёт.
    func save(_ session: EditSession? = nil) {
        _ = pop(session)
        // На диск пишет только последнее закрывшееся окно правки. Вложенное
        // «Ок» отдаёт значения наружу и на этом останавливается: иначе
        // «Отмена» внешнего окна откатила бы память, а в файле остались бы
        // новые значения — и после перезапуска они бы вернулись.
        guard snapshots.isEmpty else { return }

        let url = SettingsStore.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { try? data.write(to: url, options: .atomic) }

        // Клавиши вкладки (6.1.6) отдаём тем, кто их ловит. Раньше и `DeskModel`,
        // и перехватчик плеера читали `hotkeys.ini` оригинала сами, поэтому
        // переназначенная в окне клавиша не работала до конца жизни программы —
        // а точнее, не работала никогда.
        EffectiveHotkeys.adopt(sets: settings.hotkeySets, setName: settings.hotkeySetName)

        // Полосу переводов и палитру песен перестраивает главное окно: у него
        // свои списки модулей, и лезть в них отсюда нельзя.
        NotificationCenter.default.post(name: .slovoSettingsChanged, object: nil)
    }

    /// Записати налаштування поза вікном «Параметри» — так робить майстер
    /// імпорту, коли підключає перенесені модулі й фони.
    ///
    /// Поки вікно правки відкрите, на диск не пишемо: його «Ок» запише все
    /// разом, а «Скасувати» відкотить — включно з тим, що додав майстер.
    func saveOutsideEditing() {
        guard snapshots.isEmpty else { return }
        save()
    }

    // MARK: - Скидання, вивезення та ввезення

    /// Розділ налаштувань — вкладка вікна «Параметри».
    ///
    /// Власник: «додати функцію скидання всіх налаштувань за умовчанням і
    /// також для кожного пункту налаштувань окремий скид». Скидати все —
    /// просто: беремо той самий стан, з яким програма запускається вперше.
    /// А щоб скинути одну вкладку, треба знати, що на ній лежить, — звідси
    /// перелік імен.
    enum Area: String, CaseIterable {
        case slide, media, paths, update, remote, basic, advanced, modules, hotkeys

        /// Назва розділу для запитання «Скинути…?».
        var title: String {
            switch self {
            case .slide:    return OurWords.t("Слайд")
            case .media:    return OurWords.t("Медиа")
            case .paths:    return OurWords.t("Пути")
            case .update:   return OurWords.t("Обновление")
            case .remote:   return OurWords.t("Remote API")
            case .basic:    return OurWords.t("Основные")
            case .advanced: return OurWords.t("Дополнительные")
            case .modules:  return OurWords.t("Модули")
            case .hotkeys:  return OurWords.t("Горячие клавиши")
            }
        }

        /// Імена значень, які правлять на цій вкладці. Імена ті самі, що й у
        /// файлі налаштувань: розділ скидається підміною цих ключів.
        var optionKeys: [String] {
            switch self {
            case .slide:
                return ["crossfadeTime", "pointerColour", "pointerNDI", "pointerOpacity",
                        "pointerProjector", "pointerSize", "refAllMain", "refAllSec", "refMain",
                        "refSec", "refsSeparated", "showTransition", "showTransitionEasing",
                        "showTransitionTime", "slideTransition", "slideTransitionEasing",
                        "songDotAfterNumber", "songNumberInBrackets", "songNumberInCollection",
                        "songNumberPP"]
            case .media:
                return ["audioDeviceID", "ndiAudioGainDb", "ndiEnabled", "ndiFrameHeight",
                        "ndiFrameRate", "ndiFrameRateIndex", "ndiSendAudio", "ndiSendVideo",
                        "ndiTransparentBackground", "ndiTransport", "ndiWiFiEnabled",
                        "ndiWiFiFrameRate", "ndiWiFiHeight", "showVideoOnPreview",
                        "webVideoEnabled", "webVideoHeight", "webVideoKbps"]
            case .paths:
                return ["thumbsMode"]
            case .update:
                return ["updateInterval"]
            case .remote:
                return ["remoteEnabled", "remotePin", "remotePort", "remoteWebEnabled",
                        "remoteWebName", "remoteWebNoPort", "remoteWebPassword", "remoteWebPort",
                        "remoteWebViewOnly", "tcpEnabled", "tcpPort", "udpEnabled", "udpPort",
                        "webEnabled", "webNetInterface", "webPort", "webSocketEnabled",
                        "webSocketPort"]
            case .basic:
                return ["animationFrequency", "buttonAction", "customHeight", "customLeft",
                        "customTop", "customWidth", "defaultHeight", "defaultWidth", "foreground",
                        "monitorIndex", "percentFillingPage", "slovoTitle"]
            case .advanced:
                return ["activeInputFieldColor", "doubleMonitors", "fastInputUseBackSpace",
                        "hideSlideTime", "separatorTenVerses", "showSecondaryVerseNumbers",
                        "showVerseNumbers", "songsEndMarker", "versesOnOwnLines"]
            case .modules:
                return ["lazyLoadModules", "loadAllBooks"]
            case .hotkeys:
                return ["useRCPointer"]
            }
        }
    }

    /// Налаштування за умовчанням — ті, з якими програма запускається вперше:
    /// з файла умовчань автора, вивірених під зал.
    func factorySettings() -> SlovoSettings {
        let config = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }
        var fresh = SlovoSettings(config: config, hotkeySets: HotkeySets.load(), dataRoot: dataRoot)
        if fresh.webSlides.isEmpty { fresh.webSlides = SlovoSettings.builtInWebSlides }
        return fresh
    }

    /// Скинути все до умовчань.
    func resetAll() {
        settings = factorySettings()
    }

    /// Скинути одну вкладку, не чіпаючи решти.
    func reset(_ area: Area) {
        let fresh = factorySettings()
        settings.options = Self.merge(settings.options, taking: area.optionKeys, from: fresh.options)
        // Списки, які живуть на вкладці своїм життям, а не в `options`.
        switch area {
        case .modules: settings.modules = fresh.modules
        case .paths:
            settings.picturePaths = fresh.picturePaths
            settings.screenshotFolder = fresh.screenshotFolder
        case .remote: settings.webSlides = fresh.webSlides
        case .hotkeys:
            settings.hotkeySets = fresh.hotkeySets
            settings.hotkeySetName = fresh.hotkeySetName
        default: break
        }
    }

    /// Підміна названих значень — через той самий запис, яким налаштування
    /// лягають у файл: іменами полів, без переліку типів.
    private static func merge(_ current: ProgramOptions, taking keys: [String],
                              from fresh: ProgramOptions) -> ProgramOptions {
        let encoder = JSONEncoder()
        guard let currentData = try? encoder.encode(current),
              let freshData = try? encoder.encode(fresh),
              var currentBox = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any],
              let freshBox = (try? JSONSerialization.jsonObject(with: freshData)) as? [String: Any]
        else { return current }
        for key in keys {
            // Немає в умовчаннях — значить, значення там порожнє: прибираємо.
            if let value = freshBox[key] { currentBox[key] = value } else { currentBox.removeValue(forKey: key) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: currentBox),
              let result = try? JSONDecoder().decode(ProgramOptions.self, from: data)
        else { return current }
        return result
    }

    /// Вивезти налаштування одним файлом — перенести на інший комп'ютер або
    /// відкласти перед правкою.
    func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    /// Ввезти налаштування з файла. Чужий або зіпсований файл кидає помилку —
    /// і тоді нічого не міняється.
    func importSettings(from url: URL) throws {
        let incoming = try JSONDecoder().decode(SlovoSettings.self, from: try Data(contentsOf: url))
        settings = incoming
    }

    // MARK: - Вкладка «Модули» (6.1.4)

    /// Звести список модулів із тим, що справді лежить у теці й відкрилося:
    /// рядки з умовчань, яких на диску нема (у збірці «лише програма» це
    /// вісімдесят імен VisioBible), — геть; пісенник, що став `.songbook`, —
    /// під новим ім'ям; установлене з ресурсів, чого в списку не було, — в
    /// кінець. Шляхи ПОЗА текою даних (зовнішній диск) не чіпаємо: диск
    /// може бути просто не під'єднаний. Власник: «в списке модулей есть имя
    /// модуля, который должен был загрузиться, но физически его нет».
    @discardableResult
    func syncModuleRoster(libraryIdentifiers: Set<String>, songBookStems: Set<String>,
                          modulesFolder: URL, dataRoot: URL) -> Bool {
        let fm = FileManager.default
        var roster = settings.modules
        let before = roster
        // Пісенник .vbm, який уже .songbook.
        for index in roster.indices where roster[index].name.lowercased().hasSuffix(".vbm") {
            let url = roster[index].resolvedURL(dataRoot: dataRoot)
            let own = url.deletingPathExtension().appendingPathExtension(SongBookJSON.pathExtension)
            if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: own.path) {
                roster[index].path = String(roster[index].path.dropLast(3)) + SongBookJSON.pathExtension
                roster[index].name = own.lastPathComponent
            }
        }
        // Відносні рядки без файла.
        roster.removeAll { entry in
            !entry.path.hasPrefix("/") && !fm.fileExists(atPath: entry.resolvedURL(dataRoot: dataRoot).path)
        }
        // Установлене, чого нема в списку.
        var known = Set(roster.map { $0.libraryIdentifier.lowercased() })
        for entry in roster where entry.isSongBook {
            known.insert((entry.name as NSString).deletingPathExtension.lowercased())
        }
        let prefix = modulesFolder.lastPathComponent
        let entries = ((try? fm.contentsOfDirectory(at: modulesFolder, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in entries {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let candidate = ModuleRosterEntry(path: prefix + "\\" + name + (isDirectory ? "\\" : ""), name: name, isEnabled: true)
            let key = candidate.isSongBook ? (name as NSString).deletingPathExtension.lowercased() : candidate.libraryIdentifier.lowercased()
            guard !known.contains(key) else { continue }
            let belongs = candidate.isSongBook ? songBookStems.contains(key) : libraryIdentifiers.contains(key)
            guard belongs else { continue }
            roster.append(candidate)
            known.insert(key)
        }
        guard roster != before else { return false }
        settings.modules = roster
        return true
    }

    func setModule(_ id: String, enabled: Bool) {
        guard let index = settings.modules.firstIndex(where: { $0.id == id }) else { return }
        settings.modules[index].isEnabled = enabled
    }

    /// (24) и (25) — пометить все / снять пометку со всех.
    func setAllModules(enabled: Bool) {
        for index in settings.modules.indices { settings.modules[index].isEnabled = enabled }
    }

    /// (27) и (28) — перемещение строки вверх и вниз. Порядок этого списка —
    /// это порядок вкладок переводов в главном окне, поэтому он и правится.
    func moveModule(_ id: String, by delta: Int) -> String? {
        guard let index = settings.modules.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + delta
        guard settings.modules.indices.contains(target) else { return nil }
        settings.modules.swapAt(index, target)
        return id
    }

    /// Поміняти місцями два рядки списку.
    ///
    /// «↑» і «↓» у вкладці міняють сусідів по вигляду списку, а він тепер
    /// поділений на розділи: сусід на екрані й сусід у розписі — не завжди
    /// один рядок, тому переставляємо за іменами, а не за зсувом.
    func swapModules(_ first: String, _ second: String) {
        guard let a = settings.modules.firstIndex(where: { $0.id == first }),
              let b = settings.modules.firstIndex(where: { $0.id == second }) else { return }
        settings.modules.swapAt(a, b)
    }

    /// Что не так с выбранным для добавления модулем — сообщения автора.
    ///
    /// Своих формулировок здесь нет: под каждый случай в форме `SettingsForm`
    /// уже заведена строка, и оператор, знающий оригинал, увидит ту же.
    enum ModuleProblem {
        /// TextMessages6 — в папке нет `bibleqt.ini`.
        case notBibleQuote
        /// TextMessages38 «Не поддерживается» — спутник модуля MySword:
        /// комментарий, словарь, дневник или личные заметки. Сам перевод
        /// (`*.bbl.mybible`) программа открывает, а в этих файлах стихов нет.
        case mySword
        /// TextMessages28 «Не удается открыть модуль» — всё остальное.
        case unknownFormat
        /// Такой путь в списке уже есть.
        case alreadyListed
    }

    /// (26) — добавить модуль. Папку «Цитаты из Библии» или файл песенника
    /// подключаем там, где он лежит: копировать чужие файлы к себе — это уже
    /// не настройка, а перенос данных.
    ///
    /// Возвращает причину отказа или `nil`, если строка добавлена. Молча
    /// класть в список битую строку нельзя: у неё в колонке «Индекс» встанет
    /// «Нет», модуль никогда не откроется, и человек об этом не узнает.
    @discardableResult
    func addModule(at url: URL) -> ModuleProblem? {
        if let problem = SettingsStore.problem(with: url) { return problem }
        let entry = ModuleRosterEntry(path: relativePath(of: url),
                                      name: url.lastPathComponent,
                                      isEnabled: true)
        guard !settings.modules.contains(where: { $0.path == entry.path }) else { return .alreadyListed }
        settings.modules.append(entry)
        return nil
    }

    /// Опознание формата по тому же признаку, по какому его потом открывает
    /// `ModuleLibrary`: папка — по наличию `bibleqt.ini`, файл — по расширению.
    static func problem(with url: URL) -> ModuleProblem? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unknownFormat }

        if isDirectory.boolValue {
            let contents = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            return contents.contains { $0.lowercased() == "bibleqt.ini" } ? nil : .notBibleQuote
        }

        let name = url.lastPathComponent.lowercased()
        // MySword держит перевод в файле `*.bbl.mybible` — такой открываем.
        if name.hasSuffix(".bbl.mybible") { return nil }
        // Прочие `.mybible` — комментарии, словари, дневники, заметки — и
        // `.bbl` самого e-Sword стихов не содержат.
        if name.hasSuffix(".mybible") || name.hasSuffix(".bbl") { return .mySword }

        switch url.pathExtension.lowercased() {
        case "vbm", "sqlite3", "sqlite": return nil
        default: return .unknownFormat
        }
    }

    func removeModule(_ id: String) {
        settings.modules.removeAll { $0.id == id }
    }

    /// (29) «Найти совместимые тексты»: обходим выбранную папку и собираем
    /// всё, что программа умеет открыть, — папки с `bibleqt.ini`, модули
    /// MyBible и песенники `.vbm`.
    func searchTexts(in folder: URL) {
        searchTask?.cancel()
        isSearching = true
        scannedFolders = 0
        foundTexts = []

        searchTask = Task { [weak self] in
            guard let self else { return }
            let root = folder
            // Обход диска синхронный и живёт в отдельной функции: перебирать
            // каталоги прямо в асинхронном замыкании нельзя — итератор
            // `DirectoryEnumerator` из такого контекста недоступен.
            let found = await Task.detached(priority: .userInitiated) {
                SettingsStore.scanForTexts(in: root)
            }.value

            self.foundTexts = found.entries
            self.scannedFolders = found.folders
            self.isSearching = false
        }
    }

    /// Синхронный обход папки: возвращает найденные модули и число
    /// просмотренных каталогов — счётчики (Label14) и (Label15) оригинала.
    nonisolated static func scanForTexts(in root: URL) -> (entries: [ModuleRosterEntry], folders: Int) {
        var entries: [ModuleRosterEntry] = []
        var folders = 0
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return ([], 0) }
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                folders += 1
                let ini = url.appendingPathComponent("bibleqt.ini")
                if manager.fileExists(atPath: ini.path) {
                    entries.append(ModuleRosterEntry(path: url.path,
                                                     name: url.lastPathComponent,
                                                     isEnabled: true))
                    // Внутрь модуля «Цитаты из Библии» лезть незачем: там
                    // сотни html-файлов одной и той же книги.
                    walker.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            // У MySword в одном расширении лежат и переводы, и комментарии,
            // и заметки: в список кладём только `*.bbl.mybible` — остальное
            // никогда не откроется и встанет строкой с «Индекс: Нет».
            if ext == "mybible", !url.lastPathComponent.lowercased().hasSuffix(".bbl.mybible") { continue }
            if ext == "vbm" || ext == "sqlite3" || ext == "mybible" {
                entries.append(ModuleRosterEntry(path: url.path,
                                                 name: url.lastPathComponent,
                                                 isEnabled: true))
            }
        }
        return (entries, folders)
    }

    /// BCancelSearch — «Отмена» рядом со счётчиками поиска.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    /// TextMessages13: «Да» — заменить список, «Нет» — добавить к существующему.
    func applyFoundTexts(replacing: Bool) {
        if replacing {
            settings.modules = foundTexts
        } else {
            for entry in foundTexts where !settings.modules.contains(where: { $0.path == entry.path }) {
                settings.modules.append(entry)
            }
        }
        foundTexts = []
        scannedFolders = 0
    }

    // MARK: - Вкладка «Пути» (6.1.5)

    /// Повертає `true`, якщо тека справді додана, і `false`, якщо вона вже
    /// була в списку.
    @discardableResult
    func addPicturePath(_ url: URL) -> Bool {
        let entry = PicturePathEntry(path: relativePath(of: url), scansSubfolders: false)
        guard !settings.picturePaths.contains(where: { $0.path == entry.path }) else { return false }
        settings.picturePaths.append(entry)
        return true
    }

    func removePicturePath(_ id: String) {
        settings.picturePaths.removeAll { $0.id == id }
    }

    func toggleSubfolders(_ id: String) {
        guard let index = settings.picturePaths.firstIndex(where: { $0.id == id }) else { return }
        settings.picturePaths[index].scansSubfolders.toggle()
    }

    /// (34) — папка для снимков экрана слайда (F11). Путь внутри папки данных
    /// пишем коротко, как оригинал: у пользователя там ровно «ScreenShots\».
    func setScreenshotFolder(_ url: URL) {
        settings.screenshotFolder = relativePath(of: url)
    }

    /// Сколько картинок дают папки из списка (31) прямо сейчас.
    ///
    /// Считается в стороне от главного потока и только по требованию вида:
    /// обход папок — работа с диском, а «Искать во вложенных папках» может
    /// увести в дерево на тысячи файлов. Делать это в `body` нельзя — окно
    /// подвиснет на каждой перерисовке.
    func countBackgroundImages() async -> Int {
        let paths = settings.picturePaths
        let root = dataRoot
        return await Task.detached(priority: .utility) {
            BackgroundLibrary.count(paths: paths, dataRoot: root)
        }.value
    }

    /// Путь внутри папки данных пишем в записи оригинала — с обратными
    /// слэшами и без буквы диска, как «BackGrounds\». Всё, что лежит снаружи,
    /// остаётся полным путём: иначе оно просто не найдётся.
    private func relativePath(of url: URL) -> String {
        let root = dataRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        var tail = String(path.dropFirst(root.count + 1)).replacingOccurrences(of: "/", with: "\\")
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue { tail += "\\" }
        return tail
    }

    /// Путь из записи оригинала обратно в файловый.
    func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let unix = path.replacingOccurrences(of: "\\", with: "/")
        return dataRoot.appendingPathComponent(unix)
    }

    // MARK: - Вкладка «Горячие клавиши» (6.1.6)

    var hotkeys: [String: Hotkey] { settings.hotkeys }

    /// Кем уже занята комбинация — для сообщений TextMessages21…23.
    func actionUsing(_ hotkey: Hotkey, excluding action: String) -> HotkeyAction? {
        let current = hotkeys
        return HotkeyAction.all.first { candidate in
            candidate.iniKey != action && current[candidate.iniKey] == hotkey
        }
    }

    func setHotkey(_ hotkey: Hotkey?, for action: String, clearing other: String? = nil) {
        var current = hotkeys
        if let other { current.removeValue(forKey: other) }
        if let hotkey { current[action] = hotkey } else { current.removeValue(forKey: action) }
        settings.hotkeySets.replace(setNamed: settings.hotkeySetName, with: current)
    }

    /// (35) «По умолчанию» — раскладка поставки VisioBible V2.5.
    func resetHotkeysToDefault() {
        let name = HotkeySets.factoryDefault.order.first ?? "VB Version 2.4"
        settings.hotkeySets.replace(setNamed: settings.hotkeySetName,
                                    with: HotkeySets.factoryDefault.hotkeys(inSet: name))
    }

    /// (37) — сохранить текущее состояние клавиш в набор с заданным именем.
    func saveHotkeySet(named name: String) {
        let current = hotkeys
        settings.hotkeySets.replace(setNamed: name, with: current)
        settings.hotkeySetName = name
    }

    /// (38) — удалить выбранный набор.
    func deleteHotkeySet(named name: String) {
        settings.hotkeySets.remove(setNamed: name)
        settings.hotkeySetName = settings.hotkeySets.preferredSetName ?? ""
    }

    // MARK: - Вкладка «Remote API» (6.1.8)

    func addWebSlide(_ entry: WebSlideEntry) {
        settings.webSlides.append(entry)
    }

    func replaceWebSlide(_ id: String, with entry: WebSlideEntry) {
        guard let index = settings.webSlides.firstIndex(where: { $0.id == id }) else { return }
        settings.webSlides[index] = entry
    }

    func removeWebSlide(_ id: String) {
        settings.webSlides.removeAll { $0.id == id }
    }

    /// Файлы страниц лежат в папке `RemoteAPI` рядом с данными программы.
    /// Файлы страниц — авторские и свои.
    ///
    /// Свою папку сюда добавили после жалобы: страницу, сделанную в
    /// мастерской, сервер отдавал, а в списке Remote API её не было, и
    /// выбрать её в параметрах Web слайда было нечем.
    var webSlideFiles: [String] {
        var names: [String] = []
        for folder in [dataRoot.appendingPathComponent("RemoteAPI"), WebOutputServer.userPagesFolder] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in files where name.lowercased().hasSuffix(".html") {
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    names.append(name)
                }
            }
        }
        return names.sorted()
    }

    // MARK: - Цветовая легенда частей песен (6.4)

    func setChunkColor(_ key: String, _ color: SlideStyle.RGBA) {
        guard let index = settings.songChunks.firstIndex(where: { $0.key == key }) else { return }
        settings.songChunks[index].tColor = SlovoSettings.tColor(of: color)
    }

    func addChunkName(_ key: String, _ name: String) {
        guard let index = settings.songChunks.firstIndex(where: { $0.key == key }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !settings.songChunks[index].names.contains(name) else { return }
        settings.songChunks[index].names.append(name)
    }

    func replaceChunkName(_ key: String, at position: Int, with name: String) {
        guard let index = settings.songChunks.firstIndex(where: { $0.key == key }),
              settings.songChunks[index].names.indices.contains(position),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        settings.songChunks[index].names[position] = name
    }

    func removeChunkName(_ key: String, at position: Int) {
        guard let index = settings.songChunks.firstIndex(where: { $0.key == key }),
              settings.songChunks[index].names.indices.contains(position) else { return }
        settings.songChunks[index].names.remove(at: position)
    }

    // MARK: - 6.2 Открыть папку с настройками

    /// Открывает папку с данными программы в Finder. В оригинале это пункт
    /// меню `NOpenSettingsFolder`.
    func openSettingsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([dataRoot])
    }
}

extension Notification.Name {
    /// Настройки записаны: главному окну пора перечитать полосу переводов,
    /// цвета частей песен и правила выводов.
    static let slovoSettingsChanged = Notification.Name("SlovoSettingsChanged")
}

/// Мостик между хранилищем настроек и главным окном.
///
/// Хранилище — одиночка без ссылки на `AppState` (и правильно: окно настроек
/// не должно уметь всё). Но сообщение `.slovoSettingsChanged` кто-то обязан
/// слушать, иначе «Ок» меняет только файл. Слушателя ставим один раз за
/// запуск, отсюда и `enum` со статикой, а не объект на каждое окно.
@MainActor
enum SettingsBridge {
    private static var observer: NSObjectProtocol?

    static func install(state: AppState) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .slovoSettingsChanged, object: nil, queue: .main
        ) { [weak state] _ in
            // Сообщение приходит на главную очередь, но компилятор об этом не
            // знает — говорим ему явно, вместо того чтобы плодить Task.
            MainActor.assumeIsolated {
                guard let state else { return }
                state.applyProgramOptions(SettingsStore.shared.settings.options)
                state.applyModuleRoster(SettingsStore.shared.settings.modules)
                // Добавили модуль с другого пути — библиотека его ещё не
                // открывала. Перечитываем; по окончании полоса переводов
                // встанет по списку сама (`applyLoaded`).
                if state.rosterNeedsLibraryReload { state.reloadLibrary() }
            }
        }
    }

    /// Стоит ли слушатель — для самопроверки.
    static var isInstalled: Bool { observer != nil }
}

// MARK: - Применение настроек

extension AppState {

    /// Цветовая легенда частей песен (6.4) для списка «Текст» в песнях.
    var songPalette: SongChunkPalette { SettingsStore.shared.settings.songPalette }

    /// Значения окна «Параметры» — чтобы остальному интерфейсу не нужно было
    /// знать про хранилище настроек.
    var programOptions: ProgramOptions { SettingsStore.shared.settings.options }

    /// Раскладка выбранного набора горячих клавиш (6.1.6): ключ функции из
    /// `hotkeys.ini` → сочетание.
    var hotkeys: [String: Hotkey] { SettingsStore.shared.hotkeys }

    /// Сочетание одной функции — `state.hotkey("ShowSlide")`.
    func hotkey(_ action: String) -> Hotkey? { hotkeys[action] }

    /// Порядок и включённость переводов с вкладки «Модули» (6.1.4).
    /// Полосу вкладок перестраивает сам `AppState` — здесь только данные.
    var moduleRoster: [ModuleRosterEntry] { SettingsStore.shared.settings.modules }

    /// Вид номера в названии песни — пункт (20) вкладки «Слайд».
    /// Тип из `SlovoCore` уже есть, поэтому здесь только перекладка значений.
    var songTitleFormat: SongTitleFormat {
        let options = programOptions
        return SongTitleFormat(showsNumber: options.songNumberInCollection,
                               dotAfterNumber: options.songDotAfterNumber,
                               numberInBrackets: options.songNumberInBrackets)
    }

    /// Папка для снимков экрана слайда — элемент (34) вкладки «Пути».
    /// Относительный путь ищется от папки с данными программы, как в оригинале.
    var screenshotFolder: URL {
        let root = modulesFolder.deletingLastPathComponent()
        let stored = SettingsStore.shared.settings.screenshotFolder
        guard !stored.trimmingCharacters(in: .whitespaces).isEmpty else {
            return root.appendingPathComponent("ScreenShots")
        }
        return BackgroundLibrary.resolve(stored, dataRoot: root)
    }

    /// Пересобрать список фонов по вкладке «Пути» (31) (32) (33).
    ///
    /// Пустой список означает «папка BackGrounds рядом с модулями» — так
    /// раскладывает фоны и сам VisioBible.
    ///
    /// Обход папок уходит в фон: путей может быть несколько, у любого может
    /// стоять «искать во вложенных папках», и разбирать дерево в главном
    /// потоке значит подвесить окно ровно в момент нажатия «Ок».
    func reloadBackgroundsFromSettings() {
        let paths = SettingsStore.shared.settings.picturePaths
        let root = modulesFolder.deletingLastPathComponent()
        // Задача наследует главный поток от `AppState` — присваивание
        // `backgroundImages` попадёт туда, куда надо.
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                BackgroundLibrary.images(paths: paths, dataRoot: root)
            }.value
            self?.backgroundImages = found
        }
    }

    /// Применить записанные настройки при запуске программы.
    ///
    /// До этого окно «Параметры» было единственным, кто их читал: значения
    /// жили до закрытия программы и при следующем запуске терялись. Зовётся
    /// один раз — когда библиотека уже открыта и `AppState` успел собрать
    /// выводы из `VisioBible.ini`, иначе наши значения тут же затёрлись бы.
    func applySavedSettings() {
        let store = SettingsStore.shared
        store.reload(dataRoot: modulesFolder.deletingLastPathComponent())
        // Клавиши — раньше остального: перехватчики читают раскладку на каждое
        // нажатие, и первым же нажатием после запуска должна работать та, что
        // записана в окне «Параметры», а не та, что лежит в файле оригинала.
        EffectiveHotkeys.adopt(sets: store.settings.hotkeySets, setName: store.settings.hotkeySetName)
        applyProgramOptions(store.settings.options)
        // Список и порядок модулей (6.1.4) — после общих настроек: полоса
        // переводов должна встать по нему, а не по `[BiblePath]` оригинала.
        applyModuleRoster(store.settings.modules)
        SettingsBridge.install(state: self)
    }

    /// Перенос значений окна «Параметры» в работающие части программы.
    ///
    /// Здесь только то, что видно снаружи `AppState`: тайминги слайда, номера
    /// стихов, вид адреса, NDI и Remote API. Полоса переводов перестраивается
    /// в самом `AppState` — её список закрыт на запись, и правильно, что так.
    func applyProgramOptions(_ options: ProgramOptions) {
        var style = self.style
        // В оригинале это миллисекунды, у нас — секунды: 0 и 1 мс означают
        // мгновенную смену, и переход надо не ускорять, а выключать.
        style.transitionDuration = max(0.001, Double(options.crossfadeTime) / 1000)
        if let raw = options.slideTransition, let kind = SlideStyle.Transition(rawValue: raw) {
            style.transition = kind
        }
        if let raw = options.slideTransitionEasing, let easing = SlideStyle.Easing(rawValue: raw) {
            style.transitionEasing = easing
        }
        style.transition = options.crossfadeTime <= 1 ? .none : style.transition
        self.style = style

        outputs[.screen].showsVerseNumbers = options.showVerseNumbers
        outputs[.preview].showsVerseNumbers = options.showVerseNumbers
        outputs[.ndi].showsVerseNumbers = options.showVerseNumbers

        // (17) «Показывать номера стихов» — отдельно у основного и у второго
        // перевода. Сборка слайда читает их ОТСЮДА, а не из правил каналов:
        // текст собирается один на все выводы. Пока это не было проставлено,
        // галочка в окне «Параметры» не действовала вовсе, и номера убирались
        // только правкой VisioBible.ini руками.
        applyVerseNumberFlags(main: options.showVerseNumbers,
                              secondary: options.showSecondaryVerseNumbers)

        referenceFormat = ReferenceFormat(
            combinedMain: ReferenceFormat.NameLength(rawValue: options.refAllMain.rawValue) ?? .long,
            combinedSecondary: ReferenceFormat.NameLength(rawValue: options.refAllSec.rawValue) ?? .short,
            separateMain: ReferenceFormat.NameLength(rawValue: options.refMain.rawValue) ?? .long,
            separateSecondary: ReferenceFormat.NameLength(rawValue: options.refSec.rawValue) ?? .long)

        // NDI: прозрачный фон — это «не рисовать подложку», а частота хранится
        // индексом в списке, а не числом.
        outputs[.ndi].drawsBackground = !options.ndiTransparentBackground
        outputs[.ndi].sendsVideo = options.ndiSendVideo
        versesOnOwnLines = options.versesOnOwnLines ?? true
        // Перехід сторінок показу і зображень — свій, не слайдовий.
        let showKind = SlideStyle.Transition(rawValue: options.showTransition ?? "") ?? .fade
        let showEasing = SlideStyle.Easing(rawValue: options.showTransitionEasing ?? "") ?? .easeInOut
        media.stillTransition = (showKind, Double(options.showTransitionTime ?? 350) / 1000, showEasing)
        outputs[.ndi].sendsAudio = options.ndiSendAudio ?? true
        outputs[.ndi].frameHeight = options.ndiFrameHeight ?? 0
        // Транспорт читает загрузчик библиотеки до её запуска — из
        // UserDefaults, куда добраться можно с любого потока.
        UserDefaults.standard.set(options.ndiTransport ?? "auto", forKey: NDIRuntime.transportKey)
        applyWebVideo(options)
        ndi.setWiFi(enabled: options.ndiWiFiEnabled ?? false,
                    height: options.ndiWiFiHeight ?? 360,
                    fps: options.ndiWiFiFrameRate ?? 15)
        NDISender.audioGainDb = Double(options.ndiAudioGainDb ?? 20)
        // Третього джерела «Слово HX» більше немає: стиснене відео NDI|HX у
        // мережу шле лише бібліотека NDI Advanced SDK, а з бібліотекою NDI
        // Tools приймачі по мережі отримували тільки звук. Власник вирішив
        // прибрати джерело (10.09.2026).
        outputs[.ndi].frameRate = options.ndiFrameRate
        applyNDIRules()
        if outputs[.ndi].isEnabled != options.ndiEnabled { setNDIEnabled(options.ndiEnabled) }

        // (5) (7) (9) — куда ставить окно слайда. Раньше выбор монитора
        // записывался прямо в момент щелчка по списку и мимо «Ок»/«Отмена»;
        // теперь он приезжает сюда, то есть только по «Ок» и при запуске.
        projection.placement = SlideWindowPlacement(options: options)

        // (31) (32) (33) — фоны берутся из списка папок вкладки «Пути».
        reloadBackgroundsFromSettings()

        // 6.1.8 — начальная страница http://[IP]:82/ перечисляет ровно то, что
        // стоит в списке «Web слайды», а не все *.html из папки RemoteAPI.
        let pages = SettingsStore.shared.settings.webSlides.map {
            WebOutputSettings.WebPage.make(fileName: $0.fileName,
                                           title: $0.details.isEmpty ? $0.name : $0.details)
        }

        // Веб-сервер поднимается заново только если что-то из сетевого
        // действительно поменялось: перезапуск рвёт открытые страницы в зале.
        let webChanged = outputs.web.httpPort != options.webPort
            || outputs.web.webSocketPort != options.webSocketPort
            || outputs.web.httpEnabled != options.webEnabled
            || outputs.web.webSocketEnabled != options.webSocketEnabled
            // TCP и UDP тоже считаются: без них включённый в окне TCP-сервер
            // не поднимался вовсе — значения ложились в настройки, а
            // перезапуска не случалось, и слушатель так и не заводился.
            || outputs.web.tcpEnabled != options.tcpEnabled
            || outputs.web.tcpPort != options.tcpPort
            || outputs.web.udpEnabled != options.udpEnabled
            || outputs.web.udpPort != options.udpPort
            || (!pages.isEmpty && outputs.web.pages != pages)
        if !pages.isEmpty { outputs.web.pages = pages }
        outputs.web.httpEnabled = options.webEnabled
        outputs.web.httpPort = options.webPort
        outputs.web.webSocketEnabled = options.webSocketEnabled
        outputs.web.webSocketPort = options.webSocketPort
        outputs.web.tcpEnabled = options.tcpEnabled
        outputs.web.tcpPort = options.tcpPort
        outputs.web.udpEnabled = options.udpEnabled
        outputs.web.udpPort = options.udpPort
        if webChanged {
            setWebEnabled(false)
            if options.webEnabled || options.webSocketEnabled
                || options.tcpEnabled || options.udpEnabled {
                setWebEnabled(true)
            }
        }

        // Указка: вид и выводы — из настроек, положение остаётся.
        SlidePointer.shared.apply(look: SlidePointer.Look(options: options))

        // Пульт на телефоне: включён, пока его не выключили нарочно.
        RemoteControlServer.shared.apply(enabled: options.remoteEnabled ?? true,
                                         port: options.remotePort ?? 8103,
                                         pin: options.remotePin ?? "",
                                         state: self)
        // Пульт у браузері: свій порт і пароль, увімкнений, поки не вимкнули.
        RemoteControlServer.shared.applyWeb(enabled: options.remoteWebEnabled ?? true,
                                            port: options.remoteWebPort ?? 8105,
                                            password: options.remoteWebPassword ?? "",
                                            name: options.remoteWebName ?? "slovo",
                                            viewOnly: options.remoteWebViewOnly ?? false,
                                            noPort: options.remoteWebNoPort ?? true)

        refreshSlide()
    }
}
