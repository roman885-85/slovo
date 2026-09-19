package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.HapticFeedbackConstants;
import android.view.KeyEvent;
import android.view.Menu;
import android.view.MenuItem;
import android.os.Build;
import android.provider.MediaStore;
import android.content.ClipData;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Сам пульт: что в зале, кнопки и списки — план, части песни, Библия, поиск.
///
/// Состояние приходит долгим опросом в своём потоке: сервер держит ответ до
/// первого изменения, поэтому телефон узнаёт о смене слайда сразу, а
/// батарею впустую не жжёт. Команды уходят из отдельного исполнителя по
/// одной: две команды подряд не должны обгонять друг друга.
public final class RemoteActivity extends Activity {

    /// «Презентація» — первой: главная работа пульта — листать слайды
    /// проповедника и вести по ним указку.
    private enum Tab { SHOW, PLAN, SONG, BIBLE, SEARCH }

    private static final int PICK_FILE = 7;

    private Settings settings;
    private Api api;
    /// Ловець мережі Wi-Fi: усі запити мають іти саме нею.
    private ConnectivityManager.NetworkCallback wifiWatch;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService commands = Executors.newSingleThreadExecutor();
    private Thread poller;
    private volatile boolean polling;
    private volatile long seq;
    private State state = new State();
    private Tab tab = Tab.SHOW;

    // Презентація: картинка сторінки, пляма указки поверх неї, підпис,
    // черга картинок і указки. Блок залу на цій вкладці схований.
    private View showBar;
    private View hallBar;
    private View zoomBack;
    private ImageView pageImage;
    private PointerView pointerView;
    private TextView pageCaption;
    /// Палець зараз на картинці: чужу указку зі стану тоді не малюємо.
    private boolean touching;
    /// Коли палець прибрали: луна власної указки зі стану ще секунду
    /// приходить як «увімкнена», і без цієї позначки пляма блимала б.
    private long touchEndedAt;
    private int shownPage = -2;
    /// Скачана сторінка цілком — з неї вирізається вікно наближення.
    private Bitmap pageBitmap;
    /// Що зараз стоїть у картинці: щоб не різати те саме вдруге.
    private String shownCrop = "";

    /// Показане вікно наближення {ліво, верх, сторона}: їде до цілі плавно
    /// за 280 мс, а не стрибає. Власник: «переход в исходное состояние не
    /// резко, а плавно… подтягивание слайда — пусть это будет тоже плавно».
    /// Під щипком і з новою картинкою — одразу.
    private double[] shownWindow = {0, 0, 1};
    private android.animation.ValueAnimator windowRide;
    private int shownBitmapId;
    private final ExecutorService images = Executors.newSingleThreadExecutor();
    private final ExecutorService pointerQueue = Executors.newSingleThreadExecutor();
    private volatile boolean pointerBusy;
    private volatile double pendingX = -1, pendingY = -1;
    private long lastPointerAt;
    /// Что делает нажатие на строку вкладки «Презентація»: {0=колода|1=страница, номер}.
    private final List<int[]> showActions = new ArrayList<>();
    private final List<State.Row> searchRows = new ArrayList<>();
    private final List<Integer> searchSongIndexes = new ArrayList<>();

    private TextView status;
    private TextView liveReference;
    private TextView liveText;
    private TextView previewText;
    private Button black;
    private Button[] tabButtons;
    private View inputBar;
    private EditText input;
    private ListView list;
    private final RowAdapter adapter = new RowAdapter();

    private static final int PICK_PHOTO = 8;
    /// Вкладка «Біблія»: переклад → книга → розділ → вірші.
    private BibleBrowser bible;
    /// Пісні: список пісень пісенника чи куплети вибраної пісні.
    private View songBar;
    private Button songBookButton;
    private final List<State.Row> songRows = new ArrayList<>();
    private final List<Integer> songIndexes = new ArrayList<>();
    private boolean songListing = true;
    private String songBookTitle = "";
    private View bibleBar;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        settings = new Settings(this);
        if (!settings.hasHost()) {
            startActivity(new Intent(this, ConnectActivity.class));
            finish();
            return;
        }
        setContentView(R.layout.activity_remote);
        // Нова версія програми: питаємо GitHub раз на добу, мовчки.
        Updates.checkQuietly(this);
        status = findViewById(R.id.status);
        liveReference = findViewById(R.id.liveReference);
        liveText = findViewById(R.id.liveText);
        previewText = findViewById(R.id.previewText);
        black = findViewById(R.id.black);
        inputBar = findViewById(R.id.inputBar);
        input = findViewById(R.id.input);
        list = findViewById(R.id.list);
        list.setAdapter(adapter);
        list.setOnItemClickListener((parent, view, position, id) -> rowTapped(position));
        bibleBar = findViewById(R.id.bibleBar);
        bible = new BibleBrowser(this, new BibleBrowser.Host() {
            @Override public Api api() { return api; }
            @Override public java.util.concurrent.ExecutorService queue() { return commands; }
            @Override public void post(Runnable body) { main.post(body); }
        }, bibleBar);

        songBar = findViewById(R.id.songBar);
        songBookButton = findViewById(R.id.songBook);
        songBookButton.setOnClickListener(v -> chooseSongBook());
        findViewById(R.id.songBack).setOnClickListener(v -> { songListing = true; loadSongs(); });

