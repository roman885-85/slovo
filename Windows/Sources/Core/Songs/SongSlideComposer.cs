// =============================================================================
//  SongSlideComposer.cs — частини пісні → слайди (з Songs/SongSlideComposer.swift)
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

/// Слайд пісні: сам слайд плюс те, звідки він узявся, — яка частина, яка
/// сторінка всередині частини і якого вона типу. Без цього список слайдів не
/// розфарбувати і не підсвітити в ньому поточний рядок.
public readonly record struct SongSlide(int PartIndex, int PageIndex, int PageCount, string PartKind,
                                        string? ChunkKey, SlideStyle.RGBA? Color, Slide Slide)
{
    public string Id => $"{PartIndex}.{PageIndex}";
    public bool IsSinglePage => PageCount == 1;
}

/// Перетворення частин пісні на слайди.
///
/// Головна відмінність від біблійного тексту: у пісні перенос рядка значущий.
/// Вірш можна склеїти в абзац і дати проектору перенести його самому, а куплет
/// так ламати не можна — рядки мають стояти там, де їх поставив автор.
/// Тому тут рядок — одиниця розбиття, а не слово.
public sealed class SongSlideComposer
{
    public record struct Options
    {
        /// Ділити довгу частину на кілька слайдів. В оригіналі це
        /// `VersSubDivide` у `[Songs]`; у користувача вимкнено — куплет
        /// цілком іде на один слайд, а розмір шрифту добирається.
        public bool SplitsLongParts;

        /// По скільки рядків на слайд, коли поділ увімкнено.
        public int LinesPerPage;

        /// Порожній рядок усередині частини — це розрив, який поставив
        /// укладач збірника. Таких частин небагато (176 на 161 226), але
        /// склеювати через них дві строфи неправильно.
        public bool BlankLineBreaksPage;

        /// Назва частини («Куплет 1», «Приспів») в адресі слайда.
        public bool ShowsPartName;

        /// Номер пісні в адресі. В оригіналі — `SongNameWithNumPP`.
        public bool ShowsNumber;
        public bool ShowsTitle;

        /// Коротке ім'я збірника в адресі, як `ModuleShortName` у Біблії.
        public bool ShowsBookShortName;

        /// Що дописати в кінець останньої частини пісні. В оригіналі —
        /// `SongsEndChunkPostText`, у користувача це `***`.
        public string EndMarker;

        /// Номер сторінки («2/3»), коли частина не вмістилася на один слайд.
        public bool ShowsPageNumber;

        public Options() : this(splitsLongParts: false) { }

        public Options(bool splitsLongParts = false,
                       int linesPerPage = 4,
                       bool blankLineBreaksPage = true,
                       bool showsPartName = true,
                       bool showsNumber = false,
                       bool showsTitle = false,
                       bool showsBookShortName = false,
                       string endMarker = "",
                       bool showsPageNumber = true)
        {
            SplitsLongParts = splitsLongParts;
            LinesPerPage = Math.Max(1, linesPerPage);
            BlankLineBreaksPage = blankLineBreaksPage;
            ShowsPartName = showsPartName;
            ShowsNumber = showsNumber;
            ShowsTitle = showsTitle;
            ShowsBookShortName = showsBookShortName;
            EndMarker = endMarker;
            ShowsPageNumber = showsPageNumber;
        }

        public Options(IniSettings config)
            : this(splitsLongParts: config.Bool("VersSubDivide", "Songs") ?? false,
                   linesPerPage: 4,
                   blankLineBreaksPage: true,
                   showsPartName: true,
                   showsNumber: config.Bool("SongNameWithNumPP", "settings") ?? false,
                   showsTitle: false,
                   showsBookShortName: false,
                   endMarker: config.String("SongsEndChunkPostText", "settings") ?? "",
                   showsPageNumber: true) { }
    }

    public Options Settings;
    public SongChunkPalette Palette;

    public SongSlideComposer(Options? options = null, SongChunkPalette? palette = null)
    {
        Settings = options ?? new Options();
        Palette = palette ?? SongChunkPalette.FactoryDefault;
    }

    public SongSlideComposer(IniSettings config) : this(new Options(config), new SongChunkPalette(config)) { }

    // ── Одна частина ────────────────────────────────────────────────────────

