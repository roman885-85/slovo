// =============================================================================
//  Bench.Rows.cs — нижній ряд, верх вікна й основа списку
//  (NativeBottomBench, NativeTopBench, NativeBench на Mac)
// =============================================================================
//  Нижній ряд: слайд у передпоказі (вірш, той самий ще раз, два переклади з
//  адресою), рамка «у залі», історія на 3000 рядків (прокрутка, стрибок,
//  клацання), план на 60 пунктів (клацання, перечитування). Перетягування
//  пункту плану не міряється: на Windows це рух миші по RowList, без окремого
//  виклику, який можна смикнути з замірника.
//  Верх: розділи меню (відкрити й закрити), вкладки режиму, повзунок кегля.
//  Основа: RowList на 3400 рядків у всю робочу область — прокрутка, стрибок,
//  оновлення рядка, виділення, відбір за літерою.
// =============================================================================

using Avalonia.Controls;

namespace Slovo.App;

public static partial class Bench
{
    sealed class LongRows : IRowSource
    {
        readonly List<string> _numbers = new(), _titles = new(), _details = new();
        List<int>? _filter;
        public LongRows(int count, Func<int, string> title, Func<int, string>? detail = null)
        {
            for (var i = 1; i <= count; i++) { _numbers.Add(i.ToString()); _titles.Add(title(i)); _details.Add(detail?.Invoke(i) ?? ""); }
        }
        public int RowCount => _filter?.Count ?? _titles.Count;
        public Row RowAt(int index)
        {
            var i = _filter != null ? _filter[index] : index;
            return new Row { Lead = _numbers[i], Text = _titles[i], Detail = _details[i] };
        }
        public void Keep(string needle)
        {
            if (needle.Length == 0) { _filter = null; return; }
            var kept = new List<int>(256);
            for (var i = 0; i < _titles.Count; i++)
                if (_titles[i].Contains(needle, StringComparison.CurrentCultureIgnoreCase)) kept.Add(i);
            _filter = kept;
        }
    }

    static bool RunBottom()
    {
        var state = AppState.Shared;
        var window = OpenMain();
        SetMode(WorkMode.Bible);
        var bible = window.Bible!;
        if (state.CurrentChapter is not { Verses.Count: > 8 }) OpenPsalms(state);
        var verses = state.CurrentChapter?.Verses.Select(v => v.Number).ToList() ?? new();
        Header("Замір нижнього ряду вікна",
            "Вікно 1600×1000: план, історія, передпоказ і живий екран на місці.",
            $"Дані: {state.CurrentBook?.FullName ?? "—"} {state.SelectedChapterNumber}, віршів {verses.Count}.");
        if (verses.Count > 8)
        {
            var index = 0;
            Report("переключити вірш (передпоказ)", 61, () =>
            {
                index = (index + 1) % verses.Count;
                state.SelectedVerseNumbers = new[] { verses[index] };
            }, slide: true);
            state.SelectedVerseNumbers = new[] { verses[0] };
            Settle();
            Report("той самий слайд ще раз (нічого не змінилося)", 41, () => state.SelectedVerseNumbers = new[] { verses[0] }, slide: true);
            var other = state.OrderedModules.Select(m => m.Identifier).FirstOrDefault(id => id != state.PrimaryModuleID && !state.SecondaryModuleIDs.Contains(id));
            if (other != null)
            {
                state.ToggleSecondary(other);
                Settle();
                var pair = 0;
                Report("слайд із двома перекладами й адресою", 41, () =>
                {
                    pair = (pair + 1) % verses.Count;
                    state.SelectedVerseNumbers = new[] { verses[pair] };
                }, slide: true);
                state.ToggleSecondary(other);
                Settle();
            }
        }
        var live = false;
        Report("показ у зал і назад (рамка передпоказу)", 41, () =>
        {
            live = !live;
            window.Bottom.Preview.IsLive = live;
        });
        window.Bottom.Preview.IsLive = false;
        Settle();

        var history = window.Bottom.History.List;
        var historySource = history.Source;
        history.Source = new LongRows(3000, i => $"Бут. {i}- На початку Бог створив Небо та землю.");
        Settle();
        var (hf, he) = history.VisibleItems;
        Note($"історія: {history.ItemCount} рядків, видно {he - hf}");
        var wheel = 0;
        Report("прокрутка історії на три рядки", 121, () =>
        {
            wheel = (wheel + 3) % Math.Max(1, history.ItemCount - 20);
            history.ScrollTo(wheel, ScrollPlace.Top);
        });
        var jump = 12345;
        Report("стрибок у випадкове місце історії", 61, () =>
        {
            jump = (int)((jump * 1103515245L + 12345) & 0x3FFF_FFFF);
            history.ScrollTo(jump % history.ItemCount, ScrollPlace.Center);
        });
        var pick = 0;
        Report("клацання по рядку історії (виділення)", 61, () =>
        {
            var (first, end) = history.VisibleItems;
            pick = (pick + 1) % Math.Max(1, end - first);
            history.SetSelection(new[] { first + pick }, first + pick);
        });
        history.Source = historySource;
        Settle();

        var plan = window.Bottom.Plan.List;
        var planSource = plan.Source;
        plan.Source = new LongRows(60, i => $"{i}. Пісня «Великий Бог» — куплет {i % 5 + 1}");
        Settle();
        var (pf, pe) = plan.VisibleItems;
        Note($"план: {plan.ItemCount} пунктів, видно {pe - pf}");
        var planPick = 0;
        Report("клацання по пункту плану (виділення)", 61, () =>
        {
            var (first, end) = plan.VisibleItems;
            planPick = (planPick + 1) % Math.Max(1, end - first);
            plan.SetSelection(new[] { first + planPick }, first + planPick);
        });
        Report("привід «план змінився» (перечитати панель)", 41, () => plan.Reload());
        plan.Source = planSource;
        Settle();
        return true;
    }

