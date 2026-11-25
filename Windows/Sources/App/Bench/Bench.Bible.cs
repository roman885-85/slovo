// =============================================================================
//  Bench.Bible.cs — замір робочої області «Біблія» (NativeBibleBench Mac)
// =============================================================================
//  Ті самі дії, що на Mac: вірш, відрізок, уся глава, розділ, перечитування
//  списку, текст в одну лінію, книга, прокрутка Псалма 118 (119), клас книг,
//  переклад. Дії — як від людини: клацання по рядку списку (RowList.Click),
//  а не правка стану в обхід вікна.
// =============================================================================

namespace Slovo.App;

public static partial class Bench
{
    static bool RunBible()
    {
        var state = AppState.Shared;
        var window = OpenMain();
        if (state.AllModules.Count == 0) return false;
        SetMode(WorkMode.Bible);
        var bible = window.Bible!;
        OpenPsalms(state);
        var verses = state.CurrentChapter?.Verses.Select(v => v.Number).ToList() ?? new();
        Header("Замір робочої області «Біблія»",
            "Вікно 1600×1000, чотири колонки на місці, смуга перекладів на місці.",
            $"Переклад: {state.PrimaryModuleID}, книг {state.Books.Count}, перекладів на смузі {state.OrderedModules.Count}.",
            $"Відкрито: {state.CurrentBook?.FullName ?? "—"} {state.SelectedChapterNumber}, віршів у розділі {verses.Count}.");

        if (verses.Count > 3)
        {
            var step = 0;
            Report($"перемикання вірша (розділ із {verses.Count} віршів)", 61, () =>
            {
                step = (step + 1) % verses.Count;
                bible.VerseList.Click(step);
            }, slide: true);
            var pair = 0;
            Report("відрізок із десяти віршів (Shift)", 41, () =>
            {
                pair = (pair + 1) % Math.Max(1, verses.Count - 10);
                state.SelectedVerseNumbers = verses.GetRange(pair, 10);
            }, slide: true);
            Report("вся глава разом (Ctrl+A)", 21, () =>
            {
                state.SelectAllVerses();
                state.SelectedVerseNumbers = new[] { verses[0] };
            }, slide: true);
        }

        var chapters = state.Chapters.Count;
        if (chapters > 2)
        {
            var step = 0;
            Report("перемикання розділу (клацання)", 41, () =>
            {
                step = (step + 1) % chapters;
                bible.ChapterList.Click(step);
            }, slide: true);
            Report("перечитати список віршів", 41, () => bible.VerseList.Reload());
            var line = Math.Ceiling(UiFont.LineHeight(Math.Max(7, state.ListFontSize + 1)));
            bible.VerseList.SetUniformHeight(70);
            Settle();
            Report("перечитати список: висоти однакові", 41, () => bible.VerseList.Reload());
            bible.VerseList.SetMeasuredHeights(line + 10);
            bible.VerseList.Reload();
            Settle();

            var was = InterfaceSettings.Shared.VerseView(state.ListScope);
            InterfaceSettings.Shared.SetVerseView(InterfaceSettings.VerseViewMode.SingleLine, state.ListScope);
            Settle();
            Report("перемикання розділу: текст в одну лінію", 41, () =>
            {
                step = (step + 1) % chapters;
                bible.ChapterList.Click(step);
            }, slide: true);
            InterfaceSettings.Shared.SetVerseView(was, state.ListScope);
            Settle();
        }

        var books = bible.BookList.ItemCount;
        if (books > 2)
        {
            var step = 0;
            Report("перемикання книги (клацання)", 41, () =>
            {
                step = (step + 1) % books;
                bible.BookList.Click(step);
            }, slide: true);
        }

        OpenPsalms(state);
        var rows = bible.VerseList.ItemCount;
        if (rows > 30)
        {
            var wheel = 0;
            Report($"прокрутка Псалма {state.SelectedChapterNumber} на три рядки", 61, () =>
            {
                wheel = (wheel + 3) % rows;
                bible.VerseList.ScrollTo(wheel, ScrollPlace.Top);
            });
            var page = 0;
            Report($"прокрутка Псалма {state.SelectedChapterNumber} на сторінку", 41, () =>
            {
                page = (page + 20) % rows;
                bible.VerseList.ScrollTo(page, ScrollPlace.Top);
            });
        }

        Report("зміна класу книг (Усі ↔ Новий Заповіт)", 21, () =>
            bible.ClassList.Click(state.BookClass == BookClass.All ? (int)BookClass.New : (int)BookClass.All), slide: true);
        if (state.BookClass != BookClass.All) { bible.ClassList.Click((int)BookClass.All); Settle(); }

        var ids = state.OrderedModules.Select(m => m.Identifier).ToList();
        if (ids.Count > 1)
        {
            var k = Math.Max(0, ids.IndexOf(state.PrimaryModuleID));
            Report("зміна перекладу (смуга вкладок)", 21, () =>
            {
                k = (k + 1) % ids.Count;
                state.PrimaryModuleID = ids[k];
            }, slide: true);
        }
        return true;
    }

    /// Найдовший розділ Псалтиря (118 у синодальній нумерації, 119 — у єврейській): 176 віршів.
    static void OpenPsalms(AppState state)
    {
        if (state.Books.Count < 60 && state.OrderedModules.FirstOrDefault(m => m.Books.Count >= 66) is { } full)
        {
            state.PrimaryModuleID = full.Identifier;
            WaitChapters(state);
        }
        var psalms = state.Books.FindIndex(b => b.CanonicalNumber == 230);
        if (psalms < 0) return;
        state.SelectedBookIndex = psalms;
        WaitChapters(state);
        var longest = state.Chapters.OrderByDescending(c => c.Verses.Count).FirstOrDefault();
        if (longest != null) state.SelectedChapterNumber = longest.Number;
        Settle();
    }

    static void WaitChapters(AppState state)
    {
        var until = DateTime.Now.AddSeconds(10);
        do { Snapshot.Pump(2); Thread.Sleep(10); } while (state.IsLoadingChapters && DateTime.Now < until);
        Settle();
    }
}
