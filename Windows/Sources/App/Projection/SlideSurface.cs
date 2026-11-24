// =============================================================================
//  SlideSurface.cs — показ готового кадру слайда з переходом
// =============================================================================
//  Як SlideCanvasView + SlideTransitionAnimator на Mac: кадр уже намальований
//  чергою у фоні; тут він лише показується. Зміна кадру — одним із двадцяти
//  переходів (розчинення, через чорне, розмиття, зсув/накриття/відкриття в чотири
//  боки, наближення, віддалення, оберт, переворот, підскок) зі своєю кривою
//  часу. Гасіння залу — тим самим розчиненням: старий кадр (текст на фоні)
//  розчиняється в новий (той самий фон без тексту) — на стіні зникає лише текст.
//  Малюється прямо Skia на відеокарті: два кадри на кадр анімації — дешево.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform;
using Avalonia.Rendering.SceneGraph;
using Avalonia.Skia;
using SkiaSharp;

namespace Slovo.App;

public sealed class SlideSurface : Control
{
    SKImage? _current, _previous;
    string _kind = "none", _easing = "easeInOut";
    double _duration;
    long _started;
    bool _animating;
    /// Кадри, які вже не показуються, звільняються не одразу: їх ще може
    /// домальовувати потік відображення.
    readonly Queue<(SKImage Image, long At)> _retired = new();

    public SlideSurface() { ClipToBounds = true; }

    /// Вписувати кадр зі збереженням сторін (по краях — чорне), як дзеркало
    /// проектора на Mac (contentsGravity .resizeAspect). Без цього — на весь вид.
    public bool FitsAspect { get; set; }

    SlidePointer.Mark? _mark;
    SlidePointer.Look _markLook = SlidePointer.Look.Default;
    /// Указка поверх кадру (частки кадру); null — не видно.
    public void ShowPointer(SlidePointer.Mark? mark, SlidePointer.Look look)
    {
        if (mark == _mark && look == _markLook) return;
        _mark = mark; _markLook = look;
        InvalidateVisual();
    }

    /// Де саме лежить кадр у виді (з полями, якщо вписуємо зі сторонами).
    public Rect FrameRect
    {
        get
        {
            var b = new Rect(Bounds.Size);
            if (!FitsAspect || _current is not { Width: > 0, Height: > 0 } image) return b;
            var aspect = (double)image.Width / image.Height;
            var w = b.Width; var h = w / aspect;
            if (h > b.Height) { h = b.Height; w = h * aspect; }
            return new Rect((b.Width - w) / 2, (b.Height - h) / 2, w, h);
        }
    }

    public SKImage? CurrentImage => _current;
    public bool IsAnimating => _animating;

    // --- Кадр плеєра поверх слайда (шар відео на Mac) ---------------------------------

    VideoFrames? _video;
    bool _showsVideo;
    double _alphaFrom, _alphaTo, _alphaSeconds;
    long _alphaStarted;
    bool _fading;

    /// Показувати кадри плеєра поверх слайда; з'являється й гасне за `fadeSeconds`.
    public void SetVideo(VideoFrames? frames, bool show, double fadeSeconds)
    {
        if (!ReferenceEquals(_video, frames))
        {
            if (_video != null) _video.FrameReady -= OnVideoFrame;
            _video = frames;
            if (frames != null) frames.FrameReady += OnVideoFrame;
        }
        if (show == _showsVideo) return;
        _showsVideo = show;
        _alphaFrom = VideoAlpha;
        _alphaTo = show ? 1 : 0;
        _alphaSeconds = fadeSeconds;
        _alphaStarted = System.Diagnostics.Stopwatch.GetTimestamp();
        var top = TopLevel.GetTopLevel(this);
        if (fadeSeconds > 0.01 && top != null && !_fading) { _fading = true; FadeTick(top); }
        InvalidateVisual();
    }

    /// Чи стоїть кадр плеєра поверх слайда (зараз або гасне).
    public bool ShowsVideo => _showsVideo;

    double VideoAlpha
    {
        get
        {
            if (_alphaSeconds <= 0.01) return _alphaTo;
            var t = Math.Min(1, System.Diagnostics.Stopwatch.GetElapsedTime(_alphaStarted).TotalSeconds / _alphaSeconds);
            return _alphaFrom + (_alphaTo - _alphaFrom) * t;
        }
    }

