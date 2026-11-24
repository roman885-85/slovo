// =============================================================================
//  SlideTab.cs — вкладка «Слайд» вікна «Параметри» (як NativeSettingsSlideTab)
// =============================================================================
//  Групи: Ефект зміни слайда · Ефект зміни сторінки показу і картинки · Адреса
//  місця Писання · Приклад адреси · Назва пісні · Приклад назви пісні · Указка.
// =============================================================================

using Avalonia.Controls;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class SlideTab
{
    readonly SettingsStore _store;
    readonly TextBlock _combined = Form.Label("", false), _mainOnly = Form.Label("", false),
                       _secondOnly = Form.Label("", false), _songLine = Form.Label("", false);

    public SlideTab(SettingsStore store) { _store = store; }

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    ProgramOptions O => _store.Settings.Options;

    public Control Page()
    {
        var page = new Form.Page(new[] { Transitions(), ShowTransitions(), Address(), AddressExample(), SongName(), SongExample(), Pointer() });
        Refresh();
        return page;
    }

    static readonly IReadOnlyList<SlideStyle.TransitionPreset> Presets = SlideStyle.TransitionPreset.All;
    static readonly SlideStyle.Easing[] Easings = Enum.GetValues<SlideStyle.Easing>();

    Form.Group Transitions() => new(Captions.T("Эффект смены слайда"), new Control[]
    {
        new Form.Row(Captions.T("Переход слайда:"), new Control[]
        {
            Form.Popup(Presets.Select(p => Captions.T(p.Title)).ToList(), new Tie<int>(
                () => Index(O.SlideTransition ?? "fade", 1),
                i => { if (i < 0 || i >= Presets.Count) return; var p = Presets[i];
                       O.SlideTransition = p.Kind.RawValue(); O.SlideTransitionEasing = p.Easing.RawValue(); O.CrossfadeTime = (int)(p.Duration * 1000); }), 220),
        }, 200),
        new Form.Row(Captions.T("Кривая перехода:"), new Control[]
        {
            Form.Popup(Easings.Select(e => Captions.T(e.Title())).ToList(), new Tie<int>(
                () => EasingIndex(O.SlideTransitionEasing ?? "easeInOut", 1),
                i => { if (i >= 0 && i < Easings.Length) O.SlideTransitionEasing = Easings[i].RawValue(); }), 160),
        }, 200),
        new Form.Row(Vb("Label16", Captions.T("Время плавной смены слайдов:")), new Control[]
        {
            Form.Number(new Tie<int>(() => O.CrossfadeTime, v => O.CrossfadeTime = v), 0, 10000),
            Form.Label(Vb("Label17", "мс")),
        }, 200),
        new Form.Row(Captions.T("Время затухания при скрытии:"), new Control[]
        {
            Form.Number(new Tie<int>(() => O.HideFadeTime ?? 400, v => O.HideFadeTime = Math.Max(0, Math.Min(5000, v))), 0, 5000),
            Form.Label(Captions.T("мс")),
        }, 200),
        new Form.Row(Captions.T("Кривая затухания:"), new Control[]
        {
            Form.Popup(Easings.Select(e => Captions.T(e.Title())).ToList(), new Tie<int>(
                () => EasingIndex(O.HideFadeEasing ?? "easeOut", 2),
                i => { if (i >= 0 && i < Easings.Length) O.HideFadeEasing = Easings[i].RawValue(); }), 160),
        }, 200),
    });

    Form.Group ShowTransitions() => new(Captions.T("Эффект смены страницы показа и картинки"), new Control[]
    {
        new Form.Row(Captions.T("Переход:"), new Control[]
        {
            Form.Popup(Presets.Select(p => Captions.T(p.Title)).ToList(), new Tie<int>(
                () => Index(O.ShowTransition ?? "fade", 1),
                i => { if (i < 0 || i >= Presets.Count) return; var p = Presets[i];
                       O.ShowTransition = p.Kind.RawValue(); O.ShowTransitionEasing = p.Easing.RawValue(); O.ShowTransitionTime = (int)(p.Duration * 1000); }), 220),
        }, 200),
        new Form.Row(Captions.T("Кривая перехода:"), new Control[]
        {
            Form.Popup(Easings.Select(e => Captions.T(e.Title())).ToList(), new Tie<int>(
                () => EasingIndex(O.ShowTransitionEasing ?? "easeInOut", 1),
                i => { if (i >= 0 && i < Easings.Length) O.ShowTransitionEasing = Easings[i].RawValue(); }), 160),
        }, 200),
        new Form.Row(Captions.T("Время смены:"), new Control[]
        {
            Form.Number(new Tie<int>(() => O.ShowTransitionTime ?? 350, v => O.ShowTransitionTime = v), 0, 10000),
            Form.Label(Vb("Label17", "мс")),
        }, 200),
        new Form.Row("", new Control[]
        {
            Form.Label(Captions.T("Действует на страницы показа, фотографии и захваченный экран. На приближение точкой фокуса не действует: лупа должна ехать за рукой, а не растворяться.")),
        }),
    });

    static int Index(string raw, int fallback)
    {
        for (var i = 0; i < Presets.Count; i++) if (Presets[i].Kind.RawValue() == raw) return i;
        return fallback;
    }

    static int EasingIndex(string raw, int fallback)
    {
        for (var i = 0; i < Easings.Length; i++) if (Easings[i].RawValue() == raw) return i;
        return fallback;
    }

    Control Style(Func<AddressStyle> get, Action<AddressStyle> set) =>
        Form.Popup(new[] { Vb("TextMessages39", "Длинный"), Vb("TextMessages40", "Короткий") },
                   new Tie<int>(() => get() == AddressStyle.Long ? 0 : 1, v => { set(v == 0 ? AddressStyle.Long : AddressStyle.Short); Refresh(); }), 140);

    Form.Group Address() => new(Vb("GBBibleAddress", "Адрес места Писания:"), new Control[]
    {
        new Form.Row(Vb("GBAll", Captions.T("Объединенный:")) + " " + Vb("LRefAllMain", Captions.T("Основной перевод:")),
                     new[] { Style(() => O.RefAllMain, v => O.RefAllMain = v) }, 260),
        new Form.Row(Vb("GBAll", Captions.T("Объединенный:")) + " " + Vb("LRefAllSec", Captions.T("Второй перевод:")),
                     new[] { Style(() => O.RefAllSec, v => O.RefAllSec = v) }, 260),
        new Form.Row(Vb("GBSep", Captions.T("Отдельный")) + " " + Vb("LRefMain", Captions.T("Основной перевод:")),
                     new[] { Style(() => O.RefMain, v => O.RefMain = v) }, 260),
        new Form.Row(Vb("GBSep", Captions.T("Отдельный")) + " " + Vb("LRefSec", Captions.T("Второй перевод:")),
                     new[] { Style(() => O.RefSec, v => O.RefSec = v) }, 260),
        new Form.Row("", new Control[]
        {
            Form.Check(Vb("CBRefsSeparated", "Пробел между адресами"), Bool(() => O.RefsSeparated, v => O.RefsSeparated = v),
                       Captions.T("Отделять пробелом адреса двух переводов на слайде")),
        }),
    });

    Form.Group AddressExample() => new(Vb("GBBibleAddressExamp", "Пример адреса:"), new Control[]
    {
        new Form.Row(Vb("LRefExamplAll", Captions.T("Объединенный:")), new Control[] { _combined }, 180),
        new Form.Row(Vb("LRefExamplMain", "Основной перевод:"), new Control[] { _mainOnly }, 180),
        new Form.Row(Vb("LRefExamplSec", "Второй перевод:"), new Control[] { _secondOnly }, 180),
    });

    Form.Group SongName() => new(Vb("GBSongName", Captions.T("Название песни:")), new Control[]
    {
        new Form.Row("", new Control[] { Form.Check(Vb("CBNumPP", "Номер по порядку"), Bool(() => O.SongNumberPP, v => O.SongNumberPP = v),
                                                   Captions.T("Показывать в названии песни её номер по порядку в песеннике")) }),
        new Form.Row("", new Control[]
        {
            Form.Check(Vb("CBNumInCollect", "Номер в сборнике"), Bool(() => O.SongNumberInCollection, v => O.SongNumberInCollection = v),
                       Captions.T("Показывать в названии песни номер из печатного сборника")),
            Form.Check(Vb("CBNumInCollectInBrackets", "(Всегда в скобках)"), Bool(() => O.SongNumberInBrackets, v => O.SongNumberInBrackets = v),
                       Captions.T("Номер из сборника — всегда в скобках")),
        }),
        new Form.Row("", new Control[] { Form.Check(Vb("CBDotAfterNum", "Точка после номера"), Bool(() => O.SongDotAfterNumber, v => O.SongDotAfterNumber = v),
                                                   Captions.T("Ставить точку после номера песни в названии")) }),
    });

    Form.Group SongExample() => new(Vb("GroupBox7", "Пример названия песни:"), new Control[] { new Form.Row("", new Control[] { _songLine }) });

    Form.Group Pointer() => new(Captions.T("Указка"), new Control[]
    {
        new Form.Row(Captions.T("Цвет:"), new Control[]
        {
            Form.Colour(new Tie<Color>(() => PointerColours.FromHex(O.PointerColour) ?? PointerColours.Default, c => O.PointerColour = PointerColours.Hex(c))),
        }, 120),
        new Form.Row(Captions.T("Размер (% высоты):"), new Control[]
        {
            Form.Slider(new Tie<double>(() => (O.PointerSize ?? 0.14) * 100, v => O.PointerSize = v / 100), 3, 60, v => ((int)Math.Round(v)).ToString(), 160),
        }, 120),
        new Form.Row(Captions.T("Яркость (%):"), new Control[]
        {
            Form.Slider(new Tie<double>(() => (O.PointerOpacity ?? 0.45) * 100, v => O.PointerOpacity = v / 100), 5, 100, v => ((int)Math.Round(v)).ToString(), 160),
        }, 120),
        new Form.Row(Captions.T("Выводить:"), new Control[]
        {
            Form.Check(Captions.T("на проектор"), new Tie<bool>(() => O.PointerProjector ?? true, v => O.PointerProjector = v), Captions.T("Показывать указку в зале на проекторе")),
            Form.Check(Captions.T("в NDI"), new Tie<bool>(() => O.PointerNDI ?? true, v => O.PointerNDI = v), Captions.T("Передавать указку в трансляцию NDI")),
        }, 120),
        new Form.Row("", new Control[] { Form.Label(Captions.T("Указку ведут мышью по зеркалу проектора в нижнем ряду или пальцем по слайду на телефоне.")) }, stretch: true),
    });

    Tie<bool> Bool(Func<bool> get, Action<bool> set) => new(get, v => { set(v); Refresh(); });

    void Refresh()
    {
        var o = O;
        string Main(AddressStyle s) => s == AddressStyle.Long ? Vb("TextMessages41", "Бытие") : Vb("TextMessages43", "Быт.");
        string Second(AddressStyle s) => s == AddressStyle.Long ? Vb("TextMessages42", "Genesis") : Vb("TextMessages44", "Gen.");
        var space = o.RefsSeparated ? " " : "";
        _combined.Text = $"{Main(o.RefAllMain)}{space}({Second(o.RefAllSec)}) 1:1";
        _mainOnly.Text = $"{Main(o.RefMain)} 1:1";
        _secondOnly.Text = $"{Second(o.RefSec)} 1:1";
        var parts = new List<string>();
        if (o.SongNumberPP) parts.Add("1");
        if (o.SongNumberInCollection) parts.Add(o.SongNumberInBrackets ? "(1)" : "1");
        var head = string.Join(" ", parts);
        if (head.Length > 0 && o.SongDotAfterNumber) head += ".";
        var name = Vb("TextMessages45", "Бог велик");
        _songLine.Text = head.Length == 0 ? name : head + " " + name;
    }
}

/// Колір указки «#RRGGBB» (як SlidePointer.Look.hex на Mac).
public static class PointerColours
{
    public static readonly Color Default = Color.FromRgb(0xFF, 0xD9, 0x18);
    public static Color? FromHex(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return null;
        var h = hex.Trim().TrimStart('#');
        if (h.Length != 6 || !uint.TryParse(h, System.Globalization.NumberStyles.HexNumber, null, out var v)) return null;
        return Color.FromRgb((byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }
    public static string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";
}
