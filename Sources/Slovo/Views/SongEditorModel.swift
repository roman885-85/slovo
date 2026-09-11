import AppKit
import SlovoCore

/// Состояние модуля «Песни» вместе с режимом редактирования Песенника
/// (руководство, 5.3.8 и 5.3.9).
///
/// Почему отдельная модель, а не поля `AppState`: редактирование живёт своей
/// жизнью — у него есть «изменённый, но не сохранённый» Песенник, который
/// нельзя отдавать в показ, пока его не сохранили. `AppState` показывает то,
/// что лежит на диске, а здесь — то, что правит оператор.
@MainActor
final class SongEditorModel: ObservableObject {

    // MARK: - Что открыто

    @Published private(set) var bookID = ""
    @Published private(set) var isEditing = false
    /// Счётчик правок. `SongBookEditor` — класс, SwiftUI его изменений не
    /// видит, поэтому каждое действие двигает этот счётчик, и только он
    /// заставляет списки перерисоваться.
    @Published private(set) var revision = 0

    /// `nil` — псевдогруппа «Все песни»; она всегда первая в списке (5.3.1).
    @Published var groupIndex: Int?
    @Published var songIndex: Int?
    @Published var partIndex: Int?

    /// Поле быстрого выбора песни (31) и части песни (32).
    @Published var songQuery = ""
    @Published var partQuery = ""

    /// «Показать номер по порядку» / «Показать номер в сборнике» — пункты
    /// контекстного меню песни. Живёт в модели, а не в виде, потому что от
    /// этого же выбора зависит, какой номер печатает экспорт без служебной
    /// информации: «включая номер песен по порядку, или номер в Песеннике»
    /// (5.3.8.4).
    @Published var showsCatalogNumber = false

    @Published var sheet: Sheet?

    private(set) var editor: SongBookEditor?
    var palette: SongChunkPalette = .factoryDefault
    var captions = SongCaptions(language: nil)

    /// Куда складывать новые и импортированные Песенники.
    var modulesFolder: URL?
    /// Все Песенники каталога — нужны меню «Скопировать песни в другой
    /// Песенник» и переключению вкладок.
    var library: SongLibrary?

    /// Песенник сохранён. Вместе с именем отдаём и сам записанный Песенник:
    /// каталог держит в `Entry` название, короткое имя и число песен, и после
    /// правки атрибутов их надо обновить — иначе полоса выбора Песенника (33)
    /// продолжит показывать старое название (5.3.9.3).
    var onSaved: ((String, SongBook) -> Void)?
    /// Появился новый файл Песенника — каталог надо собрать заново.
    var onLibraryChanged: ((String) -> Void)?
    /// Песенник перечитан с диска пунктом «Перезагрузить модуль» (5.3.7):
    /// каталог должен взять то же самое, а не свою старую копию.
    var onReloaded: ((String, SongBook) -> Void)?
    /// Часть песни выбрана для показа. Двойной щелчок — сразу в зал.
    var onPartChosen: ((Song, SongPart, Bool) -> Void)?
    /// «Добавить в План» — пункт есть только когда План кому-то нужен.
    var onAddToPlan: ((Song, SongPart?) -> Void)?

    enum Sheet: Identifiable {
        case bookAttributes(editable: Bool)
        case songAttributes(song: Int, editable: Bool)
        case newSong
        case partEditor(song: Int, part: Int?)
        case copySongs

        var id: String {
            switch self {
            case .bookAttributes(let editable):     return "book-\(editable)"
            case .songAttributes(let song, let e):  return "song-\(song)-\(e)"
            case .newSong:                          return "song-new"
            case .partEditor(let song, let part):   return "part-\(song)-\(part ?? -1)"
            case .copySongs:                        return "copy"
            }
        }
    }

    // MARK: - Доступ к данным

    var hasBook: Bool { editor != nil }
    var isModified: Bool { editor?.isModified ?? false }
    var book: SongBook? { editor?.book }
    var groups: [SongGroup] { editor?.book.groups ?? [] }
    var hasGroup: Bool { groupIndex != nil }
    var hasSong: Bool { song != nil }
    var hasPart: Bool { part != nil }

