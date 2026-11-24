// =============================================================================
//  SongChunkPalette.cs — кольори типів частин пісні (з Songs/SongChunkPalette.swift)
// =============================================================================
//  Перенесено разом із Settings: на палітру спирається SlovoSettings (колірна
//  легенда частин пісень, 6.4). Решта тек Songs — окремим кроком.
// =============================================================================

using System.Globalization;
using System.Text;

namespace Slovo.Core;

/// Кольори типів частин пісні із секції `[SongChunksColors]` файла VisioBible.ini.
///
/// Рядок там виглядає так: `Verse=16747383,Куплет,Стих,Zwrotka,Couplet,…` —
/// спершу `TColor` у форматі `0x00BBGGRR`, слідом назва частини всіма мовами,
/// які розуміє оригінал. Це єдине місце, де взагалі записано, що «Zwrotka»,
/// «Vers» і «Куплет» — одне й те саме, тому кольори і синоніми беремо саме звідти.
public sealed class SongChunkPalette : IEquatable<SongChunkPalette>
{
    /// Один тип частини: ключ, колір і всі його назви.
    public sealed record Chunk(string Key, SlideStyle.RGBA Color, IReadOnlyList<string> Names)
    {
        public string Id => Key;

        /// Як називати тип в інтерфейсі: першим у списку йде російське ім'я.
        public string Title => Names.Count > 0 ? Names[0] : Key;

        public bool Equals(Chunk? other) =>
            other is not null && Key == other.Key && Color.Equals(other.Color) && Names.SequenceEqual(other.Names);

        public override int GetHashCode() => HashCode.Combine(Key, Color, Names.Count);
    }

    public IReadOnlyList<Chunk> Chunks { get; }

    private readonly record struct Alias(string Name, string Key);

    /// Відповідність «нормалізована назва → ключ типу». Порядок важливий:
    /// спершу точний збіг, потім найдовший підхожий префікс, інакше `Припев:`
    /// і `Куплет 1.` лишилися б без кольору.
    private readonly List<Alias> aliases;
    private readonly Dictionary<string, string> exactAliases;
    private readonly Dictionary<string, Chunk> byKey;

