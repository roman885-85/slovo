package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// План проповіді.
///
/// Власник: «проповедник заранее выбирает стихи из писания, которые он будет
/// использовать, презентацию или другой материал. Затем прийдя на служение
/// подключается, и когда выходит за кафедру нажимает кнопку загрузки плана
/// проповеди и весь план уже в основной программе и проповедник с планшета
/// выполняет управление показом слайдов».
///
/// Тому план складається тут без жодного зв'язку з програмою: переклади й
/// пісенники — зі своєї бібліотеки планшета (`Library`), файли — копіями в
/// пам'яті планшета. Зв'язок потрібен лише двічі: взяти модулі зі «Слова» і
/// на служінні відправити план. Тоді ж планшет довозить програмі переклади й
/// пісенники, яких у неї немає, — вона ставить їх собі сама.
public final class SermonActivity extends Activity {

    private static final int ACCENT = 0xFF4C8DFF;
    private static final int CURRENT_ROW = 0xFF24344A;
    private static final int PICK_FILE = 1;
    private static final int PICK_MODULE = 2;
    private static final String GITHUB = "https://raw.githubusercontent.com/BibleQuote/BibleQuote-Modules/master/";
    private static final String[] PLAN_TYPES = {
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
        "application/vnd.ms-powerpoint",
        "image/*", "video/*", "audio/*",
    };

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService work = Executors.newSingleThreadExecutor();
    private Library library;
    private Settings settings;
    private SermonPlan plan;
    private boolean phone;
    private boolean busy;

    private EditText titleField;
    private TextView status;
    private final List<Button> tabButtons = new ArrayList<>();
    private final List<View> panels = new ArrayList<>();
    private final Lines planLines = new Lines(false);
    private TextView planEmpty;
    private int selected = -1;

    // Біблія.
    private Spinner bibleSpinner;
    private TextView bibleEmpty;
    private View bibleBody;
    private final List<Library.Module> bibles = new ArrayList<>();
    private Library.Module bible;
    private final Lines bookLines = new Lines(false);
    private final Lines chapterCells = new Lines(true);
    private final Lines verseLines = new Lines(false);
    private final List<Library.Book> books = new ArrayList<>();
    private Library.Book book;
    private final List<Integer> chapters = new ArrayList<>();
    private int chapter = -1;
    private final List<Library.Verse> verses = new ArrayList<>();
    private final Set<Integer> picked = new TreeSet<>();

    // Пісні.
    private Spinner songbookSpinner;
    private TextView songsEmpty;
    private View songsBody;
    private EditText songFilter;
    private final List<Library.Module> songbooks = new ArrayList<>();
    private Library.Module songbook;
    private final Lines songLines = new Lines(false);
    private final List<Library.Song> songs = new ArrayList<>();
    private Library.Song song;
    private TextView songText;

