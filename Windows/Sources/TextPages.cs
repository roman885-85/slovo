// =============================================================================
//  TextPages.cs — розбиття тексту на слайди і слайди пісні
// =============================================================================
//  Перенесено з PlainTextDocument.swift (сторінки довгого тексту й довгого
//  вірша: «Розбивати на сторінки», «Розбивати на вірші», «Автоперенос слів»,
//  «мінімальний відсоток заповнення») і SongSlideComposer.swift (куплет —
//  рядок за рядком, порожній рядок — розрив сторінки, назва частини в
//  адресі). Палітра частин пісні — `[SongChunksColors]` із Slovo.ini.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Linq;

namespace Slovo;

/// Вміст одного слайда — те, що реально виводиться на екран.
public sealed record Slide(string MainText, List<string> SecondaryTexts, string Reference, bool IsBlank)
{
    public static readonly Slide Blank = new("", new List<string>(), "", true);

    public static Slide Of(string main, string reference = "", List<string>? secondary = null) =>
        new(main, secondary ?? new List<string>(), reference, main.Length == 0 && (secondary == null || secondary.All(s => s.Length == 0)));

    public bool IsEmptyText => MainText.Length == 0 && SecondaryTexts.All(s => s.Length == 0) && Reference.Length == 0;
}

/// Як довгий текст лягає на слайди («Опції роботи» режиму).
public sealed class Pagination
{
    /// `PageSubDivide` — «Розбивати на сторінки».
    public bool SplitsIntoPages { get; set; } = true;
    /// `VersSubDivide` — «Розбивати на вірші» (у тексті одиниця — рядок).
    public bool SplitsIntoParagraphs { get; set; }
    /// `WordWrap` — «Автоперенос слів».
    public bool WrapsWords { get; set; } = true;
    public bool BlankLineBreaksPage { get; set; } = true;
    public int CharactersPerLine { get; set; } = 21;
    public int LinesPerPage { get; set; } = 6;
    /// `percentfillingpage` — хвіст, що заповнить слайд менше, окремою сторінкою не робимо.
    public double MinimumFillPercent { get; set; } = 30;

    /// Скільки знаків і рядків уміщається на слайд за мінімального кегля —
    /// оцінка з геометрії: ширина знака ≈ половина кегля.
    public static (int CharactersPerLine, int LinesPerPage) Capacity(double slideWidth, double slideHeight,
        double minFontFraction, double lineSpacing, double horizontalInset, double verticalInset)
    {
        var font = Math.Max(slideHeight * minFontFraction, 1);
        var lineHeight = font * (1 + Math.Max(lineSpacing, 0));
        var usableHeight = slideHeight * (1 - 2 * Math.Clamp(verticalInset, 0, 0.4));
        var usableWidth = slideWidth * (1 - 2 * Math.Clamp(horizontalInset, 0, 0.4));
        return (Math.Max(8, (int)(usableWidth / (font * 0.5))), Math.Max(1, (int)(usableHeight / lineHeight)));
    }

    public Pagination Clone() => (Pagination)MemberwiseClone();
}

/// Модуль «Текст»: заголовок (на місці адреси) і сам текст (на місці цитати).
public sealed class TextDocument
{
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";

    public TextDocument() { }
    public TextDocument(string title, string body) { Title = title; Body = body; }

    public bool IsEmpty => Title.Trim().Length == 0 && Body.Trim().Length == 0;

    /// Рядок для Плану та Історії: «Дорогие! - Настройтесь на …».
    public string Summary(int limit = 120)
    {
        var head = Title.Trim();
        var tail = Snippet(limit);
        if (head.Length == 0) return tail;
        if (tail.Length == 0) return head;
        return head + " - " + tail;
    }

