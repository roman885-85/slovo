import Foundation

/// Слайд пісні: сам слайд плюс те, звідки він узявся, — яка частина, яка
/// сторінка всередині частини і якого вона типу. Без цього список слайдів не
/// розфарбувати і не підсвітити в ньому поточний рядок.
public struct SongSlide: Sendable, Hashable, Identifiable {
    public let partIndex: Int
    public let pageIndex: Int
    public let pageCount: Int
    public let partKind: String
    public let chunkKey: String?
    public let color: SlideStyle.RGBA?
    public let slide: Slide

    public var id: String { "\(partIndex).\(pageIndex)" }
    public var isSinglePage: Bool { pageCount == 1 }
}

/// Перетворення частин пісні на слайди.
///
/// Головна відмінність від біблійного тексту: у пісні перенос рядка значущий.
/// Вірш можна склеїти в абзац і дати проектору перенести його самому, а куплет
/// так ламати не можна — рядки мають стояти там, де їх поставив автор.
/// Тому тут рядок — одиниця розбиття, а не слово.
public struct SongSlideComposer: Sendable {

    public struct Options: Sendable, Hashable {
        /// Ділити довгу частину на кілька слайдів. В оригіналі це
        /// `VersSubDivide` у `[Songs]`; у користувача вимкнено — куплет
        /// цілком іде на один слайд, а розмір шрифту добирається.
        public var splitsLongParts: Bool

        /// По скільки рядків на слайд, коли поділ увімкнено.
        public var linesPerPage: Int

        /// Порожній рядок усередині частини — це розрив, який поставив
        /// укладач збірника. Таких частин небагато (176 на 161 226), але
        /// склеювати через них дві строфи неправильно.
        public var blankLineBreaksPage: Bool

        /// Назва частини («Куплет 1», «Приспів») в адресі слайда.
        public var showsPartName: Bool

        /// Номер пісні в адресі. В оригіналі — `SongNameWithNumPP`.
        public var showsNumber: Bool
        public var showsTitle: Bool

        /// Коротке ім'я збірника в адресі, як `ModuleShortName` у Біблії.
        public var showsBookShortName: Bool

        /// Що дописати в кінець останньої частини пісні. В оригіналі —
        /// `SongsEndChunkPostText`, у користувача це `***`.
        public var endMarker: String

        /// Номер сторінки («2/3»), коли частина не вмістилася на один слайд.
        public var showsPageNumber: Bool

        public init(splitsLongParts: Bool = false,
                    linesPerPage: Int = 4,
                    blankLineBreaksPage: Bool = true,
                    showsPartName: Bool = true,
                    showsNumber: Bool = false,
                    showsTitle: Bool = false,
                    showsBookShortName: Bool = false,
                    endMarker: String = "",
                    showsPageNumber: Bool = true) {
            self.splitsLongParts = splitsLongParts
            self.linesPerPage = max(1, linesPerPage)
            self.blankLineBreaksPage = blankLineBreaksPage
            self.showsPartName = showsPartName
            self.showsNumber = showsNumber
            self.showsTitle = showsTitle
            self.showsBookShortName = showsBookShortName
            self.endMarker = endMarker
            self.showsPageNumber = showsPageNumber
        }

        public init(config: IniSettings) {
            self.init(splitsLongParts: config.bool("VersSubDivide", in: "Songs") ?? false,
                      linesPerPage: 4,
                      blankLineBreaksPage: true,
                      showsPartName: true,
                      showsNumber: config.bool("SongNameWithNumPP", in: "settings") ?? false,
                      showsTitle: false,
                      showsBookShortName: false,
                      endMarker: config.string("SongsEndChunkPostText", in: "settings") ?? "",
                      showsPageNumber: true)
        }
    }

    public var options: Options
    public var palette: SongChunkPalette

    public init(options: Options = Options(), palette: SongChunkPalette = .factoryDefault) {
        self.options = options
        self.palette = palette
    }

    public init(config: IniSettings) {
        self.init(options: Options(config: config), palette: SongChunkPalette(config: config))
    }

    // MARK: - Одна частина

