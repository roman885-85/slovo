import AppKit
import Combine
import SlovoCore

/// Робоча область «Пісні» цілком: три списки, панель інструментів
/// Пісенника (30), вкладки Пісенників (33) і два поля швидкого вибору.
///
/// Усі частини живуть постійно, з першого показу вікна і до виходу. Вибір пісні
/// міняє вміст одного списку частин; вибір куплета не чіпає жодного
/// списку зовсім — лише заливку двох рядків. Цим нове вікно й відрізняється від
/// колишнього, де на будь-яку дію перезбиралися тіла всіх панелей разом, а
/// в список ішли три з половиною тисячі значень `Song` з повним текстом.
///
/// Правки Пісенника (5.3.9) робить `SongEditorModel` — та сама модель, що й у
/// колишньому вікні. Переписувати її нема чого: вона не малює, а міняє дані, і
/// весь її час іде на розбір файла, а не на список.
@MainActor
final class NativeSongsWorkspace {

    static let shared = NativeSongsWorkspace()

    // MARK: - Що відкрито

    /// Доступ до цих полів потрібен і панелям інструментів (сусідній файл),
    /// тому вони не `private`: у Swift `private` не переходить межу файла.
    private(set) weak var state: AppState?
    let model = SongEditorModel()
    /// Палітра частин: правка у вікні «Кольори частин» перефарбовує список
    /// частин одразу, а «Скасувати» повертає — власник просив бачити правки
    /// на льоту, а не після «Ок».
    private var paletteWatcher: AnyCancellable?
    let bridge = NativeSongBridge()
    private let index = NativeSongIndex()
    private(set) var captions = SongCaptions(language: nil)

    // MARK: - Списки

    private let groupRows = NativeSongGroupRows()

    let songRows: NativeSongRows
    let partRows = NativeSongPartRows()
    private(set) var groupList: NativeList!
    private(set) var songList: NativeList!
    private(set) var partList: NativeList!

    // MARK: - Частини вікна

    private var root: NSView?

    /// Робоча область пісень — самоперевірці: панель фонограм і межа висоти.
    var rootForCheck: NativeSongsRootView? { root as? NativeSongsRootView }
    let header = NativeSongHeader()
    private var columns: NativeColumnsView?
    var groupColumn: NativeSongColumn?
    var songColumn: NativeSongColumn?
    var partColumn: NativeSongColumn?
    private var groupTitle = NativeSongColumnTitle()
    private var songTitle = NativeSongColumnTitle()
    private var partTitle = NativeSongColumnTitle()
    let groupStrip = NativeSongToolStrip()
    let songStrip = NativeSongToolStrip()
    let partStrip = NativeSongToolStrip()
    private var songQuick: NativeSongQuickRow!
    private var partQuick: NativeSongQuickRow!
    /// Поля швидкого вибору — самоперевірці: вона друкує в них по літері.
    var songQuickField: NativeQuickField? { songQuick?.field }
    var partQuickField: NativeQuickField? { partQuick?.field }
    var mainButtons: [NativeSongButton] = []
    var saveButton: NativeSongButton?
    var groupButtons: [String: NativeSongButton] = [:]
    var songButtons: [String: NativeSongButton] = [:]
    var partButtons: [String: NativeSongButton] = [:]

    private var tokens: [Signals.Token] = []
    /// Дві кнопки поруч із полем швидкого вибору пісні. Тримаємо їх, бо
    /// підказки ставляться раз при побудові, а мову міняють при живій
    /// програмі — інакше вони лишалися б попередньою мовою.
    private var prevSongButton: NativeSongButton?
    private var nextSongButton: NativeSongButton?
    private var keys: NativeSongKeys?
    var sheetWindow: NativeSongSheetWindow?
    /// «Скорочений» або «Повний» вигляд назви на вкладках (33) — пункт меню
    /// правої кнопки з 5.3.7. Між запусками не живе, як і в автора.
    var longBookNames = true
    private var lastQuickFocus: DeskModel.QuickField?
    /// З чого пораховано нинішній відбір. Поки не змінилося — рахувати заново
    /// нема чого: на збірнику в 3400 пісень це перебір усіх назв і
    /// перечитування списку, а кличуть відбір двічі на одне натискання.
    private var filterKey = "\u{0}"
    /// За чим видно, що вміст збірника і справді правили. Лічильник
    /// правок `SongEditorModel` росте і від простого відкриття, а розібране
    /// в запасі від відкриття не псується.
    private var editions: [String: Int] = [:]
    private var openedBookID = ""
    private var openedRevision = 0
    /// Що востаннє стояло в `AppState`. За ним видно, хто змінив
    /// вибір — ми чи хтось збоку: план, історія, стрілки.
    private var lastStateSong: Int?
    private var lastStatePart: Int?
    /// Режим правки, під який зібрано панель (30).
    var builtEditing = false

    private init() {
        songRows = NativeSongRows(index: index)
    }

    // MARK: - Збирання

    /// Зібрати робочу область і покласти її у вікно.
    ///
    /// Кличуть один раз, одразу після того, як вікно піднялося. Другий виклик
    /// нічого не робить: частини постійні, перезбирати їх нічим і нема чого.
    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        captions = SongCaptions(language: state.language)
        configureModel(state: state)
        bridge.start(state: state, model: model)

        let root = buildWorkspace(state: state)
        self.root = root
        if state.mode == .songs {
            NativeMainWindowController.shared.install(root, in: .workspace)
        }

