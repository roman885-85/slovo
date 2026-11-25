// =============================================================================
//  LiveBench.cs — заміри в справжньому вікні (до кадру, який справді намальовано)
// =============================================================================
//  Заміри знімків (Bench.cs) малюють усе вікно процесором — це верхня межа. Тут
//  програма запускається по-справжньому (вікно Win32, малює відеокарта), і на
//  кожну дію чекаємо, поки кадр зі зміною ПОКАЗАНО: дія → прохід розкладки й
//  запису кадру (завдання нижчого пріоритету за рендер) → партія композитора
//  відрендерена (Compositor.RequestCompositionBatchCommitAsync().Rendered).
//  Окремо — до готового кадру слайда в передпоказі (фонова черга).
//
//    Slovo.exe --data <тестова тека> --quiet-start --live-bench <файл звіту>
//  Після звіту програма закривається сама.
// =============================================================================

using System.Diagnostics;
using System.Globalization;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Rendering.Composition;
using Avalonia.Threading;

namespace Slovo.App;

public static class LiveBench
{
    static readonly List<string> Lines = new();
    static MainWindow _window = null!;

    public static void Start(string report)
    {
        // Бібліотека читається у фоні — міряти, коли все на місці.
        DispatcherTimer.RunOnce(() => _ = Run(report), TimeSpan.FromSeconds(4));
    }

