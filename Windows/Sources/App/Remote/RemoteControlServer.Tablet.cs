// =============================================================================
//  RemoteControlServer.Tablet.cs — читання й команди планшета (як +Tablet на Mac)
// =============================================================================
//  Плеєр, картинки, екран, текст, Історія, пошук, картинка залу. Чого у
//  Windows-версії ще немає (захоплення екрана, фонограма), канал
//  віддає порожнім, а команди — з поясненням, а не мовчки.
// =============================================================================

using System.Text.Json.Nodes;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class RemoteControlServer
{
    /// Відданий кадр залу за шириною: на той самий номер удруге не малюємо, але не довше 3 с.
    readonly Dictionary<int, (int Seq, DateTime Made, byte[] Jpeg)> _hallCache = new();

    bool TabletGet(HttpRequest request, AppState state, HttpConnection connection)
    {
        switch (request.Path)
        {
            case "/api/hall.jpg":
            {
                var width = Math.Min(1920, Math.Max(160, request.QInt("w") ?? 960));
                if (_hallCache.TryGetValue(width, out var cached) && cached.Seq == HallSeq && (DateTime.Now - cached.Made).TotalSeconds < 3)
                {
                    RespondData(connection, 200, cached.Jpeg, "image/jpeg");
                    return true;
                }
                var (fw, fh) = ProjectionController.Shared.FrameSize();
                var height = Math.Max(1, (int)Math.Round(width * (double)fh / Math.Max(1, fw)));
                using var image = MainWindow.Shared?.Output?.HallFrame(width, height);
                if (image == null || Jpeg(image, width) is not { } jpeg) { Fail(connection, 404, Captions.T("в зале видео")); return true; }
                if (_hallCache.Count > 6) _hallCache.Clear();
                _hallCache[width] = (HallSeq, DateTime.Now, jpeg);
                RespondData(connection, 200, jpeg, "image/jpeg");
                return true;
            }
            case "/api/songs/books": Respond(connection, 200, SongBooksJson(state)); return true;
            case "/api/songs/list": Respond(connection, 200, SongListJson(state)); return true;
            case "/api/media": Respond(connection, 200, MediaJson()); return true;
            case "/api/pictures": Respond(connection, 200, PicturesJson()); return true;
            case "/api/screen": Respond(connection, 200, ScreenJson(state)); return true;
            case "/api/history": Respond(connection, 200, HistoryJson(state)); return true;
            case "/api/text": Respond(connection, 200, TextJson()); return true;
            case "/api/search": Respond(connection, 200, SearchJson(state)); return true;
            default: return false;
        }
    }

    static JsonObject SongBooksJson(AppState state)
    {
        var books = state.SongLibrary?.Books ?? (IReadOnlyList<SongLibrary.Entry>)Array.Empty<SongLibrary.Entry>();
        var open = Songs?.Model.Book?.Title ?? "";
        return new JsonObject
        {
            ["current"] = state.SongBookID,
            ["books"] = new JsonArray(books.Select(entry => (JsonNode)new JsonObject
            {
                ["id"] = entry.Id, ["title"] = entry.Id == state.SongBookID && open.Length > 0 ? open : entry.Title, ["short"] = entry.ShortName,
            }).ToArray()),
        };
    }

    static JsonObject SongListJson(AppState state)
    {
        var model = Songs?.Model;
        var songs = model?.Book?.Songs ?? (IReadOnlyList<Song>)Array.Empty<Song>();
        return new JsonObject
        {
            ["book"] = state.SongBookID,
            ["selected"] = model?.SongIndex ?? -1,
            ["songs"] = new JsonArray(songs.Select(s => (JsonNode)new JsonObject
            {
                ["index"] = s.Index, ["number"] = s.Index + 1, ["title"] = s.Title, ["subtitle"] = s.Subtitle ?? "",
            }).ToArray()),
        };
    }

    /// Стан плеєра для планшета (mediaJSON на Mac).
    static JsonObject MediaJson()
    {
        var media = AppState.Shared.Media;
        return new JsonObject
        {
            ["title"] = media.Title, ["playing"] = media.IsPlaying, ["position"] = media.Position, ["duration"] = media.Duration,
            ["volume"] = media.Volume, ["muted"] = media.IsMuted, ["video"] = media.HasVideo, ["toScreen"] = media.VideoToScreen,
            ["repeats"] = media.Repeats, ["index"] = media.PlaylistIndex ?? -1,
            ["playlist"] = new JsonArray(media.Playlist.Select((path, i) => (JsonNode)new JsonObject { ["index"] = i, ["name"] = media.PlaylistCaption(path) }).ToArray()),
            ["next"] = media.PlaysNext,
            // Скільки звукових доріжок бачить програвач — перевірці (ролик YouTube мусить мати звук).
            ["audioTracks"] = media.AudioTracks.Count,
            // Вбудований YouTube: сам програвач стоїть у вікні залу (а не знімки) — перевірці.
            ["embedInHall"] = media.Embed?.InHall ?? false,
            ["embedNote"] = ProjectionController.Shared.EmbedNote,
        };
    }

    static JsonObject PicturesJson()
    {
        var model = ShowWorkspace.Pictures.Model;
        return new JsonObject
        {
            ["index"] = model.Index ?? -1, ["count"] = model.Count,
            ["pages"] = new JsonArray(model.Pages.Select((p, i) => (JsonNode)new JsonObject { ["index"] = i, ["title"] = p.Short }).ToArray()),
        };
    }

    /// Джерела захоплення; порожній список — спершу зібрати (у Windows це миттєво).
    static JsonObject ScreenJson(AppState state)
    {
        var capture = state.ScreenCapture;
        if (capture.Sources.Count == 0) capture.Reload();
        return new JsonObject
        {
            ["running"] = capture.IsRunning, ["current"] = capture.Current?.Id ?? "", ["note"] = capture.State, ["permission"] = !capture.NeedsPermission,
            ["sources"] = new JsonArray(capture.Sources.Select((s, i) => (JsonNode)new JsonObject
            {
                ["index"] = i, ["id"] = s.Id, ["kind"] = s.KindName, ["title"] = s.Title, ["subtitle"] = s.Subtitle,
            }).ToArray()),
        };
    }

    static JsonObject HistoryJson(AppState state) => new()
    {
        ["records"] = new JsonArray(state.History.Records.Select((r, i) => (JsonNode)new JsonObject
        {
            ["index"] = i, ["caption"] = r.Caption, ["kind"] = r.RecordKind.ToString().ToLowerInvariant(), ["current"] = state.HistorySelection == r.Id,
        }).ToArray()),
    };

    static JsonObject TextJson()
    {
        var model = TextModuleModel.Shared;
        return new JsonObject { ["title"] = model.Document.Title, ["body"] = model.Document.Body, ["page"] = model.PageIndex, ["pages"] = model.PageCount };
    }

    static JsonObject SearchJson(AppState state) => new()
    {
        ["query"] = state.SearchedQuery, ["searching"] = state.IsSearching,
        ["hits"] = new JsonArray(state.Hits.Take(300).Select((h, i) => (JsonNode)new JsonObject
        {
            ["index"] = i, ["reference"] = $"{h.BookName} {h.Chapter}:{h.Verse}", ["text"] = h.Text,
        }).ToArray()),
    };

    /// Команда планшета: (виконано, код помилки — 0 «немає такої», повідомлення).
    (bool Done, int Code, string? Message) TabletCommand(string command, JsonObject body, int? index, string text, AppState state, JsonObject answer)
    {
        switch (command)
        {
            case "songs-book":
                if (state.SongLibrary?.EntryFor(text) == null) return (false, 404, Captions.T("нет такого сборника"));
                Focus(state, WorkMode.Songs);
                Songs?.SelectBook(text);
                return (true, 0, null);
            case "picture":
            {
                var pictures = ShowWorkspace.Pictures;
                if (index is not { } at || at < 0 || at >= pictures.Model.Count) return (false, 404, Captions.T("нет такой страницы"));
                Focus(state, WorkMode.Pictures);
                pictures.SelectPage(at);
                if (Flag(body["live"]) ?? true) pictures.ShowCurrentPage();
                return (true, 0, null);
            }
            // Список фото з пульта: прибрати одне чи всі. Вкладку програми не перемикаємо — людина лише
            // прибирає список, а не показує. Як на Mac.
            case "picture-remove":
            {
                var pictures = ShowWorkspace.Pictures;
                if (index is not { } at || at < 0 || at >= pictures.Model.Count) return (false, 404, Captions.T("нет такой страницы"));
                pictures.RemovePage(at);
                answer["count"] = pictures.Model.Count;
                return (true, 0, null);
            }
            case "pictures-clear":
                ShowWorkspace.Pictures.RemoveAll();
                answer["count"] = 0;
                return (true, 0, null);
            // Файли презентацій (PDF, PPTX…) з пульта: прибрати один (номер у списку файлів, як у
            // `decks`) чи всі. Так само без перемикання вкладки. Як на Mac.
            case "deck-remove":
            {
                var presentation = ShowWorkspace.Presentation;
                if (index is not { } at || at < 0 || at >= presentation.Model.Decks.Count) return (false, 404, Captions.T("нет такого файла"));
                presentation.RemoveDeck(at);
                answer["count"] = presentation.Model.Decks.Count;
                return (true, 0, null);
            }
            case "decks-clear":
                ShowWorkspace.Presentation.RemoveAll();
                answer["count"] = 0;
                return (true, 0, null);
            case "media-open":
            {
                var media = state.Media;
                if (index is not { } at || at < 0 || at >= media.Playlist.Count) return (false, 404, Captions.T("нет такого файла"));
                Focus(state, WorkMode.Media);
                media.OpenFromPlaylist(at);
                return (true, 0, null);
            }
            case "media-toggle": state.Media.PlayPause(); return (true, 0, null);
            case "media-play": state.Media.Play(); return (true, 0, null);
            case "media-pause": state.Media.Pause(); return (true, 0, null);
            case "media-stop": state.Media.Stop(); return (true, 0, null);
            case "media-seek":
                if (Number(body["x"]) is not { } seconds) return (false, 400, "x");
                state.Media.Seek(seconds);
                return (true, 0, null);
            case "media-volume":
                if (Number(body["x"]) is not { } level) return (false, 400, "x");
                state.Media.Volume = Math.Clamp(level, 0, 1);
                return (true, 0, null);
            case "media-mute": state.Media.IsMuted = !state.Media.IsMuted; return (true, 0, null);
            case "media-url":
            {
                // Службова (як window-open): посилання — у список плеєра й перше додане грає, як вікно
                // «Відкрити URL» (кілька посилань — з нового рядка). Перевірці YouTube і потоків.
                Focus(state, WorkMode.Media);
                var before = state.Media.Playlist.Count;
                if (state.Media.AddLinks(text) == 0)
                    return (false, 400, state.Media.CurrentFailure is { } failure ? failure.Kind + ": " + failure.Detail : "");
                // Нічого не грало — AddLinks уже відкрив перше додане; вдруге не відкривати (вбудований
                // YouTube тоді створювався двічі, і перший рушій WebView2 обривався на півдорозі).
                if (state.Media.PlaylistIndex != before) state.Media.OpenFromPlaylist(before);
                return (true, 0, null);
            }
            case "media-next": state.Media.PlaysNext = !state.Media.PlaysNext; return (true, 0, null);
            case "media-screen": state.Media.VideoToScreen = !state.Media.VideoToScreen; return (true, 0, null);
            case "media-repeat": state.Media.Repeats = !state.Media.Repeats; return (true, 0, null);
            case "screen-reload":
                state.ScreenCapture.Reload();
                return (true, 0, null);
            case "screen-start":
            {
                var sources = state.ScreenCapture.Sources;
                if (index is not { } at || at < 0 || at >= sources.Count) return (false, 404, Captions.T("нет такого источника"));
                Focus(state, WorkMode.Screen);
                state.ShowCapturedScreen(sources[at]);
                return (true, 0, null);
            }
            case "screen-stop":
                state.StopCapturedScreen();
                return (true, 0, null);
            case "text-set":
            {
                var model = TextModuleModel.Shared;
                model.Document = new PlainTextDocument(Text(body["title"]) ?? "", text);
                Focus(state, WorkMode.Text);
                model.RefreshPreview();
                answer["pages"] = model.PageCount;
                return (true, 0, null);
            }
            case "text-show":
                Focus(state, WorkMode.Text);
                TextModuleModel.Shared.Show();
                return (true, 0, null);
            case "text-page":
                if (index is not { } page) return (false, 400, "index");
                Focus(state, WorkMode.Text);
                TextModuleModel.Shared.SelectPage(page, Flag(body["live"]) ?? true);
                return (true, 0, null);
            case "history":
            {
                var records = state.History.Records;
                if (index is not { } at || at < 0 || at >= records.Count) return (false, 404, Captions.T("нет такого пункта"));
                state.ActivateHistory(records[at], Flag(body["live"]) ?? true);
                return (true, 0, null);
            }
            case "history-remove":
            {
                var records = state.History.Records;
                if (index is not { } at || at < 0 || at >= records.Count) return (false, 404, Captions.T("нет такого пункта"));
                state.RemoveHistory(records[at].Id);
                return (true, 0, null);
            }
            case "plan-add":
                state.AddCurrentToPlan();
                return (true, 0, null);
            case "plan-remove":
                if (index is not { } removed || removed < 0 || removed >= state.Plan.Count) return (false, 404, Captions.T("нет такого пункта"));
                state.DeletePlan(new[] { removed });
                return (true, 0, null);
            case "plan-move":
            {
                // «Вгору» і «вниз» на рядок; місце вставки — до зсуву рядків, як у протяжці.
                if (index is not { } from || from < 0 || from >= state.Plan.Count || Int(body["delta"]) is not { } delta || delta == 0)
                    return (false, 404, Captions.T("нет такого пункта"));
                var target = from + delta;
                if (target >= 0 && target < state.Plan.Count) state.MovePlan(new[] { from }, delta > 0 ? target + 1 : target);
                return (true, 0, null);
            }
            case "bible-search":
                Focus(state, WorkMode.Bible);
                state.RunSearch(text);
                return (true, 0, null);
            case "search-hit":
            {
                var hits = state.Hits;
                if (index is not { } at || at < 0 || at >= hits.Count) return (false, 404, Captions.T("нет такого пункта"));
                Focus(state, WorkMode.Bible);
                state.ShowHit(hits[at], Flag(body["live"]) ?? false);
                return (true, 0, null);
            }
            default:
                return (false, 0, null);
        }
    }

    // --- Фонограма (RemoteControlServer+Backing.swift) ------------------------------------
    //  Той самий програвач, що й панель на вкладці «Пісні» (AppState.Backing): список,
    //  відтворення, гучність і тон — «Проповіднику», планшетові й телефону. Плеєр і
    //  фонограма — різні речі: плеєр веде ролики (media-*), фонограма супроводжує спів.

    bool BackingGet(HttpRequest request, AppState state, HttpConnection connection)
    {
        if (request.Path != "/api/backing") return false;
        Respond(connection, 200, BackingJson(state));
        return true;
    }

    static JsonObject BackingJson(AppState state)
    {
        var player = state.Backing;
        var playlist = new JsonArray();
        for (var i = 0; i < player.Playlist.Count; i++)
            playlist.Add(new JsonObject { ["index"] = i, ["name"] = Path.GetFileNameWithoutExtension(player.Playlist[i]) });
        return new JsonObject
        {
            ["title"] = player.Title, ["playing"] = player.IsPlaying, ["position"] = player.LivePosition, ["duration"] = player.Duration,
            ["volume"] = (double)player.Volume, ["tone"] = player.PitchTones, ["loops"] = player.Loops,
            ["index"] = player.PlaylistIndex ?? -1, ["error"] = player.Error ?? "", ["playlist"] = playlist,
        };
    }

    /// null — не команда фонограми; "" — виконано; інакше — причина відмови.
    string? BackingCommand(string command, JsonObject body, int? index, string text, AppState state, JsonObject answer)
    {
        var player = state.Backing;
        bool Known(int? i) => i is { } n && n >= 0 && n < player.Playlist.Count;
        switch (command)
        {
            case "backing-open":
                if (!Known(index)) return Captions.T("нет такой фонограммы");
                player.OpenFromPlaylist(index!.Value);
                break;
            case "backing-play":
                // Без відкритої фонограми грати нічого: беремо першу зі списку.
                if (player.Url == null && player.Playlist.Count > 0) player.OpenFromPlaylist(0);
                player.Play();
                break;
            case "backing-pause": player.Pause(); break;
            case "backing-toggle": player.Toggle(); break;
            case "backing-stop": player.Stop(); break;
            case "backing-seek":
                if (Number(body["position"]) is not { } seconds) return Captions.T("нужна позиция");
                player.Seek(seconds);
                break;
            case "backing-volume":
                if (Number(body["volume"]) is not { } volume) return Captions.T("нужна громкость");
                player.Volume = (float)Math.Clamp(volume, 0, 1);
                break;
            case "backing-tone":
                if (Number(body["tone"]) is not { } tone) return Captions.T("нужен тон");
                player.SetPitch(Math.Clamp(tone, -6, 6));
                break;
            case "backing-loop":
                player.Loops = Flag(body["loops"]) ?? !player.Loops;
                break;
            case "backing-remove":
                if (!Known(index)) return Captions.T("нет такой фонограммы");
                player.RemoveFromPlaylist(index!.Value);
                break;
            default:
                return null;
        }
        answer["backing"] = BackingJson(state);
        NoteChange();
        return "";
    }
}
