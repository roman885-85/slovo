// =============================================================================
//  Bench.cs — заміри відгуку вікна (NativeBench і родина на Mac)
// =============================================================================
//  Вимога власника №4 (23.11): «в текущей версии под виндовс все тормозит при
//  переключении куплетов, песен, стихов». На Mac те саме колись лікували іншим
//  методом показу — і міряли його замірами `--appkit-*-bench`. Тут ті самі
//  дії й той самий вигляд звіту, щоб числа Mac і Windows лягли поруч.
//
//  Міряється не виклик моделі, а весь шлях до пікселів, по чотири величини на
//  дію: «робота» (сама дія і відповідь стану й списків), «розкладка» (прохід
//  розкладки вікна), «малювання» (запис кадру й растеризація Skia — два такти
//  рендера), «разом». П'ятий стовпчик — коли дія міняє слайд: скільки минуло
//  від дії до готового кадру слайда (він малюється у фоні чергою).
//
//  Запуск — у режимі знімків, на тестових даних:
//    Slovo.exe --snapshot <тека> --data <тестова тека> --bench bible|songs|bottom|top|base|all
//  Звіт — `<тека>/bench-<розділ>.txt` і в стандартний вивід.
//  Перші три проходи кожної дії — прогрів (шрифти, кеші), у медіану не йдуть.
// =============================================================================

using System.Diagnostics;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;

namespace Slovo.App;

public static partial class Bench
{
    readonly record struct Sample(double Work, double Layout, double Draw, double Total, double Slide);

    static readonly List<string> Lines = new();
    static Window _window = null!;

    public static readonly string[] Sections = { "base", "bible", "songs", "bottom", "top" };

    /// Прогнати розділ (або всі) і записати звіти. Повертає кількість звітів.
    public static int Run(string which, string folder)
    {
        var done = 0;
        foreach (var section in which == "all" ? Sections : new[] { which })
        {
            Lines.Clear();
            var before = Remember();
            var ok = section switch
            {
                "base" => RunBase(),
                "bible" => RunBible(),
                "songs" => RunSongs(),
                "bottom" => RunBottom(),
                "top" => RunTop(),
                _ => false,
            };
            if (!ok) { Console.WriteLine($"  замір «{section}»: немає такого розділу або даних для нього"); continue; }
            Lines.Add("");
            Lines.Add("Медіани в мілісекундах. «Робота» — дія й відповідь стану та списків; «розкладка» — прохід");
            Lines.Add("розкладки вікна; «малювання» — запис кадру й растеризація Skia (два такти); «разом» — сума;");
            Lines.Add("«кадр слайда» — від дії до готового кадру в передпоказі (малюється у фоні). Ціль — до 16 мс на дію.");
            Lines.Add($"Машина: {Environment.OSVersion.VersionString}, процесорів {Environment.ProcessorCount}, .NET {Environment.Version}.");
            var text = string.Join("\n", Lines) + "\n";
            File.WriteAllText(Path.Combine(folder, $"bench-{section}.txt"), text);
            Console.Write(text);
            done++;
            Restore(before);
            Snapshot.Pump(4);
        }
        // Вікно одне на всі розділи: закрите вікно Avalonia вдруге не показує.
        try { _window?.Close(); } catch { }
        return done;
    }

    // ── Стан до заміру ──────────────────────────────────────────────────────
    //  Заміри перемикають переклад, книгу, режим, пісенник — і стан запам'ятовується в теці
    //  даних. Як на Mac (restore у NativeBibleBench), після розділу все повертається: інакше
    //  наступний запуск на тій самій тестовій теці відкривався б з іншим перекладом.

    readonly record struct Remembered(string Primary, int Book, int Chapter, int[] Verses, WorkMode Mode, BookClass Class, string SongBook, double Font);

    static Remembered Remember()
    {
        var s = AppState.Shared;
        return new(s.PrimaryModuleID, s.SelectedBookIndex, s.SelectedChapterNumber, s.SelectedVerseNumbers.ToArray(), s.Mode, s.BookClass, s.SongBookID, s.ListFontSize);
    }

