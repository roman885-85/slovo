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
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Сам пульт: слайд чи зал угорі, кнопки показу, розділи — слайди, Біблія,
/// пісні, план.
///
/// Вигляд — той самий, що в «Слові» для Android (власник: «там меню и интерфейс
/// получились намного удобнее и лучше»): каркас `Shell`, картки `SlideCard`,
/// елементи `Ui`. Тут лишилося те, що робить пульт пультом.
///
/// Стан приходить довгим опитуванням у своєму потоці: сервер тримає відповідь
/// до першої зміни, тож телефон дізнається про зміну слайда одразу, а батарею
/// марно не палить. Команди йдуть з окремого виконавця по одній: дві команди
/// поспіль не мають обганяти одна одну.
public final class RemoteActivity extends Activity implements Shell.Host, HallPad.Host, SettingsPage.Host {

    /// «Слайди» — першими: головна робота пульта — гортати слайди проповідника
    /// й вести по них указку. Назви йдуть у програму разом із командою.
    private enum Tab { SHOW, BIBLE, SONG, PLAN }

    private static final int PICK_FILE = 7, PICK_PHOTO = 8;

    private Settings settings;
    private volatile Api api;
    /// Ловець мережі Wi-Fi: усі запити мають іти саме нею.
    private ConnectivityManager.NetworkCallback wifiWatch;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService commands = Executors.newSingleThreadExecutor();
    private final ExecutorService images = Executors.newSingleThreadExecutor();
    private Thread poller;
    private volatile boolean polling;
    private volatile long seq;
    private State state = new State();
    private Tab tab = Tab.SHOW;
    /// Стан зв'язку словами — для сторінки налаштувань і вікна стану.
    private String link = "";
    /// На смужці під шапкою висить скарга на зв'язок — її прибирає перша ж відповідь програми.
    private boolean linkTrouble;
    /// Чи є зв'язок. Списки розділу перечитуються, щойно він з'являється: пульт
    /// вмикають і раніше за комп'ютер, і без повтору розділ так і стояв порожнім.
    private boolean online;

    // Вікно: каркас, картки, плитки. Будуються наново після повороту, зміни
    // масштабу чи мови; стан живе в полях вище й нижче, не у видах.
    private Shell shell;
    private SlideCard pageCard, liveCard, nextCard;
    private volatile HallPad pad;
    private TextView blackTile, zoomBack;
    private View[] panels;

    // Слайди: картинка поточної сторінки презентації.
    private Bitmap pageBitmap;
    /// Що зараз у великій картці: «s:сторінка» (презентація) або «p:фото:назва».
    private String shownKey = "";
    private final Lines showLines = new Lines();
    /// Фото — вкладка програми «Зображення»: туди «Слово» кладе картинки з телефона.
    /// Доти пульт їх не показував зовсім — фото надсилалося й зникало з очей.
    private final List<State.Row> pictures = new ArrayList<>();
    private boolean picturesLoaded;
    /// Коли востаннє питали список фото: не вдалося (повільна мережа) — питаємо знову, не частіше ніж раз на 10 с.
    private long picturesAskedAt;
    private String lastMode = "";
    private int lastShowCount = -1;
    private String lastPictures = "";
    private String showSignature = "", planSignature = "";
    private Thumbs thumbs;
    private ListView showList;
    private View showEmpty;
    /// Над списком: що відкрито й «Очистити весь список».
    private View showBar;
    private TextView showSummary;

    // Біблія.
    private BibleBrowser bible;

    // Пісні: увесь пісенник тримаємо тут і відбираємо без мережі; пошук у
    // текстах пісень веде програма.
    private final Lines songLines = new Lines();
    private final List<Lines.Line> songAll = new ArrayList<>();
    private List<Lines.Line> songFound;
    private boolean songListing = true, shownListing = true;
    /// Перелік пісень уже приходив: доти під пошуком «Завантажую…», а не «порожньо».
    private boolean songsLoaded;
    private String songFilter = "", songBookTitle = "";
    private TextView songBookButton, songBack, songNote;
    private ListView songList;
    private final Runnable songSearch = this::searchSongs;