    /// Слайди однієї частини пісні.
    ///
    /// `isLastPart` вмикає хвостову позначку кінця пісні — її ставлять лише
    /// після останньої частини, інакше `***` з'являлося б після кожного куплета.
    public List<SongSlide> Slides(SongPart part, Song song, string bookShortName = "", bool isLastPart = false)
    {
        var pages = Pages(part);
        var chunk = Palette.ChunkFor(part.Kind);
        if (pages.Count == 0)
        {
            return
            [
                new SongSlide(part.Index, 0, 1, part.Kind, chunk?.Key, chunk?.Color,
                              new Slide(mainText: "",
                                        reference: Reference(part, song, bookShortName, 0, 1),
                                        isBlank: true)),
            ];
        }

        var result = new List<SongSlide>(pages.Count);
        for (var pageIndex = 0; pageIndex < pages.Count; pageIndex++)
        {
            var text = string.Join("\n", pages[pageIndex]);
            if (isLastPart && pageIndex == pages.Count - 1 && Settings.EndMarker.Length > 0)
                text += "\n" + Settings.EndMarker;
            var slide = new Slide(mainText: text, reference: Reference(part, song, bookShortName, pageIndex, pages.Count));
            result.Add(new SongSlide(part.Index, pageIndex, pages.Count, part.Kind, chunk?.Key, chunk?.Color, slide));
        }
        return result;
    }

    /// Усі слайди пісні підряд — у тому порядку, в якому частини лежать у файлі.
    public List<SongSlide> Slides(Song song, string bookShortName = "")
    {
        var result = new List<SongSlide>();
        for (var position = 0; position < song.Parts.Count; position++)
            result.AddRange(Slides(song.Parts[position], song, bookShortName, position == song.Parts.Count - 1));
        return result;
    }

    /// Слайди однієї частини за її номером — те, що потрібно обробнику
    /// «частину вибрано» у списку.
    public List<SongSlide> SlidesForPart(int index, Song song, string bookShortName = "")
    {
        if (index < 0 || index >= song.Parts.Count) return new List<SongSlide>();
        return Slides(song.Parts[index], song, bookShortName, index == song.Parts.Count - 1);
    }

    // ── Розбиття на сторінки ────────────────────────────────────────────────

    /// Рядки частини, розкладені по слайдах.
    ///
    /// Порожні рядки по краях частини у файлах трапляються майже завжди —
    /// це залишок роздільника, а не порожній рядок на екрані.
    public List<List<string>> Pages(SongPart part)
    {
        var lines = part.Lines.ToList();
        while (lines.Count > 0 && lines[^1].TrimWhitespaces().Length == 0) lines.RemoveAt(lines.Count - 1);
        while (lines.Count > 0 && lines[0].TrimWhitespaces().Length == 0) lines.RemoveAt(0);
        lines = lines.Select(line => line.TrimWhitespaces()).ToList();
        if (lines.Count == 0) return new List<List<string>>();

        // Спершу жорсткі розриви — порожні рядки всередині частини.
        var blocks = new List<List<string>> { new() };
        foreach (var line in lines)
        {
            if (Settings.BlankLineBreaksPage && line.Length == 0)
            {
                if (blocks[^1].Count > 0) blocks.Add(new List<string>());
            }
            else
            {
                blocks[^1].Add(line);
            }
        }
        blocks.RemoveAll(block => block.Count == 0);
        if (!Settings.SplitsLongParts) return blocks;

        // Потім — поділ довгих блоків на рівні сторінки. Хвіст в один
        // рядок виглядає сиротою, тому сторінки вирівнюємо за числом.
        var result = new List<List<string>>();
        foreach (var block in blocks)
        {
            if (block.Count <= Settings.LinesPerPage)
            {
                result.Add(block);
                continue;
            }
            var pageCount = (int)Math.Ceiling((double)block.Count / Settings.LinesPerPage);
            var perPage = (int)Math.Ceiling((double)block.Count / pageCount);
            for (var start = 0; start < block.Count; start += perPage)
                result.Add(block.GetRange(start, Math.Min(perPage, block.Count - start)));
        }
        return result;
    }

    // ── Адреса слайда ───────────────────────────────────────────────────────

    /// Адреса пісенного слайда. Назва частини тут обов'язкова: в оригіналі
    /// зал бачить саме «Куплет 2», і за ним же оператор розуміє, де він.
    public string Reference(SongPart part, Song song, string bookShortName, int page, int pageCount)
    {
        var pieces = new List<string>();

        if (Settings.ShowsNumber || Settings.ShowsTitle)
        {
            var head = "";
            if (Settings.ShowsNumber) head = song.Number.ToString(CultureInfo.InvariantCulture) + ".";
            if (Settings.ShowsTitle) head = head.Length == 0 ? song.Title : head + " " + song.Title;
            if (head.Length > 0) pieces.Add(head);
        }
        if (Settings.ShowsPartName && part.Kind.TrimWhitespaces().Length > 0)
            pieces.Add(part.Kind.TrimWhitespaces());
        if (Settings.ShowsPageNumber && pageCount > 1)
            pieces.Add($"{page + 1}/{pageCount}");
        if (Settings.ShowsBookShortName && bookShortName.Length > 0)
            pieces.Add(bookShortName);
        return string.Join(" · ", pieces);
    }
}
