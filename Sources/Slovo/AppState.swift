import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import SlovoCore

/// Всё состояние программы: какой модуль открыт, где стоит курсор,
/// что сейчас на проекторе.
@MainActor
final class AppState: ObservableObject {

    // Библиотека
    @Published private(set) var library: ModuleLibrary?
    /// Переводы, вынесенные на полосу вкладок, — в том порядке, в каком их
    /// расставил пользователь в оригинале.
    @Published private(set) var orderedModules: [TextModule] = [] {
        didSet {
            guard oldValue.map(\.identifier) != orderedModules.map(\.identifier) else { return }
            moduleRosterRevision += 1
        }
    }
    /// Номер состава полосы переводов. Мост окна AppKit сличает снимки
    /// состояния скалярами, а не списками; без этого числа снятая на вкладке
    /// «Модули» галочка меняла `orderedModules`, но повод «состав полосы стал
    /// другим» никуда не уходил — и полоса оставалась прежней до перезапуска.
    @Published private(set) var moduleRosterRevision = 0
    /// Вся библиотека целиком, включая модули, которых нет на полосе.
    /// В полной сборке их полторы сотни — вкладками это не показать.
    @Published private(set) var allModules: [TextModule] = []
    @Published private(set) var isLoadingLibrary = false
    /// Книга ещё разбирается в фоне — списку глав пока нечего показывать.
    @Published private(set) var isLoadingChapters = false

    // Раскладка оригинала
    @Published var mode: WorkMode = .bible {
        didSet {
            // Куда вернуться из плеера. Запоминаем прежний режим, а не текущий:
            // иначе выход из плеера привёл бы обратно в плеер.
            if mode == .media, oldValue != .media { modeBeforeMedia = oldValue }
            // Слайд один на все вкладки: без пересборки предпросмотр и
            // «Показать» на новой вкладке отдавали то, что готовила прежняя.
            // Владелец: «предпросмотр зависает на одной из вкладок, а в зал
            // уходит один из предыдущих выводов».
            if mode != oldValue { syncSlideToMode() }
        }
    }

    /// Картинка текущей вкладки показа (изображения, презентации) — для
    /// нижнего предпросмотра: там должно быть то, что уйдёт в зал.
    /// Модель захоплення екрана. Тримаємо як `AnyObject`: сам тип є лише на
    /// macOS 13 і новіших, а поле оголошується завжди.
    var screenCaptureStorage: AnyObject?

    @Published var previewStill: CGImage? {
        didSet { Signals.shared.send(.slide) }
    }

    /// Пересобрать слайд под открытую вкладку — по её текущему выбору.
    func syncSlideToMode() {
        previewStill = NativeShowWorkspace.currentImage(for: mode)
        switch mode {
        case .bible:
            refreshSlide()
        case .songs:
            if shownSong != nil || !songPages.isEmpty { refreshSlide() } else { slide = .blank }
        case .text:
            TextModuleModel.shared.refreshPreview()
        case .pictures, .presentation, .media, .screen:
            // Их предпросмотр — картинка или кадр плеера, не текстовый слайд.
            break
        }
        Signals.shared.send(.slide)
    }
    @Published var bookClass: BookClass = .all
    @Published private(set) var history: [HistoryEntry] = []
    /// Размер шрифта списков — ползунок (20) в оригинале и Ctrl + колесо мыши.
    /// Кілька віршів — кожен з нового рядка. Ставить вікно налаштувань.
    var versesOnOwnLines = true

    @Published var listFontSize: Double = 13
    @Published var searchQuery = ""
    @Published var quickInput = ""

    // Песни
    @Published var songBookID = ""
    @Published var songQuery = ""
    @Published var songIndex: Int?
    @Published var songPartIndex: Int?
    private(set) var songLibrary: SongLibrary?
    private var tabTitles: [String: String] = [:]
    /// «Длинное название» / «Короткое название» из меню вкладки перевода.
    @Published var tabNamesLong = false { didSet { rebuildTabTitles() } }

    // Панель «Управление»: шаблон и два фона, как в оригинале
    @Published private(set) var schemes: SchemeLibrary?

    /// Свои шаблоны — те, что человек собрал в Конструкторе (6.3).
    ///
    /// Лежат отдельно от авторских `.sch`: авторские мы не переписываем.
    let presets = PresetLibrary(folder: PresetLibrary.defaultFolder)

    /// Свой шаблон, применённый к залу. Пусто — слайд собирается по
    /// авторскому шаблону, как раньше.
    ///
    /// До этого Конструктор был сам по себе: шаблон сохранялся в свою папку и
    /// там же оставался. В списке «Шаблон» его не было, применить его было
    /// нечем, и правки не доходили ни до проектора, ни до предпросмотра.
    ///
    /// Экран служителя и веб-страницы живут своим шаблоном — у них своя
    /// задача. Зал, предпросмотр и трансляция идут одним: в Конструкторе
    /// шаблон один, и правка в нём обязана дойти до всех троих.
    var slidePreset: SlidePreset? { livePreset ?? ownPreset(for: .screen) }

    /// Чи слайд зараз — пісня: тоді береться шаблон пісень, якщо він є.
    /// Слайд збирається за вкладкою (`refreshSlide`), тому й тут — вкладка.
    var showsSongSlide: Bool { mode == .songs }

    /// Свій шаблон виводу з урахуванням того, що на слайді: пісням — їхній,
    /// коли призначено, інакше спільний.
    func ownPreset(for kind: OutputKind) -> SlidePreset? {
        if showsSongSlide, let own = presets.preset(for: kind, songs: true) { return own }
        return presets.preset(for: kind)
    }

    /// Шаблон, который сейчас правят в Конструкторе: зал показывает его, не
    /// дожидаясь сохранения. Владелец просил видеть правки на проекторе на
    /// лету. Пусто — рисуется сохранённый.
    private(set) var livePreset: SlidePreset?

    func previewPreset(_ preset: SlidePreset?) {
        livePreset = preset
        presetImages.removeAll()
        refreshSlide()
    }

    /// Свой шаблон вывода — с оглядкой на то, что вывод вообще включён.
    ///
    /// Трансляция берёт шаблон зала, а не свой: подложку с неё снимает правило
    /// вывода (`NdiTransparentBackGr`), как в оригинале. Пока у NDI был свой
    /// шаблон, правка в Конструкторе доходила до зала и не доходила до сети —
    /// человек менял, а на микшере оставалось прежнее.
    func preset(for kind: OutputKind) -> SlidePreset? {
        let target: OutputKind = kind == .ndi ? .screen : kind
        var chosen = (target == .screen || target == .preview) ? (livePreset ?? ownPreset(for: target))
                                                                : ownPreset(for: target)
        // Переход, выбранный в «Параметрах», главнее перехода шаблона: иначе
        // выбор в настройках не менял ничего, пока в зале стоит свой шаблон
        // (владелец: «половина эффектов не работает»).
        if programOptions.slideTransition != nil {
            chosen?.transition = style.transition
            chosen?.transitionDuration = style.transitionDuration
            chosen?.transitionEasing = style.effectiveEasing
        }
        return chosen
    }

    /// Строки слайда для объектов своего шаблона: текст, адрес, имена
    /// модулей, название песни. Собираются вместе со слайдом.
    private(set) var slideTexts = ConstructorSample()

    /// Найденные картинки объектов: по имени файла — путь. Искать их заново
    /// на каждый кадр нельзя, а меняются они только со сменой шаблонов.
    private var presetImages: [String: URL?] = [:]
    @Published private(set) var templateName = ""
    /// «Фон Общий» — подложка, общая для всех слайдов; «Фон Слайда» задаётся
    /// шаблоном. В оригинале это две разные настройки и две разные миниатюры.
    @Published var commonBackgroundPath: String?
    /// Фон слайда, выбранный человеком.
    ///
    /// Держим отдельно от `style.backgroundImagePath`: тот пересобирается на
    /// каждую смену шаблона, и выбор человека в нём не жил дольше одной
    /// правки — при следующем запуске возвращался фон шаблона.
    @Published var slideBackgroundPath: String?
    @Published var showsCommonBackground = true
    /// `LinkPreviewAndSlide` оригинала: какая пара стрелок листает только
    /// предпросмотр, а какая — и предпросмотр, и слайд в зале.
    @Published var arrowsLinked = true
    /// Пока true, смена стиха уходит и в зал. Ставится на время двойного
    /// щелчка, Enter и «связанной» пары стрелок.
    private var followLive = false
    /// Стих, от которого отсчитывается отрезок при выделении с Shift.
    private var selectionAnchor: Int?

    /// Перелистывание с явным указанием, трогать ли зал.
    func stepVerse(by delta: Int, live: Bool) {
        followLive = live
        defer { followLive = false }
        stepVerse(by: delta)
    }

    func stepChapter(by delta: Int, live: Bool) {
        followLive = live
        defer { followLive = false }
        stepChapter(by: delta)
    }

    /// Выбор стиха мышью: одиночный щелчок — только предпросмотр,
    /// двойной — сразу в зал.
    func chooseVerse(_ number: Int, mode: VerseSelection, live: Bool) {
        // Двойной щелчок по уже выделенному стиху не должен рушить набранный
        // отрезок. Иначе выделить пять стихов и вывести их не получалось:
        // первый щелчок двойного сбрасывал выделение на один стих, и в зал
        // уходил он один.
        if live, mode == .replace, selectedVerseNumbers.contains(number) {
            showCurrent()
            return
        }
        selectVerse(number, mode: mode)
        if live { showCurrent() }
    }
    /// Звідки прочитано файл налаштувань (`Slovo.ini`); `nil` — файла немає
    /// в жодному зі своїх місць, діють значення, зашиті в код.
    @Published private(set) var configPath: String?
    @Published private(set) var output: OutputSettings?
    /// Как собирать адрес на слайде — вкладка «Слайд» окна параметров.
    @Published var referenceFormat = ReferenceFormat()

    // Интерфейс
    @Published private(set) var languageCatalog: LanguageCatalog?
    @Published private(set) var language: LanguageFile?
    @Published var isSettingsOpen = false {
        // «Параметры» из системного меню и по ⌘, ставят этот признак —
        // открываем окно параметров.
        didSet {
            guard isSettingsOpen else { return }
            isSettingsOpen = false
            NativeSettingsSheet.open()
        }
    }
    /// F6 — вернуть внимание к тексту: прокрутить список к текущему стиху.
    /// Раньше здесь переключался флаг, который никто не читал, и клавиша
    /// выглядела нерабочей.
    @Published var scrollToCurrentVerse = 0
    @Published private(set) var loadError: String?
    @Published var modulesFolder: URL {
        didSet {
            Defaults.modulesFolder = modulesFolder
            DataPaths.roots = [modulesFolder.deletingLastPathComponent()]
            reloadLibrary()
        }
    }

    // Выбор перевода: один основной и сколько угодно параллельных
    @Published var primaryModuleID: String = "" { didSet { reloadBooks() } }
    @Published var secondaryModuleIDs: [String] = [] {
        didSet {
            Defaults.secondaryModules = secondaryModuleIDs
            prewarm()
            refreshSlide()
        }
    }

    // Курсор по тексту
    @Published private(set) var books: [BookInfo] = []
    @Published var selectedBookIndex: Int = 0 { didSet { selectedChapterNumber = chapters.first?.number ?? 1; reloadChapters() } }
    @Published var selectedChapterNumber: Int = 1 { didSet { selectedVerseNumbers = [firstVerseNumber]; refreshSlide() } }
    @Published var selectedVerseNumbers: [Int] = [1] { didSet { refreshSlide() } }
    @Published private(set) var chapters: [Chapter] = []

    // Слайд и вывод
    /// Правила всех выводов сразу. Каждый вывод рисует своё, поэтому общего
    /// «стиля приложения» больше нет — есть стиль конкретного канала.
    @Published var outputs = OutputConfiguration(config: nil, dataRoot: nil)

    /// Стиль монитора. Предпросмотр обязан показывать ровно то, что уйдёт на
    /// проектор, поэтому эти два канала держим синхронно.
    var style: SlideStyle {
        get { outputs[.screen].style }
        set {
            outputs[.screen].style = newValue
            outputs[.preview].style = newValue
            pushToOutputs()
        }
    }
    /// Что видно в «Предпросмотре» — оператор готовит это, пока в зале
    /// висит другое.
    @Published private(set) var slide = Slide.blank
    /// Что сейчас на проекторе. В оригинале это разные вещи: одиночный
    /// щелчок по стиху меняет только предпросмотр, двойной — выводит.
    @Published private(set) var liveSlide = Slide.blank
    /// Показан ли ТЕКСТ в зале. Само окно слайда при этом не закрывается.
    ///
    /// Так ведёт себя оригинал, и владелец просил повторить: окно с фоном
    /// поднимается сразу после запуска и живёт до закрытия программы, показ
    /// добавляет к фону текст, а «скрыть» убирает только текст. Раньше мы
    /// закрывали окно целиком — зал видел то экран рабочего стола, то слайд.
    @Published var isLive = false { didSet { pushToOutputs() } }
    @Published var backgroundImages: [URL] = []

    let projection = ProjectionController()
    /// Сетевая трансляция. Живёт всегда, но кадры считает только когда включена.
    let ndi = NDIOutput()
    /// «Видео по Wi-Fi» — H.264/AAC потоком HLS с нашего веб-сервера.
    let webVideo = WebVideoOutput()
    /// Веб-слайды: HTTP отдаёт авторские страницы, WebSocket шлёт им текст.
    let web = WebOutputServer()
    /// Медиа-плеер (16). Живёт вместе с окном: в оригинале он открывается
    /// панелью по Ctrl+M и не перезапускается при переключении режимов.
    let media = MediaPlayerModel()
    /// Независимый проигрыватель фонограммы (минусовки) — замечание 15.
    let backing = BackingTrackPlayer()
    /// Открыт ли плеер. Теперь это просто «выбран режим Медиа»: плеер стоит
    /// в ряду вкладок наравне с Библией, Текстом и Песнями, а не отдельной
    /// полосой поверх окна. Так его и открывают — кнопкой.
    ///
    /// Свойство осталось затем, что им пользуются пункт меню, клавиша Ctrl+M
    /// автора и самопроверка: им незачем знать, что за этим стоит режим.
    var isMediaOpen: Bool {
        get { mode == .media }
        set {
            guard newValue != (mode == .media) else { return }
            // Уходя из плеера, возвращаемся туда, откуда пришли, а не в
            // Библию всегда: оператор мог смотреть песню.
            mode = newValue ? .media : (modeBeforeMedia ?? .bible)
        }
    }

    /// Режим, из которого открыли плеер, — чтобы было куда вернуться.
    private var modeBeforeMedia: WorkMode?
    /// Библиотека уже открывалась хоть раз: следующее чтение — перечитывание.
    private var hasLoadedLibraryOnce = false
    /// Просили перечитати, поки читання ще йшло: зробимо це слідом.
    private var reloadWanted = false

