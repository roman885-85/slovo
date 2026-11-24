// =============================================================================
//  SongBookEditor.cs — правка Пісенника, розділ 5.3.9 посібника
//  (з Songs/SongBookEditor.swift)
// =============================================================================
//  Переклад Swift → C#:
//    `updateSong(at:) { (inout Song) in … }` — Action<Song>: пісня тут клас;
//    `updatePart(at:inSongAt:) { (inout SongPart) in … }` — SongPartMutation
//      (делегат з `ref`): частина — значення, як у Swift.
//    `copySongs(…, into: inout SongBook, …)` — приймальний пісенник
//      змінюється на місці (клас); пісні в нього лягають копіями.
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

// ── Вирівнювання частини пісні ─────────────────────────────────────────────

/// Вирівнювання тексту частини пісні — кнопки (9)–(12) панелі інструментів
/// списку «Текст» (посібник, 5.3.9.2).
///
/// Числа взято не зі стелі: у файлі пісенника в кожної частини є службове
/// поле UInt32, і в коді оригіналу воно порівнюється ланцюжком
/// `1 → «$Align$=Left», 2 → «$Align$=Right», 3 → «$Align$=Center»`.
/// Нуль означає «як задано в шаблоні слайда».
public enum SongPartAlign : uint
{
    Default = 0,
    Left = 1,
    Right = 2,
    Center = 3,
}

public static class SongPartAligns
{
    public static readonly IReadOnlyList<SongPartAlign> All =
        [SongPartAlign.Default, SongPartAlign.Left, SongPartAlign.Right, SongPartAlign.Center];

    public static uint RawValue(this SongPartAlign align) => (uint)align;

    /// `SongPartAlign(rawValue:)`.
    public static SongPartAlign? FromRawValue(uint raw) =>
        raw <= 3 ? (SongPartAlign)raw : null;

    /// Як оригінал називає це вирівнювання при експорті в текстовий файл.
    public static string? ExportName(this SongPartAlign align) => align switch
    {
        SongPartAlign.Left => "Left",
        SongPartAlign.Right => "Right",
        SongPartAlign.Center => "Center",
        _ => null,
    };

    /// `SongPartAlign(exportName:)`.
    public static SongPartAlign? FromExportName(string exportName) =>
        exportName.TrimWhitespaces().ToLowerInvariant() switch
        {
            "left" => SongPartAlign.Left,
            "right" => SongPartAlign.Right,
            "center" => SongPartAlign.Center,
            "" => SongPartAlign.Default,
            _ => null,
        };
}

// ── Група пісень ───────────────────────────────────────────────────────────

/// Користувацька група пісень — список «Група» (26) з розділу 5.3.1.
/// Зберігає номери пісень у збірнику, а не самі пісні: так їх зберігає і файл.
public sealed class SongGroup : IEquatable<SongGroup>
{
    public string Name;
    public List<int> SongIndices;

    public string Id => Name;

    public SongGroup(string name, IEnumerable<int>? songIndices = null)
    {
        Name = name;
        SongIndices = songIndices?.ToList() ?? new List<int>();
    }

    public SongGroup Copy() => new(Name, SongIndices);

    public bool Equals(SongGroup? other) =>
        other is not null && Name == other.Name && SongIndices.SequenceEqual(other.SongIndices);

    public override bool Equals(object? obj) => obj is SongGroup other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Name, SongIndices.Count);
}

// ── Форматування тексту ────────────────────────────────────────────────────

/// Пункти меню «Форматування тексту» — кнопка (13) панелі «Текст»
/// і пункти `NFormatByLiters` / `NFormatByOptimalSize` з файла перекладу.
public enum SongTextFormat
{
    ByLiters,          // «Разбиение по Заглавным Буквам»
    ByOptimalSize,     // «Оптимальное размещение на экране»
}

public static class SongTextFormatter
{
    public static readonly IReadOnlyList<SongTextFormat> AllFormats = [SongTextFormat.ByLiters, SongTextFormat.ByOptimalSize];

    public static string RawValue(this SongTextFormat format) =>
        format == SongTextFormat.ByLiters ? "byLiters" : "byOptimalSize";