    public SongChunkPalette(IReadOnlyList<Chunk> chunks)
    {
        Chunks = chunks;

        var list = new List<Alias>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        // Явні назви з конфігу важливіші за ключ: ключ — службове слово,
        // а у файлах пісенників частини підписано по-людськи.
        foreach (var chunk in chunks)
        {
            foreach (var name in chunk.Names)
            {
                var normalized = Normalize(name);
                if (normalized.Length == 0 || !seen.Add(normalized)) continue;
                list.Add(new Alias(normalized, chunk.Key));
            }
        }
        foreach (var chunk in chunks)
        {
            var normalized = Normalize(chunk.Key);
            if (normalized.Length == 0 || !seen.Add(normalized)) continue;
            list.Add(new Alias(normalized, chunk.Key));
        }
        // Того, чого в конфігу немає, але що реально трапляється в пісенниках.
        foreach (var (name, key) in ExtraAliases)
        {
            var normalized = Normalize(name);
            if (normalized.Length == 0 || !seen.Add(normalized)) continue;
            list.Add(new Alias(normalized, key));
        }

        aliases = list.OrderByDescending(alias => SwiftText.CharacterCount(alias.Name)).ToList();
        exactAliases = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var alias in list) exactAliases.TryAdd(alias.Name, alias.Key);
        byKey = new Dictionary<string, Chunk>(StringComparer.Ordinal);
        foreach (var chunk in chunks) byKey.TryAdd(chunk.Key, chunk);
    }

    /// Розбір секції `[SongChunksColors]`.
    public SongChunkPalette(IniSettings config) : this(ReadChunks(config)) { }

    private static IReadOnlyList<Chunk> ReadChunks(IniSettings config)
    {
        // Ключі в `IniSettings` зведено до нижнього регістру, тому порядок
        // відновлюємо за заздалегідь відомим списком типів, а все незнайоме
        // дописуємо слідом.
        string[] known = ["Verse", "Chorus", "Pre-Chorus", "Bridge", "Tag", "Intro", "End"];
        config.Sections.TryGetValue("SongChunksColors", out var section);
        section ??= new Dictionary<string, string>();

        var order = new List<string>(known);
        foreach (var key in section.Keys.OrderBy(key => key, StringComparer.Ordinal))
            if (!known.Any(name => name.ToLowerInvariant() == key)) order.Add(key);

        var chunks = new List<Chunk>();
        foreach (var key in order)
        {
            if (!section.TryGetValue(key.ToLowerInvariant(), out var raw)) continue;
            var fields = raw.Split(',').Select(field => field.TrimWhitespaces()).ToList();
            if (fields.Count == 0 || SwiftText.ParseInt(fields[0]) is not { } value) continue;
            var names = fields.Skip(1).Where(name => name.Length > 0).ToList();
            chunks.Add(new Chunk(key, Color(value), names));
        }
        return chunks.Count == 0 ? FactoryDefault.Chunks : chunks;
    }

    /// Назви, яких немає в `[SongChunksColors]`, але які трапляються
    /// в пісенниках. Без них 145 частин зі 161 226 лишаються без кольору.
    private static readonly (string Name, string Key)[] ExtraAliases =
    [
        ("Хор", "Chorus"),
        ("Бридж", "Bridge"),
        ("Концовка", "End"),
        ("Окончание", "End"),
        ("Закінчення", "End"),
        ("Schluss", "End"),
    ];

    /// Значення з поставки старої програми — на випадок, коли конфігу поруч немає.
    /// (Оголошено після `ExtraAliases`: статичні поля ініціалізуються згори донизу.)
    public static readonly SongChunkPalette FactoryDefault = new(new List<Chunk>
    {
        new("Verse", Color(16747383),
            ["Куплет", "Стих", "Zwrotka", "Couplet", "Copla", "Vers", "Estrofe", "Versetul", "Verš", "Kuplet", "פסוק"]),
        new("Chorus", Color(9731541),
            ["Припев", "Приспів", "Refren", "Refrain", "Estribillo", "Ritornello", "Refrão", "Refrén", "Прыпеў", "פזמון"]),
        new("Pre-Chorus", Color(8927667),
            ["Запев", "Заспів", "Соло", "Solo", "Anstimmen", "Intro", "Entonnas", "Canto", "Éneklés", "Spev", "Zpívání", "Запеў", "Пеейки", "Прадпрысьпеў"]),
        new("Bridge", Color(12341183),
            ["Мост", "Міст", "Most", "Brücke", "Puente", "Pont", "Ponte", "Híd", "Podul", "גשר"]),
        new("Tag", Color(15728814),
            ["Описание", "Опис", "Opis", "Beschreibung", "Descripción", "Description", "Descrizione", "Leírás", "Descrição", "Descriere", "Popis", "Апісанне", "תיאור"]),
        new("Intro", Color(6723891),
            ["Вступление", "Вступ", "Въведение", "Wejście", "Einführung", "Entrée", "Bevezetés", "Entrada", "Introducere", "Úvod", "Vstup", "מבוא"]),
        new("End", Color(18137),
            ["Кода", "Кінцівка", "Код", "Zakończenie", "Ende", "Final", "Fin", "Fine", "Vége", "Sfârșitul", "Konci", "Konec", "Канец", "Край", "סוף"]),
    });

    // ── Пошук типу за назвою частини ────────────────────────────────────────

    /// Тип частини за її назвою з пісенника. У файлах назви написано як
    /// попало: `Куплет`, `Куплет 1.`, `1 Куплет`, `Куплет3`, `Припев:` —
    /// тому порівнюємо лише літери і дозволяємо збіг за початком рядка.
    public Chunk? ChunkFor(string kind)
    {
        var normalized = Normalize(kind);
        if (normalized.Length == 0) return null;
        if (exactAliases.TryGetValue(normalized, out var exact)) return byKey.GetValueOrDefault(exact);
        foreach (var alias in aliases)
            if (normalized.StartsWith(alias.Name, StringComparison.Ordinal)) return byKey.GetValueOrDefault(alias.Key);
        return null;
    }

    public SlideStyle.RGBA? ColorFor(string kind) => ChunkFor(kind)?.Color;

    public Chunk? ChunkByKey(string key) => byKey.GetValueOrDefault(key);

    /// Порядковий номер частини: `Куплет 2` → 2, `1 Куплет` → 1, `Припев` → null.
    public static int? Number(string kind)
    {
        var digits = new StringBuilder();
        foreach (var c in kind + " ")
        {
            if (SwiftText.IsNumber(c)) { digits.Append(c); continue; }
            if (digits.Length > 0)
            {
                if (SwiftText.ParseInt(digits.ToString()) is { } value) return value;
                digits.Clear();
            }
        }
        return null;
    }

    /// Лише літери (і позначки — `CharacterSet.letters` їх містить), у нижньому
    /// регістрі і без діакритики: цифри, крапки і двокрапки нічого не значать.
    internal static string Normalize(string text)
    {
        var folded = SwiftText.Fold(text);
        var output = new StringBuilder(folded.Length);
        foreach (var rune in folded.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
                or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
                or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
                or UnicodeCategory.EnclosingMark)
                output.Append(rune.ToString());
        }
        return output.ToString();
    }

    /// `TColor` у Delphi — `0x00BBGGRR`, канали у зворотному порядку.
    public static SlideStyle.RGBA Color(int value) =>
        new((value & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, ((value >> 16) & 0xFF) / 255.0);

    public bool Equals(SongChunkPalette? other) => other is not null && Chunks.SequenceEqual(other.Chunks);
    public override bool Equals(object? obj) => obj is SongChunkPalette other && Equals(other);
    public override int GetHashCode() => Chunks.Count;
}
