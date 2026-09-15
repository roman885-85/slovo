package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
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

    /// Вікно вибору мови. Назва пункту меню двомовна — її знайде і той, хто
    /// не читає поточною мовою.
    static void showChooser(Activity activity) {
        String[] titles = {"Авто / Auto", "Українська", "English"};
        String[] codes = {AUTO, UK, EN};
        String current = choice(activity);
        int checked = 0;
        for (int i = 0; i < codes.length; i++) if (codes[i].equals(current)) checked = i;
        new AlertDialog.Builder(activity)
            .setTitle("Мова / Language")
            .setSingleChoiceItems(titles, checked, (dialog, which) -> {
                dialog.dismiss();
                if (codes[which].equals(current)) return;
                activity.getSharedPreferences("slovo-remote", Context.MODE_PRIVATE)
                    .edit().putString(KEY, codes[which]).apply();
                activity.recreate();
            })
            .show();
    }
}
