// =============================================================================
//  Ui.cs — дрібні будівельні блоки вікон
// =============================================================================
//  Вікна збираються кодом, а не розміткою: так текст кожної кнопки стоїть
//  поруч із тим, що вона робить, і перекладається тим самим Lang.T.
// =============================================================================

using System;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace Propovidnyk.Views;

public static class Ui
{
    public static readonly IBrush Accent = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
    public static readonly IBrush AccentSoft = new SolidColorBrush(Color.FromRgb(0xE8, 0xF0, 0xFE));
    public static readonly IBrush Muted = new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));
    public static readonly IBrush Line = new SolidColorBrush(Color.FromRgb(0xE5, 0xE7, 0xEB));
    public static readonly IBrush Good = new SolidColorBrush(Color.FromRgb(0x15, 0x80, 0x3D));
    public static readonly IBrush Bad = new SolidColorBrush(Color.FromRgb(0xB9, 0x1C, 0x1C));
    public static readonly IBrush Paper = new SolidColorBrush(Color.FromRgb(0xF8, 0xFA, 0xFC));

    public static Button Button(string text, Action click, string? tip = null, bool accent = false)
    {
        var button = new Button
        {
            Content = text,
            Padding = new Thickness(12, 6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (accent)
        {
            button.Background = Accent;
            button.Foreground = Brushes.White;
            button.FontWeight = FontWeight.SemiBold;
        }
        button.Click += (_, _) => click();
        if (tip != null) ToolTip.SetTip(button, tip);
        return button;
    }

    public static TextBlock Hint(string text) => new()
    {
        Text = text,
        Foreground = Muted,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 6),
    };

    public static TextBlock Label(string text, double size = 13, bool bold = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeight.SemiBold : FontWeight.Normal,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static StackPanel Row(params Control[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var child in children) row.Children.Add(child);
        return row;
    }

    public static Border Card(Control child, double padding = 10) => new()
    {
        Child = child,
        Padding = new Thickness(padding),
        CornerRadius = new CornerRadius(8),
        BorderBrush = Line,
        BorderThickness = new Thickness(1),
        Background = Brushes.White,
    };

    /// Коротке вікно з повідомленням і кнопкою «Гаразд».
    public static async Task Message(Window owner, string title, string text)
    {
        var dialog = new Window
        {
            Title = title,
            Width = 460,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        var ok = Button(Lang.T("Гаразд", "OK"), () => dialog.Close(), accent: true);
        ok.IsDefault = true;
        ok.IsCancel = true;
        ok.HorizontalAlignment = HorizontalAlignment.Right;
        dialog.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Spacing = 14,
            Children = { Label(text), ok },
        };
        await dialog.ShowDialog(owner);
    }

    /// Питання «так / ні». true — людина погодилася.
    public static async Task<bool> Ask(Window owner, string title, string text, string yes)
    {
        var answer = false;
        var dialog = new Window
        {
            Title = title,
            Width = 460,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        var confirm = Button(yes, () => { answer = true; dialog.Close(); }, accent: true);
        var cancel = Button(Lang.T("Скасувати", "Cancel"), () => dialog.Close());
        cancel.IsCancel = true;
        confirm.IsDefault = true;
        var buttons = Row(cancel, confirm);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        dialog.Content = new StackPanel { Margin = new Thickness(18), Spacing = 14, Children = { Label(text), buttons } };
        await dialog.ShowDialog(owner);
        return answer;
    }
}
