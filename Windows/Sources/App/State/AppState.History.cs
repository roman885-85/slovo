// =============================================================================
//  AppState.History.cs — «Історія:» (як частина DeskModel на Mac)
// =============================================================================
//  Той самий файл, що на Mac і в VisioBible: History.ini у теці даних, до 60
//  записів. Показ вірша в зал — запис «Івана 3:16- 16 . Бо так полюбив…».
//  Подвійне клацання чи Enter по запису — відкрити місце й показати в залі.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    ServiceHistory? _history;
    public ServiceHistory History => _history ??= LoadHistory();
    public Guid? HistorySelection { get; set; }

    static string HistoryPath => Path.Combine(DataHome.Folder, ServiceHistory.FileName);

    static ServiceHistory LoadHistory()
    {
        try { return File.Exists(HistoryPath) ? ServiceHistory.Read(HistoryPath) : new ServiceHistory(); }
        catch (Exception error) { Journal.Say($"історія не прочиталась: {error.Message}"); return new ServiceHistory(); }
    }

    void SaveHistory()
    {
        try { Directory.CreateDirectory(DataHome.Folder); History.Journal().Write(HistoryPath); }
        catch (Exception error) { Journal.Say($"історія не записалась: {error.Message}"); }
    }

    /// Показане в залі — в «Історію» (rememberLive у DeskModel): що саме показано,
    /// беремо з готового LiveSlide — запис однаково працює для Біблії, «Тексту» й пісень.
    void RememberLive()
    {
        var slide = LiveSlide;
        var quote = slide.MainText.Trim();
        // Порожній і чорний слайд — не місце Писання: гасіння історія не пам'ятає.
        if (slide.IsBlank || (quote.Length == 0 && slide.Reference.Length == 0)) return;
        // З плеєра й показу писати нічого: там не місце Писання, а файл.
        if (Mode is WorkMode.Media or WorkMode.Pictures or WorkMode.Presentation or WorkMode.Screen) return;
        HistoryRecord record;
        switch (Mode)
        {
            case WorkMode.Bible:
            {
                if (CurrentBook is not { } book) return;
                record = new HistoryRecord(HistoryRecord.Kind.Bible, HistoryRecord.CaptionFor(slide.Reference, quote), slide.Reference, quote,
                                           (int)BookClass, book.Index, SelectedChapterNumber, SelectedVerseNumbers.OrderBy(n => n),
                                           PrimaryModule?.Info.ShortName ?? "",
                                           SecondaryModuleIDs.Count > 0 && Module(SecondaryModuleIDs[0]) is { } s ? s.Info.ShortName : "",
                                           string.Join(",", book.ShortNames), book.FullName);
                break;
            }
            case WorkMode.Songs:
                if (SongRecord(slide, quote) is not { } song) return;
                record = song;
                break;
            default:
                record = new HistoryRecord(HistoryRecord.Kind.Text, HistoryRecord.CaptionFor(slide.Reference, quote), slide.Reference, quote);
                break;
        }
        // Показ, що прийшов із самої Історії, Історію не міняє: запис не з'являється
        // вгорі вдруге (власник, 15.09.2026). Наступний показ пишеться як завжди.
        if (_historyReplay is { } replay)
        {
            _historyReplay = null;
            if (SameMoment(replay, record)) return;
        }
        History.Remember(record);
        HistorySelection = History.Records.FirstOrDefault()?.Id;
        SaveHistory();
        Signals.Shared.Send(Signals.Kind.History);
    }

    HistoryRecord? _historyReplay;

    static bool SameMoment(HistoryRecord a, HistoryRecord b)
    {
        if (a.RecordKind != b.RecordKind) return false;
        return a.RecordKind switch
        {
            HistoryRecord.Kind.Bible => a.BookIndex == b.BookIndex && a.Chapter == b.Chapter && a.Verses.ToHashSet().SetEquals(b.Verses),
            HistoryRecord.Kind.Song => a.SongBookFileName == b.SongBookFileName && a.SongIndex == b.SongIndex && a.PartIndex == b.PartIndex,
            _ => a.Quote == b.Quote && a.Reference == b.Reference,
        };
    }

    /// Відкрити запис історії (і показати в залі): Біблія — у тому самому перекладі;
    /// текст — назад у модуль «Текст»; пісня — на вкладку «Пісні».
    public void ActivateHistory(HistoryRecord record, bool show)
    {
        HistorySelection = record.Id;
        _historyReplay = show ? record : null;
        switch (record.RecordKind)
        {
            case HistoryRecord.Kind.Bible:
            {
                // Переклад — за коротким ім'ям у записі.
                var name = record.ModuleShortName.Trim();
                if (name.Length > 0 && PrimaryModule?.Info.ShortName != name
                    && AllModules.FirstOrDefault(m => string.Equals(m.Info.ShortName, name, StringComparison.OrdinalIgnoreCase)) is { } module)
                    PrimaryModuleID = module.Identifier;
                if (Mode != WorkMode.Bible) { Mode = WorkMode.Bible; Signals.Shared.Send(Signals.Kind.Mode); }
                var position = Books.FindIndex(b => b.Index == record.BookIndex);
                if (position < 0 && record.BookIndex >= 0 && record.BookIndex < Books.Count) position = record.BookIndex;
                if (position < 0) { Journal.Say($"історія: книги №{record.BookIndex} немає в «{PrimaryModule?.Info.ShortName}»"); break; }
                var verses = record.Verses.ToList();
                OpenScripture(position, record.Chapter, available => verses.Where(available.Contains).ToList(), show ? ShowCurrentSlide : null);
                break;
            }
            case HistoryRecord.Kind.Song:
                OpenSongRecord(record, show);
                break;
            default:
                if (Mode != WorkMode.Text) { Mode = WorkMode.Text; Signals.Shared.Send(Signals.Kind.Mode); }
                TextModuleModel.Shared.Receive(record.Reference, record.Quote);
                if (show) ShowCurrentSlide();
                break;
        }
        Signals.Shared.Send(Signals.Kind.History);
    }

    /// Дія, що чекає на розібрані розділи книги (відкриття з історії чи плану).
    Action? _pendingOpen;
    void RunPendingOpen() { var open = _pendingOpen; _pendingOpen = null; open?.Invoke(); }

    public void RemoveHistory(Guid id) { History.Remove(id); if (HistorySelection == id) HistorySelection = null; SaveHistory(); Signals.Shared.Send(Signals.Kind.History); }
    public void ClearHistory() { History.RemoveAll(); SaveHistory(); Signals.Shared.Send(Signals.Kind.History); }
}

/// Рядки «Історії» для списку.
public sealed class HistoryRows : IRowSource
{
    readonly AppState _state;
    public HistoryRows(AppState state) { _state = state; }
    public int RowCount => _state.History.Records.Count;
    public Row RowAt(int index) => new(_state.History.Records[index].Caption) { SingleLine = true };
    public Avalonia.Controls.ContextMenu? MenuAt(int index)
    {
        if (index < 0 || index >= _state.History.Records.Count) return null;
        var record = _state.History.Records[index];
        string Caption(string key, string fallback) => Captions.Caption(key, fallback).Replace("&", "");
        return MenuStrip.Build(new[]
        {
            new MenuEntry(Caption("N15", "Перейти"), () => _state.ActivateHistory(record, true)),
            new MenuEntry(Caption("MIDelHisItem", "Удалить"), () => _state.RemoveHistory(record.Id), StartsGroup: true),
            new MenuEntry(Caption("MIHistClear", "Очистить историю"), _state.ClearHistory),
        });
    }
}
