package ua.church.slovo.remote;

import android.content.Context;
import android.content.SharedPreferences;

/// Налаштування пульта: адреса програми, порт, PIN і звички оператора.
///
/// Нічого з цього не вшито в збірку: адреса комп'ютера в церкві міняється з
/// роутером, і пульт має переживати це правкою одного поля, а не
/// перезбиранням. Усе, що оператор вибрав у меню, лежить тут же і
/// переживає перезапуск пульта; «Скинути налаштування» повертає звички до
/// початкових, не чіпаючи підключення.
final class Settings {

    private static final String FILE = "slovo-remote";

    /// Початковий вигляд указки — той самий, що в програмі: жовта пляма в
    /// 14 % висоти кадру. Колір — ARGB.
    static final int DEFAULT_POINTER_COLOUR = 0xFFFFD91A;
    static final float DEFAULT_POINTER_SIZE = 0.14f;
    static final float MIN_POINTER_SIZE = 0.03f;
    static final float MAX_POINTER_SIZE = 0.60f;
    /// Яскравість плями — непрозорість заливки. Початкове значення те саме,
    /// що в програмі.
    static final float DEFAULT_POINTER_OPACITY = 0.45f;
    static final float MIN_POINTER_OPACITY = 0.05f;
    static final float MAX_POINTER_OPACITY = 1.00f;
    /// Як програма називає джерело указки з пульта у своєму стані.
    static final String POINTER_SOURCE_PHONE = "телефон";

    private final SharedPreferences store;

    Settings(Context context) {
        store = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    String host() { return store.getString("host", ""); }
    int port() { return store.getInt("port", 8103); }
    String pin() { return store.getString("pin", ""); }
    String name() { return store.getString("name", ""); }

    /// Клавіші гучності гортають слайди: пульт у кишені або в руці без
    /// погляду на екран — так зручніше, ніж цілитися в кнопку.
    boolean volumeKeys() { return store.getBoolean("volumeKeys", true); }
    /// «Плюс гортає назад». На частині телефонів кнопки стоять так, що
    /// звичне «плюс — далі» виходить навпаки; перемикач міняє напрямок обох
    /// клавіш, а не змушує звикати.
    boolean volumeReversed() { return store.getBoolean("volumeReversed", false); }
    /// Не гасити екран, поки пульт відкритий: інакше телефон засинає посеред
    /// проповіді, а розблокування — це кілька секунд і зайві рухи.
    boolean keepAwake() { return store.getBoolean("keepAwake", true); }

    /// Колір плями указки (ARGB) і її розмір — частка висоти слайда, як у
    /// програмі. Те, що вибрано тут, летить у програму з кожною точкою: пляма
    /// в залі і на телефоні одна й та сама.
    int pointerColour() { return store.getInt("pointerColour", DEFAULT_POINTER_COLOUR); }
    float pointerSize() {
        float size = store.getFloat("pointerSize", DEFAULT_POINTER_SIZE);
        return Math.max(MIN_POINTER_SIZE, Math.min(MAX_POINTER_SIZE, size));
    }
    /// Яскравість плями: 0,05…1. Летить у програму разом із кольором і
    /// розміром — власник просив крутити її з телефона, а не лише в
    /// «Параметри → Слайд → Указка».
    float pointerOpacity() {
        float value = store.getFloat("pointerOpacity", DEFAULT_POINTER_OPACITY);
        return Math.max(MIN_POINTER_OPACITY, Math.min(MAX_POINTER_OPACITY, value));
    }

    /// Колір у записі програми — «#RRGGBB».
    String pointerColourHex() { return String.format("#%06X", pointerColour() & 0xFFFFFF); }

    boolean hasHost() { return !host().isEmpty(); }

    void save(String host, int port, String pin, String name) {
        store.edit()
            .putString("host", host.trim())
            .putInt("port", port)
            .putString("pin", pin.trim())
            .putString("name", name == null ? "" : name)
            .apply();
    }

    void setVolumeKeys(boolean on) { store.edit().putBoolean("volumeKeys", on).apply(); }
    void setVolumeReversed(boolean on) { store.edit().putBoolean("volumeReversed", on).apply(); }
    void setKeepAwake(boolean on) { store.edit().putBoolean("keepAwake", on).apply(); }
    void setPointer(int colour, float size, float opacity) {
        store.edit()
            .putInt("pointerColour", colour | 0xFF000000)
            .putFloat("pointerSize", size)
            .putFloat("pointerOpacity", opacity)
            .apply();
    }

    /// Повернути звички до початкових. Підключення (адреса, порт, PIN, ім'я)
    /// лишається: його вводили руками, і скидання не має виганяти оператора
    /// на екран пошуку програми посеред служіння.
    void resetPreferences() {
        store.edit()
            .remove("volumeKeys")
            .remove("volumeReversed")
            .remove("keepAwake")
            .remove("pointerColour")
            .remove("pointerSize")
            .remove("pointerOpacity")
            .apply();
    }
}
