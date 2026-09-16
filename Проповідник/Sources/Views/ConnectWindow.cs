// =============================================================================
//  ConnectWindow.cs — де шукати «Слово»
// =============================================================================
//  Пошук у мережі розсилкою (як у пульта) або адреса вручну: те, що написано
//  в «Слові» → Параметри → Remote API. PIN — якщо його там задано.
// =============================================================================

using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;

namespace Propovidnyk.Views;

public sealed class ConnectWindow : Window
{
    readonly Settings _settings;
    readonly ListBox _found;
    readonly TextBox _host, _port, _pin;
    readonly TextBlock _status;
    readonly Button _search, _check;

    public ConnectWindow(Settings settings)
    {
        _settings = settings;
        Title = Lang.T("Підключення до «Слова»", "Connection to Slovo");
        Width = 560;
        Height = 520;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _found = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<Found>((f, _) => new TextBlock { Text = f == null ? "" : $"{f.Name}  ·  {f.Host}:{f.Port}" }),
            MinHeight = 120,
        };
        _host = new TextBox { Text = settings.Host, Watermark = "192.168.1.20" };
        _port = new TextBox { Text = settings.Port.ToString(), Width = 90 };
        _pin = new TextBox { Text = settings.Pin, Width = 120, PasswordChar = '•', Watermark = Lang.T("якщо задано", "if set") };
        _found.SelectionChanged += (_, _) =>
        {
            if (_found.SelectedItem is not Found f) return;
            _host.Text = f.Host;
            _port.Text = f.Port.ToString();
            _settings.Name = f.Name;
        };
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Ui.Muted };
        _search = Ui.Button(Lang.T("Шукати в мережі", "Search the network"), async () => await Search(), accent: true);
        _check = Ui.Button(Lang.T("Перевірити й запам'ятати", "Check and remember"), async () => await Check());
        var close = Ui.Button(Lang.T("Готово", "Done"), Close);
        close.IsCancel = true;

        var form = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,8,*"), RowDefinitions = new RowDefinitions("Auto,6,Auto,6,Auto") };
        void Put(string caption, Control control, int row)
        {
            var label = Ui.Label(caption);
            Grid.SetRow(label, row);
            form.Children.Add(label);
            control.HorizontalAlignment = HorizontalAlignment.Left;
            Grid.SetRow(control, row);
            Grid.SetColumn(control, 2);
            form.Children.Add(control);
        }
        _host.MinWidth = 260;
        Put(Lang.T("Адреса комп'ютера", "Computer address"), _host, 0);
        Put(Lang.T("Порт", "Port"), _port, 2);
        Put("PIN", _pin, 4);

        var root = new StackPanel { Margin = new Thickness(16), Spacing = 10 };
        root.Children.Add(Ui.Hint(Lang.T(
            "Комп'ютер зі «Словом» і цей комп'ютер мають бути в одній мережі. У «Слові» пульт має бути ввімкнено: Параметри → Remote API (порт 8103).",
            "The computer running Slovo and this computer must be on the same network. The remote must be on in Slovo: Settings → Remote API (port 8103).")));
        root.Children.Add(_search);
        root.Children.Add(_found);
        root.Children.Add(Ui.Label(Lang.T("Або вручну:", "Or manually:"), 13, true));
        root.Children.Add(form);
        var buttons = Ui.Row(_check, close);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        root.Children.Add(buttons);
        root.Children.Add(_status);
        Content = new ScrollViewer { Content = root };
        Opened += async (_, _) => { if (!settings.HasHost) await Search(); };
    }

    async Task Search()
    {
        _search.IsEnabled = false;
        _status.Text = Lang.T("Шукаю «Слово» в мережі…", "Searching the network for Slovo…");
        try
        {
            var found = await Discovery.Search();
            _found.ItemsSource = found;
            _status.Text = found.Count == 0
                ? Lang.T("Ніхто не відповів. Перевірте, що «Слово» відкрите й пульт увімкнено, або введіть адресу вручну.",
                         "Nobody answered. Make sure Slovo is open and the remote is on, or enter the address manually.")
                : Lang.T("Виберіть «Слово» в списку — і «Перевірити й запам'ятати».", "Choose Slovo in the list — then “Check and remember”.");
            if (found.Count == 1) _found.SelectedIndex = 0;
        }
        catch (Exception error)
        {
            _status.Text = Api.Describe(error);
        }
        finally
        {
            _search.IsEnabled = true;
        }
    }

    async Task Check()
    {
        var host = (_host.Text ?? "").Trim();
        if (host.Length == 0) return;
        var port = int.TryParse(_port.Text, out var p) ? p : 8103;
        _check.IsEnabled = false;
        _status.Text = Lang.T("Перевіряю зв'язок зі «Словом»…", "Checking the connection to Slovo…");
        try
        {
            var state = await new Api(host, port, _pin.Text ?? "").State(0, CancellationToken.None);
            _settings.Host = host;
            _settings.Port = port;
            _settings.Pin = _pin.Text ?? "";
            if ((string?)state["name"] is { Length: > 0 } name) _settings.Name = name;
            _settings.Save();
            _status.Foreground = Ui.Good;
            _status.Text = Lang.F("● «Слово» на зв'язку: {0}. Запам'ятано.", "● Slovo is connected: {0}. Remembered.", _settings.Name.Length > 0 ? _settings.Name : host);
        }
        catch (Exception error)
        {
            _status.Foreground = Ui.Bad;
            _status.Text = Lang.F("Немає зв'язку: {0}", "No connection: {0}", Api.Describe(error));
        }
        finally
        {
            _check.IsEnabled = true;
        }
    }
}
