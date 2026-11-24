// =============================================================================
//  SongEditorWindow.cs — редактор пісень
// =============================================================================
//  Пісня — назва, друга назва, автор, композитор, примітка і частини: кожна
//  зі своєю назвою («Куплет 1», «Приспів») і текстом, де перенос рядка
//  значущий. Зберігається в бібліотеку й у файл .songbook у теці даних.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Slovo.Views;

public sealed class SongEditorWindow : Window
{
    readonly AppState _state;
    readonly string _bookId;
    readonly SongBookData _book;
    SongData _song;
    readonly bool _isNew;
    readonly TextBox _title = new();
    readonly TextBox _alternate = new();
    readonly TextBox _author = new();
    readonly TextBox _composer = new();
    readonly TextBox _note = new();
    readonly StackPanel _parts = new() { Spacing = 8 };
    readonly List<(TextBox Kind, TextBox Text)> _partBoxes = new();

    public SongEditorWindow(AppState state, string bookId, int? songIndex)
    {
        _state = state;
        _bookId = bookId;
        _book = state.Library.SongBook(bookId);
        _isNew = songIndex == null || _book.Songs.All(s => s.Index != songIndex);
        _song = _isNew
            ? new SongData { Index = _book.Songs.Count == 0 ? 0 : _book.Songs.Max(s => s.Index) + 1 }
            : _book.Songs.First(s => s.Index == songIndex);
        Title = (_isNew ? Lang.T("Нова пісня", "New song") : Lang.T("Пісня", "Song")) + " — " + _book.Title;
        Width = 760;
        Height = 680;
        MinWidth = 560;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _title.Text = _song.Title; _alternate.Text = _song.AlternateTitle; _author.Text = _song.Author; _composer.Text = _song.Composer; _note.Text = _song.Note;
        if (_song.Parts.Count == 0) _song.Parts.Add(new PartData { Index = 0, Kind = Lang.T("Куплет 1", "Verse 1"), Text = "" });
        foreach (var part in _song.Parts) AddPartEditor(part.Kind, part.Text);

        var fields = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,*"), RowDefinitions = new RowDefinitions("Auto,Auto,Auto"), ColumnSpacing = 8, RowSpacing = 6 };
        void Put(Control label, Control box, int row, int column) { Grid.SetRow(label, row); Grid.SetColumn(label, column); Grid.SetRow(box, row); Grid.SetColumn(box, column + 1); fields.Children.Add(label); fields.Children.Add(box); }
        Put(Ui.Label(Lang.T("Назва", "Title")), _title, 0, 0);
        Put(Ui.Label(Lang.T("Номер", "Number")), new TextBlock { Text = (_song.Index + 1).ToString(), VerticalAlignment = VerticalAlignment.Center }, 0, 2);
        Put(Ui.Label(Lang.T("Друга назва", "Alternate title")), _alternate, 1, 0);
        Put(Ui.Label(Lang.T("Автор слів", "Lyrics by")), _author, 1, 2);
        Put(Ui.Label(Lang.T("Композитор", "Composer")), _composer, 2, 0);
        Put(Ui.Label(Lang.T("Примітка", "Note")), _note, 2, 2);

        var addPart = Ui.Button("+ " + Lang.T("Частина", "Part"), () => AddPartEditor(NextKind(), ""), Lang.T("Додати частину (куплет, приспів, міст)", "Add a part (verse, chorus, bridge)"));
        var save = Ui.Button(Lang.T("Зберегти", "Save"), () => _ = Save(), accent: true);
        save.IsDefault = false;
        var delete = Ui.Button(Lang.T("Видалити пісню…", "Delete song…"), () => _ = Delete());
        delete.IsVisible = !_isNew;
        var cancel = Ui.Button(Lang.T("Скасувати", "Cancel"), Close);
        cancel.IsCancel = true;
        var buttons = Ui.Row(delete, cancel, save);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        var hint = Ui.Hint(Lang.T("Назва частини задає її колір у списку: Куплет, Приспів, Заспів, Міст, Вступ, Кінцівка. Порожній рядок усередині частини — межа слайда.",
                                   "The part name sets its colour in the list: Verse, Chorus, Pre-Chorus, Bridge, Intro, End. A blank line inside a part is a slide break."));
        var root = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(fields, Dock.Top);
        root.Children.Add(fields);
        DockPanel.SetDock(hint, Dock.Top);
        hint.Margin = new Thickness(0, 8, 0, 4);
        root.Children.Add(hint);
        DockPanel.SetDock(buttons, Dock.Bottom);
        buttons.Margin = new Thickness(0, 8, 0, 0);
        root.Children.Add(buttons);
        DockPanel.SetDock(addPart, Dock.Bottom);
        addPart.HorizontalAlignment = HorizontalAlignment.Left;
        root.Children.Add(addPart);
        root.Children.Add(new ScrollViewer { Content = _parts });
        Content = root;
    }

