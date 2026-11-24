// =============================================================================
//  SongTextFile.cs — розмітка тексту пісні та обмін текстовим файлом
//  (з Songs/SongTextFile.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

// ── Розмітка тексту пісні ──────────────────────────────────────────────────

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
public static class SongTextMarkup
{
    public const char PartMarker = '#';
    public const string AlignKey = "$Align$";

    /// Розібрати суцільний текст пісні на частини.
    public static List<SongPart> Parts(string text, SongChunkPalette? palette = null)
    {
        palette ??= SongChunkPalette.FactoryDefault;
        var lines = NormalizedLines(text);
        var headings = HeadingNames(palette);

        var parts = new List<SongPart>();
        var kind = "";
        var align = SongPartAlign.Default;
        var buffer = new List<string>();
        var opened = false;

        void Flush()
        {
            // Текст частини зберігаємо як є, аж до порожніх рядків по
            // краях: у пісенниках вони стоять навмисно і дають відступ на
            // слайді. Відкидаємо лише порожній «хвіст» перед першим «#» —
            // він не частина пісні, а роздільник.
            var body = opened ? buffer : TrimBlankEdges(buffer);
            if (!opened && body.Count == 0) return;
            parts.Add(new SongPart(parts.Count, kind, string.Join("\r\n", body), align));
            kind = "";
            align = SongPartAlign.Default;
            buffer = new List<string>();
            opened = false;
        }

        foreach (var line in lines)
        {
            var trimmed = line.TrimWhitespaces();

            if (line.StartsWith(PartMarker))
            {
                Flush();
                // Назва частини — усе, що після «#», без обрізання: у
                // збірниках трапляються «Verse » і «Куплет 1. » з пробілом
                // на кінці, і обмін не має їх міняти.
                kind = SwiftText.DropFirstCharacters(line, 1);
                opened = true;
                continue;
            }
            // «Части песни программа определяет по наличию символу „#“ в
            // начале строки, ИЛИ ключевым словам» (5.3.9.6) — тобто обидві
            // ознаки працюють в одному тексті. Хибних спрацьовувань це не
            // дає: `IsHeading` порівнює рядок цілком, тому «Мостом
            // шли» ключовим словом не стане, а стане ним лише рядок,
            // який і є «Мост» або «Куплет 2».
            if (IsHeading(trimmed, headings))
            {
                Flush();
                kind = trimmed;
                opened = true;
                continue;
            }
            if (Parameter(AlignKey, trimmed) is { } value)
            {
                align = SongPartAligns.FromExportName(value) ?? SongPartAlign.Default;
                continue;
            }
            buffer.Add(line);
        }
        Flush();
        return parts;
    }

    /// Зібрати текст назад — те, що видно в полі «Текст пісні».
    ///
    /// Між частинами порожній рядок не вставляється: він був би невідрізненним від
    /// порожнього рядка, яким закінчується сам текст частини, і обмін перестав
    /// би бути точним. Розділяє частини символ «#», і цього досить.
    public static string Text(IEnumerable<SongPart> parts) => string.Join("\r\n", Lines(parts));

    /// Ті самі рядки, але окремо — так їх зручно вкладати в
    /// текстовий файл цілого Пісенника.
    internal static List<string> Lines(IEnumerable<SongPart> parts)
    {
        var result = new List<string>();
        foreach (var part in parts)
        {
            result.Add($"{PartMarker}{part.Kind}");
            if (part.Align.ExportName() is { } name) result.Add($"{AlignKey}={name}");
            if (part.Text.Length > 0) result.AddRange(NormalizedLines(part.Text));
        }
        return result;
    }

    // ── Внутрішнє ───────────────────────────────────────────────────────────

    internal static List<string> NormalizedLines(string text) =>
        text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n').ToList();

    internal static List<string> TrimBlankEdges(IReadOnlyList<string> lines)
    {
        var result = lines.ToList();
        while (result.Count > 0 && result[0].TrimWhitespaces().Length == 0) result.RemoveAt(0);
        while (result.Count > 0 && result[^1].TrimWhitespaces().Length == 0) result.RemoveAt(result.Count - 1);
        return result;
    }

    /// `$Align$=Left` → `Left`. Регістр ключа не важливий: у файлі пісенника він
    /// написаний великими, а в текстовому експорті — мішаним.
    internal static string? Parameter(string key, string line)
    {
        var trimmed = line.TrimWhitespaces();
        var eq = trimmed.IndexOf('=');
        if (!trimmed.StartsWith('$') || eq < 0) return null;
        var name = trimmed[..eq];
        if (!SwiftText.SameIgnoringCase(name, key)) return null;
        return trimmed[(eq + 1)..];
    }