    /// «Скасування форматування» — кнопка (14). Посібник прямо описує
    /// результат: «удаляет все переносы строк так, что, например,
    /// четверостишие становится одной строкой вместо четырёх».
    public static string Unformat(string text)
    {
        var words = new List<string>();
        var lines = SplitCharacters(text.Replace("\r\n", "\n"),
                                    c => SwiftText.IsNewline(c[0]) || c == "\u000B" || c == "\t");
        foreach (var line in lines) words.AddRange(SplitCharacters(line, c => c == " "));
        return string.Join(" ", words).TrimWhitespaces();
    }

    /// «Розбиття за Великими Літерами»: рядок починається там, де починається
    /// слово з великої літери. У пісенниках так набрано більшість текстів,
    /// тому за великими відновлюється вихідне розбиття на рядки.
    public static string ByLiters(string text)
    {
        var flat = Unformat(text);
        if (flat.Length == 0) return flat;

        var lines = new List<string>();
        var current = new List<string>();
        foreach (var word in SplitCharacters(flat, c => c == " "))
        {
            var startsSentence = SwiftText.IsUppercase(SwiftText.PrefixCharacters(word, 1));
            if (startsSentence && current.Count > 0)
            {
                lines.Add(string.Join(" ", current));
                current.Clear();
            }
            current.Add(word);
        }
        if (current.Count > 0) lines.Add(string.Join(" ", current));
        return string.Join("\n", lines);
    }

    /// «Оптимальне розміщення на екрані»: рядки приблизно однієї довжини, без
    /// розриву слів. Оригінал рахує за шириною шаблону слайда; ширини тут
    /// немає, тому беремо цільову довжину рядка і розкладаємо текст рівно —
    /// це дає той самий зоровий результат: акуратна «цеглина» тексту.
    public static string ByOptimalSize(string text, int targetLineLength = 32)
    {
        var flat = Unformat(text);
        if (flat.Length == 0) return flat;
        var words = SplitCharacters(flat, c => c == " ");
        if (words.Count <= 1) return flat;

        var total = SwiftText.CharacterCount(flat);
        var lineCount = Math.Max(1, (int)Math.Round((double)total / targetLineLength, MidpointRounding.AwayFromZero));
        if (lineCount <= 1) return flat;
        var longest = words.Count > 0 ? words.Max(SwiftText.CharacterCount) : targetLineLength;
        var width = Math.Max(longest, (int)Math.Ceiling((double)total / lineCount));

        var lines = new List<string>();
        var current = "";
        foreach (var word in words)
        {
            if (current.Length == 0)
                current = word;
            else if (SwiftText.CharacterCount(current) + 1 + SwiftText.CharacterCount(word) <= width)
                current += " " + word;
            else
            {
                lines.Add(current);
                current = word;
            }
        }
        if (current.Length > 0) lines.Add(current);
        return string.Join("\n", lines);
    }

    public static string Apply(SongTextFormat format, string text) =>
        format == SongTextFormat.ByLiters ? ByLiters(text) : ByOptimalSize(text);

    /// `split(whereSeparator:)` за «знаками» Swift (графемами): порожні шматки
    /// відкидаються.
    internal static List<string> SplitCharacters(string text, Func<string, bool> isSeparator)
    {
        var result = new List<string>();
        var start = 0;
        var index = 0;
        while (index < text.Length)
        {
            var length = StringInfo.GetNextTextElementLength(text, index);
            if (length <= 0) length = 1;
            if (isSeparator(text.Substring(index, length)))
            {
                if (index > start) result.Add(text[start..index]);
                start = index + length;
            }
            index += length;
        }
        if (text.Length > start) result.Add(text[start..]);
        return result;
    }
}

// ── Властивості пісні ──────────────────────────────────────────────────────

public sealed partial class Song
{
    /// Записати властивість виду `$ID$=1728`. Порожнє значення прибирає рядок —
    /// саме так працює пункт «Очистити поле "Номер у збірнику"».
    public void SetProperty(string key, string? value)
    {
        var marker = key.StartsWith('$') ? key : $"${key}$";
        var lines = Properties.Replace("\r\n", "\n")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => !line.TrimWhitespaces().StartsWith(marker + "=", StringComparison.Ordinal))
            .ToList();

