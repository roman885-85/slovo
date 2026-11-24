// =============================================================================
//  SlovoApplication.cs — програма Avalonia: оформлення і головне вікно
// =============================================================================
//  Основа — Fluent від Avalonia, але поля вводу без її рамок і підкреслень:
//  рамку кожне поле малює саме, як на Mac. Тема — за системою (або як
//  вибрано в «Інтерфейс → Стиль»).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace Slovo;

public sealed class SlovoApplication : Application
{
    public override void Initialize()
    {
        Name = "Слово";
        Styles.Add(new FluentTheme());
        // Поля вводу: прозорі, без обідка й підкреслення в будь-якому стані.
        foreach (var key in new[] { "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                                    "TextControlBackgroundDisabled", "TextControlBorderBrush", "TextControlBorderBrushPointerOver",
                                    "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled" })
            Resources[key] = Brushes.Transparent;
        Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        Resources["TextControlThemeMinHeight"] = 0.0;
        Resources["TextControlThemePadding"] = new Thickness(0);
        Resources["TextControlSelectionHighlightColor"] = new SolidColorBrush(Color.FromRgb(0x39, 0x8E, 0xFF));
        ActualThemeVariantChanged += (_, _) => Slovo.App.Palette.NotifyChanged();
        // Мова інтерфейсу — до того, як збудовано хоч одне вікно.
        Slovo.App.Languages.Load(Slovo.Core.DataHome.Folder);
        // Оформлення, вибране в «Інтерфейс» (як interface.appearance на Mac).
        RequestedThemeVariant = Slovo.App.Defaults.String("interface.appearance") switch
        {
            "light" => Avalonia.Styling.ThemeVariant.Light,
            "dark" => Avalonia.Styling.ThemeVariant.Dark,
            _ => Avalonia.Styling.ThemeVariant.Default,
        };
    }

    public override void OnFrameworkInitializationCompleted()
    {
        Slovo.App.ShowDocuments.Install();
        Slovo.App.ModuleImportWiring.Install();
        Slovo.App.ResourcesWindow.Install();
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            // Заставка, як у автора: поки читається бібліотека, видно ім'я програми й те, чим вона зайнята.
            Slovo.App.Splash.Show();
            Slovo.App.Splash.Say("Готовлю окно…");
            desktop.MainWindow = new Slovo.App.MainWindow(Slovo.App.AppState.Shared);
            Slovo.App.Splash.Say("Открываю библиотеку переводов…");
            if (!Slovo.App.AppState.Shared.IsLoadingLibrary) Slovo.App.Splash.Hide();
            // Свій yt-dlp — свіжий: раз на добу, у фоні (вимикається в «Параметри → Медіа»).
            if (!Slovo.Program.QuietStart) Slovo.App.YouTubeToolUpdater.CheckInBackground();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