    internal static HashSet<string> HeadingNames(SongChunkPalette palette)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var chunk in palette.Chunks)
        {
            names.Add(SongChunkPalette.Normalize(chunk.Key));
            foreach (var name in chunk.Names) names.Add(SongChunkPalette.Normalize(name));
        }
        names.Remove("");
        return names;
    }

    /// Рядок — це заголовок частини, якщо він короткий і цілком складається з
    /// ключового слова з номером: «Припев», «Куплет 2», «Verse 3.».
    public static bool IsHeading(string line, IReadOnlySet<string> names)
    {
        if (line.Length == 0 || SwiftText.CharacterCount(line) > 32) return false;
        return names.Contains(SongChunkPalette.Normalize(line));
    }

    // ── Розмітка для розфарбовування поля «Текст пісні» (5.3.9.6) ───────────

    /// Чим рядок є для розбору. Рівно це й фарбує вікно правки пісні:
    /// «если это ключевое слово, то программа его окрашивает в цвет,
    /// указанный в настройках».
    public readonly record struct Role(Role.Kinds Kind, SlideStyle.RGBA? Color = null)
    {
        public enum Kinds
        {
            Body,             // звичайний рядок тексту
            Heading,          // «#Своя назва» — не ключове слово
            KeywordHeading,   // ключове слово і його колір з палітри (Color)
            Parameter,        // «$Align$=Left»
        }

        public static readonly Role Body = new(Kinds.Body);
        public static readonly Role Heading = new(Kinds.Heading);
        public static readonly Role Parameter = new(Kinds.Parameter);
        public static Role KeywordHeading(SlideStyle.RGBA color) => new(Kinds.KeywordHeading, color);
    }

    /// Рядок тексту пісні і його місце в ньому. Зсуви — в одиницях UTF-16,
    /// бо їх чекає поле правки, якому ця розмітка і потрібна.
    public readonly record struct Line(int Start, int Length, Role Role);

    /// Розібрати текст на рядки з їхніми ролями — тим самим правилом, що й
    /// `Parts`. Спільне правило важливіше за спільну функцію: якщо розфарбовування
    /// почне розходитися з розбором, воно обманюватиме оператора.
    public static List<Line> Markup(string text, SongChunkPalette palette)
    {
        var headings = HeadingNames(palette);
        var result = new List<Line>();
        var index = 0;

        while (index < text.Length)
        {
            // `getLineStart(_:end:contentsEnd:for:)`: кінці рядка NSString —
            // \n, \r, \r\n, U+0085, U+2028, U+2029.
            var contentsEnd = index;
            while (contentsEnd < text.Length && !IsLineTerminator(text[contentsEnd])) contentsEnd++;
            var lineEnd = contentsEnd;
            if (lineEnd < text.Length)
                lineEnd += text[lineEnd] == '\r' && lineEnd + 1 < text.Length && text[lineEnd + 1] == '\n' ? 2 : 1;
            var length = contentsEnd - index;
            var start = index;
            index = lineEnd > index ? lineEnd : index + 1;
            if (length <= 0) continue;

            var line = text.Substring(start, length);
            var trimmed = line.TrimWhitespaces();
            Role role;

            if (line.StartsWith(PartMarker))
            {
                var name = SwiftText.DropFirstCharacters(line, 1).TrimWhitespaces();
                role = palette.ChunkFor(name) is { } chunk ? Role.KeywordHeading(chunk.Color) : Role.Heading;
            }
            else if (IsHeading(trimmed, headings))
            {
                role = palette.ChunkFor(trimmed) is { } chunk ? Role.KeywordHeading(chunk.Color) : Role.Heading;
            }
            else if (IsParameter(trimmed))
            {
                role = Role.Parameter;
            }
            else
            {
                role = Role.Body;
            }
            if (role != Role.Body) result.Add(new Line(start, length, role));
        }
        return result;
    }

    private static bool IsLineTerminator(char c) => c is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029';

    /// Рядок виду «$Ключ$=значення»: «Название параметра всегда начинается и
    /// заканчивается символом „$“, а после него идёт символ „=“» (5.3.9.6).
    internal static bool IsParameter(string line)
    {
        var eq = line.IndexOf('=');
        if (!line.StartsWith('$') || eq < 0) return false;
        var name = line[..eq];
        return name.EndsWith('$') && SwiftText.CharacterCount(name) > 2;
    }
}

// ── Експорт та імпорт текстового файла ─────────────────────────────────────

