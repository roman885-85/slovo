package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Context;
import android.content.res.Configuration;
import android.content.res.Resources;

import java.util.Locale;

/// Мова інтерфейсу пульта й планшета: українська чи англійська.
///
/// Власник: «В программах пульта, веб и планшета добавить переключаемый
/// английский интерфейс»; «если текущая локализация не русская и не
/// украинская, то выставлять язык по умолчанию английский». Рядки лежать у
/// ресурсах: `values` — англійська (для будь-якої іншої мови пристрою),
/// `values-uk` і `values-ru` — українська. Вибір у меню («Мова / Language»)
/// переважає мову пристрою і живе в налаштуваннях.
final class Lang {

    static final String AUTO = "auto", UK = "uk", EN = "en";
    private static final String KEY = "language";
    private static volatile boolean english;

    private Lang() { }

    /// Чи йде зараз інтерфейс англійською — для рядків, складених у коді.
    static boolean english() { return english; }

    /// Рядок, складений у коді: українською чи англійською.
    static String t(String uk, String en) { return english ? en : uk; }

    /// Що відкрито в показі: «2 файли · 5 фото» / «2 files · 5 photos». Порожнє — не пишемо.
    static String showSummary(int decks, int photos) {
        java.util.List<String> parts = new java.util.ArrayList<>();
        if (decks > 0) parts.add(english ? decks + (decks == 1 ? " file" : " files") : decks + " " + files(decks));
        if (photos > 0) parts.add(photos + (english ? (photos == 1 ? " photo" : " photos") : " фото"));
        return android.text.TextUtils.join(" · ", parts);
    }

    /// 1 файл, 2 файли, 5 файлів, 11 файлів, 21 файл.
    private static String files(int n) {
        int last = n % 10, lastTwo = n % 100;
        if (last == 1 && lastTwo != 11) return "файл";
        if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) return "файли";
        return "файлів";
    }

    static String choice(Context context) {
        return context.getSharedPreferences("slovo-remote", Context.MODE_PRIVATE).getString(KEY, AUTO);
    }

    /// Мова, коли людина нічого не вибирала: мова пристрою українська чи
    /// російська — українська, будь-яка інша — англійська.
    @SuppressWarnings("deprecation")
    static String deviceDefault() {
        Locale device = Resources.getSystem().getConfiguration().locale;
        String code = device == null ? "" : device.getLanguage();
        return "uk".equals(code) || "ru".equals(code) ? UK : EN;
    }

    static String effective(Context context) {
        String pick = choice(context);
        return UK.equals(pick) || EN.equals(pick) ? pick : deviceDefault();
    }

    /// Налаштування для `applyOverrideConfiguration` у `attachBaseContext`:
    /// до `extra` (масштаб планшета) додає мову.
    static Configuration override(Context base, Configuration extra) {
        String code = effective(base);
        english = EN.equals(code);
        Configuration change = extra != null ? extra : new Configuration();
        Locale locale = UK.equals(code) ? new Locale("uk", "UA") : Locale.ENGLISH;
        change.setLocale(locale);
        Locale.setDefault(locale);
        return change;
    }

    /// Вікно вибору мови. Назва двомовна — її знайде і той, хто не читає
    /// поточною мовою. `before` (може бути `null`) виконується перед тим, як
    /// вікно перебудується: закрити сторінку налаштувань, що лежить поверх.
    static void showChooser(Activity activity, Runnable before) {
        String[] titles = {"Авто / Auto", "Українська", "English"};
        String[] codes = {AUTO, UK, EN};
        String current = choice(activity);
        int checked = 0;
        for (int i = 0; i < codes.length; i++) if (codes[i].equals(current)) checked = i;
        Ui.pick(activity, "Мова / Language", titles, checked, which -> {
            if (codes[which].equals(current)) return;
            activity.getSharedPreferences("slovo-remote", Context.MODE_PRIVATE)
                .edit().putString(KEY, codes[which]).apply();
            if (before != null) before.run();
            activity.recreate();
        });
    }

    static void showChooser(Activity activity) { showChooser(activity, null); }

    /// Назва вибраної мови — для рядка в налаштуваннях.
    static String choiceName(Context context) {
        String pick = choice(context);
        return UK.equals(pick) ? "Українська" : EN.equals(pick) ? "English" : "Авто / Auto";
    }
}
