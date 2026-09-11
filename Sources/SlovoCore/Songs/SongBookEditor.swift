import Foundation

// MARK: - Вирівнювання частини пісні

/// Вирівнювання тексту частини пісні — кнопки (9)–(12) панелі інструментів
/// списку «Текст» (посібник, 5.3.9.2).
///
/// Числа взято не зі стелі: у файлі пісенника в кожної частини є службове
/// поле UInt32, і в коді оригіналу воно порівнюється ланцюжком
/// `1 → «$Align$=Left», 2 → «$Align$=Right», 3 → «$Align$=Center»`.
/// Нуль означає «як задано в шаблоні слайда».
public enum SongPartAlign: UInt32, Sendable, Hashable, CaseIterable, Identifiable {
    case `default` = 0
    case left = 1
    case right = 2
    case center = 3

    public var id: UInt32 { rawValue }

    /// Як оригінал називає це вирівнювання при експорті в текстовий файл.
    public var exportName: String? {
        switch self {
        case .default: return nil
        case .left:    return "Left"
        case .right:   return "Right"
        case .center:  return "Center"
        }
    }

    public init?(exportName: String) {
        switch exportName.trimmingCharacters(in: .whitespaces).lowercased() {
        case "left":   self = .left
        case "right":  self = .right
        case "center": self = .center
        case "":       self = .default
        default:       return nil
        }
    }
}

// MARK: - Група пісень

/// Користувацька група пісень — список «Група» (26) з розділу 5.3.1.
/// Зберігає номери пісень у збірнику, а не самі пісні: так їх зберігає і файл.
public struct SongGroup: Sendable, Hashable, Identifiable {
    public var name: String
    public var songIndices: [Int]

    public var id: String { name }

    public init(name: String, songIndices: [Int] = []) {
        self.name = name
        self.songIndices = songIndices
    }
}

// MARK: - Форматування тексту

/// Пункти меню «Форматування тексту» — кнопка (13) панелі «Текст»
/// і пункти `NFormatByLiters` / `NFormatByOptimalSize` з файла перекладу.
public enum SongTextFormat: String, Sendable, CaseIterable, Identifiable {
    case byLiters          // «Разбиение по Заглавным Буквам»
    case byOptimalSize     // «Оптимальное размещение на экране»

    public var id: String { rawValue }
}

public enum SongTextFormatter {