    public string Snippet(int limit = 120)
    {
        var flat = string.Join(" ", Body.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0));
        return flat.Length > limit ? flat[..limit] + "…" : flat;
    }

    /// Текст, розкладений по сторінках. Кожна сторінка — один слайд.
    public List<string> Pages(Pagination pagination)
    {
        var lines = NormalizedLines(Body);
        if (lines.Count == 0) return Title.Trim().Length == 0 ? new List<string>() : new List<string> { "" };
        var blocks = Blocks(lines, pagination);
        if (!pagination.SplitsIntoPages) return blocks.Select(b => string.Join("\n", b)).ToList();
        return blocks.SelectMany(b => Paginate(b, pagination)).Select(p => string.Join("\n", p)).ToList();
    }

    public List<Slide> Slides(Pagination pagination)
    {
        var texts = Pages(pagination);
        var head = Title.Trim();
        return texts.Select(text => new Slide(text, new List<string>(), head, text.Length == 0 && head.Length == 0)).ToList();
    }

    public static List<string> NormalizedLines(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Select(l => l.Trim()).ToList();
        while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines;
    }

    static List<List<string>> Blocks(List<string> lines, Pagination pagination)
    {
        if (pagination.SplitsIntoParagraphs) return lines.Where(l => l.Length > 0).Select(l => new List<string> { l }).ToList();
        if (!pagination.BlankLineBreaksPage || !pagination.SplitsIntoPages) return new List<List<string>> { lines };
        var blocks = new List<List<string>> { new() };
        foreach (var line in lines)
        {
            if (line.Length == 0) { if (blocks[^1].Count > 0) blocks.Add(new List<string>()); }
            else blocks[^1].Add(line);
        }
        blocks.RemoveAll(b => b.Count == 0);
        return blocks;
    }

    /// Один шматок, розкладений по сторінках.
    public static List<List<string>> Paginate(List<string> block, Pagination pagination)
    {
        var capacity = pagination.LinesPerPage;
        var budget = capacity * pagination.CharactersPerLine;
        var units = new List<(string Text, bool Continuation)>();
        foreach (var line in block)
        {
            if (DisplayHeight(line, pagination) <= capacity || !pagination.WrapsWords) units.Add((line, false));
            else
            {
                var chunks = Chunks(line, budget);
                for (var i = 0; i < chunks.Count; i++) units.Add((chunks[i], i > 0));
            }
        }

        var pages = new List<List<string>>();
        var current = new List<string>();
        var used = 0;
        foreach (var unit in units)
        {
            var added = DisplayHeight(unit.Text, pagination);
            if (current.Count > 0 && used + added > capacity)
            {
                pages.Add(current);
                current = new List<string>();
                used = 0;
            }
            if (unit.Continuation && current.Count > 0) current[^1] += " " + unit.Text;
            else current.Add(unit.Text);
            used = current.Sum(l => DisplayHeight(l, pagination));
        }
        if (current.Count > 0) pages.Add(current);

        if (pages.Count > 1)
        {
            var tail = pages[^1].Sum(l => DisplayHeight(l, pagination));
            var fill = (double)tail / capacity * 100;
            if (fill < pagination.MinimumFillPercent)
            {
                var last = pages[^1];
                pages.RemoveAt(pages.Count - 1);
                pages[^1].AddRange(last);
            }
        }
        return pages;
    }

    static int DisplayHeight(string line, Pagination pagination)
    {
        if (!pagination.WrapsWords) return 1;
        var count = line.Length;
        if (count <= pagination.CharactersPerLine) return 1;
        return (int)Math.Ceiling((double)count / pagination.CharactersPerLine);
    }

    /// Довгий рядок, розрізаний за межами слів.
    public static List<string> Chunks(string line, int budget)
    {
        var limit = Math.Max(1, budget);
        if (line.Length <= limit) return new List<string> { line };
        var result = new List<string>();
        var current = "";
        foreach (var word in line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var piece = word;
            while (piece.Length > limit)
            {
                if (current.Length > 0) { result.Add(current); current = ""; }
                result.Add(piece[..limit]);
                piece = piece[limit..];
            }
            if (current.Length == 0) current = piece;
            else if (current.Length + 1 + piece.Length <= limit) current += " " + piece;
            else { result.Add(current); current = piece; }
        }
        if (current.Length > 0) result.Add(current);
        return result.Count == 0 ? new List<string> { line } : result;
    }
}

/// Один тип частини пісні: ключ, колір і всі його назви.
public sealed record SongChunk(string Key, RGBA Color, List<string> Names)
{
    public string Title => Names.Count > 0 ? Names[0] : Key;
}

/// Палітра частин пісні — `[SongChunksColors]`: назва частини задає колір у списку.
public sealed class SongPalette
{
    public List<SongChunk> Chunks { get; }
    readonly List<(string Name, string Key)> _aliases;
    readonly Dictionary<string, string> _exact;

    static readonly (string Name, string Key)[] Extra =
    {
        ("Хор", "Chorus"), ("Бридж", "Bridge"), ("Концовка", "End"), ("Кінцівка", "End"), ("Schluss", "End"),
        ("Verse", "Verse"), ("Chorus", "Chorus"), ("Bridge", "Bridge"), ("Intro", "Intro"), ("Ending", "End"),
        ("Куплет", "Verse"), ("Приспів", "Chorus"), ("Припев", "Chorus"),
    };