        subscribe()
        placeBookTabs(songs: state.mode == .songs)
        applyInterface()
        openCurrentBook()
        NativeTrace.say("песни: собрали. режим \(state.mode),"
            + " каталог \(state.songLibrary == nil ? "ещё не читан" : "есть"),"
            + " збірників \(state.songBooks.count), вибрано «\(state.songBookID)»,"
            + " відкрито «\(model.book?.title ?? "немає")», вкладок \(bookTabCount)")
        keys = NativeSongKeys(workspace: self)
    }

    /// Каталог, який уже забрали. За ним видно, що другий захід не потрібен.
    private weak var adoptedLibrary: SongLibrary?

    /// Панель фонограм над закладками пісенників.
    private(set) var backingBar: NativeBackingTrackBar?

    /// Скільки вкладок Пісенників стоїть на смузі (33). Для самоперевірки:
    /// відкритий збірник у моделі ще не значить, що людина його бачить.
    var bookTabCount: Int { header.tabs.tabCount }

    /// Вигляд списків з меню «Інтерфейс» — свій у кожного розділу.
    ///
    /// В автора вигляд списків зберігається за розділами: `[Bible]`, `[Text]`,
    /// `[Songs]`, і меню править той розділ, який відкрито. Пісенник цього
    /// меню не слухав зовсім — вибір у ньому нічого не міняв.
    ///
    /// `BooksStyle` («Значки» / «Мал. значки» / «Список» / «Таблиця») лягає
    /// на список пісень, `LinesStyle` («одна лінія» / «багато рядків») — на
    /// список частин: це ті самі два списки, що в Біблії.
    /// Перезастосувати вигляд списків — самоперевірці, яка міняє його на ходу.
    func applyInterfaceNow() { applyInterface(force: true) }

    private func applyInterface(force: Bool = false) {
        let interface = InterfaceSettings.shared
        let font = CGFloat(state?.listFontSize ?? 13)

        let single = interface.verseView(.songs) == .singleLine
        if partRows.singleLine != single {
            partRows.singleLine = single
            // Висота рахується за текстом в обох виглядах: «одна лінія» в автора
            // не сплющує куплет в один рядок екрана, а склеює рядки
            // пісні в абзац — а він усе одно переноситься по ширині стовпця.
            partList.heights = .measured(estimate: 86)
            partList.reload()
        }

        let kind = interface.bookView(.songs)
        // Кегль теж привід перезібрати: висота плитки рахується від нього, і
        // без цього великий текст вилазив за плитку.
        guard force || appliedSongView != kind else { return }
        appliedSongView = kind
        switch kind {
        case .icons:
            songList.mode = .tiles(minItemWidth: 210, itemHeight: ceil(font * 3.2), gap: 3)
        case .smallIcons:
            songList.mode = .tiles(minItemWidth: 150, itemHeight: ceil(font * 2.2), gap: 2)
        case .list, .table:
            songList.mode = .list
        }
        songList.heights = .uniform(kind == .table ? ceil(font * 1.8) : 34)
        songList.reload()
    }

    /// Вигляд списку пісень, під який його вже зібрано.
    private var appliedSongView: InterfaceSettings.BookViewMode?

    /// Де живуть закладки Пісенників (33).
    ///
    /// На сторінці пісень переклади Біблії не потрібні зовсім, а Пісенники потрібні —
    /// і місце їм рівно те, де в Біблії стоять переклади (7). Тому в режимі
    /// пісень закладки переїжджають на нижню смугу, а на виході повертаються у
    /// свою шапку. Вид один і той самий: два списки Пісенників розійшлися б у
    /// думці, який збірник відкрито.
    private func placeBookTabs(songs: Bool) {
        let strip = NativeBibleWorkspace.shared.strip
        header.keepsTabs = !songs
        if songs {
            strip?.showGuestTabs(header.tabs)
        } else {
            strip?.showGuestTabs(nil)
            if header.tabs.superview !== header { header.addSubview(header.tabs) }
            header.needsLayout = true
        }
    }

    /// Вигляд робочої області — його ставить у вікно той, чий режим вибрано.
    var workspaceView: NSView? { root }

    private func configureModel(state: AppState) {
        model.captions = captions
        model.modulesFolder = state.modulesFolder
        model.library = state.songLibrary
        model.palette = state.songPalette
        paletteWatcher = SettingsStore.shared.$settings
            .map(\.songPalette)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] palette in
                guard let self else { return }
                self.model.palette = palette
                self.reloadParts()
            }

        model.onPartChosen = { [weak self] song, part, live in
            guard let self, let state = self.state else { return }
            // Одиночне клацання готує частину в передпоказі, подвійне —
            // виводить її в зал. Правило те саме, що й для віршів.
            state.songPartIndex = part.index
            state.showSongPart(song, part)
            if live { state.showCurrent() }
        }
        // У пісенника не було підключено приймач Плану, і пункти «Додати в
        // План» у меню пісні і частини просто не з'являлися, хоча `DeskModel`
        // для них давно написано.
        model.onAddToPlan = { [weak self] song, part in
            guard let state = self?.state else { return }
            if let part, let item = DeskModel.shared.planItem(forSong: song, part: part, state: state) {
                DeskModel.shared.addToPlan([item])
            } else {
                DeskModel.shared.addToPlan(DeskModel.shared.planItems(forSong: song, state: state))
            }
        }
        model.onSaved = { [weak self] id, book in
            self?.state?.songLibrary?.adopt(book, as: id)
            self?.refreshTabs()
        }
        model.onReloaded = { [weak self] id, book in
            self?.state?.songLibrary?.adopt(book, as: id)
            self?.refreshTabs()
        }
        model.onLibraryChanged = { [weak self] id in
            self?.state?.reloadLibrary()
            self?.state?.songBookID = id
        }
        // Згорнуті назви доспіли осторонь від головного потоку — набрана
        // за цей час літера перепитується сама, уже за готовим розбором.
        index.onReady = { [weak self] in
            self?.forgetFilter()
            self?.applyFilter(reload: true)
        }
    }

    private func buildWorkspace(state: AppState) -> NSView {
        let font = CGFloat(state.listFontSize)

        groupList = NativeList(mode: .list, metrics: .songGroups,
                               heights: .uniform(22), fontSize: font)
        groupRows.owner = self
        groupList.source = groupRows
        groupList.onSelect = { [weak self] _, active, cause in
            guard cause != .code else { return }
            self?.chooseGroup(row: active)
        }

        songList = NativeList(mode: .list, metrics: .songs,
                              heights: .uniform(34), fontSize: font)
        songRows.owner = self
        songRows.titleFormat = state.songTitleFormat
        songList.source = songRows
        songList.onSelect = { [weak self] _, active, cause in
            guard cause != .code else { return }
            self?.chooseSong(row: active)
        }
        songList.onActivate = { [weak self] row in self?.activateSong(row: row) }

        // Частини переносяться за словами, і висота рядка заздалегідь невідома:
        // у куплеті вісім рядків, у вступі один. Справжня висота
        // рахується тоді, коли частина вперше показалася.
        partList = NativeList(mode: .list, metrics: .songParts,
                              heights: .measured(estimate: 86), fontSize: font)
        partRows.owner = self
        partList.source = partRows
        partList.onSelect = { [weak self] _, active, cause in
            guard cause != .code else { return }
            self?.choosePart(row: active, live: false)
        }
        partList.onActivate = { [weak self] row in self?.choosePart(row: row, live: true) }

        buildHeader()
        buildStrips()

        prevSongButton = button("chevron.up", hint("PSBFindPrevSong", "Найти предыдущую песню")) { [weak self] in
            self?.stepSong(-1)
        }
        nextSongButton = button("chevron.down", hint("PSBFindNextSong", "Найти следующую песню")) { [weak self] in
            self?.stepSong(1)
        }
        songQuick = NativeSongQuickRow(buttons: [prevSongButton, nextSongButton].compactMap { $0 })
        partQuick = NativeSongQuickRow()
        configureQuickFields()

        let groupColumn = NativeSongColumn()
        groupColumn.install([
            .init(view: groupTitle, height: NativeSongColumnTitle.height),
            .init(view: groupStrip, height: NativeSongToolStrip.height),
            .init(view: groupList, height: 0),
        ])
        let songColumn = NativeSongColumn()
        songColumn.install([
            .init(view: songTitle, height: NativeSongColumnTitle.height),
            .init(view: songStrip, height: NativeSongToolStrip.height),
            .init(view: songQuick, height: NativeSongQuickRow.height),
            .init(view: songList, height: 0),
        ])
        let partColumn = NativeSongColumn()
        partColumn.install([
            .init(view: partTitle, height: NativeSongColumnTitle.height),
            .init(view: partStrip, height: NativeSongToolStrip.height),
            .init(view: partQuick, height: NativeSongQuickRow.height),
            .init(view: partList, height: 0),
        ])
        self.groupColumn = groupColumn
        self.songColumn = songColumn
        self.partColumn = partColumn

        let columns = NativeColumnsView()
        columns.install([
            .init(view: groupColumn, minWidth: 150, idealWidth: 190, maxWidth: 320),
            .init(view: songColumn, minWidth: 220, idealWidth: 340, maxWidth: 520),
            .init(view: partColumn, minWidth: 240, idealWidth: 240, maxWidth: 0),
        ])
        self.columns = columns

        // Фонограма — тут, над закладками пісенників, на всю ширину вікна
        // (власник 16.09.2026). Стояла на «Медіа», у стовпці зі списком
        // файлів; співають же під неї пісню, і місце їй біля пісень.
        let backing = NativeBackingTrackBar(player: state.backing)
        backingBar = backing
        let root = NativeSongsRootView(header: header, columns: columns, backing: backing)
        applyCaptions()
        applyEditMode()
        return root
    }

    // MARK: - Підписи

    func caption(_ key: String, _ fallback: String) -> String {
        captions.caption(key, fallback)
    }

    func hint(_ key: String, _ fallback: String) -> String {
        captions.hint(key, fallback)
    }

    private func applyCaptions() {
        backingBar?.applyCaptions()
        groupTitle.text = caption("Label1", "Группа:")
        songTitle.text = caption("Label2", "Песня:")
        partTitle.text = caption("Label3", "Текст:")
        songQuick.field.placeholder = OurWords.t("Номер или название песни…")
        partQuick.field.placeholder = OurWords.t("Слова из текста песни…")
        songQuick.field.toolTip = hint("ENameFastInput",
                                       "Быстрый выбор Песни вводом её номера или названия")
        partQuick.field.toolTip = hint("ETextFastInput",
                                       "Быстрый выбор Части Песни вводом части её текста")
        header.modifiedTitle = OurWords.t("изменён")
    }

    // MARK: - Поля швидкого вибору (31) і (32)

    private func configureQuickFields() {
        applyFieldColors()
        songQuick.field.onChange = { [weak self] text in
            guard let self else { return }
            // Відбір іде на кожен знак: окремої кнопки «застосувати» в полів
            // оригіналу немає. `model.songQuery` міняємо самі, щоб поле і
            // модель не роз'їхалися, а список перечитуємо тут же.
            self.model.songQuery = text
            self.applyFilter(reload: true)
            self.bridge.sync()
        }
        songQuick.field.onSubmit = { [weak self] _ in self?.chooseFirstMatch() }
        songQuick.field.onFocus = { [weak self] focused in
            if focused { DeskModel.shared.quickFocus = .book }
            else if DeskModel.shared.quickFocus == .book { DeskModel.shared.quickFocus = nil }
            self?.lastQuickFocus = DeskModel.shared.quickFocus
        }
        partQuick.field.onChange = { [weak self] text in
            guard let self else { return }
            self.model.partQuery = text
            self.jumpToMatchingPart()
            self.bridge.sync()
        }
        partQuick.field.onFocus = { [weak self] focused in
            if focused { DeskModel.shared.quickFocus = .verse }
            else if DeskModel.shared.quickFocus == .verse { DeskModel.shared.quickFocus = nil }
            self?.lastQuickFocus = DeskModel.shared.quickFocus
        }
    }

    /// Підфарбування поля у фокусі — «Колір активного поля вводу» зі справжнього
    /// `VisioBible.ini` користувача (`ActiveInputFieldColor`).
    ///
    /// Колір тексту добирається за яскравістю заливки: в автора підфарбування завжди
    /// світле, бо програма живе у світлій темі Windows, а в нас
    /// тема буває й темною, і системний білий на світло-рожевому не прочитати.
    private func applyFieldColors() {
        guard let colour = state?.programOptions.activeInputFieldColor else { return }
        let fill = NSColor(rgba: colour)
        let luminance = 0.299 * colour.red + 0.587 * colour.green + 0.114 * colour.blue
        let ink: NSColor = luminance > 0.55 ? .black : .white
        for row in [songQuick, partQuick] {
            row?.field.activeFill = fill
            row?.field.activeText = ink
        }
    }

    /// «Поиск производится как по текстам „частей песни", так и по названиям
    /// частей» (поле (32)).
    private func jumpToMatchingPart() {
        let needle = NativeSongFold.bytes(model.partQuery.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty, let song = model.song else { return }
        for (position, part) in song.parts.enumerated() {
            guard NativeSongFold.contains(NativeSongFold.bytes(part.text), needle)
                || NativeSongFold.contains(NativeSongFold.bytes(part.kind), needle) else { continue }
            choosePart(row: position, live: false)
            return
        }
    }

    /// Enter у полі швидкого вибору Пісні — найшвидший шлях: набрав номер,
    /// натиснув увід.
    private func chooseFirstMatch() {
        guard songRows.rowCount > 0 else { return }
        chooseSong(row: 0)
        songList.scrollTo(0, place: .center)
    }

    /// Кнопки `PSBFindPrevSong` / `PSBFindNextSong`. На краю списку оригінал
    /// не завертає мовчки, а питає — `TextMessages51` і `TextMessages54`.
    func stepSong(_ delta: Int) {
        let total = songRows.rowCount
        guard total > 0 else {
            SongPrompt.info(captions.message(52, "Поиск песни"),
                            captions.message(53, "Песен не найдено"))
            return
        }
        guard let song = model.songIndex, let current = songRows.position(ofSong: song) else {
            chooseSong(row: delta > 0 ? 0 : total - 1)
            return
        }
        let next = current + delta
        if next >= total {
            guard SongPrompt.confirm(title: captions.message(52, "Поиск песни"),
                                     message: captions.message(51, "Достигли конца Песенника. Искать с начала?"))
            else { return }
            chooseSong(row: 0)
        } else if next < 0 {
            guard SongPrompt.confirm(title: captions.message(52, "Поиск песни"),
                                     message: captions.message(54, "Достигли начала Песенника. Искать с конца?"))
            else { return }
            chooseSong(row: total - 1)
        } else {
            chooseSong(row: next)
        }
        if let position = model.songIndex.flatMap(songRows.position(ofSong:)) {
            songList.scrollTo(position, place: .center)
        }
    }

    // MARK: - Те саме, але з коду

    /// Набрати знак у полі швидкого вибору Пісні (31).
    ///
    /// Винесено з розбору події навмисно — з тієї самої причини, що й
    /// `NativeList.click(item:)`: так шлях «набрали літеру → відібрали → список
    /// перечитано» можна і поміряти, і перевірити самоперевіркою, не підробляючи
    /// натискань клавіш.
    func typeSongQuery(_ text: String) {
        songQuick.field.text = text
        songQuick.field.onChange?(text)
    }

    /// Набрати знак у полі швидкого вибору Частини (32).
    func typePartQuery(_ text: String) {
        partQuick.field.text = text
        partQuick.field.onChange?(text)
    }

    /// Клацнути по рядку списку пісень.
    func clickSong(row: Int) { songList.click(item: row) }

    /// Клацнути по частині пісні: одиночне клацання готує в передпоказі,
    /// подвійне виводить у зал.
    func clickPart(row: Int, live: Bool) {
        partList.click(item: row, clickCount: live ? 2 : 1)
    }

    /// Клацнути по рядку групи (26).
    func clickGroup(row: Int) { groupList.click(item: row) }

    // MARK: - Що видно заміру і самоперевірці

    /// Чи доспів фоновий розбір назв.
    var songIndexIsReady: Bool { index.isReady }

    /// Скільки разів назви довелося згортати на головному потоці.
    var hurriedFolds: Int { index.hurriedFolds }

    /// Лише відбір, без перечитування списку: перебір усіх назв — це
    /// робота пісенного розділу, а не списку, і міряти їх треба окремо.
    func measureFilterOnly(_ query: String) {
        _ = index.filter(query: query, within: nil)
    }

    /// Скільки частин у пісні, що стоїть на цьому рядку списку.
    func partsCount(ofRow row: Int) -> Int {
        guard let song = songRows.song(at: row),
              let songs = model.editor?.book.songs, songs.indices.contains(song) else { return 0 }
        return songs[song].parts.count
    }

    // MARK: - Вибір

    private func chooseGroup(row: Int) {
        model.groupIndex = row == 0 ? nil : row - 1
        applyFilter(reload: true)
        model.songIndex = songRows.song(at: 0)
        lastStateSong = model.songIndex
        state?.songIndex = model.songIndex
        model.partIndex = nil
        bridge.sync()
    }

    private func chooseSong(row: Int) {
        guard let song = songRows.song(at: row) else { return }
        model.songIndex = song
        // Номер пісні тримають обидва: `AppState` пише його в налаштування і за ним
        // же будує запис «Історії» і пункт Плану.
        lastStateSong = song
        state?.songIndex = song
        model.partIndex = nil
        model.partQuery = ""
        partQuick.field.text = ""
        bridge.sync()
    }

    /// Пісня за номером у збірнику — вікну результатів пошуку.
    func song(at index: Int) -> Song? {
        guard let songs = model.editor?.book.songs, songs.indices.contains(index) else { return nil }
        return songs[index]
    }

    /// Відкрити пісню і частину збоку — з вікна результатів пошуку.
    ///
    /// Сито («Група» і швидкий вибір) знімається: знайдена пісня може бути
    /// не з відкритої групи, а показати її треба все одно. `live` — частина
    /// іде одразу в зал, як подвійне клацання по рядку.
    func reveal(song index: Int, part: Int?, live: Bool) {
        guard let songs = model.editor?.book.songs, songs.indices.contains(index) else { return }
        if model.groupIndex != nil {
            model.groupIndex = nil
            groupList.setSelection(IndexSet(integer: 0), active: 0)
        }
        if !model.songQuery.isEmpty {
            model.songQuery = ""
            songQuick.field.text = ""
        }
        applyFilter(reload: true)
        model.songIndex = index
        lastStateSong = index
        state?.songIndex = index
        model.partIndex = nil
        model.partQuery = ""
        partQuick.field.text = ""
        let song = songs[index]
        if let part, song.parts.indices.contains(part) {
            model.partIndex = part
            lastStatePart = song.parts[part].index
            model.onPartChosen?(song, song.parts[part], live)
        }
        bridge.sync()
        applySongSelection(scroll: true)
    }

    /// Подвійне клацання по пісні починає презентацію з ПЕРШОЇ частини (5.3.2).
    private func activateSong(row: Int) {
        guard let index = songRows.song(at: row) else { return }
        model.songIndex = index
        bridge.sync()
        guard let song = model.song, let first = song.parts.first else { return }
        model.partIndex = 0
        model.onPartChosen?(song, first, true)
        bridge.sync()
    }

    private func choosePart(row: Int, live: Bool) {
        guard let song = model.song, song.parts.indices.contains(row) else { return }
        model.partIndex = row
        lastStatePart = song.parts[row].index
        model.onPartChosen?(song, song.parts[row], live)
        bridge.sync()
    }

    // MARK: - Відбір

    /// Перерахувати, які пісні показано. Група і швидкий вибір — одне й те
    /// саме сито, тому й рахуються разом.
    private func applyFilter(reload: Bool) {
        // Відбір кличуть двічі на одне натискання: своїм клацанням і слідом приводом
        // від сита. Другий раз рахувати нічого — звіряємо, з чого його пораховано.
        let key = "\(index.key)#\(model.groupIndex.map(String.init) ?? "-")"
            + "#\(model.songQuery)#\(model.showsCatalogNumber)"
            + "#\(songRows.titleFormat.showsNumber)"
        guard key != filterKey else { return }
        filterKey = key

        let pool: [Int]?
        if let group = model.groupIndex, let editor = model.editor {
            pool = editor.songIndices(inGroup: group)
        } else {
            // «Усі пісні» — сита немає зовсім. Будувати під це масив із трьох з
            // половиною тисяч номерів значить платити за те, чого не просили.
            pool = nil
        }
        songRows.setFilter(index.filter(query: model.songQuery, within: pool))
        guard reload else { return }
        songList.reload()
        applySongSelection(scroll: false)
    }

    // MARK: - Приводи

    private func subscribe() {
        tokens.append(Signals.shared.subscribe(.mode) { [weak self] in
            guard let self, let state = self.state else { return }
            self.placeBookTabs(songs: state.mode == .songs)
            guard state.mode == .songs else { return }
            guard let root = self.root else {
                NativeTrace.say("пісні: вибрали вкладку, а області немає зовсім")
                return
            }
            NativeMainWindowController.shared.install(root, in: .workspace)
            NativeTrace.say("пісні: стали у вікно за вкладкою. вкладок \(self.bookTabCount),"
                + " песен \(self.model.visibleSongs.count),"
                + " відкрито «\(self.model.book?.title ?? "немає")»")
        })
        // Бібліотека читається у фоні і приходить пізніше, ніж піднімається вікно:
        // у мить збирання пісенників ще немає, і модуль лишався порожнім — у
        // власника «пісенника немає» зовсім. Щойно вона дочиталася,
        // забираємо каталог і відкриваємо збірник заново.
        tokens.append(Signals.shared.subscribe(.library) { [weak self] in
            guard let self, let state = self.state, let fresh = state.songLibrary else { return }
            // Склад смуги міняється й без нового каталогу: на вкладці
            // «Модулі» зняли галочку зі збірника. Вкладки перечитуємо завжди,
            // а от каталог забираємо рівно один раз на кожен.
            //
            // Рівно один захід на кожен каталог. Без цього рахунку виходило
            // кільце: відкриття збірника саме звіряє стан, звірка знову
            // шле «бібліотека відкрилася», і так без кінця — самоперевірка
            // пакета на цьому й повисла.
            let isFreshCatalogue = self.adoptedLibrary !== fresh
            if isFreshCatalogue {
                self.adoptedLibrary = fresh
                self.model.library = fresh
            }
            if state.songBookID.isEmpty, let first = state.songBooks.first {
                state.songBookID = first.id
            }
            self.refreshTabs()
            // Відкритий збірник міг виявитися схованим — тоді `AppState` уже
            // перевів вибір на інший, і його треба відкрити.
            if isFreshCatalogue || self.model.bookID != state.songBookID {
                self.openCurrentBook()
            }
            NativeTrace.say("песни: состав сборников. всего \(state.songBooks.count),"
                + " вибрано «\(state.songBookID)»,"
                + " відкрито «\(self.model.book?.title ?? "немає")»,"
                + " вкладок \(self.bookTabCount), песен \(self.model.visibleSongs.count)")
        })
        tokens.append(Signals.shared.subscribe(.songBook) { [weak self] in
            self?.reloadBook()
        })
        tokens.append(Signals.shared.subscribe(.songFilter) { [weak self] in
            guard let self else { return }
            self.songRows.titleFormat = self.state?.songTitleFormat ?? SongTitleFormat()
            self.songRows.showsCatalogNumber = self.model.showsCatalogNumber
            self.applyFilter(reload: true)
        })
        tokens.append(Signals.shared.subscribe(.songSelection) { [weak self] in
            guard let self else { return }
            let fromState = self.adoptSongFromState()
            self.applySongSelection(scroll: true)
            self.reloadParts()
            // Пісня прийшла з Плану чи «Історії» — разом із частиною: список
            // частин уже від нової пісні, і виділити треба саме її частину.
            if fromState, let number = self.state?.songPartIndex {
                self.lastStatePart = number
                self.applyPart(number: number)
                self.applyPartSelection()
            }
        })
        tokens.append(Signals.shared.subscribe(.songPart) { [weak self] in
            guard let self else { return }
            self.adoptPartFromState()
            self.applyPartSelection()
        })
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self, let size = self.state?.listFontSize else { return }
            self.groupList.fontSize = CGFloat(size)
            self.songList.fontSize = CGFloat(size)
            self.partList.fontSize = CGFloat(size)
            // Плитки й висоти рядків рахуються від кегля — перезбираємо їх.
            self.applyInterface(force: true)
        })
        tokens.append(Signals.shared.subscribe(.listKind) { [weak self] in
            guard let self else { return }
            // Панель (30) у режимі правки інша — її треба перезібрати, а не
            // лише погасити кнопки: «панель меняет внешний вид» (5.3.9).
            if self.builtEditing != self.model.isEditing {
                self.builtEditing = self.model.isEditing
                self.buildHeader()
            }
            self.applyEditMode()
            self.applyInterface()
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self else { return }
            self.captions = SongCaptions(language: self.state?.language)
            self.model.captions = self.captions
            self.applyCaptions()
            self.buildHeader()
            self.buildStrips()
            self.applyEditMode()
            self.prevSongButton?.toolTip = self.hint("PSBFindPrevSong", "Найти предыдущую песню")
            self.nextSongButton?.toolTip = self.hint("PSBFindNextSong", "Найти следующую песню")
            self.reloadBook()
        })
        bridge.watchChrome { [weak self] in self?.syncChrome() }
    }

    /// Панель, вкладки і поля: у них своїх приводів немає, і звіряються вони на
    /// кожну звірку сита — їхні величини короткі, це дешевше за новий знімок.
    private func syncChrome() {
        header.isModified = model.isModified
        saveButton?.isEnabled = model.isModified
        header.tabs.setCurrent(model.bookID)
        if songQuick.field.text != model.songQuery { songQuick.field.text = model.songQuery }
        if partQuick.field.text != model.partQuery { partQuick.field.text = model.partQuery }
        applyQuickFocus()
        applySheet()
    }

    /// Фокус полів доганяє `DeskModel`: F7 і F9 ловить спільний монітор, який
    /// нічого не знає про наші поля.
    private func applyQuickFocus() {
        // Позначка фокуса спільна з Біблією — діємо лише на своїй вкладці.
        guard state?.mode == .songs else { return }
        let wanted = DeskModel.shared.quickFocus
        guard wanted != lastQuickFocus else { return }
        lastQuickFocus = wanted
        switch wanted {
        case .book:  songQuick.field.focus()
        case .verse: partQuick.field.focus()
        default:     break
        }
    }

    // MARK: - Відкриття Пісенника

    private func openCurrentBook() {
        guard let state, let library = state.songLibrary else { return }
        let id = state.songBookID
        guard !id.isEmpty, let entry = library.entry(id) else { refreshTabs(); return }
        model.open(bookID: id, url: entry.url, preloaded: library.loadedBook(id))
        // Між запусками зберігаються пісенник, номер пісні і номер частини.
        if let remembered = state.songIndex,
           model.book?.songs.indices.contains(remembered) == true {
            model.songIndex = remembered
        }
        lastStateSong = state.songIndex
        reloadBook()
        if let part = state.songPartIndex {
            lastStatePart = part
            applyPart(number: part)
        }
        bridge.sync()
    }

    /// Відкрити інший Пісенник — клацання по вкладці (33).
    func selectBook(id: String) {
        guard let state, let library = state.songLibrary, let entry = library.entry(id) else { return }
        guard model.open(bookID: id, url: entry.url, preloaded: library.book(id)) else { return }
        state.songBookID = id
        bridge.sync()
    }

    /// Забути, з чого пораховано відбір: наступний виклик перерахує все.
    private func forgetFilter() { filterKey = "\u{0}" }

    /// Склад списків змінився цілком: інший збірник або правка пісень.
    private func reloadBook() {
        guard let state else { return }
        // Пісенник могли змінити і збоку — пунктом Плану або записом
        // «Історії»: вони пишуть прямо в `AppState`, нічого не знаючи про вікно.
        if !state.songBookID.isEmpty, state.songBookID != model.bookID,
           let entry = state.songLibrary?.entry(state.songBookID) {
            model.open(bookID: entry.id, url: entry.url,
                       preloaded: state.songLibrary?.book(entry.id))
        }

        let songs = model.book?.songs ?? []
        index.open(songs: songs, key: indexKey(songs: songs))
        forgetFilter()

        groupRows.reload(titles: model.groupTitles, groups: model.groups)
        groupList.reload()
        groupList.setSelection(IndexSet(integer: (model.groupIndex ?? -1) + 1))

        songRows.titleFormat = state.songTitleFormat
        songRows.showsCatalogNumber = model.showsCatalogNumber
        applyFilter(reload: true)
        applySongSelection(scroll: true)
        reloadParts()
        refreshTabs()
        applyEditMode()
    }

    /// Ключ розбору збірника.
    ///
    /// Ім'я, число пісень і лічильник СПРАВЖНІХ правок. Лічильник `revision` самої
    /// моделі сюди не годиться: він росте і від простого відкриття Пісенника, а
    /// разобранное в запасе от открытия не портится — и возврат к прежнему
    /// сборнику каждый раз стоил бы нового разбора всех названий.
    private func indexKey(songs: [Song]) -> String {
        if model.bookID != openedBookID {
            openedBookID = model.bookID
            openedRevision = model.revision
        } else if model.revision != openedRevision {
            openedRevision = model.revision
            editions[model.bookID, default: 0] += 1
        }
        return "\(model.bookID)#\(songs.count)#\(editions[model.bookID] ?? 0)"
    }

    /// Выбор песни могли сменить со стороны: пункт Плана и запись «Истории»
    /// пишут номер прямо в `AppState`.
    /// Повертає `true`, коли пісню взято з `AppState` (План, «Історія»).
    @discardableResult
    private func adoptSongFromState() -> Bool {
        guard let wanted = state?.songIndex, wanted != lastStateSong else { return false }
        lastStateSong = wanted
        guard wanted != model.songIndex,
              model.editor?.book.songs.indices.contains(wanted) == true else { return false }
        model.songIndex = wanted
        model.partIndex = nil
        // Пісня з Плану може бути не з відкритої групи чи не за швидким
        // вибором — сито знімаємо, як для знайденої пошуком (`reveal`):
        // показати її треба все одно.
        if songRows.position(ofSong: wanted) == nil {
            if model.groupIndex != nil {
                model.groupIndex = nil
                groupList.setSelection(IndexSet(integer: 0))
            }
            if !model.songQuery.isEmpty {
                model.songQuery = ""
                songQuick.field.text = ""
            }
            applyFilter(reload: true)
        }
        return true
    }

    /// То же для части: её листают стрелки, и они меняют только `AppState`.
    private func adoptPartFromState() {
        guard let number = state?.songPartIndex, number != lastStatePart else { return }
        lastStatePart = number
        guard let position = partRows.position(ofPart: number),
              position != model.partIndex else { return }
        model.partIndex = position
    }

    private func applySongSelection(scroll: Bool) {
        guard let song = model.songIndex, let position = songRows.position(ofSong: song) else {
            songList.setSelection(IndexSet())
            return
        }
        songList.setSelection(IndexSet(integer: position), active: position)
        // Уже видную строку не двигаем: щелчок по соседней песне не должен
        // дёргать список под рукой. Не видную ставим по центру — так её
        // находят после быстрого выбора, Плана и «Истории».
        guard scroll, !songList.visibleItems.contains(position) else { return }
        songList.scrollTo(position, place: .center)
    }

    private func reloadParts() {
        partRows.reload(song: model.song, palette: model.palette)
        partList.reload()
        applyPartSelection()
    }

    private func applyPartSelection() {
        guard let position = model.partIndex, position < partRows.rowCount else {
            partList.setSelection(IndexSet())
            return
        }
        partList.setSelection(IndexSet(integer: position), active: position)
        partList.scrollTo(position, place: .nearest)
    }

    /// Стрелки в режиме «Песни» листают части песни и меняют
    /// `state.songPartIndex` — это НОМЕР части, а не её место в списке.
    private func applyPart(number: Int) {
        guard let position = partRows.position(ofPart: number) else { return }
        model.partIndex = position
    }

    // MARK: - Вкладки Песенников (33)

    func refreshTabs() {
        guard let state else { return }
        let tabs = state.songBooks.map { entry in
            NativeSongBookTabs.Tab(id: entry.id, long: entry.displayName,
                                   short: entry.shortName, tooltip: entry.failure ?? entry.displayName,
                                   url: entry.url)
        }
        header.tabs.setTabs(tabs, current: model.bookID, longNames: longBookNames,
                            placeholder: OurWords.t("Песенников нет"))
    }
}

