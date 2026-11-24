// =============================================================================
//  ImportPages.cs — сторінки майстра імпорту: 4.2 вступна і 4.2.1 вибір версії
//  (як NativeImportPages.swift)
// =============================================================================
//  Порядок, підписи й ключі перекладу — авторські (форма ImportFromOldVersForm);
//  своїми словами написано тільки те, чого в автора немає. Розкладка — тими
//  самими числами, що layout() на Mac.
//
//  Відмінність від Mac одна: вікно вибору Windows бере або теку, або файл, а не
//  обидва разом, як NSOpenPanel. Тому кнопка «Вибрати теку з попередньою
//  версією» відкриває меню з двох пунктів — теку чи файл (архів .zip, .SQLite3,
//  .mybible, .vbm, .songbook).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

/// Сторінка, якій є що оновити при перемальовці майстра (ImportPageRefreshing).
public abstract class WizardPage : LayoutPanel
{
    public abstract void RefreshPage();

    /// Підпис елемента форми ImportFromOldVersForm із файла перекладу автора.
    public static string Imp(string key, string fallback) => Captions.FormCaption(key, "ImportFromOldVersForm", fallback);

    public static string ImpHint(string key, string fallback) =>
        Captions.FormHint(key, "ImportFromOldVersForm") is { Length: > 0 } hint ? hint : Captions.T(fallback);
}

// --- 4.2 Вступна ---------------------------------------------------------------------

public sealed class ImportIntroPage : WizardPage
{
    readonly ImportWizardModel _model;
    readonly ImportStack _stack = new() { Spacing = 14 };
    readonly PathLabel _destination = new();

    public ImportIntroPage(ImportWizardModel model)
    {
        _model = model;
        var intro = new WrapLabel(Captions.T("Этот мастер переносит модули Библии и песенники, шаблоны слайда и фоновые изображения в библиотеку программы."), 13);
        // Чесна межа: в оригіналі джерело — лише попередня версія, тут — будь-яка
        // тека з даними й архів; налаштувань не переносимо. Перелік форматів повний
        // і збігається з описом на GitHub.
        var ours = new WrapLabel(Captions.T("Источником может быть папка с данными прежней программы или любая папка, архив .zip либо файл: "
            + "модули «Цитата из Библии» (папка с bibleqt.ini или архив .zip, в том числе несколько архивов в одной папке); "
            + "модули MyBible (.SQLite3, .sqlite — вместе со словарями и комментариями рядом); модули MySword (.bbl.mybible); "
            + "песенники в старом формате (.vbm) и «Слова» (.songbook); шаблоны слайда (папка Templates, .sch); "
            + "фоновые изображения (.jpg, .png, .bmp, .gif, .tif, .heic, .webp). "
            + "Настройки чужой программы не переносятся — у «Слова» свои. Каждый модуль перед переносом открывается, "
            + "и в библиотеку не попадает то, что программа не прочитает."), 11, secondary: true);
        var reveal = Form.Button(Captions.T("Показать в Проводнике"),
                                 DataHome.Hint(Captions.T("Открыть в Проводнике папку, куда программа кладёт данные")), () =>
                                 {
                                     try { _model.Destination.Prepare(); } catch (Exception error) { Journal.Say("імпорт: " + error.Message); }
                                     Explorer.Show(_model.Destination.DataRoot);
                                 });
        var box = new ImportBox(Captions.T("Куда будет перенесено"), new Control[] { _destination, new ButtonRow(true, reveal) });
        var tail = new WrapLabel(Captions.T("%s — к выбору источника.", Imp("PBBNext", "Дальше")), 11, secondary: true);
        _stack.Set(new Control[] { intro, ours, box, tail });
        Children.Add(_stack);
    }

    public override void RefreshPage()
    {
        _destination.Text = _model.Destination.DataRoot;
        InvalidateArrange();
    }

    protected override void Arrangement(Size size) =>
        Place(_stack, new Rect(0, 0, size.Width, _stack.HeightFor(size.Width)));
}

// --- 4.2.1 Вибір версії -----------------------------------------------------------------

