import AppKit
import SlovoCore

/// Вікна правки Пісенника — на AppKit.
///
/// Чотири форми автора: атрибути Пісенника (`SongBookEditForm`), атрибути і
/// текст пісні (`SongEditNameForm`), частина пісні (`SongEditChunkForm`) і
/// копіювання пісень в інший Пісенник (`ImportSongsDialogForm`). Підписи
/// беруться з тих самих ключів перекладу, що й раніше.
///
/// Розкладку рахує `layout()` — у цих вікон її і всього-то: стовпець полів
/// зліва, поле тексту справа, ряд кнопок знизу.
@MainActor
enum NativeSongSheets {

    /// Спільна рамка: заголовок зверху, вміст, ряд кнопок знизу.
    class Sheet: NSView {
        let heading = NSTextField(labelWithString: "")
        var buttons: [NSButton] = []
        var onClose: (() -> Void)?

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            addSubview(heading)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        /// Кнопки ставимо в правому нижньому куті, справа наліво.
        func layoutButtons() {
            var right = bounds.width - 16
            for button in buttons.reversed() {
                let width = max(90, button.intrinsicContentSize.width + 24)
                button.frame = NSRect(x: right - width, y: bounds.height - 40, width: width, height: 24)
                right -= width + 8
            }
        }

        override func layout() {
            super.layout()
            heading.frame = NSRect(x: 16, y: 14, width: bounds.width - 32, height: 18)
            layoutButtons()
        }
    }

    // MARK: - Атрибути Пісенника (5.3.9.5)

    /// Кодування «налаштовується для всього Пісенника»; назви — ті самі, що
    /// в наборів символів Windows, з якими працює оригінал.
    static let charsets: [(UInt32, String)] = [
        (512, "UNICODE"), (1, OurWords.t("По умолчанию")), (0, "ANSI"), (204, "Кириллица"),
        (238, "Восточноевропейская"), (161, "Греческая"), (162, "Турецкая"),
        (177, "Иврит"), (186, "Балтийская"),
    ]

    final class BookAttributes: Sheet {
        private let captions: SongCaptions
        private let fields: [NSTextField]
        private let charset: NSPopUpButton
        private let warning = NSTextField(labelWithString: "")
        private let labels: [NSTextField]
        private let apply: (String, String, String, String, String, UInt32) -> Void