        if (!string.IsNullOrEmpty(value)) lines.Add($"{marker}={value}");
        Properties = string.Join("\r\n", lines);
    }

    /// «Номер у збірнику» з вікна атрибутів пісні (поле `ELogicNum`).
    public string CatalogNumberText =>
        PropertyPairs.TryGetValue("$ID$", out var value) ? value.TrimWhitespaces() : "";

    public string Tune =>
        PropertyPairs.TryGetValue("$TUNE$", out var value) ? value.TrimWhitespaces() : "";
}

// ── Редактор Пісенника ─────────────────────────────────────────────────────

/// Зміна частини пісні на місці — `(inout SongPart) -> Void` у Swift.
public delegate void SongPartMutation(ref SongPart part);

/// Змінюваний Пісенник і всі операції розділу 5.3.9 посібника.
///
/// Окремий клас, а не змінювана структура, з однієї причини: кнопка
/// «Зберегти Пісенник» (30.6) має бути неактивна, поки Пісенник не
/// мінявся, — отже, хтось зобов'язаний пам'ятати, мінявся він чи ні. Тут це
/// `IsModified`, і його виставляє кожна операція.
///
/// Редактор працює зі СВОЄЮ копією пісенника (у Swift пісенник — значення):
/// правка не просочується в кеш `SongLibrary`, доки її не прийняли
/// (`SongLibrary.Adopt`).
public sealed class SongBookEditor
{
    public SongBook Book { get; private set; }
    public string? Url { get; private set; }
    public bool IsModified { get; private set; }

    public SongBookEditor(SongBook book, string? url, bool isModified = false)
    {
        Book = book.Copy();
        Url = url;
        IsModified = isModified;
    }

    /// `SongBookEditor(fileAt:)`.
    public static SongBookEditor FromFile(string path) => new(SongBook.FromFile(path), path);

    /// Порожній Пісенник — заготовка для пункту «Створити новий Пісенник».
    public static SongBook NewBook(string title, string shortName) => new(title, shortName);

    private void Touch() => IsModified = true;

    /// Позначити як незбережений ззовні — наприклад, після правки атрибутів.
    public void MarkModified() => Touch();

    // ── Атрибути Пісенника (30.2 / 30.5) ────────────────────────────────────

    public void UpdateAttributes(string title, string shortName, string publisher,
                                 string revisionDate, string comment, uint charset)
    {
        Book.Title = title;
        Book.ShortName = shortName;
        Book.Publisher = publisher;
        Book.RevisionDate = revisionDate;
        Book.Comment = comment;
        Book.Charset = charset;
        Touch();
    }

    // ── Збереження (30.6) ───────────────────────────────────────────────────

    public string Save()
    {
        if (Url == null) throw SongBookError.NotASongBook(OurWords.T("путь к Песеннику не задан"));
        return Save(Url);
    }

    /// Повертає, куди насправді лягло: пишемо у своєму форматі `.songbook`;
    /// на `.vbm` показали — файл ляже поруч як `.songbook`, а `.vbm`
    /// лишиться для прежней программы.
    public string Save(string destination)
    {
        var target = SongBookJSON.Save(Book, destination);
        Url = target;
        IsModified = false;
        return target;
    }

    // ── Групи (5.3.9.4) ─────────────────────────────────────────────────────

    /// Номери пісень, які показує список «Пісня» для вибраної групи.
    /// `null` — псевдогрупа «Усі пісні», вона завжди перша в списку.
    public List<int> SongIndices(int? group)
    {
        if (group is not { } chosen || chosen < 0 || chosen >= Book.Groups.Count)
            return Enumerable.Range(0, Book.Songs.Count).ToList();
        // Порядок у групі — порядок у Пісеннику: так його показує оригінал.
        var members = new HashSet<int>(Book.Groups[chosen].SongIndices);
        return Enumerable.Range(0, Book.Songs.Count).Where(members.Contains).ToList();
    }

    public int AddGroup(string name)
    {
        Book.Groups.Add(new SongGroup(name));
        Touch();
        return Book.Groups.Count - 1;
    }

    public void RenameGroup(int index, string name)
    {
        if (!HasGroup(index)) return;
        Book.Groups[index].Name = name;
        Touch();
    }

    public void RemoveGroup(int index)
    {
        if (!HasGroup(index)) return;
        Book.Groups.RemoveAt(index);
        Touch();
    }

