package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.Reader;
import java.net.HttpURLConnection;
import java.net.URL;

/// Оновлення самої програми з релізів GitHub — так само, як це робить «Слово».
///
/// Власник: «программы не обновляются автоматически». Пульт і планшет ставлять
/// не з Google Play, тож ніхто їх не оновлює: досі нову версію треба було
/// ставити руками за QR-кодом. Тепер програма сама раз на добу питає
/// `releases/latest` того самого репозиторію, що й «Слово», і, якщо там
/// свіжіший файл (`Pult-Slova-2.2.apk` для телефона, `Planshet-Slova-1.8.apk`
/// для планшета), пропонує оновитися: завантажує файл у свою теку й віддає
/// його встановлювачу Android.
///
/// Чому саме так: без Google Play інших шляхів немає, а INSTALL_PACKAGES —
/// лише для системних програм. Android щоразу показує своє вікно згоди, і
/// вперше просить дозволити встановлення з цієї програми — це нормально й
/// про це сказано в підказці.
final class Updates {

    private static final String LATEST = "https://api.github.com/repos/roman885-85/slovo/releases/latest";
    private static final String STORE = "updates";
    private static final String LAST_CHECK = "lastCheck", SKIPPED = "skipped";
    /// Раз на добу: частіше — марно смикати мережу на служінні.
    private static final long DAY = 24L * 60 * 60 * 1000;

    private Updates() { }

    /// Тиха перевірка при запуску: мовчить, поки немає нової версії.
    static void checkQuietly(Activity activity) {
        SharedPreferences store = activity.getSharedPreferences(STORE, Context.MODE_PRIVATE);
        if (System.currentTimeMillis() - store.getLong(LAST_CHECK, 0) < DAY) return;
        check(activity, false);
    }

    /// Перевірка з меню: каже і тоді, коли все свіже або мережі немає.
    static void checkNow(Activity activity) {
        check(activity, true);
    }

    private static void check(Activity activity, boolean loud) {
        final Context context = activity.getApplicationContext();
        new Thread(() -> {
            Found found;
            try {
                found = ask(context);
            } catch (Exception error) {
                if (loud) say(activity, activity.getString(R.string.update_no_answer));
                return;
            }
            activity.getSharedPreferences(STORE, Context.MODE_PRIVATE)
                    .edit().putLong(LAST_CHECK, System.currentTimeMillis()).apply();
            if (found == null) {
                if (loud) say(activity, activity.getString(R.string.update_latest, ours(context)));
                return;
            }
            String skipped = activity.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString(SKIPPED, "");
            if (!loud && found.version.equals(skipped)) return;
            final Found offer = found;
            new Handler(Looper.getMainLooper()).post(() -> propose(activity, offer));
        }, "updates").start();
    }

    /// Нова версія в релізі: номер, ім'я файла й адреса.
    private static final class Found {
        final String version, name, url;
        final long size;
        Found(String version, String name, String url, long size) {
            this.version = version; this.name = name; this.url = url; this.size = size;
        }
    }

    private static Found ask(Context context) throws Exception {
        HttpURLConnection link = (HttpURLConnection) new URL(LATEST).openConnection();
        link.setRequestProperty("Accept", "application/vnd.github+json");
        link.setConnectTimeout(15000);
        link.setReadTimeout(20000);
        StringBuilder body = new StringBuilder();
        try (Reader reader = new InputStreamReader(link.getInputStream(), "UTF-8")) {
            char[] chunk = new char[8192];
            int read;
            while ((read = reader.read(chunk)) > 0) body.append(chunk, 0, read);
        } finally {
            link.disconnect();
        }
        JSONArray assets = new JSONObject(body.toString()).optJSONArray("assets");
        if (assets == null) return null;
        String prefix = context.getString(R.string.update_asset);
        String ours = ours(context);
        for (int i = 0; i < assets.length(); i++) {
            JSONObject asset = assets.optJSONObject(i);
            if (asset == null) continue;
            String name = asset.optString("name", "");
            if (!name.startsWith(prefix) || !name.endsWith(".apk")) continue;
            String version = name.substring(prefix.length(), name.length() - 4);
            if (!isNewer(version, ours)) return null;
            return new Found(version, name, asset.optString("browser_download_url", ""), asset.optLong("size", 0));
        }
        return null;
    }

