// =============================================================================
//  TextWorkspace.cs — вкладка «Текст» (як NativeTextWorkspace на Mac)
// =============================================================================
//  «Заголовок:» (поле 160…320, темно-червоний текст), кнопки «додати в План» і
//  «очистити», «Текст:» — велике поле (темно-синій текст). Набране зберігається
//  між запусками; показ у перегляд і зал — сторінками (TextModuleModel).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class TextWorkspace : LayoutPanel
{
    readonly AppState _state;
    readonly BottomCaption _titleLabel = new(), _bodyLabel = new();
    readonly FormField _title = new(14) { Height = 24 };
    readonly TextBox _body = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 15, FontFamily = UiFont.Family,
        Padding = new Thickness(4), BorderThickness = new Thickness(1), MinHeight = 0,
    };
    readonly IconButton _add = new("note.text.badge.plus", 16), _clear = new("doc", 16);

    readonly TextModuleModel _model = TextModuleModel.Shared;
    bool _pulling;

    public TextWorkspace(AppState state)
    {
        _state = state;
        foreach (Control c in new Control[] { _titleLabel, _bodyLabel, _title, _add, _clear, _body }) Children.Add(c);
        Layout = Arrange;
        _title.OnChange = t => { if (_pulling) return; _model.Title = t; Enable(); };
        // TextChanging (одразу), а не TextChanged (через чергу, коли `_pulling` уже знято).
        _body.TextChanging += (_, _) => { if (_pulling) return; _model.Body = _body.Text ?? ""; Enable(); };
        _clear.Pressed = () => { _model.Clear(); Pull(); };
        // «Додати в План» — з перенесенням Плану.
        _add.Pressed = () => _state.AddTextToPlan?.Invoke(_model.Document);
        _model.Changed += () => Dispatcher.UIThread.Post(Pull);
        ApplyColors();
        Palette.Changed += ApplyColors;
        ApplyCaptions();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        Pull();
    }

    /// Поля — за моделлю (набране могло прийти з плану чи пульта).
    void Pull()
    {
        _pulling = true;
        try
        {
            if (_title.Text != _model.Title) _title.Text = _model.Title;
            if ((_body.Text ?? "") != _model.Body) _body.Text = _model.Body;
        }
        finally { _pulling = false; }
        Enable();
    }

    void Enable()
    {
        _add.IsEnabled = _clear.IsEnabled = !_model.Document.IsEmpty;
        _add.InvalidateVisual(); _clear.InvalidateVisual();
    }

    /// F6 «Фокус на Вірші/Текст» на цій вкладці — курсор у текст.
    public void FocusBody() => _body.Focus();

    void ApplyColors()
    {
        var dark = Palette.IsDark;
        _title.Box.Foreground = Palette.Brush(dark ? Color.FromRgb(242, 140, 122) : Color.FromRgb(153, 28, 15));
        _body.Foreground = Palette.Brush(dark ? Color.FromRgb(158, 191, 255) : Color.FromRgb(28, 33, 184));
        _body.Background = Palette.Brush(Palette.TextBackground);
        _body.BorderBrush = Palette.Brush(Palette.Separator);
    }

    void ApplyCaptions()
    {
        _titleLabel.Text = Captions.Caption("Label4", "Заголовок:");
        _bodyLabel.Text = Captions.Caption("Label10", "Текст:");
        ToolTip.SetTip(_add, Captions.MainHint("SBAddTextToPlan", "Добавить в план"));
        ToolTip.SetTip(_clear, Captions.MainHint("SBClearText", "Очистить текст"));
        InvalidateArrange();
    }

    void Arrange(Size size)
    {
        const double gap = 8;
        var width = size.Width - gap * 2;
        Place(_titleLabel, new Rect(gap, gap, width, 14));
        var titleWidth = Math.Min(320, Math.Max(160, width * 0.3));
        var title = new Rect(gap, gap + 14 + 2, titleWidth, 24);
        Place(_title, title);
        Place(_add, new Rect(title.Right + 6, title.Y + 2, 22, 20));
        Place(_clear, new Rect(title.Right + 6 + 22 + 4, title.Y + 2, 22, 20));
        Place(_bodyLabel, new Rect(gap, title.Bottom + 6, width, 14));
        var bodyTop = title.Bottom + 6 + 14 + 2;
        Place(_body, new Rect(gap, bodyTop, width, Math.Max(0, size.Height - bodyTop - gap)));
    }
}
