// =============================================================================
//  RemoteServer.cs — канал пульта: телефон, планшет, «Проповідник», браузер
// =============================================================================
//  Той самий протокол, що в «Слова» на Mac (RemoteControlServer.swift і його
//  розширення Tablet/Sermon/Android): маленький HTTP із JSON, де клієнт
//  спрашує стан довгим опитом і шле команди. Шляхи, імена полів і команди —
//  ті самі, щоб клієнти працювали з Windows-«Словом» без змін. Чого в
//  Windows-версії немає (плеєр, екран, презентації, фонограми, ресурси з
//  пульта), канал відповідає порожніми списками, а не помилкою.
//
//  Два слухачі: порт пульта (8103, PIN) і порт браузера (8105 + 80, пароль,
//  «лише перегляд»). Робота зі станом — лише на потоці стану (`Invoke`).
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo.Remote;

public sealed class RemoteServer
{
    readonly AppState _state;
    HttpServer? _phone, _web, _plain;
    readonly Beacon _beacon;
    readonly Mdns _mdns = new();
    readonly object _lock = new();
    readonly List<Waiter> _waiters = new();
    string _fingerprint = "";
    string _hallFingerprint = "";
    public int Seq { get; private set; } = 1;
    public int HallSeq { get; private set; } = 1;
    public int RequestCount { get; private set; }
    public event Action? StatusChanged;

    sealed record Waiter(HttpConnection Connection, bool Web, CancellationTokenSource Timeout);

    public bool IsRunning => _phone?.IsRunning == true;
    public int Port => _phone?.Port ?? 0;
    public string? Error => _phone?.Error;
    public bool WebRunning => _web?.IsRunning == true;
    public int WebPort => _web?.Port ?? 0;
    public string? WebError => _web?.Error;
    public bool PlainReady => _plain?.IsRunning == true;
    public string? MdnsName => _mdns.Name;
    public int BeaconAnswered => _beacon.Answered;

    public RemoteServer(AppState state)
    {
        _state = state;
        _beacon = new Beacon(() => Port);
        state.Changed += _ => ScheduleCheck();
    }

    int _checkScheduled;

    /// Значення ще не всі записані, коли приходить перша зміна: команда «Далі»
    /// міняє передпоказ, а зал — наступним кроком. Звіряємо відбиток після
    /// того, як поточна дія завершиться, — як `scheduleCheck` на Mac.
    void ScheduleCheck()
    {
        if (Interlocked.Exchange(ref _checkScheduled, 1) != 0) return;
        if (Avalonia.Application.Current != null)
            Avalonia.Threading.Dispatcher.UIThread.Post(() => { _checkScheduled = 0; NoteChange(); }, Avalonia.Threading.DispatcherPriority.Background);
        else
            ThreadPool.QueueUserWorkItem(_ => { _checkScheduled = 0; try { _state.Invoke(NoteChange).Wait(); } catch { /* стан уже закрито */ } });
    }

    /// Застосувати налаштування: підняти, перезапустити на іншому порту або зупинити.
    public void Apply()
    {
        var s = _state.Settings;
        Stop();
        if (s.RemoteEnabled)
        {
            _phone = new HttpServer(s.RemotePort, false, Handle);
            if (_phone.Start()) Paths.Say("пульт: слухаю порт " + _phone.Port);
            else Paths.Say("пульт: " + _phone.Error);
            _beacon.Start();
        }
        if (s.WebEnabled)
        {
            if (s.RemoteEnabled && s.WebPort == s.RemotePort)
            {
                Paths.Say("пульт у браузері: порт збігається з портом телефона");
            }
            else
            {
                _web = new HttpServer(s.WebPort, true, Handle);
                if (_web.Start()) Paths.Say("пульт у браузері: порт " + _web.Port);
                else Paths.Say("пульт у браузері: " + _web.Error);
                if (s.WebNoPort && s.WebPort != 80 && s.RemotePort != 80)
                {
                    _plain = new HttpServer(80, true, Handle);
                    if (_plain.Start()) Paths.Say("пульт у браузері: і без номера порту — порт 80");
                    else { Paths.Say("пульт у браузері: порт 80 — " + _plain.Error); _plain = null; }
                }
            }
        }
        if (s.RemoteEnabled || s.WebEnabled) _mdns.Start(s.WebName, s.RemoteEnabled ? (_phone?.Port ?? s.RemotePort) : (_web?.Port ?? s.WebPort));
        StatusChanged?.Invoke();
    }

    public void Stop()
    {
        _phone?.Stop(); _phone = null;
        _web?.Stop(); _web = null;
        _plain?.Stop(); _plain = null;
        _beacon.Stop();
        _mdns.Stop();
        lock (_lock)
        {
            foreach (var waiter in _waiters) { waiter.Timeout.Cancel(); waiter.Connection.Close(); }
            _waiters.Clear();
        }
    }

    // MARK: Стан і довгий опит

