// =============================================================================
//  SlideRenderQueue.cs — черга малювання слайдів у фоні
// =============================================================================
//  Як на Mac (SlideRenderQueue): слайд у зал малюється розміром із проектор, і
//  текст із тінню на такому полотні — це десятки й сотні мілісекунд. Робити це
//  в обробці натискання — значить морозити вікно. Тут у кожного замовника (зал,
//  перегляд, живий екран, кадр NDI, полотно Конструктора) свій ключ, і на ключ
//  живе не більше одного замовлення в роботі й одного в очікуванні: прийшло
//  нове — попереднє очікуюче викидається. Готовий кадр приходить із поколінням;
//  замовник порівнює його зі своїм останнім і застарілий не показує. Так у залі
//  ніколи не з'являється «не те» — кадр, замовлений раніше за останній.
// =============================================================================

using Avalonia.Threading;
using SkiaSharp;

namespace Slovo.App;

public sealed class SlideRenderQueue
{
    public static readonly SlideRenderQueue Shared = new();

    sealed record Job(Action<SKCanvas, int, int> Draw, int Width, int Height, bool Opaque, int Generation,
                      Action<SKImage?, int> Completion);

    readonly object _lock = new();
    readonly HashSet<string> _busy = new();
    readonly Dictionary<string, Job> _pending = new();

    /// Скільки кадрів намальовано і скільки замовлень викинуто (для самоперевірки склеювання).
    public int RenderedCount { get; private set; }
    public int DroppedCount { get; private set; }

    /// Замовити кадр. `draw` малює на полотні заданого розміру й мусить бути готовим
    /// до роботи не в головному потоці (усі картинки розв'язані заздалегідь).
    public void Render(string key, int generation, int width, int height, bool opaque,
                       Action<SKCanvas, int, int> draw, Action<SKImage?, int> completion)
    {
        var job = new Job(draw, Math.Max(1, width), Math.Max(1, height), opaque, generation, completion);
        lock (_lock)
        {
            if (_busy.Contains(key))
            {
                if (_pending.ContainsKey(key)) DroppedCount++;
                _pending[key] = job;
                return;
            }
            _busy.Add(key);
        }
        Run(key, job);
    }

    void Run(string key, Job job)
    {
        Task.Run(() =>
        {
            SKImage? image = null;
            try
            {
                var info = new SKImageInfo(job.Width, job.Height, SKColorType.Bgra8888,
                                           job.Opaque ? SKAlphaType.Opaque : SKAlphaType.Premul);
                using var surface = SKSurface.Create(info);
                if (surface != null)
                {
                    surface.Canvas.Clear(job.Opaque ? SKColors.Black : SKColors.Transparent);
                    job.Draw(surface.Canvas, job.Width, job.Height);
                    image = surface.Snapshot();
                }
            }
            catch (Exception error) { Journal.Say($"кадр не намалювався: {error.Message}"); }
            Dispatcher.UIThread.Post(() => job.Completion(image, job.Generation));
            Job? next;
            lock (_lock)
            {
                RenderedCount++;
                if (_pending.Remove(key, out next)) { }
                else _busy.Remove(key);
            }
            if (next != null) Run(key, next);
        });
    }

    /// Черга нічим не зайнята — самоперевірці, щоб дочекатися кадру.
    public bool IsIdle { get { lock (_lock) return _busy.Count == 0 && _pending.Count == 0; } }
}

/// Картинки з диска для малювальника слайда — з будь-якого потоку, розкодовані
/// наперед (як SlideImageStore на Mac): фонів у ході два-три, кожен — мегабайти.
public sealed class SlideImageStore
{
    public static readonly SlideImageStore Shared = new();
    readonly object _lock = new();
    readonly Dictionary<string, SKImage> _images = new();
    const int Limit = 16;

    /// Кадри без файла (сторінки презентації) — під своїм ключем; останні 8 тримаємо.
    readonly List<(string Key, SKImage Image)> _pinned = new();

    public void Pin(string key, SKImage image)
    {
        lock (_lock)
        {
            var at = _pinned.FindIndex(p => p.Key == key);
            if (at >= 0) { if (!ReferenceEquals(_pinned[at].Image, image)) _pinned[at].Image.Dispose(); _pinned.RemoveAt(at); }
            _pinned.Add((key, image));
            while (_pinned.Count > 8) { _pinned[0].Image.Dispose(); _pinned.RemoveAt(0); }
        }
    }

    public SKImage? Image(string path)
    {
        lock (_lock)
        {
            foreach (var (key, pinned) in _pinned) if (key == path) return pinned;
            if (_images.TryGetValue(path, out var ready)) return ready;
        }
        SKImage? image = null;
        try
        {
            using var data = SKData.Create(path);
            if (data != null) image = SKImage.FromEncodedData(data)?.ToRasterImage(true);
        }
        catch { image = null; }
        if (image == null) return null;
        lock (_lock)
        {
            if (_images.Count >= Limit)
            {
                foreach (var old in _images.Values) old.Dispose();
                _images.Clear();
            }
            _images[path] = image;
        }
        return image;
    }

    public void Clear()
    {
        lock (_lock) { foreach (var i in _images.Values) i.Dispose(); _images.Clear(); }
    }
}
