package ua.church.slovo.remote;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.SpannableStringBuilder;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.SeekBar;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.ConnectException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Робочий екран планшета: уся програма — з планшета.
///
/// Власник: «далее сделать пульт для планшета, где будет полный функционал
/// программы». Телефон — пульт у руці проповідника: гортати, указка, Біблія.
/// Планшет — місце оператора: усі сім вкладок програми, План та Історія і
/// сам зал перед очима — те, що зараз на стіні, з указкою й наближенням.
///
/// Вигляд — той самий, що в «Слові» для Android (власник: «там меню и интерфейс
/// получились намного удобнее и лучше»): каркас `Shell` — розділи стовпчиком
/// ліворуч, вміст посередині, «Зал» і «Далі» з кнопками показу праворуч; на
/// телефоні — зал угорі, розділи смугою внизу.
///
/// Розділ планшета і вкладка програми — одне й те саме: від неї залежить,
/// що гортають «Далі» й «Назад». Тому дотик до розділу перемикає і програму,
/// а перемкнули на комп'ютері — планшет іде слідом. Розділ «План» — свій,
/// програму він не перемикає.
public final class TabletActivity extends Activity implements Shell.Host, HallPad.Host, SettingsPage.Host {

    private enum Mode {
        BIBLE("bible", R.string.t_tab_bible, R.drawable.ic_bible),
        SONGS("songs", R.string.t_tab_songs, R.drawable.ic_song),
        PRESENTATION("presentation", R.string.t_tab_presentation, R.drawable.ic_slides),
        MEDIA("media", R.string.t_tab_media, R.drawable.ic_media),
        PICTURES("pictures", R.string.t_tab_pictures, R.drawable.ic_image),
        SCREEN("screen", R.string.t_tab_screen, R.drawable.ic_cast),
        TEXT("text", R.string.t_tab_text, R.drawable.ic_text);

        final String key;
        final int title, icon;

        Mode(String key, int title, int icon) {
            this.key = key;
            this.title = title;
            this.icon = icon;
        }

        static Mode of(String key) {
            for (Mode mode : values()) if (mode.key.equals(key)) return mode;
            return null;
        }
    }

    /// Номер розділу «План» у переліку розділів — одразу за вкладками програми.
    private static final int PLAN = Mode.values().length;

    /// Клітинка сітки мініатюр: слайд презентації чи картинка.
    private static final class Thumb {
        final String title;
        final boolean current;
        final Runnable tap;
        /// Адреса мініатюри на сервері.
        final String key;
        /// Меню «⋮» у кутку мініатюри; `null` — без нього.
        Runnable menu;

        Thumb(String title, boolean current, Runnable tap, String key) {
            this.title = title;
            this.current = current;
            this.tap = tap;
            this.key = key;
        }
    }

    private static final int PICK_FILE = 7, PICK_PHOTO = 8;

    private Settings settings;
    private volatile Api api;
    private ConnectivityManager.NetworkCallback wifiWatch;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService commands = Executors.newSingleThreadExecutor();
    private final ExecutorService reads = Executors.newSingleThreadExecutor();
    private final ExecutorService images = Executors.newFixedThreadPool(2);
    private final ExecutorService hallQueue = Executors.newSingleThreadExecutor();
    private Thread poller;
    private volatile boolean polling;
    private volatile long seq;
    private boolean resumed;
    /// Чи є зв'язок. Біблія вантажиться, коли він з'являється: планшет
    /// вмикають і раніше за комп'ютер — тоді перша спроба не вдається, і без
    /// повтору вкладка так і стояла з «Failed to connect».
    private boolean online;
    private State state = new State();
    private String link = "";
    private int linkColor = Ui.DIM;
    /// На смужці під шапкою висить скарга на зв'язок — її прибирає перша ж відповідь програми.
    private boolean linkTrouble;

    private Mode mode = Mode.BIBLE;
    /// Відкрито розділ «План» (він не вкладка програми).
    private boolean planOpen;
    private String followedMode = "";
    private boolean sideHistory;
    private int sideSelected = -1;

    // Вікно: каркас, картки, плитки. Будуються наново після повороту, зміни
    // масштабу чи мови; стан живе в полях, не у видах.
    private Shell shell;
    private SlideCard liveCard, nextCard;
    private volatile HallPad pad;
    private TextView blackTile, blankTile, zoomBack;
    private ImageView hintsButton;
    private View[] panels;
    /// Рядки-підказки на екрані (ховає кнопка «?» вгорі).
    private final List<View> hintViews = new ArrayList<>();
    /// Мій перегляд: текст слайда поверх місця картинки залу.
    private TextView personalView;
    private BibleBrowser bible;

    // Пісні: увесь пісенник тримаємо тут і відбираємо без мережі.
    private JSONArray songs = new JSONArray();
    private String songsBook = "", songsBookTitle = "";
    private String songFilter = "";
    /// Перелік пісень уже приходив: доти під пошуком «Завантажую…», а не «порожньо».
    private boolean songsLoaded;
    private String partsSignature = "";
    private final Lines songLines = new Lines();
    private TextView songBookButton, songNote;
    private ListView songList;
    private LinearLayout partButtons;
    /// Яку пісню показано підсвіченою в переліку — щоб не перемальовувати
    /// його на кожну відповідь програми.
    private String shownSongTitle = "";

    // Презентація й зображення: сітки мініатюр.
    private final List<Thumb> pageThumbs = new ArrayList<>();
    private final List<Thumb> pictureThumbs = new ArrayList<>();
    private final ThumbAdapter pageAdapter = new ThumbAdapter(pageThumbs);
    private final ThumbAdapter pictureAdapter = new ThumbAdapter(pictureThumbs);
    private String gridSignature = "";
    private LinearLayout deckButtons;
    private TextView deckNote;
    private View pagesEmpty, pagesGrid, picturesEmpty, picturesGrid;
    private int picturesCount = -1;
    private String picturesSeen = "";
    private final Map<String, Bitmap> thumbs = new HashMap<>();
    private final Set<String> thumbsLoading = new HashSet<>();

    // Плеєр: стан приходить окремим запитом раз на секунду, поки розділ відкрито.
    private ImageView mediaPlay;
    private TextView mediaMute, mediaScreen, mediaRepeat, mediaTitle, mediaTime, mediaNote;
    private SeekBar mediaSeek, mediaVolume;
    private boolean seekDragging, volumeDragging;
    private double mediaDuration;
    private final Lines mediaLines = new Lines();
    private String mediaListSignature = "";
    /// Що плеєр показував минулого разу: той самий стан — екран не чіпаємо.
    /// Опитування йде щосекунди, і без цього панель без кінця перемальовувалась.
    private String mediaShown = "";

    // Екран.
    private final Lines screenLines = new Lines();
    private TextView screenNote;
    private View screenEmpty, screenList;
    private int screenRetries;

    // Текст.
    private EditText textTitle, textBody;
    private TextView textPages;
    private String textTitleValue = "", textBodyValue = "";
    private int textPage, textPageCount;

    // План та Історія.
    private final Lines sideLines = new Lines();
    private TextView tabPlan, tabHistory, sideNote, sermonOpen, sermonEnd, planAdd, planHint;
    private View planUp, planDown;
    private JSONArray history = new JSONArray();
    private long historySeq = -1;