    /// В списке настроек есть включённые модули, которых библиотека не
    /// открывала: их путь есть на диске, а в `allModules` их нет. Так бывает
    /// после «+» в «Параметрах» — модуль лежит вне папки `Modules`.
    var rosterNeedsLibraryReload: Bool {
        let dataRoot = modulesFolder.deletingLastPathComponent()
        let known = Set(allModules.map { $0.identifier.lowercased() })
        return SettingsStore.shared.settings.modules.contains { entry in
            entry.isEnabled && !entry.isSongBook
                && !known.contains(entry.libraryIdentifier.lowercased())
                && FileManager.default.fileExists(atPath: entry.resolvedURL(dataRoot: dataRoot).path)
        }
    }
    private var childObservers: [AnyCancellable] = []

    /// Приёмник команд меню: SwiftUI пересобирает сцену часто, а цель
    /// действий должна пережить пересборку.
    private(set) lazy var menuActions = MenuActions(state: self)

    // Перехватчики клавиш и колеса живут здесь, а не в структуре сцены.
    //
    // SwiftUI пересоздаёт значение `App`, и хранившиеся в нём объекты
    // уничтожались вместе с ним, снимая свой перехватчик в `deinit`.
    // Со стороны это выглядело так: стрелки работают сразу после запуска,
    // а через несколько действий перестают.
    let arrows = ArrowNavigator()
    let escapeGuard = EscapeGuard()
    let wheelZoom = WheelZoom()

    /// Установлены ли перехватчики — видно в диагностике.
    var keyHandlersInstalled: Bool { arrows.isInstalled }

    /// Ставит перехватчики один раз за запуск.
    func installKeyHandlers() {
        arrows.install(.init(stepVerse: { [weak self] delta, live in
                                 guard let self else { return }
                                 // В показе картинок и презентаций стрелки
                                 // листают страницы: стихов там нет.
                                 guard !NativeShowWorkspace.handleStep(mode: self.mode, delta: delta) else { return }
                                 self.stepVerse(by: delta, live: live)
                             },
                             extendSelection: { [weak self] delta, live in
                                 self?.extendSelection(by: delta, live: live)
                             },
                             selectAll: { [weak self] in self?.selectAllVerses() },
                             isLinked: { [weak self] in self?.arrowsLinked ?? true },
                             show: { [weak self] in self?.showCurrent() },
                             blackout: { [weak self] in self?.showBlackScreen() }))

        wheelZoom.install { [weak self] step in self?.zoomLists(by: step) }

        escapeGuard.install { [weak self] in
            guard let self, self.isLive else { return false }
            self.isLive = false
            return true
        }
    }

    private var moduleCache: [String: TextModule] = [:]
    private var hiddenBackgroundPath: String?
    private var isBlackout = false
    private var isTextHidden = false

    /// Затемнён ли зал (F12) и стоит ли «фон без текста» (Ctrl+F5) — для
    /// пульта и самопроверки: сами признаки закрыты, менять их снаружи нельзя.
    var isBlackedOut: Bool { isBlackout }
    var isTextBlank: Bool { isTextHidden }

    init() {
        // Свій дім даних: чужий корінь (пакет програми, VisioBible)
        // переноситься сюди один раз — див. `DataHome`.
        self.modulesFolder = Self.settleModulesFolder()
        DataPaths.roots = [modulesFolder.deletingLastPathComponent()]
        self.secondaryModuleIDs = Defaults.secondaryModules
        // Пересылать сюда objectWillChange от NDI и веба нельзя: они шлют
        // счётчики несколько раз в секунду, а это перерисовка всего окна —
        // сетки книг, списка стихов и раскладки фонов. Окно настроек само
        // подписывается на них через @ObservedObject.
        //
        // Перевод интерфейса читаем СРАЗУ и на месте, до открытия библиотеки.
        // Меню SwiftUI собирается один раз, при постройке сцены, и второй раз
        // за языком уже не идёт: пока перевод подгружался вместе с модулями,
        // верхние названия разделов успевали стать украинскими, а пункты
        // внутри оставались русскими до перезапуска. Двадцать небольших
        // файлов читаются за миг, ждать их не накладно.
        loadLanguages()
        reloadLibrary()
        // Список файлів плеєра, зібраний до служіння, має пережити закриття
        // програми. Тільки цей плеєр — той, з яким працює людина.
        media.remembersPlaylist = true
        media.restorePlaylist()
        backing.remembers = true
        backing.restore()

        // Окно «Редактор несоответствий нумерации» (N40) записало базу по «Ок».
        // Без этого правленые правила доходили бы до слайда только со
        // следующего запуска: движок пересчёта держит их разобранными в
        // памяти и сам за файлом не следит.
        NotificationCenter.default.addObserver(forName: .slovoNumberingChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadNumbering() }
        }

