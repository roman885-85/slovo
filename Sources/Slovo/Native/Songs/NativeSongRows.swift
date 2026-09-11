import AppKit
import SlovoCore

// MARK: - Група (26)

/// Групи пісень. Перший рядок — псевдогрупа «Усі пісні» (5.3.1), у неї
/// номера немає; далі йдуть групи збірника з числом пісень у кожній.
@MainActor
final class NativeSongGroupRows: NativeListSource {

    private var names: [String] = []
    private var counts: [String] = []

    /// Кому йдуть пункти меню правої кнопки.
    weak var owner: NativeSongsWorkspace?

    var rowCount: Int { names.count }

    func row(at index: Int) -> NativeRow {
        NativeRow(text: names[index], detail: counts[index], singleLine: true,
                  tooltip: names[index])
    }

    /// `titles` приходить готовим: перший рядок підписує файл перекладу
    /// (`SongsPluginFrame->TextMessages4`), і складати його тут удруге
    /// означало б завести другий перелік тих самих підписів.
    func reload(titles: [String], groups: [SongGroup]) {
        names = titles
        counts = [""] + groups.map { String($0.songIndices.count) }
        // Підписів завжди на один більше, ніж груп, але збірник могли
        // поправити між двома викликами — підріжемо по короткому.
        if counts.count > names.count { counts.removeLast(counts.count - names.count) }
        while counts.count < names.count { counts.append("") }
    }

    func menu(at index: Int) -> NSMenu? { owner?.groupMenu(at: index) }
}

// MARK: - Пісня (27)

/// Пісні відкритого збірника, відібрані групою і швидким вибором.
///
/// Список тримає лише розбір (`NativeSongIndex`) і перелік показаних
/// номерів. Значення `Song` сюди не потрапляють зовсім: рядок збирається з двох
/// готових рядків у ту мить, коли його треба намалювати, — а малюють два десятки
/// рядків, скільки б їх не було у збірнику.
@MainActor
final class NativeSongRows: NativeListSource {

    private let index: NativeSongIndex
    /// Показані номери пісень. `nil` — показано всі.
    private(set) var filter: [Int]?

    /// Вигляд номера в назві пісні — налаштування (20) вкладки «Слайд».
    var titleFormat = SongTitleFormat()
    /// «Показати номер у збірнику» замість «номера по порядку».
    var showsCatalogNumber = false

    weak var owner: NativeSongsWorkspace?

    init(index: NativeSongIndex) {
        self.index = index
    }

    var rowCount: Int { filter?.count ?? index.count }

    /// Номер пісні у збірнику за рядком списку. Відбір міняється, пісня — ні,
    /// тому назовні завжди ходить саме він.
    func song(at row: Int) -> Int? {
        if let filter {
            guard filter.indices.contains(row) else { return nil }
            return filter[row]
        }
        return row < index.count ? row : nil
    }

    /// Де в списку стоїть ця пісня. Відбір її викинув — `nil`.
    func position(ofSong song: Int) -> Int? {
        guard let filter else { return song < index.count ? song : nil }
        return filter.firstIndex(of: song)
    }

    func row(at row: Int) -> NativeRow {
        guard let song = song(at: row) else { return NativeRow() }
        return NativeRow(lead: lead(of: song), text: index.titles[song],
                         detail: index.subtitles[song], singleLine: true)
    }

    /// Номер у вузькій колонці зліва. Без номера (налаштування «Номер пісні в
    /// збірнику» вимкнено) колонки немає зовсім.
    private func lead(of song: Int) -> String {
        guard titleFormat.showsNumber else { return "" }
        let number = showsCatalogNumber
            ? (index.catalogNumbers.indices.contains(song)
                ? (index.catalogNumbers[song] ?? song + 1) : song + 1)
            : song + 1
        return titleFormat.number(number)
    }

    func setFilter(_ new: [Int]?) { filter = new }

    func menu(at index: Int) -> NSMenu? {
        guard let song = song(at: index) else { return nil }
        return owner?.songMenu(song: song)
    }
}

// MARK: - Текст (28)

/// Частини вибраної пісні.
///
/// Частин у пісні десяток, і все одно рядки готуються заздалегідь, на зміну
/// пісні: текст частини доводиться підрізати до восьми рядків і прибирати порожні
/// по краях, а робити це на кожне малювання значить платити за одне й те саме
/// по двадцять разів на секунду.
@MainActor
final class NativeSongPartRows: NativeListSource {