    // Зал.
    private Bitmap hallBitmap;
    private volatile boolean hallBusy;
    private volatile boolean hallPending;
    private long hallSeq = -1;
    /// Коли востаннє просили картинку залу — не частіше ніж раз на 0,6 с.
    private long hallAskedAt;
    private boolean hallLater;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            if (!resumed) return;
            if (mode == Mode.MEDIA && !planOpen) loadMedia();
            main.postDelayed(this, 1000);
        }
    };

    /// Мова й масштаб інтерфейсу (див. `Lang`, `UiScale`) — до того, як вікно візьме ресурси.
    @Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        applyOverrideConfiguration(Lang.override(base, UiScale.override(base)));
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        settings = new Settings(this);
        Stand.connect(this, getIntent());
        if (!settings.hasHost()) {
            startActivity(new Intent(this, ConnectActivity.class));
            finish();
            return;
        }
        Ui.init(this);
        UiScale.applyOrientation(this);
        bible = new BibleBrowser(this, new BibleBrowser.Host() {
            @Override
            public Api api() { return api; }

            @Override
            public ExecutorService queue() { return commands; }

            @Override
            public void post(Runnable body) { main.post(body); }
        });
        if (getIntent().getBooleanExtra("sermon", false)) planOpen = true;
        buildShell();
        stand(getIntent());
        // Нова версія програми: питаємо GitHub раз на добу, мовчки.
        Updates.checkQuietly(this);
        // Власник: «если программа для планшета запущена на телефоне, выдать
        // сообщение, что программа не адаптирована для телефона и для
        // полноценного пользования ее нужно запускать именно с планшета (но
        // запустить и выполнить адаптацию под дисплей телефона)».
        if (saved == null && getResources().getConfiguration().smallestScreenWidthDp < 600 && !Stand.on(this)) {
            Ui.info(this, getString(R.string.phone_title), getString(R.string.phone_message), getString(R.string.phone_ok), null);
        }
    }

    /// Щойно надіслали план проповіді — одразу до нього.
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (intent.getBooleanExtra("sermon", false) && shell != null) {
            sideHistory = false;
            openPlan();
        }
        stand(intent);
    }

    /// Стенд: раз на 2 с — скільки запитів якого роду пішло (`adb logcat -s SlovoNet`).
    private final Runnable meterTick = new Runnable() {
        @Override
        public void run() {
            String line = Api.meterLine();
            if (!line.isEmpty()) android.util.Log.i(Api.TAG, "за 2 с: " + line);
            main.postDelayed(this, 2000);
        }
    };

    /// Команди стенда (див. `Stand`): розділ і сторінка налаштувань без дотиків.
    private void stand(Intent intent) {
        String wanted = Stand.tab(this, intent);
        if (wanted != null && shell != null) {
            if ("plan".equals(wanted)) {
                openPlan();
            } else if ("history".equals(wanted)) {
                sideHistory = true;
                openPlan();
            } else {
                Mode chosen = Mode.of(wanted);
                if (chosen != null) chooseMode(chosen, true);
            }
        }
        String lang = Stand.word(this, intent, "lang");
        if (lang != null) {
            getSharedPreferences("slovo-remote", MODE_PRIVATE).edit().putString("language", lang).apply();
            recreate();
            return;
        }
        String scale = Stand.word(this, intent, "scale");
        if (scale != null) {
            try { settings.setUiScale(Float.parseFloat(scale)); } catch (NumberFormatException ignored) { }
            recreate();
            return;
        }
        if ("1".equals(Stand.word(this, intent, "pinch")) && pad != null) pad.rehearsePinch();
        if ("1".equals(Stand.word(this, intent, "meter"))) {
            main.removeCallbacks(meterTick);
            Api.meterLine();
            main.postDelayed(meterTick, 2000);
        }
        String open = Stand.word(this, intent, "open");
        if ("settings".equals(open)) onSettings();
        else if ("view".equals(open)) SettingsPage.view(this, this::settingsChanged);
        else if ("sermon".equals(open)) openSermon();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings == null || !settings.hasHost()) return;
        Ui.init(this);
        resumed = true;
        applyAwake();
        api = new Api(settings.host(), settings.port(), settings.pin());
        watchWiFi();
        linkState(getString(R.string.status_connecting, describeServer()), Ui.WARN);
        online = false;
        // Перше питання — без очікування зміни: інакше після повернення у вікно
        // (вибір файла, інша програма) стан «З'єднуюся…» висів би до пів хвилини,
        // поки в залі щось не зміниться.
        seq = 0;
        startPolling();
        main.post(tick);
    }

    @Override
    protected void onPause() {
        super.onPause();
        resumed = false;
        main.removeCallbacks(tick);
        stopPolling();
        unwatchWiFi();
    }

    @Override
    protected void onDestroy() {
        if (pad != null) pad.shutdown();
        super.onDestroy();
    }

    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        if (shell == null) return;
        buildShell();
    }

    @Override
    public void onBackPressed() {
        if (!planOpen && mode == Mode.BIBLE && bible.back()) return;
        super.onBackPressed();
    }

    // MARK: Вікно

    /// Скласти вікно наново: під поворот, розмір, масштаб і мову.
    private void buildShell() {
        Ui.init(this);
        // Набране в «Тексті» переживає перебудову вікна.
        if (textBody != null) {
            textTitleValue = textTitle.getText().toString();
            textBodyValue = textBody.getText().toString();
        }
        if (pad != null) pad.shutdown();
        hintViews.clear();
        shell = new Shell(this, this);
        for (Mode each : Mode.values()) shell.tab(each.icon, navTitle(each));
        shell.tab(R.drawable.ic_plan, getString(R.string.t_plan));

        blackTile = Ui.tool(this, R.drawable.ic_black, Lang.t("Чорний екран", "Black screen"), () -> send("black"));
        Ui.explain(blackTile, getString(R.string.x_black));
        blankTile = Ui.tool(this, R.drawable.ic_hide, getString(R.string.t_blank), () -> send("blank"));
        Ui.explain(blankTile, getString(R.string.x_blank));
        TextView planTile = Ui.tool(this, R.drawable.ic_plan_add, Lang.t("У План", "To Plan"), () -> {
            send("plan-add");
            say(Lang.t("Вибране додано до Плану", "The selection is added to the Plan"));
        });
        Ui.explain(planTile, getString(R.string.x_plan_add));
        TextView viewTile = Ui.tool(this, R.drawable.ic_palette, Lang.t("Вигляд", "View"), () -> SettingsPage.view(this, this::settingsChanged));
        Ui.explain(viewTile, Lang.t("Мій перегляд: зал картинкою, як на стіні, або текстом у своєму оформленні",
                                    "My view: the hall as a picture, as on the wall, or as text in my own style"));
        hintsButton = Ui.iconButton(this, R.drawable.ic_help, 0x00000000, () -> {
            settings.setHints(!settings.hints());
            applyHints();
            say(getString(settings.hints() ? R.string.t_hints_on : R.string.t_hints_off));
        });
        hintsButton.setContentDescription(getString(R.string.t_hints));
        Ui.explain(hintsButton, getString(R.string.x_hints));
        setContentView(shell.build(getString(R.string.app_name), new TextView[] {blackTile, blankTile, planTile, viewTile}, hintsButton));

        liveCard = new SlideCard(this, shell.stack);
        liveCard.picture();
        nextCard = new SlideCard(this, shell.stack);
        personalView = new TextView(this);
        personalView.setGravity(Gravity.CENTER);
        personalView.setPadding(Ui.dp(16), Ui.dp(14), Ui.dp(16), Ui.dp(14));
        personalView.setVisibility(View.GONE);
        liveCard.frame.addView(personalView, Ui.fill());
        // Розмір картки стає відомий після розкладки (і міняється з поворотом) — тоді й підганяємо текст.
        personalView.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
            if (r - l != or - ol || b - t != ob - ot) v.post(this::applyPersonal);
        });
        pad = new HallPad(this, this, liveCard.image, liveCard.pointer);
        zoomBack = SlideCard.zoomBack(this, pad::resetZoom);
        Ui.explain(zoomBack, getString(R.string.x_zoom_back));
        liveCard.corner(zoomBack, Gravity.TOP | Gravity.END);
        pad.onChange = () -> zoomBack.setVisibility(pad.zoomed() ? View.VISIBLE : View.GONE);
        Ui.explain(liveCard.frame, getString(R.string.t_hint_hall));
        // Стовпчиком (планшет): зал згори, «Далі» під ним; рядом (телефон): «Далі» ліворуч, зал праворуч.
        if (shell.stack) shell.cards(liveCard, nextCard); else shell.cards(nextCard, liveCard);

        panels = new View[] {
            buildBible(), buildSongs(), buildPresentation(), buildMedia(), buildPictures(), buildScreen(), buildText(), buildPlan(),
        };
        shell.status(link, linkColor);
        if (hallBitmap != null) pad.set(hallBitmap);
        if (planOpen) openPlan(); else chooseMode(mode, false);
        render();
        applyHints();
    }

    /// Короткі назви розділів — щоб уміщалися і в смузі внизу на телефоні.
    private String navTitle(Mode each) {
        switch (each) {
            case PRESENTATION: return Lang.t("Слайди", "Slides");
            case PICTURES: return Lang.t("Фото", "Photos");
            default: return getString(each.title);
        }
    }

    private void linkState(String text, int color) {
        link = text;
        linkColor = color;
        if (shell != null) shell.status(text, color);
    }

    private void say(String text) {
        if (shell != null) shell.note(text);
    }

    @Override
    public void onTab(int index) {
        if (index == PLAN) openPlan(); else chooseMode(Mode.values()[index], true);
    }

    @Override
    public void onSettings() { SettingsPage.show(this, this); }

    @Override
    public void onStatus() {
        Ui.menu(this, describeServer(), settings.host() + ":" + settings.port() + "\n" + link,
            new String[] { Ui.plain(getString(R.string.menu_connection)).replace("…", "") }, which -> {
                startActivity(new Intent(this, ConnectActivity.class));
                finish();
            });
    }

    @Override
    public void onPrev() { send("prev"); }

    @Override
    public void onNext() { send("next"); }

    /// «Показати»: на Біблії з вибраними віршами — саме їх; інакше — те, що в передпоказі програми.
    @Override
    public void onShow() {
        if (!planOpen && mode == Mode.BIBLE && bible.hasPicked()) bible.showPicked();
        else send("show");
    }

    @Override
    public void onHide() { send("hide"); }

    // MARK: Налаштування (сторінка `SettingsPage`)

    @Override
    public void settingsChanged() {
        applyAwake();
        if (pad != null) pad.look();
        applyHints();
        applyPersonal();
        if (pad != null && !settings.previewText()) pad.show();
    }

    @Override
    public void resetZoom() {
        if (pad != null) pad.resetZoom();
    }

    @Override
    public String linkState() { return link; }

    @Override
    public void openSermon() { startActivity(new Intent(this, SermonActivity.class)); }

    // MARK: HallPad.Host

    @Override
    public Api api() { return api; }

    @Override
    public State state() { return state; }

    // MARK: Мережа

    private void watchWiFi() {
        if (wifiWatch != null) return;
        ConnectivityManager manager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager == null) return;
        NetworkRequest request = new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build();
        wifiWatch = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                Api current = api;
                if (current != null) current.useNetwork(network);
            }

            @Override
            public void onLost(Network network) {
                Api current = api;
                if (current != null) current.useNetwork(null);
            }
        };
        try {
            manager.registerNetworkCallback(request, wifiWatch);
        } catch (Exception error) {
            wifiWatch = null;
        }
    }

    private void unwatchWiFi() {
        if (wifiWatch == null) return;
        ConnectivityManager manager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager != null) {
            try { manager.unregisterNetworkCallback(wifiWatch); } catch (Exception ignored) { }
        }
        wifiWatch = null;
    }

    private String describeServer() {
        String name = settings.name();
        return name.isEmpty() ? settings.host() : name;
    }

    private void applyAwake() {
        if (settings.keepAwake()) {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else {
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
    }

    // MARK: Запити

    private interface Got { void json(JSONObject json); }

    private void read(String path, Got then) {
        Api current = api;
        if (current == null) return;
        reads.execute(() -> {
            try {
                JSONObject json = current.get(path);
                main.post(() -> then.json(json));
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void send(String command, JSONObject body, Runnable after) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.command(command, body);
                if (after != null) main.post(after);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void send(String command) { send(command, null, null); }

    private void send(String command, int index) { send(command, body("index", index), null); }

    /// Вибрати без показу: у зал — лише «Показати» (власник 27.11: «показ слайдов и текстов
    /// происходить должен исключительно по кнопке показа»). «Слово» до 1.4.4 `live` не знає.
    private void choose(String command, int index) { send(command, body("index", index, "live", false), null); }

    private static JSONObject body(Object... pairs) {
        JSONObject json = new JSONObject();
        try {
            for (int i = 0; i + 1 < pairs.length; i += 2) json.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException ignored) { }
        return json;
    }

    /// Обрив зв'язку — «немає зв'язку»; відмова програми — її ж словами:
    /// «немає такого пункта» людині корисніше, ніж «помилка».
    private void showFailure(Exception error) {
        final Api current = api;
        main.post(() -> {
            if (error instanceof Api.PinRejected) {
                linkTrouble = true;
                linkState(Lang.t("Потрібен PIN", "PIN required"), Ui.LIVE);
                if (shell != null) shell.note(getString(R.string.status_pin), true);
            } else if ((error instanceof ConnectException || error instanceof SocketTimeoutException)
                    && current != null && current.silentFor() < 5000) {
                // Інші запити щойно пройшли — зв'язок є, загубився один запит.
                say(Lang.t("Запит не дійшов до «Слова» — спробуйте ще раз", "A request did not reach Slovo — try again"));
            } else if (error instanceof ConnectException || error instanceof SocketTimeoutException
                    || error instanceof UnknownHostException) {
                linkTrouble = true;
                linkState(Lang.t("Немає зв'язку", "No connection"), Ui.LIVE);
                if (shell != null) shell.note(getString(R.string.status_lost, describeServer()), true);
            } else {
                String why = error.getMessage();
                say(why == null || why.isEmpty() ? error.toString() : why);
            }
        });
    }

    // MARK: Опитування стану

    private void startPolling() {
        stopPolling();
        polling = true;
        final Api current = api;
        poller = new Thread(() -> {
            int failures = 0;
            long asked = 0;
            while (polling) {
                try {
                    // Своя указка будить опит до дванадцяти разів на секунду, а
                    // пляму під пальцем малює сам планшет — питаємо до трьох разів.
                    HallPad hand = pad;
                    if (hand != null && hand.pointing()) {
                        long wait = asked + 350 - System.currentTimeMillis();
                        if (wait > 0) sleep(wait);
                    }
                    asked = System.currentTimeMillis();
                    State fresh = current.state(seq);
                    failures = 0;
                    if (!polling) break;
                    seq = fresh.seq;
                    main.post(() -> apply(fresh));
                } catch (Api.PinRejected rejected) {
                    showFailure(rejected);
                    sleep(3000);
                } catch (Exception error) {
                    failures++;
                    // Прив'язка до Wi-Fi могла застаріти — після трьох невдач
                    // підряд пробуємо звичайною дорогою.
                    if (failures == 3 && current.isBound()) current.useNetwork(null);
                    // «Немає зв'язку» — коли НІЧОГО не відповідало 5 с: якщо указка,
                    // картинки чи команди тим часом доходять, зв'язок є.
                    if (failures >= 2 && current.silentFor() > 5000) {
                        final String why = Api.describe(error);
                        main.post(() -> {
                            online = false;
                            linkTrouble = true;
                            linkState(Lang.t("Немає зв'язку", "No connection"), Ui.LIVE);
                            if (shell != null) shell.note(getString(R.string.status_lost, describeServer()) + " (" + why + ")", true);
                        });
                    }
                    sleep(Math.min(5000, 800 * failures));
                }
            }
        }, "slovo-poll");
        poller.setDaemon(true);
        poller.start();
    }

    private void stopPolling() {
        polling = false;
        if (poller != null) poller.interrupt();
        poller = null;
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) { }
    }

    private void apply(State fresh) {
        state = fresh;
        Mode programMode = Mode.of(fresh.mode);
        String name = fresh.name.isEmpty() ? describeServer() : fresh.name;
        linkState(name + (programMode == null ? "" : " · " + getString(programMode.title)), Ui.GREEN);
        if (linkTrouble) {
            linkTrouble = false;
            say("");
        }
        if (!online) {
            online = true;
            bible.open();
            if (!planOpen && mode != Mode.BIBLE) enter(mode);
        }
        // Перемкнули вкладку на комп'ютері — планшет іде слідом. Із «Плану» не
        // зриваємо: дотик по його пункту сам перемикає вкладку програми, і без
        // цього план тікав би з-під пальця після кожного пункту.
        if (programMode != null && !fresh.mode.equals(followedMode)) {
            followedMode = fresh.mode;
            if (programMode != mode && !planOpen) chooseMode(programMode, false);
        }
        render();
    }

    /// Намалювати все зі стану: картки, плитки, списки відкритого розділу.
    private void render() {
        if (shell == null) return;
        State s = state;
        Mode programMode = Mode.of(s.mode);
        shell.mark(programMode == null ? -1 : programMode.ordinal());
        Ui.toolState(blackTile, Lang.t("Чорний екран", "Black screen"), s.black, Ui.LIVE);
        Ui.toolState(blankTile, getString(R.string.t_blank), s.blank, Ui.WARN);
        shell.hideBtn.setAlpha(s.live ? 1f : 0.55f);

        String liveName = applyHall(s);
        boolean hasNext = !s.previewText.isEmpty() || !s.previewReference.isEmpty();
        String nextName = !hasNext ? Lang.t("виберіть, що показати", "pick what to show")
            : s.previewReference.isEmpty() ? firstWords(s.previewText) : s.previewReference;
        nextCard.text(s.previewReference, s.previewText, nextName);
        nextCard.border(hasNext ? Ui.WARN : Ui.CARD3);
        nextCard.pill(Lang.t("Далі", "Next"), Ui.WARN);
        nextCard.title(nextName);
        boolean onAir = onAir(s);
        shell.strip(("black".equals(s.hallKind) ? Lang.t("Чорний екран", "Black screen") : getString(R.string.t_hall)) + ": " + liveName, onAir,
                    Lang.t("Далі", "Next") + ": " + (hasNext ? nextName : "—"));

        // План — зі стану; Історію перечитуємо, коли стан змінився.
        if (sideHistory) {
            if (s.seq != historySeq) loadHistory();
        } else {
            fillPlan();
        }
        // План проповіді заступив план служіння: видно, чий план, і є чим
        // повернути план служіння.
        renderSide();

        switch (mode) {
            case BIBLE:
                // Вірш перемкнули на комп'ютері або з іншого пульта —
                // підсвічення на планшеті переїжджає слідом.
                bible.follow(s.biblePosition, s.bibleChapter, s.bibleVerses);
                break;
            case SONGS:
                if (!s.songBook.equals(songsBook)) loadSongs();
                // Пісню перемкнули не звідси: у переліку теж має бути видно,
                // на якій стоїть програма.
                else if (!s.songTitle.equals(shownSongTitle)) {
                    shownSongTitle = s.songTitle;
                    fillSongs();
                    scrollToCurrentSong();
                }
                fillParts();
                break;
            case PRESENTATION:
                fillPresentation();
                break;
            case PICTURES:
                // Новіше «Слово» каже про список фото й тоді, коли програма на іншій вкладці.
                if (!s.pictures.isEmpty() && !s.pictures.equals(picturesSeen)) {
                    picturesSeen = s.pictures;
                    loadPictures();
                } else if (s.showCount != picturesCount && "pictures".equals(s.mode)) loadPictures();
                break;
            default:
                break;
        }
    }

    /// Чи є щось у залі. Порожнє тло після «Сховати» «Слово» називає текстом без слів — це не ефір.
    private static boolean onAir(State s) {
        if ("still".equals(s.hallKind) || "video".equals(s.hallKind)) return true;
        return "text".equals(s.hallKind) && (!s.liveText.isEmpty() || !s.liveReference.isEmpty());
    }

    private static String firstWords(String text) {
        String flat = text.replace('\n', ' ').trim();
        return flat.length() > 48 ? flat.substring(0, 48) + "…" : flat;
    }

    // MARK: Зал

    /// Картка «Зал»: картинку перезабираємо, коли змінився стан, і не частіше,
    /// ніж встигає прийти попередня. Відео й затемнення не тягнемо — пишемо.
    /// Повертає назву того, що в залі.
    private String applyHall(State fresh) {
        String kind = fresh.hallKind;
        boolean onAir = onAir(fresh);
        String name;
        if ("text".equals(kind) && onAir) name = fresh.liveReference.isEmpty() ? firstWords(fresh.liveText) : fresh.liveReference;
        else if (("still".equals(kind) || "video".equals(kind)) && !fresh.hallTitle.isEmpty()) name = fresh.hallTitle;
        else if ("black".equals(kind)) name = getString(R.string.t_hall_black);
        else name = Lang.t("нічого не показано", "nothing is shown");
        liveCard.title(name);
        liveCard.pill("black".equals(kind) ? Lang.t("Чорний", "Black") : getString(R.string.t_hall), onAir ? Ui.LIVE : 0xFF4A5568);
        liveCard.border(onAir ? Ui.LIVE : Ui.CARD3);
        applyPersonal();

        if ("video".equals(kind)) {
            hallBitmap = null;
            pad.set(null);
            liveCard.note(getString(R.string.t_hall_video, fresh.hallTitle));
            return name;
        }
        if ("black".equals(kind)) {
            hallBitmap = null;
            pad.set(null);
            liveCard.note(getString(R.string.t_hall_black));
            return name;
        }
        liveCard.note("empty".equals(kind) ? getString(R.string.t_hall_empty) : "");
        // Картинку залу — за `hallSeq`, а не за номером стану. Власник: «постоянные
        // обрывы связи при использовании указки и зума». Номер стану росте від
        // кожного руху указки (до 12 разів на секунду), і планшет щоразу тягнув
        // JPEG залу на сотні кілобайтів — десятки мегабіт по Wi-Fi.
        long mark = fresh.hallSeq >= 0 ? fresh.hallSeq : fresh.seq;
        if (mark != hallSeq) {
            hallSeq = mark;
            requestHall();
        } else {
            pad.show();
        }
        return name;
    }

    /// Мій перегляд: текстовий слайд — у своєму оформленні, а не картинкою
    /// залу. Власник: «текущий просмотр текста с зеленой обводкой на белом
    /// фоне, мягко говоря, не приятный» — картинка залу несе стиль стіни, а не
    /// екрана в руці. Картинки й презентації лишаються такими, як на стіні.
    private void applyPersonal() {
        if (personalView == null || state == null) return;
        boolean text = settings.previewText() && "text".equals(state.hallKind);
        liveCard.picture();
        personalView.setVisibility(text ? View.VISIBLE : View.GONE);
        liveCard.image.setVisibility(text ? View.INVISIBLE : View.VISIBLE);
        liveCard.pointer.setVisibility(text ? View.INVISIBLE : View.VISIBLE);
        if (!text) return;
        int[] colours = Settings.themeColours(settings.previewTheme());
        personalView.setBackgroundColor(colours[0]);
        personalView.setTextColor(colours[1]);
        SpannableStringBuilder shown = new SpannableStringBuilder();
        if (!state.liveReference.isEmpty()) {
            shown.append(state.liveReference);
            shown.setSpan(new RelativeSizeSpan(0.6f), 0, shown.length(), 0);
            shown.setSpan(new ForegroundColorSpan(colours[2]), 0, shown.length(), 0);
            shown.append("\n");
        }
        shown.append(state.liveText);
        // Картка залу менша за колишню колонку: вибраний розмір — стеля, а довгий
        // вірш зменшується, доки не вміститься (не дрібніше 14); лише коли й так
        // не влазить — прокрутка, як раніше.
        float size = settings.previewSize();
        int width = personalView.getWidth() - personalView.getPaddingLeft() - personalView.getPaddingRight();
        int height = personalView.getHeight() - personalView.getPaddingTop() - personalView.getPaddingBottom();
        if (width > 0 && height > 0) {
            android.text.TextPaint paint = new android.text.TextPaint(personalView.getPaint());
            float scaled = getResources().getDisplayMetrics().scaledDensity;
            boolean fits = false;
            while (true) {
                paint.setTextSize(size * scaled);
                android.text.StaticLayout fit = new android.text.StaticLayout(shown, paint, width,
                    android.text.Layout.Alignment.ALIGN_CENTER, 1f, 0f, true);
                fits = fit.getHeight() <= height;
                if (fits || size <= 14f) break;
                size -= 1f;
            }
            // На телефоні картка зовсім мала: і 14-й кегль не вміщається. Тоді — текстом-слайдом,
            // який сам стискається до розміру картки (як картка «Далі»), а не обрізаним віршем.
            if (!fits && height < Ui.dp(170)) {
                personalView.setVisibility(View.GONE);
                liveCard.text(state.liveReference, state.liveText, "");
                return;
            }
        }
        personalView.setTextSize(TypedValue.COMPLEX_UNIT_SP, size);
        personalView.setText(shown);
        // Довгий куплет більший за зал: посередині (Gravity.CENTER) його початок
        // ховався вгорі без прокрутки. Не влазить — ставимо згори й даємо
        // прокручувати пальцем; влазить — знову посередині.
        personalView.scrollTo(0, 0);
        personalView.post(() -> {
            android.text.Layout layout = personalView.getLayout();
            int room = personalView.getHeight() - personalView.getTotalPaddingTop() - personalView.getTotalPaddingBottom();
            boolean tall = layout != null && room > 0 && layout.getHeight() > room;
            personalView.setGravity(tall ? (Gravity.TOP | Gravity.CENTER_HORIZONTAL) : Gravity.CENTER);
            personalView.setMovementMethod(tall ? new android.text.method.ScrollingMovementMethod() : null);
        });
    }

    private void requestHall() {
        if (hallBusy) { hallPending = true; return; }
        final Api current = api;
        if (current == null) return;
        // Наближення теж міняє `hallSeq` (щипок — до 12 разів на секунду), хоча сама
        // картинка тоді та сама: планшет вирізає вікно сам. Тож не частіше ніж раз
        // на 0,6 с — і останнє прохання виконається обов'язково.
        long wait = hallAskedAt + 600 - System.currentTimeMillis();
        if (wait > 0) {
            if (!hallLater) {
                hallLater = true;
                main.postDelayed(() -> {
                    hallLater = false;
                    requestHall();
                }, wait);
            }
            return;
        }
        hallAskedAt = System.currentTimeMillis();
        hallBusy = true;
        hallPending = false;
        int shown = liveCard.image.getWidth();
        final int width = Math.max(480, Math.min(1600, shown > 0 ? shown : 1280));
        hallQueue.execute(() -> {
            Bitmap bitmap = null;
            try {
                byte[] bytes = current.image("/api/hall.jpg?w=" + width);
                if (bytes != null) bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            } catch (Exception ignored) { }
            final Bitmap got = bitmap;
            main.post(() -> {
                hallBusy = false;
                String kind = state.hallKind;
                if (got != null && !"video".equals(kind) && !"black".equals(kind)) {
                    hallBitmap = got;
                    liveCard.frame.ratio(got.getWidth() / (float) Math.max(1, got.getHeight()));
                    pad.set(got);
                }
                if (hallPending) requestHall();
            });
        });
    }

    // MARK: Розділи

    private void chooseMode(Mode chosen, boolean fromTouch) {
        mode = chosen;
        planOpen = false;
        if (fromTouch) {
            followedMode = chosen.key;
            send("mode", body("text", chosen.key), null);
        }
        shell.open(chosen.ordinal(), panels[chosen.ordinal()]);
        enter(chosen);
    }

    /// Розділ відкрили — перечитати його дані з програми.
    private void enter(Mode chosen) {
        switch (chosen) {
            case BIBLE:
                if (online) bible.open();
                break;
            case SONGS:
                partsSignature = "";
                loadSongs();
                fillParts();
                break;
            case PRESENTATION:
                gridSignature = "";
                fillPresentation();
                break;
            case MEDIA:
                mediaShown = "";
                loadMedia();
                break;
            case PICTURES:
                picturesCount = -1;
                loadPictures();
                break;
            case SCREEN:
                screenRetries = 0;
                loadScreen();
                break;
            case TEXT:
                loadText();
                break;
            default:
                break;
        }
    }

    private void openPlan() {
        planOpen = true;
        shell.open(PLAN, panels[PLAN]);
        chooseSide(sideHistory);
    }

    // MARK: Підказки

    /// Власник: «в планшете не понятно как добавить план в программу,
    /// интерфейс не очень удобный и местами не понятный и сложный, нужно
    /// переделать и добавить подсказки к действиям». Рядки-підказки над
    /// розділами (ховає «?» вгорі) і довгий дотик на кнопці, що каже, що
    /// вона робить (`Ui.explain`).
    private TextView hint(ViewGroup parent, String text) {
        TextView view = Ui.hint(this, text);
        parent.addView(view);
        hintViews.add(view);
        return view;
    }

    private void applyHints() {
        boolean on = settings.hints();
        for (View view : hintViews) view.setVisibility(on ? View.VISIBLE : View.GONE);
        if (planHint != null) planHint.setVisibility(on && !sideHistory ? View.VISIBLE : View.GONE);
        if (hintsButton != null) hintsButton.setImageDrawable(Ui.icon(this, R.drawable.ic_help, on ? Ui.ACCENT : Ui.DIM, 24));
        if (bible != null) bible.refresh();
    }

    // MARK: Біблія

    private View buildBible() {
        // Підказку Біблія показує сама (поки нічого не вибрано) і зважає на той самий перемикач підказок.
        return bible.build();
    }

    // MARK: Пісні

    private View buildSongs() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_songs));
        LinearLayout top = Ui.row(this);
        top.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(2));
        songBookButton = Ui.button(this, R.drawable.ic_song, "", Ui.CARD2, this::chooseSongBook);
        songBookButton.setMaxLines(1);
        songBookButton.setMaxWidth(Ui.dp(240));
        Ui.explain(songBookButton, getString(R.string.x_songbook));
        top.addView(songBookButton, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        EditText filter = Ui.search(this, getString(R.string.t_song_filter));
        filter.setText(songFilter);
        filter.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int c) { }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int c) { }

            @Override
            public void afterTextChanged(Editable s) {
                if (s.toString().equals(songFilter)) return;
                songFilter = s.toString();
                fillSongs();
            }
        });
        top.addView(filter, Ui.lp(0, Ui.dp(46), 1, 3));
        root.addView(top);
        songNote = Ui.hint(this, getString(R.string.t_songs_loading));
        root.addView(songNote);
        songList = Ui.list(this, songLines);
        Lines.wire(songList, songLines);
        root.addView(songList, Ui.lp(Ui.FILL, 0, 1));

        TextView partsTitle = Ui.label(this, getString(R.string.t_parts), 12.5f, Ui.DIM);
        partsTitle.setPadding(Ui.dp(14), Ui.dp(6), Ui.dp(14), Ui.dp(2));
        root.addView(partsTitle);
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        partButtons = Ui.row(this);
        partButtons.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(8));
        scroll.addView(partButtons);
        root.addView(scroll, Ui.lp(Ui.FILL, Ui.WRAP, 0));
        showSongBook();
        return root;
    }

    private void showSongBook() {
        if (songBookButton != null) Ui.setText(songBookButton, songsBookTitle.isEmpty() ? getString(R.string.t_songbook) : songsBookTitle);
    }

    private void loadSongs() {
        read("/api/songs/list", json -> {
            songs = json.optJSONArray("songs");
            if (songs == null) songs = new JSONArray();
            songsBook = json.optString("book", "");
            songsLoaded = true;
            fillSongs();
            read("/api/songs/books", books -> {
                JSONArray list = books.optJSONArray("books");
                if (list == null) return;
                for (int i = 0; i < list.length(); i++) {
                    JSONObject book = list.optJSONObject(i);
                    if (book != null && book.optString("id").equals(songsBook)) {
                        songsBookTitle = book.optString("title", songsBook);
                        showSongBook();
                    }
                }
            });
        });
    }

    /// Підвести перелік пісень до тієї, на якій стоїть програма.
    private void scrollToCurrentSong() {
        int at = songLines.current();
        if (at < 0 || songList == null) return;
        final int position = Math.max(0, at - 1);
        songList.post(() -> songList.setSelection(position));
    }

    private void fillSongs() {
        if (songList == null) return;
        String needle = songFilter.trim().toLowerCase(Locale.ROOT);
        // Без String.chars(): його немає на Android 5 і 6, а планшет працює й там.
        boolean number = !needle.isEmpty();
        for (int i = 0; i < needle.length() && number; i++) number = Character.isDigit(needle.charAt(i));
        List<Lines.Line> rows = new ArrayList<>();
        for (int i = 0; i < songs.length() && rows.size() < 400; i++) {
            JSONObject song = songs.optJSONObject(i);
            if (song == null) continue;
            String title = song.optString("title", "");
            int n = song.optInt("number", i + 1);
            if (!needle.isEmpty()) {
                if (number ? !String.valueOf(n).startsWith(needle) : !title.toLowerCase(Locale.ROOT).contains(needle)) continue;
            }
            final int index = song.optInt("index", i);
            String sub = song.optString("subtitle", "");
            // Підпис, що повторює назву, — зайвий рядок.
            if (sub.startsWith(title) || title.startsWith(sub)) sub = "";
            rows.add(Lines.Line.of(String.valueOf(n), title, sub, title.equals(state.songTitle), () -> send("song", index)));
        }
        songLines.set(rows);
        String note = !songsLoaded ? getString(R.string.t_songs_loading)
            : songs.length() == 0 ? getString(R.string.song_list_empty) : rows.isEmpty() ? getString(R.string.search_empty) : "";
        songNote.setText(note);
        songNote.setVisibility(note.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private void fillParts() {
        if (partButtons == null) return;
        StringBuilder signature = new StringBuilder(state.songTitle);
        for (State.Row part : state.parts) signature.append('|').append(part.title).append(part.current);
        if (signature.toString().equals(partsSignature)) return;
        partsSignature = signature.toString();
        partButtons.removeAllViews();
        for (int i = 0; i < state.parts.size(); i++) {
            final int index = i;
            State.Row part = state.parts.get(i);
            // Однакові види частин («Куплет», «Куплет») — з номером, інакше
            // кнопок не відрізнити; де номер уже в назві, лишаємо як є.
            int same = 0, before = 0;
            for (int k = 0; k < state.parts.size(); k++) {
                if (state.parts.get(k).title.equals(part.title)) { same++; if (k <= i) before++; }
            }
            String title = part.title.isEmpty() ? String.valueOf(i + 1)
                : same > 1 ? part.title + " " + before : part.title;
            TextView chip = Ui.chip(this, 0, title, () -> choose("part", index));
            Ui.chipState(chip, title, part.current, Ui.LIVE);
            partButtons.addView(chip, Ui.lp(Ui.WRAP, Ui.dp(40), 0, 3, 0, 3, 0));
        }
        if (state.parts.isEmpty()) {
            TextView none = Ui.label(this, getString(R.string.song_empty), 13, Ui.FAINT);
            none.setPadding(Ui.dp(6), Ui.dp(8), Ui.dp(6), Ui.dp(8));
            partButtons.addView(none);
        }
        fillSongs();
    }

    private void chooseSongBook() {
        read("/api/songs/books", json -> {
            JSONArray list = json.optJSONArray("books");
            if (list == null || list.length() == 0 || isFinishing()) return;
            String[] titles = new String[list.length()];
            String[] ids = new String[list.length()];
            int checked = -1;
            for (int i = 0; i < list.length(); i++) {
                JSONObject book = list.optJSONObject(i);
                ids[i] = book == null ? "" : book.optString("id", "");
                titles[i] = book == null ? "" : book.optString("title", ids[i]);
                if (ids[i].equals(json.optString("current"))) checked = i;
            }
            // Останній рядок — загальна база «Слова»: поставити в програму ще пісенники.
            String[] shown = java.util.Arrays.copyOf(titles, titles.length + 1);
            shown[titles.length] = Lang.t("＋ Завантажити ще пісенники…", "＋ Download more songbooks…");
            Ui.pick(this, getString(R.string.t_songbook), shown, checked, which -> {
                if (which == titles.length) {
                    ResourcesActivity.open(this, "songbook");
                    return;
                }
                songsBookTitle = titles[which];
                showSongBook();
                send("songs-book", body("text", ids[which]), this::loadSongs);
            });
        });
    }

    // MARK: Презентація

    private View buildPresentation() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_presentation));
        LinearLayout top = Ui.row(this);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(2));
        TextView add = Ui.button(this, R.drawable.ic_upload, getString(R.string.t_add_file), Ui.CARD2, this::pickFile);
        add.setMaxLines(1);
        Ui.explain(add, getString(R.string.x_add_file));
        top.addView(add, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        deckButtons = Ui.row(this);
        deckButtons.setGravity(Gravity.CENTER_VERTICAL);
        scroll.addView(deckButtons);
        top.addView(scroll, Ui.lp(0, Ui.WRAP, 1, 3, 0, 0, 0));
        // Власник: «документ pdf pptx и другие тоже должны иметь опции для удаления из списка»
        // і «кнопка должна быть очистить список (полностью)» — «⋮» біля кожного файла й ця кнопка.
        decksClear = Ui.button(this, R.drawable.ic_delete, Lang.t("Очистити список", "Clear the list"), Ui.CARD2, () -> clearList(false));
        decksClear.setMaxLines(1);
        Ui.explain(decksClear, Lang.t("Прибрати зі «Слова» файли презентацій — або все відкрите, разом із фото. Файли на комп'ютері лишаються.",
                                      "Remove the presentation files from Slovo — or everything open, photos too. The files stay on the computer."));
        decksClear.setVisibility(View.GONE);
        top.addView(decksClear, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        root.addView(top);
        deckNote = Ui.hint(this, "");
        root.addView(deckNote);
        FrameLayout box = new FrameLayout(this);
        pagesGrid = grid(pageAdapter, pageThumbs);
        box.addView(pagesGrid, Ui.fill());
        pagesEmpty = Ui.empty(this, R.drawable.ic_slides, Lang.t("Презентацію не відкрито", "No presentation is open"),
            getString(R.string.show_empty), getString(R.string.t_add_file), this::pickFile);
        box.addView(pagesEmpty, Ui.fill());
        root.addView(box, Ui.lp(Ui.FILL, 0, 1));
        return root;
    }

    private GridView grid(ThumbAdapter adapter, List<Thumb> rows) {
        GridView grid = new GridView(this);
        grid.setNumColumns(GridView.AUTO_FIT);
        grid.setColumnWidth(Ui.dp(150));
        grid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        grid.setHorizontalSpacing(Ui.dp(4));
        grid.setVerticalSpacing(Ui.dp(4));
        grid.setPadding(Ui.dp(8), Ui.dp(4), Ui.dp(8), Ui.dp(10));
        grid.setClipToPadding(false);
        grid.setSelector(new android.graphics.drawable.ColorDrawable(0x18FFFFFF));
        grid.setAdapter(adapter);
        grid.setOnItemClickListener((parent, view, position, id) -> {
            if (position < rows.size() && rows.get(position).tap != null) rows.get(position).tap.run();
        });
        return grid;
    }

    private void fillPresentation() {
        if (deckButtons == null) return;
        StringBuilder signature = new StringBuilder();
        for (State.Row deck : state.decks) signature.append(deck.title).append(deck.current).append('|');
        for (int i = 0; i < state.pages.size(); i++) signature.append(state.pageIndexes.get(i)).append(state.pages.get(i).title).append(',');
        signature.append(state.pageIndex);
        String caption = state.pageIndex < 0 ? ""
            : getString(R.string.page_of, state.pageLocal + 1, state.pageCount)
              + (state.onWall ? " " + getString(R.string.on_wall) : "")
              + (state.pageTitle.isEmpty() ? "" : "  — " + state.pageTitle);
        deckNote.setText(caption);
        deckNote.setVisibility(caption.isEmpty() ? View.GONE : View.VISIBLE);
        if (signature.toString().equals(gridSignature)) return;
        gridSignature = signature.toString();

        deckButtons.removeAllViews();
        for (int i = 0; i < state.decks.size(); i++) {
            final int index = i;
            State.Row deck = state.decks.get(i);
            String title = deck.title + " (" + deck.subtitle + ")";
            TextView chip = Ui.chip(this, 0, title, () -> send("deck", index));
            Ui.chipState(chip, title, deck.current, Ui.ACCENT);
            chip.setMaxWidth(Ui.dp(260));
            final String name = deck.title;
            chip.setOnLongClickListener(v -> {
                deckMenu(index, name);
                return true;
            });
            deckButtons.addView(chip, Ui.lp(Ui.WRAP, Ui.dp(40), 0, 3, 0, 0, 0));
            ImageView dots = Ui.image(this, R.drawable.ic_more, Ui.DIM, 22);
            dots.setBackground(Ui.pressable(0x00000000, 18));
            dots.setClickable(true);
            dots.setOnClickListener(v -> deckMenu(index, name));
            dots.setContentDescription(Lang.t("Дії з файлом ", "File actions ") + name);
            deckButtons.addView(dots, Ui.lp(Ui.dp(34), Ui.dp(40), 0, 0, 0, 6, 0));
        }
        decksClear.setVisibility(state.decks.isEmpty() ? View.GONE : View.VISIBLE);
        // Ключ мініатюри — з назвою файла: прибрали файл — номери сторінок зсуваються, і
        // «Сторінка 1» іншого файла не має взяти картинку прибраного з пам'яті.
        String deckName = "";
        for (State.Row deck : state.decks) if (deck.current) deckName = deck.title;
        pageThumbs.clear();
        for (int i = 0; i < state.pages.size(); i++) {
            final int index = state.pageIndexes.get(i);
            State.Row page = state.pages.get(i);
            pageThumbs.add(new Thumb((i + 1) + ". " + page.title, index == state.pageIndex,
                () -> showPage(index), "/api/page?index=" + index + "&w=320#" + deckName + "/" + page.title));
        }
        pageAdapter.notifyDataSetChanged();
        pagesEmpty.setVisibility(pageThumbs.isEmpty() ? View.VISIBLE : View.GONE);
        pagesGrid.setVisibility(pageThumbs.isEmpty() ? View.GONE : View.VISIBLE);
    }

    /// Сторінка презентації — у зал, навіть коли програма тим часом перейшла на фото: команда
    /// `page` бере сторінку з відкритого в програмі списку (див. `Api.presentationPage`).
    private void showPage(int index) {
        Api current = api;
        if (current == null) return;
        followedMode = "presentation";
        commands.execute(() -> {
            try {
                current.presentationPage(index, false);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    // MARK: Плеєр

    private View buildMedia() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_media));
        LinearLayout card = Ui.card(this);
        card.setPadding(Ui.dp(14), Ui.dp(12), Ui.dp(14), Ui.dp(12));
        mediaTitle = Ui.label(this, getString(R.string.t_nothing_open), 16.5f, Ui.TEXT);
        mediaTitle.setTypeface(Ui.MEDIUM);
        mediaTitle.setMaxLines(1);
        mediaTitle.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(mediaTitle);
        mediaTime = Ui.label(this, "", 13, Ui.DIM);
        card.addView(mediaTime, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 2, 0, 0));
        mediaSeek = Ui.seek(this, 1000);
        mediaSeek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (fromUser && mediaDuration > 0) mediaTime.setText(Ui.clock(progress / 1000.0 * mediaDuration) + " / " + Ui.clock(mediaDuration));
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) { seekDragging = true; }

            @Override
            public void onStopTrackingTouch(SeekBar bar) {
                seekDragging = false;
                if (mediaDuration > 0) send("media-seek", body("x", bar.getProgress() / 1000.0 * mediaDuration), null);
            }
        });
        card.addView(mediaSeek, Ui.lp(Ui.FILL, Ui.dp(40), 0, 0, 4, 0, 0));

        LinearLayout keys = Ui.row(this);
        keys.setGravity(Gravity.CENTER);
        ImageView toBegin = Ui.iconButton(this, R.drawable.ic_prev, Ui.CARD2, () -> send("media-seek", body("x", 0), this::loadMedia));
        Ui.explain(toBegin, getString(R.string.x_to_begin));
        mediaPlay = Ui.iconButton(this, R.drawable.ic_play, Ui.ACCENT, () -> send("media-toggle", null, this::loadMedia));
        Ui.explain(mediaPlay, getString(R.string.x_play));
        ImageView stop = Ui.iconButton(this, R.drawable.ic_stop, Ui.CARD2, () -> send("media-stop", null, this::loadMedia));
        Ui.explain(stop, getString(R.string.x_stop));
        keys.addView(toBegin, Ui.lp(Ui.dp(52), Ui.dp(52), 0, 6, 0, 6, 0));
        keys.addView(mediaPlay, Ui.lp(Ui.dp(64), Ui.dp(56), 0, 6, 0, 6, 0));
        keys.addView(stop, Ui.lp(Ui.dp(52), Ui.dp(52), 0, 6, 0, 6, 0));
        card.addView(keys, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 4, 0, 4));

        LinearLayout volume = Ui.row(this);
        volume.setGravity(Gravity.CENTER_VERTICAL);
        ImageView speaker = Ui.image(this, R.drawable.ic_volume, Ui.DIM, 20);
        speaker.setContentDescription(getString(R.string.t_volume));
        volume.addView(speaker, Ui.lp(Ui.dp(28), Ui.dp(28), 0));
        mediaVolume = Ui.seek(this, 100);
        mediaVolume.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) { }

            @Override
            public void onStartTrackingTouch(SeekBar bar) { volumeDragging = true; }

            @Override
            public void onStopTrackingTouch(SeekBar bar) {
                volumeDragging = false;
                send("media-volume", body("x", bar.getProgress() / 100.0), null);
            }
        });
        volume.addView(mediaVolume, Ui.lp(0, Ui.dp(40), 1));
        card.addView(volume);

        LinearLayout chips = Ui.row(this);
        mediaMute = Ui.chip(this, R.drawable.ic_volume, getString(R.string.t_mute), () -> send("media-mute", null, this::loadMedia));
        mediaScreen = Ui.chip(this, R.drawable.ic_black, getString(R.string.t_to_screen), () -> send("media-screen", null, this::loadMedia));
        mediaRepeat = Ui.chip(this, R.drawable.ic_repeat, getString(R.string.t_repeat), () -> send("media-repeat", null, this::loadMedia));
        Ui.explain(mediaMute, getString(R.string.x_mute));
        Ui.explain(mediaScreen, getString(R.string.x_to_screen));
        Ui.explain(mediaRepeat, getString(R.string.x_repeat));
        chips.addView(mediaMute, Ui.lp(0, Ui.dp(40), 1, 0, 0, 3, 0));
        chips.addView(mediaScreen, Ui.lp(0, Ui.dp(40), 1, 3, 0, 3, 0));
        chips.addView(mediaRepeat, Ui.lp(0, Ui.dp(40), 1, 3, 0, 0, 0));
        card.addView(chips, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 6, 0, 0));
        root.addView(card, Ui.lp(Ui.FILL, Ui.WRAP, 0, 10, 2, 10, 4));

        mediaNote = Ui.hint(this, "");
        mediaNote.setVisibility(View.GONE);
        root.addView(mediaNote);
        ListView list = Ui.list(this, mediaLines);
        Lines.wire(list, mediaLines);
        root.addView(list, Ui.lp(Ui.FILL, 0, 1));
        return root;
    }

    private void loadMedia() {
        if (mode != Mode.MEDIA) return;
        read("/api/media", this::fillMedia);
    }

    private void fillMedia(JSONObject json) {
        if (mediaPlay == null) return;
        String shown = json.toString();
        if (shown.equals(mediaShown) && !seekDragging && !volumeDragging) return;
        mediaShown = shown;
        boolean playing = json.optBoolean("playing", false);
        mediaPlay.setImageDrawable(Ui.icon(this, playing ? R.drawable.ic_pause : R.drawable.ic_play, 0xFFFFFFFF, 26));
        mediaDuration = json.optDouble("duration", 0);
        double position = json.optDouble("position", 0);
        if (!seekDragging) {
            mediaSeek.setProgress(mediaDuration > 0 ? (int) Math.round(position / mediaDuration * 1000) : 0);
            String title = json.optString("title", "");
            mediaTitle.setText(title.isEmpty() ? getString(R.string.t_nothing_open) : title);
            mediaTime.setText(mediaDuration > 0 ? Ui.clock(position) + " / " + Ui.clock(mediaDuration) : "");
        }
        if (!volumeDragging) mediaVolume.setProgress((int) Math.round(json.optDouble("volume", 1) * 100));
        Ui.chipState(mediaMute, getString(R.string.t_mute), json.optBoolean("muted", false), Ui.WARN);
        Ui.chipState(mediaScreen, getString(R.string.t_to_screen), json.optBoolean("toScreen", false), Ui.ACCENT);
        Ui.chipState(mediaRepeat, getString(R.string.t_repeat), json.optBoolean("repeats", false), Ui.ACCENT);

        JSONArray list = json.optJSONArray("playlist");
        int current = json.optInt("index", -1);
        StringBuilder signature = new StringBuilder().append(current);
        if (list != null) for (int i = 0; i < list.length(); i++) signature.append('|').append(list.optJSONObject(i));
        if (signature.toString().equals(mediaListSignature)) return;
        mediaListSignature = signature.toString();
        List<Lines.Line> rows = new ArrayList<>();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.optJSONObject(i);
                if (item == null) continue;
                final int index = item.optInt("index", i);
                rows.add(Lines.Line.of(String.valueOf(i + 1), item.optString("name", ""), "", index == current,
                    () -> send("media-open", body("index", index), this::loadMedia)));
            }
        }
        mediaLines.set(rows);
        mediaNote.setText(rows.isEmpty() ? getString(R.string.t_media_empty) : "");
        mediaNote.setVisibility(rows.isEmpty() ? View.VISIBLE : View.GONE);
    }

    // MARK: Зображення

    private View buildPictures() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_pictures));
        LinearLayout top = Ui.row(this);
        top.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(2));
        TextView add = Ui.button(this, R.drawable.ic_image, getString(R.string.t_add_photos), Ui.CARD2, this::pickPhotos);
        Ui.explain(add, getString(R.string.x_add_photos));
        top.addView(add, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        top.addView(Ui.gap(this));
        // Власник: «фото добавлены, а удалить из списка их нельзя» — «⋮» на кожному фото й очищення всього списку.
        picturesClear = Ui.button(this, R.drawable.ic_delete, Lang.t("Очистити список", "Clear the list"), Ui.CARD2, () -> clearList(true));
        Ui.explain(picturesClear, Lang.t("Прибрати зі «Слова» всі фото — або все відкрите, разом із презентаціями. Файли на комп'ютері лишаються.",
                                         "Remove all photos from Slovo — or everything open, presentations too. The files stay on the computer."));
        top.addView(picturesClear, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        root.addView(top);
        FrameLayout box = new FrameLayout(this);
        picturesGrid = grid(pictureAdapter, pictureThumbs);
        box.addView(picturesGrid, Ui.fill());
        picturesEmpty = Ui.empty(this, R.drawable.ic_image, Lang.t("Картинок немає", "No pictures"),
            Lang.t("«Фото з планшета» додає сюди фото з галереї — до двадцяти за раз, перше вибране; у зал — кнопкою «Показати».",
                   "“Photos from the tablet” adds gallery photos here — up to twenty at once, the first is chosen; “Show” puts it in the hall."),
            getString(R.string.t_add_photos), this::pickPhotos);
        picturesEmpty.setVisibility(View.GONE);
        box.addView(picturesEmpty, Ui.fill());
        root.addView(box, Ui.lp(Ui.FILL, 0, 1));
        return root;
    }

    private TextView picturesClear;
    private TextView decksClear;

    /// «⋮» біля файла презентації (PDF, PowerPoint, Keynote…): відкрити чи прибрати.
    private void deckMenu(int index, String title) {
        Ui.menu(this, title, new String[] {
            Lang.t("Відкрити сторінки", "Open the pages"),
            Lang.t("Прибрати зі списку", "Remove from the list"),
        }, which -> {
            if (which == 0) send("deck", index);
            else editShow(body("index", index), Lang.t("Прибрано: ", "Removed: ") + title, "deck-remove");
        });
    }

    /// «Очистити список» на вкладках «Презентація» й «Зображення». Відкрите є і там, і там —
    /// спершу вибір: лише цей список чи все («очистить список (полностью)»); далі — питання.
    private void clearList(boolean fromPictures) {
        read("/api/pictures", json -> {
            int photos = json.optInt("count", 0), decks = state.decks.size();
            int mine = fromPictures ? photos : decks, other = fromPictures ? decks : photos;
            if (mine == 0 && other == 0) return;
            if (mine == 0 || other == 0) {
                confirmClear(decks > 0, photos > 0, decks, photos);
                return;
            }
            Ui.menu(this, Lang.t("Очистити список", "Clear the list"), new String[] {
                fromPictures ? Lang.t("Лише фото · ", "Photos only · ") + photos
                             : Lang.t("Лише презентації · ", "Presentations only · ") + Lang.showSummary(decks, 0),
                Lang.t("Усе відкрите: ", "Everything open: ") + Lang.showSummary(decks, photos),
            }, which -> {
                if (which == 1) confirmClear(true, true, decks, photos);
                else confirmClear(!fromPictures, fromPictures, decks, photos);
            });
        });
    }

    /// Питання перед очищенням: на служінні випадковий дотик не має стерти підготовлене.
    private void confirmClear(boolean clearDecks, boolean clearPhotos, int decks, int photos) {
        List<String> what = new ArrayList<>();
        if (clearDecks) what.add("decks-clear");
        if (clearPhotos) what.add("pictures-clear");
        String title, text, done;
        if (clearDecks && clearPhotos) {
            title = Lang.t("Очистити весь список?", "Clear the whole list?");
            text = Lang.t("З «Слова» прибереться все відкрите: " + Lang.showSummary(decks, photos) + ". Самі файли на комп'ютері лишаються. Якщо щось із цього зараз у залі — зал згасне.",
                          "Everything open is removed from Slovo: " + Lang.showSummary(decks, photos) + ". The files stay on the computer. If any of it is in the hall now, the hall goes dark.");
            done = Lang.t("Список очищено", "The list is cleared");
        } else if (clearDecks) {
            title = Lang.t("Очистити список презентацій?", "Clear the presentation list?");
            text = Lang.t("З «Слова» приберуться всі файли презентацій (" + decks + "). Фото лишаються, самі файли на комп'ютері — теж. Якщо сторінка зараз у залі — зал згасне.",
                          "All presentation files (" + decks + ") are removed from Slovo. Photos stay, and so do the files on the computer. If a page is in the hall now, the hall goes dark.");
            done = Lang.t("Список презентацій очищено", "The presentation list is cleared");
        } else {
            title = Lang.t("Очистити список фото?", "Clear the photo list?");
            text = Lang.t("З «Слова» приберуться всі фото (" + photos + "). Самі файли на комп'ютері лишаються. Якщо фото зараз у залі — зал згасне.",
                          "All photos (" + photos + ") are removed from Slovo. The files stay on the computer. If a photo is in the hall now, the hall goes dark.");
            done = Lang.t("Список фото очищено", "The photo list is cleared");
        }
        Ui.confirm(this, title, text, Lang.t("Очистити", "Clear"), () -> editShow(null, done, what.toArray(new String[0])));
    }

    /// «⋮» на фото: прибрати зі списку. «Показати в залі» тут більше немає — у зал лише кнопка
    /// «Показати» (власник 27.11: «показ … исключительно по кнопке показа»).
    private void pictureMenu(int index, String title) {
        Ui.menu(this, title, new String[] {
            Lang.t("Прибрати зі списку", "Remove from the list"),
        }, which -> editPictures("picture-remove", body("index", index), Lang.t("Прибрано: ", "Removed: ") + title));
    }

    private void editPictures(String command, JSONObject json, String done) { editShow(json, done, command); }

    /// Прибрати фото чи файл, очистити список. Старе «Слово» таких команд не знає — так і кажемо.
    private void editShow(JSONObject json, String done, String... list) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            String doing = "";
            try {
                for (String command : list) {
                    doing = command;
                    current.command(command, json);
                }
                main.post(() -> {
                    say(done);
                    picturesCount = -1;
                    loadPictures();
                });
            } catch (Exception error) {
                String why = error.getMessage() == null ? "" : error.getMessage();
                if (!doing.isEmpty() && why.contains(doing)) {
                    main.post(() -> Ui.info(this, Lang.t("Потрібне новіше «Слово»", "A newer Slovo is needed"),
                        Lang.t("Прибирати фото й файли з планшета вміє «Слово» 1.4.4 і новіше. Оновіть програму на комп'ютері — або приберіть їх там: вкладки «Презентація» й «Зображення», кнопка «−».",
                               "Removing photos and files from the tablet needs Slovo 1.4.4 or newer. Update Slovo on the computer — or remove them there: the “Presentation” and “Pictures” tabs, the “−” button.")));
                } else {
                    showFailure(error);
                }
            }
        });
    }

    private void loadPictures() {
        read("/api/pictures", json -> {
            if (picturesGrid == null) return;
            JSONArray pages = json.optJSONArray("pages");
            int current = json.optInt("index", -1);
            picturesCount = json.optInt("count", 0);
            pictureThumbs.clear();
            if (pages != null) {
                for (int i = 0; i < pages.length(); i++) {
                    JSONObject page = pages.optJSONObject(i);
                    if (page == null) continue;
                    final int index = page.optInt("index", i);
                    String title = page.optString("title", "");
                    Thumb thumb = new Thumb(title, index == current, () -> send("picture", body("index", index, "live", false), this::loadPictures),
                        "/api/page?kind=pictures&index=" + index + "&w=320#" + title);
                    thumb.menu = () -> pictureMenu(index, title);
                    pictureThumbs.add(thumb);
                }
            }
            pictureAdapter.notifyDataSetChanged();
            if (picturesClear != null) picturesClear.setVisibility(pictureThumbs.isEmpty() ? View.GONE : View.VISIBLE);
            picturesEmpty.setVisibility(pictureThumbs.isEmpty() ? View.VISIBLE : View.GONE);
            picturesGrid.setVisibility(pictureThumbs.isEmpty() ? View.GONE : View.VISIBLE);
        });
    }

    // MARK: Екран

    private View buildScreen() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_screen));
        LinearLayout top = Ui.row(this);
        top.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(2));
        TextView refresh = Ui.button(this, R.drawable.ic_refresh, getString(R.string.t_screen_refresh), Ui.CARD2,
            () -> send("screen-reload", null, () -> main.postDelayed(this::loadScreen, 1200)));
        Ui.explain(refresh, getString(R.string.x_screen_refresh));
        TextView stop = Ui.button(this, R.drawable.ic_stop, getString(R.string.t_screen_stop), Ui.CARD2,
            () -> send("screen-stop", null, this::loadScreen));
        Ui.explain(stop, getString(R.string.x_screen_stop));
        top.addView(refresh, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        top.addView(stop, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        root.addView(top);
        screenNote = Ui.hint(this, "");
        screenNote.setVisibility(View.GONE);
        root.addView(screenNote);
        FrameLayout box = new FrameLayout(this);
        ListView list = Ui.list(this, screenLines);
        Lines.wire(list, screenLines);
        screenList = list;
        box.addView(list, Ui.fill());
        screenEmpty = Ui.empty(this, R.drawable.ic_cast, Lang.t("Джерел немає", "No sources"),
            Lang.t("Можливо, програмі потрібен дозвіл на запис екрана: Системні параметри → Приватність і безпека → Запис екрана.",
                   "Slovo may need the screen recording permission: System Settings → Privacy & Security → Screen Recording."),
            getString(R.string.t_screen_refresh),
            () -> send("screen-reload", null, () -> main.postDelayed(this::loadScreen, 1200)));
        screenEmpty.setVisibility(View.GONE);
        box.addView(screenEmpty, Ui.fill());
        root.addView(box, Ui.lp(Ui.FILL, 0, 1));
        return root;
    }

    private void loadScreen() {
        read("/api/screen", json -> {
            if (screenList == null || mode != Mode.SCREEN) return;
            JSONArray sources = json.optJSONArray("sources");
            String current = json.optString("current", "");
            List<Lines.Line> rows = new ArrayList<>();
            String running = "";
            if (sources != null) {
                for (int i = 0; i < sources.length(); i++) {
                    JSONObject source = sources.optJSONObject(i);
                    if (source == null) continue;
                    final int index = source.optInt("index", i);
                    boolean now = source.optString("id").equals(current) && json.optBoolean("running", false);
                    if (now) running = source.optString("title", "");
                    rows.add(Lines.Line.of(null, source.optString("title", ""), source.optString("subtitle", ""), now,
                        () -> send("screen-start", body("index", index), this::loadScreen)));
                }
            }
            screenLines.set(rows);
            screenEmpty.setVisibility(rows.isEmpty() ? View.VISIBLE : View.GONE);
            screenList.setVisibility(rows.isEmpty() ? View.GONE : View.VISIBLE);
            String note = "";
            if (rows.isEmpty()) {
                // Список джерел програма збирає у фоні — перше питання часто
                // приходить раніше, ніж він готовий.
                if (screenRetries++ < 3) main.postDelayed(this::loadScreen, 1500);
            } else {
                note = running.isEmpty() ? json.optString("note", "") : getString(R.string.t_screen_running, running);
            }
            screenNote.setText(note);
            screenNote.setVisibility(note.isEmpty() ? View.GONE : View.VISIBLE);
        });
    }

    // MARK: Текст

    private View buildText() {
        LinearLayout root = Ui.col(this);
        hint(root, getString(R.string.t_hint_text));
        textTitle = Ui.field(this, getString(R.string.t_text_title_hint), false);
        textTitle.setText(textTitleValue);
        textBody = Ui.field(this, getString(R.string.t_text_body_hint), true);
        textBody.setText(textBodyValue);
        root.addView(textTitle, Ui.lp(Ui.FILL, Ui.dp(50), 0, 11, 2, 11, 6));
        root.addView(textBody, Ui.lp(Ui.FILL, 0, 1, 11, 0, 11, 6));
        LinearLayout keys = Ui.row(this);
        keys.setPadding(Ui.dp(8), 0, Ui.dp(8), 0);
        TextView preview = Ui.button(this, R.drawable.ic_eye, getString(R.string.t_text_preview), Ui.CARD2, () -> sendText(false));
        Ui.explain(preview, getString(R.string.x_text_preview));
        TextView show = Ui.primary(this, R.drawable.ic_play, getString(R.string.t_text_show), () -> sendText(true));
        Ui.explain(show, getString(R.string.x_text_show));
        keys.addView(preview, Ui.lp(0, Ui.dp(50), 1, 3));
        keys.addView(show, Ui.lp(0, Ui.dp(50), 1.3f, 3));
        root.addView(keys);
        LinearLayout pages = Ui.row(this);
        pages.setGravity(Gravity.CENTER);
        pages.addView(Ui.iconButton(this, R.drawable.ic_left, Ui.CARD2,
            () -> { if (textPage > 0) send("text-page", body("index", textPage - 1, "live", false), this::loadText); }), Ui.lp(Ui.dp(46), Ui.dp(44), 0));
        textPages = Ui.label(this, "", 14, Ui.DIM);
        textPages.setGravity(Gravity.CENTER);
        textPages.setMinWidth(Ui.dp(150));
        pages.addView(textPages, Ui.lp(Ui.WRAP, Ui.WRAP, 0, 10, 0, 10, 0));
        pages.addView(Ui.iconButton(this, R.drawable.ic_right, Ui.CARD2,
            () -> { if (textPage + 1 < textPageCount) send("text-page", body("index", textPage + 1, "live", false), this::loadText); }), Ui.lp(Ui.dp(46), Ui.dp(44), 0));
        root.addView(pages, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 6, 0, 10));
        return root;
    }

    private void sendText(boolean live) {
        Ui.hideKeyboard(textBody);
        JSONObject json = body("text", textBody.getText().toString(), "title", textTitle.getText().toString());
        send("text-set", json, () -> {
            if (live) send("text-show", null, this::loadText); else loadText();
        });
    }

    private void loadText() {
        read("/api/text", json -> {
            if (textBody == null) return;
            // Набране людиною не перебиваємо тим, що лежить у програмі.
            if (textBody.getText().length() == 0 && textTitle.getText().length() == 0) {
                textTitle.setText(json.optString("title", ""));
                textBody.setText(json.optString("body", ""));
            }
            textPage = json.optInt("page", 0);
            textPageCount = json.optInt("pages", 0);
            textPages.setText(textPageCount > 0 ? getString(R.string.t_text_pages, textPage + 1, textPageCount) : "");
        });
    }

    // MARK: План та Історія

    private View buildPlan() {
        LinearLayout root = Ui.col(this);
        LinearLayout tabs = Ui.row(this);
        tabs.setPadding(Ui.dp(8), Ui.dp(4), Ui.dp(8), Ui.dp(2));
        tabPlan = Ui.chip(this, R.drawable.ic_plan, getString(R.string.t_plan), () -> chooseSide(false));
        tabHistory = Ui.chip(this, R.drawable.ic_history, getString(R.string.t_history), () -> chooseSide(true));
        Ui.explain(tabPlan, getString(R.string.x_tab_plan));
        Ui.explain(tabHistory, getString(R.string.x_tab_history));
        tabs.addView(tabPlan, Ui.lp(0, Ui.dp(42), 1, 3));
        tabs.addView(tabHistory, Ui.lp(0, Ui.dp(42), 1, 3));
        root.addView(tabs);

        // План проповіді — кнопкою на видноті, а не в меню.
        sermonOpen = Ui.primary(this, R.drawable.ic_plan_add, Ui.plain(getString(R.string.t_sermon_open)), this::openSermon);
        Ui.explain(sermonOpen, getString(R.string.x_sermon));
        root.addView(sermonOpen, Ui.lp(Ui.FILL, Ui.dp(50), 0, 11, 4, 11, 4));
        // «Повернути план служіння» — видна, лише поки План проповіді головний.
        sermonEnd = Ui.button(this, R.drawable.ic_refresh, getString(R.string.s_sermon_end), Ui.CARD2, () -> send("sermon-end"));
        sermonEnd.setTextColor(Ui.WARN);
        Ui.setText(sermonEnd, getString(R.string.s_sermon_end));
        root.addView(sermonEnd, Ui.lp(Ui.FILL, Ui.dp(46), 0, 11, 0, 11, 4));
        planHint = Ui.hint(this, getString(R.string.t_hint_plan));
        root.addView(planHint);

        FrameLayout box = new FrameLayout(this);
        ListView list = Ui.list(this, sideLines);
        Lines.wire(list, sideLines);
        box.addView(list, Ui.fill());
        sideNote = Ui.label(this, "", 14.5f, Ui.DIM);
        sideNote.setGravity(Gravity.CENTER);
        sideNote.setLineSpacing(Ui.dp(2), 1f);
        sideNote.setPadding(Ui.dp(28), Ui.dp(24), Ui.dp(28), Ui.dp(24));
        box.addView(sideNote, Ui.fill());
        root.addView(box, Ui.lp(Ui.FILL, 0, 1));

        LinearLayout tools = Ui.row(this);
        tools.setGravity(Gravity.CENTER_VERTICAL);
        tools.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), Ui.dp(8));
        planAdd = Ui.button(this, R.drawable.ic_plan_add, Ui.plain(getString(R.string.t_plan_add)), Ui.CARD2, () -> send("plan-add"));
        planAdd.setMaxLines(1);
        Ui.explain(planAdd, getString(R.string.x_plan_add));
        tools.addView(planAdd, Ui.lp(0, Ui.dp(48), 1, 3));
        ImageView up = Ui.iconButton(this, R.drawable.ic_up, Ui.CARD2, () -> movePlan(-1));
        up.setContentDescription(Ui.plain(getString(R.string.t_up)));
        Ui.explain(up, getString(R.string.x_up));
        ImageView down = Ui.iconButton(this, R.drawable.ic_down, Ui.CARD2, () -> movePlan(1));
        down.setContentDescription(Ui.plain(getString(R.string.t_down)));
        Ui.explain(down, getString(R.string.x_down));
        ImageView remove = Ui.iconButton(this, R.drawable.ic_delete, Ui.CARD2, this::removeSide);
        remove.setContentDescription(Ui.plain(getString(R.string.t_remove)));
        Ui.explain(remove, getString(R.string.x_remove));
        planUp = up;
        planDown = down;
        tools.addView(up, Ui.lp(Ui.dp(52), Ui.dp(48), 0, 3));
        tools.addView(down, Ui.lp(Ui.dp(52), Ui.dp(48), 0, 3));
        tools.addView(remove, Ui.lp(Ui.dp(52), Ui.dp(48), 0, 3));
        // В Історії лишається тільки «Прибрати» — притиснута праворуч.
        tools.addView(Ui.gap(this), 0);
        root.addView(tools);
        renderSide();
        return root;
    }

    private void chooseSide(boolean showHistory) {
        sideHistory = showHistory;
        sideSelected = -1;
        renderSide();
        applyHints();
        if (showHistory) loadHistory(); else fillPlan();
    }

    /// Вигляд розділу «План»: що вибрано — План чи Історія — і чий зараз план.
    private void renderSide() {
        if (tabPlan == null) return;
        String planTitle = getString(state.sermon ? R.string.s_title : R.string.t_plan);
        Ui.chipState(tabPlan, planTitle, !sideHistory, Ui.ACCENT);
        Ui.chipState(tabHistory, getString(R.string.t_history), sideHistory, Ui.ACCENT);
        planAdd.setVisibility(sideHistory ? View.GONE : View.VISIBLE);
        planUp.setVisibility(sideHistory ? View.GONE : View.VISIBLE);
        planDown.setVisibility(sideHistory ? View.GONE : View.VISIBLE);
        ((ViewGroup) planAdd.getParent()).getChildAt(0).setVisibility(sideHistory ? View.VISIBLE : View.GONE);
        sermonOpen.setVisibility(sideHistory ? View.GONE : View.VISIBLE);
        sermonEnd.setVisibility(state.sermon && !sideHistory ? View.VISIBLE : View.GONE);
    }

    private void fillPlan() {
        if (sideHistory || sideNote == null) return;
        List<Lines.Line> rows = new ArrayList<>();
        for (int i = 0; i < state.plan.size(); i++) {
            final int index = i;
            State.Row item = state.plan.get(i);
            rows.add(Lines.Line.of(String.valueOf(i + 1), item.title, item.subtitle, item.current || index == sideSelected,
                () -> { sideSelected = index; choose("plan", index); fillPlan(); }));
        }
        sideLines.set(rows);
        showSideNote(rows.isEmpty() ? Lang.t("План порожній. «Додати вибране» (або плитка «У План» під залом) кладе сюди те, що вибрано в розділі.",
                                             "The plan is empty. “Add selected” (or the “To Plan” tile under the hall) puts here what is selected in a section.") : "");
    }

    private void loadHistory() {
        historySeq = state.seq;
        read("/api/history", json -> {
            history = json.optJSONArray("records");
            if (history == null) history = new JSONArray();
            fillHistory();
        });
    }

    private void fillHistory() {
        if (!sideHistory || sideNote == null) return;
        List<Lines.Line> rows = new ArrayList<>();
        for (int i = 0; i < history.length(); i++) {
            JSONObject record = history.optJSONObject(i);
            if (record == null) continue;
            final int index = record.optInt("index", i);
            String caption = record.optString("caption", "");
            int cut = caption.indexOf("- ");
            String title = cut > 0 ? caption.substring(0, cut) : caption;
            String rest = cut > 0 ? caption.substring(cut + 2) : "";
            rows.add(Lines.Line.of(null, title, rest, record.optBoolean("current", false) || index == sideSelected,
                () -> { sideSelected = index; choose("history", index); fillHistory(); }));
        }
        sideLines.set(rows);
        showSideNote(rows.isEmpty() ? getString(R.string.t_history_empty) : "");
    }

    private void showSideNote(String text) {
        sideNote.setText(text);
        sideNote.setVisibility(text.isEmpty() ? View.GONE : View.VISIBLE);
    }

    private void movePlan(int delta) {
        int index = sideSelected;
        if (sideHistory || index < 0 || index + delta < 0 || index + delta >= state.plan.size()) return;
        sideSelected = index + delta;
        send("plan-move", body("index", index, "delta", delta), null);
    }

    private void removeSide() {
        int index = sideSelected;
        if (index < 0) {
            say(Lang.t("Спершу торкніться пункту, який прибрати", "First tap the item to remove"));
            return;
        }
        sideSelected = -1;
        send(sideHistory ? "history-remove" : "plan-remove", body("index", index), sideHistory ? this::loadHistory : null);
    }

    // MARK: Файли й фото з планшета

    private void pickFile() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
        });
        try {
            startActivityForResult(intent, PICK_FILE);
        } catch (Exception error) {
            say(getString(R.string.upload_failed, error.getMessage()));
        }
    }

    private void pickPhotos() {
        Intent intent;
        if (Build.VERSION.SDK_INT >= 33) {
            intent = new Intent(MediaStore.ACTION_PICK_IMAGES);
            intent.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 20);
        } else {
            intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType("image/*");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        }
        try {
            startActivityForResult(intent, PICK_PHOTO);
        } catch (Exception error) {
            say(getString(R.string.photo_failed, error.getMessage()));
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (resultCode != RESULT_OK || data == null) return;
        if (requestCode == PICK_PHOTO) {
            sendPhotos(photoUris(data));
            return;
        }
        if (requestCode != PICK_FILE || data.getData() == null) return;
        final Uri uri = data.getData();
        final String name = displayName(uri);
        final Api current = api;
        if (current == null) return;
        if (shell != null) shell.note(getString(R.string.uploading, name), true);
        commands.execute(() -> {
            try {
                byte[] bytes;
                try (InputStream stream = getContentResolver().openInputStream(uri)) {
                    if (stream == null) throw new java.io.IOException(Lang.t("порожній файл", "empty file"));
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] chunk = new byte[65536];
                    int count;
                    while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
                    bytes = out.toByteArray();
                }
                JSONObject answer = current.upload(name, bytes);
                int pages = answer == null ? 0 : answer.optInt("pages", 0);
                main.post(() -> say(getString(R.string.uploaded, name, pages)));
            } catch (Exception error) {
                main.post(() -> say(getString(R.string.upload_failed,
                    error.getMessage() == null ? error.toString() : error.getMessage())));
            }
        });
    }

    private List<Uri> photoUris(Intent data) {
        List<Uri> uris = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri uri = clip.getItemAt(i).getUri();
                if (uri != null) uris.add(uri);
            }
        } else if (data.getData() != null) {
            uris.add(data.getData());
        }
        return uris;
    }

    /// Фото — зменшеними, по одному; перше надіслане — одразу на стіну.
    private void sendPhotos(List<Uri> uris) {
        final Api current = api;
        if (current == null || uris.isEmpty()) return;
        final long stamp = System.currentTimeMillis() / 1000 % 100000;
        commands.execute(() -> {
            int first = -1;
            int sent = 0;
            for (int i = 0; i < uris.size(); i++) {
                final int n = i + 1;
                main.post(() -> { if (shell != null) shell.note(getString(R.string.photo_sending, n, uris.size()), true); });
                try {
                    PhotoShrink.Result photo = PhotoShrink.prepare(getContentResolver(), uris.get(i), 2560);
                    JSONObject answer = current.upload(Lang.t("Фото ", "Photo ") + stamp + "-" + n + "." + photo.extension, photo.bytes, false);
                    if (first < 0 && answer != null) first = answer.optInt("page", -1);
                    sent++;
                } catch (Exception error) {
                    final String why = error.getMessage() == null ? error.toString() : error.getMessage();
                    main.post(() -> say(getString(R.string.photo_failed, why)));
                }
            }
            if (first >= 0) {
                try { current.command("picture", body("index", first, "live", false)); } catch (Exception ignored) { }
            }
            final int total = sent;
            main.post(() -> {
                if (total > 0) say(getString(R.string.photo_sent, total));
                if (mode == Mode.PICTURES) loadPictures();
            });
        });
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                String name = cursor.getString(0);
                if (name != null && !name.isEmpty()) return name;
            }
        } catch (Exception ignored) { }
        String last = uri.getLastPathSegment();
        return last == null ? "файл" : last;
    }

    // MARK: Мініатюри

    /// Сітка мініатюр: слайди презентації й картинки. Мініатюри тягнемо по
    /// одній і тримаємо, поки не зміниться підпис сторінки.
    private final class ThumbAdapter extends BaseAdapter {
        private final List<Thumb> rows;

        ThumbAdapter(List<Thumb> rows) { this.rows = rows; }

        @Override
        public int getCount() { return rows.size(); }

        @Override
        public Object getItem(int position) { return rows.get(position); }

        @Override
        public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View recycled, ViewGroup parent) {
            LinearLayout cell;
            if (recycled instanceof LinearLayout) {
                cell = (LinearLayout) recycled;
            } else {
                cell = Ui.col(TabletActivity.this);
                cell.setPadding(Ui.dp(5), Ui.dp(5), Ui.dp(5), Ui.dp(4));
                FrameLayout frame = new FrameLayout(TabletActivity.this);
                ImageView picture = new ImageView(TabletActivity.this);
                picture.setScaleType(ImageView.ScaleType.FIT_CENTER);
                picture.setBackground(Ui.round(0xFF000000, 8));
                picture.setClipToOutline(true);
                frame.addView(picture, Ui.fill());
                // «⋮» у кутку мініатюри — дії з фото. Не фокусується: інакше сітка не ловить дотик по клітинці.
                ImageView dots = Ui.image(TabletActivity.this, R.drawable.ic_more, 0xFFFFFFFF, 20);
                dots.setBackground(Ui.ripple(Ui.round(0xB0000000, 16), 16));
                dots.setFocusable(false);
                FrameLayout.LayoutParams corner = new FrameLayout.LayoutParams(Ui.dp(36), Ui.dp(36), Gravity.TOP | Gravity.END);
                corner.setMargins(0, Ui.dp(4), Ui.dp(4), 0);
                frame.addView(dots, corner);
                cell.addView(frame, Ui.lp(Ui.FILL, Ui.dp(92), 0));
                TextView caption = Ui.label(TabletActivity.this, "", 12, Ui.DIM);
                caption.setMaxLines(1);
                caption.setEllipsize(TextUtils.TruncateAt.END);
                caption.setPadding(Ui.dp(2), Ui.dp(3), Ui.dp(2), 0);
                cell.addView(caption);
            }
            FrameLayout frame = (FrameLayout) cell.getChildAt(0);
            ImageView picture = (ImageView) frame.getChildAt(0);
            ImageView dots = (ImageView) frame.getChildAt(1);
            TextView caption = (TextView) cell.getChildAt(1);
            Thumb row = rows.get(position);
            final Runnable menu = row.menu;
            dots.setVisibility(menu == null ? View.GONE : View.VISIBLE);
            dots.setOnClickListener(menu == null ? null : v -> menu.run());
            dots.setClickable(menu != null);
            dots.setContentDescription(Lang.t("Дії", "Actions"));
            caption.setText(row.title);
            caption.setTextColor(row.current ? Ui.TEXT : Ui.DIM);
            cell.setBackground(row.current ? Ui.outlined(Ui.SELECT, Ui.alpha(Ui.ACCENT, 0xB0), 12) : Ui.round(Ui.CARD, 12));
            Bitmap ready = row.key == null ? null : thumbs.get(row.key);
            picture.setImageBitmap(ready);
            if (ready == null && row.key != null) loadThumb(row.key);
            return cell;
        }
    }

    private void loadThumb(String key) {
        if (thumbsLoading.contains(key)) return;
        final Api current = api;
        if (current == null) return;
        thumbsLoading.add(key);
        final String path = key.contains("#") ? key.substring(0, key.indexOf('#')) : key;
        images.execute(() -> {
            Bitmap bitmap = null;
            try {
                byte[] bytes = current.image(path);
                if (bytes != null) bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            } catch (Exception ignored) { }
            final Bitmap got = bitmap;
            main.post(() -> {
                thumbsLoading.remove(key);
                if (got != null) {
                    if (thumbs.size() > 300) thumbs.clear();
                    thumbs.put(key, got);
                    pageAdapter.notifyDataSetChanged();
                    pictureAdapter.notifyDataSetChanged();
                }
            });
        });
    }
}
