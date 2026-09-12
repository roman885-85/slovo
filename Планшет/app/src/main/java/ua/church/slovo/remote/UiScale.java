package ua.church.slovo.remote;

import android.content.Context;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.util.DisplayMetrics;

/// Масштаб інтерфейсу планшета.
///
/// Власник: «сделать масштабирование планшета на устройствах с маленьким
/// разрешением (при 720 план почти схлопывается и его не видно почти),
/// сделать масштабирование настраиваемым». Екран на 1280×720 точок Android
/// вважає вузьким, як у телефона (менше 600 dp), — і планшет вмикав
/// телефонну розкладку: книжна орієнтація, усе в одну колонку, план —
/// смужкою. Менша щільність дає програмі більше «місця» на тих самих
/// точках: вмикається розкладка планшета, і план не схлопується.
final class UiScale {

    private UiScale() { }

    /// Що можна вибрати в меню; 0 — «Авто».
    static final float[] CHOICES = {0f, 0.6f, 0.7f, 0.8f, 0.9f, 1f, 1.15f, 1.3f};

    /// Скільки брати зараз: вибране людиною або «Авто».
    static float effective(Context base) {
        float chosen = new Settings(base).uiScale();
        return chosen > 0 ? chosen : auto(base);
    }

    /// «Авто»: пристрій завбільшки з планшет — так каже сам Android (екран
    /// «large» і більший) або фізичний розмір (коротша сторона від 3,1″; його
    /// частина дешевих планшетів повідомляє невірно), — а в dp він вужчий за
    /// 640: зменшуємо рівно настільки, щоб вмістилася розкладка планшета.
    /// Великі планшети й телефони — як є.
    static float auto(Context base) {
        Resources res = base.getApplicationContext().getResources();
        Configuration config = res.getConfiguration();
        DisplayMetrics metrics = res.getDisplayMetrics();
        float shortInches = Math.min(metrics.widthPixels / metrics.xdpi, metrics.heightPixels / metrics.ydpi);
        int sw = config.smallestScreenWidthDp;
        boolean large = (config.screenLayout & Configuration.SCREENLAYOUT_SIZE_MASK)
            >= Configuration.SCREENLAYOUT_SIZE_LARGE;
        if ((large || shortInches >= 3.1f) && sw > 0 && sw < 640) return Math.max(0.6f, sw / 640f);
        return 1f;
    }

    /// Поправка до конфігурації вікна: лише щільність і розміри в dp —
    /// мову, шрифт і клавіатуру лишаємо системі. `null` — нічого не міняти.
    static Configuration override(Context base) {
        float scale = effective(base);
        if (Math.abs(scale - 1f) < 0.01f) return null;
        Configuration current = base.getResources().getConfiguration();
        Configuration change = new Configuration();
        change.fontScale = 0;
        change.densityDpi = Math.round(current.densityDpi * scale);
        change.smallestScreenWidthDp = Math.round(current.smallestScreenWidthDp / scale);
        change.screenWidthDp = Math.round(current.screenWidthDp / scale);
        change.screenHeightDp = Math.round(current.screenHeightDp / scale);
        return change;
    }
}