    static void Restore(Remembered r)
    {
        var s = AppState.Shared;
        if (_window is MainWindow main && main.Songs is { } songs && r.SongBook.Length > 0 && s.SongBookID != r.SongBook) songs.SelectBook(r.SongBook);
        if (s.BookClass != r.Class) { s.BookClass = r.Class; Signals.Shared.Send(Signals.Kind.BookClass); Signals.Shared.Send(Signals.Kind.Books); }
        if (r.Primary.Length > 0 && s.PrimaryModuleID != r.Primary) { s.PrimaryModuleID = r.Primary; WaitChapters(s); }
        if (s.SelectedBookIndex != r.Book) { s.SelectedBookIndex = r.Book; WaitChapters(s); }
        if (s.SelectedChapterNumber != r.Chapter) s.SelectedChapterNumber = r.Chapter;
        if (r.Verses.Length > 0) s.SelectedVerseNumbers = r.Verses;
        if (Math.Abs(s.ListFontSize - r.Font) > 0.01) s.ZoomLists(r.Font - s.ListFontSize);
        SetMode(r.Mode);
    }

    // ── Вікно ───────────────────────────────────────────────────────────────

    static MainWindow OpenMain()
    {
        var window = MainWindow.Shared ?? new MainWindow(AppState.Shared);
        window.Width = 1600;
        window.Height = 1000;
        window.Show();
        _window = window;
        Snapshot.WaitForLibrary();
        Settle();
        return window;
    }

    /// Перемкнути режим, як вкладка вгорі: стан + привід «режим» (вікно ставить свою робочу область).
    static void SetMode(WorkMode mode)
    {
        if (AppState.Shared.Mode != mode)
        {
            AppState.Shared.Mode = mode;
            Signals.Shared.Send(Signals.Kind.Mode);
        }
        Settle();
    }

    static void Header(string title, params string[] about)
    {
        Lines.Add($"# {title}");
        Lines.Add("");
        Lines.AddRange(about);
        Lines.Add("");
        Lines.Add("| дія | робота | розкладка | малювання | разом | кадр слайда |");
        Lines.Add("|---|---|---|---|---|---|");
    }

    static void Note(string text) => Lines.Add($"| _{text}_ | | | | | |");

    /// Дати вікну й черзі слайдів доробити все відкладене.
    static void Settle()
    {
        Snapshot.Pump(4);
        var until = DateTime.Now.AddSeconds(5);
        while (DateTime.Now < until && !SlideRenderQueue.Shared.IsIdle) { Snapshot.Pump(1); Thread.Sleep(2); }
        Snapshot.Pump(2);
    }

    // ── Замір ───────────────────────────────────────────────────────────────

    static void Report(string name, int repeats, Action body, bool slide = false)
    {
        var samples = new List<Sample>(repeats);
        for (var pass = 0; pass < repeats; pass++)
        {
            var sample = Measure(body, slide);
            if (pass >= 3) samples.Add(sample);
        }
        if (samples.Count == 0) return;
        string Median(Func<Sample, double> pick)
        {
            var sorted = samples.Select(pick).OrderBy(v => v).ToList();
            var value = sorted[sorted.Count / 2];
            return double.IsNaN(value) ? "—" : value.ToString("0.000", CultureInfo.InvariantCulture);
        }
        Lines.Add($"| {name} | {Median(s => s.Work)} | {Median(s => s.Layout)} | {Median(s => s.Draw)} | {Median(s => s.Total)} | {(slide ? Median(s => s.Slide) : "—")} |");
    }

    static double Ms(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;

    static Sample Measure(Action body, bool slide)
    {
        var t0 = Stopwatch.GetTimestamp();
        body();
        // Відповідь стану: те, що поставлено в чергу звичайним пріоритетом (не рендер і не фон).
        Dispatcher.UIThread.RunJobs(DispatcherPriority.Normal);
        var t1 = Stopwatch.GetTimestamp();
        _window.UpdateLayout();
        var t2 = Stopwatch.GetTimestamp();
        // Запис кадру (UI) і растеризація (сервер композиції): два такти рендера.
        AvaloniaHeadlessPlatform.ForceRenderTimerTick();
        Dispatcher.UIThread.RunJobs();
        AvaloniaHeadlessPlatform.ForceRenderTimerTick();
        Dispatcher.UIThread.RunJobs();
        var t3 = Stopwatch.GetTimestamp();
        var slideMs = double.NaN;
        if (slide)
        {
            var until = DateTime.Now.AddSeconds(3);
            while ((AppState.Shared.IsLoadingChapters || !SlideRenderQueue.Shared.IsIdle) && DateTime.Now < until) { Snapshot.Pump(1); Thread.Yield(); }
            Snapshot.Pump(1);
            slideMs = Ms(t0, Stopwatch.GetTimestamp());
        }
        return new Sample(Ms(t0, t1), Ms(t1, t2), Ms(t2, t3), Ms(t0, t3), slideMs);
    }
}
