package ua.church.slovo.remote;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;
import java.util.concurrent.ExecutorService;

/// Розділ «Біблія» пульта й планшета: переклад, книга, розділ, вірші.
///
/// Виглядає й працює, як у «Слові» для Android: згори шлях із трьох кнопок —
/// переклад, книга, розділ (зі стрілками до сусіднього розділу); кожна
/// відкриває свій вибір вікном знизу. Під шляхом — швидкий перехід адресою
/// («Ів 3:16») і пошук словами по всьому перекладу. Нижче — вірші з текстом.
///
/// Торкання вірша підсвічує його й кладе в передпоказ програми; ще кілька
/// торкань — кілька віршів; довге торкання — відрізок від першого вибраного.
/// «Показати» виводить вибране на стіну.
final class BibleBrowser {

    interface Host {
        Api api();
        ExecutorService queue();
        void post(Runnable body);
    }

    private static final class Book {
        final int position;
        final String name;
        final int chapters;
        final String testament;

        Book(int position, String name, int chapters, String testament) {
            this.position = position;
            this.name = name;
            this.chapters = chapters;
            this.testament = testament;
        }
    }

    private static final class Verse {
        final int number;
        final String text;

        Verse(int number, String text) {
            this.number = number;
            this.text = text;
        }
    }

    /// Знайдене пошуком за словами: адреса, текст і номер у переліку програми.
    private static final class Hit {
        final int index;
        final String reference, text;

        Hit(int index, String reference, String text) {
            this.index = index;
            this.reference = reference;
            this.text = text;
        }
    }

    private final Activity activity;
    private final Host host;

    private TextView translationButton, bookButton, chapterButton, note, clear;
    private EditText address;
    private ListView list;
    private FrameLayout body;
    private View empty;

    private final List<Book> books = new ArrayList<>();
    private final List<String> translationIds = new ArrayList<>();
    private final List<String> translationNames = new ArrayList<>();
    private String translationName = "";
    private Book book;
    private int chapter;
    private final TreeSet<Integer> picked = new TreeSet<>();
    /// Коли вірші востаннє вибирали тут. Відповідь програми приходить із
    /// запізненням, і без цієї позначки свіже торкання перебивалося б старим
    /// станом — вибір «відскакував» би назад.
    private long touched;
    private boolean loaded;
    private String noteText = "";
    /// Пошук за словами: поки `query` не порожній, замість віршів — знайдене.
    private String query = "", lastQuery = "";

    private final Ui.Rows<Verse> verses = new Ui.Rows<Verse>() {
        @Override
        String title(Verse v) { return v.text; }

        @Override
        String badge(Verse v) { return String.valueOf(v.number); }

        @Override
        boolean chosen(int position) { return picked.contains(items.get(position).number); }
    };

    private final Ui.Rows<Hit> hits = new Ui.Rows<Hit>() {
        @Override
        String title(Hit h) { return h.reference; }

        @Override
        String sub(Hit h) { return h.text; }

        @Override
        int color(Hit h) { return Ui.ACCENT; }
    };

    BibleBrowser(Activity activity, Host host) {
        this.activity = activity;
        this.host = host;
    }

