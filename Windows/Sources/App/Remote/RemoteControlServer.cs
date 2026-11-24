// =============================================================================
//  RemoteControlServer.cs — канал пульта (як RemoteControlServer на Mac)
// =============================================================================
//  Телефон, планшет «Проповідник» і браузер у тій самій мережі керують
//  показом. Маленький HTTP із JSON: клієнт питає стан довгим опитом (сервер
//  тримає відповідь до першої зміни, не довше 15 с) і шле команди. Шляхи,
//  імена полів і команди — ті самі, що в Mac 1.3.9, щоб клієнти працювали з
//  Windows-«Словом» без змін.
//
//  Знайти програму можна двома шляхами: крик у мережу (UDP 8104, «SLOVO?») і
//  mDNS (ім'я slovo.local і служба _slovo._tcp). Два слухачі: порт телефона
//  (8103, PIN) і порт браузера (8105 і, якщо вільний, 80; свій пароль, «лише
//  перегляд»). Розбір запиту — у фоні, робота зі станом — лише в головному потоці.
// =============================================================================

using System.Text;
using System.Text.Json.Nodes;
using Avalonia.Threading;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class RemoteControlServer
{
    public static readonly RemoteControlServer Shared = new();

    /// Перевірки: свої порти замість 8103/8105 і без порту 80 (ключі --remote-port, --web-port).
    public static int? PortOverride, WebPortOverride;
    public static bool NoPlainPort;
    /// Без крику в мережу й без імені slovo.local — щоб не перебити справжнє «Слово» поруч.
    public static bool Quiet;

    AppState? _state;
    string _pin = "";
    int _wantedPort = 8103;
    bool _enabled;
    HttpServer? _phone, _web, _plain;
    readonly Beacon _beacon;
    readonly Mdns _mdns = new();
    bool _webEnabled;
    int _wantedWebPort = 8105;
    string _webPassword = "";
    string _webName = "slovo";
    bool _webViewOnly;
    bool _webNoPort = true;

    /// Номер стану: росте на кожну зміну, телефон за ним чекає.
    public int Seq { get; private set; } = 1;
    /// Номер картинки залу: росте на кожну зміну, крім руху указки.
    public int HallSeq { get; private set; } = 1;
    string _fingerprint = "", _hallFingerprint = "";
    public int RequestCount { get; private set; }
    public int BeaconCount => _beacon.Answered;
    readonly List<Waiter> _waiters = new();
    readonly Dictionary<string, DateTime> _clientsSeen = new();
    bool _subscribed, _checkScheduled;
    public event Action? StatusChanged;

    sealed record Waiter(HttpConnection Connection, bool Web, DispatcherTimer Timeout);

    RemoteControlServer() { _beacon = new Beacon(() => Port); }

    public bool IsRunning => _phone?.IsRunning == true;
    public int Port => _phone?.IsRunning == true ? _phone.Port : 0;
    public string? LastError { get; private set; }
    public bool WebRunning => _web?.IsRunning == true;
    public int WebPort => _web?.IsRunning == true ? _web.Port : 0;
    public string? WebError { get; private set; }
    public bool WebViewOnly => _webViewOnly;
    public bool WebHasPassword => _webPassword.Length > 0;
    public bool WebNoPort => _webNoPort;
    public bool PlainReady => _plain?.IsRunning == true;
    public string? PlainError { get; private set; }
    public string? MdnsName => _mdns.Name;
    public string WebName => _webName;

    static string ComputerName => Names.Computer;

    // --- Увімкнення --------------------------------------------------------------------

    /// Застосувати налаштування телефона: увімкнути, перезапустити на іншому порту чи зупинити.
    public void Apply(bool enabled, int port, string pin, AppState state)
    {
        _state = state;
        _pin = pin;
        port = PortOverride ?? port;
        _enabled = enabled;
        if (!enabled) { StopPhone(); Announce(); return; }
        if (IsRunning && port == _wantedPort) return;
        StopPhone();
        _wantedPort = port;
        Subscribe(state);
        _phone = new HttpServer(port, false, Handle);
        if (_phone.Start()) { LastError = null; Journal.Say($"пульт: слухаю порт {_phone.Port}"); }
        else { LastError = _phone.Error; Journal.Say($"пульт: слухач не піднявся — {_phone.Error}"); }
        if (!Quiet) _beacon.Start();
        Announce();
        UpdateWakefulness();
    }

    /// Увімкнути, перезапустити чи вимкнути сторінку для браузера.
    public void ApplyWeb(bool enabled, int port, string password, string name, bool viewOnly, bool noPort = true)
    {
        port = WebPortOverride ?? port;
        if (NoPlainPort) noPort = false;
        _webPassword = password;
        _webViewOnly = viewOnly;
        var clean = Names.Clean(name);
        var unchanged = enabled == _webEnabled && port == _wantedWebPort && clean == _webName && noPort == _webNoPort && (_web != null) == enabled;
        _webEnabled = enabled;
        _wantedWebPort = port;
        _webName = clean;
        _webNoPort = noPort;
        if (unchanged) { NoteChange(); return; }
        StopWeb();
        if (enabled) StartWeb();
        Announce();
    }

    void StartWeb()
    {
        if (_state is not { } state) return;
        Subscribe(state);
        if (_wantedWebPort == _wantedPort && IsRunning)
        {
            WebError = Captions.T("этот порт уже занят пультом телефона — выберите другой");
            StatusChanged?.Invoke();
            return;
        }
        _web = new HttpServer(_wantedWebPort, true, Handle);
        if (_web.Start())
        {
            WebError = null;
            Journal.Say($"пульт у браузері: порт {_web.Port}");
            if (_webNoPort && _wantedWebPort != 80 && _wantedPort != 80)
            {
                _plain = new HttpServer(80, true, Handle);
                if (_plain.Start()) { PlainError = null; Journal.Say("пульт у браузері: і без номера порту — порт 80"); }
                else { PlainError = Captions.T("порт 80 занят — адрес с номером порта"); Journal.Say($"пульт у браузері: порт 80 — {_plain.Error}"); _plain = null; }
            }
        }
        else
        {
            WebError = _web.Error;
            Journal.Say($"пульт у браузері: слухач не піднявся — {_web.Error}");
            _web = null;
        }
        UpdateWakefulness();
        StatusChanged?.Invoke();
    }

    /// Ім'я в мережі (mDNS): slovo.local і служба _slovo._tcp — поки слухає хоч один канал.
    void Announce()
    {
        _mdns.Stop();
        if (!Quiet && (IsRunning || WebRunning)) _mdns.Start(_webName, IsRunning ? Port : WebPort);
        StatusChanged?.Invoke();
    }

    void StopPhone()
    {
        _phone?.Stop();
        _phone = null;
        _beacon.Stop();
        foreach (var waiter in _waiters.Where(w => !w.Web).ToList()) { waiter.Timeout.Stop(); waiter.Connection.Close(); _waiters.Remove(waiter); }
        UpdateWakefulness();
    }

    void StopWeb()
    {
        _plain?.Stop();
        _plain = null;
        PlainError = null;
        _web?.Stop();
        _web = null;
        WebError = null;
        foreach (var waiter in _waiters.Where(w => w.Web).ToList()) { waiter.Timeout.Stop(); waiter.Connection.Close(); _waiters.Remove(waiter); }
        UpdateWakefulness();
    }

    public void Stop()
    {
        StopPhone();
        StopWeb();
        _mdns.Stop();
        StatusChanged?.Invoke();
    }

    void UpdateWakefulness() => RemoteWakefulness.Shared.Listening(IsRunning || WebRunning);

    /// Журнал: хто на зв'язку і після якої тиші повернувся.
    void NoteClient(HttpRequest request)
    {
        if (request.Remote is not { } remote) return;
        var address = remote.ToString();
        var now = DateTime.Now;
        if (_clientsSeen.TryGetValue(address, out var last))
        {
            var quiet = (now - last).TotalSeconds;
            if (quiet > 90) Journal.Say($"пульт: {address} знову на зв'язку після {(int)quiet} с тиші");
        }
        else Journal.Say($"пульт: на зв'язку {address} — {(request.Web ? "браузер" : "телефон чи планшет")}");
        _clientsSeen[address] = now;
    }

    // --- Стан і довгий опит ------------------------------------------------------------

    /// Стежити за станом: будь-яка зміна піднімає номер і будить телефони, що чекають.
    void Subscribe(AppState state)
    {
        if (_subscribed) return;
        _subscribed = true;
        Signals.Shared.Subscribe(new[] { Signals.Kind.Slide, Signals.Kind.Mode, Signals.Kind.Live, Signals.Kind.Plan, Signals.Kind.History,
                                         Signals.Kind.SongSelection, Signals.Kind.SongPart, Signals.Kind.VerseSelection, Signals.Kind.Translations,
                                         Signals.Kind.SongBook, Signals.Kind.SearchResults }, _ => ScheduleCheck());
        state.LiveChanged += ScheduleCheck;
        state.SlideChanged += ScheduleCheck;
        TextModuleModel.Shared.Changed += ScheduleCheck;
        SlideFocus.Shared.Changed += ScheduleCheck;
        // Указка теж будить телефони, але не частіше ~12 разів на секунду.
        SlidePointer.Shared.Changed += PointerChanged;
    }

    DateTime _pointerWakeAt = DateTime.MinValue;
    bool _pointerWakePending;

    /// Пляма посунулась: підняти номер із проріджуванням і «хвостовим» викликом,
    /// щоб останнє положення й «прибрано» дійшли завжди.
    void PointerChanged()
    {
        var gap = (DateTime.Now - _pointerWakeAt).TotalSeconds;
        if (gap >= 0.08) { _pointerWakeAt = DateTime.Now; ScheduleCheck(); return; }
        if (_pointerWakePending) return;
        _pointerWakePending = true;
        DispatcherTimer.RunOnce(() => { _pointerWakePending = false; _pointerWakeAt = DateTime.Now; ScheduleCheck(); }, TimeSpan.FromSeconds(0.08 - gap));
    }

    /// Значення ще не всі записані, коли приходить зміна: звіряємо наприкінці поточного обороту.
    public void ScheduleCheck()
    {
        if (_checkScheduled || (!IsRunning && !WebRunning && _waiters.Count == 0)) return;
        _checkScheduled = true;
        Dispatcher.UIThread.Post(() => { _checkScheduled = false; NoteChange(); }, DispatcherPriority.Background);
    }

    /// Звірити відбиток стану: інший — підняти номер і відповісти тим, хто чекає.
    public void NoteChange()
    {
        if (!IsRunning && !WebRunning && _waiters.Count == 0) return;
        JsonObject snapshot;
        try { snapshot = StateJson(false); }
        catch (Exception error) { Journal.Say($"пульт: стан не зібрався — {error.Message}"); return; }
        snapshot.Remove("seq");
        snapshot.Remove("hallSeq");
        var text = snapshot.ToJsonString();
        if (text == _fingerprint) return;
        _fingerprint = text;
        Seq++;
        // Картинка залу — те саме, крім указки.
        snapshot.Remove("pointer");
        var hall = snapshot.ToJsonString();
        if (hall != _hallFingerprint) { _hallFingerprint = hall; HallSeq++; }
        var waiting = _waiters.ToList();
        _waiters.Clear();
        foreach (var waiter in waiting)
        {
            waiter.Timeout.Stop();
            Respond(waiter.Connection, 200, StateJson(waiter.Web));
        }
    }

    // --- Відповіді ---------------------------------------------------------------------

    static void Respond(HttpConnection connection, int status, JsonObject json) => _ = connection.RespondJson(status, json.ToJsonString());
    static void Fail(HttpConnection connection, int status, string error) => Respond(connection, status, new JsonObject { ["error"] = error });
    static void RespondData(HttpConnection connection, int status, byte[] body, string contentType, Dictionary<string, string>? headers = null) =>
        _ = connection.Respond(status, contentType, body, headers);

    // --- Розбір запитів ----------------------------------------------------------------

    /// Запит прийшов у фоні — розбираємо в головному потоці, де живе стан.
    Task Handle(HttpRequest request, HttpConnection connection)
    {
        Dispatcher.UIThread.Post(() =>
        {
            try { HandleOnUi(request, connection); }
            catch (Exception error)
            {
                Journal.Say($"пульт: {request.Method} {request.Path} — {error.Message}");
                Fail(connection, 400, error.Message);
            }
        });
        return Task.CompletedTask;
    }

    void HandleOnUi(HttpRequest request, HttpConnection connection)
    {
        RequestCount++;
        RemoteWakefulness.Shared.Request();
        NoteClient(request);
        if (_state is not { } state) { Fail(connection, 400, Captions.T("нет состояния")); return; }
        // Сторінка й програми для Android — лише на порту браузера і до пароля: секретів у них немає.
        if (request.Web && request.Method == "GET")
        {
            if (request.Path is "/" or "/index.html") { RespondData(connection, 200, Encoding.UTF8.GetBytes(WebPage.Html), "text/html; charset=utf-8"); return; }
            if (request.Path == "/api/apps") { Respond(connection, 200, AndroidAppsJson()); return; }
            if (request.Path.StartsWith("/download/")) { ServeAndroidApp(request.Path, connection); return; }
        }
        // Пароль — свій у кожного каналу: PIN телефона і пароль браузера.
        var secret = request.Web ? _webPassword : _pin;
        if (secret.Length > 0)
        {
            var given = request.Headers.TryGetValue("x-slovo-pin", out var header) ? header : request.Q("pin");
            if (given != secret) { Fail(connection, 401, "pin"); return; }
        }
        // «Лише перегляд»: сторінка бачить зал, але нічого не змінює.
        if (request.Web && _webViewOnly && request.Method != "GET")
        {
            Fail(connection, 403, Captions.T("только просмотр — управление выключено в Параметры → Remote API"));
            return;
        }
        if (request.Method == "GET" && request.Path == "/api/state")
        {
            var since = request.QInt("since") ?? -1;
            var web = request.Web;
            if (since < Seq) { Respond(connection, 200, StateJson(web)); return; }
            // Довгий опит: відповідь піде з першою зміною або за 15 с (телефон чекає 40).
            var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            var waiter = new Waiter(connection, web, timeout);
            timeout.Tick += (_, _) =>
            {
                timeout.Stop();
                if (!_waiters.Remove(waiter)) return;
                Respond(connection, 200, StateJson(web));
            };
            _waiters.Add(waiter);
            timeout.Start();
            return;
        }
        // Картинка сторінки показу — телефон малює її і водить по ній указкою.
        if (request.Method == "GET" && request.Path == "/api/page")
        {
            var show = request.Q("kind") == "pictures" ? ShowWorkspace.Pictures.Model : ShowWorkspace.Presentation.Model;
            var index = request.QInt("index") ?? show.Index ?? -1;
            var width = Math.Min(1600, Math.Max(160, request.QInt("w") ?? 720));
            if (index < 0 || index >= show.Count || show.Image(index) is not { } image || Jpeg(image, width) is not { } jpeg)
            {
                Fail(connection, 404, Captions.T("нет такой страницы"));
                return;
            }
            RespondData(connection, 200, jpeg, "image/jpeg");
            return;
        }
        // Біблія для телефона: переклади, книги, глави й вірші.
        if (request.Method == "GET" && request.Path == "/api/bible/books") { Respond(connection, 200, BibleBooksJson(state)); return; }
        if (request.Method == "GET" && request.Path == "/api/bible/chapter") { AnswerChapter(request, state, connection); return; }
        // Планшет: плеєр, картинки, екран, текст, Історія, пошук, зал.
        if (request.Method == "GET" && TabletGet(request, state, connection)) return;
        // Ресурси, фонограма, бібліотека для плану проповіді.
        if (request.Method == "GET" && ResourcesGet(request, state, connection)) return;
        if (request.Method == "GET" && BackingGet(request, state, connection)) return;
        if (request.Method == "GET" && LibraryGet(request, state, connection)) return;
        if (request.Method != "POST" || !request.Path.StartsWith("/api/"))
        {
            Fail(connection, 404, Captions.T("нет такого пути"));
            return;
        }
        Command(request, state, connection);
    }

    /// Тіло команди — JSON-об'єкт; завантаження файлів шлють байти, не JSON.
    static JsonObject Body(HttpRequest request)
    {
        if (request.Body.Length == 0) return new JsonObject();
        try { return JsonNode.Parse(Encoding.UTF8.GetString(request.Body)) as JsonObject ?? new JsonObject(); }
        catch { return new JsonObject(); }
    }

    static int? Int(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<int>(out var i)) return i;
        if (value.TryGetValue<double>(out var d)) return (int)d;
        if (value.TryGetValue<long>(out var l)) return (int)l;
        if (value.TryGetValue<string>(out var s) && int.TryParse(s.Trim(), out var parsed)) return parsed;
        return null;
    }

    static double? Number(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<double>(out var d)) return d;
        if (value.TryGetValue<int>(out var i)) return i;
        if (value.TryGetValue<long>(out var l)) return l;
        if (value.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed)) return parsed;
        return null;
    }

    static bool? Flag(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<bool>(out var b)) return b;
        if (Number(node) is { } n) return n != 0;
        return null;
    }

    static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var s) ? s : null;

    static void Focus(AppState state, WorkMode mode)
    {
        if (state.Mode == mode) return;
        state.Mode = mode;
        Signals.Shared.Send(Signals.Kind.Mode);
    }

    static SongsWorkspace? Songs => MainWindow.Shared?.Songs;

    void Command(HttpRequest request, AppState state, HttpConnection connection)
    {
        var command = request.Path["/api/".Length..];
        var body = command is "upload" or "module-import" ? new JsonObject() : Body(request);
        var index = Int(body["index"]);
        var text = Text(body["text"]) ?? "";
        Journal.Say($"пульт: команда {command}{(index is { } i ? $" {i}" : "")}{(text.Length == 0 ? "" : $" «{text}»")}");
        var answer = new JsonObject { ["ok"] = true };
        switch (command)
        {
            case "next":
                if (!ShowFromPhone(Text(body["tab"]), 1, state)) Step(1, state);
                break;
            case "prev":
                if (!ShowFromPhone(Text(body["tab"]), -1, state)) Step(-1, state);
                break;
            case "show":
                if (!ShowFromPhone(Text(body["tab"]), 0, state)) state.ShowCurrentSlide();
                break;
            case "hide": state.HideSlide(); break;
            case "black": state.ShowBlackScreen(); break;
            case "blank": state.ShowBlankSlide(); break;
            case "next-chapter": state.StepChapter(1, false); break;
            case "prev-chapter": state.StepChapter(-1, false); break;
            case "backing-drag":
            {
                // Посунути межу панелі фонограм — те саме, що робить рука; steps — дрібними
                // рухами, як рука (саме на дрібних губилися зсуви, поки висота «прилипала»).
                var delta = Number(body["delta"]) ?? 80;
                var steps = Math.Max(1, Math.Min(60, Int(body["steps"]) ?? 1));
                var root = MainWindow.Shared?.Songs?.View as SongsRootView;
                if (steps > 1) root?.BeginBackingDrag();
                for (var step = 0; step < steps; step++) root?.ResizeBacking(delta / steps);
                if (steps > 1) root?.EndBackingDrag();
                answer["delta"] = delta;
                answer["steps"] = steps;
                if (root != null) answer["height"] = root.BackingTarget;
                break;
            }
            case "window-snapshot":
                WindowSnapshot(state, answer);
                break;
            case "window-open":
                if (!OpenWindowForCheck(text)) { Fail(connection, 400, Captions.T("нет такого окна")); return; }
                break;
            case var name when name.StartsWith("backing-"):
                if (BackingCommand(name, body, index, text, state, answer) is { } trouble)
                {
                    if (trouble.Length > 0) { Fail(connection, 400, trouble); return; }
                    break;
                }
                Fail(connection, 404, Captions.T("нет такой команды")); return;
            case "resource-install":
                if (StartResourceInstall(body, state, answer) is { } declined) { Fail(connection, 400, declined); return; }
                break;
            case "plan":
            {
                var items = state.Plan.Items;
                if (index is not { } at || at < 0 || at >= items.Count) { Fail(connection, 404, Captions.T("нет такого пункта")); return; }
                state.ActivatePlanItem(items[at]);
                break;
            }
            case "part":
            {
                if (index is not { } part || Songs?.Model.SongIndex is not { } song) { Fail(connection, 404, Captions.T("песня не выбрана")); return; }
                Focus(state, WorkMode.Songs);
                Songs!.Reveal(song, part, true);
                break;
            }
            case "song":
                if (index is not { } songIndex) { Fail(connection, 400, "нужен index"); return; }
                Focus(state, WorkMode.Songs);
                Songs?.Reveal(songIndex, null, false);
                break;
            case "page":
            {
                // Сторінку гортають із телефона й тоді, коли програма на іншій вкладці.
                if (index is not { } page) { Fail(connection, 400, "нужен index"); return; }
                if (state.Mode is not (WorkMode.Pictures or WorkMode.Presentation)) Focus(state, WorkMode.Presentation);
                var workspace = state.Mode == WorkMode.Pictures ? ShowWorkspace.Pictures : ShowWorkspace.Presentation;
                workspace.SelectPage(page);
                workspace.ShowCurrentPage();
                break;
            }
            case "deck":
                if (index is not { } deck) { Fail(connection, 400, "нужен index"); return; }
                Focus(state, WorkMode.Presentation);
                ShowWorkspace.Presentation.SelectDeck(deck);
                break;
            case "pointer":
                if (Number(body["x"]) is { } x && Number(body["y"]) is { } y)
                {
                    // Колір «#RRGGBB», розмір і яскравість — з налаштувань пульта; старий пульт їх не шле.
                    var phone = new SlidePointer.PhoneLook(Text(body["colour"]) is { } hex ? SlidePointer.Look.ParseColour(hex) : null,
                                                           Number(body["size"]), Number(body["opacity"]));
                    var empty = phone.Colour == null && phone.Size == null && phone.Opacity == null;
                    SlidePointer.Shared.Move(x, y, SlidePointer.PhoneSource, empty ? null : phone);
                }
                else SlidePointer.Shared.Hide(SlidePointer.PhoneSource);
                break;
            case "pointer-off":
                SlidePointer.Shared.Hide(SlidePointer.PhoneSource);
                break;
            case "zoom":
            {
                // Наближення з телефона: палець показує, куди дивитися; нуль знімає наближення.
                var focus = SlideFocus.Shared;
                var zoom = Number(body["zoom"]) ?? 0;
                if (zoom <= SlideFocus.MinZoom + 0.001) focus.Reset();
                else if (Number(body["x"]) is { } zx && Number(body["y"]) is { } zy)
                {
                    focus.ZoomTo(zoom, zx, zy);
                    if (!focus.IsOn) focus.SetOn(true);
                }
                else
                {
                    if (!focus.IsOn) focus.SetOn(true);
                    focus.SetZoom(zoom);
                }
                answer["zoom"] = focus.IsOn ? focus.Current.Zoom : 1;
                break;
            }
            case "upload":
            {
                var (result, refusal) = SaveUpload(request, state);
                if (refusal != null) { Fail(connection, 400, refusal); return; }
                foreach (var (key, value) in result!) answer[key] = value?.DeepClone();
                break;
            }
            case "sermon-plan":
                WhenLibraryReady(state, 0, () =>
                {
                    Respond(connection, 200, AcceptSermonPlan(body, state));
                    NoteChange();
                });
                return;
            case "sermon-end":
                state.EndSermon();
                break;
            case "module-import":
                ImportModule(request, state, connection);
                return;
            case "goto":
            {
                Focus(state, WorkMode.Bible);
                // Показ — коли глави справді прочитано, інакше в зал іде вірш попередньої книги.
                if (!state.ApplyAddress(text, () => { state.ShowCurrentSlide(); NoteChange(); }))
                {
                    Fail(connection, 404, Captions.T("адрес не найден"));
                    return;
                }
                break;
            }
            case "bible-select":
            {
                // Книга — позицією у списку книг, глава, вірші; live — одразу в зал.
                var position = Int(body["book"]) ?? state.SelectedBookIndex;
                var chapter = Int(body["chapter"]) ?? state.SelectedChapterNumber;
                var verses = body["verses"] is JsonArray list ? list.Select(Int).OfType<int>().ToList() : new List<int>();
                var live = Flag(body["live"]) ?? false;
                if (position < 0 || position >= state.Books.Count) { Fail(connection, 404, Captions.T("нет такой книги")); return; }
                Focus(state, WorkMode.Bible);
                state.OpenScripture(position, chapter, available => verses.Count == 0 ? available : verses.Where(available.Contains).ToList(), () =>
                {
                    if (live) state.ShowCurrentSlide();
                    NoteChange();
                });
                break;
            }
            case "bible-translation":
                if (state.Module(text) == null) { Fail(connection, 404, Captions.T("нет такого перевода")); return; }
                state.PrimaryModuleID = text;
                break;
            case "mode":
                if (!Enum.TryParse<WorkMode>(text, true, out var mode) || mode.ToString().ToLowerInvariant() != text)
                {
                    Fail(connection, 400, Captions.T("нет такой вкладки"));
                    return;
                }
                Focus(state, mode);
                break;
            case "songs":
                answer["songs"] = SearchSongs(text);
                break;
            default:
                switch (TabletCommand(command, body, index, text, state, answer))
                {
                    case (true, _, _): break;
                    case (false, 0, _): Fail(connection, 404, Captions.T("нет такой команды: %s", command)); return;
                    case (false, var code, var message): Fail(connection, code, message ?? ""); return;
                }
                break;
        }
        NoteChange();
        Respond(connection, 200, answer);
    }

    /// Телефон на вкладці «Показ»: «Показати», «Далі» й «Назад» стосуються показу, хоч би що
    /// стояло на комп'ютері. Якщо показ ще не на стіні, перше «Далі» повертає ту саму сторінку.
    bool ShowFromPhone(string? tab, int delta, AppState state)
    {
        if (tab != "show") return false;
        var wasShowing = state.Mode is WorkMode.Presentation or WorkMode.Pictures;
        var workspace = state.Mode == WorkMode.Pictures ? ShowWorkspace.Pictures : ShowWorkspace.Presentation;
        if (workspace.Model.IsEmpty) return false;
        if (!wasShowing) Focus(state, WorkMode.Presentation);
        if (workspace.Model.Index == null) workspace.SelectPage(workspace.Model.CurrentRange.Start);
        if (wasShowing && delta != 0 && state.StillShown) workspace.Step(delta, false);
        workspace.ShowCurrentPage();
        return true;
    }

    /// «Далі» й «Назад» — те саме, що стрілки, але завжди з показом у залі.
    void Step(int delta, AppState state)
    {
        if (ShowWorkspace.For(state.Mode) is { } show) { show.Step(delta, true); return; }
        switch (state.Mode)
        {
            case WorkMode.Songs: state.StepSongPart(delta, true); break;
            case WorkMode.Bible: state.StepVerse(delta, true); break;
            default: return;
        }
        // Показ сховали на комп'ютері — з телефона цього не видно, а «Далі» тиснуть, щоб вірш з'явився.
        if (!state.IsLive) state.ShowCurrentSlide();
    }

    /// Книги відкритого перекладу — телефону, щоб вибирати, а не набирати.
    static JsonObject BibleBooksJson(AppState state)
    {
        var books = new JsonArray(state.Books.Select((book, position) => (JsonNode)new JsonObject
        {
            ["position"] = position, ["name"] = book.FullName, ["short"] = book.ButtonTitle,
            ["chapters"] = book.ChapterCount, ["testament"] = Testament(book),
        }).ToArray());
        return new JsonObject
        {
            ["translation"] = new JsonObject { ["id"] = state.PrimaryModuleID, ["name"] = state.PrimaryModule?.DisplayName ?? "" },
            ["translations"] = new JsonArray(state.AllModules.Select(m => (JsonNode)new JsonObject { ["id"] = m.Identifier, ["name"] = m.DisplayName }).ToArray()),
            ["current"] = new JsonObject
            {
                ["book"] = state.SelectedBookIndex, ["chapter"] = state.SelectedChapterNumber,
                ["verses"] = new JsonArray(state.SelectedVerseNumbers.Select(n => (JsonNode)n).ToArray()),
            },
            ["books"] = books,
        };
    }

    /// Старий, Новий чи інше — за наскрізним номером канону (Малахія — 460, Об'явлення — 730).
    static string Testament(BookInfo book) => book.CanonicalNumber is not { } number ? "other" : number <= 460 ? "old" : number <= 730 ? "new" : "other";

    /// Вірші глави; книгу, якої ще немає в пам'яті, читаємо у фоні.
    static void AnswerChapter(HttpRequest request, AppState state, HttpConnection connection)
    {
        var position = request.QInt("book") ?? state.SelectedBookIndex;
        var number = request.QInt("chapter") ?? state.SelectedChapterNumber;
        if (state.PrimaryModule is not { } module || position < 0 || position >= state.Books.Count)
        {
            Fail(connection, 404, Captions.T("нет такой книги"));
            return;
        }
        var book = state.Books[position];
        void Reply(IReadOnlyList<Chapter> chapters)
        {
            if (chapters.FirstOrDefault(c => c.Number == number) is not { } chapter) { Fail(connection, 404, Captions.T("нет такой главы")); return; }
            Respond(connection, 200, new JsonObject
            {
                ["book"] = position, ["name"] = book.FullName, ["chapter"] = number, ["chapters"] = book.ChapterCount,
                ["verses"] = new JsonArray(chapter.Verses.Select(v => (JsonNode)new JsonObject { ["number"] = v.Number, ["text"] = v.Text }).ToArray()),
            });
        }
        if (module.CachedChapters(book) is { } ready) { Reply(ready); return; }
        Task.Run(() =>
        {
            IReadOnlyList<Chapter> parsed;
            try { parsed = module.Chapters(book); } catch { parsed = Array.Empty<Chapter>(); }
            Dispatcher.UIThread.Post(() => Reply(parsed));
        });
    }

    /// Пісні за словом з назви — для вкладки «Пошук» на телефоні.
    static JsonArray SearchSongs(string query)
    {
        var trimmed = query.Trim();
        var needle = SongFold.Fold(trimmed);
        var found = new JsonArray();
        if (needle.Length == 0 || Songs?.Model.Book?.Songs is not { } songs) return found;
        foreach (var song in songs)
        {
            if (!SongFold.Contains(SongFold.Fold(song.Title), needle) && !SongFold.Contains(SongFold.Fold(song.AlternateTitle), needle)
                && (song.Index + 1).ToString() != trimmed) continue;
            found.Add(new JsonObject { ["index"] = song.Index, ["title"] = $"{song.Index + 1}. {song.Title}", ["subtitle"] = song.Subtitle ?? "" });
            if (found.Count >= 60) break;
        }
        return found;
    }

    // --- Картинки й файли з телефона ---------------------------------------------------

    /// Сторінка показу в JPEG потрібної ширини.
    public static byte[]? Jpeg(SKImage image, int width)
    {
        try
        {
            var scale = (double)width / Math.Max(1, image.Width);
            SKImage source = image;
            SKImage? small = null;
            if (scale < 1)
            {
                var height = Math.Max(1, (int)Math.Round(image.Height * scale));
                using var surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul));
                using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium };
                surface.Canvas.DrawImage(image, SKRect.Create(width, height), paint);
                small = surface.Snapshot();
                source = small;
            }
            using var data = source.Encode(SKEncodedImageFormat.Jpeg, 80);
            small?.Dispose();
            return data?.ToArray();
        }
        catch { return null; }
    }

    /// Куди складаються файли, надіслані з телефона.
    public static string UploadsFolder => Path.Combine(DataHome.Folder, "Пульт");

    /// Файл із телефона: зберегти й відкрити в показі — презентацію в «Презентацію», картинку в «Зображення».
    (JsonObject? Result, string? Refusal) SaveUpload(HttpRequest request, AppState state)
    {
        var rawName = request.Q("name").Split('/').LastOrDefault() ?? "";
        var name = rawName.Split('\\').Last().Replace(":", "-").Trim();
        if (name.Length == 0 || name == "..") return (null, Captions.T("нет имени файла (name=)"));
        if (request.Body.Length == 0) return (null, "пустой файл");
        // Файл плану проповіді — лише зберегти: відкриє його пункт «Файл».
        if (request.Q("store") == "1") return StoreUpload(name, request.Body, state);
        var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        ShowModel.Kind kind;
        if (ShowModel.Extensions(ShowModel.Kind.Presentation).Contains(ext)) kind = ShowModel.Kind.Presentation;
        else if (ShowModel.Extensions(ShowModel.Kind.Pictures).Contains(ext)) kind = ShowModel.Kind.Pictures;
        else return (null, Captions.T("такой файл показ не открывает: .%s", ext));
        try
        {
            Directory.CreateDirectory(UploadsFolder);
            var path = Path.Combine(UploadsFolder, name);
            File.WriteAllBytes(path, request.Body);
            var workspace = kind == ShowModel.Kind.Pictures ? ShowWorkspace.Pictures : ShowWorkspace.Presentation;
            var before = workspace.Model.Count;
            workspace.Open(new[] { path });
            Focus(state, kind == ShowModel.Kind.Pictures ? WorkMode.Pictures : WorkMode.Presentation);
            if (kind == ShowModel.Kind.Presentation && workspace.Model.Decks.Count > 0) workspace.SelectDeck(workspace.Model.Decks.Count - 1);
            else if (kind == ShowModel.Kind.Pictures && workspace.Model.Count > before) workspace.SelectPage(before);
            if (workspace.Model.Problem is { } problem && workspace.Model.Count == before) return (null, problem);
            // Фото з телефона — одразу в зал: його вибрали саме для показу.
            if (kind == ShowModel.Kind.Pictures && request.Q("show") == "1" && workspace.Model.Count > before) workspace.ShowCurrentPage();
            Journal.Say($"пульт: прийнято файл «{name}» ({request.Body.Length} байт), сторінок {workspace.Model.Count - before}");
            return (new JsonObject
            {
                ["name"] = name, ["pages"] = workspace.Model.Count - before, ["deck"] = workspace.Model.CurrentDeck ?? -1,
                ["page"] = kind == ShowModel.Kind.Pictures && workspace.Model.Count > before ? before : -1,
            }, null);
        }
        catch (Exception error) { return (null, error.Message); }
    }

    // --- Службове: знімки й вікна для перевірок ----------------------------------------

    /// Знімок вікна програми й кадру залу у файли — бачити те саме, що людина,
    /// коли зняти екран не дає система (віддалений вхід, ВМ).
    static void WindowSnapshot(AppState state, JsonObject answer)
    {
        var folder = Path.Combine(DataHome.Folder, "ScreenShots");
        Directory.CreateDirectory(folder);
        try
        {
            if (MainWindow.Shared is { } window)
            {
                var size = new Avalonia.PixelSize((int)Math.Max(1, window.Bounds.Width), (int)Math.Max(1, window.Bounds.Height));
                using var bitmap = new Avalonia.Media.Imaging.RenderTargetBitmap(size);
                bitmap.Render(window);
                var file = Path.Combine(folder, "slovo-вікно-на-вимогу.png");
                bitmap.Save(file);
                answer["snapshot"] = file;
            }
            else answer["snapshot"] = "";
        }
        catch (Exception error) { answer["snapshot"] = ""; answer["snapshotError"] = error.Message; }
        try
        {
            var (width, height) = ProjectionController.Shared.FrameSize();
            if (MainWindow.Shared?.Output?.HallFrame(width, height) is { } hall)
            {
                using (hall)
                using (var png = hall.Encode(SKEncodedImageFormat.Png, 100))
                {
                    var file = Path.Combine(folder, "slovo-зал.png");
                    using var stream = File.Create(file);
                    png.SaveTo(stream);
                    answer["зал"] = file;
                }
            }
        }
        catch (Exception error) { answer["залError"] = error.Message; }
        // Кадр плеєра чи захопленого екрана — як він лежить у спільних буферах (перевірка «Екрана» й відео).
        try
        {
            if (VideoFrames.Shared.Latest is { } frame)
            {
                var file = Path.Combine(folder, "slovo-кадр-плеєра.png");
                using var image = SkiaSharp.SKImage.FromBitmap(frame);
                using var data = image.Encode(SkiaSharp.SKEncodedImageFormat.Png, 90);
                using (var stream = File.Create(file)) data.SaveTo(stream);
                answer["кадр"] = file;
                answer["кадрРозмір"] = $"{frame.Width}×{frame.Height}";
            }
        }
        catch (Exception error) { answer["кадрError"] = error.Message; }
    }

    /// Відкрити вікно для знімка перевірки: settings[:N], web-editor, localize, numbering, close.
    static bool OpenWindowForCheck(string what)
    {
        var name = what.Split(':')[0];
        switch (name)
        {
            case "web-editor": WebSlideEditorWindow.Open(AppState.Shared); return true;
            case "localize": LocalizeWindow.Open(AppState.Shared); return true;
            case "numbering": NumberingEditorWindow.Open(AppState.Shared); return true;
            case "settings":
            {
                var window = new SettingsWindow();
                window.BuildTabs(SettingsStore.Shared);
                if (what.Contains(':') && int.TryParse(what.Split(':')[1], out var tab)) window.Tabs.SelectedIndex = tab;
                if (MainWindow.Shared is { } owner) window.Show(owner); else window.Show();
                return true;
            }
            case "close":
                foreach (var window in (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Windows.ToList() ?? new())
                    if (window != MainWindow.Shared && window is SettingsWindow or WebSlideEditorWindow or LocalizeWindow or NumberingEditorWindow) window.Close();
                return true;
            default:
                return false;
        }
    }
}