    var song: Song? {
        guard let index = songIndex, let songs = editor?.book.songs, songs.indices.contains(index) else { return nil }
        return songs[index]
    }

    var part: SongPart? {
        guard let song, let index = partIndex, song.parts.indices.contains(index) else { return nil }
        return song.parts[index]
    }

    var currentAlign: SongPartAlign { part?.align ?? .default }

    /// Свёрнутые названия — по одному разу на песенник, а не на каждый знак.
    ///
    /// `folding(options:locale:)` разбирает строку по Юникоду и стоит дорого.
    /// Пока свёртка считалась в поиске, каждая буква в поле быстрого выбора
    /// заново сворачивала все названия сборника: на «Песне возрождения 3400»
    /// это 78 мс за проход, а проходов у SwiftUI на одно нажатие бывает
    /// десяток.
    private var foldedTitles: [String] = []
    private var foldedAlternates: [String] = []
    private var foldedBookID = ""

    private func prepareFolded() {
        guard let editor, foldedBookID != bookID else { return }
        foldedBookID = bookID
        foldedTitles = editor.book.songs.map { fold($0.title) }
        foldedAlternates = editor.book.songs.map { fold($0.alternateTitle) }
    }

    /// Готовый список и то, из чего он посчитан.
    ///
    /// Это вычисляемое свойство зовётся из тела вида, то есть по многу раз в
    /// секунду. Пока оно каждый раз строило список заново, на большом
    /// сборнике окно вставало колом — владелец так и сказал: «списки
    /// тормозят, при выводе куплета зависает». Считаем один раз на изменение
    /// и держим готовое.
    private var cachedSongs: [Song] = []
    private var cachedKey = "\u{0}"

    /// Номера песен, попавших в текущую группу и подходящих под быстрый выбор.
    var visibleSongs: [Song] {
        guard let editor else { return [] }
        let query = songQuery.trimmingCharacters(in: .whitespaces)
        let key = "\(bookID)#\(groupIndex.map(String.init) ?? "-")#\(query)#\(editor.book.songs.count)"
        if key == cachedKey { return cachedSongs }

        let songs = computeVisible(editor: editor, query: query)
        cachedKey = key
        cachedSongs = songs
        return songs
    }

    /// Сбросить готовый список — после правки песенника он устарел.
    func invalidateSongList() {
        cachedKey = "\u{0}"
        foldedBookID = ""
    }

    private func computeVisible(editor: SongBookEditor, query: String) -> [Song] {
        let indices = editor.songIndices(inGroup: groupIndex)
        guard !query.isEmpty else { return indices.map { editor.book.songs[$0] } }

        // Ровно как в 5.3.5: сначала номер, потом слова в основном и
        // альтернативном названиях.
        if let number = Int(query) {
            let byNumber = indices.filter {
                editor.book.songs[$0].number == number || editor.book.songs[$0].catalogNumber == number
            }
            if !byNumber.isEmpty { return byNumber.map { editor.book.songs[$0] } }
        }
        prepareFolded()
        let needle = fold(query)
        return indices.filter { index in
            guard foldedTitles.indices.contains(index) else { return false }
            return foldedTitles[index].contains(needle) || foldedAlternates[index].contains(needle)
        }.map { editor.book.songs[$0] }
    }