    public int? DuplicateGroup(int index)
    {
        if (!HasGroup(index)) return null;
        var copy = Book.Groups[index].Copy();
        copy.Name = CopyName(copy.Name, Book.Groups.Select(group => group.Name).ToList());
        Book.Groups.Insert(index + 1, copy);
        Touch();
        return index + 1;
    }

    public int? MoveGroup(int index, int delta)
    {
        if (!HasGroup(index)) return null;
        var target = index + delta;
        if (!HasGroup(target)) return null;
        (Book.Groups[index], Book.Groups[target]) = (Book.Groups[target], Book.Groups[index]);
        Touch();
        return target;
    }

    // ── Пісня в групі (5.3.9.5) ─────────────────────────────────────────────

    public bool IsSong(int songIndex, int group) =>
        HasGroup(group) && Book.Groups[group].SongIndices.Contains(songIndex);

    public void AddSong(int songIndex, int group)
    {
        if (!HasGroup(group) || !HasSong(songIndex) || Book.Groups[group].SongIndices.Contains(songIndex)) return;
        Book.Groups[group].SongIndices.Add(songIndex);
        Book.Groups[group].SongIndices.Sort();
        Touch();
    }

    public void RemoveSong(int songIndex, int group)
    {
        if (!HasGroup(group)) return;
        var removed = Book.Groups[group].SongIndices.RemoveAll(index => index == songIndex);
        if (removed > 0) Touch();
    }

    // ── Пісні (5.3.9.6) ─────────────────────────────────────────────────────

    public int InsertSong(Song song, int position)
    {
        var target = Math.Min(Math.Max(0, position), Book.Songs.Count);
        var inserted = song.Copy();
        inserted.Index = target;
        Book.Songs.Insert(target, inserted);
        // Усе, що стояло починаючи з цієї позиції, зсунулося на одиницю —
        // посилання в групах зобов'язані зсунутися разом із піснями.
        RemapGroups(index => index < target ? index : index + 1);
        RenumberSongs();
        Touch();
        return target;
    }

    public int AppendSong(Song song) => InsertSong(song, Book.Songs.Count);

    public void RemoveSong(int index)
    {
        if (!HasSong(index)) return;
        Book.Songs.RemoveAt(index);
        // «Внимание! Песня будет удалена из всех групп.» — повідомлення оригіналу.
        foreach (var group in Book.Groups) group.SongIndices.RemoveAll(member => member == index);
        RemapGroups(member => member < index ? member : member - 1);
        RenumberSongs();
        Touch();
    }

    public int? DuplicateSong(int index)
    {
        if (!HasSong(index)) return null;
        var copy = Book.Songs[index].Copy();
        copy.Title = CopyName(copy.Title, Book.Songs.Select(song => song.Title).ToList());
        return InsertSong(copy, index + 1);
    }

    public void UpdateSong(int index, Action<Song> mutate)
    {
        if (!HasSong(index)) return;
        mutate(Book.Songs[index]);
        Book.Songs[index].Index = index;
        RenumberParts(index);
        Touch();
    }

    /// Кнопки (5)–(6) панелі «Пісня»: перемістити на одну позицію.
    public int? MoveSong(int index, int delta)
    {
        if (!HasSong(index)) return null;
        var target = index + delta;
        if (!HasSong(target)) return null;
        return SetSongPosition(index, target + 1);
    }

    /// Кнопка (7): «Установление нового номера по порядку текущей песни.
    /// При этом эта песня будет помещена в позицию, соответствующую
    /// введённому номеру». Номер — людський, з одиниці.
    public int? SetSongPosition(int index, int number)
    {
        if (!HasSong(index)) return null;
        var target = Math.Min(Math.Max(0, number - 1), Book.Songs.Count - 1);
        if (target == index) return index;

        var song = Book.Songs[index];
        Book.Songs.RemoveAt(index);
        Book.Songs.Insert(target, song);
        RemapGroups(old =>
        {
            if (old == index) return target;
            if (index < target) return old > index && old <= target ? old - 1 : old;
            return old >= target && old < index ? old + 1 : old;
        });
        RenumberSongs();
        Touch();
        return target;
    }