    /// Будь-яка зміна стану — звірити відбиток і розбудити тих, хто чекає.
    void NoteChange()
    {
        if (!IsRunning && !WebRunning) return;
        JsonObject snapshot;
        try { snapshot = StateJson(false); } catch { return; }
        snapshot.Remove("seq");
        snapshot.Remove("hallSeq");
        var text = snapshot.ToJsonString();
        if (text == _fingerprint) return;
        _fingerprint = text;
        Seq++;
        snapshot.Remove("pointer");
        var hall = snapshot.ToJsonString();
        if (hall != _hallFingerprint) { _hallFingerprint = hall; HallSeq++; }
        List<Waiter> waiting;
        lock (_lock) { waiting = _waiters.ToList(); _waiters.Clear(); }
        foreach (var waiter in waiting)
        {
            waiter.Timeout.Cancel();
            _ = waiter.Connection.RespondJson(200, StateJson(waiter.Web).ToJsonString());
        }
    }

    JsonObject StateJson(bool web)
    {
        var s = _state;
        var json = new JsonObject
        {
            ["seq"] = Seq, ["hallSeq"] = HallSeq, ["app"] = "Slovo", ["name"] = Names.Computer,
            ["mode"] = s.Mode, ["live"] = s.IsLive, ["black"] = s.IsBlackout, ["blank"] = s.IsTextHidden,
            ["slide"] = new JsonObject { ["reference"] = s.LiveSlide.Reference, ["text"] = s.LiveSlide.MainText, ["secondary"] = new JsonArray(s.LiveSlide.SecondaryTexts.Select(t => (JsonNode)t).ToArray()) },
            ["preview"] = new JsonObject { ["reference"] = s.Slide.Reference, ["text"] = s.Slide.MainText },
        };
        if (s.CurrentBook is Book book)
            json["bible"] = new JsonObject
            {
                ["book"] = book.Name, ["position"] = s.SelectedBookIndex, ["chapter"] = s.SelectedChapter,
                ["verses"] = string.Join(",", s.SelectedVerses), ["translation"] = s.PrimaryModule?.Name ?? "",
            };
        if (s.CurrentSong is Song song)
            json["song"] = new JsonObject
            {
                ["title"] = song.Title, ["number"] = song.Index + 1, ["partIndex"] = s.PartIndex ?? -1,
                ["parts"] = new JsonArray(s.Parts.Select(p => (JsonNode)new JsonObject { ["kind"] = p.Kind, ["text"] = p.Text }).ToArray()),
            };
        if (s.Mode == "pictures")
            json["show"] = new JsonObject { ["title"] = s.CurrentPicture == null ? "" : Path.GetFileName(s.CurrentPicture), ["index"] = s.PictureIndex ?? -1, ["count"] = s.Pictures.Count };
        json["presentation"] = new JsonObject
        {
            ["decks"] = new JsonArray(), ["deck"] = -1, ["pages"] = new JsonArray(), ["index"] = -1, ["local"] = -1,
            ["count"] = 0, ["total"] = 0, ["title"] = "", ["onWall"] = false,
        };
        json["pointer"] = new JsonObject
        {
            ["on"] = s.PointerOn, ["x"] = s.PointerX, ["y"] = s.PointerY,
            ["colour"] = s.PointerColour ?? s.Settings.PointerColour, ["size"] = s.PointerSizeOverride ?? s.Settings.PointerSize,
            ["opacity"] = s.PointerOpacityOverride ?? s.Settings.PointerOpacity, ["source"] = s.PointerOn ? s.PointerSource : "",
        };
        json["zoom"] = new JsonObject { ["on"] = false, ["zoom"] = 1, ["x"] = 0.5, ["y"] = 0.5, ["least"] = 1, ["most"] = 4 };
        json["hall"] = new JsonObject { ["kind"] = s.HallKind, ["title"] = s.LivePicture != null ? Path.GetFileName(s.LivePicture) : s.LiveSlide.Reference };
        json["songBook"] = s.SongBookId;
        json["plan"] = new JsonArray(s.Plan.Items.Select((item, i) => (JsonNode)new JsonObject
        {
            ["title"] = item.Title, ["subtitle"] = item.Subtitle, ["kind"] = item.Kind.ToString().ToLowerInvariant(), ["current"] = i == s.PlanSelection,
        }).ToArray());
        json["sermon"] = new JsonObject { ["on"] = s.IsSermon, ["title"] = s.IsSermon ? s.Plan.Title : "" };
        if (web) json["viewOnly"] = s.Settings.WebViewOnly;
        return json;
    }

    // MARK: Розбір запитів

    static Task Json(HttpConnection connection, int status, JsonObject json) => connection.RespondJson(status, json.ToJsonString());
    static Task Fail(HttpConnection connection, int status, string error) => Json(connection, status, new JsonObject { ["error"] = error });

