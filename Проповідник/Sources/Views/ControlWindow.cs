// =============================================================================
//  ControlWindow.cs — керування показом, коли план уже в «Слові»
// =============================================================================
//  Як колонка «План проповіді» на планшеті: зал картинкою, пункти плану
//  (клацання — пункт у залі), «Назад», «Далі», «Показати», «Сховати»,
//  «Чорний екран» і «Повернути план служіння». Стан — довгим опитом
//  /api/state: змінили щось на комп'ютері — вікно йде слідом.
// =============================================================================

using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed class ControlWindow : Window
{
    readonly Settings _settings;
    readonly Api _api;
    readonly CancellationTokenSource _closing = new();
    readonly Image _hall = new() { Stretch = Stretch.Uniform };
    readonly TextBlock _hallNote = new() { Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    readonly ListBox _plan;
    readonly TextBlock _title, _status;
    bool _filling;

    sealed record Row(int Index, string Title, string Subtitle, bool Current);

    public ControlWindow(Settings settings)
    {
        _settings = settings;
        _api = Api.From(settings);
        Title = Lang.T("Проповідник Слова — керування показом", "Slovo Preacher — show control");
        Width = 1040;
        Height = 680;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _title = Ui.Label("", 17, true);
        _status = new TextBlock { Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        _plan = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<Row>((row, _) =>
            {
                var panel = new StackPanel { Spacing = 2, Margin = new Thickness(2, 4) };
                panel.Children.Add(new TextBlock
                {
                    Text = row == null ? "" : $"{row.Index + 1}.  {row.Title}",
                    FontWeight = row?.Current == true ? FontWeight.Bold : FontWeight.SemiBold,
                    Foreground = row?.Current == true ? Ui.Accent : Brushes.Black,
                    TextWrapping = TextWrapping.Wrap,
                });
                if (!string.IsNullOrEmpty(row?.Subtitle))
                    panel.Children.Add(new TextBlock { Text = row.Subtitle, Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
                return panel;
            }),
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(_plan, Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled);
        _plan.SelectionChanged += async (_, _) =>
        {
            if (_filling || _plan.SelectedItem is not Row row) return;
            await Send("plan", row.Index);
        };

        var hall = new Border
        {
            Background = Brushes.Black,
            CornerRadius = new CornerRadius(8),
            ClipToBounds = true,
            Child = new Grid { Children = { _hall, _hallNote } },
        };
        var buttons = Ui.Row(
            Ui.Button(Lang.T("◀ Назад", "◀ Back"), async () => await Send("prev")),
            Ui.Button(Lang.T("Далі ▶", "Next ▶"), async () => await Send("next"), accent: true),
            Ui.Button(Lang.T("Показати", "Show"), async () => await Send("show"), Lang.T("Вивести в зал те, що в передпоказі", "Show what is in the preview in the hall")),
            Ui.Button(Lang.T("Сховати", "Hide"), async () => await Send("hide")),
            Ui.Button(Lang.T("Чорний екран", "Black screen"), async () => await Send("black")));
        buttons.HorizontalAlignment = HorizontalAlignment.Center;
        buttons.Margin = new Thickness(0, 10, 0, 0);

        var restore = Ui.Button(Lang.T("Повернути план служіння", "Restore the service plan"), async () =>
        {
            await Send("sermon-end");
            Close();
        }, Lang.T("План служіння лише відкладено на час проповіді — кнопка повертає його таким, яким він був",
                  "The service plan was only set aside for the sermon — this brings it back as it was"));
        restore.HorizontalAlignment = HorizontalAlignment.Stretch;
        restore.HorizontalContentAlignment = HorizontalAlignment.Center;
        restore.Foreground = Ui.Accent;

        var leftPanel = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Bottom);
        leftPanel.Children.Add(buttons);
        leftPanel.Children.Add(hall);

        var rightPanel = new DockPanel();
        var planHead = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 0, 6) };
        planHead.Children.Add(_title);
        planHead.Children.Add(Ui.Hint(Lang.T("Клацніть пункт — він у залі.", "Click an item — it goes to the hall.")));
        DockPanel.SetDock(planHead, Dock.Top);
        restore.Margin = new Thickness(0, 8, 0, 0);
        DockPanel.SetDock(restore, Dock.Bottom);
        rightPanel.Children.Add(planHead);
        rightPanel.Children.Add(restore);
        rightPanel.Children.Add(new Border { Child = _plan, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("3*,12,2*"), Margin = new Thickness(14) };
        grid.Children.Add(leftPanel);
        Grid.SetColumn(rightPanel, 2);
        grid.Children.Add(rightPanel);
        var root = new DockPanel { Background = Ui.Paper };
        _status.Margin = new Thickness(14, 0, 14, 10);
        DockPanel.SetDock(_status, Dock.Bottom);
        root.Children.Add(_status);
        root.Children.Add(grid);
        Content = root;

        Closed += (_, _) => _closing.Cancel();
        _ = Follow();
    }

    async Task Send(string name, int index = -1)
    {
        try
        {
            if (index >= 0) await _api.Command(name, index); else await _api.Command(name);
            _status.Text = "";
        }
        catch (Exception error)
        {
            _status.Text = Lang.F("Не вдалося: {0}", "Failed: {0}", Api.Describe(error));
        }
    }

    /// Довгий опит стану; після кожної зміни — і картинка залу.
    async Task Follow()
    {
        long seq = 0;
        while (!_closing.IsCancellationRequested)
        {
            try
            {
                var state = await _api.State(seq, _closing.Token);
                seq = (long?)state["seq"] ?? seq;
                await Dispatcher.UIThread.InvokeAsync(() => Apply(state));
                await RefreshHall(state);
            }
            catch (OperationCanceledException) when (_closing.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error)
            {
                await Dispatcher.UIThread.InvokeAsync(() => _status.Text = Lang.F("Немає зв'язку: {0}", "No connection: {0}", Api.Describe(error)));
                try { await Task.Delay(2000, _closing.Token); } catch { return; }
            }
        }
    }

    void Apply(JsonObject state)
    {
        var sermon = state["sermon"] as JsonObject;
        var on = (bool?)sermon?["on"] ?? false;
        _title.Text = on
            ? Lang.F("План проповіді: {0}", "Sermon plan: {0}", (string?)sermon?["title"] ?? "")
            : Lang.T("План служіння", "Service plan");
        var rows = (state["plan"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select((item, i) => new Row(i, (string?)item["title"] ?? "", (string?)item["subtitle"] ?? "", (bool?)item["current"] ?? false))
            .ToList();
        _filling = true;
        _plan.ItemsSource = rows;
        _plan.SelectedIndex = rows.FindIndex(r => r.Current);
        _filling = false;
    }

    async Task RefreshHall(JsonObject state)
    {
        var hall = state["hall"] as JsonObject;
        var kind = (string?)hall?["kind"] ?? "";
        var note = kind switch
        {
            "video" => Lang.F("У залі відео: {0}", "Video in the hall: {0}", (string?)hall?["title"] ?? ""),
            "black" => Lang.T("У залі чорний екран", "The hall screen is black"),
            "empty" => Lang.T("У залі порожньо", "The hall is empty"),
            _ => "",
        };
        byte[]? bytes = null;
        if (note.Length == 0)
        {
            try { bytes = await _api.HallImage(960, _closing.Token); } catch { bytes = null; }
        }
        await Dispatcher.UIThread.InvokeAsync(() =>
        {
            _hallNote.Text = note;
            if (bytes == null)
            {
                _hall.Source = null;
                return;
            }
            try { _hall.Source = new Bitmap(new MemoryStream(bytes)); } catch { _hall.Source = null; }
        });
    }
}
