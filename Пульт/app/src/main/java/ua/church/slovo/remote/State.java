package ua.church.slovo.remote;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/// Состояние программы, как его отдаёт `GET /api/state`.
///
/// Разбирается снисходительно: чего в ответе нет — пустая строка или ноль.
/// Пульт и программа обновляются врозь, и старый пульт не должен падать от
/// нового поля, а новый — от старого сервера.
final class State {

    static final class Row {
        final String title;
        final String subtitle;
        final boolean current;

        Row(String title, String subtitle, boolean current) {
            this.title = title;
            this.subtitle = subtitle;
            this.current = current;
        }
    }

    long seq;
    String name = "";
    String mode = "";
    boolean live;
    boolean black;
    boolean blank;

    String liveReference = "";
    String liveText = "";
    String previewReference = "";
    String previewText = "";

    String songTitle = "";
    int songPartIndex = -1;
    final List<Row> parts = new ArrayList<>();

    final List<Row> plan = new ArrayList<>();

    String bibleBook = "";
    /// Номер книги в переліку програми: за ним пульт знаходить її в себе.
    int biblePosition = -1;
    int bibleChapter;
    String bibleVerses = "";
    String bibleTranslation = "";

    String showTitle = "";
    int showIndex = -1;
    int showCount;

    /// Презентация — всегда, на какой бы вкладке ни стояла программа.
    final List<Row> decks = new ArrayList<>();
    int deck = -1;
    final List<Row> pages = new ArrayList<>();
    /// Сквозные номера страниц текущей колоды — ими шлётся команда «page».
    final List<Integer> pageIndexes = new ArrayList<>();
    /// Що зараз на стіні: text, still, video, black, empty — планшет за цим
    /// вирішує, чи перезабрати картинку залу і що написати замість неї.
    String hallKind = "";
    String hallTitle = "";
    /// Відкритий пісенник: змінили на комп'ютері — планшет перечитує пісні.
    String songBook = "";
    int pageIndex = -1;
    int pageLocal = -1;
    int pageCount;
    String pageTitle = "";
    boolean onWall;

    /// Указка: чи горить, де (частки кадру, вісь Y униз), якою вона зараз і
    /// хто її веде («телефон» або миша). Телефон малює її і в себе.
    boolean pointerOn;
    double pointerX = 0.5, pointerY = 0.5;
    String pointerColour = "";
    double pointerSize;
    double pointerOpacity = 0.45;
    String pointerSource = "";

    /// Наближення (точка фокуса) так, як його бачить зал: чи ввімкнено, у
    /// скільки разів і де середина вікна — частки сторінки, вісь Y униз.
    boolean zoomOn;
    double zoom = 1, zoomX = 0.5, zoomY = 0.5;

    /// План проповіді: програма тримає його головним, а план служіння —
    /// відкладеним до кнопки «Повернути план служіння».
    boolean sermon;
    String sermonTitle = "";