    // План.
    private final Lines planLines = new Lines();
    private ListView planList;
    private View planEmpty;

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
        thumbs = new Thumbs(() -> api, () -> {
            showLines.notifyDataSetChanged();
        });
        showLines.thumbs = thumbs;
        buildShell();
        stand(getIntent());
        // Нова версія програми: питаємо GitHub раз на добу, мовчки.
        Updates.checkQuietly(this);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
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
            for (Tab each : Tab.values()) if (each.name().equalsIgnoreCase(wanted)) selectTab(each);
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
        else if ("pointer".equals(open)) SettingsPage.pointer(this, this::settingsChanged);
        else if ("status".equals(open)) onStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings == null || !settings.hasHost()) return;
        Ui.init(this);
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
    }

    @Override
    protected void onPause() {
        super.onPause();
        stopPolling();
        unwatchWiFi();
    }

    @Override
    protected void onDestroy() {
        if (pad != null) pad.shutdown();
        if (thumbs != null) thumbs.shutdown();
        super.onDestroy();
    }

    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        if (shell == null) return;
        buildShell();
    }

    // MARK: Вікно

    /// Скласти вікно наново: під поворот, розмір, масштаб і мову.
    private void buildShell() {
        Ui.init(this);
        if (pad != null) pad.shutdown();
        shell = new Shell(this, this);
        shell.tab(R.drawable.ic_slides, getString(R.string.tab_show));
        shell.tab(R.drawable.ic_bible, getString(R.string.tab_bible));
        shell.tab(R.drawable.ic_song, Lang.t("Пісні", "Songs"));
        shell.tab(R.drawable.ic_plan, getString(R.string.tab_plan));

        blackTile = Ui.tool(this, R.drawable.ic_black, Lang.t("Чорний екран", "Black screen"), () -> send("black"));
        Ui.explain(blackTile, Lang.t("Затемнити зал повністю; ще раз — повернути", "Black out the hall; once more brings it back"));
        TextView photoTile = Ui.tool(this, R.drawable.ic_image, Lang.t("Фото", "Photos"), this::pickPhotos);
        Ui.explain(photoTile, Lang.t("Фото з галереї телефона — у список показу: до двадцяти за раз, перше вибране; у зал — «Показати»",
                                     "Photos from the phone gallery to the show list: up to twenty at once, the first is chosen; “Show” puts it in the hall"));
        TextView fileTile = Ui.tool(this, R.drawable.ic_upload, Lang.t("Файл", "File"), this::pickFile);
        Ui.explain(fileTile, Lang.t("Надіслати в програму PDF, PowerPoint чи картинку з телефона", "Send a PDF, PowerPoint or picture from the phone to Slovo"));
        TextView pointerTile = Ui.tool(this, R.drawable.ic_pointer, getString(R.string.pointer_title), () -> SettingsPage.pointer(this, this::settingsChanged));
        Ui.explain(pointerTile, Lang.t("Колір, розмір і яскравість указки — на телефоні й у залі", "Pointer colour, size and brightness — on the phone and in the hall"));
        setContentView(shell.build(getString(R.string.app_name), new TextView[] {blackTile, photoTile, fileTile, pointerTile}));

        pageCard = new SlideCard(this, shell.stack);
        pageCard.picture();
        liveCard = new SlideCard(this, shell.stack);
        nextCard = new SlideCard(this, shell.stack);
        pad = new HallPad(this, this, pageCard.image, pageCard.pointer);
        zoomBack = SlideCard.zoomBack(this, pad::resetZoom);
        pageCard.corner(zoomBack, Gravity.TOP | Gravity.START);
        pad.onChange = () -> zoomBack.setVisibility(pad.zoomed() ? View.VISIBLE : View.GONE);

        panels = new View[] { buildShow(), bible.build(), buildSongs(), buildPlan() };
        showSignature = "";
        planSignature = "";
        shownKey = "";
        shell.status(link, linkColor);
        pageBitmap = null;
        selectTab(tab);
        render();
    }

    private int linkColor = Ui.DIM;

    private void linkState(String text, int color) {
        link = text;
        linkColor = color;
        if (shell != null) shell.status(text, color);
    }

    private void say(String text) {
        if (shell != null) shell.note(text);
    }

    @Override
    public void onTab(int index) { selectTab(Tab.values()[index]); }

    @Override
    public void onSettings() { SettingsPage.show(this, this); }

    @Override
    public void onStatus() {
        Ui.menu(this, describeServer(), settings.host() + ":" + settings.port() + "\n" + link,
            new String[] { Ui.plain(getString(R.string.menu_connection)).replace("…", ""), getString(R.string.rescan) }, which -> {
                if (which == 0) {
                    startActivity(new Intent(this, ConnectActivity.class));
                    finish();
                } else {
                    searchedAt = 0;
                    say(getString(R.string.searching));
                    new Thread(this::rediscover, "slovo-find").start();
                }
            });
    }

    @Override
    public void onPrev() { send("prev"); }

    @Override
    public void onNext() { send("next"); }

    /// «Показати»: на Біблії з вибраними віршами — саме їх; інакше — те, що в передпоказі програми.
    @Override
    public void onShow() {
        if (tab == Tab.BIBLE && bible.hasPicked()) bible.showPicked();
        else send("show");
    }

    @Override
    public void onHide() { send("hide"); }

    // MARK: Налаштування (сторінка `SettingsPage`)

    @Override
    public void settingsChanged() {
        applyAwake();
        if (pad != null) pad.look();
    }

    @Override
    public void resetZoom() {
        if (pad != null) pad.resetZoom();
    }

    @Override
    public String linkState() { return link; }

    @Override
    public void openSermon() { }

    // MARK: HallPad.Host

    @Override
    public Api api() { return api; }

    @Override
    public State state() { return state; }

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

    // MARK: Клавіші

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
        // Інакше система все одно покаже повзунок гучності на відпускання.
        if (settings != null && settings.volumeKeys()
            && (code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP)) {
            return true;
        }
        return super.onKeyUp(code, event);
    }

    @Override
    public void onBackPressed() {
        if (tab == Tab.BIBLE && bible.back()) return;
        if (tab == Tab.SONG && !songListing) {
            songListing = true;
            renderSongs();
            return;
        }
        super.onBackPressed();
    }

    // MARK: Команди

    private void send(String command) {
        Api current = api;
        if (current == null) return;
        // Разом із командою — розділ, з якого натиснули. На «Слайдах»
        // «Показати», «Далі» й «Назад» стосуються презентації, хоч би що стояло
        // на компʼютері. Власник: після Біблії й пісень «Показати» виводило
        // останній показаний слайд, а не завантажену презентацію, і її
        // доводилося надсилати наново. «Слово» до 1.3.9 це поле пропускає.
        final JSONObject body = new JSONObject();
        try { body.put("tab", tab.name().toLowerCase(Locale.ROOT)); } catch (org.json.JSONException ignored) { }
        commands.execute(() -> {
            try {
                current.command(command, body);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    /// Вибрати без показу (див. `Api.choose`): у зал — кнопкою «Показати».
    private void choose(String command, int index) {
        Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.choose(command, index);
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

    /// Команда не вдалася. «Немає зв'язку» — лише коли програма вже кілька
    /// секунд не відповідає нічим; якщо інші запити щойно пройшли, зв'язок є, а
    /// загубилася одна команда — так і кажемо.
    private void showFailure(Exception error) {
        final Api current = api;
        main.post(() -> {
            if (error instanceof Api.PinRejected) {
                linkTrouble = true;
                online = false;
                linkState(Lang.t("Потрібен PIN", "PIN required"), Ui.LIVE);
                if (shell != null) shell.note(getString(R.string.status_pin), true);
            } else if (current != null && current.silentFor() < 5000) {
                say(Lang.t("Команда не дійшла до «Слова» — натисніть ще раз", "The command did not reach Slovo — press it again"));
            } else {
                linkTrouble = true;
                online = false;
                linkState(Lang.t("Немає зв'язку", "No connection"), Ui.LIVE);
                if (shell != null) shell.note(getString(R.string.status_lost, describeServer()), true);
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
                    // картинка на телефоні від стану тоді не залежить (пляму
                    // малює палець) — питаємо не частіше трьох разів на секунду.
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
                    // Прив'язка до Wi-Fi могла застаріти (мережу перепідключили,
                    // а система не сказала): після трьох невдач підряд — звичайною
                    // дорогою; нова прив'язка прийде з наступним onAvailable.
                    if (failures == 3 && current.isBound()) current.useNetwork(null);
                    // «Немає зв'язку» — коли НІЧОГО не відповідало 5 с: якщо указка чи
                    // команди тим часом доходять, зв'язок є, а опит просто повториться.
                    if (failures >= 2 && current.silentFor() > 5000) {
                        final String why = Api.describe(error);
                        main.post(() -> {
                            linkTrouble = true;
                            online = false;
                            linkState(Lang.t("Немає зв'язку", "No connection"), Ui.LIVE);
                            if (shell != null) shell.note(getString(R.string.status_lost, describeServer()) + " (" + why + ")", true);
                        });
                    }
                    // Власник: «на короткое время иногда находит слово, но
                    // вскоре связь пропадает и не подключается снова».
                    // Записана адреса могла застаріти — комп'ютер отримав
                    // іншу від роутера. Після кількох невдач шукаємо «Слово»
                    // заново й самі переходимо на живу адресу.
                    if ((failures == 4 || failures % 12 == 0) && current.silentFor() > 8000) rediscover();
                    // Пауза росте до п'яти секунд: не довбати вимкнений
                    // комп'ютер, але й підхопити його одразу, як увімкнуть.
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
        final List<String[]> hits = new ArrayList<>();
        final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        final Discovery search = new Discovery(this, new Discovery.Listener() {
            @Override
            public void found(String name, String host, int port) {
                hits.add(new String[] { name, host, String.valueOf(port) });
            }

            @Override
            public void finished() { done.countDown(); }
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
            linkState(getString(R.string.status_connecting, host), Ui.WARN);
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
        linkState(name + (modeName.isEmpty() ? "" : " · " + modeName), Ui.GREEN);
        if (linkTrouble) {
            linkTrouble = false;
            say("");
        }
        if (!online) {
            online = true;
            if (tab == Tab.BIBLE) bible.open();
            if (tab == Tab.SONG) loadSongs();
            if (tab == Tab.SHOW) loadPictures();
        }
        // Фото додали чи прибрали (тут, з планшета чи на комп'ютері) — список перечитати.
        boolean pictureMode = "pictures".equals(fresh.mode);
        // Новіше «Слово» каже про список фото завжди: прибрали фото з іншого пульта чи на
        // комп'ютері, поки програма на презентації, — перечитати (27.11 тут лишалися прибрані).
        boolean picturesChanged = !fresh.pictures.isEmpty() && !fresh.pictures.equals(lastPictures);
        if (picturesChanged) lastPictures = fresh.pictures;
        boolean modeChanged = !fresh.mode.equals(lastMode) || (pictureMode && fresh.showCount != lastShowCount);
        if (modeChanged) {
            lastMode = fresh.mode;
            lastShowCount = pictureMode ? fresh.showCount : lastShowCount;
        }
        if (picturesChanged && tab == Tab.SHOW) {
            loadPictures();
        } else if (modeChanged) {
            if (pictureMode || !picturesLoaded) loadPictures();
        } else if (!picturesLoaded && tab == Tab.SHOW && System.currentTimeMillis() - picturesAskedAt > 10_000) {
            // Перший запит не дійшов (на перевантаженому комп'ютері список фото лишався порожнім) — ще раз.
            loadPictures();
        }
        render();
    }

    /// Намалювати все зі стану: картки, плитки, списки.
    private void render() {
        if (shell == null) return;
        State s = state;
        Ui.toolState(blackTile, Lang.t("Чорний екран", "Black screen"), s.black, Ui.LIVE);
        shell.hideBtn.setAlpha(s.live ? 1f : 0.55f);

        // Зал: текст того, що на стіні.
        boolean onAir = s.live && !s.black;
        String liveName;
        if (s.black) {
            liveCard.text("", "", getString(R.string.black_on));
            liveName = getString(R.string.black_on);
        } else if (!s.live || (s.liveText.isEmpty() && s.liveReference.isEmpty())) {
            liveName = s.showTitle.isEmpty() ? getString(R.string.live_empty) : s.showTitle;
            liveCard.text("", "", liveName);
        } else {
            liveCard.text(s.liveReference, s.liveText, "");
            liveName = s.liveReference.isEmpty() ? firstWords(s.liveText) : s.liveReference;
        }
        liveCard.border(onAir ? Ui.LIVE : Ui.CARD3);
        liveCard.pill(s.black ? Lang.t("Чорний", "Black") : Lang.t("Зал", "Hall"), onAir ? Ui.LIVE : 0xFF4A5568);
        liveCard.title(liveName);

        // Далі: передпоказ програми.
        boolean hasNext = !s.previewText.isEmpty() || !s.previewReference.isEmpty();
        String nextName = !hasNext ? Lang.t("виберіть, що показати", "pick what to show")
            : s.previewReference.isEmpty() ? firstWords(s.previewText) : s.previewReference;
        nextCard.text(s.previewReference, s.previewText, nextName);
        nextCard.border(hasNext ? Ui.WARN : Ui.CARD3);
        nextCard.pill(Lang.t("Далі", "Next"), Ui.WARN);
        nextCard.title(nextName);
        shell.strip((s.black ? Lang.t("Чорний екран", "Black screen") : Lang.t("Зал", "Hall")) + ": " + liveName, onAir,
                    Lang.t("Далі", "Next") + ": " + (hasNext ? nextName : "—"));

        refreshPage(s, false);
        pad.show();
        pad.syncPointer();
        // Вірш перемкнули на комп'ютері — підсвічення в пульті йде слідом.
        if (tab == Tab.BIBLE) bible.follow(s.biblePosition, s.bibleChapter, s.bibleVerses);
        renderShow();
        if (tab == Tab.SONG && !songListing) renderSongs();
        renderPlan();
    }

    private static String firstWords(String text) {
        String flat = text.replace('\n', ' ').trim();
        return flat.length() > 48 ? flat.substring(0, 48) + "…" : flat;
    }

    // MARK: Розділи

    private void selectTab(Tab chosen) {
        tab = chosen;
        if (chosen == Tab.SHOW) shell.cards(pageCard); else shell.cards(nextCard, liveCard);
        shell.open(chosen.ordinal(), panels[chosen.ordinal()]);
        if (chosen == Tab.SONG) loadSongs();
        if (chosen == Tab.BIBLE) bible.open();
        if (chosen == Tab.SHOW) {
            loadPictures();
            refreshPage(state, true);
        }
    }

    // MARK: Слайди

    private View buildShow() {
        // Власник: «кнопка должна быть очистить список (полностью)» — видно одразу, без
        // меню: зверху списку, поки в ньому щось є.
        LinearLayout column = Ui.col(this);
        LinearLayout bar = Ui.row(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(14), Ui.dp(6), Ui.dp(10), Ui.dp(6));
        showSummary = Ui.label(this, "", 13, Ui.DIM);
        showSummary.setMaxLines(1);
        showSummary.setEllipsize(android.text.TextUtils.TruncateAt.END);
        bar.addView(showSummary, Ui.lp(0, Ui.WRAP, 1));
        TextView clearAll = Ui.chip(this, R.drawable.ic_delete, Lang.t("Очистити весь список", "Clear the whole list"), this::clearShow);
        clearAll.setContentDescription(Lang.t("Очистити весь список", "Clear the whole list"));
        Ui.explain(clearAll, Lang.t("Прибрати з «Слова» всі файли презентацій і всі фото — з питанням",
                                    "Remove every presentation file and photo from Slovo — asks first"));
        bar.addView(clearAll, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        bar.setVisibility(View.GONE);
        showBar = bar;
        column.addView(bar, Ui.lp(Ui.FILL, Ui.WRAP, 0));
        FrameLayout box = new FrameLayout(this);
        showList = Ui.list(this, showLines);
        Lines.wire(showList, showLines);
        box.addView(showList, Ui.fill());
        showEmpty = Ui.empty(this, R.drawable.ic_slides, Lang.t("Нічого не відкрито", "Nothing is open"),
            Lang.t("Надішліть із телефона PDF, PowerPoint чи фото — плитками «Файл» і «Фото» — або відкрийте презентацію в програмі на комп'ютері.",
                   "Send a PDF, PowerPoint or photos from the phone — the “File” and “Photos” tiles — or open a presentation in Slovo on the computer."),
            Lang.t("Завантажити файл…", "Upload a file…"), this::pickFile);
        box.addView(showEmpty, Ui.fill());
        column.addView(box, Ui.lp(Ui.FILL, 0, 1));
        return column;
    }

    /// Фото — список вкладки «Зображення» програми.
    private void loadPictures() {
        final Api current = api;
        if (current == null) return;
        picturesAskedAt = System.currentTimeMillis();
        commands.execute(() -> {
            try {
                JSONObject json = current.get("/api/pictures");
                JSONArray all = json.optJSONArray("pages");
                final List<State.Row> fresh = new ArrayList<>();
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject page = all.optJSONObject(i);
                        if (page == null) continue;
                        // Номер фото — у підписі рядка (він же його місце в програмі).
                        fresh.add(new State.Row(page.optString("title", ""), String.valueOf(page.optInt("index", i)), false));
                    }
                }
                main.post(() -> {
                    picturesLoaded = true;
                    pictures.clear();
                    pictures.addAll(fresh);
                    renderShow();
                });
            } catch (Exception ignored) {
                // Старе «Слово» без списку картинок — фото просто не показуємо.
            }
        });
    }

    /// Список розділу: фото й файли презентацій, у кожної сторінки й фото —
    /// мініатюра. Те, що зараз вибрано в програмі (фото чи презентація), — згори.
    private void renderShow() {
        if (showList == null) return;
        boolean pictureMode = "pictures".equals(state.mode);
        List<Lines.Line> photos = new ArrayList<>();
        if (!pictures.isEmpty()) {
            photos.add(Lines.Line.head(Lang.t("Фото", "Photos") + " · " + pictures.size()).menu(this::photosMenu));
            for (int i = 0; i < pictures.size(); i++) {
                State.Row picture = pictures.get(i);
                int index;
                try { index = Integer.parseInt(picture.subtitle); } catch (NumberFormatException wrong) { index = i; }
                final int at = index;
                final String title = name(picture.title);
                boolean current = pictureMode && state.showIndex == at;
                photos.add(Lines.Line.of(String.valueOf(i + 1), title, "", current, () -> choose("picture", at))
                    .thumb(Thumbs.picture(at, picture.title)).menu(() -> photoMenu(at, title)));
            }
        }
        List<Lines.Line> decks = new ArrayList<>();
        for (int i = 0; i < state.decks.size(); i++) {
            final int deckIndex = i;
            State.Row deck = state.decks.get(i);
            int count = 0;
            try { count = Integer.parseInt(deck.subtitle); } catch (NumberFormatException ignored) { }
            final String deckTitle = deck.title;
            decks.add(new Lines.Line(null, deck.title, getString(R.string.deck_pages, count), false, deck.current, false,
                () -> send("deck", deckIndex)).menu(() -> deckMenu(deckIndex, deckTitle)));
            if (!deck.current) continue;
            for (int j = 0; j < state.pages.size(); j++) {
                State.Row page = state.pages.get(j);
                final int pageIndex = state.pageIndexes.get(j);
                String title = page.title.isEmpty() ? getString(R.string.page_of, j + 1, state.pages.size()) : page.title;
                decks.add(Lines.Line.of(String.valueOf(j + 1), title, "", page.current && !pictureMode,
                    () -> showPage(pageIndex)).thumb(Thumbs.page(pageIndex, deck.title + "/" + page.title)));
            }
        }
        // Заголовок файлів — з «⋮»: додати файл чи очистити лише презентації.
        if (!decks.isEmpty()) {
            decks.add(0, Lines.Line.head(Lang.t("Презентації", "Presentations") + " · " + state.decks.size()).menu(this::decksMenu));
        }
        List<Lines.Line> rows = new ArrayList<>();
        if (pictureMode) {
            rows.addAll(photos);
            rows.addAll(decks);
        } else {
            rows.addAll(decks);
            rows.addAll(photos);
        }
        if (showBar != null) {
            showBar.setVisibility(rows.isEmpty() ? View.GONE : View.VISIBLE);
            showSummary.setText(Lang.showSummary(state.decks.size(), pictures.size()));
        }
        String signature = Lines.signature(rows);
        if (signature.equals(showSignature)) return;
        boolean moved = !rows.isEmpty() && showLines.current() != findCurrent(rows);
        showSignature = signature;
        showLines.set(rows);
        showEmpty.setVisibility(rows.isEmpty() ? View.VISIBLE : View.GONE);
        showList.setVisibility(rows.isEmpty() ? View.GONE : View.VISIBLE);
        // Вибране змінилося — підвести список до нього (стрілками з комп'ютера, з телефона «Далі»).
        int at = showLines.current();
        if (moved && at >= 0) showList.post(() -> showList.smoothScrollToPositionFromTop(Math.max(0, at), Ui.dp(40), 180));
    }

    /// «⋮» біля фото. Власник: «фото добавлены, а удалить из списка их нельзя. Нужно
    /// добавить с правого края списка от фото меню с тремя вертикальными точками».
    /// У зал — лише «Показати» (власник: «показ … исключительно по кнопке показа»), тож
    /// окремого «Показати в залі» в меню немає: дотик по фото вибирає, кнопка — показує.
    private void photoMenu(int index, String title) {
        Ui.menu(this, title, new String[] {
            Lang.t("Прибрати зі списку", "Remove from the list"),
        }, which -> editPhotos("picture-remove", index, Lang.t("Прибрано: ", "Removed: ") + title));
    }

    /// «⋮» біля заголовка «Фото»: додати ще чи очистити весь список (з питанням —
    /// на служінні випадковий дотик не має стерти підготовлені фото).
    private void photosMenu() {
        Ui.menu(this, Lang.t("Фото", "Photos") + " · " + pictures.size(), new String[] {
            Lang.t("Додати фото з телефона…", "Add photos from the phone…"),
            Lang.t("Очистити список фото", "Clear the photo list"),
        }, which -> {
            if (which == 0) {
                pickPhotos();
                return;
            }
            Ui.confirm(this, Lang.t("Очистити список фото?", "Clear the photo list?"),
                Lang.t("З «Слова» приберуться всі фото (" + pictures.size() + "). Самі файли на комп'ютері лишаються. Якщо фото зараз у залі — зал згасне.",
                       "All photos (" + pictures.size() + ") are removed from Slovo. The files stay on the computer. If a photo is in the hall now, the hall goes dark."),
                Lang.t("Очистити", "Clear"),
                () -> editPhotos("pictures-clear", -1, Lang.t("Список фото очищено", "The photo list is cleared")));
        });
    }

    /// «⋮» біля файла презентації (PDF, PowerPoint, Keynote…). Власник: «документ pdf
    /// pptx и другие тоже должны иметь опции для удаления из списка».
    private void deckMenu(int index, String title) {
        Ui.menu(this, title, new String[] {
            Lang.t("Відкрити сторінки", "Open the pages"),
            Lang.t("Прибрати зі списку", "Remove from the list"),
        }, which -> {
            if (which == 0) send("deck", index);
            else editShow(index, Lang.t("Прибрано: ", "Removed: ") + title, "deck-remove");
        });
    }

    /// «⋮» біля заголовка «Презентації»: надіслати ще файл чи прибрати всі файли.
    private void decksMenu() {
        int count = state.decks.size();
        Ui.menu(this, Lang.t("Презентації", "Presentations") + " · " + count, new String[] {
            Lang.t("Завантажити файл…", "Upload a file…"),
            Lang.t("Очистити список презентацій", "Clear the presentation list"),
        }, which -> {
            if (which == 0) {
                pickFile();
                return;
            }
            Ui.confirm(this, Lang.t("Очистити список презентацій?", "Clear the presentation list?"),
                Lang.t("З «Слова» приберуться всі файли презентацій (" + count + "). Фото лишаються, самі файли на комп'ютері — теж. Якщо сторінка зараз у залі — зал згасне.",
                       "All presentation files (" + count + ") are removed from Slovo. Photos stay, and so do the files on the computer. If a page is in the hall now, the hall goes dark."),
                Lang.t("Очистити", "Clear"),
                () -> editShow(-1, Lang.t("Список презентацій очищено", "The presentation list is cleared"), "decks-clear"));
        });
    }

    /// Кнопка «Очистити весь список»: і файли, і фото — з питанням, бо на служінні
    /// випадковий дотик не має стерти підготовлене.
    private void clearShow() {
        int decks = state.decks.size(), photos = pictures.size();
        if (decks == 0 && photos == 0) return;
        List<String> what = new ArrayList<>();
        if (decks > 0) what.add("decks-clear");
        if (photos > 0) what.add("pictures-clear");
        Ui.confirm(this, Lang.t("Очистити весь список?", "Clear the whole list?"),
            Lang.t("З «Слова» прибереться все відкрите: " + Lang.showSummary(decks, photos) + ". Самі файли на комп'ютері лишаються. Якщо щось із цього зараз у залі — зал згасне.",
                   "Everything open is removed from Slovo: " + Lang.showSummary(decks, photos) + ". The files stay on the computer. If any of it is in the hall now, the hall goes dark."),
            Lang.t("Очистити все", "Clear all"),
            () -> editShow(-1, Lang.t("Список очищено", "The list is cleared"), what.toArray(new String[0])));
    }

    private void editPhotos(String command, int index, String done) { editShow(index, done, command); }

    /// Прибрати фото чи файл, очистити список — і перечитати список. Старе «Слово» таких
    /// команд не знає («немає такої команди») — так і кажемо, а не «немає зв'язку».
    private void editShow(int index, String done, String... list) {
        final Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            String doing = "";
            try {
                for (String command : list) {
                    doing = command;
                    if (index >= 0) current.command(command, index); else current.command(command, new JSONObject());
                }
                main.post(() -> {
                    say(done);
                    loadPictures();
                });
            } catch (Exception error) {
                String why = error.getMessage() == null ? "" : error.getMessage();
                final boolean old = !doing.isEmpty() && why.contains(doing);
                main.post(() -> {
                    loadPictures();
                    if (old) {
                        Ui.info(this, Lang.t("Потрібне новіше «Слово»", "A newer Slovo is needed"),
                            Lang.t("Прибирати фото й файли з пульта вміє «Слово» 1.4.4 і новіше. Оновіть програму на комп'ютері — або приберіть їх там: вкладки «Презентація» й «Зображення», кнопка «−».",
                                   "Removing photos and files from the remote needs Slovo 1.4.4 or newer. Update Slovo on the computer — or remove them there: the “Presentation” and “Pictures” tabs, the “−” button."));
                    } else {
                        showFailure(error);
                    }
                });
            }
        });
    }

    /// Сторінку презентації вибрати (у зал — «Показати»), навіть коли програма стоїть на фото
    /// (див. `Api.presentationPage`).
    private void showPage(int index) {
        final Api current = api;
        if (current == null) return;
        commands.execute(() -> {
            try {
                current.presentationPage(index, false);
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private static int findCurrent(List<Lines.Line> rows) {
        for (int i = 0; i < rows.size(); i++) if (rows.get(i).current) return i;
        return -1;
    }

    /// Ім'я фото без розширення: «IMG_20261127_104819».
    private static String name(String file) {
        int dot = file.lastIndexOf('.');
        return dot > 0 && file.length() - dot <= 5 ? file.substring(0, dot) : file;
    }

    /// Велика картка: вибране фото, коли в програмі відкрито фото, інакше —
    /// поточна сторінка презентації; підпис «Слайд 3 з 12 — назва».
    /// Картинку просимо заново лише коли вона змінилася: вона важка.
    private void refreshPage(State fresh, boolean force) {
        boolean pictureMode = "pictures".equals(fresh.mode) && fresh.showIndex >= 0;
        boolean has = pictureMode || fresh.pageIndex >= 0;
        String caption;
        if (pictureMode) {
            caption = Lang.t("Фото ", "Photo ") + (fresh.showIndex + 1) + Lang.t(" з ", " of ") + fresh.showCount
                + (fresh.showTitle.isEmpty() ? "" : " — " + name(fresh.showTitle));
        } else if (has) {
            caption = getString(R.string.page_of, fresh.pageLocal + 1, fresh.pageCount) + (fresh.pageTitle.isEmpty() ? "" : " — " + fresh.pageTitle);
        } else {
            caption = Lang.t("нічого не відкрито", "nothing is open");
        }
        pageCard.title(caption);
        // «Зал» — лише коли в залі саме це фото: «Слово» може показувати порожнє тло чи інше.
        boolean onWall = pictureMode
            ? "still".equals(fresh.hallKind) && !fresh.black && fresh.hallTitle.equals(fresh.showTitle)
            : has && fresh.onWall;
        pageCard.pill(onWall ? Lang.t("Зал", "Hall") : pictureMode ? Lang.t("Фото", "Photo") : Lang.t("Слайд", "Slide"),
            onWall ? Ui.LIVE : has ? Ui.ACCENT : 0xFF4A5568);
        pageCard.border(onWall ? Ui.LIVE : Ui.CARD3);
        if (!has) {
            shownKey = "";
            pageBitmap = null;
            pad.set(null);
            pageCard.note(Lang.t("Нічого не відкрито", "Nothing is open"));
            return;
        }
        final String key = pictureMode ? "p:" + fresh.showIndex + ":" + fresh.showTitle : "s:" + fresh.pageIndex;
        pageCard.note(pageBitmap == null ? getString(R.string.bible_loading) : "");
        if (!force && key.equals(shownKey)) return;
        shownKey = key;
        final Api current = api;
        if (current == null) return;
        final int index = pictureMode ? fresh.showIndex : fresh.pageIndex;
        final boolean picture = pictureMode;
        images.execute(() -> {
            try {
                int width = Math.max(480, Math.min(1080, getResources().getDisplayMetrics().widthPixels));
                byte[] bytes = picture ? current.image("/api/page?kind=pictures&index=" + index + "&w=" + width)
                    : current.pageImage(index, width);
                Bitmap bitmap = bytes == null ? null : BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
                main.post(() -> {
                    if (key.equals(shownKey) && bitmap != null) {
                        pageBitmap = bitmap;
                        pageCard.note("");
                        pageCard.frame.ratio(bitmap.getWidth() / (float) Math.max(1, bitmap.getHeight()));
                        pad.set(bitmap);
                    }
                });
            } catch (Exception error) {
                main.post(() -> { if (key.equals(shownKey)) shownKey = ""; });
            }
        });
    }

    /// «Файл» — вибрати PDF, PPTX або картинку на телефоні й надіслати
    /// програмі: та відкриє її в показі.
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
            say(getString(R.string.upload_failed, error.getMessage()));
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
                main.post(() -> {
                    say(getString(R.string.uploaded, name, pages));
                    selectTab(Tab.SHOW);
                    loadPictures();
                });
            } catch (Exception error) {
                main.post(() -> say(getString(R.string.upload_failed,
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
            say(getString(R.string.photo_failed, error.getMessage()));
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
                main.post(() -> { if (shell != null) shell.note(getString(R.string.photo_sending, n, uris.size()), true); });
                try {
                    PhotoShrink.Result photo = PhotoShrink.prepare(getContentResolver(), uris.get(i), 2560);
                    JSONObject answer = current.upload(Lang.t("Фото ", "Photo ") + stamp + "-" + n + "." + photo.extension,
                                                       photo.bytes, false);
                    if (first < 0 && answer != null) first = answer.optInt("page", -1);
                    sent++;
                } catch (Exception error) {
                    final String why = error.getMessage() == null ? error.toString() : error.getMessage();
                    main.post(() -> say(getString(R.string.photo_failed, why)));
                }
            }
            if (first >= 0) {
                try { current.choose("picture", first); } catch (Exception ignored) { }
            }
            final int total = sent;
            main.post(() -> {
                if (total > 0) say(getString(R.string.photo_sent, total));
                loadPictures();
                if (tab != Tab.SHOW) selectTab(Tab.SHOW);
            });
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

    // MARK: Пісні

    private View buildSongs() {
        LinearLayout root = Ui.col(this);
        LinearLayout top = Ui.row(this);
        top.setPadding(Ui.dp(8), Ui.dp(2), Ui.dp(8), 0);
        songBack = Ui.button(this, R.drawable.ic_left, Lang.t("Пісні", "Songs"), Ui.CARD2, () -> {
            songListing = true;
            renderSongs();
        });
        songBack.setMaxLines(1);
        Ui.explain(songBack, Lang.t("Назад до переліку пісень", "Back to the list of songs"));
        top.addView(songBack, Ui.lp(Ui.WRAP, Ui.dp(46), 0, 3));
        songBookButton = Ui.button(this, R.drawable.ic_song, "", Ui.CARD2, this::chooseSongBook);
        songBookButton.setMaxLines(1);
        Ui.explain(songBookButton, Lang.t("Вибрати інший пісенник", "Pick another songbook"));
        top.addView(songBookButton, Ui.lp(0, Ui.dp(46), 1, 3));
        root.addView(top);

        EditText find = Ui.search(this, Lang.t("Номер, назва або слова", "Number, title or words"));
        find.setText(songFilter);
        find.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        find.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int c) { }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int c) { }

            @Override
            public void afterTextChanged(Editable s) {
                if (s.toString().equals(songFilter)) return;
                songFilter = s.toString();
                songFound = null;
                songListing = true;
                renderSongs();
                // Номер і назву відбираємо на місці; слова з тексту пісні шукає
                // програма — питаємо її, коли пальці стали.
                main.removeCallbacks(songSearch);
                if (wantsTextSearch()) main.postDelayed(songSearch, 600);
            }
        });
        find.setOnEditorActionListener((v, action, event) -> {
            Ui.hideKeyboard(find);
            main.removeCallbacks(songSearch);
            if (wantsTextSearch()) searchSongs();
            return true;
        });
        LinearLayout findRow = Ui.row(this);
        findRow.setPadding(Ui.dp(8), 0, Ui.dp(8), Ui.dp(2));
        findRow.addView(find, Ui.lp(0, Ui.dp(46), 1, 3));
        root.addView(findRow);

        songNote = Ui.hint(this, "");
        songNote.setVisibility(View.GONE);
        root.addView(songNote);
        songList = Ui.list(this, songLines);
        Lines.wire(songList, songLines);
        root.addView(songList, Ui.lp(Ui.FILL, 0, 1));
        renderSongs();
        return root;
    }

    private boolean wantsTextSearch() {
        String needle = songFilter.trim();
        if (needle.length() < 3) return false;
        for (int i = 0; i < needle.length(); i++) if (!Character.isDigit(needle.charAt(i))) return true;
        return false;
    }

    /// Список пісень відкритого пісенника — з програми. Власник: «иметь
    /// возможность выбора песен с песенника».
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
                final List<Lines.Line> rows = new ArrayList<>();
                int selected = list.optInt("selected", -1);
                if (songs != null) {
                    for (int i = 0; i < songs.length(); i++) {
                        JSONObject song = songs.optJSONObject(i);
                        if (song == null) continue;
                        final int index = song.optInt("index", i);
                        String name = song.optString("title", "");
                        String note = song.optString("subtitle", "");
                        // Підпис, що повторює назву, — зайвий рядок: у пісень
                        // перший рядок куплета часто і є назвою.
                        if (note.startsWith(name) || name.startsWith(note)) note = "";
                        rows.add(new Lines.Line(String.valueOf(song.optInt("number", index + 1)), name, note, index == selected, false, false,
                            () -> openSong(index)));
                    }
                }
                main.post(() -> {
                    songsLoaded = true;
                    songBookTitle = title;
                    songAll.clear();
                    songAll.addAll(rows);
                    renderSongs();
                });
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void openSong(int index) {
        send("song", index);
        songListing = false;
        renderSongs();
    }

    /// Пошук у назвах і текстах пісень — веде програма.
    private void searchSongs() {
        final String text = songFilter.trim();
        final Api current = api;
        if (current == null || text.isEmpty()) return;
        commands.execute(() -> {
            try {
                JSONArray songs = current.searchSongs(text);
                List<Lines.Line> rows = new ArrayList<>();
                for (int i = 0; i < songs.length(); i++) {
                    JSONObject song = songs.optJSONObject(i);
                    if (song == null) continue;
                    final int index = song.optInt("index", -1);
                    rows.add(new Lines.Line(null, song.optString("title", ""), song.optString("subtitle", ""), false, false, false,
                        () -> openSong(index)));
                }
                main.post(() -> {
                    if (!text.equals(songFilter.trim())) return;
                    songFound = rows;
                    if (songListing) renderSongs();
                });
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    private void renderSongs() {
        if (songList == null) return;
        Ui.setText(songBookButton, songBookTitle.isEmpty() ? Lang.t("Пісенник", "Songbook") : songBookTitle);
        songBack.setVisibility(songListing ? View.GONE : View.VISIBLE);
        List<Lines.Line> rows = new ArrayList<>();
        String note = "";
        if (!songListing) {
            // Частини вибраної пісні: першим рядком — її назва, щоб було видно, чию частину гортаємо.
            if (!state.songTitle.isEmpty()) rows.add(new Lines.Line(null, state.songTitle, "", false, false, true, null));
            for (int i = 0; i < state.parts.size(); i++) {
                final int index = i;
                State.Row part = state.parts.get(i);
                // Однакові види частин («Куплет», «Куплет») — з номером, інакше
                // їх не відрізнити; де номер уже в назві, лишаємо як є.
                int same = 0, before = 0;
                for (int k = 0; k < state.parts.size(); k++) {
                    if (state.parts.get(k).title.equals(part.title)) { same++; if (k <= i) before++; }
                }
                String name = part.title.isEmpty() ? part.subtitle : same > 1 ? part.title + " " + before : part.title;
                rows.add(new Lines.Line(String.valueOf(i + 1), name,
                    part.title.isEmpty() ? "" : part.subtitle, part.current, false, false, () -> choose("part", index)));
            }
            if (state.parts.isEmpty()) note = getString(R.string.song_empty);
        } else {
            String needle = songFilter.trim().toLowerCase(Locale.ROOT);
            boolean number = !needle.isEmpty();
            for (int i = 0; i < needle.length() && number; i++) number = Character.isDigit(needle.charAt(i));
            for (Lines.Line line : songAll) {
                if (!needle.isEmpty()) {
                    if (number ? !line.badge.startsWith(needle) : !line.title.toLowerCase(Locale.ROOT).contains(needle)) continue;
                }
                rows.add(line);
            }
            if (songFound != null && !number) {
                // Те, що знайшла програма (і в текстах), — після знайденого за назвою, без повторів.
                List<Lines.Line> extra = new ArrayList<>();
                for (Lines.Line found : songFound) {
                    boolean seen = false;
                    for (Lines.Line line : rows) if (line.title.equals(found.title)) { seen = true; break; }
                    if (!seen) extra.add(found);
                }
                if (!extra.isEmpty()) {
                    rows.add(new Lines.Line(null, Lang.t("Знайдено в текстах", "Found in the lyrics"), "", false, false, true, null));
                    rows.addAll(extra);
                }
            }
            if (rows.isEmpty()) {
                note = !songsLoaded ? getString(R.string.bible_loading)
                    : songAll.isEmpty() ? getString(R.string.song_list_empty) : getString(R.string.search_empty);
            }
        }
        // Перелік змінився цілком (пісні ↔ частини) — список стає на початок, без підсвітки
        // від дотику, що лишалась на першому рядку.
        if (shownListing != songListing) {
            shownListing = songListing;
            songList.setAdapter(songLines);
        }
        songLines.set(rows);
        songNote.setText(note);
        songNote.setVisibility(note.isEmpty() ? View.GONE : View.VISIBLE);
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
                int at = -1;
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject book = all.optJSONObject(i);
                        if (book == null) continue;
                        if (book.optString("id").equals(books.optString("current", ""))) at = ids.size();
                        ids.add(book.optString("id"));
                        titles.add(book.optString("title", book.optString("short", "")));
                    }
                }
                final int checked = at;
                main.post(() -> {
                    if (ids.isEmpty() || isFinishing()) return;
                    // Останній рядок — загальна база «Слова»: поставити в програму ще пісенники.
                    List<String> shown = new ArrayList<>(titles);
                    shown.add(Lang.t("＋ Завантажити ще пісенники…", "＋ Download more songbooks…"));
                    Ui.pick(RemoteActivity.this, getString(R.string.song_pick_book), shown.toArray(new String[0]), checked, which -> {
                        if (which == titles.size()) {
                            ResourcesActivity.open(RemoteActivity.this, "songbook");
                            return;
                        }
                        commands.execute(() -> {
                            try {
                                current.command("songs-book", ids.get(which));
                            } catch (Exception ignored) { }
                            main.post(() -> {
                                songListing = true;
                                songFound = null;
                                loadSongs();
                            });
                        });
                    });
                });
            } catch (Exception error) {
                showFailure(error);
            }
        });
    }

    // MARK: План

    private View buildPlan() {
        FrameLayout box = new FrameLayout(this);
        planList = Ui.list(this, planLines);
        Lines.wire(planList, planLines);
        box.addView(planList, Ui.fill());
        planEmpty = Ui.empty(this, R.drawable.ic_plan, getString(R.string.plan_empty),
            Lang.t("План служіння складають у «Слові» на комп'ютері — тут він з'явиться сам. Дотик по пункту виводить його в зал.",
                   "The service plan is made in Slovo on the computer — it appears here by itself. A tap on an item sends it to the hall."),
            null, null);
        box.addView(planEmpty, Ui.fill());
        return box;
    }

    private void renderPlan() {
        if (planList == null) return;
        List<Lines.Line> rows = new ArrayList<>();
        for (int i = 0; i < state.plan.size(); i++) {
            final int index = i;
            State.Row item = state.plan.get(i);
            rows.add(new Lines.Line(String.valueOf(i + 1), item.title, item.subtitle, item.current, false, false, () -> choose("plan", index)));
        }
        String signature = Lines.signature(rows);
        if (signature.equals(planSignature)) return;
        planSignature = signature;
        planLines.set(rows);
        planEmpty.setVisibility(rows.isEmpty() ? View.VISIBLE : View.GONE);
        planList.setVisibility(rows.isEmpty() ? View.GONE : View.VISIBLE);
    }
}
