// =============================================================================
//  ImportSummary.cs — 4.2.6 «Завершення» (як NativeImportSummary.swift)
// =============================================================================
//  До натискання — що буде перенесено (за групами, звідки й куди), після —
//  що перенеслося, що з ним сталося і де його шукати.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class ImportSummaryPage : WizardPage
{
    readonly AppState _state;
    readonly ImportWizardModel _model;
    readonly ImportScroll _scroll = new();
    /// Що показували минулого разу. Зведення перебудовується цілком, і без цієї
    /// позначки збиралося б заново на кожну перемальовку — разом із прокруткою,
    /// що поїхала б на початок під руками в людини.
    string _shownSignature = "";

    public ImportSummaryPage(AppState state, ImportWizardModel model)
    {
        _state = state;
        _model = model;
        _scroll.Body.Spacing = 12;
        Children.Add(_scroll);
    }

    protected override void Arrangement(Size size) => Place(_scroll, new Rect(size));

    public override void RefreshPage()
    {
        var signature = CurrentSignature;
        if (signature == _shownSignature) return;
        _shownSignature = signature;
        _scroll.Body.Set(_model.Outcome is { } outcome ? Result(outcome) : Plan());
        _scroll.RefreshHeight();
    }

    string CurrentSignature => _model.Outcome is { } outcome
        ? $"підсумок:{outcome.Total}:{outcome.Failures.Count}:{outcome.GetHashCode()}"
        : $"план:{_model.PlannedCount}:{_model.SelectedSource?.Id ?? ""}";

    // --- До натискання «Імпортувати» -----------------------------------------------------

    List<Control> Plan()
    {
        var rows = new List<Control>
        {
            Group(Imp("TextMessages3", "Модули"), Chosen(_model.Modules)),
            Group(Imp("TextMessages8", "Шаблоны слайда"), Chosen(_model.Templates)),
            Group(Imp("TextMessages5", "Фоновые изображения"), Chosen(_model.Images)),
            new ImportBox(Captions.T("Откуда и куда"), new Control[]
            {
                new ImportPair(Captions.T("Источник"), _model.SelectedSource?.Path ?? "—"),
                new ImportPair(Captions.T("Библиотека программы"), _model.Destination.DataRoot),
            }),
        };
        if (_model.PlannedCount == 0)
            rows.Add(new WrapLabel(Captions.T("Ничего не отмечено — переносить нечего."), 11, colour: () => Palette.SystemOrange));
        return rows;
    }

    static List<string> Chosen(IEnumerable<ImportItem> items) => items.Where(item => item.IsSelected).Select(item => item.Title).ToList();

    // --- Після перенесення ------------------------------------------------------------------

    List<Control> Result(ImportOutcome outcome)
    {
        var rows = new List<Control>
        {
            new WrapLabel(outcome.Failures.Count == 0
                              ? Captions.T("Перенесено объектов: %s", outcome.Total.ToString())
                              : Captions.T("Перенесено объектов: %s, с ошибками: %s", outcome.Total.ToString(), outcome.Failures.Count.ToString()),
                          13, FontWeight.SemiBold),
            Group(Imp("TextMessages3", "Модули"), outcome.Modules),
            Group(Imp("TextMessages8", "Шаблоны слайда"), outcome.Templates),
            Group(Imp("TextMessages5", "Фоновые изображения"), outcome.Images),
        };
        // Перенесене підключається без перезапуску: модулі — поіменно до списку
        // перекладів, тека з фонами — до списку тек із фонами. Людина має це
        // побачити написаним, інакше шукатиме перенесене у вікні вибору теки модулів.
        if (outcome.Total > 0)
            rows.Add(new WrapLabel(Captions.T("Перенесённые модули и песенники добавлены в список переводов, папка с фонами — в список папок с фонами («Параметры»)."),
                                   11, secondary: true));
        if (outcome.Failures.Count > 0)
            rows.Add(new ImportBox(Imp("ErrorMessages3", "Ошибка") + " — " + outcome.Failures.Count,
                                   outcome.Failures.Select(f => (Control)new WrapLabel($"{f.Title}: {f.Reason}", 11, colour: () => Palette.SystemOrange))));
        var reveal = Form.Button(Captions.T("Показать в Проводнике"),
                                 DataHome.Hint(Captions.T("Открыть в Проводнике папку, куда программа кладёт данные")),
                                 () => Explorer.Show(_model.Destination.DataRoot));
        var reread = Form.Button(Captions.T("Перечитать библиотеку"), null, _state.ReloadLibrary);
        rows.Add(new ButtonRow(false, reveal, reread));
        return rows;
    }

    /// Понад два десятки імен перетворюють сторінку на простирадло — решта згортається в лічильник.
    static ImportBox Group(string title, IReadOnlyList<string> names)
    {
        Control body = names.Count == 0
            ? new WrapLabel("—", 11, secondary: true)
            : new WrapLabel(string.Join(", ", names.Take(24)) + (names.Count > 24 ? " " + Captions.T("и ещё %s", (names.Count - 24).ToString()) : ""),
                            11, secondary: true);
        return new ImportBox($"{title} — {names.Count}", new[] { body });
    }
}