/// Рабочая зона: шапка сверху, три колонки под ней, фонограма — внизу.
///
/// Панель фонограм стоїть останньою, на всю ширину вікна: під нею вже сама
/// смуга з закладками пісенників (власник: «поместить над закладками названий
/// песенников и сделать на всю длину окна, с возможностью растягивания по
/// высоте»). Висоту тягнуть за межу над панеллю, подвійне клацання — як було.
@MainActor
final class NativeSongsRootView: NSView {

    private let header: NativeSongHeader
    private let columns: NativeColumnsView
    private let backing: NativeBackingTrackBar
    /// Межа над панеллю: за неї тягнуть висоту (і самоперевірка теж).
    let heightGrip = NativeBottomHeightGrip()
    /// Та сама межа знизу — щоб висоту можна було міняти з обох країв.
    let bottomGrip = NativeBottomHeightGrip()
    private static let heightKey = "backingPanelHeight"

    init(header: NativeSongHeader, columns: NativeColumnsView, backing: NativeBackingTrackBar) {
        self.header = header
        self.columns = columns
        self.backing = backing
        super.init(frame: .zero)
        addSubview(header)
        addSubview(columns)
        addSubview(heightGrip)
        addSubview(backing)
        addSubview(bottomGrip)   // поверх панелі: інакше події миші забирає вона
        heightGrip.toolTip = OurWords.t("Потяните вверх или вниз — высота панели фонограмм; двойной щелчок — как было")
        // Власник: «изменение размера с нижнего края отсутствует». Нижня межа
        // тягне так само, тільки навпаки: вниз — вище панель.
        bottomGrip.toolTip = heightGrip.toolTip
        heightGrip.onDrag = { [weak self] delta in self?.resizeBacking(by: -delta) }
        bottomGrip.onDrag = { [weak self] delta in self?.resizeBacking(by: delta) }
        heightGrip.onReset = { [weak self] in
            NativeWidths.reset(Self.heightKey)
            self?.needsLayout = true
        }
        bottomGrip.onReset = heightGrip.onReset
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Посунути межу: додатне — панель вища.
    ///
    /// Панель має два робочі стани: повний (список, картка треку, хвиля) і
    /// смужка в один ряд. Проміжні висоти лишали б половину панелі порожньою,
    /// тому висота прилипає: нижче за повну — стає смужкою, вище — повною.
    private func resizeBacking(by delta: CGFloat) {
        let wanted = backing.frame.height + delta
        let snapped = wanted < NativeBackingTrackBar.minimumHeight - 24
            ? NativeBackingTrackBar.collapsedHeight
            : max(NativeBackingTrackBar.minimumHeight, wanted)
        NativeWidths.set(Self.heightKey, snapped,
                         min: NativeBackingTrackBar.collapsedHeight, max: maximumBackingHeight)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Вище панель не піднімається: спискам пісень лишається хоч кілька рядків.
    private var maximumBackingHeight: CGFloat {
        let free = max(0, bounds.height - NativeSongHeader.height - 1 - 8)
        return max(NativeBackingTrackBar.collapsedHeight, free - 180)
    }

    /// Висота панелі зараз — самоперевірці й раскладці.
    var backingHeight: CGFloat {
        let saved = min(maximumBackingHeight,
                        NativeWidths.value(Self.heightKey, auto: NativeBackingTrackBar.minimumHeight + 40,
                                           min: NativeBackingTrackBar.collapsedHeight, max: maximumBackingHeight))
        // Той самий поділ, що й при перетягуванні: або смужка, або повна панель.
        if saved < NativeBackingTrackBar.minimumHeight - 24 { return NativeBackingTrackBar.collapsedHeight }
        return max(NativeBackingTrackBar.minimumHeight, saved)
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: NativeSongHeader.height)
        let top = NativeSongHeader.height + 1
        let gap: CGFloat = 6
        let panel = backingHeight
        let columnsHeight = max(0, bounds.height - top - panel - gap)
        columns.frame = NSRect(x: 0, y: top, width: bounds.width, height: columnsHeight)
        heightGrip.frame = NSRect(x: 0, y: columns.frame.maxY, width: bounds.width, height: gap)
        backing.frame = NSRect(x: 0, y: heightGrip.frame.maxY, width: bounds.width, height: panel)
        // Нижня межа лежить ПОВЕРХ нижнього краю панелі: місця вона не
        // забирає, а тягнути за низ дає.
        let bottom: CGFloat = 5
        bottomGrip.frame = NSRect(x: 0, y: max(0, backing.frame.maxY - bottom), width: bounds.width, height: bottom)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: NativeSongHeader.height, width: bounds.width, height: 1).fill()
    }
}