    /// Кнопка (8): меню сортування. «Этот процесс необратим и производит
    /// реальную сортировку песен в Песеннике».
    public enum SongSort
    {
        ByNumber,      // «За Номером»
        ByTitle,       // «За Назвою»
    }

    public void SortSongs(SongSort order)
    {
        if (Book.Songs.Count == 0) return;
        var songs = Book.Songs;
        Comparison<int> less = order switch
        {
            // «Если номер в песне не указан, будет произведена сортировка по
            // названию» — так попереджає сам оригінал перед сортуванням.
            SongSort.ByNumber => (left, right) =>
            {
                var a = songs[left].CatalogNumber;
                var b = songs[right].CatalogNumber;
                if (a is { } x && b is { } y && x != y) return x < y ? -1 : 1;
                if (a == null && b != null) return 1;
                if (a != null && b == null) return -1;
                return SwiftText.LocalizedStandardCompare(songs[left].Title, songs[right].Title);
            },
            _ => (left, right) => SwiftText.LocalizedStandardCompare(songs[left].Title, songs[right].Title),
        };
        // Сортування Swift стабільне — тому LINQ, а не List.Sort.
        var sorted = Enumerable.Range(0, songs.Count).OrderBy(position => position, Comparer<int>.Create(less)).ToList();

        Book.Songs = sorted.Select(position => songs[position]).ToList();
        var mapping = new Dictionary<int, int>();
        for (var newIndex = 0; newIndex < sorted.Count; newIndex++) mapping[sorted[newIndex]] = newIndex;
        RemapGroups(old => mapping.TryGetValue(old, out var moved) ? moved : old);
        RenumberSongs();
        Touch();
    }

    // ── «Номери в збірнику» (контекстне меню пісні) ─────────────────────────

    /// «Збільшити/Зменшити від цієї пісні і до кінця на…».
    public void ShiftCatalogNumbers(int index, int delta)
    {
        if (!HasSong(index) || delta == 0) return;
        for (var position = index; position < Book.Songs.Count; position++)
        {
            if (Book.Songs[position].CatalogNumber is not { } current) continue;
            Book.Songs[position].SetProperty("$ID$", Math.Max(0, current + delta).ToString(CultureInfo.InvariantCulture));
        }
        Touch();
    }

    /// «Очистити поле "Номер у збірнику" в УСІХ піснях».
    public void ClearCatalogNumbers()
    {
        foreach (var song in Book.Songs) song.SetProperty("$ID$", null);
        Touch();
    }

    /// «Установити поле "Номер у збірнику" в УСІХ піснях рівним
    /// порядковому номеру».
    public void SetCatalogNumbersToOrdinal()
    {
        for (var position = 0; position < Book.Songs.Count; position++)
            Book.Songs[position].SetProperty("$ID$", (position + 1).ToString(CultureInfo.InvariantCulture));
        Touch();
    }

    // ── Частини пісні (5.3.9.7) ─────────────────────────────────────────────

    public int? InsertPart(SongPart part, int songIndex, int position)
    {
        if (!HasSong(songIndex)) return null;
        var parts = Book.Songs[songIndex].Parts;
        var target = Math.Min(Math.Max(0, position), parts.Count);
        var inserted = part;
        inserted.Index = target;
        parts.Insert(target, inserted);
        RenumberParts(songIndex);
        Touch();
        return target;
    }

    public void RemovePart(int partIndex, int songIndex)
    {
        if (!HasSong(songIndex) || !HasPart(songIndex, partIndex)) return;
        Book.Songs[songIndex].Parts.RemoveAt(partIndex);
        RenumberParts(songIndex);
        Touch();
    }

    public int? DuplicatePart(int partIndex, int songIndex)
    {
        if (!HasSong(songIndex) || !HasPart(songIndex, partIndex)) return null;
        var copy = Book.Songs[songIndex].Parts[partIndex];
        return InsertPart(copy, songIndex, partIndex + 1);
    }

    public int? MovePart(int partIndex, int songIndex, int delta)
    {
        if (!HasSong(songIndex)) return null;
        var target = partIndex + delta;
        if (!HasPart(songIndex, partIndex) || !HasPart(songIndex, target)) return null;
        var parts = Book.Songs[songIndex].Parts;
        (parts[partIndex], parts[target]) = (parts[target], parts[partIndex]);
        RenumberParts(songIndex);
        Touch();
        return target;
    }

