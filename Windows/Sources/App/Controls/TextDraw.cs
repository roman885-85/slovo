// =============================================================================
//  TextDraw.cs — малювання й вимір тексту в прямокутнику
// =============================================================================
//  Готові розкладки тексту тримаються в кеші: рядок списку малюється на кожен
//  кадр прокрутки, а розкласти текст наново коштує більше, ніж намалювати.
// =============================================================================

using Avalonia;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;

namespace Slovo.App;

public static class TextDraw
{
    readonly record struct Key(string Text, FontWeight Weight, double Size, double Width, double Height,
                               TextAlignment Align, bool Wrap, bool Trim, Color Color, bool Plain = false);

    /// Текст «як є»: без контекстних замін шрифту. Inter сам робить із «->» стрілку
    /// «→», а ключ перекладу CTSTuning->Item0 мусить лишатися собою.
    public static readonly FontFeatureCollection Literal = new() { FontFeature.Parse("-calt"), FontFeature.Parse("-liga") };

    static readonly Dictionary<Key, TextLayout> Cache = new();
    static readonly Queue<Key> Order = new();
    const int Limit = 1500;

    static TextLayout Layout(Key key)
    {
        if (Cache.TryGetValue(key, out var ready)) return ready;
        var layout = key.Plain
            ? new TextLayout(key.Text, UiFont.Face(key.Weight), Literal, key.Size, Palette.Brush(key.Color),
                key.Align, key.Wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
                key.Trim ? TextTrimming.CharacterEllipsis : null, null, FlowDirection.LeftToRight,
                key.Width, key.Height)
            : new TextLayout(key.Text, UiFont.Face(key.Weight), key.Size, Palette.Brush(key.Color),
                key.Align, key.Wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
                key.Trim ? TextTrimming.CharacterEllipsis : null, null, FlowDirection.LeftToRight,
                key.Width, key.Height);
        Cache[key] = layout;
        Order.Enqueue(key);
        if (Order.Count > Limit)
        {
            var old = Order.Dequeue();
            if (Cache.Remove(old, out var gone)) gone.Dispose();
        }
        return layout;
    }

    /// Висота тексту з переносом слів у заданій ширині.
    public static double Height(string text, double width, double size, FontWeight weight = FontWeight.Normal)
    {
        if (string.IsNullOrEmpty(text)) return UiFont.LineHeight(size, weight);
        var layout = Layout(new Key(text, weight, size, Math.Max(1, width), double.PositiveInfinity,
                                    TextAlignment.Left, true, false, Colors.Black));
        return Math.Ceiling(layout.Height);
    }

    /// Намалювати текст у прямокутник: з переносом слів або в один рядок із
    /// трьома крапками в кінці.
    public static void Draw(DrawingContext g, string text, Rect rect, double size, Color color,
                            FontWeight weight = FontWeight.Normal, TextAlignment align = TextAlignment.Left,
                            bool wrap = true, bool trim = false, bool plain = false, bool clip = false)
    {
        if (string.IsNullOrEmpty(text) || rect.Width <= 0) return;
        // clip — рядок просто обрізається краєм, без трьох крапок (мітка NSTextField .byClipping).
        var layout = Layout(new Key(text, weight, size, clip ? double.PositiveInfinity : rect.Width, wrap ? rect.Height : double.PositiveInfinity,
                                    align, wrap && !clip, !clip && (trim || !wrap), color, plain));
        using (g.PushClip(rect))
            layout.Draw(g, rect.TopLeft);
    }

    /// Рядок, урізаний посередині («…ation Support/Slovo/…»), щоб влізти в ширину —
    /// як lineBreakMode .byTruncatingMiddle на Mac: у шляху важливі обидва кінці.
    public static string MiddleTruncated(string text, double size, double width, FontWeight weight = FontWeight.Normal)
    {
        if (width <= 0 || UiFont.Width(text, size, weight) <= width) return text;
        int low = 0, high = text.Length;
        while (low < high)
        {
            var keep = (low + high + 1) / 2;
            var head = (keep + 1) / 2;
            var candidate = text[..head] + "…" + text[(text.Length - (keep - head))..];
            if (UiFont.Width(candidate, size, weight) <= width) low = keep; else high = keep - 1;
        }
        var front = (low + 1) / 2;
        return text[..front] + "…" + text[(text.Length - (low - front))..];
    }

    /// Кегль, за якого рядок входить у ширину: зменшуємо до `minimum` від
    /// заданого півпунктами, далі ріжуть три крапки.
    public static double Fitted(string text, double size, double width, double minimum = 0.72,
                                FontWeight weight = FontWeight.Normal)
    {
        if (width <= 4 || string.IsNullOrEmpty(text)) return size;
        var wanted = UiFont.Width(text, size, weight);
        if (wanted <= width) return size;
        var scale = Math.Max(minimum, width / wanted);
        var fitted = Math.Floor(size * scale * 2) / 2;
        var floor = size * minimum;
        for (var attempt = 0; attempt < 6 && fitted - 0.5 >= floor && UiFont.Width(text, fitted, weight) > width; attempt++)
            fitted -= 0.5;
        return fitted;
    }

    public static void Clear()
    {
        foreach (var layout in Cache.Values) layout.Dispose();
        Cache.Clear();
        Order.Clear();
    }
}
