// =============================================================================
//  LyricsEditor.cs — поле тексту пісні з кольоровими ключами (як NativeSongLyricsView)
// =============================================================================
//  Моноширинний 12. Рядок «#Куплет» (чи ключове слово палітри) — напівжирний
//  кольором частини, незнайомий заголовок — напівжирний сірий, «$Align$=…» —
//  бірюзовий, решта — звичайний текст. Розфарбовує те саме правило, що й розбір
//  (SongTextMarkup.Markup): якщо фарба розійдеться з розбором, вона обманюватиме.
//
//  Поле вводу Avalonia кольорових шматків не вміє, тож текст поля прозорий, а
//  поверх нього — шар, що малює той самий текст тією ж розкладкою (той самий
//  шрифт, ширина рядка й переноси), лише з кольорами. Курсор і виділення —
//  від поля, як і було.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using Avalonia.VisualTree;
using Slovo.Core;

namespace Slovo.App;

public sealed class LyricsEditor : Panel
{
    public static readonly FontFamily Mono = new("Cascadia Mono,Consolas,Menlo,monospace");
    public readonly TextBox Box;
    readonly Paint _paint;

    public LyricsEditor(string text, bool editable, SongChunkPalette palette)
    {
        Box = new TextBox
        {
            Text = text, AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap, IsReadOnly = !editable,
            FontFamily = Mono, FontSize = 12, Padding = new Thickness(4),
            BorderThickness = new Thickness(1), BorderBrush = Palette.Brush(Palette.Separator), Background = Palette.Brush(Palette.TextBackground),
            // Текст поля прозорий — його малює шар із кольорами; курсор і виділення лишаються.
            Foreground = Brushes.Transparent, SelectionForegroundBrush = Brushes.Transparent,
            CaretBrush = Palette.Brush(Palette.Label),
        };
        _paint = new Paint(this, palette) { IsHitTestVisible = false };
        Children.Add(Box);
        Children.Add(_paint);
        Box.PropertyChanged += (_, e) =>
        {
            if (e.Property == TextBox.TextProperty || e.Property == BoundsProperty) _paint.InvalidateVisual();
        };
        Box.TemplateApplied += (_, e) =>
        {
            if (e.NameScope.Find<ScrollViewer>("PART_ScrollViewer") is { } scroll) scroll.ScrollChanged += (_, _) => _paint.InvalidateVisual();
        };
        Box.LayoutUpdated += (_, _) => _paint.InvalidateVisual();
        Palette.Changed += () =>
        {
            Box.BorderBrush = Palette.Brush(Palette.Separator);
            Box.Background = Palette.Brush(Palette.TextBackground);
            Box.CaretBrush = Palette.Brush(Palette.Label);
            _paint.InvalidateVisual();
        };
    }

    public string Text { get => Box.Text ?? ""; set => Box.Text = value; }

    /// Вставити рядок ключа в кінець (меню «Вставити ключ»).
    public void Insert(string keyword)
    {
        var value = Box.Text ?? "";
        if (value.Length > 0 && !value.EndsWith('\n')) value += "\n";
        Box.Text = value + keyword + "\n";
        Box.CaretIndex = Box.Text.Length;
    }

    /// NSColor.systemTeal світлий і темний.
    static Color Teal => Palette.IsDark ? Color.FromRgb(0x40, 0xC8, 0xE0) : Color.FromRgb(0x30, 0xB0, 0xC7);

    sealed class Paint : Control
    {
        readonly LyricsEditor _owner;
        readonly SongChunkPalette _palette;
        TextPresenter? _presenter;
        ScrollViewer? _scroll;

        public Paint(LyricsEditor owner, SongChunkPalette palette) { _owner = owner; _palette = palette; }

        public override void Render(DrawingContext g)
        {
            var box = _owner.Box;
            _presenter ??= box.GetVisualDescendants().OfType<TextPresenter>().FirstOrDefault();
            _scroll ??= box.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault();
            if (_presenter is not { } presenter || presenter.TextLayout is not { } shown) return;
            var text = box.Text ?? "";
            if (text.Length == 0) return;
            var regular = new Typeface(box.FontFamily, FontStyle.Normal, FontWeight.Normal);
            var bold = new Typeface(box.FontFamily, FontStyle.Normal, FontWeight.Bold);
            var size = box.FontSize;
            var overrides = new List<ValueSpan<TextRunProperties>>();
            foreach (var line in SongTextMarkup.Markup(text, _palette))
            {
                if (line.Start < 0 || line.Start + line.Length > text.Length) continue;
                var (face, color) = line.Role.Kind switch
                {
                    SongTextMarkup.Role.Kinds.KeywordHeading when line.Role.Color is { } c =>
                        (bold, Color.FromArgb(255, (byte)Math.Round(c.Red * 255), (byte)Math.Round(c.Green * 255), (byte)Math.Round(c.Blue * 255))),
                    SongTextMarkup.Role.Kinds.Heading => (bold, Palette.SecondaryLabel),
                    SongTextMarkup.Role.Kinds.Parameter => (regular, Teal),
                    _ => (regular, Palette.Label),
                };
                overrides.Add(new ValueSpan<TextRunProperties>(line.Start, line.Length,
                    new GenericTextRunProperties(face, size, foregroundBrush: Palette.Brush(color))));
            }
            // Та сама розкладка, що в поля: шрифт, ширина рядка, переноси, міжрядок.
            using var layout = new TextLayout(text, regular, size, Palette.Brush(Palette.Label), presenter.TextAlignment, presenter.TextWrapping,
                                              null, null, FlowDirection.LeftToRight, shown.MaxWidth, double.PositiveInfinity,
                                              presenter.LineHeight, presenter.LetterSpacing, 0, overrides);
            if (presenter.TranslatePoint(default, this) is not { } origin) return;
            var clip = _scroll is { } scroll && scroll.TranslatePoint(default, this) is { } at
                ? new Rect(at, scroll.Viewport.Width > 0 ? new Size(scroll.Viewport.Width, scroll.Viewport.Height) : scroll.Bounds.Size)
                : new Rect(Bounds.Size);
            using (g.PushClip(clip)) layout.Draw(g, origin);
        }
    }
}
