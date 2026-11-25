// =============================================================================
//  ScreenFit.cs — кожне вікно вміщається на екран, де відкрилося
// =============================================================================
//  Власник (Windows 1.4.2): «в меню настроек нельзя пролистать список настроек».
//  «Параметри» (1180×720, найменше 1000×620) на ноутбуці 1366×768 зі збільшенням
//  125 % виходили нижче краю екрана: низ списку й кнопки «Ок/Скасувати» лишались за
//  краєм, прокрутити до них було нікуди. Тож при відкритті будь-якого звичайного
//  вікна (з рамкою) — не більше за робочу область екрана (найменший розмір теж
//  поступається), а місце — у межах екрана. Вікна без рамки (зал, притулок YouTube)
//  не чіпаються.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;

namespace Slovo.App;

public static class ScreenFit
{
    public static void Install() =>
        Window.WindowOpenedEvent.AddClassHandler<Window>((window, _) => Apply(window), RoutingStrategies.Direct);

    public static void Apply(Window window)
    {
        if (window.SystemDecorations != SystemDecorations.Full || window.WindowState != WindowState.Normal) return;
        var screen = window.Screens.ScreenFromWindow(window) ?? window.Screens.Primary;
        if (screen == null) return;
        var scale = screen.Scaling > 0 ? screen.Scaling : 1;
        var area = screen.WorkingArea;
        // Запас на рамку й заголовок вікна.
        double maxWidth = area.Width / scale - 16, maxHeight = area.Height / scale - 40;
        var size = window.ClientSize;
        var changed = false;
        if (size.Width > maxWidth && maxWidth > 200)
        {
            window.MinWidth = Math.Min(window.MinWidth, maxWidth);
            window.Width = maxWidth;
            changed = true;
        }
        if (size.Height > maxHeight && maxHeight > 200)
        {
            window.MinHeight = Math.Min(window.MinHeight, maxHeight);
            window.Height = maxHeight;
            changed = true;
        }
        var width = (int)Math.Round((Math.Min(size.Width, maxWidth) + 16) * scale);
        var height = (int)Math.Round((Math.Min(size.Height, maxHeight) + 40) * scale);
        var position = window.Position;
        if (changed || position.X < area.X || position.Y < area.Y || position.X + width > area.Right || position.Y + height > area.Bottom)
        {
            window.Position = new PixelPoint(area.X + Math.Max(0, (area.Width - width) / 2), area.Y + Math.Max(0, (area.Height - height) / 2));
            if (changed) Journal.Say($"вікно «{window.Title}» більше за екран — зменшено до {(int)Math.Min(size.Width, maxWidth)}×{(int)Math.Min(size.Height, maxHeight)}");
        }
    }
}
