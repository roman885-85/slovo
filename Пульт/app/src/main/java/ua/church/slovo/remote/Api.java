package ua.church.slovo.remote;

import android.net.Network;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.List;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

/// Розмова з програмою її каналом пульта: HTTP і JSON, нічого понад це.
///
/// `HttpURLConnection`, а не стороння бібліотека: запитів два види, і
/// тягти заради них мегабайти чужого коду нема чого. Кожен запит — своє
/// з'єднання з `Connection: close`: Android любить підсовувати залежаний
/// сокет із запасу, і перший запит після паузи тоді мовчки падає.
final class Api {

    /// Сервер відхилив PIN — окрема помилка, щоб пульт сказав про це
    /// словами, а не «немає зв'язку».
    static final class PinRejected extends IOException {
        PinRejected() { super("PIN"); }
    }

    private final String base;
    private final String pin;
    /// Мережа, якою ходити до програми, — саме Wi-Fi.
    ///
    /// Без цього запити йдуть «мережею за умовчанням». Коли телефон вважає
    /// домашній Wi-Fi мережею без інтернету, за умовчанням у нього стоїть
    /// мобільний зв'язок: запит на 192.168.x.x іде в стільниковий канал,
    /// довго не доходить, і лише другою спробою — по Wi-Fi. Саме це власник
    /// бачив як «пульт периодически подвисает на командах, выполняет их, но
    /// часто с сильной задержкой».
    private volatile Network network;

    /// Коли востаннє прийшла відповідь — будь-яка: стан, команда, указка, картинка.
    /// Власник: «постоянные обрывы связи при использовании указки и зума». Опит
    /// стану інколи не встигав, хоча указка в ту ж секунду доходила десятками —
    /// і пульт кричав «Немає зв'язку». Тепер обрив — лише коли НІЧОГО не
    /// відповідало кілька секунд (див. `silentFor`).
    private volatile long lastOk = System.currentTimeMillis();

    Api(String host, int port, String pin) {
        this.base = "http://" + host.trim() + ":" + port;
        this.pin = pin == null ? "" : pin;
    }

    void useNetwork(Network network) { this.network = network; }

    /// Чи прив'язані запити до мережі Wi-Fi.
    boolean isBound() { return network != null; }

    /// Скільки мілісекунд програма вже нічого не відповідала.
    long silentFor() { return System.currentTimeMillis() - lastOk; }

    // MARK: Лічильники (стенд)

    static final String TAG = "SlovoNet";
    private static final java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong> meter =
        new java.util.concurrent.ConcurrentHashMap<>();

    private static void count(String key, long amount) {
        java.util.concurrent.atomic.AtomicLong value = meter.get(key);
        if (value == null) {
            meter.putIfAbsent(key, new java.util.concurrent.atomic.AtomicLong());
            value = meter.get(key);
        }
        value.addAndGet(amount);
    }

    /// Рід запиту для лічильника.
    private static String kind(String path) {
        if (path.startsWith("/api/pointer")) return "pointer";
        if (path.startsWith("/api/zoom")) return "zoom";
        if (path.startsWith("/api/state")) return "state";
        if (path.startsWith("/api/hall.jpg")) return "hall";
        if (path.startsWith("/api/page")) return "page";
        return "other";
    }

    /// Що набралося з минулого разу: «pointer 50 · state 6 · байт 51234 · збоїв 0» — і з нуля.
    static String meterLine() {
        StringBuilder out = new StringBuilder();
        for (String key : new String[] {"pointer", "zoom", "state", "hall", "page", "other", "bytes", "fail"}) {
            java.util.concurrent.atomic.AtomicLong value = meter.get(key);
            long n = value == null ? 0 : value.getAndSet(0);
            if (n == 0) continue;
            if (out.length() > 0) out.append(" · ");
            out.append(key).append(' ').append(n);
        }
        return out.toString();
    }

