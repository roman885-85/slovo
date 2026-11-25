// =============================================================================
//  MirrorWindow.cs — дзеркало проектора окремим вікном (NativeProjectorMirrorWindow Mac)
// =============================================================================
//  Кнопка «⤢» над «живим екраном» у нижньому ряду: той самий кадр залу, але у
//  своєму вікні, якому можна міняти розмір (власник про Mac: «дать возможность
//  менять размер этого экрана»). Плавуче — над іншими вікнами, поки йде служіння
//  (NSPanel .floating), 640×360, найменше 320×180; місце й розмір пам'ятаються
//  (setFrameAutosaveName Mac). Кадр малює та сама черга, що й зал (OutputDriver),
//  указку й наближення мишею веде той самий PointerDriver — як по дзеркалу в ряду.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public sealed class MirrorWindow : Window
{
    /// Відкрите вікно (або null).
    public static MirrorWindow? Shown { get; private set; }
    /// Відкрили чи закрили — вивід і указка підключаються самі.
    public static event Action? Changed;

    public readonly SlideFrameView View = new() { Corner = 0 };
    const string FrameKey = "projectorMirrorFrame";

    public static MirrorWindow Open()
    {
        if (Shown is { } open) { open.Activate(); return open; }
        var window = Shown = new MirrorWindow();
        window.Closed += (_, _) =>
        {
            if (Shown == window) Shown = null;
            SlidePointer.Shared.Hide(SlidePointer.MouseSource);
            Changed?.Invoke();
        };
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        Changed?.Invoke();
        return window;
    }

    MirrorWindow()
    {
        Title = Captions.T("Зеркало проектора");
        Width = 640; Height = 360; MinWidth = 320; MinHeight = 180;
        Topmost = true;
        ShowInTaskbar = false;
        Background = Brushes.Black;
        View.Surface.FitsAspect = true;
        Content = View;
        ToolTip.SetTip(View, Captions.T("Указку ведут мышью по зеркалу проектора в нижнем ряду или пальцем по слайду на телефоне."));
        if (Defaults.String(FrameKey) is { } saved && saved.Split(',') is { Length: 4 } parts
            && parts.Select(p => int.TryParse(p, out var v) ? v : int.MinValue).ToArray() is var n && n.All(v => v != int.MinValue))
        {
            Position = new PixelPoint(n[0], n[1]);
            Width = Math.Max(MinWidth, n[2]);
            Height = Math.Max(MinHeight, n[3]);
            WindowStartupLocation = WindowStartupLocation.Manual;
            Opened += (_, _) => KeepOnScreen();
        }
        else WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Closing += (_, _) =>
        {
            if (WindowState == WindowState.Normal) Defaults.Set(FrameKey, $"{Position.X},{Position.Y},{(int)Width},{(int)Height}");
        };
    }

    /// Запам'ятоване місце могло лишитися на від'єднаному моніторі — тоді посередині головного.
    void KeepOnScreen()
    {
        var screen = Screens.ScreenFromWindow(this);
        if (screen != null && screen.WorkingArea.Contains(Position)) return;
        if (Screens.Primary is { } primary)
        {
            var scale = primary.Scaling <= 0 ? 1 : primary.Scaling;
            var area = primary.WorkingArea;
            Position = new PixelPoint(area.X + Math.Max(0, (area.Width - (int)(Width * scale)) / 2), area.Y + Math.Max(0, (area.Height - (int)(Height * scale)) / 2));
        }
    }
}
