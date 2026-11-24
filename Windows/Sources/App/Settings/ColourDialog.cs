// =============================================================================
//  ColourDialog.cs — задати колір трьома числами R, G, B (як NativeColourField)
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public static class ColourDialog
{
    /// `owner` — над яким вікном питати (за умовчанням «Параметри» чи головне); `cancelled` — закрили без «Ок».
    public static void Ask(Color start, Action<Color> done, Window? owner = null, Action? cancelled = null)
    {
        var fields = new[] { start.R, start.G, start.B }.Select(v => new FormField(11, true) { Width = 60, Height = 22, Text = v.ToString() }).ToArray();
        var sample = new ColourSwatch(start) { Width = 60, Height = 22 };
        void Update()
        {
            byte P(FormField f) => (byte)Math.Clamp(int.TryParse(f.Text, out var v) ? v : 0, 0, 255);
            sample.Colour = Color.FromRgb(P(fields[0]), P(fields[1]), P(fields[2]));
        }
        foreach (var f in fields) f.OnChange = _ => Update();
        var window = new Window { Title = Captions.T("Цвет"), Width = 320, Height = 150, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var ok = new PushButton(Captions.T("Ок")) { Prominent = true, Width = 90, Height = 24 };
        var cancel = new PushButton(Captions.T("Отмена")) { Width = 90, Height = 24 };
        var accepted = false;
        ok.Pressed = () => { accepted = true; Update(); done(sample.Colour); window.Close(); };
        cancel.Pressed = () => window.Close();
        window.Closed += (_, _) => { if (!accepted) cancelled?.Invoke(); };
        var row = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, Margin = new Thickness(16, 16, 16, 8) };
        foreach (var (label, field) in new[] { "R", "G", "B" }.Zip(fields)) { row.Children.Add(Form.Label(label)); row.Children.Add(field); }
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right, Margin = new Thickness(16, 8) };
        buttons.Children.Add(sample);
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        window.Content = new StackPanel { Children = { row, buttons } };
        window.Background = Palette.Brush(Palette.WindowBackground);
        if (owner is { IsVisible: true }) window.ShowDialog(owner);
        else if (SettingsWindow.Shared is { IsVisible: true } settings) window.ShowDialog(settings);
        else if (MainWindow.Shared is { } main) window.ShowDialog(main);
        else window.Show();
    }
}
