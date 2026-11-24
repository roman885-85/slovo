// =============================================================================
//  OutputDriver.cs — хто що малює: перегляд, живий екран, зал
// =============================================================================
//  Як pushToOutputs на Mac: будь-яка зміна слайда чи залу — замовлення в чергу
//  малювання з власним ключем; кадр приходить у фоні, застарілий не показується.
//  Обробка натискання не чекає на малювання — у цьому й весь секрет швидкості.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class OutputDriver
{
    readonly AppState _state;
    readonly BottomRow _bottom;
    int _previewGeneration, _hallGeneration, _mirrorGeneration;
    bool _previewScheduled, _hallScheduled;
    bool _hallAnimated;

    public OutputDriver(AppState state, BottomRow bottom)
    {
        _state = state;
        _bottom = bottom;
        state.SlideChanged += () => SchedulePreview();
        state.LiveChanged += () => ScheduleHall(true);
        ProjectionController.Shared.Redraw = animated => ScheduleHall(animated);
        bottom.Control.ShowButton.Pressed = state.ShowCurrentSlide;
        bottom.Control.HideButton.Pressed = state.HideSlide;
        state.ShowCurrent = state.ShowCurrentSlide;
        bottom.Preview.SizeChanged += (_, _) => SchedulePreview();
        bottom.Mirror.SizeChanged += (_, _) => ScheduleHall(false);
        Signals.Shared.Subscribe(Signals.Kind.Live, () => { bottom.Control.HideButton.IsEnabled = state.IsLive; bottom.Preview.IsLive = state.IsLive && state.LiveSlide.Equals(state.Slide); });
        bottom.Control.HideButton.IsEnabled = false;
        // Кнопки кроків «Керування» (як plan у NativeControlPanel): назад/вперед розділ і
        // вірш — лише передпоказ (stepVerse(by:) без зв'язки із залом), «Поточний» —
        // список до вибраного вірша, «Знімок» — F11.
        var steps = bottom.Control.StepButtons;
        steps[0].Pressed = () => state.StepChapter(-1);
        steps[1].Pressed = () => state.StepVerse(-1);
        steps[2].Pressed = state.ScrollToCurrentVerse;
        steps[3].Pressed = () => state.StepChapter(1);
        steps[4].Pressed = () => state.StepVerse(1);
        steps[5].Pressed = state.SaveScreenshot;
        // «Активна»: стрілки й гортання одразу виводять слайд у зал.
        bottom.Control.ActiveBox.IsChecked = state.ArrowsShowLive;
        bottom.Control.ActiveBox.Toggled += on => state.ArrowsShowLive = on;
        // Дзеркало проектора — кадр залу в його сторонах, по краях чорне (як на Mac).
        bottom.Mirror.Surface.FitsAspect = true;
        // Наближення їде плавно: кожен крок — новий кадр показаної сторінки (без переходу).
        SlideFocus.Shared.ShownChanged += () => { if (_state.StillShown) ScheduleHall(false); };
        // Кадр плеєра — шаром поверх слайда в залі, «живому екрані» й передпоказі.
        state.MediaScreenChanged += ApplyVideo;
        state.Media.Changed += ApplyVideo;
        Signals.Shared.Subscribe(Signals.Kind.Live, ApplyVideo);
        // Інша вкладка — інший передпоказ («Медіа», «Екран» без кадру — порожньо, як на Mac).
        Signals.Shared.Subscribe(Signals.Kind.Mode, () => SchedulePreview());
        ApplyVideo();
    }

    /// Хто показує кадр плеєра: зал — коли він на екрані, «живий екран» — так само
    /// (і лише при показі), передпоказ — за галочкою «Відео у передпоказ».
    public void ApplyVideo()
    {
        var media = _state.Media;
        var fade = AppState.MediaFadeSeconds;
        ProjectionController.Shared.Surface?.SetVideo(media.Frames, media.IsVideoOnScreen, fade);
        _bottom.Mirror.Surface.SetVideo(media.Frames, _state.IsLive && media.IsVideoOnScreen, fade);
        _bottom.Preview.Surface.SetVideo(media.Frames, media.ShowsVideoInPreview, 0);
    }

    /// Перемальовування — на наступному проході циклу, склеєне: кілька приводів дають один кадр.
    void SchedulePreview()
    {
        _bottom.Preview.IsLive = _state.IsLive && _state.LiveSlide.Equals(_state.Slide);
        if (_previewScheduled) return;
        _previewScheduled = true;
        Dispatcher.UIThread.Post(() => { _previewScheduled = false; RenderPreview(); }, DispatcherPriority.Background);
    }

    void ScheduleHall(bool animated)
    {
        _hallAnimated |= animated;
        if (_hallScheduled) return;
        _hallScheduled = true;
        Dispatcher.UIThread.Post(() => { _hallScheduled = false; var a = _hallAnimated; _hallAnimated = false; RenderHall(a); }, DispatcherPriority.Background);
    }

    /// Картинка вписана в кадр на чорному (як кадр показу на Mac); `focus` —
    /// показаний шматок за наближення (частки), null — уся.
    static void DrawStill(SkiaSharp.SKCanvas c, int width, int height, SkiaSharp.SKImage picture, Avalonia.Rect? focus = null)
    {
        c.Clear(SkiaSharp.SKColors.Black);
        var source = focus is { } part ? SlideFocus.Crop(picture, part) : new SkiaSharp.SKRect(0, 0, picture.Width, picture.Height);
        var s = Math.Min(width / source.Width, height / source.Height);
        var w = source.Width * s; var h = source.Height * s;
        using var paint = new SkiaSharp.SKPaint { FilterQuality = SkiaSharp.SKFilterQuality.High };
        c.DrawImage(picture, source, SkiaSharp.SKRect.Create((width - w) / 2, (height - h) / 2, w, h), paint);
    }

    /// Замовлення кадру: усе зібране в головному потоці, малюється у фоні.
    SlideDrawing.Order Order(Slide slide, SlideStyle style, SlidePreset? preset, ConstructorSample texts, string? background)
    {
        var order = new SlideDrawing.Order
        {
            Slide = slide, Style = style, Preset = preset, Texts = texts, BackgroundOverride = background,
            WithSecondTranslation = slide.SecondaryTexts.Count > 0, ImagePath = _state.PresetImagePath,
        };
        order.ResolveImages();
        return order;
    }

    void RenderPreview()
    {
        var (w, h) = _bottom.Preview.PixelSize();
        var slide = _state.Slide;
        var showMode = _state.Mode is WorkMode.Pictures or WorkMode.Presentation;
        var previewStill = showMode ? _state.PreviewStill : null;
        // Вкладки показу готують картинку: нічого не вибрано — порожньо, а не вірш з іншої
        // вкладки (він звідси в зал не піде). «Екран» і «Медіа» без кадру — теж порожньо.
        if ((showMode && previewStill == null) || _state.Mode is WorkMode.Screen or WorkMode.Media)
        {
            ++_previewGeneration;
            _bottom.Preview.Surface.Show(null, false, "none", 0, "linear");
            return;
        }
        // Передпоказ відповідає на питання «що піде в зал»: шаблон відкритої
        // вкладки, тексти підготовленого слайда, фон, що ляже під текст.
        var order = Order(slide, _state.Style, _state.Preset(OutputKind.Preview), _state.Texts(slide), _state.PreviewBackgroundOverride);
        if (Program.Snapshotting) Console.WriteLine($"  [перегляд] шаблон={order.Preset?.Name ?? "—"} фон={order.BackgroundOverride ?? "—"} → {order.ImagePath(order.BackgroundOverride) ?? "не знайдено"}");
        var generation = ++_previewGeneration;
        SlideRenderQueue.Shared.Render("перегляд", generation, w, h, true,
            (c, width, height) =>
            {
                if (previewStill != null && SlideImageStore.Shared.Image(previewStill) is { } picture) DrawStill(c, width, height, picture);
                else SlideDrawing.Draw(order, c, width, height);
            },
            (image, done) => { if (done == _previewGeneration) _bottom.Preview.Surface.Show(image, false, "none", 0, "linear"); else image?.Dispose(); });
    }

    /// Кадр для NDI: той самий зал, але за правилами виводу NDI (свій шаблон, «прозорий фон» —
    /// текст без фону для титрів поверх картинки трансляції). Головний потік.
    public SkiaSharp.SKImage? NdiFrame(int width, int height, bool transparent)
    {
        var slide = _state.HallSlide;
        var still = _state.IsLive && !_state.IsBlackout ? _state.LiveStill : null;
        var style = _state.Style;
        var preset = _state.Preset(OutputKind.Ndi);
        if (_state.IsBlackout) { style = new SlideStyle { BackgroundColor = SlideStyle.RGBA.Black }; preset = null; }
        var order = Order(slide, style, preset, _state.Texts(_state.LiveSlide, live: true), _state.IsBlackout ? null : _state.BackgroundOverride);
        order.DrawsBackground = _state.IsBlackout || !transparent;
        try
        {
            using var surface = SkiaSharp.SKSurface.Create(new SkiaSharp.SKImageInfo(Math.Max(2, width), Math.Max(2, height), SkiaSharp.SKColorType.Bgra8888, SkiaSharp.SKAlphaType.Premul));
            var c = surface.Canvas;
            c.Clear(transparent && !_state.IsBlackout ? SkiaSharp.SKColors.Transparent : SkiaSharp.SKColors.Black);
            if (still != null && SlideImageStore.Shared.Image(still) is { } picture) DrawStill(c, width, height, picture, SlideFocus.Shared.ShownRect);
            else if (!slide.IsBlank || !transparent) SlideDrawing.Draw(order, c, width, height);
            return surface.Snapshot();
        }
        catch (Exception error) { Journal.Say($"кадр NDI не намалювався: {error.Message}"); return null; }
    }

    /// Кадр залу заданого розміру — одразу, у головному потоці (пульт, знімок на вимогу).
    public SkiaSharp.SKImage? HallFrame(int width, int height)
    {
        var slide = _state.HallSlide;
        var still = _state.IsLive && !_state.IsBlackout ? _state.LiveStill : null;
        var style = _state.Style;
        var preset = _state.Preset(OutputKind.Screen);
        if (_state.IsBlackout) { style = new SlideStyle { BackgroundColor = SlideStyle.RGBA.Black }; preset = null; }
        var order = Order(slide, style, preset, _state.Texts(_state.LiveSlide, live: true), _state.IsBlackout ? null : _state.BackgroundOverride);
        if (_state.IsBlackout) order.DrawsBackground = true;
        try
        {
            using var surface = SkiaSharp.SKSurface.Create(new SkiaSharp.SKImageInfo(Math.Max(2, width), Math.Max(2, height)));
            var c = surface.Canvas;
            if (still != null && SlideImageStore.Shared.Image(still) is { } picture) DrawStill(c, width, height, picture, SlideFocus.Shared.ShownRect);
            else SlideDrawing.Draw(order, c, width, height);
            return surface.Snapshot();
        }
        catch (Exception error) { Journal.Say($"кадр залу не намалювався: {error.Message}"); return null; }
    }

    void RenderHall(bool animated)
    {
        // Трансляція NDI малює свій кадр із того самого залу.
        NdiOutput.Shared.ContentChanged();
        // Вікно залу могло з'явитися щойно — кадр плеєра й до нього.
        ApplyVideo();
        var slide = _state.HallSlide;
        var still = _state.IsLive && !_state.IsBlackout ? _state.LiveStill : null;
        var style = _state.Style;
        var preset = _state.Preset(OutputKind.Screen);
        // Затемнення — чорний екран без застережень: ні тексту, ні фону, ні свого шаблону.
        if (_state.IsBlackout)
        {
            style = new SlideStyle { BackgroundColor = SlideStyle.RGBA.Black };
            preset = null;
        }
        var order = Order(slide, style, preset, _state.Texts(_state.LiveSlide, live: true), _state.IsBlackout ? null : _state.BackgroundOverride);
        if (_state.IsBlackout) order.DrawsBackground = true;
        var options = SettingsStore.Shared.Settings.Options;
        var live = _state.IsLive && (!slide.IsBlank || still != null);
        if (still != null)
        {
            // Картинка — ефектом «зміни сторінки показу» з «Параметрів».
            options = SettingsStore.Shared.Settings.Options;
        }
        // Зміна слайда — переходом стилю; гасіння — розчиненням за часом із «Параметрів».
        var transition = preset?.Transition ?? style.TransitionKind;
        var duration = preset?.TransitionDuration ?? style.TransitionDuration;
        var curve = preset?.TransitionEasing ?? style.EffectiveEasing;
        var kind = still != null ? (options.ShowTransition ?? "fade") : live ? transition.RawValue() : "fade";
        var seconds = still != null ? (options.ShowTransitionTime ?? 350) / 1000.0 : live ? duration : (options.HideFadeTime ?? 400) / 1000.0;
        var easing = still != null ? (options.ShowTransitionEasing ?? "easeInOut") : live ? curve.RawValue() : (options.HideFadeEasing ?? "easeOut");
        var focus = SlideFocus.Shared.ShownRect;
        void Draw(SkiaSharp.SKCanvas c, int width, int height)
        {
            if (still != null && SlideImageStore.Shared.Image(still) is { } picture) DrawStill(c, width, height, picture, focus);
            else SlideDrawing.Draw(order, c, width, height);
        }
        // Зал.
        if (ProjectionController.Shared.Surface != null)
        {
            var (w, h) = ProjectionController.Shared.FrameSize();
            var generation = ++_hallGeneration;
            SlideRenderQueue.Shared.Render("зал", generation, w, h, true, Draw,
                (image, done) =>
                {
                    if (done != _hallGeneration) { image?.Dispose(); return; }
                    ProjectionController.Shared.Present(image, animated, kind, seconds, easing, slide.IsBlank);
                });
        }
        // Живий екран у нижньому ряду — той самий зал меншим кадром.
        if (_bottom.ShowsMirror)
        {
            // Кадр сторін залу, зменшений до дзеркала: вид впише його з полями.
            var (fw, fh) = ProjectionController.Shared.FrameSize();
            var (vw, vh) = _bottom.Mirror.PixelSize();
            var fit = Math.Min((double)vw / Math.Max(1, fw), (double)vh / Math.Max(1, fh));
            var (mw, mh) = ((int)Math.Max(2, Math.Round(fw * fit)), (int)Math.Max(2, Math.Round(fh * fit)));
            var mg = ++_mirrorGeneration;
            SlideRenderQueue.Shared.Render("дзеркало", mg, mw, mh, true, Draw,
                (image, done) => { if (done == _mirrorGeneration) _bottom.Mirror.Surface.Show(image, animated, kind, seconds, easing); else image?.Dispose(); });
        }
    }
}