    public void UpdatePart(int partIndex, int songIndex, SongPartMutation mutate)
    {
        if (!HasSong(songIndex) || !HasPart(songIndex, partIndex)) return;
        var parts = Book.Songs[songIndex].Parts;
        var part = parts[partIndex];
        mutate(ref part);
        part.Index = partIndex;
        parts[partIndex] = part;
        Touch();
    }

    /// Кнопки (9)–(12).
    public void SetAlign(SongPartAlign align, int partIndex, int songIndex) =>
        UpdatePart(partIndex, songIndex, (ref SongPart part) => part.Align = align);

    /// Кнопка (13) — меню форматування тексту виділеної частини пісні.
    public void Format(SongTextFormat style, int partIndex, int songIndex) =>
        UpdatePart(partIndex, songIndex, (ref SongPart part) => part.Text = SongTextFormatter.Apply(style, part.Text));

    /// Кнопка (14) — скасування форматування виділеної частини пісні.
    public void Unformat(int partIndex, int songIndex) =>
        UpdatePart(partIndex, songIndex, (ref SongPart part) => part.Text = SongTextFormatter.Unformat(part.Text));

    /// «Форматувати пісню» — одразу всі частини вибраної пісні.
    public void FormatSong(SongTextFormat style, int songIndex)
    {
        if (!HasSong(songIndex)) return;
        var parts = Book.Songs[songIndex].Parts;
        for (var position = 0; position < parts.Count; position++)
        {
            var part = parts[position];
            part.Text = SongTextFormatter.Apply(style, part.Text);
            parts[position] = part;
        }
        Touch();
    }

    public void UnformatSong(int songIndex)
    {
        if (!HasSong(songIndex)) return;
        var parts = Book.Songs[songIndex].Parts;
        for (var position = 0; position < parts.Count; position++)
        {
            var part = parts[position];
            part.Text = SongTextFormatter.Unformat(part.Text);
            parts[position] = part;
        }
        Touch();
    }

    /// «Форматування ВСІХ пісень». Оригінал попереджає, що це надовго.
    public void FormatAllSongs(SongTextFormat style)
    {
        for (var song = 0; song < Book.Songs.Count; song++) FormatSong(style, song);
    }

    public void UnformatAllSongs()
    {
        for (var song = 0; song < Book.Songs.Count; song++) UnformatSong(song);
    }

    // ── Дублювання приспіву (контекстне меню пісні і групи) ─────────────────

    /// «Дублювати приспів» — додає після кожного куплета копію приспіву.
    /// `marker` — «рядок-ознака приспіву» з варіанта «за ознакою»: частина
    /// тексту, за якою приспів упізнають, коли він не підписаний як приспів.
    public int DuplicateRefrain(int songIndex, string? marker = null, SongChunkPalette? palette = null)
    {
        palette ??= SongChunkPalette.FactoryDefault;
        if (!HasSong(songIndex)) return 0;
        var parts = Book.Songs[songIndex].Parts;
        if (RefrainIndex(parts, marker, palette) is not { } refrainIndex) return 0;
        var refrain = parts[refrainIndex];

        var rebuilt = new List<SongPart>();
        var inserted = 0;
        for (var position = 0; position < parts.Count; position++)
        {
            var part = parts[position];
            rebuilt.Add(part);
            if (!IsVerse(part, palette)) continue;
            // Якщо приспів і так стоїть наступним, другий примірник не потрібен.
            var next = position + 1;
            if (next < parts.Count && IsSameRefrain(parts[next], refrain)) continue;
            rebuilt.Add(refrain);
            inserted += 1;
        }
        if (inserted <= 0) return 0;

        Book.Songs[songIndex].Parts = rebuilt;
        RenumberParts(songIndex);
        Touch();
        return inserted;
    }

    /// «Дублювати приспіви в УСІХ піснях!»
    public int DuplicateRefrainsInAllSongs(string? marker = null, SongChunkPalette? palette = null)
    {
        var total = 0;
        for (var song = 0; song < Book.Songs.Count; song++) total += DuplicateRefrain(song, marker, palette);
        return total;
    }

