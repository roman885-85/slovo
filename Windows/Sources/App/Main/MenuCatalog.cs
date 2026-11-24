// =============================================================================
//  MenuCatalog.cs — склад меню (як SlovoMenu / MenuCatalog.swift на Mac)
// =============================================================================
//  Один список на все місця, де меню показують. Підписи — з файла перекладу
//  автора (N24, N25…) або наш словник. Пункт без дії — сірий: його вікно ще не
//  перенесено на Windows (див. ПАРИТЕТ.md).
// =============================================================================

using System.Diagnostics;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public static class MenuCatalog
{
    static string C(string key, string fallback) => Captions.Caption(key, fallback).Replace("&", "");
    static string K(string action, string fallback) => EffectiveHotkeys.Hotkey(action)?.Text is { Length: > 0 } text ? text : fallback;

    /// Пункти розділу — опис вікна Mac (SlovoMenu): ті самі ключі підписів і той самий
    /// порядок. Пункт без дії — сірий: його вікно ще переноситься (ПАРИТЕТ.md).
    public static IReadOnlyList<MenuEntry> Entries(MenuGroup group, AppState state) => group switch
    {
        MenuGroup.File => new[]
        {
            new MenuEntry(Captions.T("Импорт модулей, шаблонов и фонов…"), () => ImportWizardWindow.Open()),
            new MenuEntry(Captions.T("Перечитать настройки"), () => RereadSettings(state)),
            new MenuEntry(Captions.T("Выбрать папку с модулями…"), () => _ = ChooseModules(state), Key: "Ctrl+O"),
        },
        MenuGroup.Actions => new[]
        {
            new MenuEntry(C("N24", "Показать слайд"), state.ShowCurrentSlide, Key: K("ShowSlide", "F5")),
            new MenuEntry(C("N25", "Скрыть слайд"), state.HideSlide, Key: K("HideSlide", "Escape")),
            new MenuEntry(C("N35", "Показать пустой слайд"), state.ShowBlankSlide, Key: K("ShowBlankSlide", "Ctrl+F5")),
            new MenuEntry(C("N34", "Показать/скрыть затемнение экрана"), state.ShowBlackScreen, Key: K("ShowBlackScreen", "F12")),
            new MenuEntry(C("N30", "Отображать Общий фон (Вкл/Выкл)"), state.ToggleBackground, Key: K("ShowBackGrOnSlide", "Ctrl+F9"), StartsGroup: true),
            new MenuEntry(C("N28", "Сделать снимок экрана слайда"), state.SaveScreenshot, Key: K("ScreenShot", "F11")),
            // Медіаплеєр і результати пошуку міняють саму розкладку вікна.
            new MenuEntry(Captions.T("Медиаплеер"), () => { state.Mode = WorkMode.Media; Signals.Shared.Send(Signals.Kind.Mode); },
                          state.Mode == WorkMode.Media, StartsGroup: true),
            new MenuEntry(C("N22", "Установить фокус на Стихи/Текст"), () => KeyHandling.FocusVerses?.Invoke(), Key: K("MainWin", "F6"), StartsGroup: true),
            new MenuEntry(C("N19", "Установить фокус на План"), () => KeyHandling.FocusPlan?.Invoke()),
            new MenuEntry(C("N20", "Поиск"), state.FocusSearchField, StartsGroup: true),
            new MenuEntry(C("N29", "Показать/скрыть результаты поиска"), state.ToggleSearchResults, state.IsSearchResultsShown),
            new MenuEntry(C("N21", "Быстрый выбор"), () => KeyHandling.FocusAddress?.Invoke()),
            new MenuEntry(C("N31", "Быстрый выбор Книги/Песни вводом её названия"), () => KeyHandling.FocusQuick?.Invoke(KeyHandling.QuickFieldKind.Book)),
            new MenuEntry(C("N32", "Быстрый выбор Главы вводом её номера"), () => KeyHandling.FocusQuick?.Invoke(KeyHandling.QuickFieldKind.Chapter)),
            new MenuEntry(C("N33", "Быстрый выбор Стиха/Текста вводом части текста"), () => KeyHandling.FocusQuick?.Invoke(KeyHandling.QuickFieldKind.Verse)),
            // На Mac — ⌘ зі стрілками; на Windows Ctrl зі стрілками міняє пари стрілок (5.1.4),
            // тож тут Alt.
            new MenuEntry(Captions.T("Следующий стих"), () => state.StepVerse(1), Key: "Alt+Right", StartsGroup: true),
            new MenuEntry(Captions.T("Предыдущий стих"), () => state.StepVerse(-1), Key: "Alt+Left"),
            new MenuEntry(Captions.T("Следующая глава"), () => state.StepChapter(1), Key: "Alt+Down"),
            new MenuEntry(Captions.T("Предыдущая глава"), () => state.StepChapter(-1), Key: "Alt+Up"),
        },
        MenuGroup.Settings => new[]
        {
            new MenuEntry(Captions.T("Настройки…"), OpenSettings, Key: "Ctrl+OemComma"),
            new MenuEntry(Captions.T("Пульт в браузере…"), () => BrowserRemoteWindow.Open()),
            new MenuEntry(Captions.T("Программы для Android…"), () => AndroidAppsWindow.Open()),
            new MenuEntry(Captions.T("Ресурсы с GitHub…"), () => ResourcesWindow.Open()),
            new MenuEntry(Captions.T("Папка данных в Проводнике…"), () => Explorer.Show(DataHome.Folder)),
            new MenuEntry(Captions.T("Проверить обновление программы…"), () => _ = AppUpdater.CheckNow()),
            new MenuEntry(C("N42", "Конструктор слайда"), () => SlideConstructorWindow.Open(state)),
            new MenuEntry(Captions.T("Редактор веб-слайдов…"), () => WebSlideEditorWindow.Open(state)),
            new MenuEntry(C("N40", "Редактор несоответствий нумерации переводов Библии"), () => NumberingEditorWindow.Open(state)),
        },
        MenuGroup.Interface => InterfaceEntries(state),
        MenuGroup.Language => LanguageEntries(),
        _ => new[]
        {
            new MenuEntry(C("N6", "Помощь"), () => HelpWindow.Open(), Key: "Ctrl+Shift+OemQuestion"),
            new MenuEntry(Captions.T("Горячие клавиши"), () => HelpWindow.Open("keys")),
            new MenuEntry(Captions.T("Если что-то не так"), () => HelpWindow.Open("trouble")),
            new MenuEntry(Captions.T("Установка на другой компьютер (GitHub)"), () => Open(WindowsGuide)),
            new MenuEntry(Captions.T("Документация на GitHub"), () => Open(Docs)),
            new MenuEntry(Captions.T("Пульт в браузере…"), () => BrowserRemoteWindow.Open()),
            new MenuEntry(Captions.T("Программы для Android…"), () => AndroidAppsWindow.Open()),
            new MenuEntry(Captions.T("Диагностика…"), () => Diagnostics.Show(state)),
            new MenuEntry(C("N5", "О программе..."), About),
        },
    };

    const string Docs = "https://github.com/roman885-85/slovo";
    const string WindowsGuide = "https://github.com/roman885-85/slovo/blob/main/Windows/ЧИТАТЬ.md";

    /// «Інтерфейс» (N39): чотири види вікна вибору Книги (N8–N11), «Пам'ять» (N17),
    /// оформлення (7.2).
    static IReadOnlyList<MenuEntry> InterfaceEntries(AppState state)
    {
        var settings = InterfaceSettings.Shared;
        var scope = state.ListScope;
        var list = Enum.GetValues<InterfaceSettings.BookViewMode>().Select(mode =>
        {
            var (key, fallback, _) = InterfaceSettings.Caption(mode);
            return new MenuEntry(C(key, fallback), () => settings.SetBookView(mode, scope), settings.BookView(scope) == mode);
        }).ToList();
        list.Add(new MenuEntry(C("N17", "Память"), () => settings.RemembersLayout = !settings.RemembersLayout, settings.RemembersLayout));
        // Оформлення — у вікні «Стиль інтерфейсу програми» (7.2), як на Mac.
        list.Add(new MenuEntry(Captions.T("Стиль интерфейса программы…"), () => InterfaceStyleWindow.Open(state), StartsGroup: true));
        list.Add(new MenuEntry(C("N41", "Перевод интерфейса") + "…", () => LocalizeWindow.Open(state)));
        return list;
    }

    /// «Language/Мова» (N14): вибір мови — і вбудовані мови.
    static IReadOnlyList<MenuEntry> LanguageEntries()
    {
        var list = new List<MenuEntry>
        {
            new(Captions.FormCaption("Label1", "SelectLangForm", "Выберите язык интерфейса программы") + "…", () => LanguagePickerWindow.Open()),
        };
        // Файли перекладу оригіналу й свої, потім убудовані мови, яких серед файлів немає.
        var first = true;
        foreach (var (code, name, _) in LanguagePickerWindow.All())
        {
            var chosen = code;
            list.Add(new MenuEntry(name, () => Languages.Set(chosen, DataHome.Folder), string.Equals(Languages.Code, code, StringComparison.OrdinalIgnoreCase), StartsGroup: first));
            first = false;
        }
        return list;
    }

    /// «Перечитати налаштування»: бібліотека заново і звідки прочитано.
    static void RereadSettings(AppState state)
    {
        SettingsStore.Shared.Reload(DataHome.Folder);
        state.ReloadLibrary();
        var path = IniSettings.LocateConfig();
        Alert.Tell(Captions.T("Настройки перечитаны"),
                   path != null ? Captions.T("Из файла:") + "\n" + path : Captions.T("Файл настроек не найден — оставлены прежние значения."),
                   "Закрыть");
    }

    /// «Вибрати теку з модулями…» — тека Modules з модулями «Цитати з Біблії».
    static async Task ChooseModules(AppState state)
    {
        if (MainWindow.Shared?.StorageProvider is not { } storage) return;
        var folders = await storage.OpenFolderPickerAsync(new Avalonia.Platform.Storage.FolderPickerOpenOptions
        {
            Title = Captions.T("Папка Modules с модулями «Цитаты из Библии»"),
            AllowMultiple = false,
        });
        if (folders.Count == 0 || folders[0].TryGetLocalPath() is not { } path) return;
        state.ModulesFolder = path;
    }

    static void About()
    {
        Alert.Ask(Captions.T("Слово") + " " + AppUpdater.CurrentVersion,
                  Captions.T("Версия %s", AppUpdater.CurrentVersion + " (Windows)") + "\n\n"
                  + Captions.T("Программа для показа Библии, песен, медиа и презентаций на служении — Windows. "
                  + "Читает модули «Цитаты из Библии» и MyBible, песенники .vbm, шаблоны слайдов."),
                  new[] { Captions.T("Закрыть"), Captions.T("Проверить обновление") },
                  answer => { if (answer == 1) _ = AppUpdater.CheckNow(); });
    }

    public static void OpenSettings()
    {
        if (SettingsWindow.Shared is { IsVisible: true } open) { open.Activate(); return; }
        var store = SettingsStore.Shared;
        var session = store.BeginEditing();
        var window = new SettingsWindow();
        window.BuildTabs(store);
        var accepted = false;
        window.OnAccept = () => { accepted = true; store.Save(session); window.Close(); };
        window.OnDiscard = () => window.Close();
        window.OnExport = () => { };
        window.Closed += (_, _) => { if (!accepted) store.CancelIfEditing(session); };
        if (MainWindow.Shared is { } main) window.Show(main); else window.Show();
    }


    static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { Journal.Say($"посилання не відкрилось: {error.Message}"); }
    }
}