        showBar = findViewById(R.id.showBar);
        hallBar = findViewById(R.id.hallBar);
        pageImage = findViewById(R.id.pageImage);
        pointerView = findViewById(R.id.pointerView);
        zoomBack = findViewById(R.id.zoomBack);
        zoomBack.setOnClickListener(v -> resetZoom());
        pageCaption = findViewById(R.id.pageCaption);
        findViewById(R.id.uploadButton).setOnClickListener(v -> pickFile());
        findViewById(R.id.photoButton).setOnClickListener(v -> pickPhotos());
        // Щипок двома пальцями по картинці наближає зал до того місця, де
        // пальці. Власник: «еще в пульте добавить увеличение (точка
        // фокуса)». Один палець лишається указкою — жести не сперечаються:
        // поки пальців два, указка мовчить.
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
                double wanted = zoomNow * detector.getScaleFactor();
                zoomNow = Math.max(1.0, Math.min(6.0, wanted));
                double x = Math.max(0, Math.min(1, (detector.getFocusX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (detector.getFocusY() - shown.top) / shown.height()));
                queueZoom(zoomNow, x, y);
                return true;
            }
            @Override public void onScaleEnd(ScaleGestureDetector detector) {
                zoomEndedAt = System.currentTimeMillis();
            }
        });
        pageImage.setOnTouchListener(this::pointerTouch);
        pageImage.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> updateImageRect());
        applyPointerLook();
        // Меню в своей шапке — те же пункты, что были в панели заголовка.
        findViewById(R.id.menuButton).setOnClickListener(v -> {
            PopupMenu popup = new PopupMenu(this, v);
            onCreateOptionsMenu(popup.getMenu());
            popup.setOnMenuItemClickListener(this::onOptionsItemSelected);
            popup.show();
        });

        bind(R.id.prev, "prev");
        bind(R.id.next, "next");
        bind(R.id.show, "show");
        bind(R.id.hide, "hide");
        bind(R.id.black, "black");

        tabButtons = new Button[] {
            findViewById(R.id.tabShow), findViewById(R.id.tabPlan), findViewById(R.id.tabSong),
            findViewById(R.id.tabBible), findViewById(R.id.tabSearch),
        };
        Tab[] tabs = Tab.values();
        for (int i = 0; i < tabButtons.length; i++) {
            final Tab chosen = tabs[i];
            tabButtons[i].setOnClickListener(v -> selectTab(chosen));
        }
        findViewById(R.id.inputGo).setOnClickListener(v -> submitInput());
        input.setOnEditorActionListener((view, action, event) -> {
            if (action == EditorInfo.IME_ACTION_GO || action == EditorInfo.IME_ACTION_DONE
                || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER)) {
                submitInput();
                return true;
            }
            return false;
        });
        selectTab(Tab.SHOW);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings == null || !settings.hasHost()) return;
        applyAwake();
        api = new Api(settings.host(), settings.port(), settings.pin());
        watchWiFi();
        status.setText(getString(R.string.status_connecting, describeServer()));
        startPolling();
    }

    @Override
    protected void onPause() {
        super.onPause();
        stopPolling();
        unwatchWiFi();
    }

    /// Питаємо систему про мережу Wi-Fi і ходимо саме нею.
    ///
    /// Програма стоїть у локальній мережі, а телефон, якщо вважає Wi-Fi
    /// мережею без інтернету, тримає за умовчанням мобільний зв'язок. Тоді
    /// запит на 192.168.x.x іде в стільниковий канал і доходить лише другою
    /// спробою — команда виконується, але із затримкою в кілька секунд.
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
            // Дозволу немає або система відмовила — працюємо як раніше.
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

    // MARK: Меню

    private static final int MENU_CONNECTION = 1, MENU_VOLUME = 2, MENU_AWAKE = 3,
        MENU_REVERSED = 4, MENU_POINTER = 5, MENU_RESET = 6, MENU_ZOOM_OFF = 7, MENU_LANGUAGE = 8,
        MENU_UPDATE = 9, MENU_RESOURCES = 10;

    /// Мова інтерфейсу (див. `Lang`) — до того, як вікно візьме ресурси.
    @Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        applyOverrideConfiguration(Lang.override(base, null));
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(0, MENU_CONNECTION, 0, R.string.menu_connection);
        menu.add(0, MENU_VOLUME, 1, R.string.menu_volume_keys).setCheckable(true).setChecked(settings.volumeKeys());
        menu.add(0, MENU_REVERSED, 2, R.string.menu_volume_reversed).setCheckable(true)
            .setChecked(settings.volumeReversed()).setEnabled(settings.volumeKeys());
        menu.add(0, MENU_AWAKE, 3, R.string.menu_keep_awake).setCheckable(true).setChecked(settings.keepAwake());
        menu.add(0, MENU_POINTER, 4, R.string.menu_pointer);
        menu.add(0, MENU_ZOOM_OFF, 5, R.string.menu_zoom_off);
        menu.add(0, MENU_RESET, 6, R.string.menu_reset);
        menu.add(0, MENU_LANGUAGE, 7, R.string.menu_language);
        menu.add(0, MENU_RESOURCES, 8, R.string.menu_resources);
        menu.add(0, MENU_UPDATE, 9, R.string.menu_update);
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        switch (item.getItemId()) {
            case MENU_ZOOM_OFF:
                resetZoom();
                return true;
            case MENU_CONNECTION:
                startActivity(new Intent(this, ConnectActivity.class));
                finish();
                return true;
            case MENU_VOLUME:
                settings.setVolumeKeys(!item.isChecked());
                item.setChecked(settings.volumeKeys());
                return true;
            case MENU_REVERSED:
                settings.setVolumeReversed(!item.isChecked());
                item.setChecked(settings.volumeReversed());
                return true;
            case MENU_AWAKE:
                settings.setKeepAwake(!item.isChecked());
                item.setChecked(settings.keepAwake());
                applyAwake();
                return true;
            case MENU_POINTER:
                showPointerDialog();
                return true;
            case MENU_RESET:
                confirmReset();
                return true;
            case MENU_LANGUAGE:
                Lang.showChooser(this);
                return true;
            case MENU_RESOURCES:
                startActivity(new Intent(this, ResourcesActivity.class));
                return true;
            case MENU_UPDATE:
                Updates.checkNow(this);
                return true;
            default:
                return super.onOptionsItemSelected(item);
        }
    }

    // MARK: Клавіші гучності

    @Override
    public boolean onKeyDown(int code, KeyEvent event) {
        if (settings != null && settings.volumeKeys()
            && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) {
            // Звично «мінус — далі, плюс — назад»; «Плюс гортає назад»
            // вимкнено — і навпаки, коли на телефоні кнопки стоять інакше.
            boolean forward = (code == KeyEvent.KEYCODE_VOLUME_DOWN) != settings.volumeReversed();
            send(forward ? "next" : "prev");
            return true;
        }
        return super.onKeyDown(code, event);
    }

    @Override
    public boolean onKeyUp(int code, KeyEvent event) {
        // Иначе система всё равно покажет ползунок громкости на отпускание.
        if (settings != null && settings.volumeKeys()
            && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) {
            return true;
        }
        return super.onKeyUp(code, event);
    }

    // MARK: Команды

    private void bind(int id, String command) {
        findViewById(id).setOnClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            send(command);
        });
    }

    private void send(String command) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.command(command);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void send(String command, int index) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.command(command, index);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void send(String command, String text) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.command(command, text);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void showFailure(Exception error) {
        main.post(() -> {
            if (error instanceof Api.PinRejected) {
                status.setText(R.string.status_pin);
            } else {
                status.setText(getString(R.string.status_lost, describeServer()));
            }
        });
    }

    // MARK: Опрос состояния

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
                    // Прив'язка до Wi-Fi могла застаріти (мережу перепідключили,
                    // а система не сказала): після трьох невдач підряд — звичайною
                    // дорогою; нова прив'язка прийде з наступним onAvailable.
                    if (failures == 3 && current.isBound()) current.useNetwork(null);
                    if (failures >= 2) {
                        final String why = Api.describe(error);
                        main.post(() -> status.setText(getString(R.string.status_lost, describeServer()) + " (" + why + ")"));
                    }
                    // Власник: «на короткое время иногда находит слово, но
                    // вскоре связь пропадает и не подключается снова».
                    // Записана адреса могла застаріти — комп'ютер отримав
                    // іншу від роутера. Після кількох невдач шукаємо «Слово»
                    // заново й самі переходимо на живу адресу.
                    if (failures == 4 || failures % 12 == 0) rediscover();
                    // Пауза растёт до пяти секунд: не долбить выключенный
                    // компьютер, но и подхватить его сразу, как включат.
                    sleep(Math.min(5000, 800 * failures));
                }
            }
        }, "slovo-poll");
        poller.setDaemon(true);
        poller.start();
    }

    /// Знайти «Слово» заново й перейти на адресу, яка відповідає.
    ///
    /// Шукаємо не частіше ніж раз на півхвилини: перебір підмережі — справа
    /// не безкоштовна. Беремо ту саму машину за іменем, а як не знайшлася —
    /// першу, що озвалася.
    private volatile long searchedAt;

    private void rediscover() {
        if (System.currentTimeMillis() - searchedAt < 30000) return;
        searchedAt = System.currentTimeMillis();
        final String wanted = settings.name();
        final java.util.List<String[]> hits = new java.util.ArrayList<>();
        final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        final Discovery search = new Discovery(this, new Discovery.Listener() {
            @Override public void found(String name, String host, int port) {
                hits.add(new String[] { name, host, String.valueOf(port) });
            }
            @Override public void finished() { done.countDown(); }
        });
        main.post(search::start);
        try {
            done.await(30, java.util.concurrent.TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
        main.post(search::stop);
        if (hits.isEmpty()) return;
        String[] pick = hits.get(0);
        for (String[] hit : hits) {
            if (hit[0] != null && hit[0].equals(wanted)) { pick = hit; break; }
        }
        final String host = pick[1];
        final int port = Integer.parseInt(pick[2]);
        if (host.equals(settings.host()) && port == settings.port()) return;
        final String name = pick[0];
        main.post(() -> {
            settings.save(host, port, settings.pin(), name == null ? settings.name() : name);
            status.setText(getString(R.string.status_connecting, host));
            api = new Api(host, port, settings.pin());
            seq = 0;
            startPolling();
        });
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
        String name = fresh.name.isEmpty() ? describeServer() : fresh.name;
        String modeName = modeTitle(fresh.mode);
        status.setText(getString(R.string.status_connected, name) + (modeName.isEmpty() ? "" : " · " + modeName));

        if (fresh.black) {
            liveReference.setText(R.string.black_on);
            liveText.setText("");
        } else if (!fresh.live || (fresh.liveText.isEmpty() && fresh.liveReference.isEmpty())) {
            liveReference.setText(fresh.showTitle.isEmpty() ? getString(R.string.live_empty) : fresh.showTitle);
            liveText.setText("");
        } else {
            liveReference.setText(fresh.liveReference);
            liveText.setText(fresh.liveText);
        }
        black.setTextColor(fresh.black ? Color.parseColor("#FF6B6B") : Color.WHITE);

        String preview = fresh.previewText.isEmpty() ? fresh.previewReference
            : (fresh.previewReference.isEmpty() ? fresh.previewText : fresh.previewReference + " — " + fresh.previewText);
        previewText.setText(preview.isEmpty() ? "" : getString(R.string.preview_prefix) + preview.replace('\n', ' '));

        refreshPage(fresh, false);
        // Наступний щипок починається з тієї кратності, що справді в залі:
        // її могли змінити мишею з комп'ютера.
        if (!zooming) zoomNow = fresh.zoomOn ? fresh.zoom : 1;
        zoomBack.setVisibility(fresh.zoomOn && fresh.zoom > 1.001 ? View.VISIBLE : View.GONE);
        showPage();
        syncRemotePointer(fresh);
        // Вірш перемкнули на комп'ютері — підсвічення в пульті йде слідом.
        if (tab == Tab.BIBLE) bible.follow(fresh.biblePosition, fresh.bibleChapter, fresh.bibleVerses);
        if (tab != Tab.SEARCH) adapter.notifyDataSetChanged();
    }

    // MARK: Презентация

    /// Картинка текущей страницы и подпись «Слайд 3 з 12 · в залі».
    /// Картинку просим заново только когда сменилась страница: она тяжёлая.
    private void refreshPage(State fresh, boolean force) {
        String caption = fresh.pageIndex < 0 ? ""
            : getString(R.string.page_of, fresh.pageLocal + 1, fresh.pageCount)
              + (fresh.onWall ? " " + getString(R.string.on_wall) : "")
              + (fresh.pageTitle.isEmpty() ? "" : "  — " + fresh.pageTitle);
        pageCaption.setText(caption);
        if (fresh.pageIndex < 0) {
            shownPage = -1;
            pageBitmap = null;
            shownCrop = "";
            if (windowRide != null) { windowRide.cancel(); windowRide = null; }
            shownWindow = new double[] {0, 0, 1};
            pageImage.setImageBitmap(null);
            updateImageRect();
            return;
        }
        if (!force && fresh.pageIndex == shownPage) return;
        final int wanted = fresh.pageIndex;
        shownPage = wanted;
        final Api current = api;
        if (current == null) return;
        images.execute(() -> {
            try {
                int width = Math.max(480, Math.min(1080, getResources().getDisplayMetrics().widthPixels));
                byte[] bytes = current.pageImage(wanted, width);
                Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                main.post(() -> {
                    if (state.pageIndex == wanted && bitmap != null) {
                        pageBitmap = bitmap;
                        shownCrop = "";
                        showPage();
                    }
                });
            } catch (Exception error) {
                main.post(() -> { if (shownPage == wanted) shownPage = -2; });
            }
        });
    }

    /// Сторінка на телефоні — така сама, як у залі.
    ///
    /// Власник: «при зуме страницы щипком на пульте, слайд в пульте
    /// зумируется также как и на выходе проектора». При наближенні ставимо в
    /// картинку не всю сторінку, а те саме вікно, що ріже програма
    /// (`SlideFocus.rect`: сторона 1/кратність, середина в точці, притиснуте
    /// до країв). Тоді й указка, і щипок міряються в частках показаного
    /// кадру — рівно так, як їх чекає програма. Доти телефон показував
    /// сторінку цілком, і після першого ж щипка точка наближення їхала.
    private void showPage() {
        Bitmap full = pageBitmap;
        if (full == null) return;
        double[] target = zoomWindow();
        boolean fresh = System.identityHashCode(full) != shownBitmapId;
        shownBitmapId = System.identityHashCode(full);
        boolean same = Math.abs(target[0] - shownWindow[0]) + Math.abs(target[1] - shownWindow[1])
            + Math.abs(target[2] - shownWindow[2]) < 1e-4;
        if (windowRide != null) { windowRide.cancel(); windowRide = null; }
        if (fresh || zooming || same) {
            shownWindow = target;
            drawWindow(full, target);
            return;
        }
        final double[] from = shownWindow.clone();
        android.animation.ValueAnimator ride = android.animation.ValueAnimator.ofFloat(0f, 1f);
        ride.setDuration(280);
        ride.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
        ride.addUpdateListener(a -> {
            float e = (float) a.getAnimatedValue();
            shownWindow = new double[] { from[0] + (target[0] - from[0]) * e,
                                        from[1] + (target[1] - from[1]) * e,
                                        from[2] + (target[2] - from[2]) * e };
            Bitmap now = pageBitmap;
            if (now != null) drawWindow(now, shownWindow);
        });
        windowRide = ride;
        ride.start();
    }

    /// Вирізати вікно з картинки й поставити у вид.
    private void drawWindow(Bitmap full, double[] window) {
        String signature = window[0] + ":" + window[1] + ":" + window[2] + ":" + System.identityHashCode(full);
        if (signature.equals(shownCrop)) return;
        shownCrop = signature;
        Bitmap shown = full;
        if (window[2] < 0.999) {
            int x = (int) Math.round(window[0] * full.getWidth());
            int y = (int) Math.round(window[1] * full.getHeight());
            int w = Math.min(Math.max(2, (int) Math.round(window[2] * full.getWidth())), full.getWidth() - x);
            int h = Math.min(Math.max(2, (int) Math.round(window[2] * full.getHeight())), full.getHeight() - y);
            if (w > 1 && h > 1) shown = Bitmap.createBitmap(full, x, y, w, h);
        }
        pageImage.setImageBitmap(shown);
        updateImageRect();
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

    /// Де всередині виду намальовано саму картинку: по боках бувають поля.
    /// `null` — картинки ще немає.
    private RectF imageRect() {
        Drawable drawable = pageImage.getDrawable();
        if (drawable == null) return null;
        RectF shown = new RectF(0, 0, drawable.getIntrinsicWidth(), drawable.getIntrinsicHeight());
        Matrix matrix = pageImage.getImageMatrix();
        matrix.mapRect(shown);
        return shown.width() <= 0 || shown.height() <= 0 ? null : shown;
    }

    private void updateImageRect() {
        pointerView.setImageRect(imageRect());
    }

    /// Вигляд плями під пальцем — цілком із налаштувань пульта: колір,
    /// розмір і яскравість. Раніше яскравість бралася з програми, і покрутити
    /// її з телефона було не можна.
    private void applyPointerLook() {
        pointerView.setLook(settings.pointerColour(), settings.pointerSize(), settings.pointerOpacity());
    }

    /// Чужа указка (мишею з комп'ютера або з іншого телефона) — теж на
    /// картинці, кольором і розміром, які віддала програма. Поки палець на
    /// екрані, своя пляма важливіша.
    private void syncRemotePointer(State fresh) {
        if (touching) return;
        boolean ownEcho = Settings.POINTER_SOURCE_PHONE.equals(fresh.pointerSource)
            && System.currentTimeMillis() - touchEndedAt < 1500;
        if (!fresh.pointerOn || ownEcho) {
            pointerView.hide();
            return;
        }
        int colour = parseColour(fresh.pointerColour, settings.pointerColour());
        float size = fresh.pointerSize > 0 ? (float) fresh.pointerSize : settings.pointerSize();
        pointerView.setLook(colour, size, (float) fresh.pointerOpacity);
        pointerView.show((float) fresh.pointerX, (float) fresh.pointerY);
    }

    private static int parseColour(String hex, int fallback) {
        try {
            return hex == null || hex.isEmpty() ? fallback : Color.parseColor(hex);
        } catch (IllegalArgumentException error) {
            return fallback;
        }
    }

    /// Палець на картинці — указка на стіні й тут же на телефоні. Координати —
    /// частки намальованої картинки (не всього виду: по боках бувають поля).
    private boolean pointerTouch(View view, MotionEvent event) {
        RectF shown = imageRect();
        if (shown == null) return false;
        if (view.getParent() != null) view.getParent().requestDisallowInterceptTouchEvent(true);
        if (zoomDetector != null) zoomDetector.onTouchEvent(event);
        // Поки пальців більше одного — це наближення, а не указка. І ще
        // чверть секунди після: піднімаючи щипок, один палець відривається
        // раніше за другий, і без цієї паузи в залі спалахувала пляма.
        if (zooming) {
            if (event.getActionMasked() == MotionEvent.ACTION_UP
                    || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                zooming = false;
            }
            return true;
        }
        if (event.getPointerCount() > 1 || System.currentTimeMillis() - zoomEndedAt < 250) return true;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_MOVE: {
                double x = Math.max(0, Math.min(1, (event.getX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (event.getY() - shown.top) / shown.height()));
                if (!touching) {
                    touching = true;
                    applyPointerLook();
                    pointerView.setImageRect(shown);
                }
                pointerView.show((float) x, (float) y);
                queuePointer(x, y);
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                touching = false;
                touchEndedAt = System.currentTimeMillis();
                pointerView.hide();
                pendingX = -1; pendingY = -1;
                Api current = api;
                if (current != null) pointerQueue.execute(() -> { try { current.pointerOff(); } catch (Exception ignored) { } });
                return true;
            default:
                return false;
        }
    }

    private ScaleGestureDetector zoomDetector;
    private boolean zooming;
    private long zoomEndedAt;
    private double zoomNow = 1;
    private boolean zoomBusy;
    private long lastZoomAt;

    /// Кратність шлемо не частіше двадцяти разів на секунду і без черги: щипок
    /// сипле подіями сотнями, а залу досить бачити останню.
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

    /// Зняти наближення — пункт меню і подвійний дотик двома пальцями.
    private void resetZoom() {
        zoomNow = 1;
        Api current = api;
        if (current == null) return;
        pointerQueue.execute(() -> { try { current.zoom(1, 0.5, 0.5); } catch (Exception ignored) { } });
    }

    /// Не частіше одного запиту в польоті: поки попередній не пішов, нові точки
    /// лише запам'ятовуються, і в мережу йде остання.
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
                sentX = px; sentY = py;
            }
            pointerBusy = false;
        });
    }

    // MARK: Указка: колір і розмір

    /// Кольори на вибір: помітні на будь-якому слайді. Перший — початковий,
    /// той самий, що в програмі.
    private static final int[] POINTER_COLOURS = {
        Settings.DEFAULT_POINTER_COLOUR, 0xFFFF3B30, 0xFF34C759, 0xFF3B82F6,
        0xFF22D3EE, 0xFFE040FB, 0xFFFF9500, 0xFFFFFFFF,
    };

    /// Вікно «Указка»: ряд кольорів, повзунок розміру і жива проба плями.
    /// «Початкові» повертає жовту пляму в 14 %, не закриваючи вікна.
    private void showPointerDialog() {
        final float density = getResources().getDisplayMetrics().density;
        final int pad = Math.round(16 * density);
        final int[] chosen = { settings.pointerColour() };
        final float[] size = { settings.pointerSize() };
        final float[] opacity = { settings.pointerOpacity() };

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad / 2, pad, 0);

        TextView colourLabel = new TextView(this);
        colourLabel.setText(R.string.pointer_colour);
        root.addView(colourLabel);

        // Вісім кольорів у два ряди по чотири: в один ряд вони не вміщаються
        // у вікно на вузькому телефоні, і крайні ховалися за краєм.
        final LinearLayout swatches = new LinearLayout(this);
        swatches.setOrientation(LinearLayout.VERTICAL);
        swatches.setPadding(0, pad / 2, 0, pad / 2);
        root.addView(swatches);

        final PointerView sample = new PointerView(this);
        FrameLayout stage = new FrameLayout(this);
        stage.setBackgroundColor(0xFF4A5568);
        stage.addView(sample, new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        final TextView sizeLabel = new TextView(this);
        final SeekBar seek = new SeekBar(this);
        final int minPercent = Math.round(Settings.MIN_POINTER_SIZE * 100);
        final int maxPercent = Math.round(Settings.MAX_POINTER_SIZE * 100);
        seek.setMax(maxPercent - minPercent);

        // Яскравість — третій повзунок. Власник просив крутити її з телефона:
        // у світлому залі пляма має бути щільнішою, у темному — ледь помітною.
        final TextView brightLabel = new TextView(this);
        final SeekBar bright = new SeekBar(this);
        final int minBright = Math.round(Settings.MIN_POINTER_OPACITY * 100);
        final int maxBright = Math.round(Settings.MAX_POINTER_OPACITY * 100);
        bright.setMax(maxBright - minBright);

        final List<View> swatchViews = new ArrayList<>();
        Runnable refresh = () -> {
            for (int i = 0; i < swatchViews.size(); i++) {
                View swatch = swatchViews.get(i);
                int colour = POINTER_COLOURS[i];
                GradientDrawable circle = new GradientDrawable();
                circle.setShape(GradientDrawable.OVAL);
                circle.setColor(colour);
                circle.setStroke(Math.round((colour == chosen[0] ? 3 : 1) * density),
                                 colour == chosen[0] ? 0xFFFFFFFF : 0x66FFFFFF);
                swatch.setBackground(circle);
            }
            int percent = Math.round(size[0] * 100);
            sizeLabel.setText(getString(R.string.pointer_size, percent));
            if (seek.getProgress() != percent - minPercent) seek.setProgress(percent - minPercent);
            int shine = Math.round(opacity[0] * 100);
            brightLabel.setText(getString(R.string.pointer_brightness, shine));
            if (bright.getProgress() != shine - minBright) bright.setProgress(shine - minBright);
            sample.setLook(chosen[0], size[0], opacity[0]);
            sample.show(0.5f, 0.5f);
        };

        int swatchSize = Math.round(44 * density);
        int gap = Math.round(8 * density);
        LinearLayout row = null;
        for (int i = 0; i < POINTER_COLOURS.length; i++) {
            final int colour = POINTER_COLOURS[i];
            if (i % 4 == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                swatches.addView(row);
            }
            View swatch = new View(this);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(swatchSize, swatchSize);
            params.setMargins(gap, gap / 2, gap, gap / 2);
            swatch.setLayoutParams(params);
            swatch.setOnClickListener(v -> { chosen[0] = colour; refresh.run(); });
            row.addView(swatch);
            swatchViews.add(swatch);
        }

        root.addView(sizeLabel);
        root.addView(seek);
        root.addView(brightLabel);
        root.addView(bright);
        root.addView(stage, new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, Math.round(120 * density)));
        stage.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) ->
            sample.setImageRect(new RectF(0, 0, r - l, b - t)));

        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser) return;
                size[0] = (progress + minPercent) / 100f;
                refresh.run();
            }
            @Override public void onStartTrackingTouch(SeekBar bar) { }
            @Override public void onStopTrackingTouch(SeekBar bar) { }
        });
        bright.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser) return;
                opacity[0] = (progress + minBright) / 100f;
                refresh.run();
            }
            @Override public void onStartTrackingTouch(SeekBar bar) { }
            @Override public void onStopTrackingTouch(SeekBar bar) { }
        });
        refresh.run();

        final AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle(R.string.pointer_title)
            .setView(root)
            .setPositiveButton(R.string.done, (d, which) -> {
                settings.setPointer(chosen[0], size[0], opacity[0]);
                applyPointerLook();
            })
            .setNegativeButton(R.string.cancel, null)
            .setNeutralButton(R.string.pointer_defaults, null)
            .create();
        dialog.show();
        // Кнопка «Початкові» не закриває вікно: людина бачить пробу і може
        // ще передумати.
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
            chosen[0] = Settings.DEFAULT_POINTER_COLOUR;
            size[0] = Settings.DEFAULT_POINTER_SIZE;
            opacity[0] = Settings.DEFAULT_POINTER_OPACITY;
            refresh.run();
        });
    }

    /// «Скинути налаштування…» — з питанням: скидання не має статися від
    /// випадкового дотику в темному залі.
    private void confirmReset() {
        new AlertDialog.Builder(this)
            .setTitle(R.string.reset_title)
            .setMessage(R.string.reset_message)
            .setPositiveButton(R.string.reset, (d, which) -> {
                settings.resetPreferences();
                applyAwake();
                applyPointerLook();
                Toast.makeText(this, R.string.reset_done, Toast.LENGTH_SHORT).show();
            })
            .setNegativeButton(R.string.cancel, null)
            .show();
    }

    /// «Завантажити файл…» — выбрать PDF, PPTX или картинку на телефоне и
    /// отправить программе: та откроет её в показе.
    private void pickFile() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
            "application/pdf",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
            "image/*",
        });
        try {
            startActivityForResult(intent, PICK_FILE);
        } catch (Exception error) {
            status.setText(getString(R.string.upload_failed, error.getMessage()));
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == PICK_PHOTO) {
            if (resultCode == RESULT_OK && data != null) sendPhotos(photoUris(data));
            return;
        }
        if (requestCode != PICK_FILE || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        final Uri uri = data.getData();
        final String name = displayName(uri);
        final Api current = api;
        if (current == null) return;
        status.setText(getString(R.string.uploading, name));
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
                main.post(() -> {
                    status.setText(getString(R.string.uploaded, name, pages));
                    selectTab(Tab.SHOW);
                });
            } catch (Exception error) {
                main.post(() -> status.setText(getString(R.string.upload_failed,
                    error.getMessage() == null ? error.toString() : error.getMessage())));
            }
        });
    }

    /// Фото з галереї телефона — у програму, і перше з них одразу на стіну.
    ///
    /// Власник: «добавить функцию вывода изображений (из библиотеки
    /// телефона)». На Android 13 і новіших — системний вибір фото (дозволу
    /// на всю галерею не треба); на старіших — звичайний вибір файлів.
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

    /// Надсилаємо по одному, зменшеними: знімок телефона важить 5–10 МБ, а
    /// стіні більше 2560 точок не треба. Потім перше надіслане — на стіну;
    /// решта стоять у списку й гортаються «Далі».
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
                    JSONObject answer = current.upload(Lang.t("Фото ", "Photo ") + stamp + "-" + n + "." + photo.extension,
                                                       photo.bytes, false);
                    if (first < 0 && answer != null) first = answer.optInt("page", -1);
                    sent++;
                } catch (Exception error) {
                    final String why = error.getMessage() == null ? error.toString() : error.getMessage();
                    main.post(() -> status.setText(getString(R.string.photo_failed, why)));
                }
            }
            if (first >= 0) {
                try { current.command("page", first); } catch (Exception ignored) { }
            }
            final int total = sent;
            main.post(() -> { if (total > 0) status.setText(getString(R.string.photo_sent, total)); });
        });
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int column = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                if (column >= 0) {
                    String name = cursor.getString(column);
                    if (name != null && !name.isEmpty()) return name;
                }
            }
        } catch (Exception ignored) { }
        String tail = uri.getLastPathSegment();
        return tail == null || tail.isEmpty() ? "файл" : tail;
    }

    private String modeTitle(String mode) {
        switch (mode) {
            case "bible": return getString(R.string.mode_bible);
            case "songs": return getString(R.string.mode_songs);
            case "presentation": return getString(R.string.mode_presentation);
            case "media": return getString(R.string.mode_media);
            case "pictures": return getString(R.string.mode_pictures);
            case "text": return getString(R.string.mode_text);
            default: return "";
        }
    }

    // MARK: Пісні пісенника

    /// Список пісень відкритого пісенника — з програми. Власник: «иметь
    /// возможность выбора песен с песенника»: доти на телефоні можна було
    /// лише шукати пісню за словом, а гортати пісенник — ні.
    private void loadSongs() {
        final Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                JSONObject books = current.get("/api/songs/books");
                JSONObject list = current.get("/api/songs/list");
                String bookTitle = "";
                String open = books.optString("current", "");
                JSONArray all = books.optJSONArray("books");
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject book = all.optJSONObject(i);
                        if (book != null && open.equals(book.optString("id"))) {
                            bookTitle = book.optString("title", "");
                            break;
                        }
                    }
                }
                final String title = bookTitle;
                JSONArray songs = list.optJSONArray("songs");
                final List<State.Row> rows = new ArrayList<>();
                final List<Integer> indexes = new ArrayList<>();
                int selected = list.optInt("selected", -1);
                if (songs != null) {
                    for (int i = 0; i < songs.length(); i++) {
                        JSONObject song = songs.optJSONObject(i);
                        if (song == null) continue;
                        int index = song.optInt("index", i);
                        String name = song.optString("title", "");
                        String note = song.optString("subtitle", "");
                        // Підпис, що повторює назву, — зайвий рядок: у пісень
                        // перший рядок куплета часто і є назвою.
                        if (note.startsWith(name) || name.startsWith(note)) note = "";
                        rows.add(new State.Row(song.optInt("number", index + 1) + ". " + name, note, index == selected));
                        indexes.add(index);
                    }
                }
                main.post(() -> {
                    songBookTitle = title;
                    songBookButton.setText(title.isEmpty() ? getString(R.string.song_book) : title);
                    songRows.clear();
                    songRows.addAll(rows);
                    songIndexes.clear();
                    songIndexes.addAll(indexes);
                    if (tab == Tab.SONG) adapter.notifyDataSetChanged();
                });
            } catch (Exception error) {
                final String why = Api.describe(error);
                main.post(() -> status.setText(getString(R.string.status_lost, describeServer()) + " (" + why + ")"));
            }
        });
    }

    /// Вибір пісенника: список від програми, вибір міняє пісенник і в залі.
    private void chooseSongBook() {
        final Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                JSONObject books = current.get("/api/songs/books");
                JSONArray all = books.optJSONArray("books");
                final List<String> ids = new ArrayList<>();
                final List<String> titles = new ArrayList<>();
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject book = all.optJSONObject(i);
                        if (book == null) continue;
                        ids.add(book.optString("id"));
                        titles.add(book.optString("title", book.optString("short", "")));
                    }
                }
                main.post(() -> {
                    if (ids.isEmpty()) return;
                    new AlertDialog.Builder(RemoteActivity.this)
                        .setTitle(R.string.song_pick_book)
                        .setItems(titles.toArray(new String[0]), (dialog, which) -> {
                            commands.execute(() -> {
                                try {
                                    current.command("songs-book", ids.get(which));
                                } catch (Exception ignored) { }
                                main.post(() -> { songListing = true; loadSongs(); });
                            });
                        })
                        .show();
                });
            } catch (Exception ignored) { }
        });
    }

    // MARK: Вкладки и списки

    private void selectTab(Tab chosen) {
        tab = chosen;
        Tab[] tabs = Tab.values();
        for (int i = 0; i < tabButtons.length; i++) {
            tabButtons[i].setTextColor(tabs[i] == chosen ? Color.parseColor("#4C8DFF") : Color.parseColor("#9AA4B2"));
        }
        boolean needsInput = chosen == Tab.BIBLE || chosen == Tab.SEARCH;
        inputBar.setVisibility(needsInput ? View.VISIBLE : View.GONE);
        // На презентації місце віддано слайду: куплети й вірші залу тут ні до чого.
        showBar.setVisibility(chosen == Tab.SHOW ? View.VISIBLE : View.GONE);
        hallBar.setVisibility(chosen == Tab.SHOW ? View.GONE : View.VISIBLE);
        // Біблія має свій перегляд — книги, розділи, вірші; загальний список
        // на цій вкладці ховаємо.
        bibleBar.setVisibility(chosen == Tab.BIBLE ? View.VISIBLE : View.GONE);
        songBar.setVisibility(chosen == Tab.SONG ? View.VISIBLE : View.GONE);
        if (chosen == Tab.SONG) loadSongs();
        list.setVisibility(chosen == Tab.BIBLE ? View.GONE : View.VISIBLE);
        if (chosen == Tab.BIBLE) bible.open();
        if (chosen == Tab.SHOW) refreshPage(state, true);
        input.setHint(chosen == Tab.BIBLE ? R.string.bible_hint : R.string.search_hint);
        if (!needsInput) hideKeyboard();
        adapter.notifyDataSetChanged();
    }

    private void submitInput() {
        String text = input.getText().toString().trim();
        if (text.isEmpty()) return;
        hideKeyboard();
        if (tab == Tab.BIBLE) {
            send("goto", text);
            // Програма стає на адресу, щойно прочитає розділи; тоді й перегляд
            // на телефоні переходить туди ж.
            main.postDelayed(() -> bible.reload(), 600);
            return;
        }
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                JSONArray songs = current.searchSongs(text);
                List<State.Row> rows = new ArrayList<>();
                List<Integer> indexes = new ArrayList<>();
                for (int i = 0; i < songs.length(); i++) {
                    JSONObject song = songs.optJSONObject(i);
                    if (song == null) continue;
                    rows.add(new State.Row(song.optString("title", ""), song.optString("subtitle", ""), false));
                    indexes.add(song.optInt("index", -1));
                }
                main.post(() -> {
                    searchRows.clear();
                    searchRows.addAll(rows);
                    searchSongIndexes.clear();
                    searchSongIndexes.addAll(indexes);
                    adapter.notifyDataSetChanged();
                });
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void hideKeyboard() {
        InputMethodManager manager = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (manager != null) manager.hideSoftInputFromWindow(input.getWindowToken(), 0);
    }

    private void rowTapped(int position) {
        list.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
        switch (tab) {
            case SHOW:
                if (position < showActions.size()) {
                    int[] action = showActions.get(position);
                    send(action[0] == 0 ? "deck" : "page", action[1]);
                }
                break;
            case PLAN:
                send("plan", position);
                break;
            case SONG:
                if (songListing) {
                    if (position < songIndexes.size()) {
                        send("song", songIndexes.get(position));
                        songListing = false;
                        adapter.notifyDataSetChanged();
                    }
                } else {
                    send("part", position);
                }
                break;
            case BIBLE:
                // Біблія має свій перегляд (BibleBrowser) — загальний список тут схований.
                break;
            case SEARCH:
                if (position < searchSongIndexes.size()) {
                    send("song", searchSongIndexes.get(position));
                    selectTab(Tab.SONG);
                }
                break;
        }
    }

    private List<State.Row> rows() {
        switch (tab) {
            case SHOW: {
                // Файлы — заголовками, страницы открытого файла — под ним.
                List<State.Row> rows = new ArrayList<>();
                showActions.clear();
                for (int i = 0; i < state.decks.size(); i++) {
                    State.Row deck = state.decks.get(i);
                    int count = 0;
                    try { count = Integer.parseInt(deck.subtitle); } catch (NumberFormatException ignored) { }
                    rows.add(new State.Row(deck.title, getString(R.string.deck_pages, count), deck.current));
                    showActions.add(new int[] {0, i});
                    if (!deck.current) continue;
                    for (int j = 0; j < state.pages.size(); j++) {
                        State.Row page = state.pages.get(j);
                        rows.add(new State.Row("      " + page.title, "", page.current));
                        showActions.add(new int[] {1, state.pageIndexes.get(j)});
                    }
                }
                return rows;
            }
            case PLAN: return state.plan;
            case SONG: return songListing ? songRows : state.parts;
            case SEARCH: return searchRows;
            case BIBLE: return new ArrayList<>();
            default: return new ArrayList<>();
        }
    }

    private String emptyText() {
        switch (tab) {
            case SHOW: return getString(R.string.show_empty);
            case PLAN: return getString(R.string.plan_empty);
            case SONG:
                if (songListing) return songRows.isEmpty() ? getString(R.string.song_list_empty) : "";
                return state.songTitle.isEmpty() ? getString(R.string.song_empty) : state.songTitle;
            case SEARCH: return searchRows.isEmpty() && input.length() > 0 ? getString(R.string.search_empty) : "";
            default: return "";
        }
    }

    /// Список без разметки на каждую строку: заголовок, подпись и подсветка
    /// текущего пункта. Строк немного — план и части песни.
    private final class RowAdapter extends BaseAdapter {
        @Override public int getCount() {
            List<State.Row> rows = rows();
            return rows.isEmpty() && !emptyText().isEmpty() ? 1 : rows.size();
        }

        @Override public Object getItem(int position) { return position; }
        @Override public long getItemId(int position) { return position; }

        @Override public View getView(int position, View recycled, ViewGroup parent) {
            View view = recycled != null ? recycled
                : getLayoutInflater().inflate(R.layout.row_item, parent, false);
            TextView title = view.findViewById(R.id.title);
            TextView subtitle = view.findViewById(R.id.subtitle);
            List<State.Row> rows = rows();
            if (rows.isEmpty()) {
                title.setText(emptyText());
                title.setTextColor(Color.parseColor("#9AA4B2"));
                subtitle.setText("");
                view.setBackgroundColor(Color.TRANSPARENT);
                return view;
            }
            State.Row row = rows.get(position);
            // На вкладке песни первая строка — название песни, чтобы было
            // видно, чью часть листаем.
            String head = row.title;
            if (tab == Tab.SONG && position == 0 && !state.songTitle.isEmpty()) {
                head = state.songTitle + "\n" + row.title;
            }
            title.setText(head);
            title.setTextColor(row.current ? Color.parseColor("#4C8DFF") : Color.parseColor("#F2F4F7"));
            subtitle.setText(row.subtitle);
            subtitle.setVisibility(row.subtitle.isEmpty() ? View.GONE : View.VISIBLE);
            view.setBackgroundColor(row.current ? Color.parseColor("#1F2C44") : Color.TRANSPARENT);
            return view;
        }
    }
}
