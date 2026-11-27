package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;

/// Стенд: перевірка програми без дотиків, командами з комп'ютера.
///
/// Діє лише тоді, коли на пристрої ввімкнено налагодження USB — на звичайному
/// телефоні в залі ці команди ніхто не прийме. Потрібен, бо `adb input text`
/// на емуляторі губить крапки в адресі, а вкладки простіше перемикати словом:
///
///   adb shell am start -n ua.church.slovo.remote/.RemoteActivity \
///       --es host 10.0.2.2 --ei port 8199 --es tab bible
final class Stand {

    private Stand() { }

    static boolean on(Context c) {
        try {
            return android.provider.Settings.Global.getInt(c.getContentResolver(), android.provider.Settings.Global.ADB_ENABLED, 0) == 1;
        } catch (Exception error) {
            return false;
        }
    }

    /// Адреса «Слова» з команди запуску: `--es host … [--ei port …] [--es pin …]`.
    static void connect(Activity a, Intent intent) {
        if (intent == null || !on(a)) return;
        String host = intent.getStringExtra("host");
        if (host == null || host.isEmpty()) return;
        String pin = intent.getStringExtra("pin");
        new Settings(a).save(host, intent.getIntExtra("port", 8103), pin == null ? "" : pin, "");
        intent.removeExtra("host");
    }

    /// Розділ із команди запуску (`--es tab songs`); `null` — не просили.
    static String tab(Activity a, Intent intent) {
        if (intent == null || !on(a)) return null;
        String tab = intent.getStringExtra("tab");
        if (tab != null) intent.removeExtra("tab");
        return tab;
    }

    /// Інше слово з команди запуску (`--es open settings`).
    static String word(Activity a, Intent intent, String key) {
        if (intent == null || !on(a)) return null;
        String value = intent.getStringExtra(key);
        if (value != null) intent.removeExtra(key);
        return value;
    }
}