    static async Task Run(string report)
    {
        try
        {
            _window = MainWindow.Shared!;
            var state = AppState.Shared;
            var until = DateTime.Now.AddSeconds(20);
            while ((state.IsLoadingLibrary || state.IsLoadingChapters) && DateTime.Now < until) await Task.Delay(100);
            Lines.Add("# Заміри в справжньому вікні (до показаного кадру)");
            Lines.Add("");
            Lines.Add($"Вікно {(int)_window.Bounds.Width}×{(int)_window.Bounds.Height}, рушій малювання: {RenderInfo()}.");
            Lines.Add("");
            Lines.Add("| дія | сама дія | до показаного кадру | до кадру слайда |");
            Lines.Add("|---|---|---|---|");
            await SetMode(WorkMode.Bible);
            var bible = _window.Bible!;
            var verses = state.CurrentChapter?.Verses.Count ?? 0;
            if (verses > 3)
            {
                var step = 0;
                await Report($"перемикання вірша (розділ із {verses} віршів)", 41, () => { step = (step + 1) % verses; bible.VerseList.Click(step); }, true);
            }
            var chapters = state.Chapters.Count;
            if (chapters > 2) { var step = 0; await Report("перемикання розділу", 31, () => { step = (step + 1) % chapters; bible.ChapterList.Click(step); }, true); }
            var books = bible.BookList.ItemCount;
            if (books > 2) { var step = 0; await Report("перемикання книги", 31, () => { step = (step + 1) % books; bible.BookList.Click(step); }, true); }
            var ids = state.OrderedModules.Select(m => m.Identifier).ToList();
            if (ids.Count > 1) { var k = Math.Max(0, ids.IndexOf(state.PrimaryModuleID)); await Report("зміна перекладу", 21, () => { k = (k + 1) % ids.Count; state.PrimaryModuleID = ids[k]; }, true); }

            await SetMode(WorkMode.Songs);
            var songs = _window.Songs!;
            if (songs.SongRows.RowCount > 40)
            {
                var letters = new[] { "с", "сл", "сла", "слав", "б", "бл", "бла", "благ" };
                var l = 0;
                await Report("літера в полі швидкого вибору пісні", 41, () => songs.TypeSongQuery(letters[l++ % letters.Length]), false);
                songs.TypeSongQuery("");
                var parts = 0;
                for (var row = 0; row < songs.SongRows.RowCount && parts < 3; row++) { songs.SongList.Click(row); await Settle(); parts = songs.Model.Song?.Parts.Count ?? 0; }
                if (parts >= 2)
                {
                    var p = 0;
                    await Report("куплет у передпоказ", 41, () => { p = (p + 1) % parts; songs.PartList.Click(p); }, true);
                    var q = 0;
                    await Report("куплет у зал (подвійне клацання)", 31, () => { q = (q + 1) % parts; songs.PartList.Click(q, clickCount: 2); }, true);
                    state.HideSlide();
                }
            }
            var modes = new[] { WorkMode.Bible, WorkMode.Text, WorkMode.Songs };
            var m = 0;
            await Report("перемкнути режим (Біблія → Текст → Пісні)", 31, () => { m = (m + 1) % modes.Length; _window.Tabs.Select(modes[m]); }, false);
            await SetMode(WorkMode.Bible);
            Lines.Add("");
            Lines.Add("Медіани в мілісекундах: «сама дія» — виклик у головному потоці; далі — до кадру, який композитор відрендерив;");
            Lines.Add("«до кадру слайда» — поки фонова черга домалює слайд і його покажуть. Ціль — до 16 мс (один кадр).");
            Lines.Add($"Машина: {Environment.OSVersion.VersionString}, процесорів {Environment.ProcessorCount}.");
        }
        catch (Exception error) { Lines.Add("ЗБІЙ: " + error.Message); }
        File.WriteAllText(report, string.Join("\n", Lines) + "\n");
        (Avalonia.Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

    static string RenderInfo()
    {
        try { return ElementComposition.GetElementVisual(_window)?.Compositor is { } c ? c.GetType().Name + (OperatingSystem.IsWindows() ? " (Win32)" : "") : "—"; }
        catch { return "—"; }
    }

    static async Task SetMode(WorkMode mode)
    {
        _window.Tabs.Select(mode);
        await Settle();
    }

    static async Task Settle()
    {
        for (var i = 0; i < 5; i++) await Frame();
        var until = DateTime.Now.AddSeconds(3);
        while (!SlideRenderQueue.Shared.IsIdle && DateTime.Now < until) await Task.Delay(5);
        await Frame();
    }

    /// Дочекатися, поки зміни вікна намальовано й показано.
    static async Task Frame()
    {
        // Рендер (розкладка й запис кадру) має вищий пріоритет за Background: коли ця задача
        // виконується, зміни вже записано в композицію.
        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
        if (ElementComposition.GetElementVisual(_window)?.Compositor is { } compositor)
            await compositor.RequestCompositionBatchCommitAsync().Rendered;
    }

    static async Task Report(string name, int repeats, Action body, bool slide)
    {
        var shown = new List<double>();
        var slides = new List<double>();
        var work = new List<double>();
        for (var pass = 0; pass < repeats; pass++)
        {
            var t0 = Stopwatch.GetTimestamp();
            body();
            var tw = Stopwatch.GetTimestamp();
            await Frame();
            var t1 = Stopwatch.GetTimestamp();
            double s = double.NaN;
            if (slide)
            {
                var until = DateTime.Now.AddSeconds(3);
                while ((AppState.Shared.IsLoadingChapters || !SlideRenderQueue.Shared.IsIdle) && DateTime.Now < until) await Task.Delay(1);
                await Frame();
                s = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
            }
            if (pass >= 3) { shown.Add((t1 - t0) * 1000.0 / Stopwatch.Frequency); slides.Add(s); work.Add((tw - t0) * 1000.0 / Stopwatch.Frequency); }
            await Task.Delay(30);
        }
        static string Median(List<double> values)
        {
            var sorted = values.Where(v => !double.IsNaN(v)).OrderBy(v => v).ToList();
            return sorted.Count == 0 ? "—" : sorted[sorted.Count / 2].ToString("0.0", CultureInfo.InvariantCulture);
        }
        Lines.Add($"| {name} | {Median(work)} | {Median(shown)} | {(slide ? Median(slides) : "—")} |");
    }
}
