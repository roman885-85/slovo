import Foundation

// MARK: - Розмітка тексту пісні

/// Текст пісні цілком, як його набирають у вікні «Редагування атрибутів
/// пісні» (посібник, 5.3.9.6).
///
/// Правила звідти дослівно: «Части песни программа определяет по наличию
/// символу „#“ в начале строки, или ключевым словам… текст после символа „#“
/// считается названием этой части песни… Название параметра всегда начинается
/// и заканчивается символом „$“, а после него идёт символ „=“».
///
///     #Куплет
///     $Align$=Left
///     Рядок перший
///     Рядок другий
///
/// Ключові слова беремо не зі свого списку, а з палітри `[SongChunksColors]`:
/// это единственное место, где записано, что «Припев», «Приспів» и «Refrain» —
/// одне й те саме.
public enum SongTextMarkup {

    public static let partMarker: Character = "#"
    public static let alignKey = "$Align$"

    /// Розібрати суцільний текст пісні на частини.
    public static func parts(from text: String,
                             palette: SongChunkPalette = .factoryDefault) -> [SongPart] {
        let lines = normalizedLines(text)
        let headings = headingNames(palette)

        var parts: [SongPart] = []
        var kind = ""
        var align = SongPartAlign.default
        var buffer: [String] = []
        var opened = false

        func flush() {
            // Текст частини зберігаємо як є, аж до порожніх рядків по
            // краях: у пісенниках вони стоять навмисно і дають відступ на
            // слайді. Відкидаємо лише порожній «хвіст» перед першим «#» —
            // він не частина пісні, а роздільник.
            let body = opened ? buffer : trimBlankEdges(buffer)
            guard opened || !body.isEmpty else { return }
            parts.append(SongPart(index: parts.count, kind: kind,
                                  text: body.joined(separator: "\r\n"), align: align))
            kind = ""
            align = .default
            buffer = []
            opened = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix(String(partMarker)) {
                flush()
                // Назва частини — усе, що після «#», без обрізання: у
                // збірниках трапляються «Verse » і «Куплет 1. » з пробілом
                // на кінці, і обмін не має їх міняти.
                kind = String(line.dropFirst())
                opened = true
                continue
            }
            // «Части песни программа определяет по наличию символу „#“ в
            // начале строки, ИЛИ ключевым словам» (5.3.9.6) — тобто обидві
            // ознаки працюють в одному тексті. Хибних спрацьовувань це не
            // дає: `isHeading` порівнює рядок цілком, тому «Мостом
            // шли» ключовим словом не стане, а стане ним лише рядок,
            // який і є «Мост» або «Куплет 2».
            if isHeading(trimmed, in: headings) {
                flush()
                kind = trimmed
                opened = true
                continue
            }
            if let value = parameter(alignKey, in: trimmed) {
                align = SongPartAlign(exportName: value) ?? .default
                continue
            }
            buffer.append(line)
        }
        flush()
        return parts
    }

    /// Зібрати текст назад — те, що видно в полі «Текст пісні».
    ///
    /// Між частинами порожній рядок не вставляється: він був би невідрізненним від
    /// порожнього рядка, яким закінчується сам текст частини, і обмін перестав
    /// би бути точним. Розділяє частини символ «#», і цього досить.
    public static func text(of parts: [SongPart]) -> String {
        lines(of: parts).joined(separator: "\r\n")
    }

    /// Ті самі рядки, але окремо — так їх зручно вкладати в
    /// текстовий файл цілого Пісенника.
    static func lines(of parts: [SongPart]) -> [String] {
        var result: [String] = []
        for part in parts {
            result.append("\(partMarker)\(part.kind)")
            if let name = part.align.exportName { result.append("\(alignKey)=\(name)") }
            if !part.text.isEmpty { result.append(contentsOf: normalizedLines(part.text)) }
        }
        return result
    }

    // MARK: - Внутрішнє

