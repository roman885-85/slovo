// =============================================================================
//  AppState.cs — увесь стан програми (як AppState.swift на Mac)
// =============================================================================
//  Переноситься частинами: тут — режим і кегль списків; решта (бібліотека,
//  пісні, слайд, План, Історія…) додається, коли перенесено ядро.
// =============================================================================

namespace Slovo.App;

public sealed partial class AppState
{
    public static AppState Shared { get; } = new();

    AppState()
    {
        // Модуль «Текст» віддає зібраний слайд туди ж, куди й Біблія.
        TextModuleModel.Shared.Present = (slide, live) => Present(slide, live);
    }

    public readonly Observable<WorkMode> ModeValue = new(WorkMode.Bible);
    /// Відкрита вкладка.
    public WorkMode Mode
    {
        get => ModeValue.Value;
        set
        {
            var old = ModeValue.Value;
            if (old == value) return;
            // Куди повернутися з плеєра — попередній режим, а не поточний.
            if (value == WorkMode.Media && old != WorkMode.Media) ModeBeforeMedia = old;
            ModeValue.Value = value;
            ModeDidChange(old);
        }
    }
    public WorkMode ModeBeforeMedia { get; private set; } = WorkMode.Bible;
    partial void ModeChanged(WorkMode old);
    void ModeDidChange(WorkMode old) { ModeChanged(old); SyncSlideToMode(); }

    public readonly Observable<double> ListFontSizeValue = new(13);
    /// Кегль списків — повзунок угорі й Ctrl з колесом.
    public double ListFontSize { get => ListFontSizeValue.Value; set => ListFontSizeValue.Value = value; }

    /// Ctrl з колесом — кегль списків на крок (як zoomLists на Mac).
    public void ZoomLists(double step)
    {
        var next = Math.Clamp(ListFontSize + step, ModeTabs.FontMin, ModeTabs.FontMax);
        if (Math.Abs(next - ListFontSize) < 0.01) return;
        ListFontSize = next;
        Signals.Shared.Send(Signals.Kind.ListFontSize);
    }

    /// Подвійне клацання по вірші — у зал (вибір + «Показати»).
    public void ShowVerse(int number)
    {
        SelectedVerseNumbers = new[] { number };
        ShowCurrent?.Invoke();
    }

    /// «Показати» — під'єднує вивід (зал), коли він готовий.
    public Action? ShowCurrent;

    /// Вкладки показу (Зображення, Презентація): стрілки й «Показати» — їм.
    public readonly Dictionary<WorkMode, ShowWorkspace> ShowTabs = new();

    /// Пара стрілок, що веде зал (LinkPreviewAndSlide): ↑↓ — зал, ←→ — передпоказ; Ctrl міняє.
    public bool ArrowsLinked
    {
        get => !Defaults.Has("arrowsLinked") || Defaults.Bool("arrowsLinked");
        set => Defaults.Set("arrowsLinked", value);
    }
}
