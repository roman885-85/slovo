package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
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
import android.text.InputType;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.GridView;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.PopupMenu;
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
/// Вкладка планшета і вкладка програми — одна й та сама: від неї залежить,
/// що гортають «Далі» й «Назад». Тому дотик до вкладки перемикає і програму,
/// а перемкнули на комп'ютері — планшет іде слідом.
public final class TabletActivity extends Activity {

    private enum Mode {
        BIBLE("bible", R.string.t_tab_bible), SONGS("songs", R.string.t_tab_songs),
        PRESENTATION("presentation", R.string.t_tab_presentation), MEDIA("media", R.string.t_tab_media),
        PICTURES("pictures", R.string.t_tab_pictures), SCREEN("screen", R.string.t_tab_screen),
        TEXT("text", R.string.t_tab_text);

        final String key;
        final int title;
        Mode(String key, int title) { this.key = key; this.title = title; }

        static Mode of(String key) {
            for (Mode mode : values()) if (mode.key.equals(key)) return mode;
            return null;
        }
    }

    /// Рядок будь-якого списку: що написати, чи він поточний і що робить дотик.
    private static final class Row {
        final String title;
        final String subtitle;
        final boolean current;
        final Runnable tap;
        final Runnable longTap;
        /// Адреса мініатюри на сервері — для сітки картинок і слайдів.
        final String thumb;

        Row(String title, String subtitle, boolean current, Runnable tap, Runnable longTap, String thumb) {
            this.title = title;
            this.subtitle = subtitle;
            this.current = current;
            this.tap = tap;
            this.longTap = longTap;
            this.thumb = thumb;
        }
    }

    private static final int PICK_FILE = 7, PICK_PHOTO = 8;
    private static final int CURRENT_ROW = 0xFF24344A;
    private static final int ACCENT = 0xFF4C8DFF;

    private Settings settings;
    private volatile Api api;
    private ConnectivityManager.NetworkCallback wifiWatch;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService commands = Executors.newSingleThreadExecutor();
    private final ExecutorService reads = Executors.newSingleThreadExecutor();
    private final ExecutorService images = Executors.newFixedThreadPool(2);
    private final ExecutorService hallQueue = Executors.newSingleThreadExecutor();
    private final ExecutorService pointerQueue = Executors.newSingleThreadExecutor();
    private Thread poller;
    private volatile boolean polling;
    private volatile long seq;
    private boolean resumed;
    /// Чи є зв'язок. Біблія вантажиться, коли він з'являється: планшет
    /// вмикають і раніше за комп'ютер — тоді перша спроба не вдається, і без
    /// повтору вкладка так і стояла з «Failed to connect».
    private boolean online;
    private State state = new State();

    private Mode mode = Mode.BIBLE;
    private String followedMode = "";
    private boolean sideHistory;
    private int sideSelected = -1;

    private TextView status, hallCaption, hallNote, liveText, previewText;
    private TextView panelNote, searchNote, sideNote;
    private ImageView hallImage;
    private PointerView pointerView;
    private View biblePanel, otherPanel, searchBar, bibleBar, planTools, planAdd, planUp, planDown;
    private LinearLayout modeTabs, panelTools, panelFooter;
    private ListView panelList, searchList, sideList;
    private GridView panelGrid;
    private EditText bibleSearch;
    private Button black, tabPlan, tabHistory;
    private final Map<Mode, Button> modeButtons = new HashMap<>();
    private BibleBrowser bible;

    private final List<Row> panelRows = new ArrayList<>();
    private final List<Row> searchRows = new ArrayList<>();
    private final List<Row> sideRows = new ArrayList<>();
    private final RowAdapter panelAdapter = new RowAdapter(panelRows);
    private final RowAdapter searchAdapter = new RowAdapter(searchRows);
    private final RowAdapter sideAdapter = new RowAdapter(sideRows);
    private final ThumbAdapter gridAdapter = new ThumbAdapter();

    // Пісні: увесь пісенник тримаємо тут і відбираємо без мережі.
    private JSONArray songs = new JSONArray();
    private String songsBook = "";
    private String songFilter = "";
    private String partsSignature = "";
    private Button songBookButton;
    private LinearLayout partButtons;

    // Плеєр: стан приходить окремим запитом раз на секунду, поки вкладка відкрита.
    private Button mediaPlay, mediaMute, mediaScreen, mediaRepeat;
    private SeekBar mediaSeek, mediaVolume;
    private TextView mediaTime;
    private boolean seekDragging, volumeDragging;
    private double mediaDuration;

    // Текст.
    private EditText textTitle, textBody;
    private TextView textPages;
    private int textPage, textPageCount;

    // Показ і картинки.
    private String gridSignature = "";
    private LinearLayout deckButtons;
    private int picturesCount = -1;

    // Екран.
    private int screenRetries;

    // Історія.
    private JSONArray history = new JSONArray();
    private long historySeq = -1;

    // Зал.
    private Bitmap hallBitmap;
    private String shownCrop = "";
    private volatile boolean hallBusy;
    private volatile boolean hallPending;
    private long hallSeq = -1;
    private final Map<String, Bitmap> thumbs = new HashMap<>();
    private final Set<String> thumbsLoading = new HashSet<>();