/// Експорт Пісенника в текстовий файл та імпорт із нього (посібник, 5.3.8.4).
///
/// Службові позначки взято з самої програми — в її коді лежать рівно ці
/// рядки: `$AltTitle$=`, `$Poet$=`, `$Composer$=`, `$DateCreate$=`, `$Tune$=`,
/// `$ID$=`, `$Note$=`, `#` для частини, `$Align$=Left|Right|Center` і `---` як
/// ознака початку пісні. Порядок такий самий, як порядок полів у самому файлі
/// пісенника, тому обмін виходить без втрат.
public static class SongBookTextFile
{
    /// Який номер друкувати у варіанті «без службової інформації»:
    /// посібник дозволяє «номер песен по порядку, или номер в Песеннике».
    public enum Numbering
    {
        Ordinal,      // порядковий номер
        Catalog,      // «Номер у збірнику» ($ID$)
    }

    public enum ImportMode
    {
        Append,       // «Додати пісні з текстового файла в кінець»
        Replace,      // «Видалити всі пісні… і завантажити з текстового файла»
    }

    public const string SongSeparator = "---";

    // ── Експорт ─────────────────────────────────────────────────────────────

    /// «Разом зі службовою інформацією» — режим для перенесення на інший
    /// комп'ютер: відновлюється все, крім груп.
    public static string ExportWithServiceInfo(SongBook book)
    {
        var output = new StringBuilder();
        foreach (var song in book.Songs)
        {
            // Жодного зайвого рядка: усе, що стоїть між «---» і наступним
            // «---», належить пісні. Інакше порожні рядки в кінці останньої
            // частини не можна було б відрізнити від відступу між піснями.
            var lines = new List<string> { SongSeparator, song.Title };
            Append(lines, "$AltTitle$", song.AlternateTitle);
            Append(lines, "$Poet$", song.Author);
            Append(lines, "$Composer$", song.Composer);
            Append(lines, "$DateCreate$", song.Note);
            Append(lines, "$Tune$", song.Tune);
            Append(lines, "$ID$", song.CatalogNumberText);
            lines.AddRange(SongTextMarkup.Lines(song.Parts));
            output.Append(string.Join("\r\n", lines)).Append("\r\n");
        }
        return output.ToString();
    }

    /// «Без службової інформації» — лише назви і тексти, «подходит для
    /// дальнейшей обработки для печати, или просто чтения».
    public static string ExportPlain(SongBook book, Numbering numbering = Numbering.Ordinal)
    {
        var output = new StringBuilder();
        foreach (var song in book.Songs)
        {
            var ordinal = song.Number.ToString(System.Globalization.CultureInfo.InvariantCulture);
            var number = numbering == Numbering.Ordinal
                ? ordinal
                : song.CatalogNumberText.Length == 0 ? ordinal : song.CatalogNumberText;
            output.Append($"{number}. {song.Title}\r\n\r\n");
            foreach (var part in song.Parts)
            {
                var body = part.Text.Replace("\r\n", "\n");
                output.Append(body.Replace("\n", "\r\n")).Append("\r\n\r\n");
            }
        }
        return output.ToString();
    }

    public static void Write(string text, string path)
    {
        // UTF-8 з міткою порядку байтів: так текст відкриється і в Блокноті
        // Windows, куди його найчастіше й відносять.
        var data = new List<byte> { 0xEF, 0xBB, 0xBF };
        data.AddRange(new UTF8Encoding(false).GetBytes(text));
        SwiftPath.WriteAtomically(path, data.ToArray());
    }

    private static void Append(List<string> lines, string key, string value)
    {
        var clean = value.TrimWhitespacesAndNewlines();
        if (clean.Length == 0) return;
        lines.Add($"{key}={clean}");
    }

    // ── Імпорт ──────────────────────────────────────────────────────────────

    /// Розібрати текстовий файл на пісні. Ознака початку пісні — рядок із
    /// дефісів; усе до першого такого рядка пропускається.
    public static List<Song> Songs(string text, SongChunkPalette? palette = null)
    {
        palette ??= SongChunkPalette.FactoryDefault;
        var lines = SongTextMarkup.NormalizedLines(StripBOM(text));
        // Файл закінчується переносом рядка, і розбиття дає зайвий порожній
        // елемент у хвості. Він не порожній рядок пісні, а кінець файла.
        if (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);

        var blocks = new List<List<string>>();
        List<string>? current = null;

        foreach (var line in lines)
        {
            if (IsSeparator(line))
            {
                if (current != null) blocks.Add(current);
                current = new List<string>();
                continue;
            }
            current?.Add(line);
        }
        if (current != null) blocks.Add(current);

        // Порожній блок — це теж пісня: у збірниках користувача є пісні
        // без назви і без частин (п'ять таких у `glory.vbm`), і губити їх
        // при перенесенні не можна, інакше поїдуть усі номери.
        return blocks.Select((block, index) => SongFrom(block, index, palette)).ToList();
    }