        init(captions: SongCaptions, editable: Bool, book: SongBook,
             apply: @escaping (String, String, String, String, String, UInt32) -> Void) {
            self.captions = captions
            self.apply = apply
            let values = [book.title, book.shortName, book.publisher, book.revisionDate, book.comment]
            fields = values.map { value in
                let field = NSTextField(string: value)
                field.font = .systemFont(ofSize: 12)
                field.isEditable = editable
                return field
            }
            charset = NSPopUpButton(frame: .zero, pullsDown: false)
            charset.addItems(withTitles: NativeSongSheets.charsets.map(\.1))
            charset.selectItem(at: NativeSongSheets.charsets.firstIndex { $0.0 == book.charset } ?? 0)
            charset.isEnabled = editable
            let titles = [captions.songForm("Label2", "Название:"),
                          captions.songForm("TextMessages6", "Коротк.назв.:"),
                          captions.songForm("TextMessages8", "Copyright:"),
                          captions.songForm("Label5", "Дата:"),
                          captions.songForm("Label6", "Заметки:"),
                          captions.songForm("Label8", "Кодировка:")]
            labels = titles.map { title in
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11)
                label.alignment = .right
                return label
            }
            super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 300))

            heading.stringValue = (editable
                ? captions.songForm("TextMessages0", "Редактирование")
                : captions.songForm("TextMessages9", "Просмотр"))
                + " " + captions.songForm("TextMessages2", "атрибутов Песенника")
            // Пряма цитата з посібника — попередження не наше.
            warning.stringValue = OurWords.t(
                "Для всех новых Песенников необходимо использовать кодировку «UNICODE».")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = .systemOrange
            warning.isHidden = !editable || book.charset == SongBook.unicodeCharset

            for label in labels { addSubview(label) }
            for field in fields { addSubview(field) }
            addSubview(charset)
            addSubview(warning)

            if editable {
                buttons = [
                    NativeForm.button(captions.songForm("BBCancel", "Отменить")) { [weak self] in
                        self?.onClose?()
                    },
                    NativeForm.button(captions.songForm("BBSave", "Ок")) { [weak self] in self?.save() },
                ]
                buttons[1].keyEquivalent = "\r"
                buttons[0].keyEquivalent = "\u{1B}"
            } else {
                buttons = [NativeForm.button(captions.songForm("BBClose", "Ок")) { [weak self] in
                    self?.onClose?()
                }]
                buttons[0].keyEquivalent = "\r"
            }
            for button in buttons { addSubview(button) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        private func save() {
            let index = charset.indexOfSelectedItem
            apply(fields[0].stringValue, fields[1].stringValue, fields[2].stringValue,
                  fields[3].stringValue, fields[4].stringValue,
                  NativeSongSheets.charsets[max(0, min(index, NativeSongSheets.charsets.count - 1))].0)
            onClose?()
        }

        override func layout() {
            super.layout()
            var top: CGFloat = 46
            for (index, field) in fields.enumerated() {
                labels[index].frame = NSRect(x: 16, y: top + 3, width: 130, height: 16)
                field.frame = NSRect(x: 154, y: top, width: bounds.width - 170, height: 22)
                top += 28
            }
            labels[5].frame = NSRect(x: 16, y: top + 3, width: 130, height: 16)
            charset.frame = NSRect(x: 154, y: top, width: 220, height: 22)
            top += 30
            warning.frame = NSRect(x: 16, y: top, width: bounds.width - 32, height: 16)
        }
    }

    // MARK: - Атрибути і текст пісні (5.3.9.6)

    /// Текст пісні тут один суцільний шматок з розміткою «#Назва частини»:
    /// саме так його набирають в оригіналі, і саме так його зручно правити
    /// цілком, не бігаючи по частинах.
    final class SongAttributes: Sheet {
        private let captions: SongCaptions
        private let palette: SongChunkPalette
        private let fields: [NSTextField]
        private let labels: [NSTextField]
        private let lyrics: NativeSongLyricsView
        private let keywords: NSPopUpButton
        private let apply: (@escaping (inout Song) -> Void) -> Void

        init(captions: SongCaptions, editable: Bool, palette: SongChunkPalette, song: Song,
             heading title: String? = nil,
             apply: @escaping (@escaping (inout Song) -> Void) -> Void) {
            self.captions = captions
            self.palette = palette
            self.apply = apply
            let values = [song.title, song.alternateTitle, song.author, song.composer,
                          song.note, song.tune, song.catalogNumberText]
            fields = values.map { value in
                let field = NSTextField(string: value)
                field.font = .systemFont(ofSize: 12)
                field.isEditable = editable
                return field
            }
            let titles = [captions.songForm("Label2", "Название:"),
                          captions.songForm("Label1", "Альтерн. название:"),
                          captions.songForm("Label4", "Слова:"),
                          captions.songForm("Label3", "Музыка:"),
                          captions.songForm("Label5", "Дата:"),
                          captions.songForm("Label7", "Тональность:"),
                          captions.songForm("LLogicNum", "Номер в сборнике:")]
            labels = titles.map { text in
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 11)
                label.alignment = .right
                return label
            }
            lyrics = NativeSongLyricsView(palette: palette, isEditable: editable)
            keywords = NSPopUpButton(frame: .zero, pullsDown: true)
            super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 480))

            heading.stringValue = title?.isEmpty == false ? title! :
                (editable ? captions.songForm("TextMessages0", "Редактирование")
                          : captions.songForm("TextMessages9", "Просмотр"))
                + " " + captions.songForm("TextMessages1", "песни")
            lyrics.text = SongTextMarkup.text(of: song.parts)
                .replacingOccurrences(of: "\r\n", with: "\n")

            // Кнопка «Вставити ключ» (PSBInsKeyWord): ключові слова частин і
            // технічні параметри виду `$Align$=Left`.
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: captions.songForm("PSBInsKeyWord", "Вставить ключ"),
                                    action: nil, keyEquivalent: ""))
            for chunk in palette.chunks {
                let item = NSMenuItem(title: chunk.title, action: #selector(insertKeyword(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = "#" + chunk.title
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for value in ["$Align$=Left", "$Align$=Center", "$Align$=Right"] {
                let item = NSMenuItem(title: value, action: #selector(insertKeyword(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value
                menu.addItem(item)
            }
            keywords.menu = menu
            keywords.isEnabled = editable

            for label in labels { addSubview(label) }
            for field in fields { addSubview(field) }
            addSubview(lyrics)
            addSubview(keywords)

            if editable {
                buttons = [
                    NativeForm.button(captions.songForm("BBCancel", "Отменить")) { [weak self] in
                        self?.onClose?()
                    },
                    NativeForm.button(captions.songForm("BBSave", "Ок")) { [weak self] in self?.save() },
                ]
                buttons[1].keyEquivalent = "\r"
                buttons[0].keyEquivalent = "\u{1B}"
            } else {
                buttons = [NativeForm.button(captions.songForm("BBClose", "Ок")) { [weak self] in
                    self?.onClose?()
                }]
                buttons[0].keyEquivalent = "\r"
            }
            for button in buttons { addSubview(button) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        @objc private func insertKeyword(_ sender: NSMenuItem) {
            guard let keyword = sender.representedObject as? String else { return }
            lyrics.insert(keyword)
        }

        private func save() {
            let parts = SongTextMarkup.parts(from: lyrics.text, palette: palette)
            let values = fields.map(\.stringValue)
            apply { song in
                song.title = values[0]
                song.alternateTitle = values[1]
                song.author = values[2]
                song.composer = values[3]
                song.note = values[4]
                song.setProperty("$TUNE$", values[5])
                song.setProperty("$ID$", values[6].isEmpty ? nil : values[6])
                song.parts = parts
            }
            onClose?()
        }

        override func layout() {
            super.layout()
            var top: CGFloat = 46
            for (index, field) in fields.enumerated() {
                labels[index].frame = NSRect(x: 16, y: top + 3, width: 140, height: 16)
                field.frame = NSRect(x: 164, y: top, width: 200, height: 22)
                top += 28
            }
            let left = 380.0
            keywords.frame = NSRect(x: bounds.width - 176, y: 44, width: 160, height: 22)
            lyrics.frame = NSRect(x: left, y: 72, width: bounds.width - left - 16,
                                  height: max(0, bounds.height - 72 - 52))
        }
    }

    // MARK: - Частина пісні (5.3.9.7)

    /// Кнопки на панелі ті самі, що й на панелі списку «Текст» у головному
    /// вікні, — так сказано в посібнику.
    final class PartSheet: Sheet {
        private let captions: SongCaptions
        private let kind = NSComboBox(frame: .zero)
        private let text = NSTextView()
        private let scroll = NSScrollView()
        private let songLine = NSTextField(labelWithString: "")
        private var alignButtons: [NSButton] = []
        private var align: SongPartAlign
        private let apply: (String, String, SongPartAlign) -> Void

        init(captions: SongCaptions, songTitle: String, part: SongPart?,
             apply: @escaping (String, String, SongPartAlign) -> Void) {
            self.captions = captions
            self.apply = apply
            align = part?.align ?? .default
            super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 460))

            heading.stringValue = part == nil ? captions.message(17, "Создание новой части")
                                              : captions.message(18, "Редактирование части")
            songLine.stringValue = captions.chunkForm("Label1", "Песня:") + "  " + songTitle
            songLine.font = .systemFont(ofSize: 12)
            songLine.lineBreakMode = .byTruncatingTail

            kind.addItems(withObjectValues: captions.chunkNames)
            kind.stringValue = part?.kind ?? captions.chunkNames.first ?? "Куплет"
            kind.font = .systemFont(ofSize: 12)

            text.string = (part?.text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            text.font = .systemFont(ofSize: 12)
            text.isRichText = false
            text.allowsUndo = true
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder

            let marks: [(String, SongPartAlign, String)] = [
                ("≡", .default, captions.chunkForm("TBAlignDefault", "Выравнивание по умолчанию")),
                ("⇤", .left, captions.chunkForm("TBAlignLeft", "Выравнивание по левому краю")),
                ("↔", .center, captions.chunkForm("TBAlignCenter", "Выравнивание по центру")),
                ("⇥", .right, captions.chunkForm("TBAlignRight", "Выравнивание по правому краю")),
            ]
            for (title, value, hint) in marks {
                let button = NativeForm.button(title, hint: hint) { [weak self] in
                    self?.align = value
                    self?.markAlign()
                }
                alignButtons.append(button)
                addSubview(button)
            }
            let format = NativeForm.button("¶", hint: captions.chunkForm("TBFormat", "Форматирование текста")) {
                [weak self] in self?.format()
            }
            let unformat = NativeForm.button("↺", hint: captions.chunkForm("TBUnformat",
                                                                          "Отмена форматирования")) {
                [weak self] in
                guard let self else { return }
                self.text.string = SongTextFormatter.unformat(self.text.string)
            }
            alignButtons.append(format)
            alignButtons.append(unformat)
            addSubview(format)
            addSubview(unformat)

            addSubview(songLine)
            addSubview(kind)
            addSubview(scroll)

            buttons = [
                NativeForm.button(captions.chunkForm("BBCancel", "Отменить")) { [weak self] in
                    self?.onClose?()
                },
                NativeForm.button(captions.chunkForm("BBSave", "Ок")) { [weak self] in
                    guard let self else { return }
                    self.apply(self.kind.stringValue,
                               self.text.string.replacingOccurrences(of: "\n", with: "\r\n"),
                               self.align)
                    self.onClose?()
                },
            ]
            buttons[1].keyEquivalent = "\r"
            buttons[0].keyEquivalent = "\u{1B}"
            for button in buttons { addSubview(button) }
            markAlign()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        private func markAlign() {
            let order: [SongPartAlign] = [.default, .left, .center, .right]
            for (index, value) in order.enumerated() {
                alignButtons[index].contentTintColor = value == align ? .controlAccentColor : nil
            }
        }

        private func format() {
            let menu = NSMenu()
            let liters = NSMenuItem(title: captions.caption("NFormatByLiters",
                                                            "Разбиение по Заглавным Буквам"),
                                    action: #selector(formatByLiters), keyEquivalent: "")
            liters.target = self
            let optimal = NSMenuItem(title: captions.caption("NFormatByOptimalSize",
                                                             "Оптимальное размещение на экране"),
                                     action: #selector(formatByOptimal), keyEquivalent: "")
            optimal.target = self
            menu.addItem(liters)
            menu.addItem(optimal)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: alignButtons[4])
        }

        @objc private func formatByLiters() { text.string = SongTextFormatter.byLiters(text.string) }
        @objc private func formatByOptimal() { text.string = SongTextFormatter.byOptimalSize(text.string) }

        override func layout() {
            super.layout()
            songLine.frame = NSRect(x: 16, y: 42, width: bounds.width - 32, height: 18)
            let label = NSTextField(labelWithString: "")
            _ = label
            kind.frame = NSRect(x: 16, y: 68, width: 260, height: 24)
            for (index, button) in alignButtons.enumerated() {
                button.frame = NSRect(x: 16 + CGFloat(index) * 34, y: 100, width: 30, height: 24)
            }
            scroll.frame = NSRect(x: 16, y: 132, width: bounds.width - 32,
                                  height: max(0, bounds.height - 132 - 52))
        }
    }

    // MARK: - Копіювання пісень в інший Пісенник (5.3.8.2)

    /// Вікно `ImportSongsDialogForm`. Виділяємо пісні вихідного Пісенника і
    /// відправляємо їх у приймальний.
    ///
    /// «Выделение нескольких песен производится так же, как и во всех списках
    /// Windows, с помощью „Ctrl" или „Shift" с щелчком мышью» (5.3.8.2) —
    /// тому список із множинним вибором, а не прапорці в кожного рядка.
    final class CopySongs: Sheet, NativeListSource {
        private let captions: SongCaptions
        private let songs: [Song]
        private let destinations: [SongLibrary.Entry]
        private let copy: ([Int], SongLibrary.Entry) -> Void
        private let list = NativeList(mode: .list,
                                      metrics: NativeListMetrics(leadWidth: 44, detailWidth: 0),
                                      heights: .uniform(22))
        private let destination = NSPopUpButton(frame: .zero, pullsDown: false)
        private let query = NSTextField(string: "")
        private let sourceLine = NSTextField(labelWithString: "")
        private var chosen: Set<Int> = []
        private var found: Int?

        init(captions: SongCaptions, sourceName: String, songs: [Song],
             destinations: [SongLibrary.Entry], copy: @escaping ([Int], SongLibrary.Entry) -> Void) {
            self.captions = captions
            self.songs = songs
            self.destinations = destinations
            self.copy = copy
            super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 560))

            heading.stringValue = captions.copyForm("ImportSongsDialogForm",
                                                    "Копирование песен в другой Песенник")
            sourceLine.stringValue = captions.copyForm("Label4", "Исходный песенник:") + "  " + sourceName
            sourceLine.font = .systemFont(ofSize: 12)
            destination.addItems(withTitles: destinations.map(\.displayName))
            query.font = .systemFont(ofSize: 12)

            list.source = self
            list.allowsMultipleSelection = true
            list.onSelect = { [weak self] rows, _, _ in
                guard let self else { return }
                self.chosen = Set(rows.map { self.songs[$0].index })
            }

            addSubview(sourceLine)
            addSubview(destination)
            addSubview(query)
            addSubview(list)

            buttons = [
                NativeForm.button(captions.copyForm("BBCancel", "Отменить")) { [weak self] in
                    self?.onClose?()
                },
                NativeForm.button(captions.copyForm("BBOk", "Ок")) { [weak self] in self?.run() },
                NativeForm.button("↑", hint: captions.copyForm("PngSBSearchPrev", "Искать предыдущее")) {
                    [weak self] in self?.step(-1)
                },
                NativeForm.button("↓", hint: captions.copyForm("PngSBSearchNext", "Искать следующее")) {
                    [weak self] in self?.step(1)
                },
                NativeForm.button("☑", hint: captions.copyForm("PngSBSelAll", "Выделить все песни")) {
                    [weak self] in self?.selectAll()
                },
                NativeForm.button("☐", hint: captions.copyForm("PngSBSelNone",
                                                               "Снять выделение со всех песен")) {
                    [weak self] in self?.selectNone()
                },
            ]
            buttons[1].keyEquivalent = "\r"
            buttons[0].keyEquivalent = "\u{1B}"
            for button in buttons { addSubview(button) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        private func run() {
            guard !chosen.isEmpty, destinations.indices.contains(destination.indexOfSelectedItem) else {
                onClose?()
                return
            }
            copy(Array(chosen).sorted(), destinations[destination.indexOfSelectedItem])
            onClose?()
        }

        /// Пошук «переміщується» до пісні і набраний список не чіпає — так
        /// написано в посібнику.
        private func step(_ delta: Int) {
            let needle = query.stringValue.lowercased()
            guard !needle.isEmpty else { return }
            let start = (found ?? -1) + delta
            let order = delta > 0 ? Array(songs.indices) : Array(songs.indices).reversed().map { $0 }
            let next = order.first { index in
                (delta > 0 ? index >= start : index <= start)
                    && songs[index].title.lowercased().contains(needle)
            }
            guard let next else { return }
            found = next
            list.scrollTo(next)
        }

        private func selectAll() {
            chosen = Set(songs.map(\.index))
            list.setSelection(IndexSet(songs.indices), active: 0)
        }

        private func selectNone() {
            chosen.removeAll()
            list.setSelection(IndexSet(), active: nil)
        }

        override func layout() {
            super.layout()
            sourceLine.frame = NSRect(x: 16, y: 42, width: bounds.width - 32, height: 18)
            destination.frame = NSRect(x: 16, y: 68, width: 320, height: 24)
            query.frame = NSRect(x: 16, y: 100, width: 220, height: 22)
            buttons[2].frame = NSRect(x: 244, y: 100, width: 30, height: 22)
            buttons[3].frame = NSRect(x: 278, y: 100, width: 30, height: 22)
            buttons[4].frame = NSRect(x: bounds.width - 86, y: 100, width: 30, height: 22)
            buttons[5].frame = NSRect(x: bounds.width - 50, y: 100, width: 30, height: 22)
            list.frame = NSRect(x: 16, y: 132, width: bounds.width - 32,
                                height: max(0, bounds.height - 132 - 52))
            // «Ок» і «Скасувати» — своїм рядом унизу.
            var right = bounds.width - 16
            for button in [buttons[1], buttons[0]] {
                let width = max(90, button.intrinsicContentSize.width + 24)
                button.frame = NSRect(x: right - width, y: bounds.height - 40, width: width, height: 24)
                right -= width + 8
            }
        }

        var rowCount: Int { songs.count }

        func row(at index: Int) -> NativeRow {
            var row = NativeRow()
            row.lead = "\(songs[index].index)"
            row.text = songs[index].title
            return row
        }
    }
}
