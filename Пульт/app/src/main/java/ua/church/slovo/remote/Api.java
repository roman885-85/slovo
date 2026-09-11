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

/// Разговор с программой по её каналу пульта: HTTP и JSON, ничего сверх.
///
/// `HttpURLConnection`, а не сторонняя библиотека: запросов два вида, и
/// тащить ради них мегабайты чужого кода незачем. Каждый запрос — своё
/// соединение с `Connection: close`: Android любит подсовывать залежавшийся
/// сокет из запаса, и первый запрос после паузы тогда молча падает.
final class Api {

    /// Сервер отверг PIN — отдельная ошибка, чтобы пульт сказал об этом
    /// словами, а не «нет связи».
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

    Api(String host, int port, String pin) {
        this.base = "http://" + host.trim() + ":" + port;
        this.pin = pin == null ? "" : pin;
    }

    void useNetwork(Network network) { this.network = network; }

    /// Чи прив'язані запити до мережі Wi-Fi.
    boolean isBound() { return network != null; }

    /// Причина обриву — словами для рядка стану. Власник: «андроид программа
    /// постоянно теряет связь с программой»; «немає зв'язку» без причини не
    /// каже, де шукати — у програмі, у мережі чи в телефоні.
    static String describe(Exception error) {
        if (error instanceof java.net.SocketTimeoutException) return "програма не відповіла вчасно";
        if (error instanceof java.net.NoRouteToHostException) return "немає шляху до комп'ютера — інша мережа?";
        if (error instanceof java.net.UnknownHostException) return "адресу не знайдено";
        if (error instanceof java.net.ConnectException) return "з'єднання відхилено — «Слово» закрите чи пульт вимкнено";
        String message = error.getMessage();
        return message == null || message.isEmpty() ? error.getClass().getSimpleName() : message;
    }

    String base() { return base; }

    /// Состояние программы. `since` — номер уже виденного состояния: сервер
    /// держит ответ, пока не появится новое (долгий опрос), поэтому таймаут
    /// чтения длиннее, чем время удержания на сервере.
    State state(long since) throws IOException {
        JSONObject json = request("GET", "/api/state?since=" + since, null, 40_000);
        return State.from(json);
    }

    /// Команда без тела: `next`, `prev`, `show`, `hide`, `black`…
    void command(String name) throws IOException {
        request("POST", "/api/" + name, new JSONObject(), 8_000);
    }

    /// Команда с числом: пункт плана, часть песни, страница показа.
    void command(String name, int index) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("index", index); } catch (JSONException ignored) { }
        request("POST", "/api/" + name, body, 8_000);
    }

    /// Команда со строкой: место Писания.
    void command(String name, String text) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("text", text); } catch (JSONException ignored) { }
        request("POST", "/api/" + name, body, 8_000);
    }

    /// Поиск песен по слову: строки «номер. название».
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
        request("POST", "/api/pointer", body, 5_000);
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
        request("POST", "/api/zoom", body, 8_000);
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
        HttpURLConnection connection = open("GET", path, 20_000);
        try {
            int code = connection.getResponseCode();
            if (code == 401 || code == 403) throw new PinRejected();
            if (code == 404) return null;
            if (code >= 400) throw new IOException("HTTP " + code);
            try (InputStream stream = connection.getInputStream()) { return readBytes(stream); }
        } finally {
            connection.disconnect();
        }
    }

    void pointerOff() throws IOException {
        request("POST", "/api/pointer-off", new JSONObject(), 5_000);
    }

    /// Картинка страницы показа — JPEG заданной ширины.
    byte[] pageImage(int index, int width) throws IOException {
        HttpURLConnection connection = open("GET", "/api/page?index=" + index + "&w=" + width, 20_000);
        try {
            int code = connection.getResponseCode();
            if (code == 401 || code == 403) throw new PinRejected();
            if (code >= 400) throw new IOException("HTTP " + code);
            try (InputStream stream = connection.getInputStream()) { return readBytes(stream); }
        } finally {
            connection.disconnect();
        }
    }

    /// Файл с телефона — программе: та откроет его в показе. Ответ — имя,
    /// число страниц и номер колоды.
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
                // Крупный файл шлём кусками: одним куском поток буферизует всё
                // и на слабом телефоне падает по памяти.
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

    private JSONObject request(String method, String path, JSONObject body, int readTimeout) throws IOException {
        HttpURLConnection connection = open(method, path, readTimeout);
        try {
            if (body != null) {
                byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setFixedLengthStreamingMode(bytes.length);
                try (OutputStream out = connection.getOutputStream()) { out.write(bytes); }
            }
            return finish(connection);
        } finally {
            connection.disconnect();
        }
    }

    private HttpURLConnection open(String method, String path, int readTimeout) throws IOException {
        URL url = new URL(base + path);
        Network bound = network;
        HttpURLConnection connection = (HttpURLConnection)
            (bound == null ? url.openConnection() : bound.openConnection(url));
        connection.setRequestMethod(method);
        // Коротший строк з'єднання: якщо шлях усе-таки не той, помилка має
        // прийти швидко, а не тримати команду чотири секунди.
        connection.setConnectTimeout(2_500);
        connection.setReadTimeout(readTimeout);
        connection.setRequestProperty("Connection", "close");
        connection.setRequestProperty("Accept", "application/json");
        if (!pin.isEmpty()) connection.setRequestProperty("X-Slovo-Pin", pin);
        return connection;
    }

    /// Прочитать ответ JSON; ошибки сервера — словами из его же ответа.
    private JSONObject finish(HttpURLConnection connection) throws IOException {
        int code = connection.getResponseCode();
        if (code == 401 || code == 403) throw new PinRejected();
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
        return out.toByteArray();
    }

    private static String read(InputStream stream) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int count;
        while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
        return out.toString("UTF-8");
    }
}
