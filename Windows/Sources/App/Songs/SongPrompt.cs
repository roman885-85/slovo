// =============================================================================
//  SongPrompt.cs — запитання пісенника (як NativeSongPrompt / SongCaptions на Mac)
// =============================================================================
//  Підписи панелі пісень — з файла перекладу автора з приставкою вкладеної форми
//  «SongsPluginFrame->» (TextMessagesN — тексти запитів); чого там немає — наш
//  словник. Запитання — ввести рядок, так/ні, три відповіді, попередження,
//  вибір файла для відкриття й збереження.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Slovo.App;

public static class SongCaptions
{
    const string Form = "MainForm", Prefix = "SongsPluginFrame->";

    /// Підпис елемента; у кнопок із картинкою підпис дорівнює імені — це не текст для людини.
    public static string Caption(string key, string fallback)
    {
        var text = Captions.FormCaption(Prefix + key, Form, "\0");
        return text.Length == 0 || text == "\0" || text == key ? Captions.T(fallback) : text;
    }

    public static string Hint(string key, string fallback) =>
        (Captions.FormHint(Prefix + key, Form) is { Length: > 0 } text ? text : Captions.T(fallback)).Replace("\\n", "\n");

    /// «SongsPluginFrame->TextMessagesN» — тексти запитів і попереджень.
    public static string Message(int number, string fallback)
    {
        var text = Captions.FormCaption($"{Prefix}TextMessages{number}", Form, "\0");
        return (text.Length == 0 || text == "\0" ? Captions.T(fallback) : text).Replace("\\n", "\n");
    }

    public static string Error(int number, string fallback)
    {
        var text = Captions.FormCaption($"{Prefix}ErrorMessages{number}", Form, "\0");
        return (text.Length == 0 || text == "\0" ? Captions.T(fallback) : text).Replace("\\n", "\n");
    }
}

public static class SongPrompt
{
    public enum Answer { Yes, No, Cancel }

    static Window? Owner => MainWindow.Shared;

    public static Task<bool> Confirm(string title, string message)
    {
        var done = new TaskCompletionSource<bool>();
        Alert.Ask(title, message, new[] { Captions.T("Да"), Captions.T("Нет") }, answer => done.TrySetResult(answer == 0));
        return done.Task;
    }

    public static Task<Answer> ThreeWay(string title, string message, string yes, string no)
    {
        var done = new TaskCompletionSource<Answer>();
        Alert.Ask(title, message, new[] { Captions.T(yes), Captions.T(no), Captions.T("Отмена") },
                  answer => done.TrySetResult(answer switch { 0 => Answer.Yes, 1 => Answer.No, _ => Answer.Cancel }));
        return done.Task;
    }

    public static void Warn(string title, string message) => Alert.Tell(title, message);

    /// Ввести рядок: null — передумали.
    public static Task<string?> Input(string title, string message, string value)
    {
        var done = new TaskCompletionSource<string?>();
        var window = new Window
        {
            Title = title, Width = 420, SizeToContent = SizeToContent.Height, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground),
        };
        var field = new FormField(13) { Height = 24, Text = value };
        string? result = null;
        var ok = new PushButton(Captions.T("Ок")) { Prominent = true, MinWidth = 90, Height = 24 };
        var cancel = new PushButton(Captions.T("Отмена")) { MinWidth = 90, Height = 24 };
        ok.Pressed = () => { result = field.Text; window.Close(); };
        cancel.Pressed = () => window.Close();
        field.OnSubmit = text => { result = text; window.Close(); };
        window.Closed += (_, _) => done.TrySetResult(result);
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 10,
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 13, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family },
                new TextBlock { Text = message, FontSize = 12, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family, Foreground = Palette.Brush(Palette.Label) },
                field,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, ok } },
            },
        };
        window.Opened += (_, _) => field.FocusField();
        if (Owner is { IsVisible: true } owner) window.ShowDialog(owner); else window.Show();
        return done.Task;
    }

    public static async Task<string?> OpenFile(string title, IReadOnlyList<string> extensions, bool allowsDirectories = false)
    {
        if (Owner?.StorageProvider is not { } storage) return null;
        if (allowsDirectories && extensions.Count == 0)
        {
            var folders = await storage.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = title });
            return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
        }
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            AllowMultiple = false,
            FileTypeFilter = extensions.Count == 0 ? null : new[] { new FilePickerFileType(title) { Patterns = extensions.Select(e => "*." + e).ToList() } },
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    public static async Task<string?> SaveFile(string title, string name, IReadOnlyList<string> extensions, string? directory)
    {
        if (Owner?.StorageProvider is not { } storage) return null;
        var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = title,
            SuggestedFileName = name,
            DefaultExtension = extensions.FirstOrDefault(),
            FileTypeChoices = extensions.Count == 0 ? null : new[] { new FilePickerFileType(title) { Patterns = extensions.Select(e => "*." + e).ToList() } },
            SuggestedStartLocation = directory != null ? await storage.TryGetFolderFromPathAsync(directory) : null,
        });
        return file?.TryGetLocalPath();
    }
}
