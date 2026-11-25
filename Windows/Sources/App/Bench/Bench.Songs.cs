// =============================================================================
//  Bench.Songs.cs — замір модуля «Пісні» (NativeSongsBench Mac)
// =============================================================================
//  Найбільший пісенник; літера в полі швидкого вибору, лише відбір, вибір пісні
//  клацанням (видимий рядок і стрибок через збірник), куплет у передпоказ і
//  в зал, куплет стрілкою, прокрутка, зміна пісенника, перечитування списку.
// =============================================================================

namespace Slovo.App;

public static partial class Bench
{
    static bool RunSongs()
    {
        var state = AppState.Shared;
        var window = OpenMain();
        if (state.SongBooks.Count == 0) return false;
        SetMode(WorkMode.Songs);
        var songs = window.Songs!;
        var biggest = state.SongBooks.OrderByDescending(e => FileSize(e.Url)).First();
        if (state.SongBookID != biggest.Id) { songs.SelectBook(biggest.Id); Settle(); }
        var until = DateTime.Now.AddSeconds(10);
        while (!songs.SongIndexIsReady && DateTime.Now < until) { Snapshot.Pump(2); Thread.Sleep(20); }
        Settle();
        var total = songs.SongRows.RowCount;
        var (first0, end0) = songs.SongList.VisibleItems;
        Header("Замір модуля «Пісні»",
            "Вікно 1600×1000, три списки на місці, вкладки пісенників на місці.",
            $"Відкрито пісенник: {state.SongBookID}, пісень {total}, видно рядків {end0 - first0}.",
            $"Пісенників на смузі: {state.SongBooks.Count}.");
        if (total <= 40) { Note("збірник замалий — міряти нічого"); return true; }

        var letters = new[] { "с", "сл", "сла", "слав", "б", "бл", "бла", "благ" };
        var letter = 0;
        Report("літера в полі швидкого вибору пісні", 81, () => songs.TypeSongQuery(letters[letter++ % letters.Length]));
        songs.TypeSongQuery("");
        Settle();
        var only = 0;
        Report($"лише відбір (перебір {total} назв)", 81, () => songs.FilterOnly(letters[only++ % letters.Length]));
        songs.TypeSongQuery("");
        songs.SongList.ScrollTo(0, ScrollPlace.Top);
        Settle();

        var visible = 0;
        Report("вибір пісні (клацання по видимому рядку)", 101, () =>
        {
            var (first, end) = songs.SongList.VisibleItems;
            visible = (visible + 1) % Math.Max(1, end - first);
            songs.SongList.Click(first + visible);
        });
        var seed = 12345;
        Report("вибір пісні (стрибок через увесь збірник)", 61, () =>
        {
            seed = (int)((seed * 1103515245L + 12345) & 0x3FFF_FFFF);
            songs.SongList.Click(seed % total);
        });

        // Пісня з трьома й більше частинами — для куплетів.
        var picked = 0;
        for (var row = 0; row < total && picked < 3; row++)
        {
            songs.SongList.Click(row);
            Snapshot.Pump(1);
            picked = songs.Model.Song?.Parts.Count ?? 0;
        }
        Settle();
        if (picked >= 2)
        {
            var part = 0;
            Report("перемикання куплета (у передпоказ)", 101, () =>
            {
                part = (part + 1) % picked;
                songs.PartList.Click(part);
            }, slide: true);
            var live = 0;
            Report("перемикання куплета (подвійне клацання, у зал)", 61, () =>
            {
                live = (live + 1) % picked;
                songs.PartList.Click(live, clickCount: 2);
            }, slide: true);
            var arrow = 0;
            Report("перемикання куплета стрілкою", 101, () =>
            {
                arrow++;
                state.StepSongPart(arrow % 2 == 0 ? -1 : 1, false);
            }, slide: true);
            state.HideSlide();
            Settle();
        }

        var wheel = 0;
        Report("прокрутка списку (колесо, три рядки)", 121, () =>
        {
            wheel = (wheel + 3) % Math.Max(1, total - 30);
            songs.SongList.ScrollTo(wheel, ScrollPlace.Top);
        });
        var page = 0;
        Report("прокрутка списку (сторінка)", 61, () =>
        {
            page = (page + 20) % Math.Max(1, total - 30);
            songs.SongList.ScrollTo(page, ScrollPlace.Top);
        });
        Report("прокрутка від початку до кінця збірника", 21, () =>
        {
            songs.SongList.ScrollTo(total - 1, ScrollPlace.Top);
            songs.SongList.ScrollTo(0, ScrollPlace.Top);
        });

        if (state.SongBooks.FirstOrDefault(e => e.Id != biggest.Id) is { Id: { Length: > 0 } } other)
        {
            songs.SelectBook(other.Id);
            Settle();
            songs.SelectBook(biggest.Id);
            Settle();
            var flip = false;
            Report("зміна пісенника (обидва вже розібрано)", 41, () =>
            {
                flip = !flip;
                songs.SelectBook(flip ? other.Id : biggest.Id);
            });
            songs.SelectBook(biggest.Id);
            Settle();
        }
        Report($"перечитати список пісень ({total} рядків)", 41, () => songs.SongList.Reload());
        Lines.Add("");
        Lines.Add($"Згортання назв на головному потоці знадобилося {songs.HurriedFolds} разів (0 — фоновий розбір завжди встигав).");
        return true;
    }

    static long FileSize(string path)
    {
        try { return new FileInfo(path.StartsWith("file:") ? new Uri(path).LocalPath : path).Length; } catch { return 0; }
    }
}