    public SongPalette(List<SongChunk> chunks)
    {
        Chunks = chunks;
        _aliases = new List<(string, string)>();
        var seen = new HashSet<string>();
        foreach (var chunk in chunks)
            foreach (var name in chunk.Names)
            {
                var normalized = Normalize(name);
                if (normalized.Length > 0 && seen.Add(normalized)) _aliases.Add((normalized, chunk.Key));
            }
        foreach (var chunk in chunks)
        {
            var normalized = Normalize(chunk.Key);
            if (normalized.Length > 0 && seen.Add(normalized)) _aliases.Add((normalized, chunk.Key));
        }
        foreach (var (name, key) in Extra)
        {
            var normalized = Normalize(name);
            if (normalized.Length > 0 && seen.Add(normalized)) _aliases.Add((normalized, key));
        }
        _aliases.Sort((a, b) => b.Name.Length.CompareTo(a.Name.Length));
        _exact = new Dictionary<string, string>();
        foreach (var (name, key) in _aliases) _exact.TryAdd(name, key);
    }

    /// Тип частини за її назвою: спершу точний збіг, потім найдовший префікс
    /// («Куплет 1.», «Припев:»).
    public SongChunk? ChunkFor(string kind)
    {
        var normalized = Normalize(kind);
        if (normalized.Length == 0) return null;
        if (_exact.TryGetValue(normalized, out var exactKey)) return Chunks.FirstOrDefault(c => c.Key == exactKey);
        foreach (var (name, key) in _aliases)
            if (normalized.StartsWith(name, StringComparison.Ordinal)) return Chunks.FirstOrDefault(c => c.Key == key);
        return null;
    }

    public RGBA? ColorFor(string kind) => ChunkFor(kind)?.Color;

    static string Normalize(string text)
    {
        var result = new System.Text.StringBuilder();
        foreach (var ch in text.ToLowerInvariant().Replace('ё', 'е'))
            if (char.IsLetter(ch)) result.Append(ch);
        return result.ToString();
    }

    /// Розбір секції `[SongChunksColors]`: `Verse=16747383,Куплет,Стих,…`.
    public static SongPalette FromIni(string iniText)
    {
        var chunks = new List<SongChunk>();
        var inSection = false;
        foreach (var raw in iniText.Split('\n'))
        {
            var line = raw.Trim().TrimStart('﻿');
            if (line.StartsWith('['))
            {
                inSection = line.Equals("[SongChunksColors]", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!inSection) continue;
            var eq = line.IndexOf('=');
            if (eq <= 0) continue;
            var key = line[..eq].Trim();
            var parts = line[(eq + 1)..].Split(',');
            if (parts.Length == 0 || !int.TryParse(parts[0].Trim(), out var tColor)) continue;
            chunks.Add(new SongChunk(key, RGBA.FromTColor(tColor), parts.Skip(1).Select(p => p.Trim()).Where(p => p.Length > 0).ToList()));
        }
        return chunks.Count > 0 ? new SongPalette(chunks) : FactoryDefault;
    }

    public static readonly SongPalette FactoryDefault = new(new List<SongChunk>
    {
        new("Verse", RGBA.FromTColor(16747383), new List<string> { "Куплет", "Стих", "Verse" }),
        new("Chorus", RGBA.FromTColor(9731541), new List<string> { "Припев", "Приспів", "Chorus", "Refrain" }),
        new("Pre-Chorus", RGBA.FromTColor(8927667), new List<string> { "Запев", "Заспів", "Соло" }),
        new("Bridge", RGBA.FromTColor(12341183), new List<string> { "Мост", "Міст", "Bridge" }),
        new("Tag", RGBA.FromTColor(15728814), new List<string> { "Описание", "Опис", "Description" }),
        new("Intro", RGBA.FromTColor(6723891), new List<string> { "Вступление", "Вступ", "Intro" }),
        new("End", RGBA.FromTColor(18137), new List<string> { "Кода", "Кінцівка", "End" }),
    });

    /// Палітра з умовчань «Слова» (вшитий Slovo.ini).
    public static SongPalette Default()
    {
        var ini = Embedded.Text("Slovo.ini");
        return ini.Length > 0 ? FromIni(ini) : FactoryDefault;
    }
}

/// Слайд пісні: сам слайд плюс те, звідки він узявся.
public sealed record SongSlide(int PartIndex, int PageIndex, int PageCount, string PartKind, RGBA? Color, Slide Slide)
{
    public string Id => PartIndex + "." + PageIndex;
}

/// Як підписувати пісню в списку: `SongNameWithNumInCollection`, `SongNameDotAfterNum`,
/// `SongNameWithNumInCollectionInBrackets`.
public static class SongTitleFormat
{
    public static string Number(int number, bool dot, bool brackets) =>
        brackets ? "(" + number + ")" : dot ? number + "." : number.ToString();