    void FadeTick(TopLevel top)
    {
        top.RequestAnimationFrame(_ =>
        {
            InvalidateVisual();
            if (System.Diagnostics.Stopwatch.GetElapsedTime(_alphaStarted).TotalSeconds >= _alphaSeconds) { _fading = false; return; }
            FadeTick(top);
        });
    }

    void OnVideoFrame()
    {
        if (_showsVideo || VideoAlpha > 0) InvalidateVisual();
    }

    /// Показати новий кадр: з переходом `kind` за `seconds` секунд (або одразу).
    public void Show(SKImage? image, bool animated, string kind, double seconds, string easing)
    {
        var previous = _current;
        _current = image;
        if (animated && kind != "none" && previous != null && image != null && seconds > 0.01)
        {
            if (_previous != null && !ReferenceEquals(_previous, previous)) Retire(_previous);
            _previous = previous;
            _kind = kind; _easing = easing; _duration = seconds;
            _started = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!_animating) { _animating = true; Tick(); }
        }
        else
        {
            if (previous != null) Retire(previous);
            if (_previous != null) { Retire(_previous); _previous = null; }
            _animating = false;
        }
        InvalidateVisual();
    }

    void Retire(SKImage image)
    {
        if (ReferenceEquals(image, _current)) return;
        _retired.Enqueue((image, System.Diagnostics.Stopwatch.GetTimestamp()));
        // Звільняємо те, що пішло з екрана понад дві секунди тому.
        while (_retired.Count > 0 && System.Diagnostics.Stopwatch.GetElapsedTime(_retired.Peek().At).TotalSeconds > 2)
        {
            var old = _retired.Dequeue().Image;
            if (!ReferenceEquals(old, _current) && !ReferenceEquals(old, _previous)) old.Dispose();
        }
    }

    double Progress => _duration <= 0 ? 1 : Math.Min(1, System.Diagnostics.Stopwatch.GetElapsedTime(_started).TotalSeconds / _duration);

    void Tick()
    {
        var top = TopLevel.GetTopLevel(this);
        if (top == null)
        {
            // Без вікна (знімок, перевірка) — одразу кінцевий кадр.
            Finish();
            return;
        }
        top.RequestAnimationFrame(_ =>
        {
            if (!_animating) return;
            if (Progress >= 1) { Finish(); return; }
            InvalidateVisual();
            Tick();
        });
    }

    void Finish()
    {
        _animating = false;
        if (_previous != null) { Retire(_previous); _previous = null; }
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        var p = _animating ? Progress : 1;
        var alpha = VideoAlpha;
        var video = alpha > 0 ? _video?.Latest : null;
        context.Custom(new Operation(new Rect(Bounds.Size), _current, _animating ? _previous : null, p, _kind, _easing, FitsAspect, _mark, _markLook)
            { Video = video, VideoAlpha = (float)alpha });
    }

    // --- Криві часу -------------------------------------------------------------

    public static double Ease(string easing, double t) => easing switch
    {
        "linear" => t,
        "easeOut" => Bezier(0, 0, 0.58, 1, t),
        "spring" => Bezier(0.34, 1.56, 0.64, 1, t),
        _ => Bezier(0.42, 0, 0.58, 1, t),
    };

    /// Кубічна крива Безьє (x1,y1,x2,y2) як CAMediaTimingFunction: y за x.
    static double Bezier(double x1, double y1, double x2, double y2, double x)
    {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        double t = x;
        for (var i = 0; i < 8; i++)
        {
            var cx = 3 * x1 * t * (1 - t) * (1 - t) + 3 * x2 * t * t * (1 - t) + t * t * t - x;
            var dx = 3 * x1 * (1 - t) * (1 - 3 * t) + 3 * x2 * t * (2 - 3 * t) + 3 * t * t;
            if (Math.Abs(cx) < 1e-6 || Math.Abs(dx) < 1e-6) break;
            t = Math.Clamp(t - cx / dx, 0, 1);
        }
        return 3 * y1 * t * (1 - t) * (1 - t) + 3 * y2 * t * t * (1 - t) + t * t * t;
    }

    static bool FadesOut(string kind) => kind is not ("slideLeft" or "slideRight" or "slideUp" or "slideDown"
        or "coverLeft" or "coverRight" or "coverUp" or "coverDown" or "wipeLeft" or "wipeRight" or "wipeUp" or "wipeDown" or "flip");

    // --- Малювання на відеокарті ----------------------------------------------------

    sealed class Operation : ICustomDrawOperation
    {
        readonly SKImage? _new, _old;
        readonly double _t;
        readonly string _kind, _easing;
        public Rect Bounds { get; }

        public Operation(Rect bounds, SKImage? current, SKImage? previous, double t, string kind, string easing, bool fit = false,
                         SlidePointer.Mark? mark = null, SlidePointer.Look look = default)
        { Bounds = bounds; _new = current; _old = previous; _t = t; _kind = kind; _easing = easing; _fit = fit; _mark = mark; _look = look; }
        readonly bool _fit;
        readonly SlidePointer.Mark? _mark;
        readonly SlidePointer.Look _look;

        /// Кадр плеєра поверх слайда і його прозорість (затухання).
        public SKBitmap? Video { get; init; }
        public float VideoAlpha { get; init; }

        public void Dispose() { }
        public bool HitTest(Point p) => Bounds.Contains(p);

        /// Кадр плеєра: вписаний зі сторонами на чорному, як шар з resizeAspect.
        void DrawVideo(SKCanvas c, SKRect whole)
        {
            if (Video is not { Width: > 0, Height: > 0 } bitmap || VideoAlpha <= 0) return;
            var a = (byte)Math.Round(255 * Math.Clamp(VideoAlpha, 0, 1));
            using (var black = new SKPaint { Color = new SKColor(0, 0, 0, a) }) c.DrawRect(whole, black);
            var scale = Math.Min(whole.Width / bitmap.Width, whole.Height / bitmap.Height);
            var vw = bitmap.Width * scale; var vh = bitmap.Height * scale;
            using var paint = new SKPaint { Color = new SKColor(255, 255, 255, a), FilterQuality = SKFilterQuality.Medium };
            c.DrawBitmap(bitmap, SKRect.Create(whole.Left + (whole.Width - vw) / 2, whole.Top + (whole.Height - vh) / 2, vw, vh), paint);
        }
        public bool Equals(ICustomDrawOperation? other) => false;

        public void Render(ImmediateDrawingContext context)
        {
            var lease = context.TryGetFeature<ISkiaSharpApiLeaseFeature>();
            if (lease == null) return;
            using var api = lease.Lease();
            var c = api.SkCanvas;
            var w = (float)Bounds.Width; var h = (float)Bounds.Height;
            var whole = new SKRect(0, 0, w, h);
            using (var black = new SKPaint { Color = SKColors.Black }) c.DrawRect(whole, black);
            if (_fit && (_new ?? _old) is { Width: > 0, Height: > 0 } frame)
            {
                // Сторони кадру залу; поля по краях лишаються чорними.
                var aspect = (float)frame.Width / frame.Height;
                var fw = w; var fh = w / aspect;
                if (fh > h) { fh = h; fw = h * aspect; }
                whole = SKRect.Create((w - fw) / 2, (h - fh) / 2, fw, fh);
                c.Save();
                c.ClipRect(whole);
                c.Translate(whole.Left, whole.Top);
                w = fw; h = fh;
                whole = new SKRect(0, 0, w, h);
                try { Paint(c, w, h, whole); DrawVideo(c, whole); Spot(c, w, h); }
                finally { c.Restore(); }
                return;
            }
            Paint(c, w, h, whole);
            DrawVideo(c, whole);
            Spot(c, w, h);
        }

        void Spot(SKCanvas c, float w, float h)
        {
            if (_mark is { } mark) SlidePointer.Draw(c, mark, _look, w, h);
        }

        void Paint(SKCanvas c, float w, float h, SKRect whole)
        {
            if (_old == null) { Draw(c, _new, whole, 1, SKMatrix.Identity); return; }

            var e = Ease(_easing, _t);
            var p = (float)e;
            var lin = (float)_t;
            var fadeOut = FadesOut(_kind);
            var cx = w / 2; var cy = h / 2;
            switch (_kind)
            {
                case "fadeBlack":
                    if (lin < 0.5f) Draw(c, _old, whole, 1 - lin * 2, SKMatrix.Identity);
                    else Draw(c, _new, whole, lin * 2 - 1, SKMatrix.Identity);
                    return;
                case "slideLeft":
                    Draw(c, _old, whole, 1, SKMatrix.CreateTranslation(-w * p, 0));
                    Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(w * (1 - p), 0));
                    return;
                case "slideRight":
                    Draw(c, _old, whole, 1, SKMatrix.CreateTranslation(w * p, 0));
                    Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(-w * (1 - p), 0));
                    return;
                case "slideUp":
                    Draw(c, _old, whole, 1, SKMatrix.CreateTranslation(0, -h * p));
                    Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(0, h * (1 - p)));
                    return;
                case "slideDown":
                    Draw(c, _old, whole, 1, SKMatrix.CreateTranslation(0, h * p));
                    Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(0, -h * (1 - p)));
                    return;
                case "coverLeft": Draw(c, _old, whole, 1, SKMatrix.Identity); Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(w * (1 - p), 0)); return;
                case "coverRight": Draw(c, _old, whole, 1, SKMatrix.Identity); Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(-w * (1 - p), 0)); return;
                case "coverUp": Draw(c, _old, whole, 1, SKMatrix.Identity); Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(0, h * (1 - p))); return;
                case "coverDown": Draw(c, _old, whole, 1, SKMatrix.Identity); Draw(c, _new, whole, 1, SKMatrix.CreateTranslation(0, -h * (1 - p))); return;
                case "wipeLeft": case "wipeRight": case "wipeUp": case "wipeDown":
                {
                    Draw(c, _old, whole, 1, SKMatrix.Identity);
                    var clip = _kind switch
                    {
                        "wipeLeft" => new SKRect(w * (1 - p), 0, w, h),
                        "wipeRight" => new SKRect(0, 0, w * p, h),
                        "wipeUp" => new SKRect(0, h * (1 - p), w, h),
                        _ => new SKRect(0, 0, w, h * p),
                    };
                    c.Save(); c.ClipRect(clip); Draw(c, _new, whole, 1, SKMatrix.Identity); c.Restore();
                    return;
                }
                case "flip":
                {
                    var angle = p * Math.PI / 2;
                    Draw(c, _old, whole, 1, SKMatrix.CreateScale((float)Math.Max(0.001, Math.Cos(angle)), 1, cx, cy));
                    Draw(c, _new, whole, 1, SKMatrix.CreateScale((float)Math.Max(0.001, Math.Sin(angle)), 1, cx, cy));
                    return;
                }
            }
            // Решта — з розчиненням: старий тане, новий проступає, кожен зі своїм рухом.
            SKMatrix enter = SKMatrix.Identity, leave = SKMatrix.Identity;
            switch (_kind)
            {
                case "zoom":
                    enter = SKMatrix.CreateScale(1.08f - 0.08f * p, 1.08f - 0.08f * p, cx, cy);
                    leave = SKMatrix.CreateScale(1 - 0.06f * p, 1 - 0.06f * p, cx, cy);
                    break;
                case "zoomOut":
                    enter = SKMatrix.CreateScale(0.9f + 0.1f * p, 0.9f + 0.1f * p, cx, cy);
                    leave = SKMatrix.CreateScale(1 + 0.1f * p, 1 + 0.1f * p, cx, cy);
                    break;
                case "spin":
                    enter = SKMatrix.Concat(SKMatrix.CreateRotationDegrees(-30 * (1 - p), cx, cy),
                                            SKMatrix.CreateScale(0.85f + 0.15f * p, 0.85f + 0.15f * p, cx, cy));
                    leave = SKMatrix.Concat(SKMatrix.CreateRotationDegrees(30 * p, cx, cy),
                                            SKMatrix.CreateScale(1 - 0.15f * p, 1 - 0.15f * p, cx, cy));
                    break;
                case "bounce":
                    enter = SKMatrix.CreateTranslation(0, h * 0.35f * (1 - p));
                    break;
            }
            var blur = _kind == "blur";
            Draw(c, _old, whole, fadeOut ? 1 - Math.Clamp(p, 0, 1) : 1, leave, blur ? 18 * lin : 0);
            Draw(c, _new, whole, Math.Clamp(p, 0, 1), enter, blur ? 18 * (1 - lin) : 0);
        }

        static void Draw(SKCanvas c, SKImage? image, SKRect whole, float alpha, SKMatrix transform, float blur = 0)
        {
            if (image == null || alpha <= 0.001f) return;
            c.Save();
            c.Concat(ref transform);
            using var paint = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255)), FilterQuality = SKFilterQuality.Medium };
            if (blur > 0.5f) paint.ImageFilter = SKImageFilter.CreateBlur(blur, blur);
            c.DrawImage(image, new SKRect(0, 0, image.Width, image.Height), whole, paint);
            c.Restore();
        }
    }
}
