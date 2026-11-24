// =============================================================================
//  AppState.Live.cs — що в залі: показати, сховати, стиль слайда
// =============================================================================
//  Як відповідні частини AppState.swift: перегляд (Slide) і зал (LiveSlide) —
//  різні речі. «Показати» (F5, Enter, подвійне клацання) кладе в зал те, що в
//  перегляді; «Сховати» (Esc) гасить зал тим самим розчиненням, на стіні
//  лишається фон. Стиль слайда — з Slovo.ini (як OutputConfiguration на Mac).
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    SlideStyle? _style;
    /// Стиль слайда в залі й у перегляді.
    public SlideStyle Style
    {
        get
        {
            if (_style is { } ready) return ready;
            try
            {
                if (IniSettings.LocateConfig() is { } ini) _style = new SlideStyle(IniSettings.FromFile(ini), "Bible", DataHome.Folder);
            }
            catch (Exception error) { Journal.Say($"стиль слайда з Slovo.ini не прочитався: {error.Message}"); }
            _style ??= new SlideStyle();
            return _style.Value;
        }
        set { _style = value; SlideChanged?.Invoke(); LiveChanged?.Invoke(); }
    }

    bool _isLive;
    public bool IsLive
    {
        get => _isLive;
        private set { if (_isLive == value) return; _isLive = value; SyncMediaWithLive(); }
    }
    /// «Активна»: стрілки й гортання одразу виводять слайд у зал (як arrowsShowLive на Mac).
    public bool ArrowsShowLive
    {
        get => !Defaults.Has("arrowsShowLive") || Defaults.Bool("arrowsShowLive");
        set => Defaults.Set("arrowsShowLive", value);
    }
    public Slide LiveSlide { get; private set; } = Slide.Blank;
    /// F12 — затемнення: чорний екран, ні тексту, ні фону.
    public bool IsBlackout { get; private set; }
    /// Ctrl+F5 — фон без тексту: пауза в подачі, але екран не гасне.
    public bool IsTextHidden { get; private set; }
    public event Action? LiveChanged;

    /// «Показати» (подвійне клацання, Enter, F5): те, що в перегляді, — у зал;
    /// показ був вимкнений — вмикається, як в оригіналі.
    public void ShowCurrentSlide()
    {
        var showTab = Mode is WorkMode.Text or WorkMode.Pictures or WorkMode.Presentation or WorkMode.Media;
        // «Показати» після затемнення мусить повернути картину на будь-якій вкладці.
        if (showTab && (IsBlackout || IsTextHidden)) { ResumeFromHiddenStates(); RefreshSlide(); }
        // Enter і F5 на вкладці «Текст» виводять сторінку набору.
        if (Mode == WorkMode.Text && TextModuleModel.Shared.ShowIfReady()) return;
        // У показі картинок і презентацій у зал іде сторінка показу.
        if (ShowTabs.TryGetValue(Mode, out var show) && show.ShowIfReady()) return;
        // «Показати» на вкладці «Медіа» — кадр плеєра в зал.
        if (Mode == WorkMode.Media) { ShowMediaInHall(); return; }
        // Вкладкам без свого тексту нічого виводити «по-старому» (чужий слайд з іншої вкладки).
        if (Mode is WorkMode.Pictures or WorkMode.Presentation) return;
        if (Mode == WorkMode.Text) return;
        // Показ при затемненні чи порожньому слайді мусить ПОВЕРНУТИ картину.
        if (IsBlackout || IsTextHidden) { ResumeFromHiddenStates(); RefreshSlide(); }
        LiveStill = null;
        LiveSlide = Slide;
        MarkLive();
        HallTakesText();
        IsLive = true;
        Journal.Say($"зал: {Slide.Reference}");
        RememberLive();
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    /// «Сховати»: зал гасне розчиненням, на стіні лишається фон.
    public void HideSlide()
    {
        if (!IsLive) return;
        IsLive = false;
        ResumeFromHiddenStates();
        LiveStill = null;
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    /// Що зараз бачить зал. Гасять його три речі: показ вимкнено, затемнення
    /// (F12), «фон без тексту» (Ctrl+F5) — відповідь одна на всі виводи.
    public Slide HallSlide => IsLive && !IsBlackout && !IsTextHidden ? LiveSlide : Slide.Blank;

    /// Слайд іде в зал: запам'ятати, звідки він (шаблон пісень чи спільний).
    void MarkLive()
    {
        _liveIsSong = Mode == WorkMode.Songs;
        // Підписи слайда в залі — зняті в мить виводу: інша пісня в передпоказі не
        // міняє назви під слайдом, що вже стоїть у залі.
        _liveSongTitle = _shownSong?.Song.Title ?? "";
    }

    void ResumeFromHiddenStates()
    {
        IsBlackout = false;
        IsTextHidden = false;
        // Відео в залі гасне разом із затемненням і порожнім слайдом — разом і вертається.
        _media?.Allow(MediaPlayerModel.ScreenSuppression.Blackout | MediaPlayerModel.ScreenSuppression.BlankSlide);
    }

    /// F12 — перемикач затемнення. Друге натискання повертає слайд, що стояв.
    public void ShowBlackScreen()
    {
        if (IsBlackout)
        {
            ResumeFromHiddenStates();
            RefreshSlide();
            LiveSlide = Slide;
            MarkLive();
            // Повернувся кадр плеєра — живий слайд під ним гаситься (інакше після
            // «Зупинити» з-під фільму виринав би вірш).
            if (_media is { IsVideoOnScreen: true }) LiveSlide = Slide.Blank;
        }
        else
        {
            LiveStill = null;
            LiveSlide = Slide;
            MarkLive();
            IsBlackout = true;
            IsLive = true;
            // «Затемнення — чорний екран» без застережень: кадр відео поверх лишитися не може.
            _media?.Suppress(MediaPlayerModel.ScreenSuppression.Blackout);
        }
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    /// Ctrl+F5 — фон без тексту.
    public void ShowBlankSlide()
    {
        LiveStill = null;
        LiveSlide = Slide;
        MarkLive();
        IsBlackout = false;
        IsTextHidden = true;
        IsLive = true;
        if (_media != null)
        {
            _media.Allow(MediaPlayerModel.ScreenSuppression.Blackout);
            _media.Suppress(MediaPlayerModel.ScreenSuppression.BlankSlide);
        }
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    /// Картинка в залі (вкладки «Зображення»/«Презентація») — шлях до файла; null — слайд.
    public string? LiveStill { get; private set; }
    public bool StillShown => LiveStill != null;
    /// Картинка в перегляді (вибрана на вкладці показу).
    public string? PreviewStill { get; private set; }

    /// Сторінка показу з пам'яті (презентація): кадр — під ключем сторінки.
    public void ShowStill(string key, SkiaSharp.SKImage image, string title = "")
    {
        SlideImageStore.Shared.Pin(key, image);
        ShowStill(key, title);
    }

    /// Підпис того, що в залі від показу («Проповідь — Слайд 3») — для пульта.
    public string LiveStillTitle { get; private set; } = "";

    /// Прибрати картинку з залу (кнопка «Сховати» на вкладці показу).
    public void ClearStill()
    {
        if (LiveStill == null) return;
        LiveStill = null;
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    public void ShowStill(string path, string title = "")
    {
        LiveStillTitle = title.Length > 0 ? title : Path.GetFileNameWithoutExtension(path);
        // Наближення стосується лише сторінки, на якій його зробили: інша (і та
        // сама після повернення) приходить цілою.
        if (!(IsLive && LiveStill == path)) SlideFocus.Shared.DropForNewPage();
        LiveStill = path;
        StillTakesHall();
        IsLive = true;
        LiveSlide = Slide.Blank;
        Journal.Say($"зал: картинка {(path.Contains('|') ? path : Path.GetFileName(path))}");
        Signals.Shared.Send(Signals.Kind.Live);
        LiveChanged?.Invoke();
    }

    public void SetPreviewStill(string? path)
    {
        PreviewStill = path;
        SlideChanged?.Invoke();
    }
}