    internal static int? RefrainIndex(IReadOnlyList<SongPart> parts, string? marker, SongChunkPalette palette)
    {
        if (marker != null && marker.TrimWhitespaces().Length > 0)
        {
            var needle = SongLibrary.Fold(marker);
            for (var index = 0; index < parts.Count; index++)
                if (SongLibrary.Fold(parts[index].Text).Contains(needle, StringComparison.Ordinal)) return index;
            for (var index = 0; index < parts.Count; index++)
                if (SongLibrary.Fold(parts[index].Kind).Contains(needle, StringComparison.Ordinal)) return index;
            return null;
        }
        for (var index = 0; index < parts.Count; index++)
            if (palette.ChunkFor(parts[index].Kind)?.Key == "Chorus") return index;
        return null;
    }

    internal static bool IsVerse(SongPart part, SongChunkPalette palette) =>
        palette.ChunkFor(part.Kind)?.Key == "Verse";

    internal static bool IsSameRefrain(SongPart part, SongPart refrain) =>
        SwiftText.Same(part.Kind, refrain.Kind) && SwiftText.Same(part.Text, refrain.Text);

    // ── Копіювання пісень в інший Пісенник (5.3.8.2) ────────────────────────

    /// Що робити, якщо пісня з такою назвою вже є в приймальному збірнику:
    /// оригінал питає «Песня "%s" уже существует… Перезаписать?».
    public enum CopyConflict
    {
        Overwrite,
        Skip,
        Append,
    }

    /// Копіює вибрані пісні в інший Пісенник (змінює `destination` на місці).
    /// Повертає, скільки пісень додано і скільки перезаписано.
    public static (int Added, int Overwritten) CopySongs(IEnumerable<int> indices, SongBook source,
                                                         SongBook destination, Func<Song, CopyConflict> resolve)
    {
        int added = 0, overwritten = 0;
        foreach (var index in indices.OrderBy(index => index))
        {
            if (index < 0 || index >= source.Songs.Count) continue;
            var song = source.Songs[index].Copy();

            var existing = destination.Songs.FindIndex(other => SwiftText.SameIgnoringCase(other.Title, song.Title));
            if (existing >= 0)
            {
                var decision = resolve(song);
                if (decision == CopyConflict.Skip) continue;
                if (decision == CopyConflict.Overwrite)
                {
                    song.Index = existing;
                    destination.Songs[existing] = song;
                    overwritten += 1;
                    continue;
                }
            }
            song.Index = destination.Songs.Count;
            destination.Songs.Add(song);
            added += 1;
        }
        for (var position = 0; position < destination.Songs.Count; position++) destination.Songs[position].Index = position;
        return (added, overwritten);
    }

    // ── Внутрішнє ───────────────────────────────────────────────────────────

    private bool HasSong(int index) => index >= 0 && index < Book.Songs.Count;
    private bool HasGroup(int index) => index >= 0 && index < Book.Groups.Count;
    private bool HasPart(int songIndex, int partIndex) =>
        partIndex >= 0 && partIndex < Book.Songs[songIndex].Parts.Count;

    /// Індекси — це і є порядок пісень, тому після будь-якої перестановки
    /// їх треба переписати: `Song.Index` служить і розпізнавачем рядка списку.
    private void RenumberSongs()
    {
        for (var position = 0; position < Book.Songs.Count; position++)
        {
            Book.Songs[position].Index = position;
            RenumberParts(position);
        }
    }

    private void RenumberParts(int songIndex)
    {
        if (!HasSong(songIndex)) return;
        var parts = Book.Songs[songIndex].Parts;
        for (var position = 0; position < parts.Count; position++)
        {
            var part = parts[position];
            part.Index = position;
            parts[position] = part;
        }
    }

    private void RemapGroups(Func<int, int> transform)
    {
        foreach (var group in Book.Groups)
            group.SongIndices = group.SongIndices.Select(transform).Distinct().OrderBy(index => index).ToList();
    }

    /// «Назва (2)» — як оригінал іменує дублікат групи або пісні.
    internal static string CopyName(string name, IReadOnlyList<string> taken)
    {
        bool Taken(string candidate) => taken.Any(existing => SwiftText.Same(existing, candidate));
        if (!Taken(name)) return name;
        var counter = 2;
        while (Taken($"{name} ({counter})")) counter += 1;
        return $"{name} ({counter})";
    }
}
