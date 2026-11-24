// =============================================================================
//  AppState.Media.cs — медіаплеєр і зал (як media.onScreenChanged/onWantsHall на Mac)
// =============================================================================
//  Екран у залі один: поки на ньому кадр плеєра, текст «живим» не лишається
//  (інакше після паузи чи кінця фільму з-під кадру виринав би вчорашній вірш).
//  Текст чи картинка, що пішли в зал, ставлять кадру поступку; «Показати» на
//  вкладці «Медіа» й «грати» її знімають. Затемнення, «Сховати» й порожній
//  слайд гасять і відео.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    MediaPlayerModel? _media;

    /// Медіаплеєр — один на програму.
    public MediaPlayerModel Media
    {
        get
        {
            if (_media != null) return _media;
            var media = _media = new MediaPlayerModel { RemembersPlaylist = !Program.Snapshotting };
            media.RestorePlaylist();
            media.ReloadSettingsFromDisk(Path.GetDirectoryName(ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')));
            media.OnScreenChanged = () =>
            {
                // Кадр на екрані — живий слайд гасимо, а не ховаємо під кадр.
                if (media.IsVideoOnScreen && !LiveSlide.IsBlank) LiveSlide = Slide.Blank;
                MediaScreenChanged?.Invoke();
                Signals.Shared.Send(Signals.Kind.Live);
                LiveChanged?.Invoke();
            };
            media.OnWantsHall = () => ShowMediaInHall();
            return media;
        }
    }

    BackingTrackPlayer? _backing;

    /// Фонограми вкладки «Пісні» — свій плеєр зі своїм списком (на Mac `backing`).
    /// Список і відкритий файл переживають закриття програми — але не в знімках.
    public BackingTrackPlayer Backing
    {
        get
        {
            if (_backing != null) return _backing;
            var backing = _backing = new BackingTrackPlayer { Remembers = !Program.Snapshotting };
            backing.Restore();
            return backing;
        }
    }

    /// Кадр плеєра в залі з'явився чи зник — виводам перемалюватися.
    public event Action? MediaScreenChanged;

    /// За скільки кадр плеєра з'являється й гасне в залі (на Mac `mediaFade`, 0,35 с).
    public static double MediaFadeSeconds => Defaults.Has("mediaFade") ? Math.Clamp(Defaults.Double("mediaFade"), 0, 5) : 0.35;

    /// Кадр плеєра в зал — те саме, що «Показати» для вірша. false — показувати нічого.
    public bool ShowMediaInHall()
    {
        var media = Media;
        if (media.MediaUrl == null) return false;
        media.Allow(MediaPlayerModel.ScreenSuppression.SlideTookOver | MediaPlayerModel.ScreenSuppression.Stopped);
        if (!media.VideoToScreen) media.VideoToScreen = true;
        LiveStill = null;
        if (IsBlackout || IsTextHidden) ResumeFromHiddenStates();
        if (!IsLive) IsLive = true;
        if (media.IsVideoOnScreen && !LiveSlide.IsBlank) LiveSlide = Slide.Blank;
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
        MediaScreenChanged?.Invoke();
        return true;
    }

    /// Текст зайняв екран у залі: є кадр плеєра (видимий чи ні) — поступка тексту.
    /// Питаємо «чи є кадр», а не «чи видно»: після «Сховати» кадр знято зі стіни, але
    /// файл нікуди не дівся, і «Показати» вірша мусить відсунути саме його.
    void HallTakesText()
    {
        if (_media is not { HasMedia: true } media) return;
        media.Suppress(MediaPlayerModel.ScreenSuppression.SlideTookOver);
    }

    /// Картинка показу пішла в зал: фільм поступається (звуковий файл грає далі —
    /// фонограма під сторінки презентації звична річ; на Mac так само).
    void StillTakesHall()
    {
        // Картинка чи сторінка показу — захоплення екрана поступається зовсім (як showStill на Mac).
        _media?.YieldCapture();
        if (_media is not { HasMedia: true } media) return;
        if (media.HasVideo) media.Close();
        else media.Suppress(MediaPlayerModel.ScreenSuppression.SlideTookOver);
    }

    /// Показ вимкнено — і кадр плеєра теж зі стіни («Сховати» гасить і відео).
    void SyncMediaWithLive()
    {
        if (_media is not { } media) return;
        if (IsLive) media.Allow(MediaPlayerModel.ScreenSuppression.HiddenSlide);
        else media.Suppress(MediaPlayerModel.ScreenSuppression.HiddenSlide);
    }
}