    static String ours(Context context) {
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            return info.versionName == null ? "0" : info.versionName;
        } catch (Exception error) {
            return "0";
        }
    }

    /// Версії тут десяткові, як у «Слова»: 1.7 → 1.8 → 2.0, а 2.10 новіше за 2.9.
    static boolean isNewer(String a, String b) {
        String[] left = a.split("\\."), right = b.split("\\.");
        for (int i = 0; i < Math.max(left.length, right.length); i++) {
            int l = number(i < left.length ? left[i] : "0");
            int r = number(i < right.length ? right[i] : "0");
            if (l != r) return l > r;
        }
        return false;
    }

    private static int number(String text) {
        StringBuilder digits = new StringBuilder();
        for (int i = 0; i < text.length(); i++) {
            char sign = text.charAt(i);
            if (sign >= '0' && sign <= '9') digits.append(sign); else break;
        }
        return digits.length() == 0 ? 0 : Integer.parseInt(digits.toString());
    }

    private static void propose(Activity activity, Found found) {
        if (activity.isFinishing()) return;
        String size = found.size > 0 ? " (" + Math.max(1, found.size / (1024 * 1024)) + " " + activity.getString(R.string.update_mb) + ")" : "";
        new AlertDialog.Builder(activity)
                .setTitle(activity.getString(R.string.update_title, found.version))
                .setMessage(activity.getString(R.string.update_message, ours(activity), found.version) + size
                        + "\n\n" + activity.getString(R.string.update_android_note))
                .setPositiveButton(R.string.update_do, (dialog, which) -> download(activity, found))
                .setNegativeButton(R.string.update_later, (dialog, which) ->
                        activity.getSharedPreferences(STORE, Context.MODE_PRIVATE)
                                .edit().putString(SKIPPED, found.version).apply())
                .show();
    }

    private static void download(Activity activity, Found found) {
        final AlertDialog waiting = new AlertDialog.Builder(activity)
                .setTitle(R.string.update_downloading)
                .setMessage(activity.getString(R.string.update_wait))
                .setCancelable(false)
                .show();
        new Thread(() -> {
            File file = null;
            String failure = null;
            try {
                File folder = new File(activity.getFilesDir(), "update");
                if (!folder.exists() && !folder.mkdirs()) throw new Exception("mkdir");
                for (File old : folder.listFiles() == null ? new File[0] : folder.listFiles()) old.delete();
                file = new File(folder, found.name);
                HttpURLConnection link = (HttpURLConnection) new URL(found.url).openConnection();
                link.setInstanceFollowRedirects(true);
                link.setConnectTimeout(20000);
                link.setReadTimeout(120000);
                try (InputStream from = link.getInputStream(); FileOutputStream to = new FileOutputStream(file)) {
                    byte[] chunk = new byte[64 * 1024];
                    int read;
                    while ((read = from.read(chunk)) > 0) to.write(chunk, 0, read);
                } finally {
                    link.disconnect();
                }
                if (file.length() < 10_000) throw new Exception("порожній файл");
            } catch (Exception error) {
                failure = error.getMessage() == null ? error.toString() : error.getMessage();
                file = null;
            }
            final File ready = file;
            final String said = failure;
            new Handler(Looper.getMainLooper()).post(() -> {
                try { waiting.dismiss(); } catch (Exception ignored) { }
                if (ready == null) {
                    say(activity, activity.getString(R.string.update_failed, String.valueOf(said)));
                    return;
                }
                install(activity, ready);
            });
        }, "update-download").start();
    }

    /// Віддати файл встановлювачу Android. З Android 8 програма спершу мусить
    /// дістати дозвіл «встановлення невідомих застосунків» — просимо його
    /// один раз і пояснюємо словами, а не залишаємо людину з мовчазним екраном.
    private static void install(Activity activity, File file) {
        if (Build.VERSION.SDK_INT >= 26 && !activity.getPackageManager().canRequestPackageInstalls()) {
            new AlertDialog.Builder(activity)
                    .setTitle(R.string.update_permission_title)
                    .setMessage(R.string.update_permission_text)
                    .setPositiveButton(R.string.update_permission_go, (dialog, which) -> {
                        try {
                            activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                                              Uri.parse("package:" + activity.getPackageName())));
                        } catch (Exception error) {
                            say(activity, activity.getString(R.string.update_failed, String.valueOf(error.getMessage())));
                        }
                    })
                    .setNegativeButton(R.string.update_later, null)
                    .show();
            return;
        }
        try {
            Uri where = Build.VERSION.SDK_INT >= 24
                    ? ApkProvider.uriFor(activity, file)
                    : Uri.fromFile(file);
            Intent install = new Intent(Intent.ACTION_VIEW);
            install.setDataAndType(where, "application/vnd.android.package-archive");
            install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(install);
        } catch (Exception error) {
            say(activity, activity.getString(R.string.update_failed, String.valueOf(error.getMessage())));
        }
    }

    private static void say(Activity activity, String text) {
        new Handler(Looper.getMainLooper()).post(() -> {
            if (!activity.isFinishing()) Toast.makeText(activity, text, Toast.LENGTH_LONG).show();
        });
    }
}