    /// Слайди однієї частини пісні.
    ///
    /// `isLastPart` вмикає хвостову позначку кінця пісні — її ставлять лише
    /// після останньої частини, інакше `***` з'являлося б після кожного куплета.
    public func slides(for part: SongPart,
                       of song: Song,
                       bookShortName: String = "",
                       isLastPart: Bool = false) -> [SongSlide] {
        let pages = self.pages(of: part)
        let chunk = palette.chunk(for: part.kind)
        guard !pages.isEmpty else {
            return [SongSlide(partIndex: part.index, pageIndex: 0, pageCount: 1,
                              partKind: part.kind, chunkKey: chunk?.key, color: chunk?.color,
                              slide: Slide(mainText: "",
                                           reference: reference(part: part, song: song,
                                                                bookShortName: bookShortName,
                                                                page: 0, of: 1),
                                           isBlank: true))]
        }

        return pages.enumerated().map { pageIndex, lines in
            var text = lines.joined(separator: "\n")
            if isLastPart, pageIndex == pages.count - 1, !options.endMarker.isEmpty {
                text += "\n" + options.endMarker
            }
            let slide = Slide(mainText: text,
                              reference: reference(part: part, song: song,
                                                   bookShortName: bookShortName,
                                                   page: pageIndex, of: pages.count))
            return SongSlide(partIndex: part.index, pageIndex: pageIndex, pageCount: pages.count,
                             partKind: part.kind, chunkKey: chunk?.key, color: chunk?.color,
                             slide: slide)
        }
    }

    /// Усі слайди пісні підряд — у тому порядку, в якому частини лежать у файлі.
    public func slides(for song: Song, bookShortName: String = "") -> [SongSlide] {
        song.parts.enumerated().flatMap { position, part in
            slides(for: part, of: song, bookShortName: bookShortName,
                   isLastPart: position == song.parts.count - 1)
        }
    }

    /// Слайди однієї частини за її номером — те, що потрібно обробнику
    /// «частину вибрано» у списку.
    public func slides(forPartAt index: Int, of song: Song, bookShortName: String = "") -> [SongSlide] {
        guard song.parts.indices.contains(index) else { return [] }
        return slides(for: song.parts[index], of: song, bookShortName: bookShortName,
                      isLastPart: index == song.parts.count - 1)
    }

    // MARK: - Розбиття на сторінки

    /// Рядки частини, розкладені по слайдах.
    ///
    /// Порожні рядки по краях частини у файлах трапляються майже завжди —
    /// це залишок роздільника, а не порожній рядок на екрані.
    public func pages(of part: SongPart) -> [[String]] {
        var lines = part.lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return [] }

        // Спершу жорсткі розриви — порожні рядки всередині частини.
        var blocks: [[String]] = [[]]
        for line in lines {
            if options.blankLineBreaksPage, line.isEmpty {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        blocks.removeAll { $0.isEmpty }
        guard options.splitsLongParts else { return blocks }

        // Потім — поділ довгих блоків на рівні сторінки. Хвіст в один
        // рядок виглядає сиротою, тому сторінки вирівнюємо за числом.
        return blocks.flatMap { block -> [[String]] in
            guard block.count > options.linesPerPage else { return [block] }
            let pageCount = Int((Double(block.count) / Double(options.linesPerPage)).rounded(.up))
            let perPage = Int((Double(block.count) / Double(pageCount)).rounded(.up))
            return stride(from: 0, to: block.count, by: perPage).map {
                Array(block[$0..<min($0 + perPage, block.count)])
            }
        }
    }

    // MARK: - Адреса слайда

    /// Адреса пісенного слайда. Назва частини тут обов'язкова: в оригіналі
    /// зал бачить саме «Куплет 2», і за ним же оператор розуміє, де він.
    public func reference(part: SongPart, song: Song, bookShortName: String,
                          page: Int, of pageCount: Int) -> String {
        var pieces: [String] = []

        if options.showsNumber || options.showsTitle {
            var head = ""
            if options.showsNumber { head = "\(song.number)." }
            if options.showsTitle { head = head.isEmpty ? song.title : head + " " + song.title }
            if !head.isEmpty { pieces.append(head) }
        }
        if options.showsPartName, !part.kind.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(part.kind.trimmingCharacters(in: .whitespaces))
        }
        if options.showsPageNumber, pageCount > 1 {
            pieces.append("\(page + 1)/\(pageCount)")
        }
        if options.showsBookShortName, !bookShortName.isEmpty {
            pieces.append(bookShortName)
        }
        return pieces.joined(separator: " · ")
    }
}