    static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func trimBlankEdges(_ lines: [String]) -> [String] {
        var result = lines
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty { result.removeFirst() }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        return result
    }

    /// `$Align$=Left` → `Left`. Регістр ключа не важливий: у файлі пісенника він
    /// написаний великими, а в текстовому експорті — мішаним.
    static func parameter(_ key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<eq])
        guard name.compare(key, options: .caseInsensitive) == .orderedSame else { return nil }
        return String(trimmed[trimmed.index(after: eq)...])
    }

    static func headingNames(_ palette: SongChunkPalette) -> Set<String> {
        var names = Set<String>()
        for chunk in palette.chunks {
            names.insert(SongChunkPalette.normalize(chunk.key))
            for name in chunk.names { names.insert(SongChunkPalette.normalize(name)) }
        }
        names.remove("")
        return names
    }

    /// Рядок — це заголовок частини, якщо він короткий і цілком складається з
    /// ключового слова з номером: «Припев», «Куплет 2», «Verse 3.».
    public static func isHeading(_ line: String, in names: Set<String>) -> Bool {
        guard !line.isEmpty, line.count <= 32 else { return false }
        return names.contains(SongChunkPalette.normalize(line))
    }

    // MARK: - Розмітка для розфарбовування поля «Текст пісні» (5.3.9.6)

    /// Чим рядок є для розбору. Рівно це й фарбує вікно правки пісні:
    /// «если это ключевое слово, то программа его окрашивает в цвет,
    /// указанный в настройках».
    public enum Role: Sendable, Hashable {
        case body                              // звичайний рядок тексту
        case heading                           // «#Своя назва» — не ключове слово
        case keywordHeading(SlideStyle.RGBA)   // ключове слово і його колір з палітри
        case parameter                         // «$Align$=Left»
    }

    /// Рядок тексту пісні і його місце в ньому. Зсуви — в одиницях UTF-16,
    /// бо їх чекає `NSTextStorage`, якому ця розмітка і потрібна.
    public struct Line: Sendable, Hashable {
        public let start: Int
        public let length: Int
        public let role: Role

        public init(start: Int, length: Int, role: Role) {
            self.start = start
            self.length = length
            self.role = role
        }
    }

    /// Розібрати текст на рядки з їхніми ролями — тим самим правилом, що й
    /// `parts(from:)`. Спільне правило важливіше за спільну функцію: якщо розфарбовування
    /// почне розходитися з розбором, воно обманюватиме оператора.
    public static func markup(of text: String, palette: SongChunkPalette) -> [Line] {
        let source = text as NSString
        let headings = headingNames(palette)
        var result: [Line] = []
        var index = 0

        while index < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: index, length: 0))
            let length = contentsEnd - index
            defer { index = lineEnd > index ? lineEnd : index + 1 }
            guard length > 0 else { continue }

            let line = source.substring(with: NSRange(location: index, length: length))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let role: Role

            if line.hasPrefix(String(partMarker)) {
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                role = palette.chunk(for: name).map { .keywordHeading($0.color) } ?? .heading
            } else if isHeading(trimmed, in: headings) {
                role = palette.chunk(for: trimmed).map { .keywordHeading($0.color) } ?? .heading
            } else if isParameter(trimmed) {
                role = .parameter
            } else {
                role = .body
            }
            if role != .body { result.append(Line(start: index, length: length, role: role)) }
        }
        return result
    }

    /// Рядок виду «$Ключ$=значення»: «Название параметра всегда начинается и
    /// заканчивается символом „$“, а после него идёт символ „=“» (5.3.9.6).
    static func isParameter(_ line: String) -> Bool {
        guard line.hasPrefix("$"), let eq = line.firstIndex(of: "=") else { return false }
        return line[line.startIndex..<eq].hasSuffix("$") && line[line.startIndex..<eq].count > 2
    }
}

// MARK: - Експорт та імпорт текстового файла

