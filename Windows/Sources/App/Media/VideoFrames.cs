// =============================================================================
//  VideoFrames.cs — кадри відео для залу, «живого екрана», передпоказу й плеєра
// =============================================================================
//  Як «раздача кадров» MediaPlayerModel на Mac: один AVPlayerLayer у кількох
//  місцях показати не можна, тому кадри роздаються самі. Тут — три буфери:
//  декодер пише в один, показаний — другий, третій ще може домальовувати потік
//  відображення Avalonia. Без копій і без гонок: буфер, який щойно показали,
//  декодер не займе ще два кадри.
// =============================================================================

using Avalonia.Threading;
using SkiaSharp;

namespace Slovo.App;

public sealed class VideoFrames
{
    public static VideoFrames Shared { get; } = new();

    readonly object _gate = new();
    SKBitmap?[] _pool = new SKBitmap?[3];
    int _writing = -1, _published = -1;
    int _postPending;
    /// Буфери, що пішли з ужитку при зміні розміру, — звільняються не одразу: їх ще
    /// може домальовувати потік відображення.
    readonly Queue<(SKBitmap Bitmap, long At)> _retired = new();

    /// Новий кадр готовий (головний потік, кілька кадрів поспіль склеюються в один виклик).
    public event Action? FrameReady;

    /// Показаний кадр; null — кадру немає.
    public SKBitmap? Latest
    {
        get { lock (_gate) return _published >= 0 ? _pool[_published] : null; }
    }

    public int Width { get; private set; }
    public int Height { get; private set; }
    /// Скільки кадрів прийшло — самоперевірці й знімкам.
    public long Count { get; private set; }

    /// Новий розмір кадру: буфери наново (старі — у відставку).
    public void Configure(int width, int height)
    {
        lock (_gate)
        {
            foreach (var bitmap in _pool) if (bitmap != null) _retired.Enqueue((bitmap, Environment.TickCount64));
            _pool = new SKBitmap?[3];
            for (var i = 0; i < 3; i++) _pool[i] = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque));
            _writing = -1;
            _published = -1;
            Width = width; Height = height;
            ReleaseOld();
        }
    }

    /// Буфер, у який писати наступний кадр (декодер): не показаний і не попередній.
    public IntPtr BeginWrite(out int index, out int pitch)
    {
        lock (_gate)
        {
            index = 0;
            for (var i = 0; i < 3; i++)
            {
                var candidate = (_writing + 1 + i) % 3;
                if (candidate != _published) { index = candidate; break; }
            }
            _writing = index;
            var bitmap = _pool[index];
            pitch = bitmap?.RowBytes ?? 0;
            return bitmap?.GetPixels() ?? IntPtr.Zero;
        }
    }

    /// Кадр у буфері `index` готовий — показати.
    public void Publish(int index)
    {
        lock (_gate)
        {
            if (index < 0 || index >= 3 || _pool[index] == null) return;
            _published = index;
            Count++;
        }
        if (Interlocked.Exchange(ref _postPending, 1) == 1) return;
        Dispatcher.UIThread.Post(() =>
        {
            Interlocked.Exchange(ref _postPending, 0);
            FrameReady?.Invoke();
        }, DispatcherPriority.Render);
    }

    /// Кадру більше немає (файл закрили).
    public void Clear()
    {
        lock (_gate)
        {
            _published = -1;
            Count = 0;
        }
        Dispatcher.UIThread.Post(() => FrameReady?.Invoke(), DispatcherPriority.Render);
    }

    void ReleaseOld()
    {
        while (_retired.Count > 0 && Environment.TickCount64 - _retired.Peek().At > 2000) _retired.Dequeue().Bitmap.Dispose();
    }

    /// Намалювати кадр у прямокутник зі збереженням сторін, по краях — чорне.
    /// Намалювати показаний кадр (вписаним, на чорному) з іншого потоку — під замком, щоб
    /// буфер не пішов у відставку посеред малювання (вивід NDI). false — кадру немає.
    public bool DrawLatest(SKCanvas canvas, SKRect bounds, byte alpha = 255)
    {
        lock (_gate)
        {
            if (_published < 0 || _pool[_published] is not { Width: > 0, Height: > 0 } bitmap) return false;
            using (var black = new SKPaint { Color = new SKColor(0, 0, 0, alpha) }) canvas.DrawRect(bounds, black);
            var scale = Math.Min(bounds.Width / bitmap.Width, bounds.Height / bitmap.Height);
            var w = bitmap.Width * scale; var h = bitmap.Height * scale;
            using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium, Color = new SKColor(255, 255, 255, alpha) };
            canvas.DrawBitmap(bitmap, SKRect.Create(bounds.Left + (bounds.Width - w) / 2, bounds.Top + (bounds.Height - h) / 2, w, h), paint);
            return true;
        }
    }

    public static void DrawFitted(SKCanvas canvas, SKBitmap bitmap, SKRect bounds)
    {
        using (var black = new SKPaint { Color = SKColors.Black }) canvas.DrawRect(bounds, black);
        if (bitmap.Width <= 0 || bitmap.Height <= 0) return;
        var scale = Math.Min(bounds.Width / bitmap.Width, bounds.Height / bitmap.Height);
        var w = bitmap.Width * scale; var h = bitmap.Height * scale;
        using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium };
        canvas.DrawBitmap(bitmap, SKRect.Create(bounds.Left + (bounds.Width - w) / 2, bounds.Top + (bounds.Height - h) / 2, w, h), paint);
    }
}