    /// Збій запиту — у журнал Android (видно в `adb logcat -s SlovoNet`).
    private static void failed(String method, String path, long started, Exception error) {
        count("fail", 1);
        android.util.Log.w(TAG, method + " " + path + " — " + (System.currentTimeMillis() - started) + " мс: " + describe(error));
    }

    /// Причина обриву — словами для рядка стану. Власник: «андроид программа
    /// постоянно теряет связь с программой»; «немає зв'язку» без причини не
    /// каже, де шукати — у програмі, у мережі чи в телефоні.
    static String describe(Exception error) {
        if (error instanceof java.net.SocketTimeoutException) return Lang.t("програма не відповіла вчасно", "the program did not answer in time");
        if (error instanceof java.net.NoRouteToHostException) return Lang.t("немає шляху до комп'ютера — інша мережа?", "no route to the computer — a different network?");
        if (error instanceof java.net.UnknownHostException) return Lang.t("адресу не знайдено", "address not found");
        if (error instanceof java.net.ConnectException) return Lang.t("з'єднання відхилено — «Слово» закрите чи пульт вимкнено", "connection refused — Slovo is closed or the remote is off");
        String message = error.getMessage();
        return message == null || message.isEmpty() ? error.getClass().getSimpleName() : message;
    }

    String base() { return base; }

    /// Стан програми. `since` — номер уже баченого стану: сервер
    /// тримає відповідь, доки не з'явиться новий (довгий опит), тому тайм-аут
    /// читання довший, ніж час утримання на сервері.
    State state(long since) throws IOException {
        // Строк з'єднання для опиту — 5 с, а не 2,5: на зайнятому Wi-Fi перший пакет
        // з'єднання губиться, і повтор системи приходить лише за секунду-три.
        JSONObject json = request("GET", "/api/state?since=" + since, null, 40_000, 5_000, false);
        return State.from(json);
    }

    /// Команда без тіла: `next`, `prev`, `show`, `hide`, `black`…
    void command(String name) throws IOException {
        request("POST", "/api/" + name, new JSONObject(), 8_000);
    }

