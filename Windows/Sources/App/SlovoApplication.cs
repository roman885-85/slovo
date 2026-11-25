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
        // Поля введення — як NSTextField на Mac: своє тло й тонкий обідок у КОЖНОМУ стані, у фокусі теж.
        // Раніше тут усім полям програми ставилося прозоре тло без обідка (задумано для швидких полів,
        // що малюють рамку самі), — і поле розмітки веб-слайда, а в фокусі й поле вікна «Додати
        // посилання», зливалися з вікном (власник 24.11: «часть окон и меню в которых вставляется
        // текст сливаются с фоном»). Тепер прозорі лише поля з класом «bare» — див. Slovo.App.FieldLook.
        Slovo.App.FieldLook.Install(this);
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
            // Сторож головного потоку (як на Mac): затримки від 1 с — у журнал.
            Slovo.App.MainThreadWatchdog.Shared.Start();
            // Кожне вікно — не більше за екран (ноутбуки 1366×768 зі збільшенням).
            Slovo.App.ScreenFit.Install();
            // LibVLC піднімається у фоні: перший його запуск у Windows — секунди (≈150 модулів), і
            // в головному потоці це було «Програма не відповідає» (власник, «Параметри», 1.4.2).
            // Не одразу й з найнижчим пріоритетом: запуск сам по собі важкий (бібліотека, вікна, пошук).
            if (!Slovo.Program.Snapshotting)
                new System.Threading.Thread(() => { System.Threading.Thread.Sleep(15000); Slovo.App.MediaEngine.EnsureLoaded(); })
                    { IsBackground = true, Priority = System.Threading.ThreadPriority.Lowest, Name = "slovo-libvlc-warmup" }.Start();
            // Захопленню звуку програми: чи грає щось у самому процесі (не рушій WebView2).
            Slovo.App.AppAudioCapture.InProcessPlaying = () =>
                (Slovo.App.AppState.Shared.Media.IsPlaying && !Slovo.App.AppState.Shared.Media.IsYouTubeEmbed) || Slovo.App.AppState.Shared.Backing.IsPlaying;
            if (Slovo.Program.LiveBenchReport is { } report) Slovo.App.LiveBench.Start(report);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
