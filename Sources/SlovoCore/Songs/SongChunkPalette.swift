import Foundation

/// Кольори типів частин пісні із секції `[SongChunksColors]` файла VisioBible.ini.
///
/// Рядок там виглядає так:
/// `Verse=16747383,Куплет,Стих,Zwrotka,Couplet,…`
/// — спершу `TColor` у форматі `0x00BBGGRR`, слідом назва частини всіма
/// мовами, які розуміє оригінал. Це єдине місце, де взагалі
/// записано, що «Zwrotka», «Vers» і «Куплет» — одне й те саме, тому кольори
/// і синоніми беремо саме звідти, а не зі своєї таблиці.
public struct SongChunkPalette: Sendable, Hashable {

    /// Один тип частини: ключ, колір і всі його назви.
    public struct Chunk: Sendable, Hashable, Identifiable {
        public let key: String                  // Verse, Chorus, Bridge…
        public let color: SlideStyle.RGBA
        public let names: [String]              // «Куплет», «Стих», «Zwrotka», …

        public var id: String { key }

        /// Як називати тип в інтерфейсі: першим у списку йде російське ім'я.
        public var title: String { names.first ?? key }

        public init(key: String, color: SlideStyle.RGBA, names: [String]) {
            self.key = key
            self.color = color
            self.names = names
        }
    }

    public let chunks: [Chunk]

    private struct Alias: Sendable, Hashable {
        let name: String
        let key: String
    }

    /// Відповідність «нормалізована назва → ключ типу». Порядок важливий:
    /// спершу пробуємо точний збіг, потім найдовший підхожий
    /// префікс, інакше `Припев:` і `Куплет 1.` лишилися б без кольору.
    private let aliases: [Alias]
    private let exactAliases: [String: String]
    private let byKey: [String: Chunk]

