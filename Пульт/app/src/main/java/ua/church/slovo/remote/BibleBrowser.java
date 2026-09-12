package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.GridView;
import android.widget.ListView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;
import java.util.concurrent.ExecutorService;

/// Вкладка «Біблія»: переклад → книга → розділ → вірші з текстом.
///
/// Власник: «добавить полноценную функцию вывода текста Библии (сейчас
/// подобие функции есть, но оно не понятное и не рабочее)». Доти тут був
/// рядок для адреси й два рядки «попередній / наступний розділ»: щоб вивести
/// вірш, треба було знати, як його записати. Тепер місце вибирають так, як
/// у програмі, — книга, розділ, вірші — і бачать текст раніше, ніж він піде
/// на стіну.
///
/// Торкання вірша підсвічує його й кладе в передпоказ програми; ще кілька
/// торкань — кілька віршів; довге торкання — відрізок від першого
/// вибраного. «Показати в залі» виводить вибране на стіну.
final class BibleBrowser {

    interface Host {
        Api api();
        ExecutorService queue();
        void post(Runnable body);
    }

    private enum Level { BOOKS, CHAPTERS, VERSES }

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

    private final Activity activity;
    private final Host host;
    private final Button translationButton;
    private final TextView path;
    private final TextView note;
    private final ListView list;
    private final GridView grid;
    private final View actions;
    private final Button showButton;

    private final List<Book> books = new ArrayList<>();
    /// Рядки списку книг: заголовок розділу — рядок, книга — `Book`.
    private final List<Object> bookRows = new ArrayList<>();
    private final List<String> translationIds = new ArrayList<>();
    private final List<String> translationNames = new ArrayList<>();
    private String translationName = "";
    private Level level = Level.BOOKS;
    private Book book;
    private int chapter;
    /// Книга, з якої відкрито `chapter`, — щоб у сітці підсвічувати розділ
    /// лише своєї книги.
    private int chapterBook = -1;
    private final List<Verse> verses = new ArrayList<>();
    private final TreeSet<Integer> picked = new TreeSet<>();
    /// Коли вірші востаннє вибирали тут. Відповідь програми приходить із
    /// запізненням, і без цієї позначки свіже торкання перебивалося б старим
    /// станом — вибір «відскакував» би назад.
    private long touched;
    private boolean loaded;
    private ColorStateList plainText;

    private final BaseAdapter booksAdapter = new BooksAdapter();
    private final BaseAdapter versesAdapter = new VersesAdapter();
    private final BaseAdapter chaptersAdapter = new ChaptersAdapter();

    BibleBrowser(Activity activity, Host host, View root) {
        this.activity = activity;
        this.host = host;
        translationButton = root.findViewById(R.id.bibleTranslation);
        path = root.findViewById(R.id.biblePath);
        note = root.findViewById(R.id.bibleNote);
        list = root.findViewById(R.id.bibleList);
        grid = root.findViewById(R.id.bibleGrid);
        actions = root.findViewById(R.id.bibleActions);
        showButton = root.findViewById(R.id.bibleShow);
        Button clearButton = root.findViewById(R.id.bibleClear);

        grid.setAdapter(chaptersAdapter);
        list.setOnItemClickListener((parent, view, position, id) -> rowTapped(position));
        list.setOnItemLongClickListener((parent, view, position, id) -> rowHeld(position));
        grid.setOnItemClickListener((parent, view, position, id) -> openChapter(book, position + 1, new ArrayList<>()));
        path.setOnClickListener(v -> back());
        translationButton.setOnClickListener(v -> chooseTranslation());
        showButton.setOnClickListener(v -> send(true));
        clearButton.setOnClickListener(v -> {
            touched = System.currentTimeMillis();
            picked.clear();
            render();
        });
    }

    /// Вкладку відкрили. Уперше — стаємо туди, де зараз стоїть програма;
    /// далі — там, де людина лишила вкладку.
    void open() {
        if (!loaded) reload(); else render();
    }