    async Task Handle(HttpRequest request, HttpConnection connection)
    {
        RequestCount++;
        var settings = _state.Settings;
        if (request.Web && request.Method == "GET")
        {
            if (request.Path is "/" or "/index.html")
            {
                await connection.Respond(200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(WebPage.Html));
                return;
            }
            if (request.Path == "/api/apps") { await Json(connection, 200, new JsonObject { ["apps"] = new JsonArray() }); return; }
            if (request.Path.StartsWith("/download/")) { await Fail(connection, 404, Lang.T("У Windows-версії програм для Android немає — завантажте їх з GitHub", "The Windows edition carries no Android apps — download them from GitHub")); return; }
        }
        var secret = request.Web ? settings.WebPassword : settings.RemotePin;
        if (secret.Length > 0)
        {
            var given = request.Headers.TryGetValue("x-slovo-pin", out var header) ? header : request.Q("pin");
            if (given != secret) { await Fail(connection, 401, "pin"); return; }
        }
        if (request.Web && settings.WebViewOnly && request.Method != "GET")
        {
            await Fail(connection, 403, Lang.T("лише перегляд — керування вимкнено в Параметри → Пульт", "view only — control is off in Settings → Remote"));
            return;
        }

        if (request.Method == "GET")
        {
            if (request.Path == "/api/state")
            {
                var since = request.QInt("since") ?? -1;
                if (since < Seq) { await Json(connection, 200, await _state.Invoke(() => StateJson(request.Web))); return; }
                var timeout = new CancellationTokenSource();
                lock (_lock) _waiters.Add(new Waiter(connection, request.Web, timeout));
                _ = Task.Delay(TimeSpan.FromSeconds(15), timeout.Token).ContinueWith(async t =>
                {
                    if (t.IsCanceled) return;
                    lock (_lock) _waiters.RemoveAll(w => w.Connection == connection);
                    await Json(connection, 200, await _state.Invoke(() => StateJson(request.Web)));
                }, TaskScheduler.Default);
                return;
            }
            if (await Get(request, connection)) return;
            await Fail(connection, 404, Lang.T("немає такого шляху", "no such path"));
            return;
        }
        if (request.Method != "POST" || !request.Path.StartsWith("/api/"))
        {
            await Fail(connection, 404, Lang.T("немає такого шляху", "no such path"));
            return;
        }
        await Command(request, connection);
    }

    // MARK: Читання

