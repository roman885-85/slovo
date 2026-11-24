// =============================================================================
//  InterfaceSettings.cs — розділ 7 посібника «Інтерфейс» (як InterfaceSettings.swift)
// =============================================================================
//  Вигляд вікна вибору Книги (кнопки (22), меню N8–N11), вигляд списку віршів
//  (кнопки (21)), «Пам'ять» (N17) і оформлення (7.2). Вигляд списків свій у
//  кожного режиму: Біблія, Текст, Пісні — як три пари в VisioBible.ini
//  ([Bible] LinesStyle/BooksStyle, [Text], [Songs]). Перший запуск (і запуск
//  із вимкненою «Пам'яттю») бере вигляд із файла умовчань програми.
// =============================================================================

using Avalonia.Styling;
using Slovo.Core;

namespace Slovo.App;

public sealed class InterfaceSettings
{
    public static readonly InterfaceSettings Shared = new();

    /// Режим, для якого питають вигляд списків.
    public enum ListScope { Bible, Text, Songs }

    /// Вигляд вікна вибору Книги (2): чотири пункти меню «Інтерфейс»; кнопки
    /// (22) дають лише крайні два — «плиткою» (.Icons) і «списком» (.List).
    public enum BookViewMode { Icons, SmallIcons, List, Table }

    /// Вигляд списку віршів (4), кнопки (21): LinesStyle 0 — багаторядковий, 1 — в одну лінію.
    public enum VerseViewMode { Multiline, SingleLine }

    /// Оформлення (7.2): по системі, світле, темне.
    public enum Appearance { System, Light, Dark }

    readonly Dictionary<ListScope, BookViewMode> _bookViews = new();
    readonly Dictionary<ListScope, VerseViewMode> _verseViews = new();
    Appearance _appearance;
    bool _remembers;

    static string Raw(ListScope s) => s switch { ListScope.Text => "text", ListScope.Songs => "songs", _ => "bible" };
    static string IniSection(ListScope s) => s switch { ListScope.Text => "Text", ListScope.Songs => "Songs", _ => "Bible" };
    static string BookKey(ListScope s) => $"interface.bookView.{Raw(s)}";
    static string VerseKey(ListScope s) => $"interface.verseView.{Raw(s)}";
    const string AppearanceKey = "interface.appearance", MemoryKey = "interface.memory";

    public static string RawValue(BookViewMode m) => m switch
    {
        BookViewMode.SmallIcons => "smallIcons", BookViewMode.List => "list", BookViewMode.Table => "table", _ => "icons",
    };
    static BookViewMode? BookFrom(string? raw) => raw switch
    {
        "icons" => BookViewMode.Icons, "smallIcons" => BookViewMode.SmallIcons, "list" => BookViewMode.List, "table" => BookViewMode.Table, _ => null,
    };
    static VerseViewMode? VerseFrom(string? raw) => raw switch
    {
        "multiline" => VerseViewMode.Multiline, "singleLine" => VerseViewMode.SingleLine, _ => null,
    };
    static string RawValue(VerseViewMode m) => m == VerseViewMode.SingleLine ? "singleLine" : "multiline";

    /// Ключ підпису в файлі перекладу (MainForm) і запасний підпис.
    public static (string Key, string Fallback, string Symbol) Caption(BookViewMode m) => m switch
    {
        BookViewMode.SmallIcons => ("N9", "Мал. значки", "square.grid.3x3"),
        BookViewMode.List => ("N10", "Список", "list.bullet"),
        BookViewMode.Table => ("N11", "Таблица", "tablecells"),
        _ => ("N8", "Значки", "square.grid.2x2"),
    };

    /// Кнопки (21): у оригіналу без підпису — лише підказка.
    public static (string HintKey, string Fallback, string Symbol) Caption(VerseViewMode m) => m == VerseViewMode.SingleLine
        ? ("PngSBOneLine", "Текст в одну линию", "rectangle.compress.vertical")
        : ("PngSBmanyLines", "Многострочный текст", "rectangle.expand.vertical");