public sealed class ImportVersionsPage : WizardPage, IRowSource
{
    readonly ImportWizardModel _model;
    readonly Func<Window?> _owner;
    readonly BottomCaption _hint = new() { FontSize = 11 };
    readonly ImportTable _table;
    readonly BottomCaption _empty = new() { FontSize = 12, Align = TextAlignment.Center };
    readonly BottomCaption _pathTitle = new() { FontSize = 11, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
    readonly PathLabel _pathValue = new("—");
    readonly PushButton _choose, _search, _stop;
    readonly Spinner _spinner = new();
    readonly PathLabel _searchStatus = new("", 10, monospace: false);
    /// Кого показували минулого разу: список приходить з обходу дисків десятками, і
    /// перетрушувати таблицю на кожну перемальовку — губити виділення під руками.
    List<string> _shownIDs = new();

    public ImportVersionsPage(ImportWizardModel model, Func<Window?> owner)
    {
        _model = model;
        _owner = owner;
        _choose = Form.Button(Imp("PBBSelectFolderPortableVers", "Выбрать папку с предыдущей версией"),
                              ImpHint("PBBSelectFolderPortableVers", "Выбрать вручную папку с предыдущей версией программы")
                              + "\n" + Captions.T("папка с данными, архив .zip или файл .SQLite3, .mybible, .vbm, .songbook"), Choose);
        _search = Form.Button(Imp("PBBFindPortableVers", "Найти другие версии автоматически"),
                              ImpHint("PBBFindPortableVers", "Найти другие версии программы автоматически на всех дисках"), _model.SearchAllDisks);
        _stop = Form.Button(Imp("PBBStopSearch", "Остановить"),
                            ImpHint("PBBStopSearch", "Остановить поиск других версий программы"), _model.StopSearch);
        _hint.Text = Imp("Label9", "Выберите из списка предыдущую версию для импорта.");
        _empty.Text = Imp("LOldAppNotFound", "Другие версии программы не найдены");
        // Label1 — «Шлях до теки з налаштуваннями попередньої версії програми:»
        _pathTitle.Text = Imp("Label1", "Путь к папке с настройками предыдущей версии программы:");
        _table = new ImportTable(this, 0, 240, Imp("LVVersions->Column0", "Версия"), Imp("LVVersions->Column1", "Путь"));
        _table.List.OnSelect = (_, row, cause) =>
        {
            if (cause == SelectCause.Code || row < 0 || row >= _model.Sources.Count) return;
            _model.SelectedSourceID = _model.Sources[row].Id;
        };
        foreach (Control c in new Control[] { _hint, _table, _empty, _pathTitle, _pathValue, _choose, _search, _stop, _spinner, _searchStatus })
            Children.Add(c);
    }

    public override void RefreshPage()
    {
        var ids = _model.Sources.Select(source => source.Id).ToList();
        if (!ids.SequenceEqual(_shownIDs))
        {
            _shownIDs = ids;
            _table.Reload();
        }
        var selected = _model.Sources.FindIndex(source => source.Id == _model.SelectedSourceID);
        if (selected >= 0 && !_table.List.Selection.Contains(selected)) _table.List.SetSelection(new[] { selected }, selected);
        var hasSources = _model.Sources.Count > 0;
        _table.IsVisible = hasSources;
        _empty.IsVisible = !hasSources;
        _pathValue.Text = _model.SelectedSource?.Path ?? "—";
        _search.IsVisible = !_model.IsSearching;
        _stop.IsVisible = _model.IsSearching;
        _spinner.IsVisible = _model.IsSearching;
        _spinner.IsSpinning = _model.IsSearching;
        _searchStatus.Text = _model.IsSearching ? _model.SearchStatus : "";
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        var width = size.Width;
        Place(_hint, MacLabel.Inset(new Rect(0, 0, width, 16)));
        var searchRow = size.Height - 18;
        Place(_searchStatus, new Rect(22, searchRow, Math.Max(0, width - 22), 14));
        Place(_spinner, new Rect(0, searchRow, 14, 14));

        var buttonsRow = searchRow - 30;
        var chooseWidth = Math.Min(width * 0.55, MacButton.Intrinsic(_choose) + 24);
        Place(_choose, new Rect(0, buttonsRow, chooseWidth, 22));
        var searchWidth = Math.Min(width - chooseWidth - 8, MacButton.Intrinsic(_search) + 24);
        Place(_search, new Rect(chooseWidth + 8, buttonsRow, Math.Max(0, searchWidth), 22));
        Place(_stop, new Rect(chooseWidth + 8, buttonsRow, Math.Max(90, MacButton.Intrinsic(_stop) + 24), 22));

        var pathRow = buttonsRow - 44;
        Place(_pathTitle, MacLabel.Inset(new Rect(0, pathRow, width, 15)));
        Place(_pathValue, new Rect(0, pathRow + 18, width, 15));

        const double tableTop = 22;
        var tableHeight = Math.Max(60, pathRow - 8 - tableTop);
        Place(_table, new Rect(0, tableTop, width, tableHeight));
        var lh = UiFont.LineHeight(12);
        Place(_empty, new Rect(0, tableTop + tableHeight / 2 - lh / 2, width, lh));
    }

    // --- Таблиця ------------------------------------------------------------------------

    public int RowCount => _model.Sources.Count;

    public Row RowAt(int index)
    {
        var source = _model.Sources[index];
        return new Row($"{Mark(source.Kind)} {source.Version}", "", source.Path)
        {
            SingleLine = true, Tooltip = source.Path, Fill = ImportTable.Stripe(index),
        };
    }

    /// Звідки взялося джерело. Значків в оригіналі немає — пишемо знаком, щоб у списку
    /// було видно, що перед тобою: установлена копія, тека чи архів.
    static string Mark(ImportSourceKind kind) => kind switch
    {
        ImportSourceKind.Installed => "▣",
        ImportSourceKind.Folder => "▤",
        _ => "🗜",
    };

    /// N2 — «Відкрити теку з програмою».
    public ContextMenu? MenuAt(int index)
    {
        if (index < 0 || index >= _model.Sources.Count) return null;
        var path = _model.Sources[index].OriginUrl;
        return MenuStrip.Build(new[] { new MenuEntry(Imp("N2", "Открыть папку с программой"), () => Explorer.Show(path)) });
    }

    // --- Вибір теки чи файла -----------------------------------------------------------------

    /// OpenDialogSelHandly — «Вибрати теку з попередньою версією». Крім теки приймаємо
    /// архів і окремий файл модуля: майстер працює не тільки з минулою версією програми.
    void Choose()
    {
        var menu = MenuStrip.Build(new[]
        {
            new MenuEntry(Imp("PBBSelectFolderPortableVers", "Выбрать папку с предыдущей версией") + "…", () => _ = ChooseFolder()),
            new MenuEntry(Captions.T("Выбрать файл…"), () => _ = ChooseFile()),
        });
        menu.PlacementTarget = _choose;
        menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
        menu.Open(_choose);
    }

    string PickerTitle => Imp("OpenDialogSelHandly", "Выбрать папку с предыдущей версией") + " — "
                          + Captions.T("папка с данными, архив .zip или файл .SQLite3, .mybible, .vbm, .songbook");

    async Task ChooseFolder()
    {
        if (TopLevel.GetTopLevel(_owner()) is not { } top) return;
        var folders = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = PickerTitle, AllowMultiple = false });
        if (folders.Count > 0 && folders[0].TryGetLocalPath() is { } path) _model.AddChosen(path, Languages.Current);
    }

    async Task ChooseFile()
    {
        if (TopLevel.GetTopLevel(_owner()) is not { } top) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = PickerTitle,
            AllowMultiple = false,
            FileTypeFilter = new[]
            {
                new FilePickerFileType(Captions.T("папка с данными, архив .zip или файл .SQLite3, .mybible, .vbm, .songbook"))
                {
                    Patterns = new[] { "*.zip", "*.SQLite3", "*.sqlite", "*.mybible", "*.vbm", "*.songbook" },
                },
            },
        });
        if (files.Count > 0 && files[0].TryGetLocalPath() is { } path) _model.AddChosen(path, Languages.Current);
    }
}