    public init(chunks: [Chunk]) {
        self.chunks = chunks

        var aliases: [Alias] = []
        var seen = Set<String>()
        // Явні назви з конфігу важливіші за ключ: ключ — службове слово,
        // а у файлах пісенників частини підписано по-людськи.
        for chunk in chunks {
            for name in chunk.names {
                let normalized = Self.normalize(name)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
                aliases.append(Alias(name: normalized, key: chunk.key))
            }
        }
        for chunk in chunks {
            let normalized = Self.normalize(chunk.key)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            aliases.append(Alias(name: normalized, key: chunk.key))
        }
        // Того, чого в конфігу немає, але що реально трапляється в пісенниках
        // користувача: «Хор», «Бридж», «Концовка», «Schluss».
        for (name, key) in Self.extraAliases {
            let normalized = Self.normalize(name)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            aliases.append(Alias(name: normalized, key: key))
        }

        self.aliases = aliases.sorted { $0.name.count > $1.name.count }
        self.exactAliases = Dictionary(aliases.map { ($0.name, $0.key) }, uniquingKeysWith: { first, _ in first })
        self.byKey = Dictionary(chunks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Розбір секції `[SongChunksColors]`.
    public init(config: IniSettings) {
        // Ключі в `IniSettings` зведено до нижнього регістру, тому
        // порядок відновлюємо за заздалегідь відомим списком типів, а все
        // незнайоме дописуємо слідом.
        let known = ["Verse", "Chorus", "Pre-Chorus", "Bridge", "Tag", "Intro", "End"]
        let section = config.sections["SongChunksColors"] ?? [:]

        var order = known
        for key in section.keys.sorted() where !known.contains(where: { $0.lowercased() == key }) {
            order.append(key)
        }

        var chunks: [Chunk] = []
        for key in order {
            guard let raw = section[key.lowercased()] else { continue }
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = fields.first, let value = Int(first) else { continue }
            let names = fields.dropFirst().filter { !$0.isEmpty }
            chunks.append(Chunk(key: key, color: Self.color(tColor: value), names: Array(names)))
        }
        self.init(chunks: chunks.isEmpty ? Self.factoryDefault.chunks : chunks)
    }

    /// Значення з поставки VisioBible — на випадок, коли конфігу поруч немає.
    public static let factoryDefault = SongChunkPalette(chunks: [
        Chunk(key: "Verse", color: SongChunkPalette.color(tColor: 16747383),
              names: ["Куплет", "Стих", "Zwrotka", "Couplet", "Copla", "Vers", "Estrofe", "Versetul", "Verš", "Kuplet", "פסוק"]),
        Chunk(key: "Chorus", color: SongChunkPalette.color(tColor: 9731541),
              names: ["Припев", "Приспів", "Refren", "Refrain", "Estribillo", "Ritornello", "Refrão", "Refrén", "Прыпеў", "פזמון"]),
        Chunk(key: "Pre-Chorus", color: SongChunkPalette.color(tColor: 8927667),
              names: ["Запев", "Заспів", "Соло", "Solo", "Anstimmen", "Intro", "Entonnas", "Canto", "Éneklés", "Spev", "Zpívání", "Запеў", "Пеейки", "Прадпрысьпеў"]),
        Chunk(key: "Bridge", color: SongChunkPalette.color(tColor: 12341183),
              names: ["Мост", "Міст", "Most", "Brücke", "Puente", "Pont", "Ponte", "Híd", "Podul", "גשר"]),
        Chunk(key: "Tag", color: SongChunkPalette.color(tColor: 15728814),
              names: ["Описание", "Опис", "Opis", "Beschreibung", "Descripción", "Description", "Descrizione", "Leírás", "Descrição", "Descriere", "Popis", "Апісанне", "תיאור"]),
        Chunk(key: "Intro", color: SongChunkPalette.color(tColor: 6723891),
              names: ["Вступление", "Вступ", "Въведение", "Wejście", "Einführung", "Entrée", "Bevezetés", "Entrada", "Introducere", "Úvod", "Vstup", "מבוא"]),
        Chunk(key: "End", color: SongChunkPalette.color(tColor: 18137),
              names: ["Кода", "Кінцівка", "Код", "Zakończenie", "Ende", "Final", "Fin", "Fine", "Vége", "Sfârșitul", "Konci", "Konec", "Канец", "Край", "סוף"]),
    ])

    /// Назви, яких немає в `[SongChunksColors]`, але які трапляються
    /// в пісенниках. Без них 145 частин зі 161 226 лишаються без кольору.
    private static let extraAliases: [(String, String)] = [
        ("Хор", "Chorus"),
        ("Бридж", "Bridge"),
        ("Концовка", "End"),
        ("Окончание", "End"),
        ("Закінчення", "End"),
        ("Schluss", "End"),
    ]

    // MARK: - Пошук типу за назвою частини

    /// Тип частини за її назвою з пісенника.
    ///
    /// У файлах назви написано як попало: `Куплет`, `Куплет 1`,
    /// `Куплет 1.`, `1 Куплет`, `Куплет3`, `Припев:` і навіть
    /// `Припев: се, се я с вами…`. Тому порівнюємо лише літери і
    /// дозволяємо збіг за початком рядка.
    public func chunk(for kind: String) -> Chunk? {
        let normalized = Self.normalize(kind)
        guard !normalized.isEmpty else { return nil }
        if let exact = exactAliases[normalized] { return byKey[exact] }
        if let prefixed = aliases.first(where: { normalized.hasPrefix($0.name) }) { return byKey[prefixed.key] }
        return nil
    }

    public func color(for kind: String) -> SlideStyle.RGBA? {
        chunk(for: kind)?.color
    }

    public func chunk(key: String) -> Chunk? { byKey[key] }

    /// Порядковий номер частини: `Куплет 2` → 2, `1 Куплет` → 1, `Припев` → nil.
    public static func number(in kind: String) -> Int? {
        let digits = kind.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return digits.first
    }

    /// Лише літери, в нижньому регістрі і без діакритики: цифри, крапки і
    /// двокрапки в назві частини нічого не значать.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }))
    }

    /// `TColor` у Delphi — `0x00BBGGRR`, канали у зворотному порядку.
    static func color(tColor value: Int) -> SlideStyle.RGBA {
        SlideStyle.RGBA(Double(value & 0xFF) / 255,
                        Double((value >> 8) & 0xFF) / 255,
                        Double((value >> 16) & 0xFF) / 255)
    }
}
