// =============================================================================
//  AppState.Screen.cs — захоплення екрана з боку стану програми (AppState+Screen.swift)
// =============================================================================
//  Тут навмисно немає нічого свого: ні окремого вікна на проекторі, ні окремої
//  дороги в мережу. Кадр віддається плеєру, а далі все вже написане — зал,
//  живий екран, указка, «Сховати» і затемнення.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    ScreenCaptureModel? _screenCapture;

    /// Модель захоплення: заводиться першим зверненням.
    public ScreenCaptureModel ScreenCapture
    {
        get
        {
            if (_screenCapture != null) return _screenCapture;
            var fresh = _screenCapture = new ScreenCaptureModel();
            // Плеєр сам знімає захоплення, коли в зал показують щось інше; зупинити треба
            // й сам потік, інакше він далі гріє машину.
            Media.StopCaptureStream = () => fresh.Stop();
            fresh.LostSource = () => Media.EndCapture();
            return fresh;
        }
    }

    /// Почати показ монітора чи вікна. Як для картинки: натиснули «Показати» — показати.
    public void ShowCapturedScreen(ScreenCaptureModel.Source source)
    {
        var capture = ScreenCapture;
        Media.BeginCapture(source.Title);
        if (!capture.Start(source))
        {
            Media.EndCapture();
            return;
        }
        LiveStill = null;
        if (!IsLive) IsLive = true;
        if (Media.IsVideoOnScreen && !LiveSlide.IsBlank) LiveSlide = Slide.Blank;
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
        MediaScreenChanged?.Invoke();
    }

    /// Зупинити показ екрана.
    public void StopCapturedScreen()
    {
        ScreenCapture.Stop();
        Media.EndCapture();
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
        MediaScreenChanged?.Invoke();
    }
}
