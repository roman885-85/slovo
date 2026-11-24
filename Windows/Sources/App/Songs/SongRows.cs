// =============================================================================
//  SongRows.cs — рядки списків «Пісень» (як NativeSongRows на Mac)
// =============================================================================
//  Групи: назва й кількість пісень; пісні: номер (за порядком або в збірнику —
//  за форматом назви), назва, автор/композитор; частини: назва частини кольором
//  палітри (або «Частина N»), вирівнювання, текст без порожніх рядків по краях,
//  тло — той самий колір дуже блідо.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public static class SongMetrics
{
    public static ListMetrics Groups() => new() { DetailWidth = 34, Padding = new Thickness(8, 3, 6, 3), TextFontDelta = 0 };
    public static ListMetrics Songs() => new() { LeadWidth = 42, LeadFontDelta = -1, Padding = new Thickness(8, 4, 8, 4), TextFontDelta = 0 };
    public static ListMetrics Parts() => new()
    {
        LeadWidth = 92, LeadAlign = TextAlignment.Left, LeadFontDelta = -1, Padding = new Thickness(8, 6, 8, 6), TextFontDelta = -1,
    };
}

public sealed class SongGroupRows : IRowSource
{
    List<string> _names = new(), _counts = new();
    public Func<int, ContextMenu?>? Menu;
    public int RowCount => _names.Count;
    public Row RowAt(int index) => new(_names[index], "", _counts[index]) { SingleLine = true, Tooltip = _names[index] };

    public void Reload(IReadOnlyList<string> titles, IReadOnlyList<SongGroup> groups)
    {
        _names = titles.ToList();
        _counts = new List<string> { "" }.Concat(groups.Select(g => g.SongIndices.Count.ToString())).ToList();
        while (_counts.Count > _names.Count) _counts.RemoveAt(_counts.Count - 1);
        while (_counts.Count < _names.Count) _counts.Add("");
    }
}

public sealed class SongRows : IRowSource
{
    readonly SongIndex _index;
    public List<int>? Filter { get; private set; }
    public SongTitleFormat TitleFormat = new();
    public bool ShowsCatalogNumber;

    public SongRows(SongIndex index) { _index = index; }

    public int RowCount => Filter?.Count ?? _index.Count;

    public int? SongAt(int row)
    {
        if (Filter != null) return row >= 0 && row < Filter.Count ? Filter[row] : null;
        return row >= 0 && row < _index.Count ? row : null;
    }

    public int? PositionOfSong(int song)
    {
        if (Filter == null) return song < _index.Count ? song : null;
        var at = Filter.IndexOf(song);
        return at < 0 ? null : at;
    }

    public Row RowAt(int row)
    {
        if (SongAt(row) is not { } song) return new Row("");
        return new Row(_index.Titles[song], Lead(song), _index.Subtitles[song]) { SingleLine = true };
    }

    string Lead(int song)
    {
        if (!TitleFormat.ShowsNumber) return "";
        var number = ShowsCatalogNumber && song < _index.CatalogNumbers.Count ? _index.CatalogNumbers[song] ?? song + 1 : song + 1;
        return TitleFormat.NumberText(number);
    }

    public void SetFilter(List<int>? filter) => Filter = filter;
}

public sealed class SongPartRows : IRowSource
{
    readonly List<string> _kinds = new(), _texts = new();
    readonly List<Color> _tints = new(), _fills = new();
    public List<int> Numbers { get; } = new();
    public bool SingleLine;
    public int RowCount => _texts.Count;

    public Row RowAt(int index)
    {
        // «Одна лінія» в автора не сплющує куплет в один рядок екрана, а склеює рядки
        // пісні в абзац — він усе одно переноситься по ширині стовпця.
        var text = SingleLine ? string.Join(" ", _texts[index].Split('\n')) : _texts[index];
        return new Row(text, _kinds[index]) { LeadColor = _tints[index], Fill = _fills[index], SingleLine = false };
    }

    public int? PositionOfPart(int number) { var at = Numbers.IndexOf(number); return at < 0 ? null : at; }

    public void Reload(Song? song, SongChunkPalette palette)
    {
        _kinds.Clear(); _texts.Clear(); _tints.Clear(); _fills.Clear(); Numbers.Clear();
        if (song == null) return;
        foreach (var part in song.Parts)
        {
            var chunk = palette.ChunkFor(part.Kind);
            var tint = chunk != null
                ? Color.FromRgb((byte)Math.Round(chunk.Color.Red * 255), (byte)Math.Round(chunk.Color.Green * 255), (byte)Math.Round(chunk.Color.Blue * 255))
                : Palette.SecondaryLabel;
            var title = part.Kind.Length == 0 ? chunk?.Title ?? "" : part.Kind;
            if (title.Length == 0) title = Captions.T("Часть %s", (part.Index + 1).ToString());
            if (part.Align != SongPartAlign.Default && part.Align.ExportName() is { } name) title += " · " + name;
            _kinds.Add(title);
            _texts.Add(Preview(part));
            _tints.Add(tint);
            _fills.Add(tint.WithAlpha(0.12));
            Numbers.Add(part.Index);
        }
    }

    static string Preview(SongPart part)
    {
        var lines = part.Lines.Select(l => l.Trim()).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
        return string.Join("\n", lines);
    }
}