    /// Перечитати книги і стати на місце програми — після адреси, набраної
    /// руками, і після зміни перекладу.
    void reload() {
        loadBooks(true);
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
                    JSONObject current = json == null ? null : json.optJSONObject("current");
                    if (follow && current != null && jump(current)) return;
                    level = Level.BOOKS;
                    render();
                });
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void accept(JSONObject json) {
        books.clear();
        bookRows.clear();
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
        // Розділи — як у програмі: Старий Заповіт, Новий, решта.
        String[][] groups = {
            {"old", activity.getString(R.string.bible_old)},
            {"new", activity.getString(R.string.bible_new)},
            {"other", activity.getString(R.string.bible_other)},
        };
        for (String[] group : groups) {
            boolean header = false;
            for (Book item : books) {
                if (!item.testament.equals(group[0])) continue;
                if (!header) {
                    bookRows.add(group[1]);
                    header = true;
                }
                bookRows.add(item);
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
    /// виділений текст лишається на старому місці». Розділ малювався один раз
    /// — при відкритті вкладки, — і далі жив своїм життям. Тепер підсвічення
    /// переїжджає слідом за програмою, а список підводиться до нього.
    void follow(int position, int chapterNumber, String numbers) {
        if (!loaded || level != Level.VERSES || chapterNumber <= 0) return;
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
        if (picked.isEmpty()) return;
        for (int i = 0; i < verses.size(); i++) {
            if (verses.get(i).number != picked.first()) continue;
            list.setSelection(Math.max(0, i - 1));
            return;
        }
    }

    private void openChapter(Book target, int number, List<Integer> chosen) {
        if (target == null) return;
        Api api = host.api();
        if (api == null) return;
        book = target;
        note(activity.getString(R.string.bible_loading));
        host.queue().execute(() -> {
            try {
                JSONObject json = api.bibleChapter(target.position, number);
                host.post(() -> {
                    verses.clear();
                    JSONArray items = json == null ? null : json.optJSONArray("verses");
                    if (items != null) {
                        for (int i = 0; i < items.length(); i++) {
                            JSONObject item = items.optJSONObject(i);
                            if (item == null) continue;
                            verses.add(new Verse(item.optInt("number"), item.optString("text", "")));
                        }
                    }
                    chapter = number;
                    chapterBook = target.position;
                    level = Level.VERSES;
                    picked.clear();
                    for (Verse verse : verses) if (chosen.contains(verse.number)) picked.add(verse.number);
                    render();
                    // До першого вибраного: на довгому розділі він інакше
                    // лишається за краєм екрана.
                    int first = 0;
                    if (!picked.isEmpty()) {
                        for (int i = 0; i < verses.size(); i++) {
                            if (verses.get(i).number == picked.first()) {
                                first = Math.max(0, i - 1);
                                break;
                            }
                        }
                    }
                    list.setSelection(first);
                });
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    // MARK: Дії

    private void rowTapped(int position) {
        list.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
        if (level == Level.BOOKS) {
            if (position < 0 || position >= bookRows.size()) return;
            Object row = bookRows.get(position);
            if (!(row instanceof Book)) return;
            book = (Book) row;
            // Книга з одного розділу — одразу до віршів: вибирати там нема з чого.
            if (book.chapters == 1) {
                openChapter(book, 1, new ArrayList<>());
                return;
            }
            level = Level.CHAPTERS;
            render();
            return;
        }
        if (level == Level.VERSES) {
            if (position < 0 || position >= verses.size()) return;
            int number = verses.get(position).number;
            touched = System.currentTimeMillis();
            if (picked.contains(number)) picked.remove(number); else picked.add(number);
            render();
            send(false);
        }
    }

    /// Довге торкання — відрізок від першого вибраного до цього вірша.
    private boolean rowHeld(int position) {
        if (level != Level.VERSES || position < 0 || position >= verses.size()) return false;
        list.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
        touched = System.currentTimeMillis();
        int number = verses.get(position).number;
        if (picked.isEmpty()) {
            picked.add(number);
        } else {
            int from = Math.min(picked.first(), number);
            int to = Math.max(picked.last(), number);
            for (Verse verse : verses) if (verse.number >= from && verse.number <= to) picked.add(verse.number);
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
                if (live) host.post(() -> note(activity.getString(R.string.bible_shown, where)));
            } catch (Exception error) {
                host.post(() -> note(reason(error)));
            }
        });
    }

    private void back() {
        if (level == Level.VERSES) {
            level = book != null && book.chapters > 1 ? Level.CHAPTERS : Level.BOOKS;
        } else if (level == Level.CHAPTERS) {
            level = Level.BOOKS;
        }
        render();
    }

    private void chooseTranslation() {
        if (translationNames.isEmpty()) {
            reload();
            return;
        }
        String[] names = translationNames.toArray(new String[0]);
        new AlertDialog.Builder(activity)
            .setTitle(R.string.bible_translation)
            .setItems(names, (dialog, which) -> {
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
            })
            .show();
    }

    // MARK: Вигляд

    private void render() {
        translationButton.setText(translationName.isEmpty()
            ? activity.getString(R.string.bible_translation) : translationName);
        boolean chapters = level == Level.CHAPTERS;
        grid.setVisibility(chapters ? View.VISIBLE : View.GONE);
        list.setVisibility(chapters ? View.GONE : View.VISIBLE);
        actions.setVisibility(level == Level.VERSES ? View.VISIBLE : View.GONE);
        switch (level) {
            case BOOKS:
                path.setText(activity.getString(R.string.bible_books));
                if (list.getAdapter() != booksAdapter) list.setAdapter(booksAdapter);
                booksAdapter.notifyDataSetChanged();
                note(books.isEmpty() ? activity.getString(R.string.bible_no_books) : "");
                break;
            case CHAPTERS:
                path.setText("‹  " + (book == null ? "" : book.name));
                chaptersAdapter.notifyDataSetChanged();
                note(activity.getString(R.string.bible_pick_chapter));
                break;
            case VERSES:
                path.setText("‹  " + (book == null ? "" : book.name) + " · "
                    + activity.getString(R.string.bible_chapter_n, chapter));
                if (list.getAdapter() != versesAdapter) list.setAdapter(versesAdapter);
                versesAdapter.notifyDataSetChanged();
                showButton.setEnabled(!picked.isEmpty());
                showButton.setText(picked.isEmpty() ? activity.getString(R.string.bible_show)
                    : activity.getString(R.string.bible_show_count, picked.size()));
                note(picked.isEmpty() ? activity.getString(R.string.bible_pick_hint) : "");
                break;
        }
    }

    private void note(String text) {
        note.setText(text);
        note.setVisibility(text == null || text.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private static String reason(Exception error) {
        String text = error.getMessage();
        return text == null || text.isEmpty() ? error.toString() : text;
    }

    /// «1-3, 5» — так, як пишуть адресу.
    private static String span(List<Integer> numbers) {
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < numbers.size()) {
            int start = numbers.get(i);
            int end = start;
            while (i + 1 < numbers.size() && numbers.get(i + 1) == end + 1) end = numbers.get(++i);
            if (out.length() > 0) out.append(", ");
            out.append(start == end ? String.valueOf(start) : start + "-" + end);
            i++;
        }
        return out.toString();
    }

    private int dp(int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }

    private View row(View recycled, ViewGroup parent) {
        View view = recycled != null ? recycled
            : activity.getLayoutInflater().inflate(R.layout.row_item, parent, false);
        TextView title = view.findViewById(R.id.title);
        if (plainText == null) plainText = title.getTextColors();
        return view;
    }

    // MARK: Адаптери

    private final class BooksAdapter extends BaseAdapter {
        @Override public int getCount() { return bookRows.size(); }
        @Override public Object getItem(int position) { return bookRows.get(position); }
        @Override public long getItemId(int position) { return position; }
        @Override public boolean areAllItemsEnabled() { return false; }
        @Override public boolean isEnabled(int position) { return bookRows.get(position) instanceof Book; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            View view = row(recycled, parent);
            TextView title = view.findViewById(R.id.title);
            TextView subtitle = view.findViewById(R.id.subtitle);
            Object item = bookRows.get(position);
            if (item instanceof Book) {
                Book entry = (Book) item;
                title.setText(entry.name);
                title.setTypeface(Typeface.DEFAULT);
                title.setTextColor(plainText);
                subtitle.setText(activity.getString(R.string.bible_chapters, entry.chapters));
                subtitle.setVisibility(View.VISIBLE);
                view.setBackgroundColor(book != null && book.position == entry.position
                    ? Color.parseColor("#1E3A5F") : Color.TRANSPARENT);
            } else {
                title.setText(String.valueOf(item));
                title.setTypeface(Typeface.DEFAULT_BOLD);
                title.setTextColor(Color.parseColor("#4C8DFF"));
                subtitle.setText("");
                subtitle.setVisibility(View.GONE);
                view.setBackgroundColor(Color.TRANSPARENT);
            }
            return view;
        }
    }

    private final class VersesAdapter extends BaseAdapter {
        @Override public int getCount() { return verses.size(); }
        @Override public Object getItem(int position) { return verses.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            View view = row(recycled, parent);
            TextView title = view.findViewById(R.id.title);
            TextView subtitle = view.findViewById(R.id.subtitle);
            Verse verse = verses.get(position);
            // Номер — синім і жирним: по ньому око шукає вірш.
            String number = String.valueOf(verse.number);
            SpannableString text = new SpannableString(number + "  " + verse.text);
            text.setSpan(new StyleSpan(Typeface.BOLD), 0, number.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            text.setSpan(new ForegroundColorSpan(Color.parseColor("#4C8DFF")), 0, number.length(),
                         Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            title.setText(text);
            title.setTypeface(Typeface.DEFAULT);
            title.setTextColor(plainText);
            subtitle.setText("");
            subtitle.setVisibility(View.GONE);
            view.setBackgroundColor(picked.contains(verse.number)
                ? Color.parseColor("#23466E") : Color.TRANSPARENT);
            return view;
        }
    }

    private final class ChaptersAdapter extends BaseAdapter {
        @Override public int getCount() { return book == null ? 0 : book.chapters; }
        @Override public Object getItem(int position) { return position + 1; }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            TextView cell = recycled instanceof TextView ? (TextView) recycled : new TextView(activity);
            cell.setText(String.valueOf(position + 1));
            cell.setGravity(Gravity.CENTER);
            cell.setTextSize(18);
            cell.setPadding(0, dp(12), 0, dp(12));
            cell.setTextColor(Color.parseColor("#E6EDF3"));
            boolean current = book != null && chapterBook == book.position && position + 1 == chapter;
            cell.setBackgroundColor(Color.parseColor(current ? "#1E3A5F" : "#1B2430"));
            return cell;
        }
    }
}