    /// Скласти вид розділу (наново — після повороту, зміни масштабу чи мови; стан живе в полях).
    View build() {
        LinearLayout root = Ui.col(activity);
        // Шлях: переклад → книга → розділ. Кожна ланка відкриває свій вибір.
        LinearLayout path = Ui.row(activity);
        path.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), 0);
        translationButton = Ui.button(activity, "", Ui.CARD2, this::chooseTranslation);
        bookButton = Ui.button(activity, "", Ui.CARD2, this::pickBook);
        chapterButton = Ui.button(activity, "", Ui.CARD2, () -> pickChapter(book));
        for (TextView b : new TextView[] {translationButton, bookButton, chapterButton}) {
            b.setMaxLines(1);
            b.setPadding(Ui.dp(8), 0, Ui.dp(8), 0);
        }
        Ui.explain(translationButton, Lang.t("Змінити переклад Біблії", "Change the Bible translation"));
        Ui.explain(bookButton, Lang.t("Вибрати книгу", "Pick a book"));
        Ui.explain(chapterButton, Lang.t("Вибрати розділ", "Pick a chapter"));
        path.addView(translationButton, Ui.lp(0, Ui.dp(46), 1.1f, 3));
        path.addView(bookButton, Ui.lp(0, Ui.dp(46), 1.35f, 3));
        path.addView(Ui.iconButton(activity, R.drawable.ic_left, Ui.CARD2, () -> moveChapter(-1)), Ui.lp(Ui.dp(40), Ui.dp(46), 0, 3));
        path.addView(chapterButton, Ui.lp(0, Ui.dp(46), 0.62f, 3));
        path.addView(Ui.iconButton(activity, R.drawable.ic_right, Ui.CARD2, () -> moveChapter(1)), Ui.lp(Ui.dp(40), Ui.dp(46), 0, 3));

        LinearLayout find = Ui.row(activity);
        find.setPadding(Ui.dp(8), 0, Ui.dp(8), Ui.dp(2));
        address = Ui.search(activity, Lang.t("Адреса: Ів 3:16", "Reference: John 3:16"));
        address.setImeOptions(EditorInfo.IME_ACTION_GO);
        address.setOnEditorActionListener((v, action, e) -> {
            go(address.getText().toString());
            Ui.hideKeyboard(address);
            return true;
        });
        find.addView(address, Ui.lp(0, Ui.dp(46), 1, 3));
        TextView words = Ui.button(activity, R.drawable.ic_text, Lang.t("Слова", "Words"), Ui.CARD2, this::askWords);
        Ui.explain(words, Lang.t("Знайти вірші за словами в усьому перекладі", "Find verses by words in the whole translation"));
        find.addView(words, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));

        LinearLayout info = Ui.row(activity);
        info.setGravity(Gravity.CENTER_VERTICAL);
        info.setPadding(Ui.dp(14), 0, Ui.dp(10), 0);
        note = Ui.label(activity, "", 12.5f, Ui.DIM);
        note.setLineSpacing(Ui.dp(1), 1f);
        note.setPadding(0, Ui.dp(4), Ui.dp(8), Ui.dp(4));
        info.addView(note, Ui.lp(0, Ui.WRAP, 1));
        clear = Ui.chip(activity, R.drawable.ic_close, "", this::clearTapped);
        clear.setMinHeight(Ui.dp(32));
        info.addView(clear, Ui.lp(Ui.WRAP, Ui.dp(32), 0, 0, 2, 0, 2));

        list = Ui.list(activity, verses);
        list.setOnItemClickListener((parent, view, position, id) -> rowTapped(position));
        list.setOnItemLongClickListener((parent, view, position, id) -> rowHeld(position));
        body = new FrameLayout(activity);
        body.addView(list, Ui.fill());
        empty = Ui.empty(activity, R.drawable.ic_bible, Lang.t("Біблію ще не відкрито", "The Bible is not open yet"),
            activity.getString(R.string.bible_no_books), Lang.t("Спробувати ще", "Try again"), this::reload);
        empty.setVisibility(View.GONE);
        body.addView(empty, Ui.fill());

        root.addView(path);
        root.addView(find);
        root.addView(info, Ui.lp(Ui.FILL, Ui.WRAP, 0));
        root.addView(body, Ui.lp(Ui.FILL, 0, 1));
        render();
        return root;
    }

    /// Розділ відкрили. Уперше — стаємо туди, де зараз стоїть програма;
    /// далі — там, де людина лишила розділ.
    void open() {
        if (!loaded) reload(); else render();
    }

    /// Перечитати книги і стати на місце програми — після адреси, набраної
    /// руками, і після зміни перекладу.
    void reload() {
        loadBooks(true);
    }

    /// Перемалювати (увімкнули чи сховали підказки).
    void refresh() { render(); }

    /// Чи є що виводити кнопкою «Показати».
    boolean hasPicked() { return query.isEmpty() && book != null && !picked.isEmpty(); }

    /// Вибрані вірші — в зал.
    void showPicked() { send(true); }

    /// «Назад»: з результатів пошуку — до віршів. `false` — тут нічого закривати.
    boolean back() {
        if (query.isEmpty()) return false;
        closeSearch();
        return true;
    }

    // MARK: Дані

    private void loadBooks(boolean follow) {
        Api api = host.api();
        if (api == null) return;
        note(activity.getString(R.string.bible_loading));
        host.queue().execute(() -> {
            try {
                JSONObject json = api.bibleBooks();
                host.post(() -> {
                    accept(json);
                    note("");
                    JSONObject current = json == null ? null : json.optJSONObject("current");
                    if (follow && current != null && jump(current)) return;
                    render();
                });
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void accept(JSONObject json) {
        books.clear();
        translationIds.clear();
        translationNames.clear();
        if (json == null) return;
        loaded = true;
        JSONObject translation = json.optJSONObject("translation");
        translationName = translation == null ? "" : translation.optString("name", "");
        JSONArray all = json.optJSONArray("translations");
        if (all != null) {
            for (int i = 0; i < all.length(); i++) {
                JSONObject item = all.optJSONObject(i);
                if (item == null) continue;
                translationIds.add(item.optString("id", ""));
                translationNames.add(item.optString("name", ""));
            }
        }
        JSONArray found = json.optJSONArray("books");
        if (found != null) {
            for (int i = 0; i < found.length(); i++) {
                JSONObject item = found.optJSONObject(i);
                if (item == null) continue;
                books.add(new Book(item.optInt("position", i), item.optString("name", ""),
                                   Math.max(1, item.optInt("chapters", 1)), item.optString("testament", "other")));
            }
        }
        // Книга, на якій стояли, могла зникнути разом зі старим перекладом.
        if (book != null) {
            Book same = null;
            for (Book item : books) if (item.position == book.position) same = item;
            book = same;
            if (same == null) {
                chapter = 0;
                picked.clear();
                verses.set(null);
            }
        }
    }

    /// Стати на місце, яке програма показує зараз.
    private boolean jump(JSONObject current) {
        int position = current.optInt("book", -1);
        Book target = null;
        for (Book item : books) {
            if (item.position == position) {
                target = item;
                break;
            }
        }
        if (target == null) return false;
        List<Integer> chosen = new ArrayList<>();
        JSONArray numbers = current.optJSONArray("verses");
        if (numbers != null) for (int i = 0; i < numbers.length(); i++) chosen.add(numbers.optInt(i));
        openChapter(target, Math.max(1, current.optInt("chapter", 1)), chosen);
        return true;
    }

    /// Іти за програмою: вірш перемкнули не звідси.
    ///
    /// Власник: «у планшеті при перемиканні тексту сам текст перемикається, а
    /// виділений текст лишається на старому місці». Підсвічення переїжджає
    /// слідом за програмою, а список підводиться до нього.
    void follow(int position, int chapterNumber, String numbers) {
        if (!loaded || !query.isEmpty() || chapterNumber <= 0) return;
        if (System.currentTimeMillis() - touched < 1500) return;
        List<Integer> chosen = new ArrayList<>();
        for (String part : numbers.split(",")) {
            String text = part.trim();
            if (text.isEmpty()) continue;
            try { chosen.add(Integer.parseInt(text)); } catch (NumberFormatException ignored) { }
        }
        if (book == null || book.position != position || chapter != chapterNumber) {
            for (Book item : books) {
                if (item.position != position) continue;
                openChapter(item, chapterNumber, chosen);
                return;
            }
            return;
        }
        if (picked.size() == chosen.size() && picked.containsAll(chosen)) return;
        picked.clear();
        picked.addAll(chosen);
        render();
        scrollToPicked();
    }

    /// Підвести список до першого вибраного вірша.
    private void scrollToPicked() {
        if (picked.isEmpty() || list == null) return;
        for (int i = 0; i < verses.items.size(); i++) {
            if (verses.items.get(i).number != picked.first()) continue;
            list.setSelection(Math.max(0, i - 1));
            return;
        }
    }

    private void openChapter(Book target, int number, List<Integer> chosen) {
        if (target == null) return;
        Api api = host.api();
        if (api == null) return;
        note(activity.getString(R.string.bible_loading));
        host.queue().execute(() -> {
            try {
                JSONObject json = api.bibleChapter(target.position, number);
                host.post(() -> {
                    List<Verse> fresh = new ArrayList<>();
                    JSONArray items = json == null ? null : json.optJSONArray("verses");
                    if (items != null) {
                        for (int i = 0; i < items.length(); i++) {
                            JSONObject item = items.optJSONObject(i);
                            if (item == null) continue;
                            fresh.add(new Verse(item.optInt("number"), item.optString("text", "")));
                        }
                    }
                    book = target;
                    chapter = number;
                    picked.clear();
                    for (Verse verse : fresh) if (chosen.contains(verse.number)) picked.add(verse.number);
                    verses.set(fresh);
                    note("");
                    render();
                    // До першого вибраного: на довгому розділі він інакше
                    // лишається за краєм екрана.
                    if (list != null) {
                        list.setSelection(0);
                        scrollToPicked();
                    }
                });
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void moveChapter(int delta) {
        if (book == null || !query.isEmpty()) return;
        int next = chapter + delta;
        if (next < 1 || next > book.chapters) return;
        touched = System.currentTimeMillis();
        openChapter(book, next, new ArrayList<>());
    }

    // MARK: Дії

    private void rowTapped(int position) {
        list.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
        if (!query.isEmpty()) {
            if (position < 0 || position >= hits.items.size()) return;
            hit(hits.items.get(position), false);
            hits.select(position);
            return;
        }
        if (position < 0 || position >= verses.items.size()) return;
        int number = verses.items.get(position).number;
        touched = System.currentTimeMillis();
        if (picked.contains(number)) picked.remove(number); else picked.add(number);
        render();
        send(false);
    }

    /// Довге торкання — відрізок від першого вибраного до цього вірша; у знайденому
    /// пошуком — те саме, що дотик: у передпоказ. У зал — лише «Показати» (власник 27.11:
    /// «показ слайдов и текстов происходить должен исключительно по кнопке показа»).
    private boolean rowHeld(int position) {
        if (!query.isEmpty()) {
            if (position < 0 || position >= hits.items.size()) return false;
            list.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            hit(hits.items.get(position), false);
            hits.select(position);
            return true;
        }
        if (position < 0 || position >= verses.items.size()) return false;
        list.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        touched = System.currentTimeMillis();
        int number = verses.items.get(position).number;
        if (picked.isEmpty()) {
            picked.add(number);
        } else {
            int from = Math.min(picked.first(), number);
            int to = Math.max(picked.last(), number);
            for (Verse verse : verses.items) if (verse.number >= from && verse.number <= to) picked.add(verse.number);
        }
        render();
        send(false);
        return true;
    }

    /// Вибране — у передпоказ програми або одразу в зал.
    private void send(boolean live) {
        Api api = host.api();
        if (api == null || book == null || picked.isEmpty()) return;
        final int position = book.position;
        final int number = chapter;
        final List<Integer> chosen = new ArrayList<>(picked);
        final String where = book.name + " " + number + ":" + span(chosen);
        host.queue().execute(() -> {
            try {
                api.bibleSelect(position, number, chosen, live);
                // Вдалося — стара скарга («Read timed out») більше не до речі.
                host.post(() -> note(live ? activity.getString(R.string.bible_shown, where) : ""));
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void clearTapped() {
        if (!query.isEmpty()) {
            closeSearch();
            return;
        }
        touched = System.currentTimeMillis();
        picked.clear();
        render();
    }

    /// Перейти за адресою: програма стає на неї, щойно прочитає розділи; тоді
    /// й перегляд тут переходить туди ж.
    private void go(String text) {
        String where = text.trim();
        Api api = host.api();
        if (where.isEmpty() || api == null) return;
        if (!query.isEmpty()) {
            query = "";
            render();
        }
        host.queue().execute(() -> {
            try {
                // Адреса — у передпоказ, у зал — «Показати». `live` «Слово» до 1.4.4 не знає.
                JSONObject body = new JSONObject();
                body.put("text", where);
                body.put("live", false);
                api.command("goto", body);
                host.post(() -> list.postDelayed(this::reload, 600));
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void chooseTranslation() {
        if (translationNames.isEmpty()) {
            reload();
            return;
        }
        int checked = translationNames.indexOf(translationName);
        // Останній рядок — загальна база «Слова»: поставити в програму ще переклади.
        List<String> names = new ArrayList<>(translationNames);
        names.add(Lang.t("＋ Завантажити ще переклади…", "＋ Download more translations…"));
        Ui.pick(activity, activity.getString(R.string.bible_translation), names.toArray(new String[0]), checked, which -> {
            if (which == translationNames.size()) {
                ResourcesActivity.open(activity, "bible");
                return;
            }
            Api api = host.api();
            if (api == null || which < 0 || which >= translationIds.size()) return;
            String id = translationIds.get(which);
            host.queue().execute(() -> {
                try {
                    api.command("bible-translation", id);
                    host.post(this::reload);
                } catch (Exception error) {
                    host.post(() -> note(reason(error)));
                }
            });
        });
    }

    /// Книги — сіткою у вікні знизу: Старий Заповіт синім, Новий зеленим, решта сірим.
    private void pickBook() {
        if (books.isEmpty()) {
            reload();
            return;
        }
        GridView grid = grid(96);
        Dialog[] dialog = new Dialog[1];
        grid.setAdapter(new BaseAdapter() {
            @Override
            public int getCount() { return books.size(); }

            @Override
            public Object getItem(int i) { return books.get(i); }

            @Override
            public long getItemId(int i) { return i; }

            @Override
            public View getView(int i, View convert, ViewGroup parent) {
                TextView t = convert instanceof TextView ? (TextView) convert : Ui.label(activity, "", 13, Ui.TEXT);
                Book b = books.get(i);
                t.setText(b.name);
                t.setGravity(Gravity.CENTER);
                t.setMaxLines(2);
                t.setMinHeight(Ui.dp(46));
                t.setPadding(Ui.dp(3), Ui.dp(3), Ui.dp(3), Ui.dp(3));
                int color = book != null && b.position == book.position ? Ui.ACCENT
                    : "new".equals(b.testament) ? 0xFF173A30 : "old".equals(b.testament) ? 0xFF1B2B4A : Ui.CARD2;
                t.setBackground(Ui.round(color, 10));
                return t;
            }
        });
        grid.setOnItemClickListener((p, v, i, id) -> {
            dialog[0].dismiss();
            Book chosen = books.get(i);
            // Книга з одного розділу — одразу до віршів: вибирати там нема з чого.
            if (chosen.chapters == 1) openChapter(chosen, 1, new ArrayList<>());
            else pickChapter(chosen);
        });
        dialog[0] = Ui.sheet(activity, activity.getString(R.string.bible_books), grid);
    }

    private void pickChapter(Book target) {
        if (target == null) {
            pickBook();
            return;
        }
        GridView grid = grid(52);
        Dialog[] dialog = new Dialog[1];
        grid.setAdapter(new BaseAdapter() {
            @Override
            public int getCount() { return target.chapters; }

            @Override
            public Object getItem(int i) { return i + 1; }

            @Override
            public long getItemId(int i) { return i; }

            @Override
            public View getView(int i, View convert, ViewGroup parent) {
                TextView t = convert instanceof TextView ? (TextView) convert : Ui.label(activity, "", 16, Ui.TEXT);
                t.setText(String.valueOf(i + 1));
                t.setGravity(Gravity.CENTER);
                t.setMinHeight(Ui.dp(46));
                t.setTypeface(Typeface.DEFAULT_BOLD);
                boolean current = book != null && book.position == target.position && i + 1 == chapter;
                t.setBackground(Ui.round(current ? Ui.ACCENT : Ui.CARD2, 10));
                return t;
            }
        });
        grid.setOnItemClickListener((p, v, i, id) -> {
            dialog[0].dismiss();
            touched = System.currentTimeMillis();
            if (!query.isEmpty()) query = "";
            openChapter(target, i + 1, new ArrayList<>());
        });
        dialog[0] = Ui.sheet(activity, target.name + " — " + activity.getString(R.string.bible_pick_chapter).toLowerCase(java.util.Locale.ROOT), grid);
    }

    private GridView grid(int columnDp) {
        GridView grid = new GridView(activity);
        grid.setNumColumns(GridView.AUTO_FIT);
        grid.setColumnWidth(Ui.dp(columnDp));
        grid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        grid.setHorizontalSpacing(Ui.dp(4));
        grid.setVerticalSpacing(Ui.dp(4));
        grid.setPadding(Ui.dp(8), Ui.dp(8), Ui.dp(8), Ui.dp(8));
        grid.setSelector(new android.graphics.drawable.ColorDrawable(0x22FFFFFF));
        return grid;
    }

    // MARK: Пошук за словами

    private void askWords() {
        Ui.prompt(activity, Lang.t("Пошук словами в перекладі", "Search the translation by words"), lastQuery, false, text -> {
            String wanted = text.trim();
            if (!wanted.isEmpty()) runSearch(wanted);
        });
    }

    private void runSearch(String wanted) {
        Api api = host.api();
        if (api == null) return;
        lastQuery = wanted;
        query = wanted;
        hits.set(null);
        hits.selected = -1;
        note(Lang.t("Шукаю «" + wanted + "»…", "Searching for “" + wanted + "”…"));
        render();
        host.queue().execute(() -> {
            try {
                JSONObject body = new JSONObject();
                body.put("text", wanted);
                api.command("bible-search", body);
                host.post(() -> pollSearch(wanted, 0));
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    /// Поки програма шукає — чекаємо до хвилини: перший пошук на зайнятому
    /// комп'ютері буває довшим за 20 с, і без цього тут писало «нічого не
    /// знайдено», хоча пошук ще йшов.
    private void pollSearch(String wanted, int attempt) {
        Api api = host.api();
        if (api == null || !wanted.equals(query)) return;
        host.queue().execute(() -> {
            try {
                JSONObject json = api.get("/api/search");
                host.post(() -> {
                    if (!wanted.equals(query)) return;
                    boolean searching = json.optBoolean("searching", false);
                    if (searching && attempt < 150) {
                        if (list != null) list.postDelayed(() -> pollSearch(wanted, attempt + 1), 400);
                        return;
                    }
                    if (searching) {
                        note(Lang.t("Програма ще шукає «" + wanted + "» — спробуйте ще раз за хвилину",
                                    "Slovo is still searching for “" + wanted + "” — try again in a minute"));
                        return;
                    }
                    List<Hit> found = new ArrayList<>();
                    JSONArray all = json.optJSONArray("hits");
                    if (all != null) {
                        for (int i = 0; i < all.length(); i++) {
                            JSONObject one = all.optJSONObject(i);
                            if (one == null) continue;
                            found.add(new Hit(one.optInt("index", i), one.optString("reference", ""), one.optString("text", "")));
                        }
                    }
                    hits.set(found);
                    note(found.isEmpty()
                        ? Lang.t("За «" + wanted + "» нічого не знайдено", "Nothing found for “" + wanted + "”")
                        : Lang.t("«" + wanted + "»: " + found.size() + ". Дотик — у передпоказ; у зал — «Показати»",
                                 "“" + wanted + "”: " + found.size() + ". Tap to preview; “Show” puts it in the hall"));
                    render();
                });
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void hit(Hit found, boolean live) {
        Api api = host.api();
        if (api == null) return;
        host.queue().execute(() -> {
            try {
                JSONObject body = new JSONObject();
                body.put("index", found.index);
                body.put("live", live);
                api.command("search-hit", body);
            } catch (JSONException ignored) {
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void closeSearch() {
        query = "";
        note("");
        render();
        reload();
    }

    // MARK: Вигляд

    private void render() {
        if (list == null) return;
        Ui.setText(translationButton, translationName.isEmpty() ? activity.getString(R.string.bible_translation) : translationName);
        Ui.setText(bookButton, book == null ? activity.getString(R.string.bible_books) : book.name);
        Ui.setText(chapterButton, book == null || chapter <= 0 ? "—" : String.valueOf(chapter));
        boolean searching = !query.isEmpty();
        BaseAdapter wanted = searching ? hits : verses;
        if (list.getAdapter() != wanted) list.setAdapter(wanted);
        else wanted.notifyDataSetChanged();
        boolean nothing = !searching && loaded && books.isEmpty();
        empty.setVisibility(nothing ? View.VISIBLE : View.GONE);
        list.setVisibility(nothing ? View.GONE : View.VISIBLE);
        if (searching) {
            Ui.chipState(clear, Lang.t("До віршів", "Back to verses"), false, Ui.ACCENT);
            clear.setVisibility(View.VISIBLE);
        } else if (!picked.isEmpty()) {
            Ui.chipState(clear, Lang.t("Вибрано: ", "Picked: ") + picked.size(), true, Ui.WARN);
            clear.setVisibility(View.VISIBLE);
        } else {
            clear.setVisibility(View.GONE);
        }
        showNote();
    }

    private void note(String text) {
        noteText = text == null ? "" : text;
        showNote();
    }

    /// Рядок під пошуком: повідомлення, а коли його немає — підказка, що робити.
    private void showNote() {
        if (note == null) return;
        String shown = noteText;
        if (shown.isEmpty() && query.isEmpty()) {
            if (book == null && loaded && !books.isEmpty()) shown = Lang.t("Виберіть книгу й розділ", "Pick a book and a chapter");
            else if (book != null && picked.isEmpty() && new Settings(activity).hints()) {
                shown = Lang.t("Торкніться віршів — вони підсвітяться й підуть у передпоказ. Довге торкання — відрізок. «Показати» виведе їх на стіну.",
                               "Tap verses — they light up and go to the preview. A long tap picks a range. “Show” puts them on the wall.");
            }
        }
        note.setText(shown);
        boolean visible = !shown.isEmpty() || clear.getVisibility() == View.VISIBLE;
        ((View) note.getParent()).setVisibility(visible ? View.VISIBLE : View.GONE);
    }

    private static String reason(Exception error) {
        String text = error.getMessage();
        return text == null || text.isEmpty() ? error.toString() : text;
    }

    /// «1-3,5» — так, як пишуть адресу.
    private static String span(List<Integer> numbers) {
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < numbers.size()) {
            int start = numbers.get(i);
            int end = start;
            while (i + 1 < numbers.size() && numbers.get(i + 1) == end + 1) end = numbers.get(++i);
            if (out.length() > 0) out.append(',');   // як у програмі: «3:16-17,19», без пробілу
            out.append(start == end ? String.valueOf(start) : start + "-" + end);
            i++;
        }
        return out.toString();
    }
}