    private func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }

    // MARK: - Открытие Песенника

    /// Перейти на другой Песенник. Если текущий изменён, оригинал сначала
    /// спрашивает, сохранять ли его, — здесь то же самое.
    @discardableResult
    func open(bookID id: String, url: URL?, preloaded: SongBook?) -> Bool {
        guard id != bookID || editor == nil else { return true }
        guard confirmDiscardChanges() else { return false }

        guard let url else {
            editor = nil
            bookID = id
            resetSelection()
            bump()
            return true
        }
        do {
            let book = try preloaded ?? SongBook(fileAt: url)
            editor = SongBookEditor(book: book, url: url)
            bookID = id
        } catch {
            editor = nil
            bookID = id
            warn(captions.error(2, "Ошибка"), captions.error(3, "Не удалось открыть файл модуля.\n") + "\(error)")
        }
        resetSelection()
        bump()
        return true
    }

    /// «Перезагрузить модуль Песенника» из меню правой кнопки над вкладкой
    /// (5.3.7). Файл могли поправить снаружи — читаем его заново; если у нас
    /// есть незаписанные правки, сначала спрашиваем, как со сменой Песенника.
    func reloadBook() {
        invalidateSongList()
        guard let current = editor, let url = current.url else { return }
        guard confirmDiscardChanges() else { return }
        do {
            let book = try SongBook(fileAt: url)
            editor = SongBookEditor(book: book, url: url)
            onReloaded?(bookID, book)
            resetSelection()
            bump()
        } catch {
            warn(captions.error(2, "Ошибка"),
                 captions.error(3, "Не удалось открыть файл модуля.\n") + "\(error)")
        }
    }

    private func resetSelection() {
        groupIndex = nil
        songIndex = editor?.book.songs.isEmpty == false ? 0 : nil
        partIndex = nil
        songQuery = ""
        partQuery = ""
    }

    private func bump() { revision &+= 1 }

    /// Общий приём: выполнить правку и сразу перерисовать списки.
    private func edit(_ action: () -> Void) {
        guard editor != nil else { return }
        action()
        // Готовый список песен после правки устарел: имя могли поменять, не
        // трогая их числа. Сбрасываем здесь — через `edit` проходят все
        // правки песенника, и забыть про какую-то уже нельзя.
        invalidateSongList()
        bump()
    }

    // MARK: - Режим (30.1 / 30.4)

    func enterEditMode() {
        guard hasBook else { return }
        isEditing = true
    }

    /// (30.4) «Переход в режим просмотра. Если Песенник изменён, будет выдан
    /// запрос на его сохранение».
    func leaveEditMode() {
        guard confirmDiscardChanges() else { return }
        isEditing = false
        bump()
    }

    /// Возвращает `false`, если пользователь передумал уходить.
    @discardableResult
    func confirmDiscardChanges() -> Bool {
        guard let editor, editor.isModified else { return true }
        let name = editor.book.title.isEmpty ? bookID : editor.book.title
        let question = captions.message(2, "Песенник \"%s\" изменён. Сохранить?")
            .replacingOccurrences(of: "%s", with: name)

        switch SongPrompt.threeWay(title: captions.message(3, "Сохранение Песенника"),
                                   message: question,
                                   yes: "Сохранить", no: "Не сохранять") {
        case .yes:    save(); return true
        case .no:     return true
        case .cancel: return false
        }
    }

    // MARK: - Сохранение (30.6)

    func save() {
        guard let editor, editor.isModified else { return }
        do {
            try editor.save()
            onSaved?(bookID, editor.book)
            bump()
        } catch {
            warn(captions.error(1, "Ошибка при сохранении"), "\(error)")
        }
    }

    // MARK: - Атрибуты Песенника (30.2 / 30.5, раздел 5.3.9.3)

    func openBookAttributes(editable: Bool) {
        guard hasBook else { return }
        sheet = .bookAttributes(editable: editable && isEditing)
    }

    func applyBookAttributes(title: String, shortName: String, publisher: String,
                             revisionDate: String, comment: String, charset: UInt32) {
        edit {
            editor?.updateAttributes(title: title, shortName: shortName, publisher: publisher,
                                     revisionDate: revisionDate, comment: comment, charset: charset)
        }
    }

    // MARK: - Группы (5.3.9.4)

    var groupTitles: [String] {
        [captions.message(4, "Все песни")] + groups.map(\.name)
    }

    func addGroup() {
        guard let name = SongPrompt.input(title: captions.message(5, "Создание группы"),
                                          message: captions.message(6, "Введите название группы"),
                                          value: ""), !name.isEmpty else { return }
        edit {
            let index = editor?.addGroup(named: name)
            groupIndex = index
        }
    }

    func renameGroup() {
        guard let index = groupIndex, groups.indices.contains(index) else { return }
        guard let name = SongPrompt.input(title: captions.message(15, "Редактирование группы"),
                                          message: captions.message(6, "Введите название группы"),
                                          value: groups[index].name), !name.isEmpty else { return }
        edit { editor?.renameGroup(at: index, to: name) }
    }

    func deleteGroup() {
        guard let index = groupIndex, groups.indices.contains(index) else { return }
        guard SongPrompt.confirm(title: captions.message(1, "Удаление группы"),
                                 message: captions.message(0, "Внимание! Все связи с этой группой будут разорваны. Удалить группу?")) else { return }
        edit {
            editor?.removeGroup(at: index)
            groupIndex = nil
        }
    }

    func duplicateGroup() {
        guard let index = groupIndex, groups.indices.contains(index) else { return }
        edit { groupIndex = editor?.duplicateGroup(at: index) }
    }

    func moveGroup(by delta: Int) {
        guard let index = groupIndex else { return }
        edit { if let target = editor?.moveGroup(at: index, by: delta) { groupIndex = target } }
    }

    // MARK: - Песня в группе (5.3.9.5)

    func isSongInGroup(_ group: Int) -> Bool {
        guard let songIndex else { return false }
        return editor?.isSong(songIndex, inGroup: group) ?? false
    }

    func addSongToGroup(_ group: Int) {
        guard let songIndex else { return }
        edit { editor?.addSong(songIndex, toGroup: group) }
    }

    func removeSongFromCurrentGroup() {
        guard let songIndex, let group = groupIndex else { return }
        guard SongPrompt.confirm(title: captions.message(14, "Удаление песни из группы"),
                                 message: captions.message(13, "Удалить песню из группы?")) else { return }
        edit { editor?.removeSong(songIndex, fromGroup: group) }
    }

    /// Что сделает кнопка (2) панели «Песня» при нынешнем выборе.
    ///
    /// В файле перевода на удаление песни заведены две пары сообщений:
    /// 11/12 «Внимание! Песня будет удалена из всех групп.» и 13/14 «Удалить
    /// песню из группы?». Вторая пара имеет смысл только тогда, когда выбрана
    /// пользовательская группа, — на «Все песни» убирать песню не из чего.
    var deleteRemovesFromGroupOnly: Bool { groupIndex != nil }

    // MARK: - Песни (5.3.9.6)

    /// «Для создания новой песни необходимо нажать кнопку (1)… В результате
    /// откроется окно для ввода атрибутов и текста новой песни.» Песня
    /// появляется в списке только после «Ок»: отменённый ввод не должен
    /// оставлять пустую строку.
    func addSong() {
        guard hasBook else { return }
        sheet = .newSong
    }

    func createSong(_ mutate: (inout Song) -> Void) {
        edit {
            var song = Song(index: editor?.book.songs.count ?? 0, title: "")
            mutate(&song)
            songIndex = editor?.appendSong(song)
            partIndex = nil
        }
    }

    /// Кнопка (2) панели «Песня». На «Все песни» удаляет песню из Песенника
    /// (11/12), на пользовательской группе — только из этой группы (13/14):
    /// иначе второй паре сообщений в файле автора неоткуда взяться, а
    /// удаление песни из Песенника щелчком по группе было бы неожиданным.
    func deleteSong() {
        guard let index = songIndex else { return }
        if deleteRemovesFromGroupOnly {
            removeSongFromCurrentGroup()
            return
        }
        guard SongPrompt.confirm(title: captions.message(12, "Удаление песни"),
                                 message: captions.message(11, "Внимание! Песня будет удалена из всех групп.")) else { return }
        edit {
            editor?.removeSong(at: index)
            songIndex = editor?.book.songs.isEmpty == false ? min(index, (editor?.book.songs.count ?? 1) - 1) : nil
            partIndex = nil
        }
    }

    func duplicateSong() {
        guard let index = songIndex else { return }
        edit { if let copy = editor?.duplicateSong(at: index) { songIndex = copy } }
    }

    func moveSong(by delta: Int) {
        guard let index = songIndex else { return }
        edit { if let target = editor?.moveSong(at: index, by: delta) { songIndex = target } }
    }

    /// Кнопка (7) — «Установление нового номера по порядку текущей песни».
    func setSongPosition() {
        guard let index = songIndex, let editor else { return }
        guard let raw = SongPrompt.input(title: captions.message(29, "Перемещение песни"),
                                         message: captions.message(30, "Укажите новую позицию песни"),
                                         value: String(index + 1)) else { return }
        guard let number = Int(raw.trimmingCharacters(in: .whitespaces)),
              number >= 1, number <= editor.book.songs.count else {
            warn(captions.message(8, "Ошибка ввода"),
                 captions.message(31, "Введите корректную позицию песни"))
            return
        }
        edit { if let target = editor.setSongPosition(at: index, to: number) { songIndex = target } }
    }

    /// Кнопка (8) — сортировка. «Этот процесс необратим».
    func sortSongs(_ order: SongBookEditor.SongSort) {
        let question = order == .byNumber
            ? captions.message(48, "Произвести сортировку песен по НОМЕРУ?\n(Эта операция необратима!)")
            : captions.message(49, "Произвести сортировку песен по НАЗВАНИЮ?\n(Эта операция необратима!)")
        guard SongPrompt.confirm(title: captions.message(47, "Сортировка песен"), message: question) else { return }
        edit {
            editor?.sortSongs(order)
            songIndex = editor?.book.songs.isEmpty == false ? 0 : nil
            partIndex = nil
        }
    }

    func openSongAttributes(editable: Bool) {
        guard let index = songIndex else { return }
        sheet = .songAttributes(song: index, editable: editable && isEditing)
    }

    func applySongAttributes(at index: Int, _ mutate: @escaping (inout Song) -> Void) {
        edit { editor?.updateSong(at: index, mutate) }
    }

    // MARK: - Части песни (5.3.9.7)

    func addPart() {
        guard songIndex != nil else { return }
        sheet = .partEditor(song: songIndex!, part: nil)
    }

    func openPartEditor() {
        guard let songIndex, let partIndex else { return }
        sheet = .partEditor(song: songIndex, part: partIndex)
    }

    func applyPart(songAt songIndex: Int, partAt partIndex: Int?, kind: String, text: String, align: SongPartAlign) {
        edit {
            if let partIndex {
                editor?.updatePart(at: partIndex, inSongAt: songIndex) {
                    $0.kind = kind
                    $0.text = text
                    $0.align = align
                }
                self.partIndex = partIndex
            } else {
                let position = (editor?.book.songs[songIndex].parts.count ?? 0)
                let part = SongPart(index: position, kind: kind, text: text, align: align)
                self.partIndex = editor?.insertPart(part, inSongAt: songIndex, at: position)
            }
        }
    }

    func deletePart() {
        guard let songIndex, let partIndex else { return }
        guard SongPrompt.confirm(title: captions.message(19, "Удаление части из песни"),
                                 message: captions.message(20, "Удалить эту часть из песни?")) else { return }
        edit {
            editor?.removePart(at: partIndex, inSongAt: songIndex)
            let count = editor?.book.songs[songIndex].parts.count ?? 0
            self.partIndex = count == 0 ? nil : min(partIndex, count - 1)
        }
    }

    func duplicatePart() {
        guard let songIndex, let partIndex else { return }
        edit { if let copy = editor?.duplicatePart(at: partIndex, inSongAt: songIndex) { self.partIndex = copy } }
    }

    func movePart(by delta: Int) {
        guard let songIndex, let partIndex else { return }
        edit { if let target = editor?.movePart(at: partIndex, inSongAt: songIndex, by: delta) { self.partIndex = target } }
    }

    func setAlign(_ align: SongPartAlign) {
        guard let songIndex, let partIndex else { return }
        edit { editor?.setAlign(align, forPartAt: partIndex, inSongAt: songIndex) }
    }

    func formatPart(_ style: SongTextFormat) {
        guard let songIndex, let partIndex else { return }
        edit { editor?.format(style, partAt: partIndex, inSongAt: songIndex) }
    }

    func unformatPart() {
        guard let songIndex, let partIndex else { return }
        guard SongPrompt.confirm(title: captions.message(26, "Отмена форматирования"),
                                 message: captions.message(25, "Убрать переносы строк для этой части песни?")) else { return }
        edit { editor?.unformat(partAt: partIndex, inSongAt: songIndex) }
    }

    // MARK: - Контекстное меню песни (5.3.9.2)

    /// «Дублировать припев» и «Дублировать припев по признаку».
    func duplicateRefrainInSong(byMarker: Bool) {
        guard let songIndex else { return }
        var marker: String?
        if byMarker {
            guard let value = SongPrompt.input(title: captions.message(16, "Дублировать припевы по признаку"),
                                               message: captions.message(22, "Строка-признак припева:"),
                                               value: "") else { return }
            marker = value
        } else {
            guard SongPrompt.confirm(title: captions.message(40, "Внимание"),
                                     message: captions.message(27, "Дублировать припев после каждого куплета?")) else { return }
        }
        edit { editor?.duplicateRefrain(inSongAt: songIndex, marker: marker, palette: palette) }
    }

    /// «Дублировать припевы во ВСЕХ песнях!»
    func duplicateRefrainsEverywhere(byMarker: Bool) {
        var marker: String?
        if byMarker {
            guard let value = SongPrompt.input(title: captions.message(16, "Дублировать припевы по признаку"),
                                               message: captions.message(22, "Строка-признак припева:"),
                                               value: "") else { return }
            marker = value
        }
        guard SongPrompt.confirm(title: captions.message(40, "Внимание"),
                                 message: captions.message(28, "Дублировать припев после каждого куплета\nво ВСЕХ ПЕСНЯХ?")) else { return }
        edit { editor?.duplicateRefrainsInAllSongs(marker: marker, palette: palette) }
    }

    /// «Форматировать песню» — сразу все её части.
    func formatSong(_ style: SongTextFormat) {
        guard let songIndex else { return }
        guard SongPrompt.confirm(title: captions.message(35, "Форматирование Песни"),
                                 message: captions.message(36, "Вы уверены?")) else { return }
        edit { editor?.format(style, songAt: songIndex) }
    }

    func unformatSong() {
        guard let songIndex else { return }
        guard SongPrompt.confirm(title: captions.message(34, "Отмена форматирования"),
                                 message: captions.message(36, "Вы уверены?")) else { return }
        edit { editor?.unformat(songAt: songIndex) }
    }

    /// «Форматирование ВСЕХ песен». Оригинал предупреждает, что это надолго.
    func formatAllSongs(_ style: SongTextFormat) {
        guard SongPrompt.confirm(title: captions.message(37, "Форматирование ВСЕХ Песен"),
                                 message: captions.message(36, "Вы уверены?") + "\n"
                                    + captions.message(39, "Это может занять длительное время.")) else { return }
        edit { editor?.formatAllSongs(style) }
    }

    func unformatAllSongs() {
        guard SongPrompt.confirm(title: captions.message(38, "Отмена форматирования ВСЕХ Песен."),
                                 message: captions.message(36, "Вы уверены?")) else { return }
        edit { editor?.unformatAllSongs() }
    }

    /// «Номера в сборнике»: увеличить или уменьшить от выбранной песни и до
    /// последней.
    func shiftCatalogNumbers(increase: Bool) {
        guard let songIndex else { return }
        let prompt = increase ? captions.message(43, "Увеличить номера на:")
                              : captions.message(44, "Уменьшить номера на:")
        guard let raw = SongPrompt.input(title: captions.message(42, "Изменение номеров песен"),
                                         message: prompt, value: "1"),
              let value = Int(raw.trimmingCharacters(in: .whitespaces)), value != 0 else { return }
        edit { editor?.shiftCatalogNumbers(from: songIndex, by: increase ? value : -value) }
    }

    func clearCatalogNumbers() {
        guard SongPrompt.confirm(title: captions.message(40, "Внимание"),
                                 message: captions.message(45, "Очистить поле \"Номер в сборнике\" во ВСЕХ песнях?")) else { return }
        edit { editor?.clearCatalogNumbers() }
    }

    func setCatalogNumbersToOrdinal() {
        guard SongPrompt.confirm(title: captions.message(40, "Внимание"),
                                 message: captions.message(46, "Установить поле \"Номер в сборнике\" во ВСЕХ песнях равным порядковому номеру?")) else { return }
        edit { editor?.setCatalogNumbersToOrdinal() }
    }

    // MARK: - Управление Песенниками (5.3.8.1 – 5.3.8.4)

    /// «Создать новый Песенник»: сначала имя файла, потом окно атрибутов.
    func createBook() {
        guard confirmDiscardChanges() else { return }
        guard let url = SongPrompt.saveFile(title: captions.caption("SaveModuleDialog", "Сохранить Песенник как..."),
                                            name: OurWords.t("Новый песенник"), extensions: ["vbm"],
                                            directory: modulesFolder) else { return }

        let name = url.deletingPathExtension().lastPathComponent
        let book = SongBookEditor.newBook(title: name, shortName: name)
        let editor = SongBookEditor(book: book, url: url, isModified: true)
        do {
            try editor.save()
        } catch {
            warn(captions.error(4, "Не удалось создать файл:"), url.path + "\n\(error)")
            return
        }
        adopt(editor, id: name)
        // «После этого откроется окно редактирования атрибутов Песенника.»
        sheet = .bookAttributes(editable: true)
    }

    /// «Копирование песен в другой Песенник» (5.3.8.2).
    func openCopySongs() {
        guard hasBook else { return }
        sheet = .copySongs
    }

    /// Сама операция: скопировать и сразу сохранить приёмный Песенник.
    func copySongs(_ indices: [Int], into destination: SongLibrary.Entry) {
        guard let source = editor?.book else { return }
        do {
            var target = try SongBook(fileAt: destination.url)
            var askAll: SongBookEditor.CopyConflict?
            SongBookEditor.copySongs(indices, from: source, into: &target) { song in
                if let askAll { return askAll }
                let question = captions.message(41, "Песня \"%s\" уже существует в приемном Песеннике.\nПерезаписать?")
                    .replacingOccurrences(of: "%s", with: song.title)
                let answer = SongPrompt.threeWay(title: captions.message(40, "Внимание"),
                                                 message: question,
                                                 yes: "Перезаписать", no: "Пропустить")
                switch answer {
                case .yes:    return .overwrite
                case .no:     return .skip
                case .cancel: askAll = .skip; return .skip
                }
            }
            try SongBookWriter.write(target, to: destination.url)
            // Итогового окна «добавлено столько-то» в оригинале нет: после
            // «Ок» руководство не описывает ни одного сообщения, и в
            // SongsPluginFrame под него нет соответствующей строки.
            onSaved?(destination.id, target)
        } catch {
            warn(captions.error(5, "Не удалось перезаписать файл:"), destination.url.path + "\n\(error)")
        }
    }

    /// «Импортировать из BibleQuote модуля» (5.3.8.3).
    func importBibleQuote() {
        guard confirmDiscardChanges() else { return }
        guard let source = SongPrompt.openFile(title: captions.message(33, "Импорт Песенника"),
                                               message: "Файл biblequote.ini модуля-песенника",
                                               extensions: ["ini"], allowsDirectories: true) else { return }
        // «Здесь возможно ввести символ или строку, которыми помечаются
        // припевы в BibleQuote модуле… Ручной ввод необходим, т.к. признак
        // не стандартизирован.»
        guard let marker = SongPrompt.input(title: captions.message(33, "Импорт Песенника"),
                                            message: captions.message(22, "Строка-признак припева:"),
                                            value: "") else { return }
        importBook(named: source.deletingPathExtension().lastPathComponent) {
            try SongBookImporter.fromBibleQuote(iniAt: source,
                                                refrainMarker: marker.isEmpty ? nil : marker,
                                                palette: self.palette)
        }
    }

    /// «Импортировать из SoftProjector модуля» (5.3.8.3). Признак припева
    /// вводить не нужно: «в этом формате припевы промаркированы однозначно».
    func importSoftProjector() {
        guard confirmDiscardChanges() else { return }
        guard let source = SongPrompt.openFile(title: captions.message(33, "Импорт Песенника"),
                                               message: OurWords.t("Файл .sps программы SoftProjector"),
                                               extensions: ["sps"], allowsDirectories: false) else { return }
        importBook(named: source.deletingPathExtension().lastPathComponent) {
            try SongBookImporter.fromSoftProjector(fileAt: source, palette: self.palette)
        }
    }

    private func importBook(named suggestion: String, _ make: () throws -> SongBook) {
        let imported: SongBook
        do {
            imported = try make()
        } catch {
            warn(captions.error(2, "Ошибка"), "\(error)")
            return
        }
        guard let url = SongPrompt.saveFile(title: captions.caption("SaveModuleDialog", "Сохранить Песенник как..."),
                                            name: suggestion, extensions: ["vbm"],
                                            directory: modulesFolder) else { return }

        let editor = SongBookEditor(book: imported, url: url, isModified: true)
        do {
            try editor.save()
        } catch {
            warn(captions.error(4, "Не удалось создать файл:"), url.path + "\n\(error)")
            return
        }
        adopt(editor, id: url.deletingPathExtension().lastPathComponent)
        // «Часть полей будут заполнены автоматически данными из
        // импортируемого модуля» — и сразу показываем окно атрибутов.
        sheet = .bookAttributes(editable: true)
    }

    /// «Экспортировать Песенник в текстовый файл» (5.3.8.4).
    func exportToTextFile() {
        guard let book = editor?.book else { return }
        let answer = SongPrompt.threeWay(title: captions.message(50, "Экспорт Песенника"),
                                         message: captions.message(55, "Экспортировать вместе со служебной информацией Песенника?\n\nДа - экспортировать тексты песен и служебную информацию\nНет - экспортировать только тексты песен"),
                                         yes: "Да", no: "Нет")
        let text: String
        switch answer {
        case .yes:    text = SongBookTextFile.exportWithServiceInfo(book)
        // «в файл выгружается только названия песен и их содержимое, включая
        // номер песен по порядку, ИЛИ номер в Песеннике». Какой именно —
        // решает тот же переключатель, что и в списке песен: печатаем то, что
        // оператор сейчас видит на экране.
        case .no:     text = SongBookTextFile.exportPlain(book,
                                                          numbering: showsCatalogNumber ? .catalog : .ordinal)
        case .cancel: return
        }
        guard let url = SongPrompt.saveFile(title: captions.caption("SaveModuleAsTextDialog", "Сохранить Песенник в текстовый файл как..."),
                                            name: book.shortName.isEmpty ? bookID : book.shortName,
                                            extensions: ["txt"], directory: nil) else { return }
        do {
            try SongBookTextFile.write(text, to: url)
        } catch {
            warn(captions.error(4, "Не удалось создать файл:"), url.path + "\n\(error)")
        }
    }

    /// «Импортировать Песенник из текстового файла» (5.3.8.4).
    func importFromTextFile() {
        guard editor != nil else { return }
        guard let url = SongPrompt.openFile(title: captions.caption("loadModuleAsTextDialog", "Загрузить Песенник из текстового файла"),
                                            message: "", extensions: ["txt"], allowsDirectories: false) else { return }
        guard let text = Self.readText(at: url) else {
            warn(captions.error(2, "Ошибка"), captions.error(3, "Не удалось открыть файл модуля.\n") + url.path)
            return
        }
        let answer = SongPrompt.threeWay(title: captions.message(56, "Чтение Песенника из текстового файла"),
                                         message: captions.message(57, "Добавить песни в конец Песенника?\n\nДа - добавить в конец\nНет - полностью заменить все песни"),
                                         yes: "Да", no: "Нет")
        let mode: SongBookTextFile.ImportMode
        switch answer {
        case .yes:    mode = .append
        case .no:     mode = .replace
        case .cancel: return
        }

        edit {
            guard let current = editor else { return }
            var book = current.book
            let added = SongBookTextFile.importSongs(from: text, into: &book, mode: mode, palette: palette)
            guard added > 0 else {
                warn(captions.error(2, "Ошибка"), captions.message(53, "Песен не найдено"))
                return
            }
            let replacement = SongBookEditor(book: book, url: current.url, isModified: true)
            editor = replacement
            songIndex = book.songs.isEmpty ? nil : 0
            partIndex = nil
            // «Если импорт произошел успешно Песенник можно сохранить,
            // путём нажатия на кнопку (30.6)» — сами не сохраняем.
            isEditing = true
        }
    }

    private func adopt(_ newEditor: SongBookEditor, id: String) {
        editor = newEditor
        bookID = id
        resetSelection()
        isEditing = true
        onLibraryChanged?(id)
        bump()
    }

    // MARK: -

    private func warn(_ title: String, _ message: String) {
        SongPrompt.warn(title: title, message: message)
    }

    /// Текстовые выгрузки приходят и из Windows: там их пишут в UTF-8 с
    /// меткой, а старые — в однобайтовой кодировке. Гадать нельзя, поэтому
    /// сначала UTF-8, потом кириллическая CP1251.
    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1251)
    }
}
