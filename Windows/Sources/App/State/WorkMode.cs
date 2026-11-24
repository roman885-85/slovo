// =============================================================================
//  WorkMode.cs — режими (вкладки) головного вікна і класи книг
// =============================================================================
//  Як AppStateUI.swift: порядок вкладок задав власник — Біблія, Пісні,
//  Презентація, Медіа, Зображення, Екран, Текст. Назви режимів у файлі
//  налаштувань — ті самі, що на Mac (rawValue), запам'ятований режим читається.
// =============================================================================

namespace Slovo.App;

public enum WorkMode { Bible, Songs, Presentation, Media, Pictures, Screen, Text }

public enum BookClass { All, Old, New, Apocrypha }

public static class WorkModeInfo
{
    public static readonly WorkMode[] All =
        { WorkMode.Bible, WorkMode.Songs, WorkMode.Presentation, WorkMode.Media, WorkMode.Pictures, WorkMode.Screen, WorkMode.Text };

    public static string RawValue(this WorkMode mode) => mode switch
    {
        WorkMode.Bible => "bible", WorkMode.Songs => "songs", WorkMode.Presentation => "presentation",
        WorkMode.Media => "media", WorkMode.Pictures => "pictures", WorkMode.Screen => "screen", _ => "text",
    };

    public static WorkMode? FromRaw(string? raw) => All.Cast<WorkMode?>().FirstOrDefault(m => m!.Value.RawValue() == raw);

    public static string Title(this WorkMode mode) => mode switch
    {
        WorkMode.Bible => Captions.T("Библия"),
        WorkMode.Text => Captions.T("Текст"),
        WorkMode.Songs => Captions.T("Песни"),
        WorkMode.Media => Captions.T("Медиа"),
        WorkMode.Pictures => Captions.T("Картинки"),
        WorkMode.Presentation => Captions.T("Презентация"),
        _ => Captions.T("Экран"),
    };

    /// Значок вкладки — ім'я як у Mac-версії (малюнок — Icons).
    public static string Icon(this WorkMode mode) => mode switch
    {
        WorkMode.Bible => "book.closed",
        WorkMode.Text => "doc.text",
        WorkMode.Songs => "music.note.list",
        WorkMode.Media => "play.rectangle",
        WorkMode.Pictures => "photo",
        WorkMode.Presentation => "rectangle.on.rectangle",
        _ => "macwindow.on.rectangle",
    };

    /// Підпис вкладки — з файла перекладу автора, де він там є (NativeTopCaptions.modeTitle).
    public static string TabTitle(this WorkMode mode) => mode switch
    {
        WorkMode.Bible => Captions.Caption("TSBible", mode.Title()),
        WorkMode.Text => Captions.Caption("TSText", mode.Title()),
        // У пісенника підпис вкладки автор поклав у поле підказки.
        WorkMode.Songs => Captions.MainHint("SongsPluginFrame", "Песни"),
        _ => mode.Title(),
    };

    public static string CaptionKey(this BookClass c) => c switch
    {
        BookClass.All => "TextMessages0", BookClass.Old => "TextMessages1",
        BookClass.New => "TextMessages2", _ => "TextMessages3",
    };

    public static string Title(this BookClass c) => c switch
    {
        BookClass.All => Captions.T("Вся Библия"), BookClass.Old => Captions.T("Ветх.Завет"),
        BookClass.New => Captions.T("Нов.Завет"), _ => Captions.T("Неканон."),
    };
}
