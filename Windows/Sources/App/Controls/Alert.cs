// =============================================================================
//  Alert.cs — вікно-повідомлення з кнопками (як NSAlert на Mac)
// =============================================================================
//  Заголовок напівжирний, пояснення, кнопки праворуч (перша — головна, кольору
//  акценту). Відповідь — номер натиснутої кнопки (0 — перша).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Slovo.App;

public static class Alert
{
    /// `owner` — чиє це питання (вікно, над яким воно стає); без нього — «Параметри» чи головне.
    public static void Ask(string title, string message, IReadOnlyList<string> buttons, Action<int>? answer = null, Window? owner = null)
    {
        var window = new Window
        {
            Title = title, Width = 420, SizeToContent = SizeToContent.Height, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground),
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var chosen = -1;
        for (var i = buttons.Count - 1; i >= 0; i--)
        {
            var index = i;
            var b = new PushButton(buttons[i]) { Prominent = i == 0, MinWidth = 90, Height = 24 };
            b.Pressed = () => { chosen = index; window.Close(); };
            row.Children.Add(b);
        }
        window.Closed += (_, _) => answer?.Invoke(chosen < 0 ? buttons.Count - 1 : chosen);
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 10,
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 13, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family },
                new TextBlock { Text = message, FontSize = 12, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family, Foreground = Palette.Brush(Palette.Label) },
                row,
            },
        };
        var parent = owner ?? (Window?)SettingsWindow.Shared ?? MainWindow.Shared;
        if (parent is { IsVisible: true }) window.ShowDialog(parent); else window.Show();
    }

    public static void Tell(string title, string message, string ok = "Ок") => Ask(title, message, new[] { Captions.T(ok) });
}