    /// Команда з числом: пункт плану, частина пісні, сторінка показу.
    void command(String name, int index) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("index", index); } catch (JSONException ignored) { }
        request("POST", "/api/" + name, body, 8_000);
    }

    /// Сторінка презентації — у зал. Команда `page` у «Слові» бере сторінку з того
    /// списку, що відкритий у програмі: після фото там «Зображення», і `page 3` показувала
    /// фото № 3 замість сторінки PDF (власник: «после начала показа фото невозможно
    /// отобразить документ, вместо него показывается фото»). Тому спершу — вкладка
    /// «Презентація» — завжди, а не «якщо програма не на ній»: пульт дізнається про вкладку
    /// програми із запізненням, і дотик одразу після фото інакше міг піти у фото. Зайвий
    /// короткий запит дешевший за таку гонку. Працює й зі старим «Словом».
    void presentationPage(int index) throws IOException { presentationPage(index, true); }

    /// `live: false` — лише вибрати сторінку (у зал — кнопкою «Показати»).
    void presentationPage(int index, boolean live) throws IOException {
        command("mode", "presentation");
        if (live) command("page", index); else choose("page", index);
    }

    /// Вибрати без показу: сторінку, фото, частину пісні, пункт плану чи «Історії».
    /// Власник 27.11: «показ слайдов и текстов происходить должен исключительно по кнопке
    /// показа» — дотик у списку лише вибирає (у програмі — передпоказ), у зал — «Показати».
    /// «Слово» до 1.4.4 `live` не знає й показує одразу, як раніше.
    void choose(String name, int index) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("index", index);
            body.put("live", false);
        } catch (JSONException ignored) { }
        command(name, body);
    }

    /// Команда з рядком: місце Писання.
    void command(String name, String text) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("text", text); } catch (JSONException ignored) { }
        request("POST", "/api/" + name, body, 8_000);
    }

    /// Пошук пісень за словом: рядки «номер. назва».
    JSONArray searchSongs(String query) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("text", query); } catch (JSONException ignored) { }
        JSONObject json = request("POST", "/api/songs", body, 15_000);
        JSONArray songs = json == null ? null : json.optJSONArray("songs");
        return songs == null ? new JSONArray() : songs;
    }

    /// Указка на слайді: частки ширини і висоти картинки, вісь Y униз.
    /// Разом із точкою летять колір «#RRGGBB», розмір (частка висоти кадру)
    /// і яскравість із налаштувань пульта — пляма в залі така сама, як на
    /// телефоні.
    void pointer(double x, double y, String colourHex, double size, double opacity) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("x", x);
            body.put("y", y);
            body.put("colour", colourHex);
            body.put("size", size);
            body.put("opacity", opacity);
        } catch (JSONException ignored) { }
        // Без повтору: наступна точка вже в дорозі, стара нікому не потрібна.
        request("POST", "/api/pointer", body, 5_000, 2_500, false);
    }

    /// Наближення: у скільки разів і навколо якої точки показаного кадру.
    /// Кратність 1 знімає наближення зовсім.
    void zoom(double zoom, double x, double y) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("zoom", zoom);
            body.put("x", x);
            body.put("y", y);
        } catch (Exception ignored) { }
        request("POST", "/api/zoom", body, 8_000, 2_500, false);
    }

    /// Книги відкритого перекладу, список перекладів і де стоїть програма.
    JSONObject bibleBooks() throws IOException {
        return request("GET", "/api/bible/books", null, 15_000);
    }

    /// Вірші розділу. Книга — позиція у списку книг, як у `bibleBooks`.
    JSONObject bibleChapter(int book, int chapter) throws IOException {
        return request("GET", "/api/bible/chapter?book=" + book + "&chapter=" + chapter, null, 20_000);
    }

    /// Вибрати місце Писання: у передпоказ або одразу в зал.
    void bibleSelect(int book, int chapter, List<Integer> verses, boolean live) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("book", book);
            body.put("chapter", chapter);
            body.put("live", live);
            JSONArray numbers = new JSONArray();
            for (Integer verse : verses) numbers.put(verse);
            body.put("verses", numbers);
        } catch (JSONException ignored) { }
        request("POST", "/api/bible-select", body, 8_000);
    }

    /// Читання для планшета: списки й стан розділів програми.
    JSONObject get(String path) throws IOException {
        JSONObject json = request("GET", path, null, 20_000);
        return json == null ? new JSONObject() : json;
    }

    /// Команда з довільним тілом — і відповідь сервера цілком.
    JSONObject command(String name, JSONObject body) throws IOException {
        JSONObject json = request("POST", "/api/" + name, body == null ? new JSONObject() : body, 10_000);
        return json == null ? new JSONObject() : json;
    }

    /// Картинка за адресою сервера. `null` — картинки немає: у залі відео.
    byte[] image(String path) throws IOException {
        long started = System.currentTimeMillis();
        HttpURLConnection connection = open("GET", path, 20_000);
        try {
            int code = connection.getResponseCode();
            if (code == 401 || code == 403) throw new PinRejected();
            lastOk = System.currentTimeMillis();
            if (code == 404) return null;
            if (code >= 400) throw new IOException("HTTP " + code);
            try (InputStream stream = connection.getInputStream()) { return readBytes(stream); }
        } catch (IOException error) {
            if (!(error instanceof PinRejected)) failed("GET", path, started, error);
            throw error;
        } finally {
            connection.disconnect();
        }
    }

    void pointerOff() throws IOException {
        request("POST", "/api/pointer-off", new JSONObject(), 5_000, 2_500, true);
    }

    /// Картинка сторінки показу — JPEG заданої ширини.
    byte[] pageImage(int index, int width) throws IOException {
        byte[] bytes = image("/api/page?index=" + index + "&w=" + width);
        if (bytes == null) throw new IOException(Lang.t("немає такої сторінки", "no such page"));
        return bytes;
    }

    /// Файл із телефона — програмі: та відкриє його в показі. Відповідь — ім'я,
    /// кількість сторінок і номер колоди.
    JSONObject upload(String name, byte[] bytes) throws IOException {
        return upload(name, bytes, false);
    }

    /// `show` — одразу вивести в зал: так надсилається одне фото з телефона.
    JSONObject upload(String name, byte[] bytes, boolean show) throws IOException {
        String encoded = URLEncoder.encode(name, "UTF-8").replace("+", "%20");
        HttpURLConnection connection = open("POST", "/api/upload?name=" + encoded + (show ? "&show=1" : ""), 120_000);
        try {
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/octet-stream");
            connection.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream out = connection.getOutputStream()) {
                // Великий файл шлемо шматками: одним шматком потік буферизує все
                // і на слабкому телефоні падає через пам'ять.
                int offset = 0;
                while (offset < bytes.length) {
                    int chunk = Math.min(65536, bytes.length - offset);
                    out.write(bytes, offset, chunk);
                    offset += chunk;
                }
            }
            return finish(connection);
        } finally {
            connection.disconnect();
        }
    }

    /// Файл плану проповіді — лише зберегти в програмі, нічого не відкриваючи.
    /// Відповідь — ім'я, під яким файл там лежить.
    String storeFile(String name, byte[] bytes) throws IOException {
        JSONObject json = post("/api/upload?store=1&name=" + encode(name), bytes, 300_000);
        return json == null ? name : json.optString("file", name);
    }

    /// Модуль, якого в програмі немає: програма ставить його собі й вмикає.
    /// Відповідь — імена модулів, як їх тепер знає програма.
    JSONObject importModule(String name, byte[] bytes) throws IOException {
        JSONObject json = post("/api/module-import?name=" + encode(name), bytes, 300_000);
        return json == null ? new JSONObject() : json;
    }

    /// План проповіді. Програма відповідає, коли дочитає бібліотеку після
    /// імпорту модулів, — тому строк читання довгий.
    JSONObject sermonPlan(JSONObject plan) throws IOException {
        JSONObject json = request("POST", "/api/sermon-plan", plan, 90_000);
        return json == null ? new JSONObject() : json;
    }

    /// Сирі байти: переклад чи пісенник для бібліотеки планшета.
    byte[] bytes(String path) throws IOException {
        HttpURLConnection connection = open("GET", path, 180_000);
        try {
            int code = connection.getResponseCode();
            if (code == 401 || code == 403) throw new PinRejected();
            if (code >= 400) {
                InputStream error = connection.getErrorStream();
                String text = error == null ? "" : read(error);
                String reason = text;
                try { reason = new JSONObject(text).optString("error", text); } catch (JSONException ignored) { }
                throw new IOException(reason.isEmpty() ? "HTTP " + code : reason);
            }
            try (InputStream stream = connection.getInputStream()) { return readBytes(stream); }
        } finally {
            connection.disconnect();
        }
    }

    private JSONObject post(String path, byte[] bytes, int readTimeout) throws IOException {
        HttpURLConnection connection = open("POST", path, readTimeout);
        try {
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/octet-stream");
            connection.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream out = connection.getOutputStream()) {
                int offset = 0;
                while (offset < bytes.length) {
                    int chunk = Math.min(65536, bytes.length - offset);
                    out.write(bytes, offset, chunk);
                    offset += chunk;
                }
            }
            return finish(connection);
        } finally {
            connection.disconnect();
        }
    }

    private static String encode(String name) throws IOException {
        return URLEncoder.encode(name, "UTF-8").replace("+", "%20");
    }

    private JSONObject request(String method, String path, JSONObject body, int readTimeout) throws IOException {
        return request(method, path, body, readTimeout, 2_500, true);
    }

    /// Запит. `retry` — якщо не вдалося навіть з'єднатися (запит точно не дійшов
    /// до програми), ще одна спроба за чверть секунди: на Wi-Fi перший пакет
    /// з'єднання інколи губиться, і команда «Далі» пропадала зовсім. Повтор лише
    /// тоді, коли з'єднання не відбулося, — двічі одна команда не спрацює.
    private JSONObject request(String method, String path, JSONObject body, int readTimeout, int connectTimeout,
                               boolean retry) throws IOException {
        long started = System.currentTimeMillis();
        for (int attempt = 0; ; attempt++) {
            HttpURLConnection connection = open(method, path, readTimeout, connectTimeout);
            // Тіло й заголовки — ДО з'єднання: після `connect()` HttpURLConnection
            // їх не приймає («Already connected»). Збірка 27.11 11:10 ставила їх
            // після — і жодна команда з тілом не йшла до програми (власник: «не одна
            // команда не доходит до программы»).
            byte[] bytes = body == null ? null : body.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes != null) {
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setFixedLengthStreamingMode(bytes.length);
            }
            boolean connected = false;
            try {
                connection.connect();
                connected = true;
                if (bytes != null) {
                    try (OutputStream out = connection.getOutputStream()) { out.write(bytes); }
                }
                return finish(connection);
            } catch (RuntimeException broken) {
                // Помилка в самому коді запиту — не мовчати: інакше команда губиться без сліду.
                IOException error = new IOException(broken.toString(), broken);
                failed(method, path, started, error);
                throw error;
            } catch (IOException error) {
                if (!connected && retry && attempt == 0) {
                    android.util.Log.i(TAG, method + " " + path + ": не з'єдналося (" + describe(error) + ") — ще раз");
                    try { Thread.sleep(250); } catch (InterruptedException stop) { Thread.currentThread().interrupt(); throw error; }
                    continue;
                }
                if (!(error instanceof PinRejected)) failed(method, path, started, error);
                throw error;
            } finally {
                connection.disconnect();
            }
        }
    }

    private HttpURLConnection open(String method, String path, int readTimeout) throws IOException {
        return open(method, path, readTimeout, 2_500);
    }

    private HttpURLConnection open(String method, String path, int readTimeout, int connectTimeout) throws IOException {
        count(kind(path), 1);
        URL url = new URL(base + path);
        Network bound = network;
        HttpURLConnection connection = (HttpURLConnection)
            (bound == null ? url.openConnection() : bound.openConnection(url));
        connection.setRequestMethod(method);
        // Коротший строк з'єднання: якщо шлях усе-таки не той, помилка має
        // прийти швидко, а не тримати команду чотири секунди.
        connection.setConnectTimeout(connectTimeout);
        connection.setReadTimeout(readTimeout);
        connection.setRequestProperty("Connection", "close");
        connection.setRequestProperty("Accept", "application/json");
        if (!pin.isEmpty()) connection.setRequestProperty("X-Slovo-Pin", pin);
        return connection;
    }

    /// Прочитати відповідь JSON; помилки сервера — словами з його ж відповіді.
    private JSONObject finish(HttpURLConnection connection) throws IOException {
        int code = connection.getResponseCode();
        if (code == 401 || code == 403) throw new PinRejected();
        lastOk = System.currentTimeMillis();
        InputStream stream = code < 400 ? connection.getInputStream() : connection.getErrorStream();
        String text = stream == null ? "" : read(stream);
        if (code >= 400) {
            String reason = text;
            try { reason = new JSONObject(text).optString("error", text); } catch (JSONException ignored) { }
            throw new IOException(reason.isEmpty() ? "HTTP " + code : reason);
        }
        if (text.isEmpty()) return null;
        try {
            return new JSONObject(text);
        } catch (JSONException error) {
            throw new IOException("Не JSON: " + text);
        }
    }

    private static byte[] readBytes(InputStream stream) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[16384];
        int count;
        while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
        count("bytes", out.size());
        return out.toByteArray();
    }

    private static String read(InputStream stream) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int count;
        while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
        count("bytes", out.size());
        return out.toString("UTF-8");
    }
}
