// =============================================================================
//  ImportListPage.cs — сторінки 4.2.2–4.2.4: опис того, що можна перенести
//  (як NativeImportListPage.swift)
// =============================================================================
//  Влаштовані однаково: галочка, «Коротка назва» з позначкою стану, «Повна
//  назва» і дві кнопки праворуч угорі — «позначити все» / «зняти все».
//  Позначки — не прикраса: рівно вони пояснюють, чому стоїть галочка (4.2.2:
//  «автоматично будуть позначені відсутні в поточній версії або новіші модулі»).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class ImportListPage : WizardPage, IRowSource
{
    readonly ImportWizardModel _model;
    readonly ImportWizardModel.Page _page;
    readonly PushButton _selectAll, _deselectAll;
    readonly ImportTable _table;
    readonly BottomCaption _empty = new() { FontSize = 12, Align = TextAlignment.Center };
    readonly BottomCaption _counter = new() { FontSize = 10 };
    List<string> _shownIDs = new();

    public ImportListPage(ImportWizardModel model, ImportWizardModel.Page page)
    {
        _model = model;
        _page = page;
        // Кнопки-значки без підпису (texturedRounded на Mac): рамка на всю кнопку.
        _selectAll = new PushButton("", "checkmark.square") { Margin = 0, SymbolSize = 13, Pressed = () => _model.SetAll(_page, true) };
        _deselectAll = new PushButton("", "square") { Margin = 0, SymbolSize = 13, Pressed = () => _model.SetAll(_page, false) };
        ToolTip.SetTip(_selectAll, SelectAllHint);
        ToolTip.SetTip(_deselectAll, DeselectAllHint);
        _table = new ImportTable(this, 22, 300, Imp("LVModules->Column0", "Короткое название"), Imp("LVModules->Column1", "Полное название"));
        _table.List.OnLeadClick = Toggle;
        _empty.Text = EmptyText;
        foreach (Control c in new Control[] { _selectAll, _deselectAll, _table, _empty, _counter }) Children.Add(c);
    }

    List<ImportItem> Items => _model.Items(_page);

    public override void RefreshPage()
    {
        var list = Items;
        _empty.IsVisible = list.Count == 0;
        _table.IsVisible = list.Count > 0;
        var ids = list.Select(item => item.Id).ToList();
        if (!ids.SequenceEqual(_shownIDs))
        {
            _shownIDs = ids;
            _table.Reload();
        }
        else
        {
            // Галочки міняються найчастіше — рядки перемальовуються на місці.
            _table.List.ReloadRows(Enumerable.Range(0, list.Count));
        }
        var chosen = list.Where(item => item.IsSelected).ToList();
        var bytes = chosen.Sum(item => item.ByteSize);
        var line = Captions.T("Отмечено %s из %s", chosen.Count.ToString(), list.Count.ToString());
        if (bytes > 0) line += " · " + ByteSize.Text(bytes);
        _counter.Text = line;
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        var width = size.Width;
        Place(_deselectAll, new Rect(width - 28, 0, 28, 22));
        Place(_selectAll, new Rect(width - 62, 0, 28, 22));
        const double top = 28;
        var bottom = size.Height - 18;
        var body = new Rect(0, top, width, Math.Max(60, bottom - top - 6));
        Place(_table, body);
        var lh = UiFont.LineHeight(12);
        Place(_empty, new Rect(0, body.Center.Y - lh / 2, width, lh));
        Place(_counter, MacLabel.Inset(new Rect(0, bottom, width, 14)));
    }

    void Toggle(int index)
    {
        var list = Items;
        if (index < 0 || index >= list.Count) return;
        _model.SetSelected(list[index].Id, _page, !list[index].IsSelected);
    }

    // --- Таблиця ------------------------------------------------------------------------

    public int RowCount => Items.Count;

    public Row RowAt(int index)
    {
        var item = Items[index];
        return new Row(item.Title, item.IsSelected ? "☑" : "☐", item.Subtitle)
        {
            SingleLine = true, Tooltip = item.Subtitle, Fill = ImportTable.Stripe(index), Badge = ConditionBadge(item) ?? "",
        };
    }

    /// TextMessages4 «Немає» — у поточній версії цього немає, TextMessages2
    /// «Застар.» — те, що є, старіше за джерело.
    static string? ConditionBadge(ImportItem item) => item.Condition switch
    {
        ImportCondition.Missing => Imp("TextMessages4", "Нет"),
        ImportCondition.Outdated => Imp("TextMessages2", "Устар."),
        _ => null,
    };

    /// N1 — «Відкрити теку з модулем».
    public ContextMenu? MenuAt(int index)
    {
        var list = Items;
        if (index < 0 || index >= list.Count) return null;
        var path = list[index].SourceUrl;
        return MenuStrip.Build(new[] { new MenuEntry(Imp("N1", "Открыть папку с модулем"), () => Explorer.Show(path)) });
    }

    // --- Підписи ------------------------------------------------------------------------

    string EmptyText => _page switch
    {
        ImportWizardModel.Page.Modules => Captions.T("В источнике нет модулей"),
        ImportWizardModel.Page.Templates => Captions.T("В источнике нет шаблонов слайда"),
        ImportWizardModel.Page.Images => Captions.T("В источнике нет фоновых изображений"),
        _ => "",
    };

    string SelectAllHint => _page switch
    {
        ImportWizardModel.Page.Modules => ImpHint("PSBSelModules", "Выделить все модули"),
        ImportWizardModel.Page.Templates => ImpHint("PSBSelTemplates", "Выделить все шаблоны слайда"),
        ImportWizardModel.Page.Images => ImpHint("PSBSelImages", "Выделить все изображения"),
        _ => "",
    };

    string DeselectAllHint => _page switch
    {
        ImportWizardModel.Page.Modules => ImpHint("PSBUnSelModules", "Снять выделение со всех модулей"),
        ImportWizardModel.Page.Templates => ImpHint("PSBUnSelTemplates", "Снять выделение со всех шаблонов слайда"),
        ImportWizardModel.Page.Images => ImpHint("PSBUnSelImages", "Снять выделение со всех изображений"),
        _ => "",
    };
}