    public static string Title(int index, string title, bool showsNumber, bool dot, bool brackets) =>
        showsNumber ? Number(index + 1, dot, brackets) + " " + title : title;
}

/// Перетворення частин пісні на слайди: рядок — одиниця розбиття, не слово.
public sealed class SongComposer
{
    /// `VersSubDivide` у `[Songs]`: ділити довгу частину на кілька слайдів.
    public bool SplitsLongParts { get; set; }
    public int LinesPerPage { get; set; } = 4;
    public bool BlankLineBreaksPage { get; set; } = true;
    public bool ShowsPartName { get; set; } = true;
    public bool ShowsNumber { get; set; }
    public bool ShowsTitle { get; set; }
    /// `SongsEndChunkPostText` — що дописати в кінець останньої частини.
    public string EndMarker { get; set; } = "";
    public bool ShowsPageNumber { get; set; } = true;
    public SongPalette Palette { get; set; } = SongPalette.Default();

    public List<SongSlide> Slides(Part part, int songNumber, string songTitle, bool isLastPart)
    {
        var pages = Pages(part.Text);
        var chunk = Palette.ChunkFor(part.Kind);
        if (pages.Count == 0)
            return new List<SongSlide>
            {
                new(part.Index, 0, 1, part.Kind, chunk?.Color,
                    new Slide("", new List<string>(), Reference(part.Kind, songNumber, songTitle, 0, 1), true)),
            };
        var result = new List<SongSlide>();
        for (var i = 0; i < pages.Count; i++)
        {
            var text = string.Join("\n", pages[i]);
            if (isLastPart && i == pages.Count - 1 && EndMarker.Length > 0) text += "\n" + EndMarker;
            result.Add(new SongSlide(part.Index, i, pages.Count, part.Kind, chunk?.Color,
                                     new Slide(text, new List<string>(), Reference(part.Kind, songNumber, songTitle, i, pages.Count), false)));
        }
        return result;
    }

    /// Усі слайди пісні підряд.
    public List<SongSlide> Slides(IReadOnlyList<Part> parts, int songNumber, string songTitle)
    {
        var all = new List<SongSlide>();
        for (var i = 0; i < parts.Count; i++) all.AddRange(Slides(parts[i], songNumber, songTitle, i == parts.Count - 1));
        return all;
    }

    /// Рядки частини, розкладені по слайдах: порожні рядки по краях — залишок
    /// роздільника; порожній усередині — розрив, поставлений укладачем.
    public List<List<string>> Pages(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim()).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
        if (lines.Count == 0) return new List<List<string>>();

        var blocks = new List<List<string>> { new() };
        foreach (var line in lines)
        {
            if (BlankLineBreaksPage && line.Length == 0) { if (blocks[^1].Count > 0) blocks.Add(new List<string>()); }
            else blocks[^1].Add(line);
        }
        blocks.RemoveAll(b => b.Count == 0);
        if (!SplitsLongParts) return blocks;

        var perPageWanted = Math.Max(1, LinesPerPage);
        var result = new List<List<string>>();
        foreach (var block in blocks)
        {
            if (block.Count <= perPageWanted) { result.Add(block); continue; }
            var pageCount = (int)Math.Ceiling((double)block.Count / perPageWanted);
            var perPage = (int)Math.Ceiling((double)block.Count / pageCount);
            for (var at = 0; at < block.Count; at += perPage)
                result.Add(block.GetRange(at, Math.Min(perPage, block.Count - at)));
        }
        return result;
    }

    /// Адреса пісенного слайда: зал бачить «Куплет 2», і за ним оператор розуміє, де він.
    public string Reference(string kind, int songNumber, string songTitle, int page, int pageCount)
    {
        var pieces = new List<string>();
        if (ShowsNumber || ShowsTitle)
        {
            var head = "";
            if (ShowsNumber) head = songNumber + ".";
            if (ShowsTitle) head = head.Length == 0 ? songTitle : head + " " + songTitle;
            if (head.Length > 0) pieces.Add(head);
        }
        var trimmedKind = kind.Trim();
        if (ShowsPartName && trimmedKind.Length > 0) pieces.Add(trimmedKind);
        if (ShowsPageNumber && pageCount > 1) pieces.Add((page + 1) + "/" + pageCount);
        return string.Join(" · ", pieces);
    }
}