    /// Улити пісні в Пісенник (змінює `book` на місці). Повертає, скільки пісень додано.
    public static int ImportSongs(string text, SongBook book, ImportMode mode, SongChunkPalette? palette = null)
    {
        var incoming = Songs(text, palette);
        if (incoming.Count == 0) return 0;

        if (mode == ImportMode.Append)
        {
            book.Songs.AddRange(incoming);
        }
        else
        {
            book.Songs = incoming;
            // Групи тримають номери пісень; після повної заміни ці номери
            // вказують у порожнечу, тому склад груп очищаємо, а самі
            // групи лишаємо — їх користувач налаштовував руками.
            foreach (var group in book.Groups) group.SongIndices = new List<int>();
        }
        for (var position = 0; position < book.Songs.Count; position++) book.Songs[position].Index = position;
        return incoming.Count;
    }

    /// Ознака початку пісні — рівно три дефіси і нічого більше.
    ///
    /// Перевіряти «рядок із дефісів» не можна: у `sion.vbm` усередині пісні
    /// «O schimbare în viața» є рядок `----`, і за несуворим правилом
    /// пісня розвалювалася надвоє.
    internal static bool IsSeparator(string line) => line.TrimWhitespaces() == SongSeparator;

    internal static string StripBOM(string text) => text.StartsWith('\uFEFF') ? text[1..] : text;

    private static Song SongFrom(List<string> block, int index, SongChunkPalette palette)
    {
        // Перший рядок блоку — назва пісні, і вона буває порожньою (п'ять
        // таких пісень у `glory.vbm`). Порожні рядки зверху зрізати не можна:
        // ми прийняли б за назву перший рядок тексту.
        //
        // Назву пишемо як є: у «lieder von liederbuch.vbm» у пісень
        // початковий пробіл, і обмін не має його з'їдати.
        var lines = block.ToList();
        var title = "";
        if (lines.Count > 0)
        {
            title = lines[0];
            lines.RemoveAt(0);
        }
        var song = new Song(index, title);

        // Атрибути йдуть одразу за назвою і кінчаються на першому рядку,
        // який не «$Ключ$=значення». Усе інше — текст пісні.
        var body = new List<string>();
        var inAttributes = true;

        foreach (var line in lines)
        {
            var trimmed = line.TrimWhitespaces();
            if (inAttributes && trimmed.Length == 0) continue;
            if (inAttributes && Attribute(trimmed) is { } pair)
            {
                Apply(pair, song);
                continue;
            }
            inAttributes = false;
            body.Add(line);
        }

        song.Parts = SongTextMarkup.Parts(string.Join("\n", body), palette);
        for (var position = 0; position < song.Parts.Count; position++)
        {
            var part = song.Parts[position];
            part.Index = position;
            song.Parts[position] = part;
        }
        return song;
    }

    private static (string Key, string Value)? Attribute(string line)
    {
        var eq = line.IndexOf('=');
        if (!line.StartsWith('$') || eq < 0) return null;
        var key = line[..eq].ToLowerInvariant();
        // `$Align$` стосується частини пісні, а не самої пісні: він не має
        // проковтуватися розбором атрибутів, інакше перша частина втратить
        // вирівнювання.
        if (key == "$align$") return null;
        return (key, line[(eq + 1)..].TrimWhitespaces());
    }

    private static void Apply((string Key, string Value) pair, Song song)
    {
        switch (pair.Key)
        {
            case "$alttitle$": song.AlternateTitle = pair.Value; break;
            case "$poet$": case "$author$": song.Author = pair.Value; break;
            case "$composer$": song.Composer = pair.Value; break;
            // П'яте поле файла пісенника — це дата: в усіх збірниках
            // користувача в ньому стоїть «03.12.2013» і подібне. Старе ім'я
            // `$Note$` приймаємо теж, щоб читалися чужі вивантаження.
            case "$datecreate$": case "$note$": song.Note = pair.Value; break;
            case "$tune$": song.SetProperty("$TUNE$", pair.Value); break;
            case "$id$": song.SetProperty("$ID$", pair.Value); break;
            default: song.SetProperty(pair.Key.ToUpperInvariant(), pair.Value); break;
        }
    }
}