    static bool RunTop()
    {
        var state = AppState.Shared;
        var window = OpenMain();
        SetMode(WorkMode.Bible);
        Header("Замір верху вікна: смуга меню і вкладки режиму",
            "Вікно 1600×1000. Розділ меню — збирання пунктів, відкриття під кнопкою й закриття.");
        foreach (var group in MenuGroupInfo.All)
        {
            Report($"відкрити розділ «{window.Menu.Caption(group)}»", 61, () =>
            {
                var menu = MenuStrip.Build(window.Menu.Entries(group));
                menu.Open(window.Menu);
                Snapshot.Pump(1);
                menu.Close();
            });
        }
        var modes = new[] { WorkMode.Bible, WorkMode.Text, WorkMode.Songs };
        var m = 0;
        Report("перемкнути режим (Біблія → Текст → Пісні)", 61, () =>
        {
            m = (m + 1) % modes.Length;
            window.Tabs.Select(modes[m]);
        });
        window.Tabs.Select(WorkMode.Bible);
        Settle();
        var size = state.ListFontSize;
        var up = true;
        Report("зрушити повзунок кегля на ступінь", 121, () =>
        {
            state.ZoomLists(up ? 1 : -1);
            up = !up;
        });
        if (Math.Abs(state.ListFontSize - size) > 0.01) { state.ZoomLists(size - state.ListFontSize); Settle(); }
        return true;
    }

    static bool RunBase()
    {
        var window = OpenMain();
        SetMode(WorkMode.Bible);
        var rows = new LongRows(3400, i => $"Пісня {i}: хвала і подяка Господу нашому", i => $"слова й музика, збірник {i % 40}");
        var list = new RowList(ListMetrics.Settings(220), 13) { Source = rows };
        list.SetUniformHeight(34);
        list.AllowsMultipleSelection = true;
        window.Root.Slots[Slot.Workspace].Install(list);
        Settle();
        var (vf, ve) = list.VisibleItems;
        Header("Замір основи списку (RowList)",
            "Вікно 1600×1000, список у всю робочу область, висота рядка 34.",
            $"Дані: вигаданий збірник — {list.ItemCount} рядків, видно {ve - vf}.");
        Report("відкрити збірник 3400", 11, () => list.Reload());
        var wheel = 0;
        Report("прокрутка на три рядки (колесо)", 121, () => { wheel = (wheel + 3) % Math.Max(1, list.ItemCount - 30); list.ScrollTo(wheel, ScrollPlace.Top); });
        var page = 0;
        Report("прокрутка на сторінку", 61, () => { page = (page + 20) % Math.Max(1, list.ItemCount - 30); list.ScrollTo(page, ScrollPlace.Top); });
        var seed = 12345;
        Report("стрибок у випадкове місце", 61, () => { seed = (int)((seed * 1103515245L + 12345) & 0x3FFF_FFFF); list.ScrollTo(seed % list.ItemCount, ScrollPlace.Center); });
        list.ScrollTo(0, ScrollPlace.Top);
        Settle();
        var one = 0;
        Report("оновити один рядок", 101, () => { var (f, e) = list.VisibleItems; one = (one + 1) % Math.Max(1, e - f); list.ReloadRow(f + one); });
        var pick = 0;
        Report("змінити виділення (один рядок)", 101, () => { var (f, e) = list.VisibleItems; pick = (pick + 1) % Math.Max(1, e - f); list.SetSelection(new[] { f + pick }, f + pick); });
        var span = 0;
        Report("виділити відрізок у 200 рядків", 41, () => { span = (span + 1) % 50; list.SetSelection(Enumerable.Range(span, 200), span); });
        Report("виділити все (3400)", 41, () => { list.SelectAll(); list.SetSelection(Array.Empty<int>()); });
        var letters = new[] { "сла", "бла", "гос", "хва", "мир" };
        var letter = 0;
        Report("відбір за літерою (перебір 3400 назв)", 41, () => rows.Keep(letters[letter++ % letters.Length]));
        Report("перечитати список після відбору", 41, () => list.Reload());
        rows.Keep("");
        list.Reload();
        list.SetMeasuredHeights(34);
        list.ScrollTo(0, ScrollPlace.Top);
        Settle();
        var tall = 0;
        Report("прокрутка при висотах за текстом", 61, () => { tall = (tall + 3) % Math.Max(1, list.ItemCount - 30); list.ScrollTo(tall, ScrollPlace.Top); });
        var tallRow = 0;
        Report("оновити один рядок при висотах за текстом", 61, () => { var (f, e) = list.VisibleItems; tallRow = (tallRow + 1) % Math.Max(1, e - f); list.ReloadRow(f + tallRow); });
        window.Root.Slots[Slot.Workspace].Install(window.Bible!.View);
        return true;
    }
}