        // Клавишу переназначили в окне «Параметры» (6.1.6). Меню держит
        // сочетания в подписях пунктов, и без пересборки в нём осталась бы
        // старая клавиша — а работала бы уже новая.
        NotificationCenter.default.addObserver(forName: .slovoHotkeysChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bumpMenu() }
        }

        // Окно «Перевод интерфейса» (7.1) сохранило или удалило перевод.
        NotificationCenter.default.addObserver(forName: .slovoInterfaceLanguagesChanged,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadLanguages()
                self?.bumpMenu()
            }
        }
    }

    // MARK: - Загрузка

    /// Де шукати дані, за спаданням пріоритету.
    ///
    /// Насамперед — усередині власного пакета: повна збірка везе модулі,
    /// шаблони, фони та шрифти з собою, і її можна перенести на комп'ютер,
    /// де нічого більше не встановлено. Потім особиста тека користувача, куди
    /// лягають додані вручну модулі. Установлений VisioBible не перевіряємо:
    /// програма від нього не залежить.
    /// Тека модулів на старті. Власник: «все переводы и модули внутри пакета
    /// всегда» — тому за умовчанням це `Contents/Resources/app/Modules` у
    /// самому пакеті (скопійований пакет — цілий); вибрана вручну — збережена;
    /// пакет без даних (відкрита збірка) — свій дім у Application Support.
    /// Пісенники VisioBible в теці один раз переводяться у свій `.songbook`.
    static func settleModulesFolder() -> URL {
        let fm = FileManager.default
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app/Modules")
        let folder: URL
        if let saved = Defaults.modulesFolder, fm.fileExists(atPath: saved.path) {
            folder = saved
        } else if fm.fileExists(atPath: inBundle.path) {
            folder = inBundle
        } else {
            folder = DataHome.modules
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let repaired = DataHome.repairNestedModules(in: folder)
        if repaired > 0 { NativeTrace.say("модулі: полагоджено \(repaired), що лягли текою замість файла") }
        if let report = DataHome.convertSongBooksOnce(in: folder) {
            NativeTrace.say("пісенники: " + report.summary)
            if report.converted > 0 { migrationNote = report.summary }
        }
        return folder
    }

    /// Що перетворили на старті — сказати людині один раз після появи вікна.
    static var migrationNote: String?

    static func guessModulesFolder() -> URL { DataHome.modules }

    /// Открытие библиотеки в фоне.
    ///
    /// В полной сборке модулей под две сотни, и разбор их описаний занимает
    /// секунды. Делать это в главном потоке нельзя: окно не появится, пока
    /// не прочитан последний `bibleqt.ini`, и программа выглядит зависшей.
    /// Поэтому читаем в фоне, а в главный поток отдаём уже готовое.
    func reloadLibrary() {
        // Читання вже йде — не кидаємо друге поруч, але й не забуваємо: те,
        // що просять зараз, читатимемо одразу після цього.
        //
        // Доти прохання просто зникало. Саме через це доданий у «Параметрах»
        // модуль міг не з'явитися взагалі: людина встигала натиснути «Ок»,
        // поки бібліотека ще відкривалася після запуску, — і програма мовчки
        // лишала все, як було.
        guard !isLoadingLibrary else { reloadWanted = true; return }
        reloadWanted = false
        isLoadingLibrary = true
        moduleCache.removeAll()

        let folder = modulesFolder
        let dataRoot = folder.deletingLastPathComponent()
        // Модули, которые человек добавил в «Параметрах» с других путей:
        // папка обходится целиком, а эти надо открыть поимённо.
        let extras = SettingsStore.shared.settings.modules
            .filter { $0.isEnabled }
            .map { $0.resolvedURL(dataRoot: dataRoot) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = ModuleLibrary(modulesDirectory: folder, extraModules: extras)
            let config = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyLoaded(loaded, config: config, dataRoot: dataRoot)
                }
            }
        }
    }

    private func applyLoaded(_ loaded: ModuleLibrary, config: IniSettings?, dataRoot: URL) {
        library = loaded
        loadError = loaded.modules.isEmpty ? OurWords.t("В папке %s не найдено ни одного модуля.", "\(modulesFolder.path)") : nil

        loadBackgrounds()
        loadLanguages()
        songLibrary = SongLibrary(songFiles: loaded.songFiles)
        // Список модулів у налаштуваннях — за тим, що справді є на диску.
        SettingsStore.shared.syncModuleRoster(
            libraryIdentifiers: Set(loaded.modules.map { $0.identifier.lowercased() }),
            songBookStems: Set(loaded.songFiles.map { $0.deletingPathExtension().lastPathComponent.lowercased() }),
            modulesFolder: modulesFolder, dataRoot: dataRoot)
        // Галочки вкладки «Модули» ложатся на каталог тут же: `applySavedSettings`
        // дойдёт до них ниже, но `songBookID` выбирается уже сейчас — и без
        // этого выбирался бы выключенный сборник.
        rebuildSongBooks(SettingsStore.shared.settings.modules)
        if let config { songComposer = SongSlideComposer(config: config) }
        if let config {
            biblePagination = PlainTextDocument.Pagination(config: config, section: "Bible", style: style)
        }
        schemes = SchemeLibrary(dataRoot: dataRoot, config: config)
        if songBookID.isEmpty { songBookID = songBooks.first?.id ?? "" }
        FontLoader.registerFonts(in: dataRoot.appendingPathComponent("Fonts"))

        if let config {
            configPath = IniSettings.locateConfig()?.path
            output = OutputSettings(config: config)
            outputs = OutputConfiguration(config: config, dataRoot: dataRoot)
        }

        if let config {
            referenceFormat = ReferenceFormat(config: config)
            // Файл налаштувань — це ПОЧАТКОВІ значення, а не вирок. Поки вони
            // читалися на кожен запуск, вони затирали все, що людина обрала
            // минулого разу: і спільний фон, і шаблон, і зв'язані стрілки
            // поверталися до записаного у файлі. Звідси й «фон не
            // запам'ятовується»: він запам'ятовувався справно, а при
            // наступному запуску його перебивав ini.
            if Defaults.arrowsLinked == nil {
                arrowsLinked = config.bool("LinkPreviewAndSlide", in: "Bible") ?? true
            }
            // Пустая запись — это «ничего не выбрано», а не выбор: тогда
            // начальное значение из настроек оригинала берём как обычно.
            if (Defaults.lastTemplate ?? "").isEmpty {
                templateName = config.string("DefaultScheme", in: "Bible") ?? ""
            }
            if Defaults.showsCommonBackground == nil {
                showsCommonBackground = config.bool("ShowCommonBackGr", in: "settings") ?? true
            }
            if (Defaults.commonBackground ?? "").isEmpty,
               let relative = config.string("CommonBackgrFileName", in: "settings") {
                let url = dataRoot.appendingPathComponent(relative.replacingOccurrences(of: "\\", with: "/"))
                if FileManager.default.fileExists(atPath: url.path) { commonBackgroundPath = url.path }
            }
        }
        allModules = order(loaded.modules, using: config)
        rebuildTabTitles()
        orderedModules = pinned(from: allModules, using: config)

        // Только теперь, а не раньше: расписать переводы по стандартам
        // нумерации можно лишь тогда, когда они уже разложены по списку.
        // Раньше этот вызов стоял выше — и уходил в работу с пустым списком,
        // отчего стандарт не находился ни у одного перевода, кроме восьми
        // названных в таблице автора.
        reloadNumbering()

        let remembered = Defaults.primaryModule
        if let remembered, loaded.module(withIdentifier: remembered) != nil {
            primaryModuleID = remembered
        } else {
            primaryModuleID = orderedModules.first?.identifier ?? ""
        }

        if secondaryModuleIDs.isEmpty,
           let index = config?.int("defmoduletabindexsecond", in: "Bible"), index >= 0,
           orderedModules.indices.contains(index) {
            secondaryModuleIDs = [orderedModules[index].identifier]
        }
        secondaryModuleIDs = secondaryModuleIDs.filter { loaded.module(withIdentifier: $0) != nil }
        isLoadingLibrary = false
        // Хід пошуку — одразу, у фоні. Перший пошук читає весь переклад
        // (13 с на вільному комп'ютері, під навантаженням понад 20), а з
        // планшета поля програми ніхто не торкається, і ці секунди падали
        // на перший же запит: планшет писав «нічого не знайдено».
        DeskModel.shared.prepareSearch(state: self)

        // Перечитали библиотеку по ходу работы (добавили модуль в «Параметрах»)
        // — полоса переводов встаёт по списку настроек тут же. При первом
        // запуске это делает `applySavedSettings`, и второй раз незачем.
        if hasLoadedLibraryOnce {
            applyModuleRoster(SettingsStore.shared.settings.modules)
        }
        hasLoadedLibraryOnce = true

        // В настройках оригинала трансляция включена (`NdiSendSlide`), значит
        // она нужна на каждом служении — поднимаем сразу, не заставляя лезть
        // в настройки перед началом.
        // Оба сетевых вывода поднимаем по настройкам оригинала.
        //
        // Раньше автозапуск NDI подвешивал интерфейс, но причина была не в
        // самой трансляции: кадр перерисовывался на каждый показ, счётчики
        // канала перерисовывали всё окно несколько раз в секунду, а фон
        // раскодировался заново при каждой перерисовке. Теперь кадр рисуется
        // только при смене содержимого, счётчики наружу не идут, а картинки
        // берутся из кэша — трансляцию можно включать сразу, как в оригинале.
        prewarm()
        if outputs[.ndi].isEnabled { setNDIEnabled(true) }
        if outputs[.web].isEnabled { setWebEnabled(true) }

        // Налаштування вікна «Параметри» (6.1) — останнім рядком: до нього
        // виводи мають бути зібрані з файла умовчань, інакше вони затерли б
        // наші власні значення.
        applySavedSettings()

        // И то, на чём остановились в прошлый раз.
        restoreState()

        // Поки читали, просили перечитати ще раз — робимо це тепер.
        if reloadWanted { reloadLibrary() }
    }

    /// Порядок как в `[BiblePath]`; чего там нет — в конец, по алфавиту.
    private func order(_ modules: [TextModule], using config: IniSettings?) -> [TextModule] {
        guard let wanted = config?.moduleOrder(), !wanted.isEmpty else {
            return modules.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
        }

        var rank: [String: Int] = [:]
        for (index, name) in wanted.enumerated() where rank[name.lowercased()] == nil {
            rank[name.lowercased()] = index
        }
        return modules.sorted { left, right in
            let l = rank[left.identifier.lowercased()] ?? Int.max
            let r = rank[right.identifier.lowercased()] ?? Int.max
            if l != r { return l < r }
            return left.identifier.localizedStandardCompare(right.identifier) == .orderedAscending
        }
    }

    /// Что показывать на полосе вкладок.
    ///
    /// В `[BiblePath]` перечислены модули, которые пользователь сам вынес
    /// наверх, и у каждого стоит признак включённости. Остальное из библиотеки
    /// остаётся доступным, но вкладку не занимает: в полной сборке модулей
    /// полторы сотни, и полоса из них нечитаема.
    private func pinned(from modules: [TextModule], using config: IniSettings?) -> [TextModule] {
        guard let entries = config?.moduleEntries(), !entries.isEmpty else { return modules }

        var enabled: Set<String> = []
        for entry in entries where entry.isEnabled { enabled.insert(entry.name.lowercased()) }

        let chosen = modules.filter { enabled.contains($0.identifier.lowercased()) }
        // Если конфиг не совпал с содержимым папки, лучше показать всё,
        // чем пустую полосу переводов.
        return chosen.isEmpty ? modules : chosen
    }

    /// Подпись вкладки.
    ///
    /// Один и тот же перевод часто есть и в «Цитате из Библии», и в MyBible —
    /// например RST+. Две одинаковые вкладки рядом неразличимы, поэтому в
    /// таком случае дописываем формат.
    ///
    /// Считается один раз при открытии библиотеки: перебирать сотню с лишним
    /// модулей на каждую вкладку при каждой перерисовке — это заметно.
    func tabTitle(for module: TextModule) -> String {
        tabTitles[module.identifier] ?? module.info.shortName
    }

    func setTabNames(long: Bool) { tabNamesLong = long }

    private func rebuildTabTitles() {
        var counts: [String: Int] = [:]
        for module in allModules {
            counts[module.info.shortName.lowercased(), default: 0] += 1
        }
        tabTitles = allModules.reduce(into: [:]) { result, module in
            // «Длинное название» показывает полное имя перевода, как в меню
            // вкладки у оригинала: «Синодальный» вместо «RST+».
            if tabNamesLong {
                result[module.identifier] = module.displayName
                return
            }
            let name = module.info.shortName
            result[module.identifier] = (counts[name.lowercased()] ?? 0) > 1
                ? "\(name) · \(module.format == .myBible ? "MB" : "BQ")"
                : name
        }
    }

    /// Ctrl + колесо: шаг в одну ступень, с разумными границами.
    func zoomLists(by step: Double) {
        listFontSize = min(22, max(9, listFontSize + step))
    }

    /// Вернуться к показу одного перевода.
    func showSingleTranslation() {
        guard !secondaryModuleIDs.isEmpty else { return }
        secondaryModuleIDs = []
    }

    /// Показать папку модуля в Finder — пункт из меню вкладки перевода.
    func revealModule(_ id: String) {
        guard let module = module(id) else { return }
        let url: URL
        if let bq = module as? BibleModule {
            url = bq.directory
        } else {
            url = modulesFolder.appendingPathComponent("\(module.identifier).SQLite3")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleSecondary(_ id: String) {
        if secondaryModuleIDs.contains(id) {
            secondaryModuleIDs.removeAll { $0 == id }
        } else {
            secondaryModuleIDs.append(id)
        }
    }

    /// Вынести модуль на полосу вкладок и сделать основным.
    func promote(_ module: TextModule) {
        if !orderedModules.contains(where: { $0.identifier == module.identifier }) {
            orderedModules.append(module)
        }
        primaryModuleID = module.identifier
    }

    /// (17) «Показывать номера стихов» — отдельно у основного и у второго
    /// перевода.
    ///
    /// `output` закрыт на запись снаружи, и правильно: его собирает
    /// `VisioBible.ini`. Но окно «Параметры» вправе его поправить, иначе
    /// галочка не действует вовсе — а до сих пор так и было.
    func applyVerseNumberFlags(main: Bool, secondary: Bool) {
        guard output != nil else { return }
        output?.showVerseNumbers = main
        output?.showSecondaryVerseNumbers = secondary
        refreshSlide()
    }

    /// Полоса переводов по списку модулей окна «Параметры» (6.1.4).
    /// Порядок строк и галочки задаёт человек, а не `[BiblePath]` оригинала.
    func applyModuleRoster(_ entries: [ModuleRosterEntry]) {
        guard !entries.isEmpty, let library else { return }
        // Песенники живут своим списком — им галочки раскладывает отдельно.
        rebuildSongBooks(entries)

        let wanted = entries.filter { $0.isEnabled && !$0.isSongBook }
        let chosen = wanted.compactMap { entry in
            // По имени библиотеки, а не по имени файла: база MyBible зовётся
            // без `.SQLite3`, и сравнение с именем файла её не находило.
            library.modules.first { $0.identifier.lowercased() == entry.libraryIdentifier.lowercased() }
        }
        // Розпис не про цю теку — жодного її модуля в ньому не названо, ні
        // ввімкненого, ні вимкненого. Тоді смугу не чіпаємо: розпис лишився
        // від іншої теки модулів, і затерти ним живий список не можна.
        //
        // Раніше тут стояло інше: «не знайшлося ЖОДНОГО ввімкненого». Через це
        // знята остання галочка не робила нічого — програма мовчки лишала все,
        // як було. Саме на це власник і скаржився: «при відключенні або
        // включенні модуля в програмі нічого не відбувається».
        let mentioned = entries.contains { entry in
            !entry.isSongBook && library.modules.contains {
                $0.identifier.lowercased() == entry.libraryIdentifier.lowercased()
            }
        }
        guard mentioned else { return }
        orderedModules = chosen
        if !chosen.contains(where: { $0.identifier == primaryModuleID }) {
            primaryModuleID = chosen.first?.identifier ?? ""
        }
        secondaryModuleIDs = secondaryModuleIDs.filter { id in
            chosen.contains { $0.identifier == id }
        }
    }

    /// Підключити те, що переніс майстер імпорту.
    ///
    /// Перенесене лягає в особисту теку, а бібліотека читається з пакета;
    /// перемикати її цілком на особисту теку не можна — зникли б усі
    /// поставкові модулі, шаблони й шрифти. Тому модулі й пісенники
    /// додаються до списку перекладів поіменно, як і додані в «Параметрах»,
    /// а тека з перенесеними фонами — до списку тек із фонами. Шаблони
    /// бібліотека підбирає з особистої теки сама.
    func adoptImported(modules: [URL], backgroundsFolder: URL?) {
        let store = SettingsStore.shared
        var changed = false
        for url in modules where store.addModule(at: url) == nil { changed = true }
        if let folder = backgroundsFolder,
           FileManager.default.fileExists(atPath: folder.path),
           store.addPicturePath(folder) {
            changed = true
        }
        if changed { store.saveOutsideEditing() }
        reloadLibrary()
        reloadBackgroundsFromSettings()
        media.reloadSettingsFromDisk(force: true)
    }

    private func loadBackgrounds() {
        // Фоны лежат рядом с модулями, на уровень выше — так их раскладывает
        // и VisioBible, и наш собственный каталог.
        let folder = modulesFolder.deletingLastPathComponent().appendingPathComponent("BackGrounds")
        let allowed: Set<String> = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        backgroundImages = files
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Интерфейс

    private var dataRoot: URL { modulesFolder.deletingLastPathComponent() }

    /// Своя довідка — «ЧИТАТИ.md» у пакеті. Довідка VisioBible (`.chm`,
    /// `RemoteAPI_*.txt`) більше не шукається.
    var helpFileURL: URL? {
        let own = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app/ЧИТАТИ.md")
        return FileManager.default.fileExists(atPath: own.path) ? own : nil
    }

    private func loadLanguages() {
        // Свои и правленые переводы лежат в папке «Слова»; склейка отдаёт их
        // вместе с оригинальными, и наш файл вытесняет одноимённый чужой.
        let directory = InterfaceLanguageStore.mergedDirectory(
            originals: dataRoot.appendingPathComponent("Language"))
        let catalog = LanguageCatalog(directory: directory)
        guard !catalog.languages.isEmpty else {
            // Файлів перекладу VisioBible немає (чиста установка «Слова»): мова —
            // з убудованих, українська за умовчанням. Раніше тут був просто вихід,
            // наш словник лишався російським, а з ним і весь інтерфейс.
            let code = Defaults.languageCode ?? "uk"
            OurWords.language = Self.builtInLanguages.contains { $0.code == code } ? code : "uk"
            return
        }
        languageCatalog = catalog

        // При перечитуванні тримаємося вже обраної мови, а не тієї, що
        // записана в налаштуваннях: інакше правка перекладу скинула б вибір.
        // Поки людина нічого не обирала — українська: це мова програми за
        // умовчанням, окремого вікна вибору при першому запуску немає.
        let wanted = language?.code ?? Defaults.languageCode ?? "uk"
        language = catalog.language(code: wanted) ?? catalog.language(code: "uk") ?? catalog.languages.first
        OurWords.language = language?.code ?? wanted
        applyOurWordOverrides()
    }

    /// Правки наших подписей из файла перевода текущего языка (секция
    /// `[Slovo]`) — в словарь. Без этого окно «Перевод интерфейса» могло
    /// править только формы автора.
    private func applyOurWordOverrides() {
        let section = language?.forms[OurWords.sectionName] ?? [:]
        OurWords.applyOverrides(section.mapValues(\.caption))
    }

    /// Мови, які «Слово» знає саме, без файлів перекладу VisioBible: підписи
    /// автора йдуть через наш словник так само, як і наші власні.
    static let builtInLanguages: [(code: String, name: String)] = [
        ("uk", "Українська"), ("ru", "Русский"), ("en", "English"), ("de", "Deutsch"),
    ]

    /// Код мови інтерфейсу — файлу перекладу або вбудованої.
    var languageCode: String { language?.code ?? OurWords.language }

    func setLanguage(code: String) {
        guard let picked = languageCatalog?.language(code: code) else {
            // Файла цієї мови немає, але мова вбудована — перемикаємо наш словник.
            guard Self.builtInLanguages.contains(where: { $0.code == code }) else { return }
            language = nil
            Defaults.languageCode = code
            OurWords.language = code
            OurWords.applyOverrides([:])
            bumpMenu()
            return
        }
        language = picked
        Defaults.languageCode = code
        // Наши собственные подписи автор не переводил — их переводим мы сами.
        OurWords.language = code
        applyOurWordOverrides()
        bumpMenu()
    }

    /// Готовый состав меню и списка языков.
    ///
    /// Раньше он собирался заново на каждую перерисовку окна — а перерисовка
    /// случается на любое нажатие. Двадцать языков, шесть разделов и три
    /// десятка пунктов строились по многу раз в секунду просто так.
    /// Пересобираем только при смене языка интерфейса.
    @Published private(set) var menuRevision = 0

    private func bumpMenu() { menuRevision += 1 }

    /// Подпись элемента интерфейса из файла перевода VisioBible.
    func text(_ key: String, form: String = "MainForm", default fallback: String) -> String {
        // Чего нет в файле перевода — берётся запасная русская подпись. Она
        // идёт через наш словарь: иначе в украинском интерфейсе оставались
        // русские слова везде, где у файла перевода нет ключа.
        let spare = OurWords.t(fallback)
        return language?.caption(key, form: form, default: spare) ?? spare
    }

    /// F11 в оригинале — снимок текущего слайда в папку ScreenShots.
    func saveScreenshot() {
        let size = CGSize(width: output?.slideWidth ?? 1920, height: output?.slideHeight ?? 1080)
        // Тем же рисовальщиком, что и зал: снимок обязан показывать ровно то,
        // что видели люди, а не «примерно то же самое».
        let order = SlideDrawing.Order(slide: slide, style: style, preset: slidePreset,
                                       texts: ConstructorSample(slide: slide),
                                       backgroundOverride: backgroundOverride,
                                       withSecondTranslation: !slide.secondaryTexts.isEmpty,
                                       imageURL: { [weak self] name in self?.presetImageURL(name) })
        guard let frame = SlideDrawing.image(order, size: size, opaque: true) else { return }
        let image = NSImage(cgImage: frame, size: size)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let folder = screenshotFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "slide_" + stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".png"
        let file = folder.appendingPathComponent(name)
        guard (try? png.write(to: file)) != nil else { return }

        // Молчаливое сохранение неотличимо от «ничего не произошло»:
        // показываем файл в Finder, чтобы было видно результат.
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func module(_ id: String) -> TextModule? {
        if let cached = moduleCache[id] { return cached }
        guard let found = library?.module(withIdentifier: id) else { return nil }
        moduleCache[id] = found
        return found
    }

    var primaryModule: TextModule? { module(primaryModuleID) }

    private func reloadBooks() {
        Defaults.primaryModule = primaryModuleID
        prewarm()
        books = primaryModule?.books ?? []
        if selectedBookIndex >= books.count { selectedBookIndex = 0 }
        reloadChapters()
    }

    /// Открытие книги.
    ///
    /// Разбор книги занимает сотни миллисекунд — на Псалтирь почти полсекунды.
    /// В главном потоке это выглядит так, будто программа замерла на нажатии.
    /// Поэтому: разобранную книгу отдаём сразу, неразобранную читаем в фоне.
    private func reloadChapters() {
        guard let module = primaryModule, books.indices.contains(selectedBookIndex) else {
            chapters = []
            return
        }
        let book = books[selectedBookIndex]

        if let ready = module.cachedChapters(ofBook: book) {
            isLoadingChapters = false
            applyChapters(ready)
            return
        }

        isLoadingChapters = true
        // Звіряємо і позицію, і саму книгу: поки розділи читалися, могли
        // змінити і вибір книги, і сам переклад — тоді прочитане вже не
        // наше. (`books` — завжди повний список модуля, фільтр заповітів живе
        // окремо у `visibleBooks`, тож позиція тут і номер книги збігаються.)
        let requested = selectedBookIndex
        let wanted = book.index
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed = (try? module.chapters(ofBook: book)) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.selectedBookIndex == requested,
                          self.books.indices.contains(requested),
                          self.books[requested].index == wanted else { return }
                    self.isLoadingChapters = false
                    self.applyChapters(parsed)
                }
            }
        }
    }

    private func applyChapters(_ parsed: [Chapter]) {
        chapters = parsed
        if !chapters.contains(where: { $0.number == selectedChapterNumber }) {
            selectedChapterNumber = chapters.first?.number ?? 1
        }
        // Місце, яке чекало на глави, тепер можна відкрити по-справжньому.
        if let waiting = pendingScripture {
            pendingScripture = nil
            resolveScripture(waiting)
        }
        refreshSlide()
    }

    /// Прохання відкрити місце: глава, як вибрати вірші з наявних і що
    /// зробити, коли все стало на місце (наприклад, показати в залі).
    private struct ScriptureRequest {
        let chapter: Int
        let pick: ([Int]) -> [Int]
        let then: (() -> Void)?
    }

    /// Місце, яке попросили відкрити раніше, ніж прийшли глави книги.
    private var pendingScripture: ScriptureRequest?

    /// Відкрити місце Писання цілком: книга, глава і вірші — одним рухом.
    ///
    /// Заведено окремо, і ось чому. Глави книги читаються з диска у фоні:
    /// між «поставили книгу» і «глави прийшли» минає час. Пункт плану й
    /// запис історії ставили книгу і тут же питали, які в главі є вірші, —
    /// а їх ще не було. Список виходив порожній, вибрані вірші відкидалися
    /// як неіснуючі, і місце відкривалося на першому вірші глави замість
    /// того, який просили. Власник: «при нажатии на ссылку она меняется, а
    /// на место писания не переходит».
    ///
    /// Тепер, якщо глави ще не прийшли, прохання чекає на них і виконується
    /// рівно тоді, коли їх принесли.
    func openScripture(bookPosition: Int, chapter: Int, verses: [Int], then: (() -> Void)? = nil) {
        openScripture(bookPosition: bookPosition, chapter: chapter,
                      pick: { available in verses.filter { available.contains($0) } }, then: then)
    }

    /// Те саме, але вірші вибираються з тих, що справді є в главі, — так
    /// працює адреса «Ів 3:16-18», яка знає номери, а не наявність.
    /// `then` кличеться рівно тоді, коли місце стало: показ у залі до цього
    /// показав би попередній вірш.
    func openScripture(bookPosition: Int, chapter: Int,
                       pick: @escaping ([Int]) -> [Int], then: (() -> Void)? = nil) {
        pendingScripture = nil
        if selectedBookIndex != bookPosition { selectedBookIndex = bookPosition }
        resolveScripture(ScriptureRequest(chapter: chapter, pick: pick, then: then))
    }

    private func resolveScripture(_ request: ScriptureRequest) {
        // Глави ще в дорозі — місце дочекається їх у `applyChapters`.
        guard !isLoadingChapters, let first = chapters.first?.number,
              let last = chapters.last?.number else {
            pendingScripture = request
            return
        }
        // Главу за межами книги підтягуємо до найближчої наявної: опечатка в
        // номері не має лишати вікно зовсім без глави.
        let numbers = chapters.map(\.number)
        selectedChapterNumber = numbers.contains(request.chapter)
            ? request.chapter : min(max(request.chapter, first), last)
        let available = currentChapter?.verses.map(\.number) ?? []
        let wanted = request.pick(available)
        if !wanted.isEmpty { selectedVerseNumbers = wanted }
        scrollToCurrentVerse += 1
        request.then?()
    }

    // MARK: - Несоответствия нумерации переводов (N40)

    /// База несоответствий: у переводов восточного и западного счёта не
    /// совпадают номера псалмов и стихов, и без пересчёта второй перевод на
    /// слайде показывает соседнее место. Правится окном «Редактор
    /// несоответствий нумерации переводов Библии».
    @Published private(set) var numbering = NumberingBase()

    /// Стандарт для переводов, которых в базе нет: у автора там перечислены
    /// только исключения. Меняется в том же окне.
    var defaultNumberingStandard: String {
        UserDefaults.standard.string(forKey: "numberingDefaultStandard") ?? "ru"
    }

    /// Чтение базы — с диска, значит не в главном потоке.
    ///
    /// Здесь же расписываются переводы по стандартам. Это отдельная работа и
    /// тоже не для главного потока: у перевода, про который ещё ничего не
    /// известно, приходится разобрать Псалтирь, чтобы посмотреть на девятый
    /// и сто сорок седьмой псалмы. Ответы запоминаются в своём файле, так что
    /// платим за это один раз.
    func reloadNumbering() {
        let dataRoot = modulesFolder.deletingLastPathComponent()
        let modules = allModules
        let inUse = ([primaryModuleID] + secondaryModuleIDs).compactMap { module($0) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = NumberingBase.load(dataRoot: dataRoot)
            // Тот же файл читает и движок пересчёта — здесь же, в фоне.
            _ = VerseNumbering.shared.loadRules()
            // Без этой строки стандарт находился только у восьми переводов,
            // названных в таблице автора, а всем прочим — включая KJV —
            // молча подставлялся восточный счёт, и пересчёт не срабатывал
            // вовсе. Теперь стандарт считается по строению самого перевода.
            // Сперва те переводы, что сейчас на слайде, и только потом все
            // остальные. Разбор Псалтири у полусотни переводов при первом
            // запуске занимает больше половины минуты, и всё это время
            // второй перевод показывал бы соседнее место молча.
            if !inUse.isEmpty {
                NumberingAssignments.shared.apply(to: .shared, modules: inUse)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.numberingCodes.removeAll()
                        self?.refreshSlide()
                    }
                }
            }
            NumberingAssignments.shared.apply(to: .shared, modules: modules)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.numbering = loaded
                    self.numberingCodes.removeAll()
                    self.refreshSlide()
                }
            }
        }
    }

    /// Стандарт нумерации модуля. Ответ запоминаем: слайд собирается на
    /// каждое нажатие, а перебирать таблицу базы каждый раз незачем.
    private var numberingCodes: [String: String] = [:]

    func numberingCode(ofModule id: String) -> String {
        if let known = numberingCodes[id] { return known }

        // Готовый ответ из памяти движка. Спрашивать здесь сами назначения
        // нельзя: у перевода без посчитанной догадки они разбирают Псалтирь
        // с диска, а это место работает на каждое нажатие. Всё, что нужно,
        // уже разложил `apply` при загрузке библиотеки — в фоне и один раз.
        //
        // Порядок один на всю программу: выбор владельца → догадка по книгам
        // самого перевода → таблица автора. Он же показывается в окне N40,
        // и слайд обязан считать ровно по нему, иначе окно говорит одно,
        // а на экране выходит другое.
        var code = VerseNumbering.shared.standard(ofModule: id).id

        if code.isEmpty {
            // Запасной путь для перевода, которого в библиотеке уже нет:
            // в плане и в истории от него остаётся одно короткое имя.
            var names = [id]
            if let module = module(id), !module.info.shortName.isEmpty {
                names.insert(module.info.shortName, at: 0)
            }
            code = numbering.standardCode(forModuleNames: names) ?? ""
        }

        // Пусто — значит стандарт не опознан. Тогда не переводим вовсе:
        // подставить наугад восточный счёт хуже, чем оставить свои номера,
        // — чужие числа сбивают, а свои нет.
        numberingCodes[id] = code
        return code
    }

    // MARK: - Текущий текст

    var currentBook: BookInfo? {
        books.indices.contains(selectedBookIndex) ? books[selectedBookIndex] : nil
    }

    var currentChapter: Chapter? {
        chapters.first { $0.number == selectedChapterNumber }
    }

    var firstVerseNumber: Int { currentChapter?.verses.first?.number ?? 1 }

    /// Текст выбранных стихов в заданном переводе.
    private func text(inModule id: String) -> String? {
        guard let module = module(id), let book = currentBook else { return nil }
        // Ту же книгу в другом переводе ищем по сквозному номеру канона:
        // модули с неканоническими книгами длиннее обычных, и сопоставление
        // по порядковому номеру ставило «Бытие» напротив чужой книги.
        guard let counterpart = module.counterpart(of: book) else { return nil }

        // Тут нельзя читать с диска. Сборка слайда происходит на каждое
        // нажатие, а разбор книги стоит сотни миллисекунд — именно из-за
        // этого нажатие на книгу отзывалось через секунду. Берём только
        // разобранное; если книга ещё не готова, ставим её в очередь и
        // пересоберём слайд, когда она появится.
        guard let ready = module.cachedChapters(ofBook: counterpart) else {
            scheduleFill(module: module, book: counterpart)
            return nil
        }
        // Перевод с другим счётом глав и стихов адресуется иначе: 22-й псалом
        // Синодального — это 23-й псалом западного счёта, а синодальные
        // «Числа 30:1» — это «Numbers 29:40», совсем другой стих.
        //
        // Пересчёт идёт по базе несоответствий оригинала, но правила её
        // разбирает `VerseNumbering`, а не `NumberingBase`: сверка обоих на
        // всех 856 170 адресах, где в базе есть правила, показала 947
        // расхождений, и настоящий текст модулей всякий раз подтверждал
        // первый. Таблицы уже в памяти, к диску отсюда не ходим.
        //
        // Отрывок, лежащий в одной главе, в другом счёте может перейти её
        // границу — поэтому ответом служит список кусков, а не пара чисел.
        var spans = [VerseSpan(chapter: selectedChapterNumber, verses: selectedVerseNumbers)]
        let target = numberingCode(ofModule: id)
        let source = numberingCode(ofModule: primaryModuleID)
        if id != primaryModuleID, target != source, let canonical = book.canonicalNumber {
            let engine = VerseNumbering.shared
            spans = engine.translate(book: canonical,
                                     chapter: selectedChapterNumber,
                                     verses: selectedVerseNumbers,
                                     from: engine.standard(id: source),
                                     to: engine.standard(id: target),
                                     verseCount: { number in
                                         ready.first { $0.number == number }?.verses.count
                                     })
        }

        // Кілька віршів — кожен зі свого рядка і зі своїм номером. Власник:
        // «было бы лучше при выводе нескольких стихов каждый с новой строки,
        // и номер рядом с ним писать». Номер тут потрібен незалежно від
        // галочки (17): без нього рядки однакові на вигляд, і незрозуміло,
        // де кінчається один вірш.
        let manyVerses = spans.reduce(0) { $0 + $1.verses.count } > 1
        let ownLines = versesOnOwnLines && manyVerses
        let withNumbers = ownLines || (id == primaryModuleID
            ? (output?.showVerseNumbers ?? false)
            : (output?.showSecondaryVerseNumbers ?? false))

        let picked = spans.flatMap { span -> [String] in
            guard let chapter = ready.first(where: { $0.number == span.chapter }) else { return [] }
            return span.verses.sorted().compactMap { number -> String? in
                guard let text = chapter.verse(number)?.text else { return nil }
                return withNumbers ? "\(number) \(text)" : text
            }
        }
        return picked.isEmpty ? nil : picked.joined(separator: ownLines ? "\n" : " ")
    }

    /// Раздаёт текущий слайд всем выводам. Каждый получает своё содержимое и
    /// свой стиль — состав текста и оформление у каналов разные.
    /// Раздаёт выводам то, что показывается в зале, — не предпросмотр.
    /// Запомнить, на чём остановились.
    ///
    /// Пишется в `UserDefaults`: там запись буферизуется, и звать это на
    /// каждое движение недорого. Показ в зале нарочно не запоминаем — при
    /// следующем запуске программа не должна сама что-то выводить.
    private func rememberState() {
        guard !isLoadingLibrary, isRestored else { return }
        Defaults.lastMode = mode.rawValue
        Defaults.lastBookClass = bookClass.rawValue
        Defaults.lastBookIndex = selectedBookIndex
        Defaults.lastChapter = selectedChapterNumber
        Defaults.lastVerses = selectedVerseNumbers
        Defaults.lastTemplate = templateName
        Defaults.slideStyle = try? JSONEncoder().encode(style)
        Defaults.commonBackground = commonBackgroundPath
        Defaults.slideBackground = slideBackgroundPath
        Defaults.showsCommonBackground = showsCommonBackground
        Defaults.tabNamesLong = tabNamesLong
        Defaults.arrowsLinked = arrowsLinked
        Defaults.lastSongBook = songBookID
        Defaults.lastSongIndex = songIndex
        Defaults.lastSongPart = songPartIndex
    }

    /// Пока идёт восстановление, запоминать нечего: иначе первые же
    /// присваивания затрут записанное наполовину поднятыми значениями.
    private var isRestored = false

    /// Вернуть то, на чём остановились в прошлый раз. Зовётся один раз,
    /// когда библиотека уже открыта и номера книг снова что-то значат.
    private func restoreState() {
        defer { isRestored = true }

        // Самопроверке нужен предсказуемый старт: она рассчитывает на первую
        // книгу и разобранную главу. Возвращённое место владельца (какая-нибудь
        // 1-е Тимофею, ещё не разобранная с диска) роняло половину проверок —
        // причём только в пакете, где настоящие записи, и не в отладке.
        if CommandLine.arguments.contains("--selftest") { return }

        if let name = Defaults.lastTemplate, !name.isEmpty,
           schemes?.template(named: name) != nil {
            applyTemplate(named: name)
        }
        // Правленый вид кладётся ПОВЕРХ шаблона: шаблон задаёт основу, а
        // человек мог после этого поменять шрифт, размер, цвет или поля, и
        // его правки главнее. Не разобралось — значит запись от прежней
        // сборки; тогда остаёмся на шаблоне, это не поломка.
        if let data = Defaults.slideStyle,
           let saved = try? JSONDecoder().decode(SlideStyle.self, from: data) {
            style = saved
        }
        // Шлях міг застаріти (програму перенесли, ресурси тепер в іншій теці) —
        // шукаємо той самий файл за хвостом шляху в поточних коренях даних.
        if let path = Defaults.commonBackground.flatMap(DataPaths.existing) {
            commonBackgroundPath = path
            if path != Defaults.commonBackground { Defaults.commonBackground = path }
        }
        if let path = Defaults.slideBackground.flatMap(DataPaths.existing) {
            slideBackgroundPath = path
            if path != Defaults.slideBackground { Defaults.slideBackground = path }
        }
        if let shows = Defaults.showsCommonBackground { showsCommonBackground = shows }
        if let long = Defaults.tabNamesLong { tabNamesLong = long }
        if let linked = Defaults.arrowsLinked { arrowsLinked = linked }

        if let raw = Defaults.lastBookClass, let value = BookClass(rawValue: raw) {
            bookClass = value
        }
        if let index = Defaults.lastBookIndex, books.indices.contains(index) {
            selectedBookIndex = index
            if let chapter = Defaults.lastChapter,
               chapters.contains(where: { $0.number == chapter }) {
                selectedChapterNumber = chapter
                let available = currentChapter?.verses.map(\.number) ?? []
                let verses = (Defaults.lastVerses ?? []).filter { available.contains($0) }
                if !verses.isEmpty { selectedVerseNumbers = verses }
            }
        }

        if let book = Defaults.lastSongBook, !book.isEmpty,
           songBooks.contains(where: { $0.id == book }) {
            songBookID = book
            songIndex = Defaults.lastSongIndex
            songPartIndex = Defaults.lastSongPart
        }

        // Свой шаблон восстанавливать не надо: привязка вывода к шаблону
        // лежит своим файлом рядом с шаблонами и переживает запуск сама.
        if let mine = presets.preset(for: .screen) { templateName = mine.name }

        // Режим — последним: он решает, что показывать, и должен встать
        // поверх уже поднятого выбора.
        if let raw = Defaults.lastMode, let value = WorkMode(rawValue: raw) { mode = value }
    }

    /// Поднять окно слайда. Зовётся один раз при запуске программы.
    func startProjection() {
        projection.setVisible(true)
        // Плеер сообщает о смене кадра сам: паузу, конец файла и затемнение
        // окно слайда иначе узнает только со следующим стихом.
        // Указка: сдвинулась — обновить слой проектора и кадр трансляции.
        SlidePointer.shared.onChange = { [weak self] in self?.applyPointer() }
        // Наближення до точки фокуса: різати картинку вміє сам плеєр, а що
        // саме вирізати — вирішує `SlideFocus`. Змінилося наближення —
        // перемальовуємо показане, не чіпаючи вихідної сторінки.
        // Ріжемо по показаному вікну: воно їде до цілі плавно, і сторінка
        // в залі пливе разом із ним, а не стрибає.
        media.focusCrop = { image in SlideFocus.crop(image, rect: SlideFocus.shared.shownRect) }
        SlideFocus.shared.onChange = { [weak self] in self?.applyFocus() }
        SlideFocus.shared.onShownChange = { [weak self] in self?.media.refreshStill() }
        media.onScreenChanged = { [weak self] in
            guard let self else { return }
            // Экран один: пока на нём кадр плеера или картинка, текста в зале
            // больше нет — и «живой» слайд гасим, а не прячем под кадр. Иначе
            // после скрытия картинки, паузы или конца фильма из-под него
            // выныривал прежний стих. Владелец видел это как «вместо
            // презентации — последний открытый текст Библии».
            if self.media.isVideoOnScreen, !self.liveSlide.isBlank { self.liveSlide = .blank }
            // И пересобрать выводы целиком, а не только кадр и сеть: пока
            // здесь трогали лишь кадр, `lastScreenSlide`, трансляция и
            // веб-страница жили с прежним текстом под картинкой.
            self.pushToOutputs()
        }
        // Фильм открыли и он пошёл — значит его и надо показать. Прежде он
        // играл «в стол»: на проекторе оставался стих, пока оператор не
        // нажмёт «Показать», а кнопка «Видео на экран» помогала лишь со
        // второго раза.
        media.onWantsHall = { [weak self] in self?.showMediaInHall() }
        // Звук файла — в трансляцию, минуя главный поток: отвод зовёт из
        // звукового потока, а канал сам решает, брать ли его сейчас.
        let network = ndi
        let wifi = webVideo
        media.networkAudioSink = { planar, channels, samples, rate in
            network.submitPlayerAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
            wifi.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
        }
        media.onPlaybackChanged = { [weak self] in
            guard let self else { return }
            // Потоку без дорожки (HLS, YouTube через yt-dlp) отвод не
            // достаётся — звук берётся только системным захватом.
            self.ndi.audioNeedsSystemCapture = self.media.isYouTube || self.media.hostedView != nil
                || (self.media.isStream && !self.media.hasAudioTap)
            self.ndi.audioWanted = self.media.isPlaying || self.backing.isPlaying
            // Пока играет основной плеер, фонограмма в сеть не идёт: два
            // потока разом — каша.
            self.backing.mainPlayerIsPlaying = self.media.isPlaying
        }
        // Фонограмма — в трансляцию тем же отводом, что и плеер.
        backing.networkAudioSink = { planar, channels, samples, rate in
            network.submitPlayerAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
            wifi.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
        }
        backing.onChange = { [weak self] in
            guard let self else { return }
            self.ndi.audioWanted = self.media.isPlaying || self.backing.isPlaying
        }
        pushToOutputs()
    }

    /// Второй перевод — тот, что показан рядом с основным.
    private var secondModule: (any TextModule)? {
        guard let id = secondaryModuleIDs.first else { return nil }
        return allModules.first { $0.identifier == id }
    }

    /// Строки, которые шаблон Конструктора расставляет по своим объектам:
    /// сам стих, второй перевод, адрес, название песни, имена переводов.
    private func refreshSlideTexts() {
        slideTexts = texts(for: liveSlide)
    }

    /// Тексты объектов шаблона для данного слайда: стих, адрес, названия
    /// переводов, название песни.
    private func texts(for shown: Slide) -> ConstructorSample {
        ConstructorSample(
            slide: shown,
            songTitle: shownSong?.song.title ?? "",
            moduleNameFirst: primaryModule?.displayName ?? "",
            moduleShortNameFirst: primaryModule.map { tabTitle(for: $0) } ?? "",
            moduleNameSecond: secondModule?.displayName ?? "",
            moduleShortNameSecond: secondModule.map { tabTitle(for: $0) } ?? "")
    }

    /// Тексты для ПРЕДПРОСМОТРА — из подготовленного слайда, а не из зала.
    ///
    /// `slideTexts` собирается из `liveSlide` — того, что видит зал. Пока
    /// предпросмотр брал их же, при выключенном показе он рисовал свой
    /// шаблон без единой буквы (в зале пусто — и текстов нет), а при
    /// включённом — под подготовленным стихом стоял текст стиха ИЗ ЗАЛА:
    /// предпросмотр «отставал на один слайд» и «путал» содержимое
    /// (замечания 4 и 5). Снимки тура это и показали: фон есть, стиха нет.
    var previewTexts: ConstructorSample { texts(for: previewSlide) }
    /// Самопроверке: тексты объектов для любого слайда — эталон сравнения.
    func slideTextsForCheck(of shown: Slide) -> ConstructorSample { texts(for: shown) }

    /// Что сейчас видит зал.
    ///
    /// Гасят его три вещи: показ выключен, включено затемнение (F12), включён
    /// «фон без текста» (Ctrl+F5). Раньше это решал каждый вывод сам, и решали
    /// они по-разному: проектор гас, а трансляция и веб-страница продолжали
    /// висеть с прежним стихом. Теперь ответ один на всех — и разойтись им
    /// больше негде.
    private var hallSlide: Slide {
        guard isLive, !isBlackout, !isTextHidden else { return .blank }
        return liveSlide
    }

    private func pushToOutputs() {
        refreshSlideTexts()
        let hall = hallSlide

        let screen = outputs[.screen]
        // Затемнение — чёрный экран без оговорок: ни текста, ни фона, ни
        // своего шаблона. Прочие способы погасить оставляют зал с одним фоном.
        var screenStyle = screen.effectiveStyle
        var screenPreset = preset(for: .screen)
        if isBlackout {
            var black = SlideStyle()
            black.backgroundColor = .black
            screenStyle = black
            screenPreset = nil
        }
        NDITrace.say("зал: фон=\(backgroundOverride ?? "шаблона") общий=\(showsCommonBackground)"
                     + " свой=\(slideBackgroundPath ?? "нет") показ=\(isLive) пусто=\(hall.isBlank)")
        // Пока в зале кадр — под ним НЕ рисуем ничего. Прежде стих лежал под
        // кадром всё время показа, и при каждом закрытии на миг показывался
        // из-под уходящей картинки. Убирать его надо не поверх, а вовсе.
        let underMedia = media.isVideoOnScreen
        lastScreenSlide = screen.compose(underMedia ? .blank : hall)
        projection.update(slide: lastScreenSlide,
                          style: screenStyle,
                          preset: screenPreset,
                          texts: slideTexts,
                          backgroundOverride: backgroundOverride,
                          imageURL: { [weak self] name in self?.presetImageURL(name) })

        // Кадр плеера — в то же окно слайда, поверх текста; и в сеть — по
        // тому же признаку показа.
        applyMediaOnScreen()
        applyNDIVideo()

        // NDI получает своё содержимое и свой стиль: у него, как правило,
        // прозрачная подложка и другая частота кадров.
        pushToNDI()

        let pages = outputs[.web]
        if pages.isEnabled, underMedia {
            // На странице во время показа стоял стих Библии — тот самый,
            // что уже снят с проектора. Отдаём странице то же, что и залу:
            // фотографию или страницу презентации, а под фильм — пустоту:
            // кино в браузер этим каналом не передать.
            publishStillToWeb()
        } else if pages.isEnabled {
            // Раскладку шаблона отдаём вместе со слайдом: страница
            // `slovo-slide.html` рисует по ней те же объекты, что и проектор.
            // Страницы автора этой секции не читают и работают как прежде.
            web.setTemplate(preset(for: .web) ?? screenPreset,
                            withSecondTranslation: !hall.secondaryTexts.isEmpty,
                            text: { [weak self] object in
                                self?.slideTexts.text(for: object) ?? ""
                            },
                            imageURL: { [weak self] name in self?.presetImageURL(name) },
                            fontURL: { family in FontLoader.fileURL(forFamily: family) })
            let outgoing = pages.compose(hall)
            lastWebPayload = RemoteSlidePayload(slide: outgoing, mode: web.mode,
                                                moduleNames: web.moduleNames, next: [])
            web.publish(slide: outgoing, kind: .web)
        }
    }

    /// Картинка показа — на веб-страницу.
    ///
    /// Отдельной раскладкой, а не новым полем протокола: страница давно умеет
    /// рисовать фон картинкой, и менять ради этого пакет, который слушают и
    /// чужие приёмники, ни к чему.
    private func publishStillToWeb() {
        var payload = RemoteSlidePayload(slide: .blank, mode: web.mode,
                                         moduleNames: web.moduleNames, next: [])
        payload.layout = WebSlideLayout(
            background: .init(color: .black, imageID: webStillID(), fillMode: "contain"),
            objects: [])
        lastWebPayload = payload
        web.publish(payload)
    }

    /// Что ушло в зал и на страницу последним.
    ///
    /// Держим не ради удобства, а ради проверки: содержимое окна слайда и
    /// страницы иначе видно только глазами, а глазами эти две ошибки —
    /// стих под кадром и стих в браузере — и не были замечены месяцами.
    private(set) var lastScreenSlide = Slide.blank
    private(set) var lastWebPayload: RemoteSlidePayload?

    /// Записать показанную картинку файлом и отдать её короткое имя.
    ///
    /// Каждой новой странице — своё имя: браузер держит картинки в памяти по
    /// адресу, и под прежним именем он показал бы прошлую страницу.
    private func webStillID() -> String? {
        // У веб іде те саме, що в зал: уже вирізане точкою фокуса.
        guard let still = media.shownStill ?? media.still else { return nil }
        if let known = webStill, known.image === still { return known.id }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-web-still", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        webStillCounter &+= 1
        let file = folder.appendingPathComponent("страница-\(webStillCounter).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, still,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let id = web.registerImage(path: "media-still-\(webStillCounter)", url: file)
        webStill = (still, id)
        return id
    }

    private var webStill: (image: CGImage, id: String)?
    private var webStillCounter = 0

    /// Отдать трансляции то, что идёт в зал.
    ///
    /// Отдельным местом, а не строкой внутри `pushToOutputs`, потому что то же
    /// самое нужно в миг включения трансляции. Раньше там звали `update` без
    /// шаблона, и первый кадр уходил в сеть нарисованным по-старому — свой
    /// шаблон из Конструктора появлялся только со следующим стихом.
    private func pushToNDI(blanked: Bool = false) {
        let network = outputs[.ndi]
        // Кадры нужны и без основного NDI: их ждут «Слово Wi-Fi» и «Видео по Wi-Fi».
        guard ndi.feeds else { return }

        // «Отображать Видео» (`NdiSendVideo`): пока в зале идёт видео, на
        // микшер уходит оно, а не слайд, — так же, как на проекторе, где окно
        // видео накрывает окно слайда. Настройка была, а дела за ней не было.
        applyNDIVideo()
        if network.sendsVideo, media.isVideoOnScreen, !blanked { return }
        // «Убрать» и затемнение гасят зал — значит гасят и трансляцию.
        // Раньше NDI слал слайд, что бы ни делал оператор: кнопка убирала
        // картинку со стены, а на микшере она оставалась висеть.
        let hall = blanked ? Slide.blank : hallSlide
        NDITrace.say("зал: показ=\(isLive) затемнення=\(isBlackout) без тексту=\(isTextHidden)"
                     + " режим=\(mode.rawValue) пусто=\(hall.isBlank)")
        // Гашение идёт своей короткой дорогой: пустой кадр отдаётся очереди
        // напрямую, без отрисовки и без сверки отпечатков. Так у кнопки
        // «Убрать» не остаётся ни одного места, где она может промолчать.
        // Гашение вслед за показом растворяем: рывок на микшере читается
        // как сбой связи. «Убрать» при обычном слайде гасит по-прежнему разом.
        guard !hall.isBlank else {
            ndi.blank(fade: media.still != nil || media.hasVideo ? Defaults.mediaFadeSeconds : 0)
            return
        }
        ndi.update(slide: network.compose(hall), preset: preset(for: .ndi), texts: slideTexts,
                   imageURL: { [weak self] name in self?.presetImageURL(name) })
    }

    /// Подключить или отключить видео на канале трансляции.
    ///
    /// Зовётся из `pushToNDI`, то есть на всякую смену состояния зала: показ,
    /// затемнение, «пустой слайд», конец файла. Отдельного наблюдателя не
    /// заводим — состояние и так проходит здесь целиком.
    /// Кадр плеера показывается в окне слайда — там же, где текст Библии и
    /// песни. Своего окна у плеера нет: экран в зале один.
    private func applyMediaOnScreen() {
        // «Скрыть» гасит зал целиком — и кадр плеера с картинкой тоже, а не
        // только текст: прежде скрытая картинка оставалась в зале.
        let shown = isLive && media.isVideoOnScreen
        projection.applyVideo(shown ? media : nil)
        projection.hostWeb(media.hostedView, shown: shown)
    }

    /// Наближення змінилося: показане перемальовуємо, а в мережу і на
    /// веб-сторінку йде вже вирізаний шматок.
    func applyFocus() {
        media.refreshStill()
        webStill = nil
        refreshSlide()
    }

    /// Указка — на те выводы, что выбраны в настройках.
    func applyPointer() {
        let pointer = SlidePointer.shared
        projection.applyPointer(pointer.look.toProjector ? pointer.mark : nil, look: pointer.look)
        ndi.setPointer(pointer.look.toNDI ? pointer.mark : nil, look: pointer.look)
    }

    private func applyNDIVideo() {
        let network = outputs[.ndi]
        let wanted = network.isEnabled && network.sendsVideo && media.isVideoOnScreen && isLive
        guard wanted != media.sendsToNetwork else { return }
        if wanted {
            media.onNetworkFrame = { [weak self] buffer in
                MainActor.assumeIsolated { self?.ndi.submitVideo(buffer) }
            }
            // Фотография и страница презентации идут той же дорогой, но
            // одним кадром: у них нет потока, который можно тянуть.
            media.onNetworkStill = { [weak self] image in
                MainActor.assumeIsolated { self?.ndi.submitImage(image) }
            }
            // Перехід між сторінками показу канал малює сам, по кадру на
            // такт: у мережу йде потік, і «як змінилася сторінка» там треба
            // не оголосити, а намалювати — те саме, що для слайда.
            media.onNetworkStillTransition = { [weak self] from, to, kind, seconds in
                MainActor.assumeIsolated { self?.ndi.submitImageTransition(from: from, to: to,
                                                                          kind: kind, seconds: seconds) }
            }
            media.sendsToNetwork = true
            if let still = media.shownStill ?? media.still { ndi.submitImage(still) }
            NDITrace.say("зал: відео йде в трансляцію замість слайда")
        } else {
            media.sendsToNetwork = false
            media.onNetworkFrame = nil
            media.onNetworkStill = nil
            media.onNetworkStillTransition = nil
            // Видео кончилось — на канале должен снова оказаться слайд, а не
            // застывший последний кадр. И появиться он должен так же плавно,
            // как уходит кадр с проектора.
            ndi.resumeSlide(fade: Defaults.mediaFadeSeconds)
            NDITrace.say("зал: видео с трансляции снято, вернули слайд")
        }
    }

    /// Готовый слайд со стороны — из модуля «Текст», из плана, из песни.
    /// `live` решает, уходит он только в предпросмотр или сразу в зал.
    func present(_ ready: Slide, live: Bool) {
        slide = ready
        if live {
            // Сперва новый слайд, потом снятие кадра: снятие кадра само
            // пересобирает выводы, и делать это со вчерашним слайдом нельзя.
            liveSlide = ready
            hallTakesText()
            if !isLive { isLive = true }
        }
        pushToOutputs()
        if live { DeskModel.shared.rememberLive(state: self) }
    }

    /// Выводит подготовленный слайд в зал: двойной щелчок, Enter или F5.
    /// Если показ был выключен — включается, как в оригинале.
    func showCurrent() {
        // «Показати» після «Чорного екрана» мусить повернути картину на будь-
        // якій вкладці. Вкладки показу, плеєра й тексту віддають показ собі й
        // виходять раніше, ніж Біблія доходить до зняття затемнення нижче, —
        // і з пульта зал так і лишався чорним: «Чорний» не перемикач, а іншої
        // кнопки, щоб зняти затемнення, на пульті немає. Знайшла це перевірка
        // планшета 2026-09-11.
        if mode == .text || mode == .pictures || mode == .presentation || mode == .media,
           isBlackout || isTextHidden {
            resumeFromHiddenStates()
            refreshSlide()
        }
        // Enter и F5 в режиме «Текст» выводят страницу набора.
        if mode == .text, TextModuleModel.shared.showIfReady() { return }
        // В показе картинок и презентаций в зал уходит страница показа.
        // Прежде кнопка звала сюда всегда, и в зал уносило последнее место
        // из Библии или куплет песни — то, что человек открывал до этого.
        if NativeShowWorkspace.handleShow(mode: mode) { return }
        // В режиме «Медиа» кнопка выводит кадр плеера — фильм или картинку.
        if mode == .media, showMediaInHall() { return }
        // Вкладкам без своего текста нечего выводить «по-старому»: прежде
        // сюда проваливался чужой слайд с другой вкладки.
        if mode == .text || mode == .pictures || mode == .presentation || mode == .media { return }
        // Слайд — ровно под эту вкладку, а не то, что готовила предыдущая.
        syncSlideToMode()
        // Показ при затемнении или пустом слайде обязан ВЕРНУТЬ картину.
        // Без этого выходило наоборот: `slide` в таком состоянии пуст, и F5
        // уносил в зал пустоту — то есть гасил зал вместо того, чтобы
        // показать подготовленное место.
        if isBlackout || isTextHidden {
            resumeFromHiddenStates()
            refreshSlide()
        }
        // Сперва новый слайд, потом снятие кадра: снятие кадра само
        // пересобирает выводы, и делать это со вчерашним слайдом нельзя.
        liveSlide = slide
        hallTakesText()
        if !isLive { isLive = true }
        pushToOutputs()
        DeskModel.shared.rememberLive(state: self)
    }

    /// Текст занял экран в зале.
    ///
    /// Экран один: пока на нём стоит кадр плеера, стих под ним не виден
    /// вовсе. Поэтому вывод текста снимает кадр — и с проектора, и с
    /// трансляции, — а не оставляет его висеть поверх.
    private func hallTakesText() {
        // Спрашиваем «есть ли кадр», а не «виден ли он сейчас».
        //
        // Замечание 4, дословный ход владельца: показал слайды презентации,
        // нажал «Скрыть», перешёл на Библию, выбрал стих, нажал «Показать» —
        // и на проекторе снова слайд презентации. Причина: «Скрыть» гасит зал
        // (`isLive = false`), а вслед за ним `MediaHotkeys` ставит картинке
        // запрет `.hiddenSlide`. Стало быть, к этой строке `isVideoOnScreen`
        // уже false, старая проверка выходила ни с чем и запрета
        // `.slideTookOver` не ставила. Дальше «Показать» включало зал, запрет
        // `.hiddenSlide` снимался — и ничем не удержанная картинка
        // возвращалась на стену поверх стиха, а сам стих уходил под неё.
        //
        // Теперь запрет ставится по наличию картинки или файла, и снятие
        // `.hiddenSlide` его не отменяет: кадр вернётся в зал только тогда,
        // когда его позовут — «Показать» в плеере или на вкладке показа.
        guard media.hasMedia else { return }
        NDITrace.say("зал: текст зайняв екран, заборони до=\(media.screenSuppression.rawValue)")
        media.screenSuppression.insert(.slideTookOver)
    }

    /// Кадр плеера в зал — то же, что «Показать» делает для стиха.
    ///
    /// `false` — показывать нечего: ни файла, ни картинки.
    @discardableResult
    func showMediaInHall() -> Bool {
        guard media.mediaURL != nil || media.still != nil else { return false }
        media.screenSuppression.subtract([.slideTookOver, .stopped])
        // Галочка «Видео на экран» (16.5) — то самое, о чём просит кнопка.
        if !media.videoToScreen { media.videoToScreen = true }
        if !isLive { isLive = true }
        // Вся сборка выводов: под кадром не должно остаться текста ни на
        // проекторе, ни в трансляции, ни на веб-странице.
        pushToOutputs()
        return true
    }

    /// Включение и выключение веб-слайдов.
    func setWebEnabled(_ enabled: Bool) {
        outputs[.web].isEnabled = enabled
        guard enabled else { web.stop(); return }

        web.mode = .bible
        web.moduleNames = ([primaryModuleID] + secondaryModuleIDs).compactMap { id in
            guard let module = module(id) else { return nil }
            let short = module.info.shortName.isEmpty ? module.identifier : module.info.shortName
            return RemoteModuleName(short: short, full: module.info.name)
        }
        // Заготовки для Библии и песен — готовыми страницами в списке.
        if WebSlideSeeder.seed(store: SettingsStore.shared) > 0 || outputs.web.pages.isEmpty {
            outputs.web.pages = SettingsStore.shared.settings.webSlides.map {
                WebOutputSettings.WebPage.make(fileName: $0.fileName,
                                               title: $0.details.isEmpty ? $0.name : $0.details)
            }
        }
        web.start(settings: outputs.web, dataRoot: modulesFolder.deletingLastPathComponent())
        web.publish(slide: outputs[.web].compose(slide), kind: .web)
    }

    /// Включение и выключение сетевой трансляции.
    func setNDIEnabled(_ enabled: Bool) {
        outputs[.ndi].isEnabled = enabled
        if enabled {
            ndi.start(rules: outputs[.ndi])
            refreshSlideTexts()
            pushToNDI()
        } else {
            ndi.stop()
        }
    }

    /// Правила NDI поменялись на ходу — частота кадров, фон, показ видео.
    /// «Видео по Wi-Fi»: включить или выключить канал и подключить его к
    /// насосу кадров NDI.
    func applyWebVideo(_ options: ProgramOptions) {
        let enabled = options.webVideoEnabled ?? false
        webVideo.apply(enabled: enabled, height: options.webVideoHeight ?? 720,
                       bitrateKbps: options.webVideoKbps ?? 3000)
        ndi.setWebVideo(webVideo, enabled: enabled)
    }

    func applyNDIRules() {
        guard outputs[.ndi].isEnabled else { return }
        ndi.apply(rules: outputs[.ndi])
    }

    /// То, что видит оператор в предпросмотре: содержимое своего канала.
    var previewSlide: Slide { outputs[.preview].compose(slide) }
    var previewStyle: SlideStyle { outputs[.preview].effectiveStyle }

    func refreshSlide() {
        rememberState()
        // В режиме «Песни» слайд собирает `showSongPart`, а не место Писания.
        // Без этой отсечки любой фоновый пересбор — дочитанная книга,
        // применённые настройки, пересчёт нумерации, смена шаблона — молча
        // подменял куплет стихом из открытой в фоне главы. Владелец видел
        // это в зале: вместо песни на экране появлялось Писание.
        // Затемнение (F12) и «фон без текста» (Ctrl+F5) гасят зал целиком —
        // и проверять их надо ДО песенника. Пока песенник перехватывал
        // пересборку первым, обе кнопки в режиме «Песни» не гасили ничего:
        // `showSongPage` заново отдавал ту же часть песни.
        if isBlackout || isTextHidden {
            slide = .blank
            pushToOutputs()
            return
        }
        if mode == .songs {
            // Ничего не ищем: берём ровно то, что уже показано.
            // Держим ту же страницу, на которой стоим: пересборка случается
            // от чего угодно, и сбрасывать оператора на начало куплета нельзя.
            if !songPages.isEmpty { showSongPage() } else if let shown = shownSong {
                showSongPart(shown.song, shown.part)
            }
            return
        }
        guard let book = currentBook, !selectedVerseNumbers.isEmpty else {
            slide = .blank
            pushToOutputs()
            return
        }

        let main = text(inModule: primaryModuleID) ?? ""
        let secondary = secondaryModuleIDs.compactMap { text(inModule: $0) }

        let address = reference(for: book)

        // Разбивка на страницы. Пока переводов два, оставляем как было: у
        // автора для пары переводов своя разметка шаблона со своими местами
        // под текст, и делить её надо вместе с ней, а не по одному тексту.
        var shown = main
        // Разбиваем только ОДИН стих, если он длинный. Когда оператор выделил
        // несколько стихов, он сделал это нарочно и просил вывести их на один
        // экран — дробить его выбор нельзя. У автора для этого есть
        // `VersSubDivide`, но владелец просил прямо обратного, и его слово
        // здесь главнее настройки.
        if secondary.isEmpty, !main.isEmpty, selectedVerseNumbers.count == 1 {
            if address != paginatedAddress {
                paginatedAddress = address
                biblePages = PlainTextDocument(title: "", body: main).pages(biblePagination)
                biblePageIndex = 0
            }
            if biblePages.count > 1, biblePages.indices.contains(biblePageIndex) {
                shown = biblePages[biblePageIndex]
            }
        } else {
            biblePages = []
            biblePageIndex = 0
            paginatedAddress = ""
        }

        slide = Slide(mainText: shown,
                      secondaryTexts: secondary,
                      reference: address,
                      isBlank: shown.isEmpty && secondary.isEmpty)
        // «В историю заносятся адреса всех стихов, которые были ПЕРВЫМИ
        // ПОКАЗАНЫ в окне слайда» (5.1.11): предпросмотр не пишет ничего, но
        // при связанной навигации смена предпросмотра и есть показ в зале.
        if followLive {
            // Связанные стрелки выводят стих в зал так же, как «Показать»:
            // без этого кадр плеера оставался поверх слайда. Сперва слайд,
            // потом кадр — см. `showCurrent`.
            liveSlide = slide
            hallTakesText()
            // «В историю заносятся адреса всех стихов, которые были ПОКАЗАНЫ
            // в окне слайда» — значит при скрытом показе писать нечего: зал
            // этого места не видел. Раньше каждая связанная стрелка при
            // нажатом Esc добавляла запись о том, чего не было.
            if isLive { DeskModel.shared.rememberLive(state: self) }
        } else if !slide.isBlank,
                  liveSlide.reference == slide.reference,
                  liveSlide.mainText.isEmpty {
            // Стрелка могла увести слайд в зал раньше, чем книга дочиталась с
            // диска: тогда на проектор ушёл адрес БЕЗ текста, и таким он
            // оставался навсегда — дочитанное обновляло только предпросмотр.
            // Догоняем: адрес тот же, текст появился — значит это он и есть.
            liveSlide = slide
        }
        pushToOutputs()
    }

    /// Книги, которые уже поставлены в очередь на разбор, — чтобы не пускать
    /// один и тот же файл в работу несколько раз подряд.
    private var filling: Set<String> = []

    private func scheduleFill(module: TextModule, book: BookInfo) {
        let key = "\(module.identifier)#\(book.index)"
        guard !filling.contains(key) else { return }
        filling.insert(key)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? module.chapters(ofBook: book)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.filling.remove(key)
                    self.refreshSlide()
                }
            }
        }
    }

    var currentTemplate: SchemeLibrary.Template? {
        guard let schemes, !templateName.isEmpty else { return nil }
        return schemes.template(named: templateName)
    }

    /// Выбор шаблона слайда — вместе с ним меняются шрифты, цвета и фон.
    func applyTemplate(named name: String) {
        guard let schemes, let style = schemes.slideStyle(named: name, base: style) else { return }
        templateName = name
        self.style = style
        // Свой фон человек выбирал не для одного шаблона: смена шаблона его
        // не отменяет. Раньше отменяла — и выбор терялся молча.
        applyBackgrounds()
    }

    /// Применить свой шаблон из Конструктора — или снять его.
    ///
    /// Снятый шаблон возвращает слайд к авторскому: так человек всегда может
    /// вернуться к тому, что работало.
    /// `forSongs` — призначити (або зняти) шаблон саме для пісень: Біблія й
    /// решта лишаються зі спільним.
    func applyPreset(_ preset: SlidePreset?, forSongs: Bool = false) {
        if forSongs {
            if let preset {
                presets.assign(preset, to: .screen, songs: true)
                presets.assign(preset, to: .preview, songs: true)
                presets.assign(preset, to: .ndi, songs: true)
            } else {
                presets.unassign(.screen, songs: true)
                presets.unassign(.preview, songs: true)
                presets.unassign(.ndi, songs: true)
            }
            objectWillChange.send()
            refreshSlide()
            pushToOutputs()
            return
        }
        // Зал, предпросмотр и трансляция держатся вместе: предпросмотр затем и
        // нужен, чтобы видеть, что уйдёт в зал, а трансляция показывает тот же
        // слайд, только без подложки — за подложку отвечает правило вывода
        // (`NdiTransparentBackGr`), а не отдельный шаблон. Пока у NDI был свой
        // шаблон, правка в Конструкторе доходила до зала и не доходила до сети:
        // человек менял, а на микшере всё оставалось как было.
        if let preset {
            presets.assign(preset, to: .screen)
            presets.assign(preset, to: .preview)
            presets.assign(preset, to: .ndi)
            templateName = preset.name
        } else {
            presets.unassign(.screen)
            presets.unassign(.preview)
            presets.unassign(.ndi)
        }
        objectWillChange.send()
        refreshSlide()
        pushToOutputs()
    }

    /// Перечитать свои шаблоны с диска: Конструктор пишет их файлами.
    func reloadPresets() {
        presets.reload()
        objectWillChange.send()
        refreshSlide()
        pushToOutputs()
    }

    /// Где искать картинку объекта своего шаблона.
    ///
    /// Полный путь берём как есть. Одно имя файла — ищем в папках авторских
    /// шаблонов: объекты приходят из них, и там же лежат их картинки. Папку
    /// своего шаблона запоминать негде — в самом файле шаблона её нет.
    func presetImageURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let cleaned = name.replacingOccurrences(of: "\\", with: "/")
        // Повний шлях, що застарів (шаблон зроблено в програмі, яка лежала
        // деінде), — переводимо на поточні теки даних; не знайшли — шукаємо
        // картинку за іменем у шаблонах, як і для відносних.
        if let found = DataPaths.existing(cleaned) { return URL(fileURLWithPath: found) }
        let leaf = cleaned.split(separator: "/").last.map(String.init) ?? cleaned
        if let ready = presetImages[leaf] { return ready }
        var found: URL?
        for template in schemes?.templates ?? [] {
            let url = template.folderURL.appendingPathComponent(leaf)
            if FileManager.default.fileExists(atPath: url.path) { found = url; break }
        }
        presetImages[leaf] = found
        return found
    }

    /// Общий фон применяется поверх шаблона: в оригинале это отдельный
    /// переключатель, и он важнее фона шаблона.
    func setCommonBackground(_ path: String?) {
        commonBackgroundPath = path
        applyBackgrounds()
    }

    func toggleCommonBackground() {
        showsCommonBackground.toggle()
        applyBackgrounds()
    }

    /// Фон, выбранный человеком, — тот, что важнее фона шаблона.
    ///
    /// Пусто — значит человек ничего не выбирал, и картинку кладёт сам
    /// шаблон. Иначе со своим шаблоном кнопка «Фон Слайда» не значила ничего.
    /// Фон, который сейчас должен быть в зале.
    ///
    /// Правило владельца, и оно же в оригинале: пока текста нет — на стене
    /// общий фон, тот самый, что стоит при запуске; показали текст — под ним
    /// фон слайда. Так зал никогда не видит пустого экрана, а смена текста
    /// читается как смена картинки, а не как вспышка.
    ///
    /// Пусто — значит человек ничего не выбирал, и картинку кладёт шаблон.
    var backgroundOverride: String? {
        guard isLive, !isBlackout, !isTextHidden else {
            return showsCommonBackground ? commonBackgroundPath : slideBackgroundPath
        }
        return slideBackgroundPath ?? (showsCommonBackground ? commonBackgroundPath : nil)
    }

    /// Фон для предпросмотра: тот, что ляжет под текст по «Показать».
    ///
    /// Предпросмотр отвечает на вопрос «что уйдёт в зал», и правило зала
    /// «пока текста нет — общий фон» к нему не относится. Пока предпросмотр
    /// брал `backgroundOverride`, до показа он рисовал общий фон, а без
    /// общего — фон шаблона: владелец выбирал картинку под слайд, видел в
    /// окне чужую и решал, что выбор не сработал (замечание 5).
    var previewBackgroundOverride: String? {
        slideBackgroundPath ?? (showsCommonBackground ? commonBackgroundPath : nil)
    }

    private func applyBackgrounds() {
        // Порядок как у автора: общий фон важнее всего, затем выбранный
        // человеком фон слайда, и только потом фон шаблона.
        if showsCommonBackground, let common = commonBackgroundPath {
            style.backgroundImagePath = common
        } else if let own = slideBackgroundPath {
            style.backgroundImagePath = own
        } else if let template = currentTemplate?.backgroundURL?.path {
            style.backgroundImagePath = template
        }
        refreshSlide()
        // Нижний ряд перечитывает миниатюры по этому поводу. Без него
        // выбранная картинка уходила в зал, а квадратик в окне оставался
        // прежним — и выбор выглядел несработавшим.
        Signals.shared.send(.slide)
    }

    /// Быстрый выбор: «Ин 3:16» в поле над нижним рядом.
    func applyQuickInput() {
        let text = quickInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let module = primaryModule else { return }
        guard let reference = ReferenceParser.resolve(text, in: module) else { return }

        selectedBookIndex = reference.book.index
        // Главу могли не назвать — «Ин» открывает первую.
        selectedChapterNumber = reference.chapter ?? 1
        if !reference.verses.isEmpty { selectedVerseNumbers = reference.verses }
        quickInput = ""
    }

    /// Книги текущего класса. Ветхий и Новый Завет разделяет сквозной номер:
    /// Евангелие от Матфея — 470, всё до него Ветхий Завет.
    var visibleBooks: [BookInfo] {
        switch bookClass {
        case .all: return books
        // Неканонические книги узнаём по номеру: у канона он лежит в
        // сетке, кратной десяти, а у дополнительных книг — между ними.
        case .old: return books.filter { canonical($0).map { $0 < 470 } ?? true }
        case .new: return books.filter { canonical($0).map { $0 >= 470 } ?? false }
        case .apocrypha: return books.filter { book in
            guard let number = book.canonicalNumber else { return true }
            return !CanonicalBook.canonicalOrder.contains(number)
        }
        }
    }

    /// Прогрев основного перевода в фоне.
    ///
    /// Первое открытие книги стоит сотни миллисекунд, а на служении это
    /// нажатие посреди проповеди. Пока никто ничего не нажимает, разбираем
    /// весь перевод заранее — дальше любая книга открывается мгновенно.
    private func prewarm() {
        // Второй перевод разбирается ровно там же, где основной, — в момент
        // сборки слайда. Если греть только основной, нажатие на книгу всё
        // равно упирается в чтение второго, и подвисание никуда не девается.
        let modules = ([primaryModuleID] + secondaryModuleIDs).compactMap { module($0) }
        guard !modules.isEmpty else { return }

        prewarmGeneration += 1
        let generation = prewarmGeneration

        // Греем по одной книге с паузой между ними.
        //
        // Без паузы фоновый разбор съедает ядро целиком, и окно начинает
        // отвечать через секунду — при том что сама книга уже разобрана.
        // На служении важнее отзывчивость, чем скорость прогрева: он всё
        // равно закончится за полминуты, пока оператор листает первую главу.
        Self.prewarmQueue.async { [weak self] in
            for module in modules {
                for book in module.books {
                    let stop = DispatchQueue.main.sync {
                        MainActor.assumeIsolated { self?.prewarmGeneration != generation }
                    }
                    if stop { return }

                    if module.cachedChapters(ofBook: book) == nil {
                        _ = try? module.chapters(ofBook: book)
                        Thread.sleep(forTimeInterval: 0.04)
                    }
                }
            }
        }
    }

    /// Очередь прогрева — одна на всю программу и последовательная: два
    /// параллельных прогрева заняли бы два ядра вместо одного.
    private static let prewarmQueue = DispatchQueue(label: "ua.church.slovo.prewarm", qos: .background)
    /// Номер поколения: смена перевода отменяет прежний прогрев.
    private var prewarmGeneration = 0

    private func canonical(_ book: BookInfo) -> Int? {
        guard let number = book.canonicalNumber,
              CanonicalBook.canonicalOrder.contains(number) else { return nil }
        return number
    }

    // MARK: - Песни

    /// Сборники, оставленные включёнными на вкладке «Модули» (6.1.4).
    /// Ими живёт всё окно: полоса вкладок, списки, диалоги переноса песни.
    @Published private(set) var songBooks: [SongLibrary.Entry] = []

    /// Весь прочитанный каталог сборников, включая выключенные. Нужен окну
    /// «Параметры»: снятая строка обязана остаться в списке видимой — иначе
    /// галочку некуда будет вернуть.
    var allSongBooks: [SongLibrary.Entry] { songLibrary?.books ?? [] }

    /// Номер состава полосы песенников — по нему мост окна узнаёт, что список
    /// вкладок стал другим. То же, что `moduleRosterRevision`, но для песен.
    @Published private(set) var songRosterRevision = 0

    /// Пересобрать видимый список сборников по галочкам вкладки «Модули».
    ///
    /// Сборника, которого в списке модулей нет вовсе, галочки не касались —
    /// такой показываем: прятать то, чего человек не выключал, нельзя.
    func rebuildSongBooks(_ entries: [ModuleRosterEntry]) {
        let all = songLibrary?.books ?? []
        var flags: [String: Bool] = [:]
        for entry in entries where entry.isSongBook {
            flags[entry.name.lowercased()] = entry.isEnabled
        }
        // Галочку ставили на «pv3055.vbm», а збірник уже «pv3055.songbook»:
        // шукаємо й за старим ім'ям.
        let visible = all.filter {
            flags[$0.url.lastPathComponent.lowercased()]
                ?? flags[$0.id.lowercased() + ".vbm"]
                ?? true
        }
        guard visible.map(\.id) != songBooks.map(\.id) else { return }
        songBooks = visible
        songRosterRevision += 1
        // Открытый сборник выключили — уходим на первый оставшийся, иначе в
        // окне остались бы песни из спрятанного сборника.
        if !visible.contains(where: { $0.id == songBookID }) {
            songBookID = visible.first?.id ?? ""
            songIndex = nil
            songPartIndex = nil
        }
    }

    var songMatches: [SongMatch] {
        guard let library = songLibrary, !songBookID.isEmpty else { return [] }
        return library.search(songQuery, in: songBookID)
    }

    /// Разбивка библейского текста на страницы — `[Bible]` в настройках
    /// автора: `PageSubDivide`, `VersSubDivide`, `WordWrap`, `fontminsize`.
    ///
    /// У автора длинный отрывок ложится на несколько страниц, и на слайде
    /// загораются объекты «Пред./След. страница». У нас он до сих пор
    /// втискивался в одну страницу и мельчал до нечитаемого.
    private var biblePagination = PlainTextDocument.Pagination()
    /// Страницы текущего места и та, что показывается.
    private(set) var biblePages: [String] = []
    private(set) var biblePageIndex = 0
    /// Адрес, для которого посчитаны страницы, — по нему видно, что место
    /// сменилось и отсчёт пора начинать заново.
    private var paginatedAddress = ""

    /// Есть ли куда листать: по этому загораются объекты шаблона
    /// «Пред. страница» и «След. страница».
    var hasPreviousSlidePage: Bool { biblePageIndex > 0 }
    var hasNextSlidePage: Bool { biblePageIndex + 1 < biblePages.count }

    /// Кнопки (13.1): листание страниц внутри одного места Писания.
    @discardableResult
    func stepSlidePage(by delta: Int, live: Bool) -> Bool {
        let next = biblePageIndex + delta
        guard biblePages.indices.contains(next) else { return false }
        biblePageIndex = next
        refreshSlide()
        if live { showCurrent() }
        return true
    }

    /// Сборщик слайдов песни: страницы длинного куплета, название части и
    /// номер песни в адресе, знак конца песни после последней части.
    ///
    /// Он был написан целиком и не звался ниоткуда — 218 строк работы лежали
    /// без дела, а зал не видел ни номера песни, ни знака, что песня
    /// кончилась, и длинный куплет уезжал на один слайд целиком.
    private var songComposer = SongSlideComposer(options: .init(), palette: .factoryDefault)

    /// Страницы части, которая сейчас показывается. Куплет может не влезть на
    /// один слайд — тогда стрелка листает страницы, и только с последней
    /// уходит на следующую часть.
    private var songPages: [SongSlide] = []
    private var songPageIndex = 0

    /// Песня и часть, которые сейчас на слайде.
    ///
    /// Держим здесь, а не выясняем заново: `songMatches` на каждое обращение
    /// прогоняет поиск по всему песеннику, а сборка слайда случается на любое
    /// изменение состояния. Пока сборка спрашивала `selectedSong`, программа
    /// вставала колом ровно во время пения.
    private var shownSong: (song: Song, part: SongPart)?
    /// Пісня на слайді — самоперевірці.
    var shownSongForCheck: Song? { shownSong?.song }

    var selectedSong: Song? {
        guard let index = songIndex, songMatches.indices.contains(index) else { return nil }
        return songMatches[index].song
    }

    /// Стрелки в режиме «Песни» листают части песни, а не стихи Библии.
    ///
    /// Возвращает `true`, если шаг сделан здесь. Край песни забираем себе
    /// тоже: иначе стрелка на последнем куплете подменила бы слайд местом
    /// Писания из открытой в фоне главы — и зал увидел бы стих посреди пения.
    @discardableResult
    func stepSongPart(by delta: Int, live: Bool) -> Bool {
        // Песню берём ту, что на слайде; поиск по песеннику — только если
        // ещё ничего не показывали.
        guard let song = shownSong?.song ?? selectedSong, !song.parts.isEmpty else { return false }

        // `songPartIndex` хранит НОМЕР части (`SongPart.index`), а не её
        // место в списке — так его ставят и список частей, и план, и
        // история. Считать его местом значило не двигаться вовсе: у первой
        // части номер бывает и нулём, и единицей, и next выходил за список.
        // Сперва страницы внутри части: длинный куплет у автора ложится на
        // несколько слайдов, и стрелка листает их, а не перескакивает часть.
        let nextPage = songPageIndex + delta
        if songPages.count > 1, songPages.indices.contains(nextPage) {
            songPageIndex = nextPage
            showSongPage()
            if live { showCurrent() }
            return true
        }

        let current = songPartIndex ?? song.parts[0].index
        let position = song.parts.firstIndex { $0.index == current } ?? 0
        let next = position + delta
        guard song.parts.indices.contains(next) else { return true }

        let part = song.parts[next]
        songPartIndex = part.index
        showSongPart(song, part)
        // Шагнули назад — встаём на ПОСЛЕДНЮЮ страницу предыдущей части, а не
        // на первую: иначе назад пролистывалось бы через начало каждой части.
        if delta < 0, songPages.count > 1 {
            songPageIndex = songPages.count - 1
            showSongPage()
        }
        if live { showCurrent() }
        return true
    }

    /// Часть песни уходит на слайд так же, как стих: свой текст, свой адрес.
    func showSongPart(_ song: Song, _ part: SongPart) {
        shownSong = (song, part)
        let isLast = song.parts.last?.index == part.index
        songPages = songComposer.slides(for: part, of: song,
                                        bookShortName: songBookShortName,
                                        isLastPart: isLast)
        songPageIndex = 0
        showSongPage()
    }

    /// Краткое имя Песенника — им подписывается адрес, как у Библии.
    private var songBookShortName: String {
        songLibrary?.books.first { $0.id == songBookID }?.shortName ?? ""
    }

    /// Вывести текущую страницу части.
    private func showSongPage() {
        guard songPages.indices.contains(songPageIndex) else {
            slide = .blank
            pushToOutputs()
            return
        }
        slide = songPages[songPageIndex].slide
        pushToOutputs()
    }

    /// Адрес под слайд.
    ///
    /// Когда включён второй перевод, оригинал сливает оба названия в одну
    /// строку — «Буття(Gen.) 1:1», — и длина каждой части настраивается
    /// отдельно на вкладке «Слайд» окна параметров. Раньше здесь всегда
    /// стояло короткое имя основного перевода, и адрес не совпадал с тем,
    /// что привык видеть зал.
    private func reference(for book: BookInfo) -> String {
        let secondBook = secondaryModuleIDs.first
            .flatMap { module($0) }
            .flatMap { $0.counterpart(of: book) }

        guard let secondBook else {
            return referenceFormat.separate(book: book,
                                            chapter: selectedChapterNumber,
                                            verses: selectedVerseNumbers,
                                            isSecondary: false)
        }
        return referenceFormat.combined(main: book,
                                        secondary: secondBook,
                                        chapter: selectedChapterNumber,
                                        verses: selectedVerseNumbers)
    }

    // MARK: - Навигация

    private func resumeFromHiddenStates() {
        isBlackout = false
        isTextHidden = false
        // Видео в зале живёт в своём окне поверх слайда и само по себе не
        // гаснет — снимаем запрет вместе с затемнением.
        media.screenSuppression.subtract([.blackout, .blankSlide])
    }

    /// Как отзывается щелчок или стрелка по стиху.
    ///
    /// Способы взяты из руководства (5.1.4): протянуть мышью или Shift —
    /// отрезок подряд, Ctrl — добавить или убрать отдельный стих, Ctrl+A —
    /// вся глава. Несколько выбранных стихов уходят на один слайд, а в
    /// строке адреса складываются в диапазон «Бытие 3:5-8» или в перечисление
    /// через запятую, если они не подряд.
    enum VerseSelection {
        case replace     // обычный щелчок
        case extend      // Shift: отрезок от опорного стиха
        case toggle      // Ctrl: добавить или убрать один
    }

    func selectVerse(_ number: Int, extending: Bool) {
        selectVerse(number, mode: extending ? .extend : .replace)
    }

    func selectVerse(_ number: Int, mode: VerseSelection) {
        resumeFromHiddenStates()

        switch mode {
        case .replace:
            selectionAnchor = number
            selectedVerseNumbers = [number]

        case .extend:
            // Опорный стих — тот, с которого начали выделять, а не первый по
            // возрастанию: иначе Shift вверх схлопывал бы отрезок.
            let anchor = selectionAnchor ?? selectedVerseNumbers.first ?? number
            selectionAnchor = anchor
            selectedVerseNumbers = Array(min(anchor, number)...max(anchor, number))

        case .toggle:
            var picked = Set(selectedVerseNumbers)
            if picked.contains(number), picked.count > 1 {
                picked.remove(number)
            } else {
                picked.insert(number)
                selectionAnchor = number
            }
            selectedVerseNumbers = picked.sorted()
        }
    }

    /// Ctrl+A — вся глава на один слайд.
    func selectAllVerses() {
        guard let chapter = currentChapter, !chapter.verses.isEmpty else { return }
        resumeFromHiddenStates()
        selectionAnchor = chapter.verses.first?.number
        selectedVerseNumbers = chapter.verses.map(\.number)
    }

    /// Shift со стрелкой — раздвинуть выделение на соседний стих.
    func extendSelection(by delta: Int, live: Bool) {
        guard let chapter = currentChapter else { return }
        let numbers = chapter.verses.map(\.number)
        guard let edge = delta > 0 ? selectedVerseNumbers.max() : selectedVerseNumbers.min(),
              let position = numbers.firstIndex(of: edge) else { return }

        let next = position + delta
        guard numbers.indices.contains(next) else { return }

        followLive = live
        defer { followLive = false }
        selectVerse(numbers[next], mode: .extend)
        if live { showCurrent() }
    }

    func stepVerse(by delta: Int) {
        // Проверка режима стоит ЗДЕСЬ, а не в паре с `live:`, потому что эту
        // однорукую зовут ещё кнопки панели «Управление» и пункты меню. Пока
        // проверка была только наверху, кнопка в режиме «Песни» листала стихи
        // Библии поверх куплета, а в режиме «Текст» — поверх объявления.
        if mode == .text, TextModuleModel.shared.handleStep(by: delta, live: followLive) { return }
        // В режиме «Песни» стрелка Библию не трогает НИКОГДА — даже если
        // песня ещё не выбрана. Прежде шаг «не срабатывал» и управление
        // проваливалось сюда, к стихам: на вкладке «Песни» оператор жал
        // стрелку, а в зал уходило место Писания и ложилось в «Историю».
        // На записи владельца это видно прямо: список куплетов на экране, а
        // в зале «1-я Паралипоменон 7:18» и вся история из соседних стихов.
        if mode == .songs {
            stepSongPart(by: delta, live: followLive)
            return
        }
        resumeFromHiddenStates()
        // Довгий вірш поділено на частини — стрілка спершу гортає їх.
        //
        // Власник: «длинный стих полностью не выводится», і далі — як має
        // бути: «делить на части, при перелистывании будет вывод по
        // несколько частей, при этом указатель на стихе библии не будет
        // перемещаться дальше, пока весь стих не пролистают на проекторе».
        //
        // Частини рахувалися й раніше, і об'єкти шаблона «Наст. сторінка»
        // ними гортали. А стрілка про них не знала й одразу йшла до
        // наступного вірша — тому в залі й було видно лише початок довгого
        // вірша, а кінець не бачив ніхто.
        if stepSlidePage(by: delta, live: followLive) { return }
        guard let chapter = currentChapter, let current = selectedVerseNumbers.last else { return }
        let numbers = chapter.verses.map(\.number)
        guard let position = numbers.firstIndex(of: current) else { return }
        let next = position + delta

        if numbers.indices.contains(next) {
            selectedVerseNumbers = [numbers[next]]
            // Ідемо назад — стаємо на ОСТАННЮ частину попереднього вірша:
            // інакше, гортаючи назад, людина перестрибувала б через кінець
            // довгого вірша до його початку.
            if delta < 0, biblePages.count > 1 {
                biblePageIndex = biblePages.count - 1
                refreshSlide()
                if followLive { showCurrent() }
            }
        } else if delta > 0 {
            stepChapter(by: 1)
        } else if delta < 0 {
            // Смена главы сама ставит первый стих и пересобирает слайд. Если
            // при этом держать «уходит в зал», в зал уйдёт промежуточный
            // первый стих новой главы, а в «Историю» лягут две записи вместо
            // одной. Отпускаем на время перехода и берём обратно перед тем,
            // как поставить настоящий стих — последний в главе.
            let wasLive = followLive
            followLive = false
            stepChapter(by: -1)
            followLive = wasLive
            selectedVerseNumbers = [currentChapter?.verses.last?.number ?? 1]
        }
    }

    func stepChapter(by delta: Int) {
        resumeFromHiddenStates()
        let numbers = chapters.map(\.number)
        guard let position = numbers.firstIndex(of: selectedChapterNumber) else { return }
        let next = position + delta
        if numbers.indices.contains(next) {
            selectedChapterNumber = numbers[next]
        } else if delta > 0, selectedBookIndex + 1 < books.count {
            selectedBookIndex += 1
        } else if delta < 0, selectedBookIndex > 0 {
            selectedBookIndex -= 1
            selectedChapterNumber = chapters.last?.number ?? 1
        }
    }

    func setBackground(_ url: URL?) {
        slideBackgroundPath = url?.path
        hiddenBackgroundPath = nil
        applyBackgrounds()
    }

    /// F9 в оригинале временно убирает картинку, не теряя выбор.
    func toggleBackground() {
        if let hidden = hiddenBackgroundPath {
            style.backgroundImagePath = hidden
            hiddenBackgroundPath = nil
        } else if let current = style.backgroundImagePath {
            hiddenBackgroundPath = current
            style.backgroundImagePath = nil
        }
        refreshSlide()
    }

    func chooseBackgroundFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = OurWords.t("Выбрать")
        panel.message = OurWords.t("Изображение общего фона")
        if panel.runModal() == .OK, let url = panel.url { setBackground(url) }
    }

    /// F12 — полностью чёрный экран: ни текста, ни фона.
    func showBlackScreen() {
        // Пункт у автора называется «Показать/скрыть затемнение экрана» (N34),
        // то есть это переключатель. Раньше он всегда только ЗАТЕМНЯЛ, и
        // второе нажатие делало хуже: `slide` к тому времени пуст, и строка
        // «liveSlide = slide» стирала слайд зала насовсем.
        if isBlackout {
            resumeFromHiddenStates()
            refreshSlide()
            liveSlide = slide
            pushToOutputs()
            return
        }
        liveSlide = slide
        isBlackout = true
        isLive = true
        // «Затемнение — это чёрный экран» без оговорок: кадр видео поверх
        // него остаться не должен.
        media.screenSuppression.insert(.blackout)
        refreshSlide()
    }

    /// Ctrl+F5 — фон без текста: пауза в подаче, но экран не гаснет.
    func showBlankSlide() {
        liveSlide = slide
        isBlackout = false
        isTextHidden = true
        isLive = true
        media.screenSuppression.remove(.blackout)
        media.screenSuppression.insert(.blankSlide)
        refreshSlide()
    }
}

