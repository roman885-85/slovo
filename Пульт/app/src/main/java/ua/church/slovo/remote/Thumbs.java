package ua.church.slovo.remote;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;

import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Мініатюри сторінок показу й фото для списків пульта.
///
/// Власник: «фото должны отображаться в списке как и страницы презентации (но
/// с миниатюрами, миниатюры сделай и для слайдов)». Картинку малює сама
/// програма (`/api/page?…&w=…`); тут — черга й пам'ять.
///
/// По одній за раз і лише для рядків, які видно: список на 56 сторінок не
/// має засипати Wi-Fi і програму запитами, поки людина веде указку. Ключ —
/// адреса плюс назва сторінки після `#`: змінився файл — інша назва, і
/// мініатюра береться наново.
final class Thumbs {

    interface Source { Api api(); }

    private static final int KEEP = 160;

    private final Source source;
    private final Runnable loaded;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService work = Executors.newSingleThreadExecutor();
    private final LinkedHashMap<String, Bitmap> cache = new LinkedHashMap<String, Bitmap>(64, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<String, Bitmap> eldest) { return size() > KEEP; }
    };
    private final Set<String> loading = new HashSet<>();
    /// Що не вдалося і коли: пробуємо знову не раніше ніж за 10 с.
    private final Map<String, Long> failed = new HashMap<>();

    /// `loaded` — нова мініатюра прийшла (головний потік): перемалювати список.
    Thumbs(Source source, Runnable loaded) {
        this.source = source;
        this.loaded = loaded;
    }

    /// Мініатюра за ключем або `null` — тоді її вже питають, а список перемалюється, щойно прийде.
    Bitmap get(String key) {
        if (key == null) return null;
        Bitmap ready = cache.get(key);
        if (ready != null) return ready;
        if (loading.contains(key)) return null;
        Long when = failed.get(key);
        if (when != null && System.currentTimeMillis() - when < 10_000) return null;
        Api api = source.api();
        if (api == null) return null;
        loading.add(key);
        final String path = key.contains("#") ? key.substring(0, key.indexOf('#')) : key;
        work.execute(() -> {
            Bitmap bitmap = null;
            try {
                byte[] bytes = api.image(path);
                if (bytes != null) bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            } catch (Exception ignored) { }
            final Bitmap got = bitmap;
            main.post(() -> {
                loading.remove(key);
                if (got == null) {
                    failed.put(key, System.currentTimeMillis());
                    return;
                }
                failed.remove(key);
                cache.put(key, got);
                if (loaded != null) loaded.run();
            });
        });
        return null;
    }

    /// Адреса мініатюри сторінки презентації (наскрізний номер) чи фото.
    static String page(int index, String title) {
        return "/api/page?index=" + index + "&w=280#" + title;
    }

    static String picture(int index, String title) {
        return "/api/page?kind=pictures&index=" + index + "&w=280#" + title;
    }

    void shutdown() { work.shutdownNow(); }
}