/// Експорт Пісенника в текстовий файл та імпорт із нього (посібник, 5.3.8.4).
///
/// Службові позначки взято з самої програми — в її коді лежать рівно ці
/// рядки: `$AltTitle$=`, `$Poet$=`, `$Composer$=`, `$DateCreate$=`, `$Tune$=`,
/// `$ID$=`, `$Note$=`, `#` для частини, `$Align$=Left|Right|Center` і `---` як
/// ознака початку пісні. Порядок такий самий, як порядок полів у самому файлі
/// пісенника, тому обмін виходить без втрат.
public enum SongBookTextFile {

    /// Який номер друкувати у варіанті «без службової інформації»:
    /// посібник дозволяє «номер песен по порядку, или номер в Песеннике».
    public enum Numbering: String, Sendable, CaseIterable, Identifiable {
        case ordinal      // порядковий номер
        case catalog      // «Номер у збірнику» ($ID$)
        public var id: String { rawValue }
    }

    public enum ImportMode: String, Sendable, CaseIterable, Identifiable {
        case append       // «Додати пісні з текстового файла в кінець»
        case replace      // «Видалити всі пісні… і завантажити з текстового файла»
        public var id: String { rawValue }
    }

    public static let songSeparator = "---"

    // MARK: Експорт

    /// «Разом зі службовою інформацією» — режим для перенесення на інший
    /// комп'ютер: відновлюється все, крім груп.
    public static func exportWithServiceInfo(_ book: SongBook) -> String {
        var out = ""
        for song in book.songs {
            // Жодного зайвого рядка: усе, що стоїть між «---» і наступним
            // «---», належить пісні. Інакше порожні рядки в кінці останньої
            // частини не можна було б відрізнити від відступу між піснями.
            var lines = [songSeparator, song.title]
            append(&lines, "$AltTitle$", song.alternateTitle)
            append(&lines, "$Poet$", song.author)
            append(&lines, "$Composer$", song.composer)
            append(&lines, "$DateCreate$", song.note)
            append(&lines, "$Tune$", song.tune)
            append(&lines, "$ID$", song.catalogNumberText)
            lines.append(contentsOf: SongTextMarkup.lines(of: song.parts))
            out += lines.joined(separator: "\r\n") + "\r\n"
        }
        return out
    }

    /// «Без службової інформації» — лише назви і тексти, «подходит для
    /// дальнейшей обработки для печати, или просто чтения».
    public static func exportPlain(_ book: SongBook, numbering: Numbering = .ordinal) -> String {
        var out = ""
        for song in book.songs {
            let number: String
            switch numbering {
            case .ordinal: number = String(song.number)
            case .catalog: number = song.catalogNumberText.isEmpty ? String(song.number) : song.catalogNumberText
            }
            out += "\(number). \(song.title)\r\n\r\n"
            for part in song.parts {
                let body = part.text.replacingOccurrences(of: "\r\n", with: "\n")
                out += body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
            }
        }
        return out
    }

    public static func write(_ text: String, to url: URL) throws {
        // UTF-8 з міткою порядку байтів: так текст відкриється і в Блокноті
        // Windows, куди його найчастіше й відносять.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: url, options: .atomic)
    }

    private static func append(_ lines: inout [String], _ key: String, _ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lines.append("\(key)=\(clean)")
    }

    // MARK: Імпорт

    /// Розібрати текстовий файл на пісні. Ознака початку пісні — рядок із
    /// дефісів; усе до першого такого рядка пропускається.
    public static func songs(from text: String,
                             palette: SongChunkPalette = .factoryDefault) -> [Song] {
        var lines = SongTextMarkup.normalizedLines(stripBOM(text))
        // Файл закінчується переносом рядка, і розбиття дає зайвий порожній
        // елемент у хвості. Він не порожній рядок пісні, а кінець файла.
        if lines.last?.isEmpty == true { lines.removeLast() }

        var blocks: [[String]] = []
        var current: [String]?

        for line in lines {
            if isSeparator(line) {
                if let block = current { blocks.append(block) }
                current = []
                continue
            }
            current?.append(line)
        }
        if let block = current { blocks.append(block) }

        // Порожній блок — це теж пісня: у збірниках користувача є пісні
        // без назви і без частин (п'ять таких у `glory.vbm`), і губити їх
        // при перенесенні не можна, інакше поїдуть усі номери.
        return blocks.enumerated().map { index, block in
            song(from: block, index: index, palette: palette)
        }
    }