    async Task<bool> Get(HttpRequest request, HttpConnection connection)
    {
        switch (request.Path)
        {
            case "/api/hall.jpg":
            {
                var width = Math.Clamp(request.QInt("w") ?? 960, 160, 1920);
                var jpeg = await _state.Invoke(() => _state.HallJpeg(width));
                await connection.Respond(200, "image/jpeg", jpeg);
                return true;
            }
            case "/api/page":
            {
                // Картинка сторінки показу — у Windows-версії лише вкладка «Зображення».
                var width = Math.Clamp(request.QInt("w") ?? 720, 160, 1600);
                var index = request.QInt("index");
                var path = await _state.Invoke(() => index is int i && i >= 0 && i < _state.Pictures.Count ? _state.Pictures[i] : _state.CurrentPicture);
                var image = path == null ? null : SlideRenderer.Image(path);
                if (image == null) { await Fail(connection, 404, Lang.T("немає такої сторінки", "no such page")); return true; }
                var height = Math.Max(1, (int)Math.Round((double)image.Height * width / image.Width));
                using var bitmap = SlideRenderer.Render(new RenderOrder { Picture = path, DrawsBackground = false }, width, height);
                await connection.Respond(200, "image/jpeg", SlideRenderer.Jpeg(bitmap, 0));
                return true;
            }
            case "/api/bible/books":
                await Json(connection, 200, await _state.Invoke(BibleBooksJson));
                return true;
            case "/api/bible/chapter":
            {
                var position = request.QInt("book");
                var number = request.QInt("chapter");
                var answer = await _state.Invoke(() => ChapterJson(position ?? _state.SelectedBookIndex, number ?? _state.SelectedChapter));
                if (answer == null) await Fail(connection, 404, Lang.T("немає такої книги або розділу", "no such book or chapter"));
                else await Json(connection, 200, answer);
                return true;
            }
            case "/api/songs/books":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["current"] = _state.SongBookId,
                    ["books"] = new JsonArray(_state.SongBooks.Select(b => (JsonNode)new JsonObject { ["id"] = b.Id, ["title"] = b.Name, ["short"] = b.ShortName }).ToArray()),
                }));
                return true;
            case "/api/songs/list":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["book"] = _state.SongBookId, ["selected"] = _state.SongIndex ?? -1,
                    ["songs"] = new JsonArray(_state.Library.SongsOf(_state.SongBookId, "").Select(s => (JsonNode)new JsonObject
                    {
                        ["index"] = s.Index, ["number"] = s.Index + 1, ["title"] = s.Title, ["subtitle"] = "",
                    }).ToArray()),
                }));
                return true;
            case "/api/media":
                await Json(connection, 200, new JsonObject
                {
                    ["title"] = "", ["playing"] = false, ["position"] = 0, ["duration"] = 0, ["volume"] = 1, ["muted"] = false,
                    ["video"] = false, ["toScreen"] = false, ["repeats"] = false, ["index"] = -1, ["playlist"] = new JsonArray(),
                    ["note"] = Lang.T("Медіаплеєра у Windows-версії ще немає", "The Windows edition has no media player yet"),
                });
                return true;
            case "/api/pictures":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["index"] = _state.PictureIndex ?? -1, ["count"] = _state.Pictures.Count,
                    ["pages"] = new JsonArray(_state.Pictures.Select((p, i) => (JsonNode)new JsonObject { ["index"] = i, ["title"] = Path.GetFileNameWithoutExtension(p) }).ToArray()),
                }));
                return true;
            case "/api/screen":
                await Json(connection, 200, new JsonObject
                {
                    ["running"] = false, ["current"] = "", ["note"] = Lang.T("Захоплення екрана у Windows-версії ще немає", "Screen capture is not in the Windows edition yet"),
                    ["permission"] = true, ["sources"] = new JsonArray(),
                });
                return true;
            case "/api/history":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["records"] = new JsonArray(_state.History.Records.Select((r, i) => (JsonNode)new JsonObject
                    {
                        ["index"] = i, ["caption"] = r.Caption, ["kind"] = r.Kind.ToString().ToLowerInvariant(), ["current"] = _state.HistorySelection == r.Id,
                    }).ToArray()),
                }));
                return true;
            case "/api/text":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["title"] = _state.Text.Title, ["body"] = _state.Text.Body, ["page"] = _state.TextPageIndex, ["pages"] = _state.TextPages.Count,
                }));
                return true;
            case "/api/search":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["query"] = _state.SearchedQuery, ["searching"] = _state.IsSearching,
                    ["hits"] = new JsonArray(_state.Hits.Take(300).Select((h, i) => (JsonNode)new JsonObject { ["index"] = i, ["reference"] = h.Reference, ["text"] = h.Text }).ToArray()),
                }));
                return true;
            case "/api/resources/sources":
            case "/api/resources":
                await Json(connection, 200, new JsonObject { ["sources"] = new JsonArray(), ["items"] = new JsonArray(), ["note"] = Lang.T("Ресурси ставляться на самому комп'ютері: меню «Файл»", "Resources are installed on the computer itself: File menu") });
                return true;
            case "/api/resources/progress":
                await Json(connection, 200, new JsonObject { ["running"] = false, ["items"] = new JsonArray() });
                return true;
            case "/api/backing":
                await Json(connection, 200, new JsonObject { ["list"] = new JsonArray(), ["index"] = -1, ["playing"] = false, ["position"] = 0, ["duration"] = 0, ["volume"] = 1, ["tone"] = 0, ["loop"] = false });
                return true;
            case "/api/library":
                await Json(connection, 200, await _state.Invoke(() => new JsonObject
                {
                    ["bibles"] = new JsonArray(_state.AllModules.Select(m => (JsonNode)new JsonObject
                    {
                        ["id"] = m.Id, ["name"] = m.Name, ["short"] = m.ShortName, ["books"] = _state.Library.Count("books", m.Id),
                    }).ToArray()),
                    // Планшет розбирає лише `.vbm` — так його і називаємо.
                    ["songbooks"] = new JsonArray(_state.SongBooks.Select(b => (JsonNode)new JsonObject
                    {
                        ["file"] = Path.GetFileNameWithoutExtension(AppState.SongBookFileName(b.Id)) + ".vbm", ["name"] = b.Name,
                        ["format"] = "vbm", ["songs"] = _state.Library.Count("songs", b.Id),
                    }).ToArray()),
                }));
                return true;
            case "/api/library/bible":
            {
                var id = request.Q("id");
                var module = await _state.Invoke(() => _state.Module(id));
                if (module == null) { await Fail(connection, 404, Lang.T("немає такого перекладу", "no such translation")); return true; }
                var text = await Task.Run(() => SlovoBibleText(module));
                await connection.Respond(200, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes(text));
                return true;
            }
            case "/api/library/songbook":
            {
                var file = request.Q("file");
                var book = await _state.Invoke(() => _state.SongBookByFileName(file));
                if (book == null) { await Fail(connection, 404, Lang.T("немає такого пісенника", "no such songbook")); return true; }
                var bytes = await Task.Run(() => SongBookWriter.Vbm(_state.Library.SongBook(book.Id)));
                await connection.Respond(200, "application/octet-stream", bytes);
                return true;
            }
        }
        return false;
    }

    JsonObject BibleBooksJson() => new()
    {
        ["translation"] = new JsonObject { ["id"] = _state.PrimaryModuleId, ["name"] = _state.PrimaryModule?.Name ?? "" },
        ["translations"] = new JsonArray(_state.Modules.Select(m => (JsonNode)new JsonObject { ["id"] = m.Id, ["name"] = m.Name }).ToArray()),
        ["current"] = new JsonObject { ["book"] = _state.SelectedBookIndex, ["chapter"] = _state.SelectedChapter, ["verses"] = new JsonArray(_state.SelectedVerses.Select(v => (JsonNode)v).ToArray()) },
        ["books"] = new JsonArray(_state.Books.Select((b, i) => (JsonNode)new JsonObject
        {
            ["position"] = i, ["name"] = b.Name, ["short"] = BookNames.ButtonTitle(b), ["chapters"] = b.Chapters, ["testament"] = AppState.Testament(b),
        }).ToArray()),
    };

    JsonObject? ChapterJson(int position, int number)
    {
        var module = _state.PrimaryModule;
        if (module == null || position < 0 || position >= _state.Books.Count) return null;
        var book = _state.Books[position];
        var verses = _state.Library.Verses(module.Id, book.Index, number);
        if (verses.Count == 0) return null;
        return new JsonObject
        {
            ["book"] = position, ["name"] = book.Name, ["chapter"] = number, ["chapters"] = book.Chapters,
            ["verses"] = new JsonArray(verses.Select(v => (JsonNode)new JsonObject { ["number"] = v.Number, ["text"] = v.Text }).ToArray()),
        };
    }

    /// Переклад цілком рядками SLOVO-BIBLE — планшету й «Проповіднику».
    string SlovoBibleText(Module module)
    {
        static string Field(string text) => text.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        var out_ = new StringBuilder("SLOVO-BIBLE 1\n");
        out_.Append("M\t").Append(Field(module.Id)).Append('\t').Append(Field(module.Name)).Append('\t').Append(Field(module.ShortName)).Append('\n');
        foreach (var book in _state.Library.Books(module.Id))
        {
            out_.Append("B\t").Append(book.Index).Append('\t').Append(book.Canon > 0 ? book.Canon.ToString() : "").Append('\t')
                .Append(Field(book.Name)).Append('\t').Append(Field(book.ShortName)).Append('\t').Append(book.Chapters).Append('\n');
        }
        foreach (var verse in _state.Library.AllVerses(module.Id))
        {
            // Вірші йдуть після всіх книг; планшет пише їх у базу під поточною книгою — тож
            // перед віршами іншої книги повторюємо її рядок B.
            out_.Append("V\t").Append(verse.Chapter).Append('\t').Append(verse.Number).Append('\t').Append(Field(verse.Text)).Append('\n');
        }
        return Rearranged(out_.ToString(), module);
    }

    /// Рядки V мають стояти під своєю книгою B — так читає планшет.
    string Rearranged(string flat, Module module)
    {
        var books = _state.Library.Books(module.Id);
        var byBook = new Dictionary<int, StringBuilder>();
        var output = new StringBuilder("SLOVO-BIBLE 1\n");
        output.Append("M\t").Append(module.Id.Replace('\t', ' ')).Append('\t').Append(module.Name.Replace('\t', ' ')).Append('\t').Append(module.ShortName.Replace('\t', ' ')).Append('\n');
        foreach (var verse in _state.Library.AllVerses(module.Id))
        {
            if (!byBook.TryGetValue(verse.Book, out var sb)) byBook[verse.Book] = sb = new StringBuilder();
            sb.Append("V\t").Append(verse.Chapter).Append('\t').Append(verse.Number).Append('\t')
              .Append(verse.Text.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ')).Append('\n');
        }
        foreach (var book in books)
        {
            output.Append("B\t").Append(book.Index).Append('\t').Append(book.Canon > 0 ? book.Canon.ToString() : "").Append('\t')
                  .Append(book.Name.Replace('\t', ' ')).Append('\t').Append(book.ShortName.Replace('\t', ' ')).Append('\t').Append(book.Chapters).Append('\n');
            if (byBook.TryGetValue(book.Index, out var sb)) output.Append(sb);
        }
        return output.ToString();
    }

    // MARK: Команди

    async Task Command(HttpRequest request, HttpConnection connection)
    {
        var command = request.Path["/api/".Length..];
        JsonObject body;
        try { body = request.Body.Length > 0 && !IsBinaryCommand(command) ? JsonNode.Parse(request.Body) as JsonObject ?? new JsonObject() : new JsonObject(); }
        catch { body = new JsonObject(); }
        int? index = body["index"] is JsonValue iv ? (iv.TryGetValue<int>(out var ii) ? ii : int.TryParse(iv.ToString(), out var si) ? si : null) : null;
        var text = (string?)body["text"] ?? "";
        double? Number(string key) => body[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
        bool Flag(string key) => body[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

        Paths.Say("пульт: команда " + command + (index != null ? " " + index : "") + (text.Length > 0 ? " «" + text + "»" : ""));
        var answer = new JsonObject { ["ok"] = true };
        var s = _state;
        string? failure = null;
        var failureCode = 404;

        if (command == "upload") { await Upload(request, connection); return; }
        if (command == "module-import") { await ModuleImport(request, connection); return; }

        await s.Invoke(() =>
        {
            switch (command)
            {
                case "next": if (!ShowFromPhone((string?)body["tab"], 1)) Step(1); break;
                case "prev": if (!ShowFromPhone((string?)body["tab"], -1)) Step(-1); break;
                case "show": if (!ShowFromPhone((string?)body["tab"], 0)) s.ShowCurrent(); break;
                case "hide": s.Hide(); break;
                case "black": s.ToggleBlackScreen(); break;
                case "blank": s.ToggleBlankSlide(); break;
                case "next-chapter": s.StepChapter(1, false); break;
                case "prev-chapter": s.StepChapter(-1, false); break;
                case "plan":
                    if (index is int pi && pi >= 0 && pi < s.Plan.Items.Count) s.ActivatePlan(pi, true);
                    else failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "part":
                    if (s.SongIndex == null) failure = Lang.T("пісня не вибрана", "no song selected");
                    else if (index is int part) s.SelectPart(part, true);
                    break;
                case "song":
                    if (index is int si2) { s.SelectSong(si2, false); } else { failure = "index"; failureCode = 400; }
                    break;
                case "page":
                case "picture":
                    if (index is int page && page >= 0 && page < s.Pictures.Count) s.ShowPicture(page);
                    else failure = Lang.T("немає такої сторінки", "no such page");
                    break;
                case "deck": break;
                case "pointer":
                    if (Number("x") is double x && Number("y") is double y)
                        s.MovePointer(x, y, "phone", (string?)body["colour"], Number("size"), Number("opacity"));
                    else s.HidePointer();
                    break;
                case "pointer-off": s.HidePointer(); break;
                case "zoom": answer["zoom"] = 1; break;
                case "sermon-plan": answer = AcceptSermonPlan(body); break;
                case "sermon-end": s.EndSermon(); break;
                case "goto":
                    if (!s.ApplyQuickInput(text, true)) failure = Lang.T("адресу не знайдено", "address not found");
                    break;
                case "bible-select":
                {
                    var position = (int?)Number("book") ?? s.SelectedBookIndex;
                    var chapter = (int?)Number("chapter") ?? s.SelectedChapter;
                    var verses = (body["verses"] as JsonArray ?? new JsonArray()).Select(n => (int?)n ?? -1).Where(v => v >= 0).ToList();
                    if (!s.OpenScripture(position, chapter, verses, Flag("live"))) failure = Lang.T("немає такої книги", "no such book");
                    break;
                }
                case "bible-translation":
                    if (s.Module(text) == null) failure = Lang.T("немає такого перекладу", "no such translation");
                    else s.SelectPrimary(text);
                    break;
                case "mode":
                    if (AppState.Modes.Contains(text)) s.Mode = text;
                    else if (text is "presentation" or "media" or "screen") { failure = Lang.T("цієї вкладки у Windows-версії ще немає", "this tab is not in the Windows edition yet"); failureCode = 400; }
                    else { failure = Lang.T("немає такої вкладки", "no such tab"); failureCode = 400; }
                    break;
                case "songs":
                    answer["songs"] = new JsonArray(s.Library.SongsOf(s.SongBookId, text, 60).Select(song => (JsonNode)new JsonObject
                    {
                        ["index"] = song.Index, ["title"] = (song.Index + 1) + ". " + song.Title, ["subtitle"] = "",
                    }).ToArray());
                    break;
                case "songs-book":
                    if (s.SongBooks.Any(b => b.Id == text)) s.SelectSongBook(text);
                    else failure = Lang.T("немає такого збірника", "no such songbook");
                    break;
                case "text-set":
                    s.TextPageIndex = 0;
                    s.SetText((string?)body["title"] ?? "", text);
                    if (s.Mode != "text") s.Mode = "text";
                    answer["pages"] = s.TextPages.Count;
                    break;
                case "text-show": s.ShowText(); break;
                case "text-page":
                    if (index is int tp) s.SelectTextPage(tp, true); else { failure = "index"; failureCode = 400; }
                    break;
                case "history":
                    if (index is int hi && !s.ActivateHistory(hi, true)) failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "history-remove":
                    if (index is int hr && hr >= 0 && hr < s.History.Records.Count) s.RemoveHistory(s.History.Records[hr].Id);
                    else failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "plan-add": s.AddCurrentToPlan(); break;
                case "plan-remove":
                    if (index is int pr && pr >= 0 && pr < s.Plan.Items.Count) s.RemovePlanItem(pr);
                    else failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "plan-move":
                    if (index is int pm && pm >= 0 && pm < s.Plan.Items.Count && Number("delta") is double delta && delta != 0) s.MovePlanItem(pm, (int)delta);
                    else failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "bible-search":
                    if (s.Mode != "bible") s.Mode = "bible";
                    s.RunSearch(text);
                    break;
                case "search-hit":
                    if (index is int sh && !s.ShowHit(sh, Flag("live"))) failure = Lang.T("немає такого пункту", "no such item");
                    break;
                case "window-open":
                    if (s.WindowRequested == null) { failure = Lang.T("вікна немає", "no window"); failureCode = 400; }
                    else s.WindowRequested(text);
                    break;
                case "window-snapshot":
                    // Знімок вікна програми й кадру залу у файли — щоб бачити те саме, що людина,
                    // коли зняти екран не дає система (перевірка у віртуальній машині).
                    try { answer["зал"] = s.SaveScreenshot(); } catch { /* без знімка */ }
                    try { answer["snapshot"] = s.WindowSnapshot?.Invoke(Path.Combine(Paths.Screenshots, "slovo-вікно.png")) ?? ""; }
                    catch (Exception error) { answer["snapshot"] = ""; answer["snapshotError"] = error.Message; }
                    break;
                default:
                    if (command.StartsWith("media-") || command.StartsWith("screen-") || command.StartsWith("backing-") || command.StartsWith("resources-") || command.StartsWith("resource-"))
                    {
                        failure = Lang.T("цієї функції у Windows-версії ще немає", "this function is not in the Windows edition yet");
                        failureCode = 400;
                    }
                    else failure = Lang.F("немає такої команди: {0}", "no such command: {0}", command);
                    break;
            }
        });
        if (failure != null) { await Fail(connection, failureCode, failure); return; }
        await Json(connection, 200, answer);
    }

    static bool IsBinaryCommand(string command) => command is "upload" or "module-import";

    /// Телефон на вкладці «Показ»: у Windows-версії показ — це «Зображення».
    bool ShowFromPhone(string? tab, int delta)
    {
        if (tab != "show") return false;
        var s = _state;
        if (s.Pictures.Count == 0) return false;
        var wasShowing = s.Mode == "pictures";
        if (!wasShowing) s.Mode = "pictures";
        if (s.PictureIndex == null) s.SelectPicture(0);
        if (wasShowing && delta != 0 && s.IsLive && s.LivePicture != null) s.StepPicture(delta, false);
        if (s.PictureIndex is int index) s.ShowPicture(index);
        return true;
    }

    /// «Далі» й «Назад» з телефона — завжди з показом у залі.
    void Step(int delta)
    {
        var s = _state;
        s.Step(delta, true);
        if (!s.IsLive) s.ShowCurrent();
    }

    // MARK: Файли з телефона

    async Task Upload(HttpRequest request, HttpConnection connection)
    {
        var rawName = request.Q("name").Split('/').Last().Split('\\').Last();
        var name = rawName.Replace(':', '-').Trim();
        if (name.Length == 0) { await Fail(connection, 400, Lang.T("немає імені файла (name=)", "no file name (name=)")); return; }
        if (request.Body.Length == 0) { await Fail(connection, 400, Lang.T("порожній файл", "empty file")); return; }
        var target = Path.Combine(Paths.Uploads, name);
        try { await File.WriteAllBytesAsync(target, request.Body); }
        catch (Exception error) { await Fail(connection, 400, error.Message); return; }
        if (request.Q("store") == "1") { await Json(connection, 200, new JsonObject { ["file"] = name }); return; }
        if (!AppState.IsPictureFile(target))
        {
            await Fail(connection, 400, Lang.F("такий файл Windows-версія ще не показує: .{0} (лише картинки)", "the Windows edition does not show such files yet: .{0} (pictures only)", Path.GetExtension(name).TrimStart('.')));
            return;
        }
        var show = request.Q("show") == "1";
        var position = await _state.Invoke(() =>
        {
            SlideRenderer.Forget(target);
            _state.ReloadPictures();
            var at = _state.Pictures.FindIndex(p => string.Equals(p, target, StringComparison.OrdinalIgnoreCase));
            if (at >= 0) { if (show) _state.ShowPicture(at); else _state.SelectPicture(at); }
            return at;
        });
        Paths.Say("пульт: прийнято файл «" + name + "» (" + request.Body.Length + " байт)");
        await Json(connection, 200, new JsonObject { ["name"] = name, ["pages"] = position >= 0 ? 1 : 0, ["deck"] = -1, ["page"] = position });
    }

    /// Переклад чи пісенник із планшета: поставити й увімкнути.
    async Task ModuleImport(HttpRequest request, HttpConnection connection)
    {
        var name = Path.GetFileName(request.Q("name")).Replace(':', '-').Trim();
        if (name.Length == 0 || name == ".." || request.Body.Length == 0) { await Fail(connection, 400, Lang.T("немає імені файла (name=)", "no file name (name=)")); return; }
        var folder = Path.Combine(Paths.Cache, "import-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, name);
        try
        {
            await File.WriteAllBytesAsync(file, request.Body);
            Paths.Say("пульт: модуль із планшета «" + name + "» (" + request.Body.Length + " байт)");
            var result = await Task.Run(() => ResourceStore.ImportFile(_state.Library, file, "tablet"));
            await _state.Invoke(() =>
            {
                foreach (var id in result.Modules) if (!_state.Settings.ModuleOrder.Contains(id)) _state.Settings.ModuleOrder.Add(id);
                _state.ReloadModules();
                _state.ReloadTemplates();
                _state.ReloadPictures();
            });
            await Json(connection, 200, new JsonObject
            {
                ["modules"] = new JsonArray(result.Modules.Select(m => (JsonNode)m).ToArray()),
                ["imported"] = new JsonArray(result.Names.Select(n => (JsonNode)n).ToArray()),
                ["failures"] = new JsonArray(result.Failures.Select(f => (JsonNode)f).ToArray()),
            });
        }
        catch (Exception error)
        {
            await Fail(connection, 400, error.Message);
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch { /* тимчасова тека */ }
        }
    }

    // MARK: План проповіді

    JsonObject AcceptSermonPlan(JsonObject body)
    {
        var raw = body["items"] as JsonArray ?? new JsonArray();
        var notes = new List<string>();
        var items = new List<PlanItem>();
        foreach (var node in raw)
            if (node is JsonObject entry && SermonItem(entry, notes) is PlanItem item) items.Add(item);
        var title = ((string?)body["title"] ?? "").Trim();
        _state.BeginSermon(items, title);
        Paths.Say("пульт: план проповіді «" + title + "» — " + items.Count + " пунктів із " + raw.Count);
        return new JsonObject { ["added"] = items.Count, ["first"] = 0, ["notes"] = new JsonArray(notes.Select(n => (JsonNode)n).ToArray()) };
    }

    PlanItem? SermonItem(JsonObject entry, List<string> notes)
    {
        string S(string key) => (string?)entry[key] ?? "";
        int? N(string key) => entry[key] is JsonValue v ? (v.TryGetValue<int>(out var i) ? i : int.TryParse(v.ToString().Trim(), out var p) ? p : null) : null;
        var title = S("title").Trim();
        var s = _state;
        switch (S("type"))
        {
            case "scripture":
            {
                var chapter = N("chapter") ?? 1;
                var verses = (entry["verses"] as JsonArray ?? new JsonArray()).Select(n => (int?)n ?? -1).Where(v => v >= 0).ToList();
                var module = s.Module(S("module")) ?? s.AllModules.FirstOrDefault(m => m.Name.Equals(S("moduleName").Trim(), StringComparison.OrdinalIgnoreCase)) ?? s.PrimaryModule;
                if (module != null)
                {
                    var books = s.Library.Books(module.Id);
                    var canon = N("canon");
                    var bookName = S("bookName").Trim();
                    var position = canon is int c ? books.FindIndex(b => b.Canon == c) : -1;
                    if (position < 0 && bookName.Length > 0) position = books.FindIndex(b => b.Name.Equals(bookName, StringComparison.OrdinalIgnoreCase));
                    if (position >= 0) return PlanItem.Scripture(module.Id, books[position], position, chapter, verses, S("text"));
                }
                notes.Add(Lang.F("«{0}»: такої книги нема в перекладах програми — пункт став текстом", "“{0}”: no such book in the program's translations — the item became text", title));
                return PlanItem.Text(new TextDocument(title, S("text")));
            }
            case "song":
            {
                var file = S("songBook");
                var index = N("song") ?? -1;
                var book = s.SongBookByFileName(file);
                var song = book == null ? null : s.Library.SongAt(book.Id, index);
                if (book != null && song != null && (title.Length == 0 || song.Title == title))
                    return PlanItem.Song(AppState.SongBookFileName(book.Id), index, song.Title, s.Library.Parts(book.Id, index).FirstOrDefault()?.Text);
                var parts = entry["parts"] as JsonArray ?? new JsonArray();
                var lyrics = string.Join("\n\n", parts.Select(p => (string?)p?["text"] ?? "").Where(t => t.Length > 0));
                notes.Add(Lang.F("«{0}»: пісенника нема в програмі — пісня стала текстом", "“{0}”: the songbook is not in the program — the song became text", title));
                return PlanItem.Text(new TextDocument(title, lyrics));
            }
            case "text":
            {
                var heading = S("heading");
                var text = S("body");
                return heading.Length == 0 && text.Length == 0 ? null : PlanItem.Text(new TextDocument(heading, text));
            }
            case "file":
            {
                var name = Path.GetFileName(S("file"));
                var path = Path.Combine(Paths.Uploads, name);
                if (name.Length == 0 || !File.Exists(path)) { notes.Add(Lang.F("«{0}»: файл не дійшов до програми", "“{0}”: the file did not reach the program", title.Length == 0 ? name : title)); return null; }
                if (!AppState.IsPictureFile(path)) notes.Add(Lang.F("«{0}»: Windows-версія показує лише картинки", "“{0}”: the Windows edition shows pictures only", title.Length == 0 ? name : title));
                return PlanItem.File(path, title);
            }
        }
        return null;
    }
}