    static State from(JSONObject json) {
        State state = new State();
        if (json == null) return state;
        state.seq = json.optLong("seq", 0);
        state.name = json.optString("name", "");
        state.mode = json.optString("mode", "");
        state.live = json.optBoolean("live", false);
        state.black = json.optBoolean("black", false);
        state.blank = json.optBoolean("blank", false);

        JSONObject slide = json.optJSONObject("slide");
        if (slide != null) {
            state.liveReference = slide.optString("reference", "");
            state.liveText = slide.optString("text", "");
        }
        JSONObject preview = json.optJSONObject("preview");
        if (preview != null) {
            state.previewReference = preview.optString("reference", "");
            state.previewText = preview.optString("text", "");
        }
        JSONObject song = json.optJSONObject("song");
        if (song != null) {
            state.songTitle = song.optString("title", "");
            state.songPartIndex = song.optInt("partIndex", -1);
            JSONArray parts = song.optJSONArray("parts");
            if (parts != null) {
                for (int i = 0; i < parts.length(); i++) {
                    JSONObject part = parts.optJSONObject(i);
                    if (part == null) continue;
                    state.parts.add(new Row(part.optString("kind", ""), firstLine(part.optString("text", "")),
                                            i == state.songPartIndex));
                }
            }
        }
        JSONArray plan = json.optJSONArray("plan");
        if (plan != null) {
            for (int i = 0; i < plan.length(); i++) {
                JSONObject item = plan.optJSONObject(i);
                if (item == null) continue;
                state.plan.add(new Row(item.optString("title", ""), item.optString("subtitle", ""),
                                       item.optBoolean("current", false)));
            }
        }
        JSONObject sermon = json.optJSONObject("sermon");
        if (sermon != null) {
            state.sermon = sermon.optBoolean("on", false);
            state.sermonTitle = sermon.optString("title", "");
        }
        JSONObject bible = json.optJSONObject("bible");
        if (bible != null) {
            state.bibleBook = bible.optString("book", "");
            state.biblePosition = bible.optInt("position", -1);
            state.bibleChapter = bible.optInt("chapter", 0);
            state.bibleVerses = bible.optString("verses", "");
            state.bibleTranslation = bible.optString("translation", "");
        }
        JSONObject show = json.optJSONObject("show");
        if (show != null) {
            state.showTitle = show.optString("title", "");
            state.showIndex = show.optInt("index", -1);
            state.showCount = show.optInt("count", 0);
        }
        JSONObject presentation = json.optJSONObject("presentation");
        if (presentation != null) {
            state.deck = presentation.optInt("deck", -1);
            state.pageIndex = presentation.optInt("index", -1);
            state.pageLocal = presentation.optInt("local", -1);
            state.pageCount = presentation.optInt("count", 0);
            state.pageTitle = presentation.optString("title", "");
            state.onWall = presentation.optBoolean("onWall", false);
            JSONArray decks = presentation.optJSONArray("decks");
            if (decks != null) {
                for (int i = 0; i < decks.length(); i++) {
                    JSONObject deck = decks.optJSONObject(i);
                    if (deck == null) continue;
                    state.decks.add(new Row(deck.optString("name", ""), String.valueOf(deck.optInt("count", 0)),
                                            deck.optInt("index", i) == state.deck));
                }
            }
            JSONArray pages = presentation.optJSONArray("pages");
            if (pages != null) {
                for (int i = 0; i < pages.length(); i++) {
                    JSONObject page = pages.optJSONObject(i);
                    if (page == null) continue;
                    int index = page.optInt("index", -1);
                    state.pageIndexes.add(index);
                    state.pages.add(new Row(page.optString("title", ""), "", index == state.pageIndex));
                }
            }
        }
        JSONObject pointer = json.optJSONObject("pointer");
        if (pointer != null) {
            state.pointerOn = pointer.optBoolean("on", false);
            state.pointerX = pointer.optDouble("x", 0.5);
            state.pointerY = pointer.optDouble("y", 0.5);
            state.pointerColour = pointer.optString("colour", "");
            state.pointerSize = pointer.optDouble("size", 0);
            state.pointerOpacity = pointer.optDouble("opacity", 0.45);
            state.pointerSource = pointer.optString("source", "");
        }
        JSONObject hall = json.optJSONObject("hall");
        if (hall != null) {
            state.hallKind = hall.optString("kind", "");
            state.hallTitle = hall.optString("title", "");
        }
        state.songBook = json.optString("songBook", "");
        JSONObject zoom = json.optJSONObject("zoom");
        if (zoom != null) {
            state.zoomOn = zoom.optBoolean("on", false);
            state.zoom = zoom.optDouble("zoom", 1);
            state.zoomX = zoom.optDouble("x", 0.5);
            state.zoomY = zoom.optDouble("y", 0.5);
        }
        return state;
    }

    /// Первая строка части — для списка; целиком текст видно в зале.
    private static String firstLine(String text) {
        String flat = text.replace("\r\n", "\n").trim();
        int cut = flat.indexOf('\n');
        return cut < 0 ? flat : flat.substring(0, cut) + " …";
    }
}