/// Тонкая обёртка над UserDefaults, чтобы ключи не разъезжались по файлам.
enum Defaults {
    private static let store = UserDefaults.standard

    // MARK: - На чём остановились
    //
    // Владелец просил прямо: «последние изменения в программе сохраняться
    // должны автоматически и при последующем запуске работать исходя из
    // них». Раньше между запусками переживали только язык, папка модулей и
    // два выбранных перевода — всё прочее программа забывала.

    /// Плавность появления и ухода кадра, в секундах. 0 — резко, как было.
    ///
    /// Настройка наша: у автора её нет вовсе, кадр у него возникает разом.
    /// Треть секунды — то, что глаз читает как «появилось», а не «мигнуло».
    static var mediaFadeSeconds: Double {
        get { store.object(forKey: "mediaFade") as? Double ?? 0.35 }
        set { store.set(newValue, forKey: "mediaFade") }
    }

    /// Путь к yt-dlp, указанный руками: программа или папка исходников.
    /// Пусто — ищем сами (см. `YouTubeResolver`).
    static var youTubeToolPath: String? {
        get { store.string(forKey: "youTubeTool") }
        set { store.set(newValue, forKey: "youTubeTool") }
    }

    static var lastMode: String? {
        get { store.string(forKey: "lastMode") }
        set { store.set(newValue, forKey: "lastMode") }
    }
    static var lastBookClass: String? {
        get { store.string(forKey: "lastBookClass") }
        set { store.set(newValue, forKey: "lastBookClass") }
    }
    static var lastBookIndex: Int? {
        get { store.object(forKey: "lastBookIndex") as? Int }
        set { store.set(newValue, forKey: "lastBookIndex") }
    }
    static var lastChapter: Int? {
        get { store.object(forKey: "lastChapter") as? Int }
        set { store.set(newValue, forKey: "lastChapter") }
    }
    static var lastVerses: [Int]? {
        get { store.array(forKey: "lastVerses") as? [Int] }
        set { store.set(newValue, forKey: "lastVerses") }
    }
    static var lastTemplate: String? {
        get { store.string(forKey: "lastTemplate") }
        set { store.set(newValue, forKey: "lastTemplate") }
    }
    /// Весь вид слайда целиком: шрифт и его размер, насыщенность и наклон,
    /// цвета, обводка, тень, поля, выравнивание, межстрочный интервал, фон и
    /// переход. Имени шаблона мало — человек правит эти значения и ползунком
    /// в окне, и конструктором, и всё это должно пережить закрытие программы.
    static var slideStyle: Data? {
        get { store.data(forKey: "slideStyle") }
        set { store.set(newValue, forKey: "slideStyle") }
    }
    static var slideBackground: String? {
        get { store.string(forKey: "slideBackground") }
        set { store.set(newValue, forKey: "slideBackground") }
    }
    static var commonBackground: String? {
        get { store.string(forKey: "commonBackground") }
        set { store.set(newValue, forKey: "commonBackground") }
    }
    static var showsCommonBackground: Bool? {
        get { store.object(forKey: "showsCommonBackground") as? Bool }
        set { store.set(newValue, forKey: "showsCommonBackground") }
    }
    static var tabNamesLong: Bool? {
        get { store.object(forKey: "tabNamesLong") as? Bool }
        set { store.set(newValue, forKey: "tabNamesLong") }
    }
    static var arrowsLinked: Bool? {
        get { store.object(forKey: "arrowsLinked") as? Bool }
        set { store.set(newValue, forKey: "arrowsLinked") }
    }
    static var lastSongBook: String? {
        get { store.string(forKey: "lastSongBook") }
        set { store.set(newValue, forKey: "lastSongBook") }
    }
    static var lastSongIndex: Int? {
        get { store.object(forKey: "lastSongIndex") as? Int }
        set { store.set(newValue, forKey: "lastSongIndex") }
    }
    static var lastSongPart: Int? {
        get { store.object(forKey: "lastSongPart") as? Int }
        set { store.set(newValue, forKey: "lastSongPart") }
    }

    static var modulesFolder: URL? {
        get { store.url(forKey: "modulesFolder") }
        set { store.set(newValue, forKey: "modulesFolder") }
    }
    static var primaryModule: String? {
        get { store.string(forKey: "primaryModule") }
        set { store.set(newValue, forKey: "primaryModule") }
    }
    static var secondaryModules: [String] {
        get { store.stringArray(forKey: "secondaryModules") ?? [] }
        set { store.set(newValue, forKey: "secondaryModules") }
    }
    static var languageCode: String? {
        get { store.string(forKey: "languageCode") }
        set { store.set(newValue, forKey: "languageCode") }
    }
}