    // Указка й наближення на картинці залу — як на телефоні.
    private ScaleGestureDetector zoomDetector;
    private boolean zooming, touching;
    private long zoomEndedAt, touchEndedAt, lastZoomAt, lastPointerAt;
    private double zoomNow = 1;
    private volatile boolean zoomBusy, pointerBusy;
    private volatile double pendingX = -1, pendingY = -1;

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!resumed) return;
            if (mode == Mode.MEDIA) loadMedia();
            main.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        settings = new Settings(this);
        if (!settings.hasHost()) {
            startActivity(new Intent(this, ConnectActivity.class));
            finish();
            return;
        }
        setContentView(R.layout.activity_tablet);
        status = findViewById(R.id.status);
        hallCaption = findViewById(R.id.hallCaption);
        hallNote = findViewById(R.id.hallNote);
        hallImage = findViewById(R.id.hallImage);
        pointerView = findViewById(R.id.pointerView);
        liveText = findViewById(R.id.liveText);
        previewText = findViewById(R.id.previewText);
        biblePanel = findViewById(R.id.biblePanel);
        otherPanel = findViewById(R.id.otherPanel);
        searchBar = findViewById(R.id.searchBar);
        bibleBar = findViewById(R.id.bibleBar);
        searchNote = findViewById(R.id.searchNote);
        searchList = findViewById(R.id.searchList);
        bibleSearch = findViewById(R.id.bibleSearch);
        modeTabs = findViewById(R.id.modeTabs);
        panelTools = findViewById(R.id.panelTools);
        panelFooter = findViewById(R.id.panelFooter);
        panelNote = findViewById(R.id.panelNote);
        panelList = findViewById(R.id.panelList);
        panelGrid = findViewById(R.id.panelGrid);
        sideList = findViewById(R.id.sideList);
        sideNote = findViewById(R.id.sideNote);
        planTools = findViewById(R.id.planTools);
        planAdd = findViewById(R.id.planAdd);
        planUp = findViewById(R.id.planUp);
        planDown = findViewById(R.id.planDown);
        tabPlan = findViewById(R.id.tabPlan);
        tabHistory = findViewById(R.id.tabHistory);
        black = findViewById(R.id.black);

        bible = new BibleBrowser(this, new BibleBrowser.Host() {
            @Override public Api api() { return api; }
            @Override public ExecutorService queue() { return commands; }
            @Override public void post(Runnable body) { main.post(body); }
        }, bibleBar);

        wireList(panelList, panelRows);
        wireList(searchList, searchRows);
        wireList(sideList, sideRows);
        panelList.setAdapter(panelAdapter);
        searchList.setAdapter(searchAdapter);
        sideList.setAdapter(sideAdapter);
        panelGrid.setAdapter(gridAdapter);
        panelGrid.setOnItemClickListener((parent, view, position, id) -> {
            if (position < panelRows.size() && panelRows.get(position).tap != null) panelRows.get(position).tap.run();
        });

        for (Mode each : Mode.values()) {
            Button button = new Button(this, null, 0, R.style.TabButton);
            button.setText(each.title);
            button.setOnClickListener(v -> chooseMode(each, true));
            modeTabs.addView(button, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            modeButtons.put(each, button);
        }

        bind(R.id.prev, "prev");
        bind(R.id.next, "next");
        bind(R.id.show, "show");
        bind(R.id.hide, "hide");
        bind(R.id.black, "black");
        bind(R.id.blank, "blank");

        findViewById(R.id.bibleSearchGo).setOnClickListener(v -> runSearch());
        bibleSearch.setOnEditorActionListener((view, action, event) -> {
            if (action == EditorInfo.IME_ACTION_SEARCH || action == EditorInfo.IME_ACTION_DONE) {
                runSearch();
                return true;
            }
            return false;
        });
        findViewById(R.id.searchClose).setOnClickListener(v -> closeSearch());

        tabPlan.setOnClickListener(v -> chooseSide(false));
        tabHistory.setOnClickListener(v -> chooseSide(true));
        planAdd.setOnClickListener(v -> send("plan-add"));
        planUp.setOnClickListener(v -> movePlan(-1));
        planDown.setOnClickListener(v -> movePlan(1));
        findViewById(R.id.sideRemove).setOnClickListener(v -> removeSide());

        findViewById(R.id.menuButton).setOnClickListener(this::showMenu);

        zoomDetector = new ScaleGestureDetector(this, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScaleBegin(ScaleGestureDetector detector) {
                zooming = true;
                pointerView.hide();
                Api current = api;
                if (current != null) pointerQueue.execute(() -> { try { current.pointerOff(); } catch (Exception ignored) { } });
                return true;
            }
            @Override public boolean onScale(ScaleGestureDetector detector) {
                RectF shown = imageRect();
                if (shown == null || shown.width() <= 0 || shown.height() <= 0) return true;
                zoomNow = Math.max(1.0, Math.min(6.0, zoomNow * detector.getScaleFactor()));
                // Точка — у частках ПОКАЗАНОГО кадру, як і в указки: так її
                // чекає програма (`SlideFocus.zoom(to:aroundShown:)`), а на
                // планшеті показане — те саме вікно, що в залі.
                double x = Math.max(0, Math.min(1, (detector.getFocusX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (detector.getFocusY() - shown.top) / shown.height()));
                queueZoom(zoomNow, x, y);
                return true;
            }
            @Override public void onScaleEnd(ScaleGestureDetector detector) {
                zoomEndedAt = System.currentTimeMillis();
            }
        });
        hallImage.setOnTouchListener(this::hallTouch);
        hallImage.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> updateImageRect());

        chooseSide(false);
        chooseMode(Mode.BIBLE, false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings == null || !settings.hasHost()) return;
        resumed = true;
        applyAwake();
        api = new Api(settings.host(), settings.port(), settings.pin());
        watchWiFi();
        status.setText(getString(R.string.status_connecting, describeServer()));
        online = false;
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

    // MARK: Мережа

    private void watchWiFi() {
        if (wifiWatch != null) return;
        ConnectivityManager manager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (manager == null) return;
        NetworkRequest request = new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build();
        wifiWatch = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) {
                Api current = api;
                if (current != null) current.useNetwork(network);
            }
            @Override public void onLost(Network network) {
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

    private void showMenu(View anchor) {
        PopupMenu popup = new PopupMenu(this, anchor);
        popup.getMenu().add(0, 1, 0, R.string.menu_connection);
        popup.getMenu().add(0, 2, 1, R.string.menu_keep_awake).setCheckable(true).setChecked(settings.keepAwake());
        popup.getMenu().add(0, 3, 2, R.string.menu_zoom_off);
        popup.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1:
                    startActivity(new Intent(this, ConnectActivity.class));
                    finish();
                    return true;
                case 2:
                    settings.setKeepAwake(!settings.keepAwake());
                    applyAwake();
                    return true;
                case 3:
                    resetZoom();
                    return true;
                default:
                    return false;
            }
        });
        popup.show();
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

    private static JSONObject body(Object... pairs) {
        JSONObject json = new JSONObject();
        try {
            for (int i = 0; i + 1 < pairs.length; i += 2) json.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException ignored) { }
        return json;
    }

    private void bind(int id, String command) {
        findViewById(id).setOnClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            send(command);
        });
    }

    /// Обрив зв'язку — «немає зв'язку»; відмова програми — її ж словами:
    /// «немає такого пункта» людині корисніше, ніж «помилка».
    private void showFailure(Exception error) {
        main.post(() -> {
            if (error instanceof Api.PinRejected) {
                status.setText(R.string.status_pin);
            } else if (error instanceof ConnectException || error instanceof SocketTimeoutException
                    || error instanceof UnknownHostException) {
                status.setText(getString(R.string.status_lost, describeServer()));
            } else {
                String why = error.getMessage();
                status.setText(why == null || why.isEmpty() ? error.toString() : why);
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
            while (polling) {
                try {
                    State fresh = current.state(seq);
                    failures = 0;
                    if (!polling) break;
                    seq = fresh.seq;
                    main.post(() -> apply(fresh));
                } catch (Api.PinRejected rejected) {
                    main.post(() -> status.setText(R.string.status_pin));
                    sleep(3000);
                } catch (Exception error) {
                    failures++;
                    // Прив'язка до Wi-Fi могла застаріти — після трьох невдач
                    // підряд пробуємо звичайною дорогою.
                    if (failures == 3 && current.isBound()) current.useNetwork(null);
                    if (failures >= 2) {
                        final String why = Api.describe(error);
                        main.post(() -> {
                            online = false;
                            status.setText(getString(R.string.status_lost, describeServer()) + " (" + why + ")");
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
        if (!online) {
            online = true;
            bible.open();
        }
        String name = fresh.name.isEmpty() ? describeServer() : fresh.name;
        Mode programMode = Mode.of(fresh.mode);
        status.setText(getString(R.string.status_connected, name)
            + (programMode == null ? "" : " · " + getString(programMode.title)));
        black.setTextColor(fresh.black ? Color.parseColor("#FF6B6B") : Color.WHITE);

        // Перемкнули вкладку на комп'ютері — планшет іде слідом.
        if (programMode != null && !fresh.mode.equals(followedMode)) {
            followedMode = fresh.mode;
            if (programMode != mode) chooseMode(programMode, false);
        }
        markModeButtons(programMode);

        applyHall(fresh);
        String preview = fresh.previewText.isEmpty() ? fresh.previewReference
            : (fresh.previewReference.isEmpty() ? fresh.previewText : fresh.previewReference + " — " + fresh.previewText);
        previewText.setText(preview.isEmpty() ? "" : getString(R.string.t_preview, preview.replace('\n', ' ')));

        // Сторона: План — зі стану; Історію перечитуємо, коли стан змінився.
        if (sideHistory) {
            if (fresh.seq != historySeq) loadHistory();
        } else {
            fillPlan();
        }

        switch (mode) {
            case SONGS:
                if (!fresh.songBook.equals(songsBook)) loadSongs();
                fillParts();
                break;
            case PRESENTATION:
                fillPresentation();
                break;
            case PICTURES:
                if (fresh.showCount != picturesCount && "pictures".equals(fresh.mode)) loadPictures();
                break;
            default:
                break;
        }
    }

    private void markModeButtons(Mode programMode) {
        for (Map.Entry<Mode, Button> entry : modeButtons.entrySet()) {
            boolean chosen = entry.getKey() == mode;
            entry.getValue().setTextColor(chosen ? ACCENT : Color.WHITE);
            String title = getString(entry.getKey().title);
            entry.getValue().setText(entry.getKey() == programMode && !chosen ? "● " + title : title);
        }
    }

    // MARK: Зал

    /// Картинка залу: перезабираємо, коли змінився стан, і не частіше, ніж
    /// встигає прийти попередня. Відео й затемнення не тягнемо — пишемо.
    private void applyHall(State fresh) {
        String kind = fresh.hallKind;
        String caption = getString(R.string.t_hall);
        if (!fresh.liveReference.isEmpty() && "text".equals(kind)) caption += " — " + fresh.liveReference;
        else if (!fresh.hallTitle.isEmpty() && ("still".equals(kind) || "video".equals(kind))) caption += " — " + fresh.hallTitle;
        hallCaption.setText(caption);
        liveText.setText("text".equals(kind) ? fresh.liveText : "");

        if ("video".equals(kind)) {
            showHallNote(getString(R.string.t_hall_video, fresh.hallTitle));
            return;
        }
        if ("black".equals(kind)) {
            showHallNote(getString(R.string.t_hall_black));
            return;
        }
        hallNote.setText("empty".equals(kind) ? getString(R.string.t_hall_empty) : "");
        if (fresh.seq != hallSeq) {
            hallSeq = fresh.seq;
            requestHall();
        } else {
            showHall();
        }
    }

    private void showHallNote(String text) {
        hallBitmap = null;
        shownCrop = "";
        hallImage.setImageBitmap(null);
        hallNote.setText(text);
        updateImageRect();
    }

    private void requestHall() {
        if (hallBusy) { hallPending = true; return; }
        final Api current = api;
        if (current == null) return;
        hallBusy = true;
        hallPending = false;
        final int width = Math.max(480, Math.min(1600, hallImage.getWidth() > 0 ? hallImage.getWidth() : 1280));
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
                    shownCrop = "";
                    showHall();
                }
                if (hallPending) requestHall();
            });
        });
    }

    /// Вікно наближення в частках цілого кадру: {ліво, верх, сторона} —
    /// те саме правило, що в програмі (`SlideFocus.rect`).
    private double[] zoomWindow() {
        if (!state.zoomOn || state.zoom <= 1.001) return new double[] {0, 0, 1};
        double side = 1.0 / Math.max(1.0, Math.min(6.0, state.zoom));
        double left = Math.min(1 - side, Math.max(0, state.zoomX - side / 2));
        double top = Math.min(1 - side, Math.max(0, state.zoomY - side / 2));
        return new double[] {left, top, side};
    }

    /// Зал на планшеті — такий, як на стіні: при наближенні — вирізане вікно.
    private void showHall() {
        Bitmap full = hallBitmap;
        if (full == null) return;
        if (!zooming) zoomNow = state.zoomOn ? state.zoom : 1;
        double[] window = zoomWindow();
        String signature = window[0] + ":" + window[1] + ":" + window[2] + ":" + System.identityHashCode(full);
        if (signature.equals(shownCrop)) return;
        shownCrop = signature;
        Bitmap shown = full;
        if (window[2] < 1) {
            int x = (int) Math.round(window[0] * full.getWidth());
            int y = (int) Math.round(window[1] * full.getHeight());
            int w = Math.min(Math.max(2, (int) Math.round(window[2] * full.getWidth())), full.getWidth() - x);
            int h = Math.min(Math.max(2, (int) Math.round(window[2] * full.getHeight())), full.getHeight() - y);
            if (w > 1 && h > 1) shown = Bitmap.createBitmap(full, x, y, w, h);
        }
        hallImage.setImageBitmap(shown);
        updateImageRect();
        syncRemotePointer();
    }

    private RectF imageRect() {
        Drawable drawable = hallImage.getDrawable();
        if (drawable == null) return null;
        RectF shown = new RectF(0, 0, drawable.getIntrinsicWidth(), drawable.getIntrinsicHeight());
        Matrix matrix = hallImage.getImageMatrix();
        matrix.mapRect(shown);
        return shown.width() <= 0 || shown.height() <= 0 ? null : shown;
    }

    private void updateImageRect() {
        pointerView.setImageRect(imageRect());
    }

    private void syncRemotePointer() {
        if (touching) return;
        boolean ownEcho = Settings.POINTER_SOURCE_PHONE.equals(state.pointerSource)
            && System.currentTimeMillis() - touchEndedAt < 1500;
        if (!state.pointerOn || ownEcho) {
            pointerView.hide();
            return;
        }
        int colour = settings.pointerColour();
        try { if (!state.pointerColour.isEmpty()) colour = Color.parseColor(state.pointerColour); } catch (IllegalArgumentException ignored) { }
        float size = state.pointerSize > 0 ? (float) state.pointerSize : settings.pointerSize();
        pointerView.setLook(colour, size, (float) state.pointerOpacity);
        pointerView.show((float) state.pointerX, (float) state.pointerY);
    }

    /// Палець на залі — указка на стіні; два пальці — наближення. Подвійний
    /// дотик знімає наближення.
    private long lastTapAt;

    private boolean hallTouch(View view, MotionEvent event) {
        RectF shown = imageRect();
        // Картинки залу немає — затемнення чи відео: указці нема куди лягти,
        // і без цієї перевірки пляма падала в кут чорного екрана.
        if (shown == null || hallBitmap == null) return false;
        if (view.getParent() != null) view.getParent().requestDisallowInterceptTouchEvent(true);
        zoomDetector.onTouchEvent(event);
        if (zooming) {
            if (event.getActionMasked() == MotionEvent.ACTION_UP || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                zooming = false;
            }
            return true;
        }
        if (event.getPointerCount() > 1 || System.currentTimeMillis() - zoomEndedAt < 250) return true;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: {
                long now = System.currentTimeMillis();
                if (now - lastTapAt < 300 && state.zoomOn) {
                    lastTapAt = 0;
                    resetZoom();
                    return true;
                }
                lastTapAt = now;
            }
            // fall through
            case MotionEvent.ACTION_MOVE: {
                double x = Math.max(0, Math.min(1, (event.getX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (event.getY() - shown.top) / shown.height()));
                if (!touching) {
                    touching = true;
                    pointerView.setLook(settings.pointerColour(), settings.pointerSize(), settings.pointerOpacity());
                    pointerView.setImageRect(shown);
                }
                pointerView.show((float) x, (float) y);
                queuePointer(x, y);
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL: {
                touching = false;
                touchEndedAt = System.currentTimeMillis();
                pointerView.hide();
                pendingX = -1;
                pendingY = -1;
                Api current = api;
                if (current != null) pointerQueue.execute(() -> { try { current.pointerOff(); } catch (Exception ignored) { } });
                return true;
            }
            default:
                return false;
        }
    }

    private void queueZoom(double zoom, double x, double y) {
        long now = System.currentTimeMillis();
        if (zoomBusy || now - lastZoomAt < 50) return;
        lastZoomAt = now;
        Api current = api;
        if (current == null) return;
        zoomBusy = true;
        pointerQueue.execute(() -> {
            try { current.zoom(zoom, x, y); } catch (Exception ignored) { }
            zoomBusy = false;
        });
    }

    private void resetZoom() {
        zoomNow = 1;
        Api current = api;
        if (current == null) return;
        pointerQueue.execute(() -> { try { current.zoom(1, 0.5, 0.5); } catch (Exception ignored) { } });
    }

    private void queuePointer(double x, double y) {
        pendingX = x;
        pendingY = y;
        long now = System.currentTimeMillis();
        if (pointerBusy || now - lastPointerAt < 40) return;
        lastPointerAt = now;
        final Api current = api;
        if (current == null) return;
        final String colour = settings.pointerColourHex();
        final double size = settings.pointerSize();
        final double opacity = settings.pointerOpacity();
        pointerBusy = true;
        pointerQueue.execute(() -> {
            double sentX = Double.NaN, sentY = Double.NaN;
            while (true) {
                double px = pendingX, py = pendingY;
                if (px < 0 || (px == sentX && py == sentY)) break;
                try { current.pointer(px, py, colour, size, opacity); } catch (Exception error) { break; }
                sentX = px;
                sentY = py;
            }
            pointerBusy = false;
        });
    }

    // MARK: Вкладки

    private void chooseMode(Mode chosen, boolean fromTouch) {
        mode = chosen;
        if (fromTouch) {
            followedMode = chosen.key;
            send("mode", body("text", chosen.key), null);
        }
        markModeButtons(Mode.of(state.mode));
        hideKeyboard();
        boolean isBible = chosen == Mode.BIBLE;
        biblePanel.setVisibility(isBible ? View.VISIBLE : View.GONE);
        otherPanel.setVisibility(isBible ? View.GONE : View.VISIBLE);
        if (isBible) {
            if (online) bible.open();
            return;
        }

        panelTools.removeAllViews();
        panelFooter.removeAllViews();
        panelRows.clear();
        panelAdapter.notifyDataSetChanged();
        gridAdapter.notifyDataSetChanged();
        gridSignature = "";
        panelNote.setText("");
        showGrid(false);
        switch (chosen) {
            case SONGS: buildSongs(); break;
            case PRESENTATION: buildPresentation(); break;
            case MEDIA: buildMedia(); break;
            case PICTURES: buildPictures(); break;
            case SCREEN: buildScreen(); break;
            case TEXT: buildText(); break;
            default: break;
        }
    }

    private void showGrid(boolean grid) {
        panelGrid.setVisibility(grid ? View.VISIBLE : View.GONE);
        panelList.setVisibility(grid ? View.GONE : View.VISIBLE);
    }

    private Button smallButton(String title, View.OnClickListener action) {
        Button button = new Button(this, null, 0, R.style.SmallButton);
        button.setText(title);
        button.setOnClickListener(action);
        return button;
    }

    private LinearLayout row(View... views) {
        LinearLayout line = new LinearLayout(this);
        line.setOrientation(LinearLayout.HORIZONTAL);
        line.setGravity(Gravity.CENTER_VERTICAL);
        for (View view : views) line.addView(view);
        return line;
    }

    private static LinearLayout.LayoutParams weight(float weight) {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, weight);
    }

    // MARK: Біблія — пошук за словами

    private void runSearch() {
        final String query = bibleSearch.getText().toString().trim();
        if (query.isEmpty()) return;
        hideKeyboard();
        searchBar.setVisibility(View.VISIBLE);
        bibleBar.setVisibility(View.GONE);
        searchRows.clear();
        searchAdapter.notifyDataSetChanged();
        searchNote.setText(getString(R.string.t_searching, query));
        send("bible-search", body("text", query), () -> pollSearch(query, 0));
    }

    private void pollSearch(String query, int attempt) {
        read("/api/search", json -> {
            boolean searching = json.optBoolean("searching", false);
            if (searching && attempt < 50) {
                main.postDelayed(() -> pollSearch(query, attempt + 1), 400);
                return;
            }
            JSONArray hits = json.optJSONArray("hits");
            searchRows.clear();
            if (hits != null) {
                for (int i = 0; i < hits.length(); i++) {
                    JSONObject hit = hits.optJSONObject(i);
                    if (hit == null) continue;
                    final int index = hit.optInt("index", i);
                    searchRows.add(new Row(hit.optString("reference", ""), hit.optString("text", ""), false,
                        () -> send("search-hit", body("index", index, "live", false), null),
                        () -> send("search-hit", body("index", index, "live", true), null), null));
                }
            }
            searchAdapter.notifyDataSetChanged();
            searchNote.setText(searchRows.isEmpty() ? getString(R.string.t_search_none, query)
                : getString(R.string.t_search_found, query, searchRows.size()));
        });
    }

    private void closeSearch() {
        searchBar.setVisibility(View.GONE);
        bibleBar.setVisibility(View.VISIBLE);
        bible.reload();
    }

    // MARK: Пісні

    private void buildSongs() {
        songBookButton = smallButton(getString(R.string.t_songbook), v -> chooseSongBook());
        EditText filter = new EditText(this);
        filter.setHint(R.string.t_song_filter);
        filter.setSingleLine(true);
        filter.setText(songFilter);
        filter.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void afterTextChanged(Editable s) {
                songFilter = s.toString();
                fillSongs();
            }
        });
        panelTools.addView(row(songBookButton, filter));
        filter.setLayoutParams(weight(1));

        TextView partsTitle = new TextView(this);
        partsTitle.setText(R.string.t_parts);
        partsTitle.setTextColor(0xFF9AA4B2);
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        partButtons = new LinearLayout(this);
        partButtons.setOrientation(LinearLayout.HORIZONTAL);
        scroll.addView(partButtons);
        panelFooter.addView(partsTitle);
        panelFooter.addView(scroll);
        partsSignature = "";
        panelNote.setText(R.string.t_songs_loading);
        loadSongs();
        fillParts();
    }

    private void loadSongs() {
        read("/api/songs/list", json -> {
            songs = json.optJSONArray("songs");
            if (songs == null) songs = new JSONArray();
            songsBook = json.optString("book", "");
            if (mode == Mode.SONGS) {
                fillSongs();
                read("/api/songs/books", books -> {
                    JSONArray list = books.optJSONArray("books");
                    if (list == null || songBookButton == null) return;
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject book = list.optJSONObject(i);
                        if (book != null && book.optString("id").equals(songsBook)) {
                            songBookButton.setText(book.optString("title", songsBook));
                        }
                    }
                });
            }
        });
    }

    private void fillSongs() {
        if (mode != Mode.SONGS) return;
        String needle = songFilter.trim().toLowerCase(Locale.ROOT);
        // Без String.chars(): його немає на Android 5 і 6, а планшет працює й там.
        boolean number = !needle.isEmpty();
        for (int i = 0; i < needle.length() && number; i++) number = Character.isDigit(needle.charAt(i));
        panelRows.clear();
        for (int i = 0; i < songs.length() && panelRows.size() < 400; i++) {
            JSONObject song = songs.optJSONObject(i);
            if (song == null) continue;
            String title = song.optString("title", "");
            int n = song.optInt("number", i + 1);
            if (!needle.isEmpty()) {
                if (number ? !String.valueOf(n).startsWith(needle) : !title.toLowerCase(Locale.ROOT).contains(needle)) continue;
            }
            final int index = song.optInt("index", i);
            panelRows.add(new Row(n + ". " + title, song.optString("subtitle", ""),
                title.equals(state.songTitle), () -> send("song", index), null, null));
        }
        panelAdapter.notifyDataSetChanged();
        panelNote.setText(songs.length() == 0 ? getString(R.string.song_empty) : "");
    }

    private void fillParts() {
        if (partButtons == null || mode != Mode.SONGS) return;
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
            Button button = smallButton(title, v -> send("part", index));
            button.setTextColor(part.current ? ACCENT : Color.WHITE);
            partButtons.addView(button);
        }
        fillSongs();
    }

    private void chooseSongBook() {
        read("/api/songs/books", json -> {
            JSONArray list = json.optJSONArray("books");
            if (list == null || list.length() == 0) return;
            String[] titles = new String[list.length()];
            String[] ids = new String[list.length()];
            int checked = -1;
            for (int i = 0; i < list.length(); i++) {
                JSONObject book = list.optJSONObject(i);
                ids[i] = book == null ? "" : book.optString("id", "");
                titles[i] = book == null ? "" : book.optString("title", ids[i]);
                if (ids[i].equals(json.optString("current"))) checked = i;
            }
            new AlertDialog.Builder(this)
                .setTitle(R.string.t_songbook)
                .setSingleChoiceItems(titles, checked, (dialog, which) -> {
                    dialog.dismiss();
                    songBookButton.setText(titles[which]);
                    send("songs-book", body("text", ids[which]), this::loadSongs);
                })
                .show();
        });
    }

    // MARK: Презентація

    private void buildPresentation() {
        HorizontalScrollView scroll = new HorizontalScrollView(this);
        deckButtons = new LinearLayout(this);
        deckButtons.setOrientation(LinearLayout.HORIZONTAL);
        scroll.addView(deckButtons);
        panelTools.addView(row(smallButton(getString(R.string.t_add_file), v -> pickFile())));
        panelTools.addView(scroll);
        showGrid(true);
        fillPresentation();
    }

    private void fillPresentation() {
        if (mode != Mode.PRESENTATION || deckButtons == null) return;
        StringBuilder signature = new StringBuilder();
        for (State.Row deck : state.decks) signature.append(deck.title).append(deck.current).append('|');
        for (int i = 0; i < state.pages.size(); i++) signature.append(state.pageIndexes.get(i)).append(state.pages.get(i).title).append(',');
        signature.append(state.pageIndex);
        String caption = state.pageIndex < 0 ? getString(R.string.show_empty)
            : getString(R.string.page_of, state.pageLocal + 1, state.pageCount)
              + (state.onWall ? " " + getString(R.string.on_wall) : "")
              + (state.pageTitle.isEmpty() ? "" : "  — " + state.pageTitle);
        panelNote.setText(caption);
        if (signature.toString().equals(gridSignature)) return;
        gridSignature = signature.toString();

        deckButtons.removeAllViews();
        for (int i = 0; i < state.decks.size(); i++) {
            final int index = i;
            State.Row deck = state.decks.get(i);
            Button button = smallButton(deck.title + " (" + deck.subtitle + ")", v -> send("deck", index));
            button.setTextColor(deck.current ? ACCENT : Color.WHITE);
            deckButtons.addView(button);
        }
        panelRows.clear();
        for (int i = 0; i < state.pages.size(); i++) {
            final int index = state.pageIndexes.get(i);
            State.Row page = state.pages.get(i);
            panelRows.add(new Row((i + 1) + ". " + page.title, "", index == state.pageIndex,
                () -> send("page", index), null, "/api/page?index=" + index + "&w=320#" + page.title));
        }
        gridAdapter.notifyDataSetChanged();
    }

    // MARK: Плеєр

    private void buildMedia() {
        mediaShown = "";
        mediaPlay = smallButton(getString(R.string.t_play), v -> send("media-toggle", null, this::loadMedia));
        Button toBegin = smallButton(getString(R.string.t_to_begin), v -> send("media-seek", body("x", 0), this::loadMedia));
        Button stop = smallButton(getString(R.string.t_stop), v -> send("media-stop", null, this::loadMedia));
        mediaTime = new TextView(this);
        mediaTime.setPadding(12, 0, 12, 0);
        panelTools.addView(row(toBegin, mediaPlay, stop, mediaTime));

        mediaSeek = new SeekBar(this);
        mediaSeek.setMax(1000);
        mediaSeek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (fromUser && mediaDuration > 0) mediaTime.setText(clock(progress / 1000.0 * mediaDuration) + " / " + clock(mediaDuration));
            }
            @Override public void onStartTrackingTouch(SeekBar bar) { seekDragging = true; }
            @Override public void onStopTrackingTouch(SeekBar bar) {
                seekDragging = false;
                if (mediaDuration > 0) send("media-seek", body("x", bar.getProgress() / 1000.0 * mediaDuration), null);
            }
        });
        panelTools.addView(mediaSeek);

        TextView volumeTitle = new TextView(this);
        volumeTitle.setText(R.string.t_volume);
        volumeTitle.setPadding(8, 0, 8, 0);
        mediaVolume = new SeekBar(this);
        mediaVolume.setMax(100);
        mediaVolume.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) { }
            @Override public void onStartTrackingTouch(SeekBar bar) { volumeDragging = true; }
            @Override public void onStopTrackingTouch(SeekBar bar) {
                volumeDragging = false;
                send("media-volume", body("x", bar.getProgress() / 100.0), null);
            }
        });
        panelTools.addView(row(volumeTitle, mediaVolume));
        mediaVolume.setLayoutParams(weight(1));

        mediaMute = smallButton(getString(R.string.t_mute), v -> send("media-mute", null, this::loadMedia));
        mediaScreen = smallButton(getString(R.string.t_to_screen), v -> send("media-screen", null, this::loadMedia));
        mediaRepeat = smallButton(getString(R.string.t_repeat), v -> send("media-repeat", null, this::loadMedia));
        panelTools.addView(row(mediaMute, mediaScreen, mediaRepeat));
        loadMedia();
    }

    private void loadMedia() {
        if (mode != Mode.MEDIA) return;
        read("/api/media", this::fillMedia);
    }

    /// Що плеєр показував минулого разу: той самий стан — екран не чіпаємо.
    /// Опитування йде щосекунди, і без цього панель без кінця перемальовувалась.
    private String mediaShown = "";

    private void fillMedia(JSONObject json) {
        if (mode != Mode.MEDIA || mediaPlay == null) return;
        String shown = json.toString();
        if (shown.equals(mediaShown) && !seekDragging && !volumeDragging) return;
        mediaShown = shown;
        boolean playing = json.optBoolean("playing", false);
        mediaPlay.setText(playing ? R.string.t_pause : R.string.t_play);
        mediaDuration = json.optDouble("duration", 0);
        double position = json.optDouble("position", 0);
        if (!seekDragging) {
            mediaSeek.setProgress(mediaDuration > 0 ? (int) Math.round(position / mediaDuration * 1000) : 0);
            String title = json.optString("title", "");
            mediaTime.setText((title.isEmpty() ? getString(R.string.t_nothing_open) : title)
                + (mediaDuration > 0 ? "   " + clock(position) + " / " + clock(mediaDuration) : ""));
        }
        if (!volumeDragging) mediaVolume.setProgress((int) Math.round(json.optDouble("volume", 1) * 100));
        mediaMute.setTextColor(json.optBoolean("muted", false) ? ACCENT : Color.WHITE);
        mediaScreen.setTextColor(json.optBoolean("toScreen", false) ? ACCENT : Color.WHITE);
        mediaRepeat.setTextColor(json.optBoolean("repeats", false) ? ACCENT : Color.WHITE);

        JSONArray list = json.optJSONArray("playlist");
        int current = json.optInt("index", -1);
        StringBuilder signature = new StringBuilder().append(current);
        if (list != null) for (int i = 0; i < list.length(); i++) signature.append('|').append(list.optJSONObject(i));
        if (signature.toString().equals(gridSignature)) return;
        gridSignature = signature.toString();
        panelRows.clear();
        if (list != null) {
            for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.optJSONObject(i);
                if (item == null) continue;
                final int index = item.optInt("index", i);
                panelRows.add(new Row(item.optString("name", ""), "", index == current,
                    () -> send("media-open", body("index", index), this::loadMedia), null, null));
            }
        }
        panelAdapter.notifyDataSetChanged();
        panelNote.setText(panelRows.isEmpty() ? getString(R.string.t_media_empty) : "");
    }

    private static String clock(double seconds) {
        long total = Math.max(0, Math.round(seconds));
        long hours = total / 3600, minutes = total / 60 % 60, rest = total % 60;
        return hours > 0 ? String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, rest)
            : String.format(Locale.ROOT, "%d:%02d", minutes, rest);
    }

    // MARK: Зображення

    private void buildPictures() {
        panelTools.addView(row(smallButton(getString(R.string.t_add_photos), v -> pickPhotos())));
        showGrid(true);
        picturesCount = -1;
        loadPictures();
    }

    private void loadPictures() {
        read("/api/pictures", json -> {
            if (mode != Mode.PICTURES) return;
            JSONArray pages = json.optJSONArray("pages");
            int current = json.optInt("index", -1);
            picturesCount = json.optInt("count", 0);
            panelRows.clear();
            if (pages != null) {
                for (int i = 0; i < pages.length(); i++) {
                    JSONObject page = pages.optJSONObject(i);
                    if (page == null) continue;
                    final int index = page.optInt("index", i);
                    String title = page.optString("title", "");
                    panelRows.add(new Row(title, "", index == current, () -> send("picture", body("index", index), this::loadPictures),
                        null, "/api/page?kind=pictures&index=" + index + "&w=320#" + title));
                }
            }
            gridAdapter.notifyDataSetChanged();
            panelNote.setText(panelRows.isEmpty() ? getString(R.string.t_pictures_empty) : "");
        });
    }

    // MARK: Екран

    private void buildScreen() {
        panelTools.addView(row(
            smallButton(getString(R.string.t_screen_refresh), v -> send("screen-reload", null, () -> main.postDelayed(this::loadScreen, 1200))),
            smallButton(getString(R.string.t_screen_stop), v -> send("screen-stop", null, this::loadScreen))));
        screenRetries = 0;
        loadScreen();
    }

    private void loadScreen() {
        read("/api/screen", json -> {
            if (mode != Mode.SCREEN) return;
            JSONArray sources = json.optJSONArray("sources");
            String current = json.optString("current", "");
            panelRows.clear();
            String running = "";
            if (sources != null) {
                for (int i = 0; i < sources.length(); i++) {
                    JSONObject source = sources.optJSONObject(i);
                    if (source == null) continue;
                    final int index = source.optInt("index", i);
                    boolean now = source.optString("id").equals(current) && json.optBoolean("running", false);
                    if (now) running = source.optString("title", "");
                    panelRows.add(new Row(source.optString("title", ""), source.optString("subtitle", ""), now,
                        () -> send("screen-start", body("index", index), this::loadScreen), null, null));
                }
            }
            panelAdapter.notifyDataSetChanged();
            if (panelRows.isEmpty()) {
                // Список джерел програма збирає у фоні — перше питання часто
                // приходить раніше, ніж він готовий.
                if (screenRetries++ < 3) main.postDelayed(this::loadScreen, 1500);
                panelNote.setText(R.string.t_screen_empty);
            } else {
                panelNote.setText(running.isEmpty() ? json.optString("note", "") : getString(R.string.t_screen_running, running));
            }
        });
    }

    // MARK: Текст

    private void buildText() {
        textTitle = new EditText(this);
        textTitle.setHint(R.string.t_text_title_hint);
        textTitle.setSingleLine(true);
        textBody = new EditText(this);
        textBody.setHint(R.string.t_text_body_hint);
        textBody.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
            | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        textBody.setMinLines(6);
        textBody.setGravity(Gravity.TOP | Gravity.START);
        panelTools.addView(textTitle);
        panelTools.addView(textBody);
        panelTools.addView(row(
            smallButton(getString(R.string.t_text_preview), v -> sendText(false)),
            smallButton(getString(R.string.t_text_show), v -> sendText(true))));
        textPages = new TextView(this);
        textPages.setPadding(12, 0, 12, 0);
        panelTools.addView(row(
            smallButton("◀", v -> { if (textPage > 0) send("text-page", body("index", textPage - 1), this::loadText); }),
            textPages,
            smallButton("▶", v -> { if (textPage + 1 < textPageCount) send("text-page", body("index", textPage + 1), this::loadText); })));
        panelList.setVisibility(View.GONE);
        loadText();
    }

    private void sendText(boolean live) {
        hideKeyboard();
        JSONObject json = body("text", textBody.getText().toString(), "title", textTitle.getText().toString());
        send("text-set", json, () -> {
            if (live) send("text-show", null, this::loadText); else loadText();
        });
    }

    private void loadText() {
        read("/api/text", json -> {
            if (mode != Mode.TEXT || textBody == null) return;
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

    private void chooseSide(boolean showHistory) {
        sideHistory = showHistory;
        sideSelected = -1;
        tabPlan.setTextColor(showHistory ? Color.WHITE : ACCENT);
        tabHistory.setTextColor(showHistory ? ACCENT : Color.WHITE);
        planAdd.setVisibility(showHistory ? View.GONE : View.VISIBLE);
        planUp.setVisibility(showHistory ? View.GONE : View.VISIBLE);
        planDown.setVisibility(showHistory ? View.GONE : View.VISIBLE);
        if (showHistory) loadHistory(); else fillPlan();
    }

    private void fillPlan() {
        if (sideHistory) return;
        sideRows.clear();
        for (int i = 0; i < state.plan.size(); i++) {
            final int index = i;
            State.Row item = state.plan.get(i);
            sideRows.add(new Row(item.title, item.subtitle, item.current || index == sideSelected,
                () -> { sideSelected = index; send("plan", index); fillPlan(); }, null, null));
        }
        sideAdapter.notifyDataSetChanged();
        showSideNote(sideRows.isEmpty() ? getString(R.string.t_plan_empty) : "");
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
        if (!sideHistory) return;
        sideRows.clear();
        for (int i = 0; i < history.length(); i++) {
            JSONObject record = history.optJSONObject(i);
            if (record == null) continue;
            final int index = record.optInt("index", i);
            String caption = record.optString("caption", "");
            int cut = caption.indexOf("- ");
            String title = cut > 0 ? caption.substring(0, cut) : caption;
            String rest = cut > 0 ? caption.substring(cut + 2) : "";
            sideRows.add(new Row(title, rest, record.optBoolean("current", false) || index == sideSelected,
                () -> { sideSelected = index; send("history", index); fillHistory(); }, null, null));
        }
        sideAdapter.notifyDataSetChanged();
        showSideNote(sideRows.isEmpty() ? getString(R.string.t_history_empty) : "");
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
        if (index < 0) return;
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
            status.setText(getString(R.string.upload_failed, error.getMessage()));
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
            status.setText(getString(R.string.photo_failed, error.getMessage()));
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
        status.setText(getString(R.string.uploading, name));
        commands.execute(() -> {
            try {
                byte[] bytes;
                try (InputStream stream = getContentResolver().openInputStream(uri)) {
                    if (stream == null) throw new java.io.IOException("порожній файл");
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] chunk = new byte[65536];
                    int count;
                    while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
                    bytes = out.toByteArray();
                }
                JSONObject answer = current.upload(name, bytes);
                int pages = answer == null ? 0 : answer.optInt("pages", 0);
                main.post(() -> status.setText(getString(R.string.uploaded, name, pages)));
            } catch (Exception error) {
                main.post(() -> status.setText(getString(R.string.upload_failed,
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
                main.post(() -> status.setText(getString(R.string.photo_sending, n, uris.size())));
                try {
                    PhotoShrink.Result photo = PhotoShrink.prepare(getContentResolver(), uris.get(i), 2560);
                    JSONObject answer = current.upload("Фото " + stamp + "-" + n + "." + photo.extension, photo.bytes, false);
                    if (first < 0 && answer != null) first = answer.optInt("page", -1);
                    sent++;
                } catch (Exception error) {
                    final String why = error.getMessage() == null ? error.toString() : error.getMessage();
                    main.post(() -> status.setText(getString(R.string.photo_failed, why)));
                }
            }
            if (first >= 0) {
                try { current.command("picture", body("index", first)); } catch (Exception ignored) { }
            }
            final int total = sent;
            main.post(() -> {
                if (total > 0) status.setText(getString(R.string.photo_sent, total));
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

    private void hideKeyboard() {
        View focused = getCurrentFocus();
        InputMethodManager keyboard = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (focused != null && keyboard != null) keyboard.hideSoftInputFromWindow(focused.getWindowToken(), 0);
    }

    // MARK: Списки

    private void wireList(ListView list, List<Row> rows) {
        list.setOnItemClickListener((AdapterView<?> parent, View view, int position, long id) -> {
            if (position < rows.size() && rows.get(position).tap != null) {
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
                rows.get(position).tap.run();
            }
        });
        list.setOnItemLongClickListener((parent, view, position, id) -> {
            if (position < rows.size() && rows.get(position).longTap != null) {
                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
                rows.get(position).longTap.run();
                return true;
            }
            return false;
        });
    }

    private final class RowAdapter extends BaseAdapter {
        private final List<Row> rows;

        RowAdapter(List<Row> rows) { this.rows = rows; }

        @Override public int getCount() { return rows.size(); }
        @Override public Object getItem(int position) { return rows.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            View view = recycled != null ? recycled
                : getLayoutInflater().inflate(R.layout.row_item, parent, false);
            Row row = rows.get(position);
            TextView title = view.findViewById(R.id.title);
            TextView subtitle = view.findViewById(R.id.subtitle);
            title.setText(row.title);
            subtitle.setText(row.subtitle);
            subtitle.setVisibility(row.subtitle.isEmpty() ? View.GONE : View.VISIBLE);
            view.setBackgroundColor(row.current ? CURRENT_ROW : Color.TRANSPARENT);
            return view;
        }
    }

    /// Сітка мініатюр: слайди презентації й картинки. Мініатюри тягнемо по
    /// одній і тримаємо, поки не зміниться підпис сторінки.
    private final class ThumbAdapter extends BaseAdapter {
        @Override public int getCount() { return panelRows.size(); }
        @Override public Object getItem(int position) { return panelRows.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            LinearLayout cell;
            ImageView picture;
            TextView caption;
            if (recycled instanceof LinearLayout) {
                cell = (LinearLayout) recycled;
                picture = (ImageView) cell.getChildAt(0);
                caption = (TextView) cell.getChildAt(1);
            } else {
                cell = new LinearLayout(TabletActivity.this);
                cell.setOrientation(LinearLayout.VERTICAL);
                cell.setPadding(4, 4, 4, 4);
                picture = new ImageView(TabletActivity.this);
                picture.setScaleType(ImageView.ScaleType.FIT_CENTER);
                picture.setBackgroundColor(Color.BLACK);
                int height = Math.round(90 * getResources().getDisplayMetrics().density);
                cell.addView(picture, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height));
                caption = new TextView(TabletActivity.this);
                caption.setSingleLine(true);
                caption.setTextSize(12);
                cell.addView(caption);
            }
            Row row = panelRows.get(position);
            caption.setText(row.title);
            cell.setBackgroundColor(row.current ? CURRENT_ROW : Color.TRANSPARENT);
            Bitmap ready = row.thumb == null ? null : thumbs.get(row.thumb);
            picture.setImageBitmap(ready);
            if (ready == null && row.thumb != null) loadThumb(row.thumb);
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
                    gridAdapter.notifyDataSetChanged();
                }
            });
        });
    }
}
