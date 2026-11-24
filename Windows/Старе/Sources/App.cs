// =============================================================================
//  App.cs — тема й перше вікно
// =============================================================================

using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace Slovo;

public sealed class App : Application
{
    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = ThemeVariant.Light;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var state = AppState.Shared;
            desktop.MainWindow = new Views.MainWindow(state);
            desktop.ShutdownRequested += (_, _) => state.Shutdown();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