    // Текст.
    private EditText textHeading;
    private EditText textBody;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        library = new Library(this);
        settings = new Settings(this);
        phone = getResources().getConfiguration().smallestScreenWidthDp < 600;
        // На телефоні лише вертикально: лежачи список книг стискався до нуля.
        if (phone) setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT);
        plan = SermonPlan.load(this, prefs().getString("current", ""));
        if (plan == null) plan = new SermonPlan();
        setContentView(build());
        titleField.setText(plan.title);
        showTab(0);
        reloadBibles();
        reloadSongbooks();
        refreshPlan();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        work.shutdownNow();
    }

    private SharedPreferences prefs() {
        return getSharedPreferences("slovo-sermon", MODE_PRIVATE);
    }

    // MARK: Вигляд

    private View build() {
        LinearLayout root = vertical();
        int pad = dp(8);
        root.setPadding(pad, pad, pad, pad);

        Button back = small("←", v -> finish());
        titleField = new EditText(this);
        titleField.setHint(R.string.s_plan_name_hint);
        titleField.setSingleLine(true);
        titleField.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { }
            @Override public void afterTextChanged(Editable s) {
                if (s.toString().equals(plan.title)) return;
                plan.title = s.toString();
                savePlan();
            }
        });
        Button plans = small(getString(R.string.s_plans), v -> choosePlan());
        Button shelf = small(getString(R.string.s_library), v -> openLibrary());
        Button upload = small(getString(R.string.s_upload), v -> upload());
        upload.setTextColor(ACCENT);
        upload.setTypeface(Typeface.DEFAULT_BOLD);

        if (phone) {
            LinearLayout top = row();
            top.addView(back);
            top.addView(titleField, weight(1));
            root.addView(top);
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            LinearLayout buttons = row();
            buttons.addView(plans);
            buttons.addView(shelf);
            buttons.addView(upload);
            scroller.addView(buttons);
            root.addView(scroller);
        } else {
            LinearLayout top = row();
            top.addView(back);
            top.addView(titleField, weight(1));
            top.addView(plans);
            top.addView(shelf);
            top.addView(upload);
            root.addView(top);
        }
        status = new TextView(this);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        status.setTextColor(0xFF9AA4B2);
        status.setPadding(dp(4), 0, dp(4), dp(4));
        root.addView(status);

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(phone ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        root.addView(body, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        LinearLayout left = vertical();
        LinearLayout tabs = row();
        addTab(tabs, getString(R.string.t_tab_bible));
        addTab(tabs, getString(R.string.t_tab_songs));
        addTab(tabs, getString(R.string.s_tab_file));
        addTab(tabs, getString(R.string.t_tab_text));
        if (phone) {
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            scroller.addView(tabs);
            left.addView(scroller);
        } else {
            left.addView(tabs);
        }
        FrameLayout area = new FrameLayout(this);
        left.addView(area, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        addPanel(area, biblePanel());
        addPanel(area, songsPanel());
        addPanel(area, filePanel());
        addPanel(area, textPanel());
        body.addView(left, phone
            ? new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 3)
            : new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 3));

        LinearLayout right = vertical();
        right.setPadding(phone ? 0 : dp(10), phone ? dp(6) : 0, 0, 0);
        TextView planTitle = new TextView(this);
        planTitle.setText(R.string.t_plan);
        planTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        planTitle.setTypeface(Typeface.DEFAULT_BOLD);
        LinearLayout tools = row();
        tools.addView(planTitle, weight(1));
        tools.addView(small(getString(R.string.t_up), v -> move(-1)));
        tools.addView(small(getString(R.string.t_down), v -> move(1)));
        tools.addView(small(getString(R.string.t_remove), v -> removeSelected()));
        right.addView(tools);
        planEmpty = hint(getString(R.string.s_plan_empty));
        right.addView(planEmpty);
        ListView planList = new ListView(this);
        planList.setAdapter(planLines);
        planList.setOnItemClickListener((parent, view, position, id) -> {
            selected = position;
            planLines.mark(position);
        });
        right.addView(planList, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        body.addView(right, phone
            ? new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 2)
            : new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 2));
        return root;
    }

    private void addTab(LinearLayout tabs, String title) {
        int index = tabButtons.size();
        Button button = new Button(this, null, 0, R.style.TabButton);
        button.setText(title);
        button.setOnClickListener(v -> showTab(index));
        tabButtons.add(button);
        tabs.addView(button);
    }

    private void addPanel(FrameLayout area, View panel) {
        panels.add(panel);
        area.addView(panel, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT));
    }

    private void showTab(int index) {
        for (int i = 0; i < panels.size(); i++) {
            panels.get(i).setVisibility(i == index ? View.VISIBLE : View.GONE);
            tabButtons.get(i).setTextColor(i == index ? ACCENT : Color.WHITE);
        }
    }

    // MARK: Біблія

    private View biblePanel() {
        LinearLayout panel = vertical();
        bibleSpinner = new Spinner(this);
        bibleSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                chooseBible(position);
            }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        });
        panel.addView(bibleSpinner);
        bibleEmpty = hint(getString(R.string.s_no_bibles));
        panel.addView(bibleEmpty);

        LinearLayout columns = new LinearLayout(this);
        columns.setOrientation(LinearLayout.HORIZONTAL);
        ListView bookList = new ListView(this);
        bookList.setAdapter(bookLines);
        bookList.setOnItemClickListener((parent, view, position, id) -> chooseBook(position));
        GridView chapterGrid = new GridView(this);
        chapterGrid.setNumColumns(GridView.AUTO_FIT);
        chapterGrid.setColumnWidth(dp(phone ? 44 : 52));
        chapterGrid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        chapterGrid.setAdapter(chapterCells);
        chapterGrid.setOnItemClickListener((parent, view, position, id) -> chooseChapter(position));
        ListView verseList = new ListView(this);
        verseList.setAdapter(verseLines);
        verseList.setOnItemClickListener((parent, view, position, id) -> toggleVerse(position));
        columns.addView(bookList, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 3));
        columns.addView(chapterGrid, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 2));
        columns.addView(verseList, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 5));

        LinearLayout bottom = row();
        bottom.addView(hint(getString(R.string.s_pick_verses)), weight(1));
        bottom.addView(small(getString(R.string.s_add_chapter), v -> addScripture(true)));
        Button add = small(getString(R.string.s_add_verses), v -> addScripture(false));
        add.setTextColor(ACCENT);
        bottom.addView(add);

        LinearLayout content = vertical();
        content.addView(columns, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        content.addView(bottom);
        bibleBody = content;
        panel.addView(content, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return panel;
    }

    private void reloadBibles() {
        bibles.clear();
        bibles.addAll(library.modules(Library.BIBLE));
        List<String> names = new ArrayList<>();
        for (Library.Module module : bibles) names.add(module.name);
        bibleSpinner.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, names));
        boolean empty = bibles.isEmpty();
        bibleEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);
        bibleSpinner.setVisibility(empty ? View.GONE : View.VISIBLE);
        bibleBody.setVisibility(empty ? View.GONE : View.VISIBLE);
        if (empty) {
            bible = null;
            return;
        }
        String last = prefs().getString("bible", "");
        int position = 0;
        for (int i = 0; i < bibles.size(); i++) if (bibles.get(i).id.equals(last)) position = i;
        bibleSpinner.setSelection(position);
        chooseBible(position);
    }

    private void chooseBible(int position) {
        if (position < 0 || position >= bibles.size()) return;
        Library.Module chosen = bibles.get(position);
        if (bible != null && bible.id.equals(chosen.id) && !books.isEmpty()) return;
        bible = chosen;
        prefs().edit().putString("bible", chosen.id).apply();
        books.clear();
        books.addAll(library.books(chosen.id));
        List<String> names = new ArrayList<>();
        for (Library.Book item : books) names.add(item.name);
        bookLines.set(names, null);
        book = null;
        chapters.clear();
        chapterCells.set(new ArrayList<>(), null);
        chapter = -1;
        verses.clear();
        verseLines.set(new ArrayList<>(), null);
    }

    private void chooseBook(int position) {
        if (bible == null || position < 0 || position >= books.size()) return;
        book = books.get(position);
        bookLines.mark(position);
        chapters.clear();
        chapters.addAll(library.chapters(bible.id, book.index));
        List<String> numbers = new ArrayList<>();
        for (Integer number : chapters) numbers.add(String.valueOf(number));
        chapterCells.set(numbers, null);
        chapter = -1;
        verses.clear();
        verseLines.set(new ArrayList<>(), null);
        if (chapters.size() == 1) chooseChapter(0);
    }

    private void chooseChapter(int position) {
        if (bible == null || book == null || position < 0 || position >= chapters.size()) return;
        chapter = chapters.get(position);
        chapterCells.mark(position);
        verses.clear();
        verses.addAll(library.verses(bible.id, book.index, chapter));
        picked.clear();
        List<String> lines = new ArrayList<>();
        for (Library.Verse verse : verses) lines.add(verse.number + "  " + verse.text);
        verseLines.set(lines, null);
    }

    private void toggleVerse(int position) {
        if (position < 0 || position >= verses.size()) return;
        int number = verses.get(position).number;
        if (!picked.remove(number)) picked.add(number);
        Set<Integer> marked = new HashSet<>();
        for (int i = 0; i < verses.size(); i++) if (picked.contains(verses.get(i).number)) marked.add(i);
        verseLines.markAll(marked);
    }

    private void addScripture(boolean whole) {
        if (bible == null || book == null || chapter < 0) {
            toast(getString(R.string.bible_pick_chapter));
            return;
        }
        if (!whole && picked.isEmpty()) {
            toast(getString(R.string.s_pick_verses));
            return;
        }
        SermonPlan.Item item = new SermonPlan.Item();
        item.type = SermonPlan.SCRIPTURE;
        item.module = bible.id;
        item.moduleName = bible.name;
        item.bookName = book.name;
        item.canon = book.canon;
        item.book = book.index;
        item.chapter = chapter;
        StringBuilder text = new StringBuilder();
        for (Library.Verse verse : verses) {
            if (!whole && !picked.contains(verse.number)) continue;
            if (!whole) item.verses.add(verse.number);
            if (text.length() > 0) text.append(' ');
            text.append(verse.text);
        }
        item.text = text.toString();
        String name = book.shortName.isEmpty() ? book.name : book.shortName.split(" ")[0];
        item.title = name + " " + chapter + (whole ? "" : ":" + span(item.verses));
        addItem(item);
        picked.clear();
        verseLines.markAll(new HashSet<>());
    }

    /// Вірші, що йдуть підряд, згортаються в діапазон: 1,2,3,7 → «1-3,7».
    private static String span(List<Integer> numbers) {
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < numbers.size()) {
            int start = numbers.get(i);
            int end = start;
            while (i + 1 < numbers.size() && numbers.get(i + 1) == end + 1) {
                i++;
                end = numbers.get(i);
            }
            if (out.length() > 0) out.append(',');
            out.append(start == end ? String.valueOf(start) : start + "-" + end);
            i++;
        }
        return out.toString();
    }

    // MARK: Пісні

    private View songsPanel() {
        LinearLayout panel = vertical();
        songbookSpinner = new Spinner(this);
        songbookSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                chooseSongbook(position);
            }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        });
        songFilter = new EditText(this);
        songFilter.setHint(R.string.t_song_filter);
        songFilter.setSingleLine(true);
        songFilter.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { }
            @Override public void afterTextChanged(Editable s) { reloadSongs(); }
        });
        LinearLayout top = row();
        top.addView(songbookSpinner, weight(1));
        top.addView(songFilter, weight(1));
        panel.addView(top);
        songsEmpty = hint(getString(R.string.s_no_songbooks));
        panel.addView(songsEmpty);

        LinearLayout columns = new LinearLayout(this);
        columns.setOrientation(LinearLayout.HORIZONTAL);
        ListView songList = new ListView(this);
        songList.setAdapter(songLines);
        songList.setOnItemClickListener((parent, view, position, id) -> chooseSong(position));
        ScrollView scroller = new ScrollView(this);
        songText = new TextView(this);
        songText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        songText.setPadding(dp(10), dp(6), dp(6), dp(6));
        scroller.addView(songText);
        columns.addView(songList, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1));
        columns.addView(scroller, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1));

        LinearLayout bottom = row();
        bottom.addView(spacer());
        Button add = small(getString(R.string.s_add_song), v -> addSong());
        add.setTextColor(ACCENT);
        bottom.addView(add);

        LinearLayout content = vertical();
        content.addView(columns, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        content.addView(bottom);
        songsBody = content;
        panel.addView(content, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return panel;
    }

    private void reloadSongbooks() {
        songbooks.clear();
        songbooks.addAll(library.modules(Library.SONGS));
        List<String> names = new ArrayList<>();
        for (Library.Module module : songbooks) names.add(module.name);
        songbookSpinner.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, names));
        boolean empty = songbooks.isEmpty();
        songsEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);
        songsBody.setVisibility(empty ? View.GONE : View.VISIBLE);
        songbookSpinner.setVisibility(empty ? View.GONE : View.VISIBLE);
        songFilter.setVisibility(empty ? View.GONE : View.VISIBLE);
        if (empty) {
            songbook = null;
            return;
        }
        String last = prefs().getString("songbook", "");
        int position = 0;
        for (int i = 0; i < songbooks.size(); i++) if (songbooks.get(i).id.equals(last)) position = i;
        songbookSpinner.setSelection(position);
        chooseSongbook(position);
    }

    private void chooseSongbook(int position) {
        if (position < 0 || position >= songbooks.size()) return;
        Library.Module chosen = songbooks.get(position);
        if (songbook != null && songbook.id.equals(chosen.id) && !songs.isEmpty()) return;
        songbook = chosen;
        prefs().edit().putString("songbook", chosen.id).apply();
        reloadSongs();
    }

    private void reloadSongs() {
        songs.clear();
        song = null;
        songText.setText("");
        if (songbook == null) {
            songLines.set(new ArrayList<>(), null);
            return;
        }
        songs.addAll(library.songs(songbook.id, songFilter.getText().toString(), 400));
        List<String> titles = new ArrayList<>();
        for (Library.Song item : songs) titles.add((item.index + 1) + ". " + item.title);
        songLines.set(titles, null);
    }

    private void chooseSong(int position) {
        if (songbook == null || position < 0 || position >= songs.size()) return;
        song = songs.get(position);
        songLines.mark(position);
        StringBuilder text = new StringBuilder();
        for (Library.Part part : library.parts(songbook.id, song.index)) {
            if (text.length() > 0) text.append("\n\n");
            if (!part.kind.isEmpty()) text.append(part.kind).append('\n');
            text.append(part.text);
        }
        songText.setText(text);
    }

    private void addSong() {
        if (songbook == null || song == null) {
            toast(getString(R.string.s_add_song));
            return;
        }
        SermonPlan.Item item = new SermonPlan.Item();
        item.type = SermonPlan.SONG;
        item.module = songbook.id;
        item.songBook = songbook.id.startsWith("songs:") ? songbook.id.substring(6) : songbook.id;
        item.song = song.index;
        item.title = song.title.isEmpty() ? (song.index + 1) + "" : song.title;
        for (Library.Part part : library.parts(songbook.id, song.index)) {
            item.parts.add(new String[] { part.kind, part.text });
        }
        addItem(item);
    }

    // MARK: Файл і текст

    private View filePanel() {
        LinearLayout panel = vertical();
        panel.setPadding(dp(6), dp(12), dp(6), dp(6));
        TextView note = hint(getString(R.string.s_file_hint));
        panel.addView(note);
        Button pick = small(getString(R.string.s_pick_file), v -> pick(PICK_FILE, PLAN_TYPES));
        pick.setTextColor(ACCENT);
        panel.addView(pick, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT));
        return panel;
    }

    private View textPanel() {
        LinearLayout panel = vertical();
        textHeading = new EditText(this);
        textHeading.setHint(R.string.t_text_title_hint);
        textHeading.setSingleLine(true);
        textBody = new EditText(this);
        textBody.setHint(R.string.t_text_body_hint);
        textBody.setGravity(Gravity.TOP | Gravity.START);
        textBody.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
            | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        panel.addView(textHeading);
        panel.addView(textBody, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        LinearLayout bottom = row();
        bottom.addView(spacer());
        Button add = small(getString(R.string.s_text_add), v -> addText());
        add.setTextColor(ACCENT);
        bottom.addView(add);
        panel.addView(bottom);
        return panel;
    }

    private void addText() {
        String heading = textHeading.getText().toString().trim();
        String body = textBody.getText().toString().trim();
        if (heading.isEmpty() && body.isEmpty()) return;
        SermonPlan.Item item = new SermonPlan.Item();
        item.type = SermonPlan.TEXT;
        item.heading = heading;
        item.body = body;
        String first = body.replace('\n', ' ');
        item.title = !heading.isEmpty() ? heading : (first.length() > 60 ? first.substring(0, 60) + "…" : first);
        addItem(item);
        textHeading.setText("");
        textBody.setText("");
    }

    private void pick(int request, String[] types) {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        if (types != null) intent.putExtra(Intent.EXTRA_MIME_TYPES, types);
        try {
            startActivityForResult(intent, request);
        } catch (RuntimeException error) {
            toast(getString(R.string.s_failed, error.getMessage()));
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        String name = displayName(uri);
        if (request == PICK_FILE) {
            setStatus(getString(R.string.s_loading, name));
            work.execute(() -> {
                try {
                    File copy = new File(SermonPlan.filesFolder(this), UUID.randomUUID() + "-" + name);
                    copy(uri, copy);
                    main.post(() -> {
                        SermonPlan.Item item = new SermonPlan.Item();
                        item.type = SermonPlan.FILE;
                        item.name = name;
                        item.title = name;
                        item.path = copy.getPath();
                        addItem(item);
                        setStatus("");
                    });
                } catch (IOException error) {
                    main.post(() -> setStatus(getString(R.string.s_failed, error.getMessage())));
                }
            });
        } else if (request == PICK_MODULE) {
            importModuleFile(uri, name);
        }
    }

    // MARK: План

    private void addItem(SermonPlan.Item item) {
        plan.items.add(item);
        selected = plan.items.size() - 1;
        refreshPlan();
        savePlan();
        toast(getString(R.string.s_loaded, item.title));
    }

    private void refreshPlan() {
        List<String> titles = new ArrayList<>();
        List<String> subtitles = new ArrayList<>();
        for (SermonPlan.Item item : plan.items) {
            titles.add(item.title);
            subtitles.add(item.subtitle());
        }
        planLines.set(titles, subtitles);
        if (selected >= plan.items.size()) selected = plan.items.size() - 1;
        planLines.mark(selected);
        planEmpty.setVisibility(plan.items.isEmpty() ? View.VISIBLE : View.GONE);
    }

    private void move(int delta) {
        int target = selected + delta;
        if (selected < 0 || target < 0 || target >= plan.items.size()) return;
        SermonPlan.Item item = plan.items.remove(selected);
        plan.items.add(target, item);
        selected = target;
        refreshPlan();
        savePlan();
    }

    private void removeSelected() {
        if (selected < 0 || selected >= plan.items.size()) return;
        SermonPlan.Item item = plan.items.remove(selected);
        if (SermonPlan.FILE.equals(item.type) && !item.path.isEmpty()) {
            //noinspection ResultOfMethodCallIgnored
            new File(item.path).delete();
        }
        refreshPlan();
        savePlan();
    }

    private void savePlan() {
        try {
            plan.save(this);
            prefs().edit().putString("current", plan.id).apply();
        } catch (IOException error) {
            setStatus(getString(R.string.s_failed, error.getMessage()));
        }
    }

    private void choosePlan() {
        List<SermonPlan> saved = SermonPlan.all(this);
        String[] labels = new String[saved.size() + 1];
        labels[0] = getString(R.string.s_new_plan);
        for (int i = 0; i < saved.size(); i++) {
            SermonPlan item = saved.get(i);
            String title = item.title.trim().isEmpty() ? getString(R.string.s_untitled) : item.title.trim();
            labels[i + 1] = getString(R.string.s_plan_items, title, item.items.size());
        }
        new AlertDialog.Builder(this)
            .setTitle(R.string.s_plans)
            .setItems(labels, (dialog, which) -> {
                if (which == 0) {
                    openPlan(new SermonPlan());
                } else {
                    openPlan(saved.get(which - 1));
                }
            })
            .setNeutralButton(R.string.s_delete_plan, (dialog, which) -> confirmDeletePlan())
            .setNegativeButton(R.string.cancel, null)
            .show();
    }

    private void openPlan(SermonPlan chosen) {
        plan = chosen;
        selected = -1;
        titleField.setText(plan.title);
        refreshPlan();
        savePlan();
    }

    private void confirmDeletePlan() {
        String title = plan.title.trim().isEmpty() ? getString(R.string.s_untitled) : plan.title.trim();
        new AlertDialog.Builder(this)
            .setMessage(getString(R.string.s_delete_plan_confirm, title))
            .setPositiveButton(R.string.s_delete, (dialog, which) -> {
                plan.delete(this);
                List<SermonPlan> left = SermonPlan.all(this);
                openPlan(left.isEmpty() ? new SermonPlan() : left.get(0));
            })
            .setNegativeButton(R.string.cancel, null)
            .show();
    }

    // MARK: Бібліотека

    private void openLibrary() {
        List<Library.Module> all = new ArrayList<>(library.modules(Library.BIBLE));
        all.addAll(library.modules(Library.SONGS));
        AlertDialog.Builder builder = new AlertDialog.Builder(this).setTitle(R.string.s_library_title);
        if (all.isEmpty()) {
            builder.setMessage(R.string.s_library_empty);
        } else {
            String[] labels = new String[all.size()];
            for (int i = 0; i < all.size(); i++) {
                Library.Module module = all.get(i);
                String kind = getString(Library.BIBLE.equals(module.kind) ? R.string.s_kind_bible : R.string.s_kind_songs);
                String source;
                switch (module.source) {
                    case "slovo": source = getString(R.string.s_source_slovo); break;
                    case "github": source = getString(R.string.s_source_github); break;
                    default: source = getString(R.string.s_source_file); break;
                }
                labels[i] = kind + " · " + module.name + " — " + source;
            }
            builder.setItems(labels, (dialog, which) -> confirmDeleteModule(all.get(which)));
        }
        builder.setPositiveButton(R.string.s_from_slovo, (dialog, which) -> fromSlovo())
            .setNegativeButton(R.string.s_from_github, (dialog, which) -> fromGithub())
            .setNeutralButton(R.string.s_from_file, (dialog, which) -> pick(PICK_MODULE, null))
            .show();
    }

    private void confirmDeleteModule(Library.Module module) {
        new AlertDialog.Builder(this)
            .setMessage(getString(R.string.s_delete_module, module.name))
            .setPositiveButton(R.string.s_delete, (dialog, which) -> {
                library.delete(module.id);
                reloadBibles();
                reloadSongbooks();
            })
            .setNegativeButton(R.string.cancel, null)
            .show();
    }

    private File modulesFolder() {
        File folder = new File(getFilesDir(), "modules");
        //noinspection ResultOfMethodCallIgnored
        folder.mkdirs();
        return folder;
    }

    /// Зі «Слова» по Wi-Fi: переклади рядками, пісенники файлами `.vbm`.
    private void fromSlovo() {
        if (!settings.hasHost()) {
            toast(getString(R.string.s_need_connection));
            return;
        }
        if (busy) return;
        busy = true;
        setStatus(getString(R.string.s_slovo_loading));
        work.execute(() -> {
            try {
                JSONObject answer = api().get("/api/library");
                List<String[]> offer = new ArrayList<>(); // вид, id чи файл, назва
                JSONArray list = answer.optJSONArray("bibles");
                if (list != null) {
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject item = list.optJSONObject(i);
                        if (item == null || library.module("slovo:" + item.optString("id")) != null) continue;
                        offer.add(new String[] { Library.BIBLE, item.optString("id"), item.optString("name") });
                    }
                }
                list = answer.optJSONArray("songbooks");
                if (list != null) {
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject item = list.optJSONObject(i);
                        if (item == null || !"vbm".equals(item.optString("format"))) continue;
                        if (library.module("songs:" + item.optString("file")) != null) continue;
                        offer.add(new String[] { Library.SONGS, item.optString("file"), item.optString("name") });
                    }
                }
                main.post(() -> {
                    busy = false;
                    setStatus("");
                    chooseAndTake(offer, this::takeFromSlovo);
                });
            } catch (Exception error) {
                failed(error);
            }
        });
    }

    private void takeFromSlovo(List<String[]> chosen) {
        busy = true;
        work.execute(() -> {
            Api api = api();
            List<String> done = new ArrayList<>();
            for (String[] item : chosen) {
                status(getString(R.string.s_loading, item[2]));
                try {
                    if (Library.BIBLE.equals(item[0])) {
                        byte[] bytes = api.bytes("/api/library/bible?id=" + encode(item[1]));
                        ModuleReaders.readSlovoBible(library, new ByteArrayInputStream(bytes));
                    } else {
                        byte[] bytes = api.bytes("/api/library/songbook?file=" + encode(item[1]));
                        ModuleReaders.importVbm(library, bytes, item[1], "slovo", "");
                    }
                    done.add(item[2]);
                } catch (Exception error) {
                    status(getString(R.string.s_failed, item[2] + ": " + Api.describe(error)));
                }
            }
            main.post(() -> finishTaking(done));
        });
    }

    /// З GitHub: каталог модулів «Цитати з Біблії» — лише переклади Біблії.
    private void fromGithub() {
        if (busy) return;
        busy = true;
        setStatus(getString(R.string.s_github_loading));
        work.execute(() -> {
            try {
                String ini = new String(download(GITHUB + "modules.ini"), StandardCharsets.UTF_8);
                List<String[]> offer = new ArrayList<>();
                String id = null;
                for (String raw : ini.split("\r?\n")) {
                    String line = raw.trim();
                    if (line.startsWith("[") && line.endsWith("]")) {
                        id = line.substring(1, line.length() - 1);
                    } else if (id != null && line.startsWith("ModuleName=")) {
                        if (id.startsWith("Bible_") && library.module("gh:" + id) == null) {
                            offer.add(new String[] { Library.BIBLE, id, line.substring("ModuleName=".length()).trim() });
                        }
                        id = null;
                    }
                }
                main.post(() -> {
                    busy = false;
                    setStatus("");
                    chooseAndTake(offer, this::takeFromGithub);
                });
            } catch (Exception error) {
                failed(error);
            }
        });
    }

    private void takeFromGithub(List<String[]> chosen) {
        busy = true;
        work.execute(() -> {
            List<String> done = new ArrayList<>();
            for (String[] item : chosen) {
                status(getString(R.string.s_loading, item[2]));
                File zip = new File(modulesFolder(), item[1] + ".zip");
                try {
                    byte[] bytes = download(GITHUB + "modules/" + encode(item[1]) + ".zip");
                    try (OutputStream out = new FileOutputStream(zip)) { out.write(bytes); }
                    ModuleReaders.importBibleQuoteZip(library, zip, "gh:" + item[1], "github", getCacheDir());
                    done.add(item[2]);
                } catch (Exception error) {
                    //noinspection ResultOfMethodCallIgnored
                    zip.delete();
                    status(getString(R.string.s_failed, item[2] + ": " + Api.describe(error)));
                }
            }
            main.post(() -> finishTaking(done));
        });
    }

    /// З файла: zip «Цитати з Біблії», MyBible `.SQLite3` чи пісенник `.vbm`.
    private void importModuleFile(Uri uri, String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (!lower.endsWith(".zip") && !lower.endsWith(".sqlite3") && !lower.endsWith(".vbm")) {
            toast(getString(R.string.s_unsupported_file));
            return;
        }
        busy = true;
        setStatus(getString(R.string.s_loading, name));
        work.execute(() -> {
            File kept = new File(modulesFolder(), name);
            try {
                copy(uri, kept);
                if (lower.endsWith(".zip")) {
                    ModuleReaders.importBibleQuoteZip(library, kept, "file:" + name, "file", getCacheDir());
                } else if (lower.endsWith(".sqlite3")) {
                    ModuleReaders.importMyBible(library, kept, "file:" + name, "file");
                } else {
                    ModuleReaders.importVbm(library, ModuleReaders.readAll(kept), name, "file", kept.getPath());
                }
                List<String> done = new ArrayList<>();
                done.add(name);
                main.post(() -> finishTaking(done));
            } catch (Exception error) {
                //noinspection ResultOfMethodCallIgnored
                kept.delete();
                failed(error);
            }
        });
    }

    private interface Take { void chosen(List<String[]> items); }

    private void chooseAndTake(List<String[]> offer, Take take) {
        if (offer.isEmpty()) {
            toast(getString(R.string.s_nothing_new));
            return;
        }
        String[] labels = new String[offer.size()];
        boolean[] checked = new boolean[offer.size()];
        for (int i = 0; i < offer.size(); i++) {
            String kind = getString(Library.BIBLE.equals(offer.get(i)[0]) ? R.string.s_kind_bible : R.string.s_kind_songs);
            labels[i] = kind + " · " + offer.get(i)[2];
        }
        new AlertDialog.Builder(this)
            .setTitle(R.string.s_choose)
            .setMultiChoiceItems(labels, checked, (dialog, which, isChecked) -> checked[which] = isChecked)
            .setPositiveButton(R.string.s_take, (dialog, which) -> {
                List<String[]> chosen = new ArrayList<>();
                for (int i = 0; i < offer.size(); i++) if (checked[i]) chosen.add(offer.get(i));
                if (!chosen.isEmpty()) take.chosen(chosen);
            })
            .setNegativeButton(R.string.cancel, null)
            .show();
    }

    private void finishTaking(List<String> done) {
        busy = false;
        reloadBibles();
        reloadSongbooks();
        if (!done.isEmpty()) setStatus(getString(R.string.s_loaded, join(done)));
    }

    // MARK: На служінні — у «Слово»

    private void upload() {
        if (plan.items.isEmpty()) {
            toast(getString(R.string.s_upload_empty));
            return;
        }
        if (!settings.hasHost()) {
            toast(getString(R.string.s_need_connection));
            return;
        }
        if (busy) return;
        busy = true;
        setStatus(getString(R.string.s_uploading));
        List<SermonPlan.Item> sending = new ArrayList<>(plan.items);
        String title = plan.title.trim();
        work.execute(() -> {
            try {
                Api api = api();
                JSONObject answer = api.get("/api/library");
                Set<String> bibleIds = new HashSet<>();
                Map<String, String> bibleByName = new HashMap<>();
                JSONArray list = answer.optJSONArray("bibles");
                if (list != null) {
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject item = list.optJSONObject(i);
                        if (item == null) continue;
                        bibleIds.add(item.optString("id"));
                        bibleByName.put(item.optString("name").toLowerCase(Locale.ROOT), item.optString("id"));
                    }
                }
                Set<String> songFiles = new HashSet<>();
                list = answer.optJSONArray("songbooks");
                if (list != null) {
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject item = list.optJSONObject(i);
                        if (item != null) songFiles.add(item.optString("file").toLowerCase(Locale.ROOT));
                    }
                }

                Map<String, String> resolved = new HashMap<>();
                List<String> notes = new ArrayList<>();
                JSONArray items = new JSONArray();
                for (SermonPlan.Item item : sending) {
                    JSONObject json = new JSONObject();
                    json.put("type", item.type);
                    json.put("title", item.title);
                    switch (item.type) {
                        case SermonPlan.SCRIPTURE:
                            json.put("module", resolveBible(api, item, bibleIds, bibleByName, resolved));
                            json.put("moduleName", item.moduleName);
                            json.put("canon", item.canon);
                            json.put("bookName", item.bookName);
                            json.put("chapter", item.chapter);
                            JSONArray numbers = new JSONArray();
                            for (Integer verse : item.verses) numbers.put(verse);
                            json.put("verses", numbers);
                            json.put("text", item.text);
                            break;
                        case SermonPlan.SONG:
                            ensureSongbook(api, item, songFiles);
                            json.put("songBook", item.songBook);
                            json.put("song", item.song);
                            JSONArray parts = new JSONArray();
                            for (String[] part : item.parts) {
                                JSONObject one = new JSONObject();
                                one.put("kind", part[0]);
                                one.put("text", part[1]);
                                parts.put(one);
                            }
                            json.put("parts", parts);
                            break;
                        case SermonPlan.TEXT:
                            json.put("heading", item.heading);
                            json.put("body", item.body);
                            break;
                        default:
                            File file = new File(item.path);
                            if (!file.isFile()) {
                                notes.add(getString(R.string.s_file_missing, item.name));
                                continue;
                            }
                            status(getString(R.string.s_sending_file, item.name));
                            json.put("file", api.storeFile(item.name, ModuleReaders.readAll(file)));
                            break;
                    }
                    items.put(json);
                }
                status(getString(R.string.s_uploading));
                JSONObject body = new JSONObject();
                body.put("title", title);
                body.put("items", items);
                JSONObject result = api.sermonPlan(body);
                int added = result.optInt("added");
                JSONArray extra = result.optJSONArray("notes");
                if (extra != null) for (int i = 0; i < extra.length(); i++) notes.add(extra.optString(i));
                main.post(() -> finishUpload(added, notes));
            } catch (Exception error) {
                failed(error);
            }
        });
    }

    /// Переклад пункту так, як його знає програма: той самий зі «Слова», той
    /// самий за назвою або щойно поставлений із файла, який привіз планшет.
    private String resolveBible(Api api, SermonPlan.Item item, Set<String> ids, Map<String, String> byName,
                                Map<String, String> resolved) throws IOException, JSONException {
        String known = resolved.get(item.module);
        if (known != null) return known;
        String found = null;
        if (item.module.startsWith("slovo:") && ids.contains(item.module.substring(6))) found = item.module.substring(6);
        if (found == null) found = byName.get(item.moduleName.toLowerCase(Locale.ROOT));
        if (found == null) {
            Library.Module module = library.module(item.module);
            File original = module == null || module.original.isEmpty() ? null : new File(module.original);
            if (original != null && original.isFile()) {
                status(getString(R.string.s_importing, module.name));
                JSONObject answer = api.importModule(original.getName(), ModuleReaders.readAll(original));
                JSONArray modules = answer.optJSONArray("modules");
                if (modules != null && modules.length() > 0) found = modules.optString(0);
            }
        }
        if (found == null) found = "";
        resolved.put(item.module, found);
        return found;
    }

    /// Пісенника в програмі немає — довезти файл, з якого він прийшов на планшет.
    private void ensureSongbook(Api api, SermonPlan.Item item, Set<String> files) throws IOException {
        if (files.contains(item.songBook.toLowerCase(Locale.ROOT))) return;
        Library.Module module = library.module(item.module);
        File original = module == null || module.original.isEmpty() ? null : new File(module.original);
        if (original == null || !original.isFile()) return;
        status(getString(R.string.s_importing, module.name));
        api.importModule(item.songBook, ModuleReaders.readAll(original));
        files.add(item.songBook.toLowerCase(Locale.ROOT));
    }

    private void finishUpload(int added, List<String> notes) {
        busy = false;
        setStatus(getString(R.string.s_uploaded, added));
        Runnable open = () -> {
            Intent intent = new Intent(this, TabletActivity.class);
            intent.putExtra("sermon", true);
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            startActivity(intent);
            finish();
        };
        if (notes.isEmpty()) {
            toast(getString(R.string.s_uploaded, added));
            open.run();
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle(getString(R.string.s_uploaded, added))
            .setMessage(join(notes).replace(", ", "\n"))
            .setPositiveButton(R.string.done, (dialog, which) -> open.run())
            .setCancelable(false)
            .show();
    }

    // MARK: Мережа й файли

    private Api api() {
        return new Api(settings.host(), settings.port(), settings.pin());
    }

    /// GitHub — звичайним шляхом через інтернет, а не прив'язкою до Wi-Fi програми.
    private static byte[] download(String address) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setConnectTimeout(15_000);
        connection.setReadTimeout(60_000);
        try {
            int code = connection.getResponseCode();
            if (code >= 400) throw new IOException("HTTP " + code);
            try (InputStream in = connection.getInputStream()) { return ModuleReaders.readAll(in); }
        } finally {
            connection.disconnect();
        }
    }

    private void copy(Uri uri, File target) throws IOException {
        try (InputStream in = getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(target)) {
            if (in == null) throw new IOException("файл не відкривається");
            byte[] chunk = new byte[65536];
            int count;
            while ((count = in.read(chunk)) > 0) out.write(chunk, 0, count);
        }
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, new String[] { OpenableColumns.DISPLAY_NAME },
                null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) return cursor.getString(0);
        } catch (RuntimeException ignored) { }
        String last = uri.getLastPathSegment();
        return last == null ? "file" : last.substring(last.lastIndexOf('/') + 1);
    }

    private static String encode(String value) throws IOException {
        return URLEncoder.encode(value, "UTF-8").replace("+", "%20");
    }

    // MARK: Дрібниці

    private void failed(Exception error) {
        main.post(() -> {
            busy = false;
            setStatus(getString(R.string.s_failed, Api.describe(error)));
        });
    }

    private void status(String text) {
        main.post(() -> setStatus(text));
    }

    private void setStatus(String text) {
        status.setText(text);
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }

    private static String join(List<String> parts) {
        StringBuilder out = new StringBuilder();
        for (String part : parts) {
            if (out.length() > 0) out.append(", ");
            out.append(part);
        }
        return out.toString();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private Button small(String title, View.OnClickListener action) {
        Button button = new Button(this, null, 0, R.style.SmallButton);
        button.setText(title);
        button.setOnClickListener(action);
        return button;
    }

    private LinearLayout row() {
        LinearLayout line = new LinearLayout(this);
        line.setOrientation(LinearLayout.HORIZONTAL);
        line.setGravity(Gravity.CENTER_VERTICAL);
        return line;
    }

    private LinearLayout vertical() {
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        return column;
    }

    private TextView hint(String text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        view.setTextColor(0xFF9AA4B2);
        view.setPadding(dp(6), dp(6), dp(6), dp(6));
        return view;
    }

    /// Розпірка в ряду кнопок. Висота нульова: порожній `View` з висотою «за
    /// вмістом» бере всю доступну висоту, і ряд забирав місце в поля тексту
    /// оголошення та в списку пісень.
    private View spacer() {
        View space = new View(this);
        space.setLayoutParams(new LinearLayout.LayoutParams(0, 0, 1));
        return space;
    }

    private static LinearLayout.LayoutParams weight(float weight) {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, weight);
    }

    /// Рядки списку: заголовок і друга, дрібніша, або комірка сітки розділів.
    private final class Lines extends BaseAdapter {
        private final boolean cells;
        private final List<String> titles = new ArrayList<>();
        private final List<String> subtitles = new ArrayList<>();
        private final Set<Integer> marked = new HashSet<>();

        Lines(boolean cells) { this.cells = cells; }

        void set(List<String> newTitles, List<String> newSubtitles) {
            titles.clear();
            titles.addAll(newTitles);
            subtitles.clear();
            if (newSubtitles != null) subtitles.addAll(newSubtitles);
            marked.clear();
            notifyDataSetChanged();
        }

        void mark(int position) {
            marked.clear();
            if (position >= 0) marked.add(position);
            notifyDataSetChanged();
        }

        void markAll(Set<Integer> positions) {
            marked.clear();
            marked.addAll(positions);
            notifyDataSetChanged();
        }

        @Override public int getCount() { return titles.size(); }
        @Override public Object getItem(int position) { return titles.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View recycled, ViewGroup parent) {
            if (cells) {
                TextView cell = recycled instanceof TextView ? (TextView) recycled : new TextView(SermonActivity.this);
                cell.setGravity(Gravity.CENTER);
                cell.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
                cell.setPadding(0, dp(10), 0, dp(10));
                cell.setText(titles.get(position));
                cell.setBackgroundColor(marked.contains(position) ? CURRENT_ROW : Color.TRANSPARENT);
                return cell;
            }
            View view = recycled != null && !(recycled instanceof TextView) ? recycled
                : getLayoutInflater().inflate(R.layout.row_item, parent, false);
            ((TextView) view.findViewById(R.id.title)).setText(titles.get(position));
            TextView subtitle = view.findViewById(R.id.subtitle);
            String second = position < subtitles.size() ? subtitles.get(position) : "";
            subtitle.setText(second);
            subtitle.setVisibility(second.isEmpty() ? View.GONE : View.VISIBLE);
            view.setBackgroundColor(marked.contains(position) ? CURRENT_ROW : Color.TRANSPARENT);
            return view;
        }
    }
}