    /// «Скасування форматування» — кнопка (14). Посібник прямо описує
    /// результат: «удаляет все переносы строк так, что, например,
    /// четверостишие становится одной строкой вместо четырёх».
    public static func unformat(_ text: String) -> String {
        let words = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0.isNewline || $0 == "\u{0B}" || $0 == "\t" })
            .flatMap { $0.split(separator: " ") }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// «Розбиття за Великими Літерами»: рядок починається там, де починається
    /// слово з великої літери. У пісенниках так набрано більшість текстів,
    /// тому за великими відновлюється вихідне розбиття на рядки.
    public static func byLiters(_ text: String) -> String {
        let flat = unformat(text)
        guard !flat.isEmpty else { return flat }

        var lines: [String] = []
        var current: [Substring] = []
        for word in flat.split(separator: " ") {
            let startsSentence = word.first.map { $0.isUppercase } ?? false
            if startsSentence, !current.isEmpty {
                lines.append(current.joined(separator: " "))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { lines.append(current.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    /// «Оптимальне розміщення на екрані»: рядки приблизно однієї довжини, без
    /// розриву слів. Оригінал рахує за шириною шаблону слайда; ширини тут
    /// немає, тому беремо цільову довжину рядка і розкладаємо текст рівно —
    /// це дає той самий зоровий результат: акуратна «цеглина» тексту.
    public static func byOptimalSize(_ text: String, targetLineLength: Int = 32) -> String {
        let flat = unformat(text)
        guard !flat.isEmpty else { return flat }
        let words = flat.split(separator: " ").map(String.init)
        guard words.count > 1 else { return flat }

        let total = flat.count
        let lineCount = max(1, Int((Double(total) / Double(targetLineLength)).rounded()))
        guard lineCount > 1 else { return flat }
        let width = max(words.map(\.count).max() ?? targetLineLength,
                        Int((Double(total) / Double(lineCount)).rounded(.up)))

        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    public static func apply(_ format: SongTextFormat, to text: String) -> String {
        switch format {
        case .byLiters:      return byLiters(text)
        case .byOptimalSize: return byOptimalSize(text)
        }
    }
}

// MARK: - Властивості пісні

extension Song {
    /// Записати властивість виду `$ID$=1728`. Порожнє значення прибирає рядок —
    /// саме так працює пункт «Очистити поле "Номер у збірнику"».
    public mutating func setProperty(_ key: String, _ value: String?) {
        let marker = key.hasPrefix("$") ? key : "$\(key)$"
        var lines = properties.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(marker + "=") }

        if let value, !value.isEmpty { lines.append("\(marker)=\(value)") }
        properties = lines.joined(separator: "\r\n")
    }

    /// «Номер у збірнику» з вікна атрибутів пісні (поле `ELogicNum`).
    public var catalogNumberText: String {
        propertyPairs["$ID$"]?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    public var tune: String {
        propertyPairs["$TUNE$"]?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

// MARK: - Редактор Пісенника

/// Змінюваний Пісенник і всі операції розділу 5.3.9 посібника.
///
/// Окремий клас, а не змінювана структура, з однієї причини: кнопка
/// «Зберегти Пісенник» (30.6) має бути неактивна, поки Пісенник не
/// мінявся, — отже, хтось зобов'язаний пам'ятати, мінявся він чи ні. Тут це
/// `isModified`, і його виставляє кожна операція.
public final class SongBookEditor {

    public private(set) var book: SongBook
    public private(set) var url: URL?
    public private(set) var isModified: Bool

    public init(book: SongBook, url: URL?, isModified: Bool = false) {
        self.book = book
        self.url = url
        self.isModified = isModified
    }

    public convenience init(fileAt url: URL) throws {
        self.init(book: try SongBook(fileAt: url), url: url)
    }

    /// Порожній Пісенник — заготовка для пункту «Створити новий Пісенник».
    public static func newBook(title: String, shortName: String) -> SongBook {
        SongBook(title: title, shortName: shortName)
    }

    private func touch() { isModified = true }

    /// Позначити як незбережений ззовні — наприклад, після правки атрибутів.
    public func markModified() { touch() }

    // MARK: - Атрибути Пісенника (30.2 / 30.5)

    public func updateAttributes(title: String, shortName: String, publisher: String,
                                 revisionDate: String, comment: String, charset: UInt32) {
        book.title = title
        book.shortName = shortName
        book.publisher = publisher
        book.revisionDate = revisionDate
        book.comment = comment
        book.charset = charset
        touch()
    }

    // MARK: - Збереження (30.6)

    @discardableResult
    public func save() throws -> URL {
        guard let url else { throw SongBookError.notASongBook(OurWords.t("путь к Песеннику не задан")) }
        try save(to: url)
        return url
    }

    public func save(to destination: URL) throws {
        try SongBookWriter.write(book, to: destination)
        url = destination
        isModified = false
    }

    // MARK: - Групи (5.3.9.4)

    /// Номери пісень, які показує список «Пісня» для вибраної групи.
    /// `nil` — псевдогрупа «Усі пісні», вона завжди перша в списку.
    public func songIndices(inGroup group: Int?) -> [Int] {
        guard let group, book.groups.indices.contains(group) else {
            return Array(book.songs.indices)
        }
        // Порядок у групі — порядок у Пісеннику: так його показує оригінал.
        let members = Set(book.groups[group].songIndices)
        return book.songs.indices.filter { members.contains($0) }
    }

    @discardableResult
    public func addGroup(named name: String) -> Int {
        book.groups.append(SongGroup(name: name))
        touch()
        return book.groups.count - 1
    }

    public func renameGroup(at index: Int, to name: String) {
        guard book.groups.indices.contains(index) else { return }
        book.groups[index].name = name
        touch()
    }

    public func removeGroup(at index: Int) {
        guard book.groups.indices.contains(index) else { return }
        book.groups.remove(at: index)
        touch()
    }

    @discardableResult
    public func duplicateGroup(at index: Int) -> Int? {
        guard book.groups.indices.contains(index) else { return nil }
        var copy = book.groups[index]
        copy.name = Self.copyName(of: copy.name, taken: book.groups.map(\.name))
        book.groups.insert(copy, at: index + 1)
        touch()
        return index + 1
    }

    @discardableResult
    public func moveGroup(at index: Int, by delta: Int) -> Int? {
        guard book.groups.indices.contains(index) else { return nil }
        let target = index + delta
        guard book.groups.indices.contains(target) else { return nil }
        book.groups.swapAt(index, target)
        touch()
        return target
    }

    // MARK: - Пісня в групі (5.3.9.5)

    public func isSong(_ songIndex: Int, inGroup group: Int) -> Bool {
        guard book.groups.indices.contains(group) else { return false }
        return book.groups[group].songIndices.contains(songIndex)
    }

    public func addSong(_ songIndex: Int, toGroup group: Int) {
        guard book.groups.indices.contains(group),
              book.songs.indices.contains(songIndex),
              !book.groups[group].songIndices.contains(songIndex) else { return }
        book.groups[group].songIndices.append(songIndex)
        book.groups[group].songIndices.sort()
        touch()
    }

    public func removeSong(_ songIndex: Int, fromGroup group: Int) {
        guard book.groups.indices.contains(group) else { return }
        let before = book.groups[group].songIndices.count
        book.groups[group].songIndices.removeAll { $0 == songIndex }
        if book.groups[group].songIndices.count != before { touch() }
    }

    // MARK: - Пісні (5.3.9.6)

    @discardableResult
    public func insertSong(_ song: Song, at position: Int) -> Int {
        let target = min(max(0, position), book.songs.count)
        var inserted = song
        inserted.index = target
        book.songs.insert(inserted, at: target)
        // Усе, що стояло починаючи з цієї позиції, зсунулося на одиницю —
        // посилання в групах зобов'язані зсунутися разом із піснями.
        remapGroups { $0 < target ? $0 : $0 + 1 }
        renumberSongs()
        touch()
        return target
    }

    @discardableResult
    public func appendSong(_ song: Song) -> Int {
        insertSong(song, at: book.songs.count)
    }

    public func removeSong(at index: Int) {
        guard book.songs.indices.contains(index) else { return }
        book.songs.remove(at: index)
        // «Внимание! Песня будет удалена из всех групп.» — повідомлення оригіналу.
        for position in book.groups.indices {
            book.groups[position].songIndices.removeAll { $0 == index }
        }
        remapGroups { $0 < index ? $0 : $0 - 1 }
        renumberSongs()
        touch()
    }

    @discardableResult
    public func duplicateSong(at index: Int) -> Int? {
        guard book.songs.indices.contains(index) else { return nil }
        var copy = book.songs[index]
        copy.title = Self.copyName(of: copy.title, taken: book.songs.map(\.title))
        return insertSong(copy, at: index + 1)
    }

    public func updateSong(at index: Int, _ mutate: (inout Song) -> Void) {
        guard book.songs.indices.contains(index) else { return }
        mutate(&book.songs[index])
        book.songs[index].index = index
        renumberParts(in: index)
        touch()
    }

    /// Кнопки (5)–(6) панелі «Пісня»: перемістити на одну позицію.
    @discardableResult
    public func moveSong(at index: Int, by delta: Int) -> Int? {
        guard book.songs.indices.contains(index) else { return nil }
        let target = index + delta
        guard book.songs.indices.contains(target) else { return nil }
        return setSongPosition(at: index, to: target + 1)
    }

    /// Кнопка (7): «Установление нового номера по порядку текущей песни.
    /// При этом эта песня будет помещена в позицию, соответствующую
    /// введённому номеру». Номер — людський, з одиниці.
    @discardableResult
    public func setSongPosition(at index: Int, to number: Int) -> Int? {
        guard book.songs.indices.contains(index) else { return nil }
        let target = min(max(0, number - 1), book.songs.count - 1)
        guard target != index else { return index }

        let song = book.songs.remove(at: index)
        book.songs.insert(song, at: target)
        remapGroups { old in
            if old == index { return target }
            if index < target { return (old > index && old <= target) ? old - 1 : old }
            return (old >= target && old < index) ? old + 1 : old
        }
        renumberSongs()
        touch()
        return target
    }

    /// Кнопка (8): меню сортування. «Этот процесс необратим и производит
    /// реальную сортировку песен в Песеннике».
    public enum SongSort: String, Sendable, CaseIterable, Identifiable {
        case byNumber      // «За Номером»
        case byTitle       // «За Назвою»
        public var id: String { rawValue }
    }

    public func sortSongs(_ order: SongSort) {
        guard !book.songs.isEmpty else { return }
        let positions = Array(book.songs.indices)
        let sorted: [Int]

        switch order {
        case .byNumber:
            // «Если номер в песне не указан, будет произведена сортировка по
            // названию» — так попереджає сам оригінал перед сортуванням.
            sorted = positions.sorted { left, right in
                let a = book.songs[left].catalogNumber
                let b = book.songs[right].catalogNumber
                switch (a, b) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default:
                    return book.songs[left].title.localizedStandardCompare(book.songs[right].title) == .orderedAscending
                }
            }
        case .byTitle:
            sorted = positions.sorted {
                book.songs[$0].title.localizedStandardCompare(book.songs[$1].title) == .orderedAscending
            }
        }

        book.songs = sorted.map { book.songs[$0] }
        var mapping: [Int: Int] = [:]
        for (newIndex, oldIndex) in sorted.enumerated() { mapping[oldIndex] = newIndex }
        remapGroups { mapping[$0] ?? $0 }
        renumberSongs()
        touch()
    }

    // MARK: - «Номери в збірнику» (контекстне меню пісні)

    /// «Збільшити/Зменшити від цієї пісні і до кінця на…».
    public func shiftCatalogNumbers(from index: Int, by delta: Int) {
        guard book.songs.indices.contains(index), delta != 0 else { return }
        for position in index..<book.songs.count {
            guard let current = book.songs[position].catalogNumber else { continue }
            book.songs[position].setProperty("$ID$", String(max(0, current + delta)))
        }
        touch()
    }

    /// «Очистити поле "Номер у збірнику" в УСІХ піснях».
    public func clearCatalogNumbers() {
        for position in book.songs.indices { book.songs[position].setProperty("$ID$", nil) }
        touch()
    }

    /// «Установити поле "Номер у збірнику" в УСІХ піснях рівним
    /// порядковому номеру».
    public func setCatalogNumbersToOrdinal() {
        for position in book.songs.indices {
            book.songs[position].setProperty("$ID$", String(position + 1))
        }
        touch()
    }

    // MARK: - Частини пісні (5.3.9.7)

    @discardableResult
    public func insertPart(_ part: SongPart, inSongAt songIndex: Int, at position: Int) -> Int? {
        guard book.songs.indices.contains(songIndex) else { return nil }
        let target = min(max(0, position), book.songs[songIndex].parts.count)
        var inserted = part
        inserted.index = target
        book.songs[songIndex].parts.insert(inserted, at: target)
        renumberParts(in: songIndex)
        touch()
        return target
    }

    public func removePart(at partIndex: Int, inSongAt songIndex: Int) {
        guard book.songs.indices.contains(songIndex),
              book.songs[songIndex].parts.indices.contains(partIndex) else { return }
        book.songs[songIndex].parts.remove(at: partIndex)
        renumberParts(in: songIndex)
        touch()
    }

    @discardableResult
    public func duplicatePart(at partIndex: Int, inSongAt songIndex: Int) -> Int? {
        guard book.songs.indices.contains(songIndex),
              book.songs[songIndex].parts.indices.contains(partIndex) else { return nil }
        let copy = book.songs[songIndex].parts[partIndex]
        return insertPart(copy, inSongAt: songIndex, at: partIndex + 1)
    }

    @discardableResult
    public func movePart(at partIndex: Int, inSongAt songIndex: Int, by delta: Int) -> Int? {
        guard book.songs.indices.contains(songIndex) else { return nil }
        let target = partIndex + delta
        guard book.songs[songIndex].parts.indices.contains(partIndex),
              book.songs[songIndex].parts.indices.contains(target) else { return nil }
        book.songs[songIndex].parts.swapAt(partIndex, target)
        renumberParts(in: songIndex)
        touch()
        return target
    }

    public func updatePart(at partIndex: Int, inSongAt songIndex: Int, _ mutate: (inout SongPart) -> Void) {
        guard book.songs.indices.contains(songIndex),
              book.songs[songIndex].parts.indices.contains(partIndex) else { return }
        mutate(&book.songs[songIndex].parts[partIndex])
        book.songs[songIndex].parts[partIndex].index = partIndex
        touch()
    }

    /// Кнопки (9)–(12).
    public func setAlign(_ align: SongPartAlign, forPartAt partIndex: Int, inSongAt songIndex: Int) {
        updatePart(at: partIndex, inSongAt: songIndex) { $0.align = align }
    }

    /// Кнопка (13) — меню форматування тексту виділеної частини пісні.
    public func format(_ style: SongTextFormat, partAt partIndex: Int, inSongAt songIndex: Int) {
        updatePart(at: partIndex, inSongAt: songIndex) {
            $0.text = SongTextFormatter.apply(style, to: $0.text)
        }
    }

    /// Кнопка (14) — скасування форматування виділеної частини пісні.
    public func unformat(partAt partIndex: Int, inSongAt songIndex: Int) {
        updatePart(at: partIndex, inSongAt: songIndex) {
            $0.text = SongTextFormatter.unformat($0.text)
        }
    }

    /// «Форматувати пісню» — одразу всі частини вибраної пісні.
    public func format(_ style: SongTextFormat, songAt songIndex: Int) {
        guard book.songs.indices.contains(songIndex) else { return }
        for position in book.songs[songIndex].parts.indices {
            book.songs[songIndex].parts[position].text =
                SongTextFormatter.apply(style, to: book.songs[songIndex].parts[position].text)
        }
        touch()
    }

    public func unformat(songAt songIndex: Int) {
        guard book.songs.indices.contains(songIndex) else { return }
        for position in book.songs[songIndex].parts.indices {
            book.songs[songIndex].parts[position].text =
                SongTextFormatter.unformat(book.songs[songIndex].parts[position].text)
        }
        touch()
    }

    /// «Форматування ВСІХ пісень». Оригінал попереджає, що це надовго.
    public func formatAllSongs(_ style: SongTextFormat) {
        for song in book.songs.indices { format(style, songAt: song) }
    }

    public func unformatAllSongs() {
        for song in book.songs.indices { unformat(songAt: song) }
    }

    // MARK: - Дублювання приспіву (контекстне меню пісні і групи)

    /// «Дублювати приспів» — додає після кожного куплета копію приспіву.
    /// `marker` — «рядок-ознака приспіву» з варіанта «за ознакою»: частина
    /// тексту, за якою приспів упізнають, коли він не підписаний як приспів.
    @discardableResult
    public func duplicateRefrain(inSongAt songIndex: Int,
                                 marker: String? = nil,
                                 palette: SongChunkPalette = .factoryDefault) -> Int {
        guard book.songs.indices.contains(songIndex) else { return 0 }
        let parts = book.songs[songIndex].parts
        guard let refrainIndex = Self.refrainIndex(in: parts, marker: marker, palette: palette) else { return 0 }
        let refrain = parts[refrainIndex]

        var rebuilt: [SongPart] = []
        var inserted = 0
        for (position, part) in parts.enumerated() {
            rebuilt.append(part)
            guard Self.isVerse(part, palette: palette) else { continue }
            // Якщо приспів і так стоїть наступним, другий примірник не потрібен.
            let next = position + 1
            if next < parts.count, Self.isSameRefrain(parts[next], refrain) { continue }
            rebuilt.append(refrain)
            inserted += 1
        }
        guard inserted > 0 else { return 0 }

        book.songs[songIndex].parts = rebuilt
        renumberParts(in: songIndex)
        touch()
        return inserted
    }

    /// «Дублювати приспіви в УСІХ піснях!»
    @discardableResult
    public func duplicateRefrainsInAllSongs(marker: String? = nil,
                                            palette: SongChunkPalette = .factoryDefault) -> Int {
        var total = 0
        for song in book.songs.indices {
            total += duplicateRefrain(inSongAt: song, marker: marker, palette: palette)
        }
        return total
    }

    static func refrainIndex(in parts: [SongPart], marker: String?,
                             palette: SongChunkPalette) -> Int? {
        if let marker, !marker.trimmingCharacters(in: .whitespaces).isEmpty {
            let needle = SongLibrary.fold(marker)
            return parts.firstIndex { SongLibrary.fold($0.text).contains(needle) }
                ?? parts.firstIndex { SongLibrary.fold($0.kind).contains(needle) }
        }
        return parts.firstIndex { palette.chunk(for: $0.kind)?.key == "Chorus" }
    }

    static func isVerse(_ part: SongPart, palette: SongChunkPalette) -> Bool {
        palette.chunk(for: part.kind)?.key == "Verse"
    }

    static func isSameRefrain(_ part: SongPart, _ refrain: SongPart) -> Bool {
        part.kind == refrain.kind && part.text == refrain.text
    }

    // MARK: - Копіювання пісень в інший Пісенник (5.3.8.2)

    /// Що робити, якщо пісня з такою назвою вже є в приймальному збірнику:
    /// оригінал питає «Песня "%s" уже существует… Перезаписать?».
    public enum CopyConflict: Sendable {
        case overwrite
        case skip
        case append
    }

    /// Копіює вибрані пісні в інший Пісенник і зберігає його.
    /// Повертає, скільки пісень додано і скільки перезаписано.
    @discardableResult
    public static func copySongs(_ indices: [Int],
                                 from source: SongBook,
                                 into destination: inout SongBook,
                                 resolve: (Song) -> CopyConflict) -> (added: Int, overwritten: Int) {
        var added = 0, overwritten = 0
        for index in indices.sorted() {
            guard source.songs.indices.contains(index) else { continue }
            var song = source.songs[index]

            if let existing = destination.songs.firstIndex(where: {
                $0.title.compare(song.title, options: [.caseInsensitive]) == .orderedSame
            }) {
                switch resolve(song) {
                case .skip: continue
                case .overwrite:
                    song.index = existing
                    destination.songs[existing] = song
                    overwritten += 1
                    continue
                case .append: break
                }
            }
            song.index = destination.songs.count
            destination.songs.append(song)
            added += 1
        }
        for position in destination.songs.indices { destination.songs[position].index = position }
        return (added, overwritten)
    }

    // MARK: - Внутрішнє

    /// Індекси — це і є порядок пісень, тому після будь-якої перестановки
    /// їх треба переписати: `Song.index` служить і розпізнавачем рядка списку.
    private func renumberSongs() {
        for position in book.songs.indices {
            book.songs[position].index = position
            renumberParts(in: position)
        }
    }

    private func renumberParts(in songIndex: Int) {
        guard book.songs.indices.contains(songIndex) else { return }
        for position in book.songs[songIndex].parts.indices {
            book.songs[songIndex].parts[position].index = position
        }
    }

    private func remapGroups(_ transform: (Int) -> Int) {
        for position in book.groups.indices {
            let mapped = book.groups[position].songIndices.map(transform)
            book.groups[position].songIndices = Array(Set(mapped)).sorted()
        }
    }

    /// «Назва (2)» — як оригінал іменує дублікат групи або пісні.
    static func copyName(of name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var counter = 2
        while taken.contains("\(name) (\(counter))") { counter += 1 }
        return "\(name) (\(counter))"
    }
}