    private var kinds: [String] = []
    private var texts: [String] = []
    private var tints: [NSColor] = []
    private var fills: [NSColor] = []
    /// Номери частин (`SongPart.index`): у першої частини він буває і нулем,
    /// і одиницею, тому місце в списку і номер частини — не одне й те саме.
    private(set) var numbers: [Int] = []

    weak var owner: NativeSongsWorkspace?

    var rowCount: Int { texts.count }

    /// «Текст в одну лінію» з меню «Інтерфейс» (21). У `VisioBible.ini` це
    /// `LinesStyle` розділу `[Songs]`, і в автора там стоїть одиниця: список
    /// частин у пісеннику за умовчанням однорядковий.
    var singleLine = false

    /// «Текст в одну лінію» тут означає не «показати перший рядок», а
    /// «зібрати частину в один абзац»: в автора куплет так і стоїть — рядки
    /// пісні склеєні в суцільний текст і перенесені по ширині стовпця, цілком.
    /// Поки сюди потрапляв лише перший рядок, куплет було не прочитати, і
    /// список частин утрачав сенс: по ньому й знаходять потрібне місце.
    func row(at index: Int) -> NativeRow {
        let text = singleLine
            ? texts[index].split(separator: "\n").joined(separator: " ")
            : texts[index]
        return NativeRow(lead: kinds[index], text: text,
                         leadColor: tints[index], fill: fills[index],
                         singleLine: false)
    }

    /// Місце в списку за номером частини.
    func position(ofPart number: Int) -> Int? { numbers.firstIndex(of: number) }

    func reload(song: Song?, palette: SongChunkPalette) {
        kinds.removeAll(keepingCapacity: true)
        texts.removeAll(keepingCapacity: true)
        tints.removeAll(keepingCapacity: true)
        fills.removeAll(keepingCapacity: true)
        numbers.removeAll(keepingCapacity: true)
        guard let song else { return }
        for part in song.parts {
            let chunk = palette.chunk(for: part.kind)
            let tint = chunk.map {
                NSColor(calibratedRed: CGFloat($0.color.red), green: CGFloat($0.color.green),
                        blue: CGFloat($0.color.blue), alpha: 1)
            } ?? NSColor.secondaryLabelColor
            var title = part.kind.isEmpty ? (chunk?.title ?? "") : part.kind
            if title.isEmpty { title = OurWords.t("Часть %s", "\(part.index + 1)") }
            if part.align != .default, let name = part.align.exportName {
                // Вирівнювання задається кнопками (9)–(12) і в тексті не видно —
                // без позначки оператор про нього не дізнається.
                title += " · " + name
            }
            kinds.append(title)
            texts.append(Self.preview(part))
            tints.append(tint)
            // В автора вид частини позначено кольоровою смужкою зліва. Смужки в
            // рядка списку немає, а колір частини потрібен: приспів знаходять за кольором
            // швидше, ніж читають підпис. Тому кольором фарбується сама
            // підкладка рядка — блідо, щоб текст лишився читабельним.
            fills.append(tint.withAlphaComponent(0.12))
            numbers.append(part.index)
        }
    }

    /// Текст частини цілком, без порожніх рядків по краях.
    ///
    /// Раніше тут стояла відсічка у вісім рядків. На довгому куплеті вона
    /// з'їдала кінець, а за цим списком оператор саме читає — ним і знаходить
    /// потрібне місце в пісні. Висоту рядка список рахує за текстом сам,
    /// тому довга частина просто займає більше місця.
    private static func preview(_ part: SongPart) -> String {
        var lines = part.lines.map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    func menu(at index: Int) -> NSMenu? {
        guard numbers.indices.contains(index) else { return nil }
        return owner?.partMenu(number: numbers[index])
    }
}

// MARK: - Метрики трьох списків

extension NativeListMetrics {

    /// Групи: назва і число пісень правою колонкою.
    static let songGroups: NativeListMetrics = {
        var m = NativeListMetrics()
        m.detailWidth = 34
        m.padding = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
        m.textFontDelta = 0
        return m
    }()

    /// Частини пісні: підпис частини зліва своїм кольором, текст справа.
    static let songParts: NativeListMetrics = {
        var m = NativeListMetrics()
        m.leadWidth = 92
        m.leadAlign = .left
        m.leadFontDelta = -1
        m.padding = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        m.textFontDelta = -1
        return m
    }()
}