    /// Улити пісні в Пісенник. Повертає, скільки пісень додано.
    @discardableResult
    public static func importSongs(from text: String, into book: inout SongBook,
                                   mode: ImportMode,
                                   palette: SongChunkPalette = .factoryDefault) -> Int {
        let incoming = songs(from: text, palette: palette)
        guard !incoming.isEmpty else { return 0 }

        switch mode {
        case .append:
            book.songs.append(contentsOf: incoming)
        case .replace:
            book.songs = incoming
            // Групи тримають номери пісень; після повної заміни ці номери
            // вказують у порожнечу, тому склад груп очищаємо, а самі
            // групи лишаємо — їх користувач налаштовував руками.
            for position in book.groups.indices { book.groups[position].songIndices = [] }
        }
        for position in book.songs.indices { book.songs[position].index = position }
        return incoming.count
    }

    /// Ознака початку пісні — рівно три дефіси і нічого більше.
    ///
    /// Перевіряти «рядок із дефісів» не можна: у `sion.vbm` усередині пісні
    /// «O schimbare în viața» є рядок `----`, і за несуворим правилом
    /// пісня розвалювалася надвоє.
    static func isSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == songSeparator
    }

    static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func song(from block: [String], index: Int,
                             palette: SongChunkPalette) -> Song {
        // Перший рядок блоку — назва пісні, і вона буває порожньою (п'ять
        // таких пісень у `glory.vbm`). Порожні рядки зверху зрізати не можна:
        // ми прийняли б за назву перший рядок тексту.
        //
        // Назву пишемо як є: у «lieder von liederbuch.vbm» у пісень
        // початковий пробіл, і обмін не має його з'їдати.
        var lines = block
        let title = lines.isEmpty ? "" : lines.removeFirst()
        var song = Song(index: index, title: title)

        // Атрибути йдуть одразу за назвою і кінчаються на першому рядку,
        // який не «$Ключ$=значення». Усе інше — текст пісні.
        var body: [String] = []
        var inAttributes = true

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inAttributes, trimmed.isEmpty { continue }
            if inAttributes, let pair = attribute(trimmed) {
                apply(pair, to: &song)
                continue
            }
            inAttributes = false
            body.append(line)
        }

        song.parts = SongTextMarkup.parts(from: body.joined(separator: "\n"), palette: palette)
        for position in song.parts.indices { song.parts[position].index = position }
        return song
    }

    private static func attribute(_ line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("$"), let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<eq]).lowercased()
        // `$Align$` стосується частини пісні, а не самої пісні: він не має
        // проковтуватися розбором атрибутів, інакше перша частина втратить
        // вирівнювання.
        guard key != "$align$" else { return nil }
        return (key, String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func apply(_ pair: (key: String, value: String), to song: inout Song) {
        switch pair.key {
        case "$alttitle$":              song.alternateTitle = pair.value
        case "$poet$", "$author$":      song.author = pair.value
        case "$composer$":              song.composer = pair.value
        // П'яте поле файла пісенника — це дата: в усіх збірниках
        // користувача в ньому стоїть «03.12.2013» і подібне. Старе ім'я
        // `$Note$` приймаємо теж, щоб читалися чужі вивантаження.
        case "$datecreate$", "$note$":  song.note = pair.value
        case "$tune$":                  song.setProperty("$TUNE$", pair.value)
        case "$id$":                    song.setProperty("$ID$", pair.value)
        default:                        song.setProperty(pair.key.uppercased(), pair.value)
        }
    }
}
