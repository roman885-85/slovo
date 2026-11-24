// =============================================================================
//  PointerDriver.cs — указка й наближення в нижньому ряду (як NativePointerBar,
//  NativeFocusBar і мишача частина NativeProjectorMirror)
// =============================================================================
//  Ліва кнопка по живому екрану — пляма-указка в залі, поки тримають; за
//  ввімкненого наближення клацання ще й переводить погляд туди. Колесо —
//  ближче/далі навколо курсора, середня кнопка — назад. Панель указки міняє
//  колір, розмір, яскравість і куди виводити (Усе / Зал / NDI) — і пише це в
//  «Параметри»; панель наближення вмикає його, міняє кратність, «У центр».
// =============================================================================

using Avalonia;
using Avalonia.Input;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class PointerDriver
{
    readonly BottomRow _bottom;
    bool _holding;
    /// Показ стану в панелях — не правка людини: події повзунків тоді ігноруємо.
    bool _showing;

    public PointerDriver(BottomRow bottom)
    {
        _bottom = bottom;
        SlidePointer.Shared.Apply(SlidePointer.Look.From(SettingsStore.Shared.Settings.Options));
        SlidePointer.Shared.Changed += Apply;
        SlideFocus.Shared.Changed += ShowFocus;

        var bar = bottom.PointerBar;
        bar.Colour.OnClick = () => ColourDialog.Ask(bar.Colour.Colour, picked => { bar.Colour.Colour = picked; ApplyBar(); });
        bar.SizeSlider.ValueChanged += _ => { if (!_showing) ApplyBar(); };
        bar.Brightness.ValueChanged += _ => { if (!_showing) ApplyBar(); };
        bar.Outputs.Selected += _ => { if (!_showing) ApplyBar(); };
        ShowBar(SlidePointer.Shared.BaseLook);

        var focus = bottom.FocusBar;
        focus.Toggle.Toggled += on => SlideFocus.Shared.SetOn(on);
        focus.Zoom.ValueChanged += value => { if (!_showing) SlideFocus.Shared.SetZoom(value / 100); };
        focus.CenterButton.Pressed = SlideFocus.Shared.Center;
        ShowFocus();

        var mirror = bottom.Mirror;
        mirror.Cursor = new Cursor(StandardCursorType.Cross);
        mirror.PointerPressed += (_, e) =>
        {
            var point = e.GetCurrentPoint(mirror);
            if (point.Properties.IsMiddleButtonPressed) { SlideFocus.Shared.Reset(); e.Handled = true; return; }
            if (!point.Properties.IsLeftButtonPressed) return;
            _holding = true;
            e.Pointer.Capture(mirror);
            if (SlideFocus.Shared.IsOn && Fraction(point.Position) is { } spot) SlideFocus.Shared.MoveToShown(spot.X, spot.Y);
            PointAt(point.Position);
            e.Handled = true;
        };
        mirror.PointerMoved += (_, e) => { if (_holding) PointAt(e.GetPosition(mirror)); };
        mirror.PointerReleased += (_, e) =>
        {
            if (!_holding) return;
            _holding = false;
            e.Pointer.Capture(null);
            SlidePointer.Shared.Hide(SlidePointer.MouseSource);
        };
        mirror.PointerWheelChanged += (_, e) =>
        {
            var steps = e.Delta.Y;
            if (Math.Abs(steps) < 0.0001) return;
            Magnify(Math.Pow(1.18, steps), e.GetPosition(mirror));
            e.Handled = true;
        };
        Apply();
    }

    /// Точка в частках кадру (кадр у виді може мати поля).
    (double X, double Y)? Fraction(Point p)
    {
        var frame = _bottom.Mirror.Surface.FrameRect;
        if (frame.Width <= 0 || frame.Height <= 0) return null;
        return (Math.Min(1, Math.Max(0, (p.X - frame.X) / frame.Width)), Math.Min(1, Math.Max(0, (p.Y - frame.Y) / frame.Height)));
    }

    void PointAt(Point p)
    {
        if (Fraction(p) is { } spot) SlidePointer.Shared.Move(spot.X, spot.Y, SlidePointer.MouseSource);
    }

    void Magnify(double factor, Point at)
    {
        if (Fraction(at) is not { } spot) return;
        var focus = SlideFocus.Shared;
        var now = focus.IsOn ? focus.Current.Zoom : SlideFocus.MinZoom;
        var wanted = now * factor;
        if (wanted <= SlideFocus.MinZoom + 0.001) { if (focus.IsOn) focus.Reset(); return; }
        focus.ZoomTo(wanted, spot.X, spot.Y);
        if (!focus.IsOn) focus.SetOn(true);
    }

    /// Указка — на ті виводи, що вибрані; дзеркало показує її завжди.
    void Apply()
    {
        var pointer = SlidePointer.Shared;
        var look = pointer.Current;
        _bottom.Mirror.Surface.ShowPointer(pointer.Point, look);
        ProjectionController.Shared.Surface?.ShowPointer(look.ToProjector ? pointer.Point : null, look);
        ShowBar(pointer.BaseLook);
    }

    void ShowBar(SlidePointer.Look look)
    {
        _showing = true;
        try { ShowBarValues(look); } finally { _showing = false; }
    }

    void ShowBarValues(SlidePointer.Look look)
    {
        var bar = _bottom.PointerBar;
        bar.Colour.Colour = Color.FromRgb((byte)Math.Round(look.Colour.Red * 255), (byte)Math.Round(look.Colour.Green * 255), (byte)Math.Round(look.Colour.Blue * 255));
        bar.SizeSlider.Value = Math.Round(look.Size * 100);
        bar.Brightness.Value = Math.Round(look.Opacity * 100);
        bar.Outputs.SelectedIndex = look.ToProjector && look.ToNDI ? 0 : look.ToProjector ? 1 : 2;
        bar.Sample.Look = new PointerLook(bar.Colour.Colour, look.Size, look.Opacity, look.ToProjector, look.ToNDI);
    }

    void ApplyBar()
    {
        var bar = _bottom.PointerBar;
        var look = SlidePointer.Shared.BaseLook;
        var c = bar.Colour.Colour;
        look.Colour = new SlideStyle.RGBA(c.R / 255.0, c.G / 255.0, c.B / 255.0);
        look.Size = bar.SizeSlider.Value / 100;
        look.Opacity = bar.Brightness.Value / 100;
        (look.ToProjector, look.ToNDI) = bar.Outputs.SelectedIndex switch { 1 => (true, false), 2 => (false, true), _ => (true, true) };
        SlidePointer.Shared.Apply(look);
        var store = SettingsStore.Shared;
        var options = store.Settings.Options;
        options.PointerColour = SlidePointer.Look.Hex(look.Colour);
        options.PointerSize = look.Size;
        options.PointerOpacity = look.Opacity;
        options.PointerProjector = look.ToProjector;
        options.PointerNDI = look.ToNDI;
        store.SaveOutsideEditing();
    }

    void ShowFocus()
    {
        var focus = SlideFocus.Shared;
        _showing = true;
        try { _bottom.FocusBar.Show(focus.IsOn, focus.Current.Zoom); } finally { _showing = false; }
    }
}
