// =============================================================================
//  RemoteControlServer.State.cs — стан для телефона (stateJSON на Mac)
// =============================================================================

using System.Text.Json.Nodes;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class RemoteControlServer
{
    static string ModeRaw(WorkMode mode) => mode.ToString().ToLowerInvariant();

    /// Відбиток списку фото (FNV-1a по назвах): однаковий на Mac і Windows, сталий між пусками.
    static long PicturesSign(IEnumerable<string> titles)
    {
        uint hash = 2166136261;
        foreach (var title in titles)
        {
            foreach (var b in System.Text.Encoding.UTF8.GetBytes(title)) hash = unchecked((hash ^ b) * 16777619);
            hash = unchecked((hash ^ 1) * 16777619);
        }
        return hash;
    }

    public JsonObject StateJson(bool web = false)
    {
        if (_state is not { } state) return new JsonObject { ["seq"] = Seq };
        var live = state.LiveSlide;
        var json = new JsonObject
        {
            ["seq"] = Seq, ["hallSeq"] = HallSeq, ["app"] = "Slovo", ["name"] = ComputerName,
            ["mode"] = ModeRaw(state.Mode), ["live"] = state.IsLive, ["black"] = state.IsBlackout, ["blank"] = state.IsTextHidden,
            ["slide"] = new JsonObject
            {
                ["reference"] = live.Reference, ["text"] = live.MainText,
                ["secondary"] = new JsonArray(live.SecondaryTexts.Select(t => (JsonNode)t).ToArray()),
            },
            ["preview"] = new JsonObject { ["reference"] = state.Slide.Reference, ["text"] = state.Slide.MainText },
        };
        if (state.CurrentBook is { } book)
            json["bible"] = new JsonObject
            {
                ["book"] = book.FullName, ["position"] = state.SelectedBookIndex, ["chapter"] = state.SelectedChapterNumber,
                ["verses"] = string.Join(",", state.SelectedVerseNumbers), ["translation"] = state.PrimaryModule?.DisplayName ?? "",
            };
        if (Songs?.Model is { Song: { } song } model)
            json["song"] = new JsonObject
            {
                ["title"] = song.Title, ["number"] = song.Index + 1, ["partIndex"] = model.PartIndex ?? -1,
                ["parts"] = new JsonArray(song.Parts.Select(p => (JsonNode)new JsonObject { ["kind"] = p.Kind, ["text"] = p.Text }).ToArray()),
            };
        if (ShowWorkspace.For(state.Mode) is { } own)
            json["show"] = new JsonObject { ["title"] = own.Model.CurrentTitle, ["index"] = own.Model.Index ?? -1, ["count"] = own.Model.Count };
        // Список фото — завжди, на якій би вкладці не стояла програма: прибрали фото з іншого пульта
        // чи на комп'ютері, поки програма на презентації, — пульт має перечитати свій список. `sign` —
        // відбиток назв. Як на Mac (`picturesSign`).
        var pictures = ShowWorkspace.Pictures.Model;
        json["pictures"] = new JsonObject { ["count"] = pictures.Count, ["sign"] = PicturesSign(pictures.Pages.Select(p => p.Title)) };
        // Презентація — завжди, хоч на якій вкладці програма: головна робота пульта — гортати її.
        var show = ShowWorkspace.Presentation.Model;
        var (start, count) = show.CurrentRange;
        var onWall = state.IsLive && state.StillShown && state.Mode == WorkMode.Presentation;
        json["presentation"] = new JsonObject
        {
            ["decks"] = new JsonArray(show.Decks.Select((deck, i) => (JsonNode)new JsonObject { ["index"] = i, ["name"] = deck.Name, ["count"] = deck.Count }).ToArray()),
            ["deck"] = show.CurrentDeck ?? (show.Decks.Count == 0 ? -1 : 0),
            ["pages"] = new JsonArray(Enumerable.Range(start, count).Where(i => i >= 0 && i < show.Count)
                                       .Select(i => (JsonNode)new JsonObject { ["index"] = i, ["title"] = show.Pages[i].Short }).ToArray()),
            ["index"] = show.Index ?? -1,
            ["local"] = show.Index is { } at ? at - start : -1,
            ["count"] = count, ["total"] = show.Count, ["title"] = show.CurrentTitle, ["onWall"] = onWall,
        };
        // Указка: місце, вигляд і хто веде — чужу (мишею) телефон показує кольором програми.
        var pointer = SlidePointer.Shared;
        var look = pointer.Current;
        json["pointer"] = new JsonObject
        {
            ["on"] = pointer.Point != null, ["x"] = pointer.Point?.X ?? 0.5, ["y"] = pointer.Point?.Y ?? 0.5,
            ["colour"] = SlidePointer.Look.Hex(look.Colour), ["size"] = look.Size, ["opacity"] = look.Opacity,
            ["source"] = pointer.Point == null ? "" : pointer.Source,
        };
        var focus = SlideFocus.Shared;
        json["zoom"] = new JsonObject
        {
            ["on"] = focus.IsOn, ["zoom"] = focus.IsOn ? focus.Current.Zoom : 1, ["x"] = focus.Current.X, ["y"] = focus.Current.Y,
            ["least"] = SlideFocus.MinZoom, ["most"] = SlideFocus.MaxZoom,
        };
        json["hall"] = HallJson(state);
        // Відкритий пісенник: змінили на комп'ютері — планшет перечитує пісні.
        json["songBook"] = state.SongBookID;
        json["plan"] = new JsonArray(state.Plan.Items.Select(item => (JsonNode)new JsonObject
        {
            ["title"] = item.Title, ["subtitle"] = item.Subtitle ?? "", ["kind"] = item.Kind.RawValue(), ["current"] = state.PlanSelection.Contains(item.Id),
        }).ToArray());
        // План проповіді заступив план служіння — планшет показує, чий план перед ним.
        json["sermon"] = new JsonObject { ["on"] = state.IsSermon, ["title"] = state.IsSermon ? state.Plan.Title : "" };
        if (web) json["viewOnly"] = _webViewOnly;
        return json;
    }

    /// Що зараз на стіні: затемнення, картинка показу, текст чи порожньо.
    static JsonObject HallJson(AppState state)
    {
        string kind;
        var media = state.Media;
        if (state.IsBlackout) kind = "black";
        else if (media.IsVideoOnScreen) kind = "video";
        else if (state.IsLive && state.StillShown) kind = "still";
        else kind = state.IsLive ? "text" : "empty";
        var title = media.IsVideoOnScreen ? media.Title : state.IsLive && state.StillShown ? state.LiveStillTitle : state.LiveSlide.Reference;
        return new JsonObject { ["kind"] = kind, ["title"] = title };
    }
}