    string NextKind()
    {
        var verses = _partBoxes.Count(p => (p.Kind.Text ?? "").StartsWith(Lang.T("Куплет", "Verse"), StringComparison.OrdinalIgnoreCase));
        return _partBoxes.Count % 2 == 1 ? Lang.T("Приспів", "Chorus") : Lang.T("Куплет", "Verse") + " " + (verses + 1);
    }

    void AddPartEditor(string kind, string text)
    {
        var kindBox = new TextBox { Text = kind, Width = 160 };
        var textBox = new TextBox { Text = text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 };
        var pair = (kindBox, textBox);
        _partBoxes.Add(pair);
        var card = new Border { Padding = new Thickness(8), CornerRadius = new CornerRadius(6), BorderBrush = Ui.Line, BorderThickness = new Thickness(1) };
        var head = new DockPanel();
        var tools = Ui.Row(
            Ui.Button("↑", () => Move(pair, -1), Lang.T("Вище", "Up")),
            Ui.Button("↓", () => Move(pair, 1), Lang.T("Нижче", "Down")),
            Ui.Button("×", () => { if (_partBoxes.Count > 1) { _partBoxes.Remove(pair); _parts.Children.Remove(card); } }, Lang.T("Прибрати частину", "Remove the part")));
        DockPanel.SetDock(tools, Dock.Right);
        head.Children.Add(tools);
        head.Children.Add(Ui.Row(Ui.Label(Lang.T("Частина", "Part")), kindBox));
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(head);
        stack.Children.Add(textBox);
        card.Child = stack;
        card.Tag = pair;
        _parts.Children.Add(card);
    }

    void Move((TextBox Kind, TextBox Text) pair, int delta)
    {
        var at = _partBoxes.IndexOf(pair);
        var target = at + delta;
        if (at < 0 || target < 0 || target >= _partBoxes.Count) return;
        _partBoxes.RemoveAt(at);
        _partBoxes.Insert(target, pair);
        var card = _parts.Children.First(c => ((Border)c).Tag is ValueTuple<TextBox, TextBox> t && t.Item1 == pair.Kind);
        _parts.Children.Remove(card);
        _parts.Children.Insert(target, card);
    }

    async System.Threading.Tasks.Task Save()
    {
        var title = (_title.Text ?? "").Trim();
        if (title.Length == 0) { await Ui.Message(this, Lang.T("Пісня", "Song"), Lang.T("Дайте пісні назву.", "Give the song a title.")); return; }
        _song.Title = title;
        _song.AlternateTitle = (_alternate.Text ?? "").Trim();
        _song.Author = (_author.Text ?? "").Trim();
        _song.Composer = (_composer.Text ?? "").Trim();
        _song.Note = (_note.Text ?? "").Trim();
        _song.Parts.Clear();
        var index = 0;
        foreach (var (kindBox, textBox) in _partBoxes)
        {
            var text = (textBox.Text ?? "").Replace("\r\n", "\n").Trim('\n');
            if (text.Trim().Length == 0 && (kindBox.Text ?? "").Trim().Length == 0) continue;
            _song.Parts.Add(new PartData { Index = index++, Kind = (kindBox.Text ?? "").Trim(), Text = text });
        }
        if (_isNew) _book.Songs.Add(_song);
        try
        {
            Persist();
            _state.SongBookChanged(_bookId);
            _state.SelectSong(_song.Index, false);
            Close();
        }
        catch (Exception error) { await Ui.Message(this, Lang.T("Пісня", "Song"), error.Message); }
    }

    async System.Threading.Tasks.Task Delete()
    {
        if (!await Ui.Ask(this, Lang.T("Видалити пісню", "Delete song"), Lang.F("Видалити «{0}» з пісенника? Номери наступних пісень зсунуться.", "Delete “{0}” from the songbook? The numbers of the following songs will shift.", _song.Title), Lang.T("Видалити", "Delete"))) return;
        _book.Songs.Remove(_song);
        var i = 0;
        foreach (var song in _book.Songs) song.Index = i++;
        try
        {
            Persist();
            _state.SongBookChanged(_bookId);
            Close();
        }
        catch (Exception error) { await Ui.Message(this, Lang.T("Пісня", "Song"), error.Message); }
    }

    /// У бібліотеку й у файл .songbook поруч (свій формат; .vbm лишається як є).
    void Persist()
    {
        var known = _state.Library.Find(_bookId);
        var fileName = AppState.SongBookFileName(_bookId);
        var original = known?.Original ?? "";
        var target = original.EndsWith("." + SongBookWriter.Extension, StringComparison.OrdinalIgnoreCase) && original.Length > 0
            ? original
            : Path.Combine(Paths.Modules, Path.GetFileNameWithoutExtension(fileName) + "." + SongBookWriter.Extension);
        SongBookWriter.WriteSongbook(_book, target);
        _state.Library.SaveSongBook(_bookId, _book, known?.Source ?? "file", target);
    }
}
