package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.util.DisplayMetrics;

/// Масштаб інтерфейсу й положення екрана — спільні для пульта й планшета,
/// за зразком «Слова» для Android: щоб програмою було однаково зручно
/// користуватися на телефоні й планшеті з будь-якою щільністю та роздільністю.
///
/// «Авто» дивиться на сам пристрій:
///  • вузький екран (менше 350 dp — маленькі телефони, великий системний
///    масштаб) — зменшуємо, щоб усі кнопки вмістилися в ряд;
///  • пристрій завбільшки з планшет, який Android через малу роздільність
///    вважає телефоном (1280×720, 1024×600), — зменшуємо, щоб увімкнулась
///    розкладка планшета. Власник: «при 720 план почти схлопывается и его не
///    видно почти, сделать масштабирование настраиваемым»;
///  • решта — як є.
/// Якщо «Авто» вгадало погано, масштаб вибирається вручну у відсотках
/// («Налаштування» → «Масштаб інтерфейсу») — це та сама щільність (dpi), лише
/// для однієї нашої програми.
final class UiScale {

    private UiScale() { }

    /// Що можна вибрати; 0 — «Авто».
    static final float[] CHOICES = {0f, 0.6f, 0.7f, 0.8f, 0.9f, 1f, 1.15f, 1.3f, 1.5f, 1.75f, 2f};
    /// Системний «великий шрифт» понад це не множимо: у програми є свій масштаб, а ряди кнопок розсипаються.
    private static final float MAX_FONT = 1.3f;

    /// Скільки брати зараз: вибране людиною або «Авто».
    static float effective(Context base) {
        float chosen = new Settings(base).uiScale();
        return chosen > 0 ? chosen : auto(base);
    }

    /// «Авто». Пристрій завбільшки з планшет — так каже сам Android (екран
    /// «large» і більший) або фізичний розмір короткої сторони (його частина
    /// дешевих планшетів повідомляє невірно, тому планшет вірить уже 3,1″, а
    /// пульт для телефона — лише 4,3″: великий телефон не має стати «планшетом»).
    static float auto(Context base) {
        Resources res = base.getApplicationContext().getResources();
        Configuration config = res.getConfiguration();
        DisplayMetrics metrics = res.getDisplayMetrics();
        float shortInches = Math.min(metrics.widthPixels / Math.max(1f, metrics.xdpi), metrics.heightPixels / Math.max(1f, metrics.ydpi));
        int sw = config.smallestScreenWidthDp;
        if (sw <= 0) return 1f;
        boolean large = (config.screenLayout & Configuration.SCREENLAYOUT_SIZE_MASK) >= Configuration.SCREENLAYOUT_SIZE_LARGE;
        float edge = tabletApp(base) ? 3.1f : 4.3f;
        if ((large || shortInches >= edge) && sw < 640) return Math.max(0.6f, sw / 640f);
        if (sw < 350) return Math.max(0.7f, sw / 360f);
        return 1f;
    }

    /// Чи це «Планшет Слова» (а не пульт для телефона): у нього свої звички
    /// щодо масштабу й положення екрана.
    static boolean tabletApp(Context c) {
        return c.getApplicationContext().getResources().getBoolean(R.bool.tablet_app);
    }

    /// Щільність, з якою зараз малюється програма, dpi.
    static int dpi(Context base) {
        return Math.round(base.getApplicationContext().getResources().getConfiguration().densityDpi * effective(base));
    }

    /// Поправка до конфігурації вікна: щільність, розміри в dp і стеля для
    /// системного масштабу шрифту. `null` — нічого міняти не треба.
    static Configuration override(Context base) {
        float scale = effective(base);
        Configuration current = base.getResources().getConfiguration();
        boolean sameScale = Math.abs(scale - 1f) < 0.01f;
        if (sameScale && current.fontScale <= MAX_FONT) return null;
        Configuration change = new Configuration();
        change.fontScale = Math.min(current.fontScale, MAX_FONT);
        if (!sameScale) {
            change.densityDpi = Math.round(current.densityDpi * scale);
            change.smallestScreenWidthDp = Math.round(current.smallestScreenWidthDp / scale);
            change.screenWidthDp = Math.round(current.screenWidthDp / scale);
            change.screenHeightDp = Math.round(current.screenHeightDp / scale);
        }
        return change;
    }

    /// Підпис варіанта масштабу: «Авто (зараз 84 %, 180 dpi)» або «115 % · 245 dpi».
    static String label(Context c, float value) {
        int system = c.getApplicationContext().getResources().getConfiguration().densityDpi;
        if (value <= 0) {
            float auto = auto(c);
            return Lang.t("Авто", "Auto") + " (" + Math.round(auto * 100) + " %, " + Math.round(system * auto) + " dpi)";
        }
        return Math.round(value * 100) + " % · " + Math.round(system * value) + " dpi";
    }

    // MARK: Положення екрана

    /// Варіанти: 0 — типово, 1 — вертикально, 2 — горизонтально, 3 — за датчиком.
    ///
    /// «Типово» в планшета — як було завжди: планшет лежить горизонтально, а на
    /// телефоні програма стоїть вертикально, і ніщо не перевертається (власник:
    /// «программа должна быть железно зафиксирована в ориентации и не
    /// переворачиваться»). У пульта «типово» — як тримають телефон.
    static String[] orientationNames(Context c) {
        boolean tablet = tabletApp(c);
        return new String[] {
            tablet ? Lang.t("Типово: планшет — горизонтально, телефон — вертикально", "Default: tablet — landscape, phone — portrait")
                   : Lang.t("Як тримаю пристрій", "As I hold the device"),
            Lang.t("Лише вертикально", "Portrait only"),
            Lang.t("Лише горизонтально", "Landscape only"),
            Lang.t("За датчиком — перевертається сама", "By sensor — rotates itself"),
        };
    }

    static void applyOrientation(Activity a) {
        int pick = new Settings(a).orientation();
        boolean tablet = tabletApp(a);
        boolean phone = a.getResources().getConfiguration().smallestScreenWidthDp < 600;
        int wanted;
        switch (pick) {
            case 1: wanted = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT; break;
            case 2: wanted = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE; break;
            case 3: wanted = ActivityInfo.SCREEN_ORIENTATION_FULL_USER; break;
            default:
                wanted = !tablet ? ActivityInfo.SCREEN_ORIENTATION_USER
                    : phone ? ActivityInfo.SCREEN_ORIENTATION_PORTRAIT : ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE;
                break;
        }
        if (a.getRequestedOrientation() != wanted) a.setRequestedOrientation(wanted);
    }
}
