// =============================================================================
//  SearchBox.cs — поле пошуку (як NSSearchField): лупа зліва, хрестик праворуч
// =============================================================================
//  Те саме поле, що під колонками головного вікна (QuickField), плюс значок
//  лупи на початку й хрестик «очистити», поки в полі щось є. Зміна тексту —
//  одразу (sendsSearchStringImmediately), хрестик теж повідомляє про зміну.
// =============================================================================

using Avalonia;
using Avalonia.Controls;

namespace Slovo.App;

public sealed class SearchBox : QuickField
{
    readonly IconView _glass = new("magnifyingglass", 12);
    readonly IconButton _clear = new("xmark", 8);

    public SearchBox(double fontSize = 12) : base(fontSize)
    {
        Children.Add(_glass);
        Children.Add(_clear);
        _clear.IsVisible = false;
        _clear.Pressed = () =>
        {
            Text = "";
            _clear.IsVisible = false;
            OnChange?.Invoke("");
            FocusField();
        };
        Box.TextChanged += (_, _) =>
        {
            var shown = (Box.Text ?? "").Length > 0;
            if (_clear.IsVisible == shown) return;
            _clear.IsVisible = shown;
            InvalidateArrange();
        };
    }

    protected override void Arrangement(Size size)
    {
        base.Arrangement(size);
        Place(_glass, new Rect(6, Math.Round((size.Height - 12) / 2), 12, 12));
        Place(_clear, new Rect(size.Width - 20, Math.Round((size.Height - 16) / 2), 16, 16));
        var h = Math.Ceiling(Box.FontSize) + 6;
        var right = _clear.IsVisible ? 22 : 6;
        Place(Box, new Rect(22, (size.Height - h) / 2, Math.Max(0, size.Width - 22 - right), h));
    }
}