    /// У пісенника своя пара кнопок (21): ключі з приставкою вкладеної форми.
    public static string HintPrefix(ListScope s) => s == ListScope.Songs ? "SongsPluginFrame->" : "";

    InterfaceSettings()
    {
        _remembers = !Defaults.Has(MemoryKey) || Defaults.Bool(MemoryKey);
        IniSettings? original = null;
        try { if (IniSettings.LocateConfig() is { } path) original = IniSettings.FromFile(path); } catch { }
        foreach (var scope in Enum.GetValues<ListScope>())
        {
            var iniBooks = original?.Int("BooksStyle", IniSection(scope)) ?? 0;
            var iniLines = original?.Int("LinesStyle", IniSection(scope)) ?? 0;
            _bookViews[scope] = (_remembers ? BookFrom(Defaults.String(BookKey(scope))) : null)
                                ?? (iniBooks == 1 ? BookViewMode.List : BookViewMode.Icons);
            _verseViews[scope] = (_remembers ? VerseFrom(Defaults.String(VerseKey(scope))) : null)
                                 ?? (iniLines == 1 ? VerseViewMode.SingleLine : VerseViewMode.Multiline);
        }
        _appearance = Defaults.String(AppearanceKey) switch
        {
            "light" => Appearance.Light, "dark" => Appearance.Dark, _ => Appearance.System,
        };
    }

    public BookViewMode BookView(ListScope scope) => _bookViews.TryGetValue(scope, out var m) ? m : BookViewMode.Icons;
    public VerseViewMode VerseView(ListScope scope) => _verseViews.TryGetValue(scope, out var m) ? m : VerseViewMode.Multiline;

    public void SetBookView(BookViewMode mode, ListScope scope)
    {
        _bookViews[scope] = mode;
        StoreViews();
        Signals.Shared.Send(Signals.Kind.ListKind);
    }

    public void SetVerseView(VerseViewMode mode, ListScope scope)
    {
        _verseViews[scope] = mode;
        StoreViews();
        Signals.Shared.Send(Signals.Kind.ListKind);
    }

    /// Кнопки (22): «плиткою» — «списком».
    public void SetBooksFlow(bool flow, ListScope scope) => SetBookView(flow ? BookViewMode.Icons : BookViewMode.List, scope);
    public bool BooksAreFlowing(ListScope scope) => BookView(scope) is BookViewMode.Icons or BookViewMode.SmallIcons;

    /// N17 «Пам'ять»: запам'ятовувати вигляд списків між запусками.
    public bool RemembersLayout
    {
        get => _remembers;
        set
        {
            _remembers = value;
            Defaults.Set(MemoryKey, value);
            // Увімкнули пам'ять — одразу закріплюємо те, що видно зараз.
            if (value) WriteViews();
            Signals.Shared.Send(Signals.Kind.ListKind);
        }
    }

    /// Оформлення (7.2) — живе й за вимкненої «Пам'яті»: це вибір людини.
    public Appearance Look
    {
        get => _appearance;
        set
        {
            _appearance = value;
            Defaults.Set(AppearanceKey, value switch { Appearance.Light => "light", Appearance.Dark => "dark", _ => "system" });
            ApplyAppearance();
        }
    }

    public void ApplyAppearance()
    {
        if (Avalonia.Application.Current is not { } app) return;
        app.RequestedThemeVariant = _appearance switch
        {
            Appearance.Light => ThemeVariant.Light, Appearance.Dark => ThemeVariant.Dark, _ => ThemeVariant.Default,
        };
        Palette.NotifyChanged();
    }

    void StoreViews() { if (_remembers) WriteViews(); }

    void WriteViews()
    {
        foreach (var scope in Enum.GetValues<ListScope>())
        {
            Defaults.Set(BookKey(scope), RawValue(BookView(scope)));
            Defaults.Set(VerseKey(scope), RawValue(VerseView(scope)));
        }
    }
}
