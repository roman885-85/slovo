// =============================================================================
//  MainWindow.Live.cs — стан програми, зал і команди
// =============================================================================
//  Стан «Слова» читається довгим опитом /api/state: програма тримає
//  відповідь, доки щось не зміниться, — тож вікно йде за програмою, а не
//  перепитує її щосекунди. Картинка залу — окремим кроком, бо вона важка.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed partial class MainWindow
{
    // MARK: Команди

    void Status(string text) => Dispatcher.UIThread.Post(() => _status.Text = text);

    async Task Run(Func<Task<JsonObject>> work)
    {
        try
        {
            await work();
            Status("");
        }
        catch (Exception error)
        {
            Status(Lang.F("Не вдалося: {0}", "Failed: {0}", Api.Describe(error)));
            Paths.Say("команда: " + error.Message);
        }
    }

    void Send(string name) => _ = Run(() => _api.Command(name));

    void Send(string name, int index)
    {
        _touched = DateTime.UtcNow;
        _ = Run(() => _api.Command(name, index));
    }

    void Send(string name, JsonObject body) => _ = Run(() => _api.Command(name, body, 15));

    void Send(string name, string text, bool byText) => _ = Run(() => _api.Command(name, text));

    void Move(int delta)
    {
        if (_sideHistory || _sideSelected < 0) return;
        Send("plan-move", new JsonObject { ["index"] = _sideSelected, ["delta"] = delta });
    }

    void Remove()
    {
        if (_sideSelected < 0) return;
        Send(_sideHistory ? "history-remove" : "plan-remove", _sideSelected);
    }

    // MARK: План та Історія

    void FillSide()
    {
        if (_side == null) return;
        _planTab.Background = _sideHistory ? Brushes.Transparent : Ui.AccentSoft;
        _historyTab.Background = _sideHistory ? Ui.AccentSoft : Brushes.Transparent;
        var sermon = _state["sermon"] as JsonObject;
        var on = (bool?)sermon?["on"] ?? false;
        _sermonEnd.IsVisible = on;
        _sideTitle.Text = _sideHistory
            ? Lang.T("Історія", "History")
            : on ? Lang.F("План проповіді: {0}", "Sermon plan: {0}", (string?)sermon?["title"] ?? "") : Lang.T("План служіння", "Service plan");

        List<SideRow> rows;
        if (_sideHistory)
        {
            rows = (_state["history"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select((r, i) => new SideRow(i, (string?)r["caption"] ?? "", "", (bool?)r["current"] ?? false)).ToList();
        }
        else
        {
            rows = (_state["plan"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select((r, i) => new SideRow(i, (string?)r["title"] ?? "", (string?)r["subtitle"] ?? "", (bool?)r["current"] ?? false)).ToList();
        }
        _fillingSide = true;
        _side.ItemsSource = rows;
        var current = rows.FindIndex(r => r.Current);
        _side.SelectedIndex = current >= 0 ? current : Math.Min(_sideSelected, rows.Count - 1);
        _fillingSide = false;
    }

    /// Історія приходить окремим запитом: у стані її немає.
    async Task LoadHistory()
    {
        if (!_online) return;
        try
        {
            var answer = await _api.Get("/api/history");
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _state["history"] = answer["records"]?.DeepClone();
                if (_sideHistory) FillSide();
            });
        }
        catch
        {
            // Історія — не привід писати про помилку в рядку стану.
        }
    }

    // MARK: Стан програми

    async Task Follow()
    {
        while (!_closing.IsCancellationRequested)
        {
            if (!_settings.HasHost)
            {
                await Dispatcher.UIThread.InvokeAsync(ShowConnection);
                try { await Task.Delay(1000, _closing.Token); } catch { return; }
                continue;
            }
            try
            {
                var state = await _api.State(_seq, _closing.Token);
                _seq = (long?)state["seq"] ?? _seq;
                var wasOffline = !_online;
                _online = true;
                _misses = 0;
                // Вкладку зібрано до того, як «Слово» озвалося: списки в ній
                // порожні, бо питати не було кого. Щойно зв'язок є —
                // збираємо її наново.
                if (wasOffline) await Dispatcher.UIThread.InvokeAsync(() => ShowTab(_tab));
                await Dispatcher.UIThread.InvokeAsync(() => Apply(state));
                await LoadHistory();
                await RefreshTab();
            }
            catch (OperationCanceledException) when (_closing.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error)
            {
                _online = false;
                _misses++;
                await Dispatcher.UIThread.InvokeAsync(() =>
                {
                    ShowConnection();
                    _status.Text = Lang.F("Немає зв'язку: {0}", "No connection: {0}", Api.Describe(error));
                });
                // Власник: «на короткое время иногда находит слово, но вскоре
                // связь пропадает и не подключается снова». Причина майже
                // завжди одна: записана адреса перестала бути дійсною —
                // комп'ютер отримав іншу від роутера або нас занесло на
                // адресу Parallels/VPN, якої з цієї машини не видно. Тому
                // після кількох невдач шукаємо «Слово» заново й самі
                // переходимо на ту адресу, яка відповідає.
                if (_misses >= 3) await Rediscover();
                try { await Task.Delay(2000, _closing.Token); } catch { return; }
            }
        }
    }

    /// Скільки разів поспіль не вийшло дочитатися до «Слова».
    int _misses;
    DateTime _searchedAt;

    /// Знайти «Слово» в мережі заново й перейти на адресу, яка відповідає.
    /// Шукаємо не частіше ніж раз на півхвилини: пошук стукає в усю підмережу.
    async Task Rediscover()
    {
        if ((DateTime.UtcNow - _searchedAt).TotalSeconds < 30) return;
        _searchedAt = DateTime.UtcNow;
        Status(Lang.T("Шукаю «Слово» в мережі…", "Looking for Slovo on the network…"));
        List<Found> found;
        try
        {
            found = await Discovery.Search(_closing.Token);
        }
        catch (Exception error)
        {
            Paths.Say("пошук наново: " + error.Message);
            return;
        }
        if (found.Count == 0) return;
        // Та сама машина, але інша адреса — беремо її мовчки; якщо в мережі
        // кілька «Слів», лишаємося на тому, яке звали раніше, за іменем.
        var pick = found.FirstOrDefault(one => one.Name == _settings.Name) ?? found[0];
        if (pick.Host == _settings.Host && pick.Port == _settings.Port) return;
        Paths.Say($"зв'язок: {_settings.Host}:{_settings.Port} не відповідає — переходжу на {pick.Host}:{pick.Port}");
        _settings.Host = pick.Host;
        _settings.Port = pick.Port;
        if (!string.IsNullOrEmpty(pick.Name)) _settings.Name = pick.Name;
        _settings.Save();
        _api = Api.From(_settings);
        _seq = 0;
        _misses = 0;
        Status(Lang.F("Знайшлося за адресою {0}", "Found at {0}", pick.Host));
    }

    void Apply(JsonObject state)
    {
        _state = state;
        ShowConnection();
        // Вкладка програми веде за собою вікно — як на планшеті.
        var mode = (string?)state["mode"] ?? "";
        if (mode.Length > 0 && mode != _tab && DateTime.UtcNow - _touched > TimeSpan.FromSeconds(2))
        {
            _tab = mode;
            ShowTab(mode);
        }
        MarkTabs();

        var slide = state["slide"] as JsonObject;
        var preview = state["preview"] as JsonObject;
        _liveReference.Text = (string?)slide?["reference"] ?? "";
        _liveText.Text = FirstLines((string?)slide?["text"] ?? "");
        _previewReference.Text = (string?)preview?["reference"] ?? "";
        _previewText.Text = FirstLines((string?)preview?["text"] ?? "");
        var live = (bool?)state["live"] ?? false;
        Accent(_showButton, live);
        Accent(_blackButton, (bool?)state["black"] ?? false);
        Accent(_blankButton, (bool?)state["blank"] ?? false);
        FillSide();
        FillSongParts();
        FillPages();
        if (state["media"] is JsonObject media) ApplyMedia(media);
    }

    static string FirstLines(string text)
    {
        var lines = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        return string.Join(" ", lines.Take(4));
    }

    /// Дочитати те, чого в стані немає: списки відкритої вкладки.
    async Task RefreshTab()
    {
        if (DateTime.UtcNow - _touched < TimeSpan.FromSeconds(1)) return;
        switch (_tab)
        {
            case "songs": await LoadSongs(); break;
            case "pictures": await LoadPictures(); break;
            case "media": await LoadMedia(); break;
            case "screen": await LoadScreen(); break;
            case "text": await LoadText(); break;
        }
    }

    // MARK: Зал

    async Task RefreshHallLoop()
    {
        var lastSeq = -1L;
        while (!_closing.IsCancellationRequested)
        {
            try
            {
                if (_online && (lastSeq != _seq || DateTime.UtcNow.Second % 5 == 0))
                {
                    lastSeq = _seq;
                    await RefreshHall();
                }
                await Task.Delay(1000, _closing.Token);
            }
            catch (OperationCanceledException) { return; }
            catch
            {
                try { await Task.Delay(2000, _closing.Token); } catch { return; }
            }
        }
    }

    async Task RefreshHall()
    {
        var hall = _state["hall"] as JsonObject;
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

    // MARK: Підключення, план, мова

    void ShowConnection()
    {
        if (_connection == null) return;
        if (!_settings.HasHost)
        {
            _connection.Text = Lang.T("«Слово» ще не вибрано — «Підключення…» вгорі", "Slovo is not chosen yet — “Connection…” at the top");
            _connection.Foreground = Ui.Muted;
            return;
        }
        var where = (_settings.Name.Length > 0 ? _settings.Name + " · " : "") + _settings.Host + ":" + _settings.Port;
        _connection.Text = (_online
            ? Lang.T("● «Слово» на зв'язку", "● Slovo is connected")
            : Lang.T("○ «Слово» не відповідає — перевірте мережу і програму на комп'ютері",
                     "○ Slovo is not responding — check the network and the program on the computer")) + "  (" + where + ")";
        _connection.Foreground = _online ? Ui.Good : Ui.Bad;
    }

    async void OpenConnection()
    {
        await new ConnectWindow(_settings).ShowDialog(this);
        _api = Api.From(_settings);
        _seq = 0;
        _online = false;
        ShowConnection();
    }

    async void OpenPlan()
    {
        var plan = new PlanWindow { Uploaded = () => { _sideHistory = false; FillSide(); } };
        await plan.ShowDialog(this);
        _seq = 0;
    }

    void ChangeLanguage(string code)
    {
        _settings.Language = code;
        _settings.Save();
        Lang.Choice = code;
        Build();
    }
}
