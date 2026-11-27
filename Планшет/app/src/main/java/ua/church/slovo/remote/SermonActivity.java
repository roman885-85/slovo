package ua.church.slovo.remote;

import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;

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
///
/// Вигляд — картки, кнопки й вікна знизу «Слова» для Android (див. `Ui`).
/// Розкладка складається кодом і наново після повороту: усе, що показано,
/// живе в полях класу, а не у видах.
public final class SermonActivity extends Activity {

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
    private boolean busy;

    /// Широка розкладка (планшет лежачи): добір ліворуч, план праворуч;
    /// вузька — те саме стовпчиком.
    private boolean wide;
    /// Чи вміщається підказка під віршами в один ряд із кнопками.
    private boolean roomy;
    /// Те, з чого екран малюється наново після повороту: вкладка, рядок
    /// стану, зв'язок і набране в полях вводу.
    private int tab;
    private String statusText = "";
    private String linkText = "";
    private int linkColour = Ui.DIM;
    private String keptFilter = "", keptHeading = "", keptBody = "";

    private EditText titleField;
    private TextView status;
    private final List<TextView> tabChips = new ArrayList<>();
    private final List<View> panels = new ArrayList<>();
    /// Кроки, лічильник і зв'язок — щоб було видно, що робити далі.
    private final List<TextView> steps = new ArrayList<>();
    private TextView plansButton;
    private TextView planCount, orderHint, linkState;
    private ListView planList;
    private View planEmpty;
    private int selected = -1;

    /// Рядки плану: номер, назва й дрібніше — вид пункту словами та початок тексту.
    private final Ui.Rows<SermonPlan.Item> planRows = new Ui.Rows<SermonPlan.Item>() {
        @Override
        String title(SermonPlan.Item item) { return item.title; }

        @Override
        String sub(SermonPlan.Item item) {
            String kind = kindName(item.type);
            String rest = item.subtitle();
            // У файла підпис — те саме ім'я, що й назва: двічі його не пишемо.
            return rest.isEmpty() || rest.equals(item.title) ? kind : kind + " · " + rest;
        }

        @Override
        String badge(SermonPlan.Item item) { return String.valueOf(items.indexOf(item) + 1); }
    };

    // Біблія.
    private TextView bibleButton, bibleHint;
    private View bibleEmpty;
    private View bibleBody;
    private ListView verseList;
    private final List<Library.Module> bibles = new ArrayList<>();
    private Library.Module bible;
    private final List<Library.Book> books = new ArrayList<>();
    private Library.Book book;
    private final List<Integer> chapters = new ArrayList<>();
    private int chapter = -1;
    private final List<Library.Verse> verses = new ArrayList<>();
    private final Set<Integer> picked = new TreeSet<>();

    private final Ui.Rows<Library.Book> bookRows = new Ui.Rows<Library.Book>() {
        @Override
        String title(Library.Book item) { return item.name; }

        @Override
        boolean chosen(int position) { return items.get(position) == book; }
    };

    /// Розділи — сіткою комірок із номерами; вибраний — кольором акценту.
    private final BaseAdapter chapterCells = new BaseAdapter() {
        @Override
        public int getCount() { return chapters.size(); }

        @Override
        public Object getItem(int position) { return chapters.get(position); }

        @Override
        public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View recycled, ViewGroup parent) {
            TextView cell = recycled instanceof TextView ? (TextView) recycled : Ui.label(SermonActivity.this, "", 16, Ui.TEXT);
            int number = chapters.get(position);
            cell.setText(String.valueOf(number));
            cell.setGravity(Gravity.CENTER);
            cell.setMinHeight(Ui.dp(44));
            cell.setTypeface(Typeface.DEFAULT_BOLD);
            cell.setBackground(Ui.round(number == chapter ? Ui.ACCENT : Ui.CARD2, 10));
            return cell;
        }
    };

    private final Ui.Rows<Library.Verse> verseRows = new Ui.Rows<Library.Verse>() {
        @Override
        String title(Library.Verse item) { return item.text; }

        @Override
        String badge(Library.Verse item) { return String.valueOf(item.number); }

        @Override
        boolean chosen(int position) { return picked.contains(items.get(position).number); }
    };

    // Пісні.
    private TextView songbookButton, songsHint;
    private View songsTop;
    private View songsEmpty;
    private View songsBody;
    private EditText songFilter;
    private final List<Library.Module> songbooks = new ArrayList<>();
    private Library.Module songbook;
    private final List<Library.Song> songs = new ArrayList<>();
    private Library.Song song;
    private TextView songText;
    /// Текст вибраної пісні — щоб повернути його після повороту.
    private String songShown = "";

    private final Ui.Rows<Library.Song> songRows = new Ui.Rows<Library.Song>() {
        @Override
        String title(Library.Song item) { return item.title; }

        @Override
        String badge(Library.Song item) { return String.valueOf(item.index + 1); }

        @Override
        boolean chosen(int position) { return items.get(position) == song; }
    };

    // Текст.
    private EditText textHeading;
    private EditText textBody;

    /// Масштаб інтерфейсу (див. `UiScale`) — до того, як вікно візьме ресурси.
    @Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        // Мова інтерфейсу (див. `Lang`) і масштаб — одним налаштуванням.
        applyOverrideConfiguration(Lang.override(base, UiScale.override(base)));
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Ui.init(this);
        // Положення екрана — за `UiScale`: типово на телефоні лише вертикально
        // (лежачи список книг стискався до нуля) і без перевертання —
        // «железно зафиксирована в ориентации».
        UiScale.applyOrientation(this);
        library = new Library(this);
        settings = new Settings(this);
        plan = SermonPlan.load(this, prefs().getString("current", ""));
        if (plan == null) plan = new SermonPlan();
        linkText = getString(R.string.s_checking);
        setContentView(build());
        reloadBibles();
        reloadSongbooks();
        render();
    }

    /// Поворот чи інший розмір вікна: розкладку складаємо наново під нову
    /// ширину. Стан лежить у полях, тож усе вибране лишається на місці; набране
    /// в полях вводу забираємо зі старих видів і повертаємо в нові.
    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        if (titleField == null) return;
        keptFilter = songFilter.getText().toString();
        keptHeading = textHeading.getText().toString();
        keptBody = textBody.getText().toString();
        Ui.init(this);
        setContentView(build());
        render();
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
        DisplayMetrics metrics = getResources().getDisplayMetrics();
        wide = Shell.wide(this);
        roomy = wide && metrics.widthPixels / metrics.density >= 1000;
        tabChips.clear();
        panels.clear();
        steps.clear();

        LinearLayout root = Ui.col(this);
        root.setBackgroundColor(Ui.BG);
        root.setFitsSystemWindows(true);
        root.addView(header());

        // Три кроки: поточний — яскравий, решта — сірі (див. `refreshPlan`).
        LinearLayout stepRow = Ui.row(this);
        stepRow.setPadding(Ui.dp(6), Ui.dp(2), Ui.dp(6), 0);
        for (int text : new int[] {R.string.s_step_1, R.string.s_step_2, R.string.s_step_3}) {
            TextView step = Ui.label(this, getString(text), wide ? 13.5f : 12, Ui.DIM);
            step.setTypeface(Ui.MEDIUM);
            step.setGravity(Gravity.CENTER);
            step.setMaxLines(2);
            step.setPadding(Ui.dp(6), Ui.dp(7), Ui.dp(6), Ui.dp(7));
            steps.add(step);
            stepRow.addView(step, Ui.lp(0, Ui.FILL, 1, 2));
        }
        root.addView(stepRow);

        status = Ui.hint(this, "");
        root.addView(status);

        LinearLayout body = wide ? Ui.row(this) : Ui.col(this);
        body.setPadding(Ui.dp(5), Ui.dp(2), Ui.dp(5), Ui.dp(8));
        root.addView(body, Ui.lp(Ui.FILL, 0, 1));

        LinearLayout left = Ui.col(this);
        LinearLayout tabs = Ui.row(this);
        addTab(tabs, R.drawable.ic_bible, getString(R.string.t_tab_bible));
        addTab(tabs, R.drawable.ic_song, getString(R.string.t_tab_songs));
        addTab(tabs, R.drawable.ic_folder, getString(R.string.s_tab_file));
        addTab(tabs, R.drawable.ic_text, getString(R.string.t_tab_text));
        if (wide) {
            left.addView(tabs);
        } else {
            // На вузькому екрані чотири вкладки можуть не вміститися в ряд — тоді ряд гортається.
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            scroller.setHorizontalScrollBarEnabled(false);
            scroller.addView(tabs);
            left.addView(scroller);
        }
        FrameLayout area = new FrameLayout(this);
        left.addView(area, Ui.lp(Ui.FILL, 0, 1));
        addPanel(area, biblePanel());
        addPanel(area, songsPanel());
        addPanel(area, filePanel());
        addPanel(area, textPanel());
        body.addView(left, wide ? Ui.lp(0, Ui.FILL, 3) : Ui.lp(Ui.FILL, 0, 3));
        body.addView(planColumn(), wide ? Ui.lp(0, Ui.FILL, 2, 5, 3, 3, 0) : Ui.lp(Ui.FILL, 0, 2, 3, 6, 3, 0));
        return root;
    }

    /// Шапка: «назад», назва плану й куди піти — до своїх планів і до бібліотеки.
    private View header() {
        LinearLayout box = Ui.col(this);
        LinearLayout bar = Ui.row(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(6), Ui.dp(4), Ui.dp(5), Ui.dp(2));
        ImageView back = Ui.iconButton(this, R.drawable.ic_back, 0, this::finish);
        back.setContentDescription(getString(R.string.x_back));
        titleField = Ui.field(this, getString(R.string.s_plan_name_hint), false);
        // Назву пишуть звичайними словами: з великої літери й із підказками клавіатури.
        titleField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        titleField.setText(plan.title);
        titleField.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { }
            @Override public void afterTextChanged(Editable s) {
                if (s.toString().equals(plan.title)) return;
                plan.title = s.toString();
                savePlan();
            }
        });
        // Власник: «в планшете не понятно как добавить план в программу».
        // Вгорі — лише назва й куди піти; головна дія, «Завантажити в
        // «Слово»», стоїть окремо великою кнопкою під планом.
        plansButton = Ui.button(this, R.drawable.ic_folder, getString(R.string.s_plans_count, 0), Ui.CARD2, this::choosePlan);
        TextView shelf = Ui.button(this, R.drawable.ic_extension, getString(R.string.s_library), Ui.CARD2, this::openLibrary);
        // Довгий дотик на кнопці — що вона робить.
        Ui.explain(back, getString(R.string.x_back));
        Ui.explain(plansButton, getString(R.string.x_plans));
        Ui.explain(shelf, getString(R.string.x_library));

        bar.addView(back, Ui.lp(Ui.dp(48), Ui.dp(48), 0));
        bar.addView(titleField, Ui.lp(0, Ui.dp(48), 1, 2, 0, 3, 0));
        box.addView(bar);
        if (wide) {
            plansButton.setMaxLines(1);
            shelf.setMaxLines(1);
            bar.addView(plansButton, Ui.lp(Ui.WRAP, Ui.dp(48), 0, 3, 0, 3, 0));
            bar.addView(shelf, Ui.lp(Ui.WRAP, Ui.dp(48), 0, 3, 0, 3, 0));
        } else {
            // Вузький екран: дві кнопки — другим рядом, на всю ширину порівну.
            LinearLayout second = Ui.row(this);
            second.setPadding(Ui.dp(5), Ui.dp(2), Ui.dp(5), 0);
            second.addView(plansButton, Ui.lp(0, Ui.FILL, 1, 3));
            second.addView(shelf, Ui.lp(0, Ui.FILL, 1, 3));
            box.addView(second);
        }
        return box;
    }

    private void addTab(LinearLayout tabs, int icon, String title) {
        int index = tabChips.size();
        TextView chip = Ui.chip(this, icon, title, () -> showTab(index));
        tabChips.add(chip);
        tabs.addView(chip, Ui.lp(Ui.WRAP, Ui.dp(40), 0, 3));
    }

    private void addPanel(FrameLayout area, View panel) {
        panels.add(panel);
        area.addView(panel, Ui.fill());
    }

    private void showTab(int index) {
        tab = index;
        for (int i = 0; i < panels.size(); i++) {
            panels.get(i).setVisibility(i == index ? View.VISIBLE : View.GONE);
            TextView chip = tabChips.get(i);
            // Назва вкладки лежить в описі кнопки — `chipState` кладе її туди сам.
            Ui.chipState(chip, String.valueOf(chip.getContentDescription()), i == index, Ui.ACCENT);
        }
    }

    /// Перемалювати все зі стану — після `build()`: і вперше, і після повороту.
    private void render() {
        showTab(tab);
        showBibles();
        showSongbooks();
        songText.setText(songShown);
        refreshPlan();
        setStatus(statusText);
        showLink();
    }

    /// Картка-колонка зі списком усередині. Заокруглені кути обрізають і
    /// підсвічення рядка під пальцем — воно не вилазить за картку.
    private LinearLayout pane(View inner) {
        LinearLayout card = Ui.card(this);
        card.setClipToOutline(true);
        card.addView(inner, Ui.lp(Ui.FILL, 0, 1));
        return card;
    }

    /// Порожній стан по центру, у прокрутці: на низькому екрані (телефон,
    /// відкрита клавіатура) значок із поясненням не обрізає, а гортає.
    private View centred(LinearLayout box) {
        if (!wide) box.setPadding(Ui.dp(16), Ui.dp(10), Ui.dp(16), Ui.dp(10));
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(box, new FrameLayout.LayoutParams(Ui.FILL, Ui.WRAP));
        return scroll;
    }

    /// Підказки в ресурсах називають кнопки ще зі старими значками-символами
    /// («＋ Додати вірші в план»). Значки тепер справжні, тож символ із назви
    /// прибираємо — у лапках має стояти те саме, що написано на кнопці.
    private static String tidy(String text) {
        return text.replace("＋ ", "").replace("⬆ ", "");
    }

    // MARK: Біблія

    private View biblePanel() {
        LinearLayout panel = Ui.col(this);
        bibleHint = Ui.hint(this, tidy(getString(R.string.s_hint_bible)));
        panel.addView(bibleHint);
        // Переклад — кнопкою з його назвою; вибір відкривається вікном знизу.
        bibleButton = Ui.button(this, R.drawable.ic_bible, "", Ui.CARD2, this::pickBible);
        bibleButton.setMaxLines(1);
        bibleButton.setPadding(Ui.dp(16), 0, Ui.dp(16), 0);
        if (wide) bibleButton.setMinWidth(Ui.dp(240));
        Ui.explain(bibleButton, getString(R.string.x_translation));
        panel.addView(bibleButton, Ui.lp(wide ? Ui.WRAP : Ui.FILL, Ui.dp(46), 0, 3));
        bibleEmpty = centred(Ui.empty(this, R.drawable.ic_bible, Lang.t("Перекладів ще немає", "No translations yet"),
            getString(R.string.s_no_bibles), getString(R.string.s_library), this::openLibrary));
        panel.addView(bibleEmpty, Ui.lp(Ui.FILL, 0, 1));

        LinearLayout columns = Ui.row(this);
        ListView bookList = Ui.list(this, bookRows);
        bookList.setOnItemClickListener((parent, view, position, id) -> chooseBook(position));
        GridView chapterGrid = new GridView(this);
        chapterGrid.setNumColumns(GridView.AUTO_FIT);
        chapterGrid.setColumnWidth(Ui.dp(wide ? 52 : 44));
        chapterGrid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        chapterGrid.setHorizontalSpacing(Ui.dp(4));
        chapterGrid.setVerticalSpacing(Ui.dp(4));
        chapterGrid.setPadding(Ui.dp(6), Ui.dp(8), Ui.dp(6), Ui.dp(8));
        chapterGrid.setClipToPadding(false);
        chapterGrid.setSelector(new ColorDrawable(0x22FFFFFF));
        chapterGrid.setAdapter(chapterCells);
        chapterGrid.setOnItemClickListener((parent, view, position, id) -> chooseChapter(position));
        verseList = Ui.list(this, verseRows);
        verseList.setOnItemClickListener((parent, view, position, id) -> toggleVerse(position));
        columns.addView(pane(bookList), Ui.lp(0, Ui.FILL, 3, 3));
        columns.addView(pane(chapterGrid), Ui.lp(0, Ui.FILL, 2, 3));
        columns.addView(pane(verseList), Ui.lp(0, Ui.FILL, 5, 3));

        TextView pickHint = Ui.hint(this, getString(R.string.s_pick_verses));
        TextView whole = Ui.button(this, R.drawable.ic_add, Ui.plain(getString(R.string.s_add_chapter)), Ui.CARD2, () -> addScripture(true));
        TextView add = Ui.primary(this, R.drawable.ic_plan_add, Ui.plain(getString(R.string.s_add_verses)), () -> addScripture(false));
        LinearLayout bottom = Ui.row(this);
        bottom.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout content = Ui.col(this);
        content.addView(columns, Ui.lp(Ui.FILL, 0, 1));
        if (wide) {
            whole.setMaxLines(1);
            add.setMaxLines(1);
            whole.setPadding(Ui.dp(16), 0, Ui.dp(16), 0);
            add.setPadding(Ui.dp(18), 0, Ui.dp(18), 0);
            // Підказка — в одному ряду з кнопками, лише коли їй там вистачає місця.
            if (roomy) bottom.addView(pickHint, Ui.lp(0, Ui.WRAP, 1));
            else {
                content.addView(pickHint);
                bottom.addView(Ui.gap(this));
            }
            bottom.addView(whole, Ui.lp(Ui.WRAP, Ui.dp(48), 0, 3));
            bottom.addView(add, Ui.lp(Ui.WRAP, Ui.dp(48), 0, 3));
        } else {
            // Вузький екран: кнопки ділять ряд, тож поля в них менші, а підпис головної — дрібніший.
            content.addView(pickHint);
            whole.setPadding(Ui.dp(8), Ui.dp(6), Ui.dp(8), Ui.dp(6));
            add.setPadding(Ui.dp(8), Ui.dp(6), Ui.dp(8), Ui.dp(6));
            add.setTextSize(14.5f);
            bottom.addView(whole, Ui.lp(0, Ui.FILL, 1, 3));
            bottom.addView(add, Ui.lp(0, Ui.FILL, 1.6f, 3));
        }
        content.addView(bottom);
        bibleBody = content;
        panel.addView(content, Ui.lp(Ui.FILL, 0, 1));
        return panel;
    }

    private void reloadBibles() {
        bibles.clear();
        bibles.addAll(library.modules(Library.BIBLE));
        if (bibles.isEmpty()) {
            bible = null;
            showBibles();
            return;
        }
        String last = prefs().getString("bible", "");
        int position = 0;
        for (int i = 0; i < bibles.size(); i++) if (bibles.get(i).id.equals(last)) position = i;
        chooseBible(position);
        showBibles();
    }

    /// Кнопка перекладу з його назвою; без перекладів — порожній стан із
    /// кнопкою «Переклади й пісенники» замість трьох колонок.
    private void showBibles() {
        boolean empty = bibles.isEmpty();
        bibleEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);
        bibleHint.setVisibility(empty ? View.GONE : View.VISIBLE);
        bibleButton.setVisibility(empty ? View.GONE : View.VISIBLE);
        bibleBody.setVisibility(empty ? View.GONE : View.VISIBLE);
        Ui.setText(bibleButton, bible == null ? getString(R.string.bible_translation) : bible.name);
    }

    private void pickBible() {
        String[] names = new String[bibles.size()];
        int checked = -1;
        for (int i = 0; i < bibles.size(); i++) {
            names[i] = bibles.get(i).name;
            if (bible != null && bibles.get(i).id.equals(bible.id)) checked = i;
        }
        Ui.pick(this, getString(R.string.bible_translation), names, checked, which -> {
            chooseBible(which);
            showBibles();
        });
    }

    private void chooseBible(int position) {
        if (position < 0 || position >= bibles.size()) return;
        Library.Module chosen = bibles.get(position);
        if (bible != null && bible.id.equals(chosen.id) && !books.isEmpty()) return;
        bible = chosen;
        prefs().edit().putString("bible", chosen.id).apply();
        books.clear();
        books.addAll(library.books(chosen.id));
        book = null;
        bookRows.set(books);
        chapters.clear();
        chapter = -1;
        chapterCells.notifyDataSetChanged();
        verses.clear();
        verseRows.set(verses);
    }

    private void chooseBook(int position) {
        if (bible == null || position < 0 || position >= books.size()) return;
        book = books.get(position);
        bookRows.notifyDataSetChanged();
        chapters.clear();
        chapters.addAll(library.chapters(bible.id, book.index));
        chapter = -1;
        chapterCells.notifyDataSetChanged();
        verses.clear();
        verseRows.set(verses);
        if (chapters.size() == 1) chooseChapter(0);
    }

    private void chooseChapter(int position) {
        if (bible == null || book == null || position < 0 || position >= chapters.size()) return;
        chapter = chapters.get(position);
        chapterCells.notifyDataSetChanged();
        verses.clear();
        verses.addAll(library.verses(bible.id, book.index, chapter));
        picked.clear();
        verseRows.set(verses);
        // Новий розділ читають з початку, а не з місця, де стояв попередній.
        verseList.setSelection(0);
    }

    private void toggleVerse(int position) {
        if (position < 0 || position >= verses.size()) return;
        int number = verses.get(position).number;
        if (!picked.remove(number)) picked.add(number);
        verseRows.notifyDataSetChanged();
    }

    private void addScripture(boolean whole) {
        if (bible == null || book == null || chapter < 0) {
            Ui.toast(this, getString(R.string.bible_pick_chapter));
            return;
        }
        if (!whole && picked.isEmpty()) {
            Ui.toast(this, getString(R.string.s_pick_verses));
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
        verseRows.notifyDataSetChanged();
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
        LinearLayout panel = Ui.col(this);
        songsHint = Ui.hint(this, tidy(getString(R.string.s_hint_songs)));
        panel.addView(songsHint);
        // Пісенник — кнопкою з його назвою, як і переклад; поруч — пошук пісні.
        songbookButton = Ui.button(this, R.drawable.ic_song, "", Ui.CARD2, this::pickSongbook);
        songbookButton.setMaxLines(1);
        Ui.explain(songbookButton, getString(R.string.x_songbook));
        songFilter = Ui.search(this, getString(R.string.t_song_filter));
        // Набране до повороту повертаємо ще до того, як поле почне слухати зміни:
        // інакше список перечитався б і вибрана пісня злетіла б.
        songFilter.setText(keptFilter);
        songFilter.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) { }
            @Override public void afterTextChanged(Editable s) { reloadSongs(); }
        });
        LinearLayout top = Ui.row(this);
        top.addView(songbookButton, Ui.lp(0, Ui.dp(46), 1, 3));
        top.addView(songFilter, Ui.lp(0, Ui.dp(46), 1, 3));
        songsTop = top;
        panel.addView(top);
        songsEmpty = centred(Ui.empty(this, R.drawable.ic_song, Lang.t("Пісенників ще немає", "No songbooks yet"),
            getString(R.string.s_no_songbooks), getString(R.string.s_library), this::openLibrary));
        panel.addView(songsEmpty, Ui.lp(Ui.FILL, 0, 1));

        LinearLayout columns = Ui.row(this);
        ListView songList = Ui.list(this, songRows);
        songList.setOnItemClickListener((parent, view, position, id) -> chooseSong(position));
        ScrollView scroller = new ScrollView(this);
        songText = Ui.label(this, "", 16, Ui.TEXT);
        songText.setHint(Lang.t("Виберіть пісню — тут буде її текст", "Pick a song — its words will show here"));
        songText.setHintTextColor(Ui.FAINT);
        songText.setLineSpacing(Ui.dp(2), 1f);
        songText.setPadding(Ui.dp(14), Ui.dp(12), Ui.dp(14), Ui.dp(14));
        scroller.addView(songText);
        columns.addView(pane(songList), Ui.lp(0, Ui.FILL, 1, 3));
        columns.addView(pane(scroller), Ui.lp(0, Ui.FILL, 1, 3));

        LinearLayout content = Ui.col(this);
        content.addView(columns, Ui.lp(Ui.FILL, 0, 1));
        content.addView(addRow(Ui.plain(getString(R.string.s_add_song)), this::addSong));
        songsBody = content;
        panel.addView(content, Ui.lp(Ui.FILL, 0, 1));
        return panel;
    }

    /// Ряд із головною кнопкою «Додати … в план»: на широкому екрані вона
    /// стоїть праворуч, на вузькому — на всю ширину.
    private LinearLayout addRow(String title, Runnable action) {
        LinearLayout bottom = Ui.row(this);
        TextView add = Ui.primary(this, R.drawable.ic_plan_add, title, action);
        if (wide) {
            add.setMaxLines(1);
            add.setPadding(Ui.dp(18), 0, Ui.dp(18), 0);
            bottom.addView(Ui.gap(this));
            bottom.addView(add, Ui.lp(Ui.WRAP, Ui.dp(48), 0, 3));
        } else {
            bottom.addView(add, Ui.lp(0, Ui.dp(48), 1, 3));
        }
        return bottom;
    }

    private void reloadSongbooks() {
        songbooks.clear();
        songbooks.addAll(library.modules(Library.SONGS));
        if (songbooks.isEmpty()) {
            songbook = null;
            showSongbooks();
            return;
        }
        String last = prefs().getString("songbook", "");
        int position = 0;
        for (int i = 0; i < songbooks.size(); i++) if (songbooks.get(i).id.equals(last)) position = i;
        chooseSongbook(position);
        showSongbooks();
    }

    private void showSongbooks() {
        boolean empty = songbooks.isEmpty();
        songsEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);
        songsHint.setVisibility(empty ? View.GONE : View.VISIBLE);
        songsTop.setVisibility(empty ? View.GONE : View.VISIBLE);
        songsBody.setVisibility(empty ? View.GONE : View.VISIBLE);
        Ui.setText(songbookButton, songbook == null ? getString(R.string.t_songbook) : songbook.name);
    }

    private void pickSongbook() {
        String[] names = new String[songbooks.size()];
        int checked = -1;
        for (int i = 0; i < songbooks.size(); i++) {
            names[i] = songbooks.get(i).name;
            if (songbook != null && songbooks.get(i).id.equals(songbook.id)) checked = i;
        }
        Ui.pick(this, getString(R.string.t_songbook), names, checked, which -> {
            chooseSongbook(which);
            showSongbooks();
        });
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
        songShown = "";
        songText.setText("");
        if (songbook == null) {
            songRows.set(songs);
            return;
        }
        songs.addAll(library.songs(songbook.id, songFilter.getText().toString(), 400));
        songRows.set(songs);
    }

    private void chooseSong(int position) {
        if (songbook == null || position < 0 || position >= songs.size()) return;
        song = songs.get(position);
        songRows.notifyDataSetChanged();
        StringBuilder text = new StringBuilder();
        for (Library.Part part : library.parts(songbook.id, song.index)) {
            if (text.length() > 0) text.append("\n\n");
            if (!part.kind.isEmpty()) text.append(part.kind).append('\n');
            text.append(part.text);
        }
        songShown = text.toString();
        songText.setText(songShown);
    }

    private void addSong() {
        if (songbook == null || song == null) {
            Ui.toast(this, Lang.t("Спершу виберіть пісню", "Pick a song first"));
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
        return centred(Ui.empty(this, R.drawable.ic_folder, Lang.t("Файл у план", "A file for the plan"),
            getString(R.string.s_file_hint), Ui.plain(getString(R.string.s_pick_file)), () -> pick(PICK_FILE, PLAN_TYPES)));
    }

    private View textPanel() {
        LinearLayout panel = Ui.col(this);
        panel.addView(Ui.hint(this, tidy(getString(R.string.s_hint_text))));
        textHeading = Ui.field(this, getString(R.string.t_text_title_hint), false);
        textHeading.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        textHeading.setText(keptHeading);
        textBody = Ui.field(this, getString(R.string.t_text_body_hint), true);
        textBody.setText(keptBody);
        panel.addView(textHeading, Ui.lp(Ui.FILL, Ui.dp(48), 0, 3));
        panel.addView(textBody, Ui.lp(Ui.FILL, 0, 1, 3));
        panel.addView(addRow(Ui.plain(getString(R.string.s_text_add)), this::addText));
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
            Ui.toast(this, getString(R.string.s_failed, error.getMessage()));
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

    /// Права колонка: картка з лічильником, кнопками порядку й списком
    /// пунктів, під нею — головна дія екрана і стан зв'язку.
    private View planColumn() {
        LinearLayout right = Ui.col(this);
        LinearLayout card = Ui.card(this);
        card.setClipToOutline(true);

        LinearLayout tools = Ui.row(this);
        tools.setGravity(Gravity.CENTER_VERTICAL);
        tools.setPadding(Ui.dp(16), Ui.dp(7), Ui.dp(7), Ui.dp(3));
        planCount = Ui.label(this, getString(R.string.s_plan_count, 0), 18, Ui.TEXT);
        planCount.setTypeface(Ui.MEDIUM);
        planCount.setMaxLines(1);
        tools.addView(planCount, Ui.lp(0, Ui.WRAP, 1));
        ImageView up = Ui.iconButton(this, R.drawable.ic_up, Ui.CARD2, () -> move(-1));
        ImageView down = Ui.iconButton(this, R.drawable.ic_down, Ui.CARD2, () -> move(1));
        ImageView remove = Ui.iconButton(this, R.drawable.ic_delete, Ui.CARD2, this::removeSelected);
        up.setContentDescription(Ui.plain(getString(R.string.t_up)));
        down.setContentDescription(Ui.plain(getString(R.string.t_down)));
        remove.setContentDescription(Ui.plain(getString(R.string.t_remove)));
        Ui.explain(up, getString(R.string.x_up));
        Ui.explain(down, getString(R.string.x_down));
        Ui.explain(remove, getString(R.string.x_remove));
        for (ImageView button : new ImageView[] {up, down, remove}) tools.addView(button, Ui.lp(Ui.dp(44), Ui.dp(44), 0, 3));
        card.addView(tools);

        FrameLayout holder = new FrameLayout(this);
        planList = Ui.list(this, planRows);
        planList.setOnItemClickListener((parent, view, position, id) -> {
            selected = position;
            planRows.select(position);
        });
        holder.addView(planList, Ui.fill());
        planEmpty = centred(Ui.empty(this, R.drawable.ic_plan, Lang.t("Пунктів ще немає", "No items yet"),
            getString(R.string.s_plan_empty), null, null));
        holder.addView(planEmpty, Ui.fill());
        card.addView(holder, Ui.lp(Ui.FILL, 0, 1));
        orderHint = Ui.hint(this, getString(R.string.s_hint_order));
        card.addView(orderHint);
        right.addView(card, Ui.lp(Ui.FILL, 0, 1));

        TextView upload = Ui.primary(this, R.drawable.ic_upload, Ui.plain(getString(R.string.s_upload)), this::upload);
        upload.setTextSize(17);
        upload.setMaxLines(1);
        Ui.explain(upload, getString(R.string.x_upload));
        right.addView(upload, Ui.lp(Ui.FILL, Ui.dp(56), 0, 0, 8, 0, 0));
        linkState = Ui.label(this, "", 12.5f, Ui.DIM);
        linkState.setGravity(Gravity.CENTER);
        linkState.setPadding(Ui.dp(8), Ui.dp(5), Ui.dp(8), 0);
        right.addView(linkState);
        return right;
    }

    private void addItem(SermonPlan.Item item) {
        plan.items.add(item);
        selected = plan.items.size() - 1;
        refreshPlan();
        savePlan();
        Ui.toast(this, getString(R.string.s_loaded, item.title));
    }

    private void refreshPlan() {
        if (selected >= plan.items.size()) selected = plan.items.size() - 1;
        planRows.set(plan.items);
        planRows.select(selected);
        boolean empty = plan.items.isEmpty();
        planEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);
        planList.setVisibility(empty ? View.GONE : View.VISIBLE);
        planCount.setText(getString(R.string.s_plan_count, plan.items.size()));
        orderHint.setVisibility(plan.items.size() > 1 ? View.VISIBLE : View.GONE);
        for (int i = 0; i < steps.size(); i++) {
            boolean current = empty ? i == 0 : i == 2;
            steps.get(i).setTextColor(current ? 0xFFFFFFFF : Ui.DIM);
            steps.get(i).setBackground(current ? Ui.gradient(Ui.ACCENT, Ui.ACCENT2, 12) : Ui.round(Ui.CARD2, 12));
        }
        Ui.setText(plansButton, getString(R.string.s_plans_count, SermonPlan.all(this).size()));
        // Вибраний пункт — на видноті: щойно доданий чи посунутий не ховається за краєм списку.
        if (selected >= 0) {
            ListView list = planList;
            int at = selected;
            list.post(() -> list.smoothScrollToPosition(at));
        }
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

    /// «Мої плани»: новий план, збережені й останнім рядком — видалити відкритий.
    private void choosePlan() {
        List<SermonPlan> saved = SermonPlan.all(this);
        String[] labels = new String[saved.size() + 2];
        labels[0] = Ui.plain(getString(R.string.s_new_plan));
        for (int i = 0; i < saved.size(); i++) {
            SermonPlan item = saved.get(i);
            String title = item.title.trim().isEmpty() ? getString(R.string.s_untitled) : item.title.trim();
            labels[i + 1] = getString(R.string.s_plan_items, title, item.items.size());
        }
        labels[labels.length - 1] = getString(R.string.s_delete_plan);
        Ui.menu(this, getString(R.string.s_plans), labels, which -> {
            if (which == 0) {
                openPlan(new SermonPlan());
            } else if (which <= saved.size()) {
                openPlan(saved.get(which - 1));
            } else {
                confirmDeletePlan();
            }
        });
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
        Ui.confirm(this, getString(R.string.s_delete_plan), getString(R.string.s_delete_plan_confirm, title),
            getString(R.string.s_delete), () -> {
                plan.delete(this);
                List<SermonPlan> left = SermonPlan.all(this);
                openPlan(left.isEmpty() ? new SermonPlan() : left.get(0));
            });
    }

    // MARK: Бібліотека

    /// Бібліотека планшета вікном знизу: що вже є (дотик — прибрати) і звідки взяти ще.
    private void openLibrary() {
        List<Library.Module> all = new ArrayList<>(library.modules(Library.BIBLE));
        all.addAll(library.modules(Library.SONGS));
        Dialog[] sheet = new Dialog[1];
        LinearLayout box = Ui.col(this);
        if (all.isEmpty()) {
            TextView note = Ui.label(this, getString(R.string.s_library_empty), 15, Ui.DIM);
            note.setLineSpacing(Ui.dp(3), 1f);
            note.setPadding(Ui.dp(22), 0, Ui.dp(22), Ui.dp(4));
            box.addView(note);
        } else {
            Ui.Rows<Library.Module> rows = new Ui.Rows<Library.Module>() {
                @Override
                String title(Library.Module module) { return module.name; }

                @Override
                String sub(Library.Module module) {
                    String kind = getString(Library.BIBLE.equals(module.kind) ? R.string.s_kind_bible : R.string.s_kind_songs);
                    String source;
                    switch (module.source) {
                        case "slovo": source = getString(R.string.s_source_slovo); break;
                        case "github": source = getString(R.string.s_source_github); break;
                        default: source = getString(R.string.s_source_file); break;
                    }
                    return kind + " · " + source;
                }
            };
            rows.set(all);
            ListView list = Ui.list(this, rows);
            list.setOnItemClickListener((parent, view, position, id) -> {
                sheet[0].dismiss();
                confirmDeleteModule(all.get(position));
            });
            // Список бере стільки, скільки треба, а довгий гортається: кнопки під ним завжди видно.
            box.addView(list, Ui.lp(Ui.FILL, 0, 1));
            box.addView(Ui.hint(this, Lang.t("Дотик по рядку — прибрати його з планшета. Нижче — звідки взяти ще.",
                                             "Tap a row to remove it from the tablet. Below — where to get more.")),
                Ui.lp(Ui.FILL, Ui.WRAP, 0, 8, 0, 8, 0));
        }
        // У вузькому вікні (телефон) три кнопки зі значками в ряд не вміщаються — там лише підписи.
        boolean icons = Math.min(getResources().getDisplayMetrics().widthPixels, Ui.dp(600)) >= Ui.dp(520);
        LinearLayout buttons = Ui.row(this);
        buttons.setPadding(Ui.dp(16), Ui.dp(10), Ui.dp(16), Ui.dp(2));
        TextView slovo = Ui.button(this, icons ? R.drawable.ic_wifi : 0, getString(R.string.s_from_slovo), Ui.CARD2, () -> {
            sheet[0].dismiss();
            fromSlovo();
        });
        TextView github = Ui.button(this, icons ? R.drawable.ic_download : 0, getString(R.string.s_from_github), Ui.CARD2, () -> {
            sheet[0].dismiss();
            fromGithub();
        });
        TextView file = Ui.button(this, icons ? R.drawable.ic_folder : 0, getString(R.string.s_from_file), Ui.CARD2, () -> {
            sheet[0].dismiss();
            pick(PICK_MODULE, null);
        });
        for (TextView button : new TextView[] {slovo, github, file}) {
            if (!icons) button.setPadding(Ui.dp(6), Ui.dp(8), Ui.dp(6), Ui.dp(8));
            buttons.addView(button, Ui.lp(0, Ui.FILL, 1, 4));
        }
        box.addView(buttons);
        sheet[0] = Ui.sheet(this, getString(R.string.s_library_title), box);
    }

    private void confirmDeleteModule(Library.Module module) {
        Ui.confirm(this, getString(R.string.s_delete_module, module.name), null, getString(R.string.s_delete), () -> {
            library.delete(module.id);
            reloadBibles();
            reloadSongbooks();
        });
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
            Ui.toast(this, getString(R.string.s_need_connection));
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
            Ui.toast(this, getString(R.string.s_unsupported_file));
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
            Ui.toast(this, getString(R.string.s_nothing_new));
            return;
        }
        String[] labels = new String[offer.size()];
        for (int i = 0; i < offer.size(); i++) {
            String kind = getString(Library.BIBLE.equals(offer.get(i)[0]) ? R.string.s_kind_bible : R.string.s_kind_songs);
            labels[i] = kind + " · " + offer.get(i)[2];
        }
        Ui.multi(this, getString(R.string.s_choose), labels, getString(R.string.s_take), checked -> {
            List<String[]> chosen = new ArrayList<>();
            for (int i = 0; i < offer.size(); i++) if (checked[i]) chosen.add(offer.get(i));
            if (!chosen.isEmpty()) take.chosen(chosen);
        });
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
            Ui.toast(this, getString(R.string.s_upload_empty));
            return;
        }
        if (!settings.hasHost()) {
            Ui.toast(this, getString(R.string.s_need_connection));
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
        // Після завантаження — що далі: власник не мав звідки дізнатися.
        String help = getString(R.string.s_uploaded_help);
        Dialog dialog = Ui.info(this, getString(R.string.s_uploaded, added),
            notes.isEmpty() ? help : help + "\n\n" + join(notes).replace(", ", "\n"), getString(R.string.done), open);
        // Закрити можна лише кнопкою: вона й веде до пульта, де планом керують.
        dialog.setCancelable(false);
        dialog.setCanceledOnTouchOutside(false);
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
            if (in == null) throw new IOException(Lang.t("файл не відкривається", "the file does not open"));
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

    /// Рядок стану під кроками; порожній — ховається, щоб не тримати місце.
    private void setStatus(String text) {
        statusText = text == null ? "" : text;
        if (status == null) return;
        status.setText(statusText);
        status.setVisibility(statusText.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private static String join(List<String> parts) {
        StringBuilder out = new StringBuilder();
        for (String part : parts) {
            if (out.length() > 0) out.append(", ");
            out.append(part);
        }
        return out.toString();
    }

    @Override
    protected void onResume() {
        super.onResume();
        checkLink();
    }

    /// «Слово» на зв'язку чи ні — видно під кнопкою, ще до того, як її натиснули.
    private void checkLink() {
        if (linkState == null) return;
        if (!settings.hasHost()) {
            link(getString(R.string.s_need_connection), Ui.LIVE);
            return;
        }
        link(getString(R.string.s_checking), Ui.DIM);
        Api probe = api();
        new Thread(() -> {
            boolean reached;
            try { probe.state(0); reached = true; } catch (Exception error) { reached = false; }
            boolean online = reached;
            main.post(() -> link(getString(online ? R.string.s_online : R.string.s_offline), online ? Ui.GREEN : Ui.LIVE));
        }).start();
    }

    private void link(String text, int colour) {
        linkText = text;
        linkColour = colour;
        showLink();
    }

    private void showLink() {
        if (linkState == null) return;
        linkState.setText(linkText);
        linkState.setTextColor(linkColour);
    }

    /// Вид пункту словами — замість значків-емодзі перед назвою.
    private static String kindName(String type) {
        if (SermonPlan.SCRIPTURE.equals(type)) return Lang.t("Вірші", "Verses");
        if (SermonPlan.SONG.equals(type)) return Lang.t("Пісня", "Song");
        if (SermonPlan.FILE.equals(type)) return Lang.t("Файл", "File");
        return Lang.t("Текст", "Text");
    }
}
