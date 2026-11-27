package ua.church.slovo.remote;

import android.app.Dialog;
import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.text.InputType;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.style.ReplacementSpan;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.BaseAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.PopupWindow;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/// Набір елементів інтерфейсу пульта й планшета — той самий, що в «Слові» для
/// Android: кольори, кнопки, картки, значки, списки й вікна, що виїжджають знизу.
///
/// Власник: «перевести программы пульт слова, планшет слова на новый интерфейс
/// от слова для андроид. Там меню и интерфейс получились намного удобнее и
/// лучше». Тому файл перенесено звідти майже без змін — щоб три програми
/// виглядали й поводились однаково, а не «схоже».
///
/// Вигляд — темний, для затемненої зали: майже чорне тло, підняті картки із
/// заокругленими кутами, один яскравий синьо-фіолетовий акцент для головної
/// дії, червоний — лише для «це зараз у залі», бурштиновий — для передпоказу.
/// Кожна дія має значок і підпис, кожен дотик — видимий відгук (хвилю).
///
/// Розкладка складається кодом, без XML: вікно перебудовується на льоту під
/// телефон і планшет, під поворот, масштаб і мову.
final class Ui {

    static final int BG = 0xFF0B0E13, CARD = 0xFF141922, CARD2 = 0xFF1D2531, CARD3 = 0xFF2A3648, LINE = 0xFF222B38,
        TEXT = 0xFFF3F5F8, DIM = 0xFF93A0B4, FAINT = 0xFF5F6B7D, ACCENT = 0xFF6C8CFF, ACCENT2 = 0xFF9B6CFF,
        LIVE = 0xFFFF5A5F, WARN = 0xFFFFB020, GREEN = 0xFF34D399, SELECT = 0xFF1B2A4D, RAIL = 0xFF10141B;

    static final int FILL = ViewGroup.LayoutParams.MATCH_PARENT, WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;

    static final Typeface MEDIUM = Typeface.create("sans-serif-medium", Typeface.NORMAL);

    private static float density = 2f;

    interface Pick { void on(int index); }
    interface Text { void on(String value); }
    interface Picks { void on(boolean[] checked); }

    private Ui() { }

    static void init(Context c) { density = c.getResources().getDisplayMetrics().density; }

    static int dp(float v) { return Math.round(v * density); }

    // MARK: Тла

    static GradientDrawable round(int color, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        return d;
    }

    static GradientDrawable gradient(int from, int to, float radiusDp) {
        GradientDrawable d = new GradientDrawable(GradientDrawable.Orientation.TL_BR, new int[] {from, to});
        d.setCornerRadius(dp(radiusDp));
        return d;
    }

    /// Тло з рамкою — для «увімкнених» перемикачів і вибраних карток.
    static GradientDrawable outlined(int fill, int stroke, float radiusDp) {
        GradientDrawable d = round(fill, radiusDp);
        d.setStroke(dp(1.5f), stroke);
        return d;
    }

    static int alpha(int color, int alpha) { return (color & 0x00FFFFFF) | (alpha << 24); }

    /// Тло з хвилею від дотику; у фокусі (клавіатура, пульт телевізора) — біла рамка.
    static Drawable ripple(Drawable content, float radiusDp) {
        GradientDrawable focus = round(0x22FFFFFF, radiusDp);
        focus.setStroke(dp(2), 0xFFFFFFFF);
        StateListDrawable states = new StateListDrawable();
        states.addState(new int[] {android.R.attr.state_focused}, new android.graphics.drawable.LayerDrawable(new Drawable[] {content, focus}));
        states.addState(new int[] {}, content);
        return new RippleDrawable(ColorStateList.valueOf(0x38FFFFFF), states, round(0xFFFFFFFF, radiusDp));
    }

    static Drawable pressable(int color, float radiusDp) { return ripple(round(color, radiusDp), radiusDp); }

    // MARK: Значки

    static Drawable icon(Context c, int res, int color, float sizeDp) {
        Drawable d = c.getResources().getDrawable(res, c.getTheme()).mutate();
        d.setTint(color);
        d.setBounds(0, 0, dp(sizeDp), dp(sizeDp));
        return d;
    }

    /// Значок у рядку тексту — щоб значок і підпис стояли по центру кнопки разом.
    private static final class IconSpan extends ReplacementSpan {
        private final Drawable drawable;
        private final int gap;

        IconSpan(Drawable d, int gapPx) {
            drawable = d;
            gap = gapPx;
        }

        @Override
        public int getSize(Paint paint, CharSequence text, int start, int end, Paint.FontMetricsInt fm) {
            return drawable.getBounds().width() + gap;
        }

        @Override
        public void draw(Canvas canvas, CharSequence text, int start, int end, float x, int top, int y, int bottom, Paint paint) {
            canvas.save();
            canvas.translate(x, top + (bottom - top - drawable.getBounds().height()) / 2f);
            drawable.draw(canvas);
            canvas.restore();
        }
    }

    /// Текст зі значком попереду.
    static CharSequence withIcon(Context c, int res, int color, float sizeDp, String text) {
        if (res == 0) return text;
        SpannableString s = new SpannableString("​" + text);
        s.setSpan(new IconSpan(icon(c, res, color, sizeDp), text.isEmpty() ? 0 : dp(7)), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        return s;
    }

    /// Змінити підпис кнопки, зберігши її значок.
    static void setText(TextView button, String text) {
        Object tag = button.getTag();
        if (tag instanceof Integer) button.setText(withIcon(button.getContext(), (Integer) tag, button.getCurrentTextColor(), 19, text));
        else button.setText(text);
        button.setContentDescription(text);
    }

    /// Старі рядки ресурсів несли значок просто в тексті («▶ Грати», «＋ Додати
    /// вибране», «📋 Скласти план»). Тепер значки — справжні, тож із тексту
    /// прибираємо все до першої літери чи лапок.
    static String plain(String text) {
        if (text == null) return "";
        int i = 0;
        while (i < text.length()) {
            int cp = text.codePointAt(i);
            if (Character.isLetterOrDigit(cp) || cp == '«' || cp == '"' || cp == '(') break;
            i += Character.charCount(cp);
        }
        String rest = i >= text.length() ? text : text.substring(i);
        // «Далі ▶» — значок і в кінці.
        int end = rest.length();
        while (end > 0) {
            int cp = rest.codePointBefore(end);
            if (Character.isLetterOrDigit(cp) || cp == '»' || cp == '"' || cp == ')' || cp == '.' || cp == '…' || cp == '%') break;
            end -= Character.charCount(cp);
        }
        return rest.substring(0, end).trim();
    }

    static ImageView image(Context c, int res, int color, float sizeDp) {
        ImageView v = new ImageView(c);
        v.setImageDrawable(icon(c, res, color, sizeDp));
        v.setScaleType(ImageView.ScaleType.CENTER);
        return v;
    }

    /// Кругла кнопка-значок.
    static ImageView iconButton(Context c, int res, int bg, Runnable action) {
        ImageView v = image(c, res, TEXT, 24);
        v.setBackground(ripple(round(bg, 24), 24));
        v.setClickable(true);
        v.setFocusable(true);
        if (action != null) v.setOnClickListener(x -> {
            x.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            action.run();
        });
        return v;
    }

    // MARK: Написи й кнопки

    static TextView label(Context c, String text, float sp, int color) {
        TextView t = new TextView(c);
        t.setText(text);
        t.setTextSize(sp);
        t.setTextColor(color);
        return t;
    }

    /// Звичайна кнопка: заокруглена плашка з підписом.
    static TextView button(Context c, String text, int bg, Runnable action) {
        return button(c, 0, text, bg, action);
    }

    /// Кнопка зі значком і підписом.
    static TextView button(Context c, int iconRes, String text, int bg, Runnable action) {
        TextView t = label(c, "", 14.5f, TEXT);
        t.setTypeface(MEDIUM);
        t.setGravity(Gravity.CENTER);
        t.setBackground(pressable(bg, 12));
        t.setPadding(dp(12), dp(8), dp(12), dp(8));
        t.setMinHeight(dp(46));
        t.setMaxLines(2);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setClickable(true);
        t.setFocusable(true);
        if (iconRes != 0) t.setTag(iconRes);
        setText(t, text);
        if (action != null) t.setOnClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            action.run();
        });
        return t;
    }

    /// Головна дія екрана: яскрава кнопка з градієнтом.
    static TextView primary(Context c, int iconRes, String text, Runnable action) {
        TextView t = button(c, iconRes, text, ACCENT, action);
        t.setBackground(ripple(gradient(ACCENT, ACCENT2, 16), 16));
        t.setTextSize(16);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setTextColor(0xFFFFFFFF);
        setText(t, text);
        return t;
    }

    /// Кнопка ввімкнена чи ні: вимкнена — бліда й не відповідає на дотик.
    static void enable(View v, boolean on) {
        v.setEnabled(on);
        v.setAlpha(on ? 1f : 0.45f);
    }

    /// Маленький перемикач-пігулка зі значком: «Без звуку», «Повтор» тощо.
    static TextView chip(Context c, int iconRes, String text, Runnable action) {
        TextView t = label(c, "", 13, TEXT);
        t.setTypeface(MEDIUM);
        t.setGravity(Gravity.CENTER);
        t.setPadding(dp(13), 0, dp(14), 0);
        t.setMinHeight(dp(38));
        t.setMaxLines(1);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setClickable(true);
        t.setFocusable(true);
        if (iconRes != 0) t.setTag(iconRes);
        chipState(t, text, false, ACCENT);
        if (action != null) t.setOnClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            action.run();
        });
        return t;
    }

    /// Плитка панелі інструментів: значок над коротким підписом. Плитки стоять рівним рядом
    /// на всю ширину — без прокрутки, тож жодна кнопка не ховається за краєм екрана.
    static TextView tool(Context c, int iconRes, String text, Runnable action) {
        TextView t = label(c, "", 11, TEXT);
        t.setTypeface(MEDIUM);
        t.setGravity(Gravity.CENTER);
        // Не setSingleLine: однорядковий режим прокручує текст убік, і тоді Android не зменшує шрифт.
        t.setMaxLines(1);
        t.setPadding(dp(2), dp(6), dp(2), dp(5));
        t.setCompoundDrawablePadding(dp(3));
        t.setClickable(true);
        t.setFocusable(true);
        t.setTag(iconRes);
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            // Довгий підпис (англійська, великий шрифт) зменшується, а не обрізається.
            t.setAutoSizeTextTypeUniformWithConfiguration(7, 11, 1, android.util.TypedValue.COMPLEX_UNIT_SP);
        } else {
            t.setEllipsize(TextUtils.TruncateAt.END);
        }
        toolState(t, text, false, ACCENT);
        if (action != null) t.setOnClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            action.run();
        });
        return t;
    }

    /// Стан плитки: увімкнена — кольорова з рамкою.
    static void toolState(TextView t, String text, boolean on, int onColor) {
        t.setText(text);
        t.setContentDescription(text);
        t.setTextColor(on ? onColor : TEXT);
        Object tag = t.getTag();
        if (tag instanceof Integer) t.setCompoundDrawables(null, icon(t.getContext(), (Integer) tag, on ? onColor : DIM, 21), null, null);
        t.setBackground(ripple(on ? outlined(alpha(onColor, 0x30), onColor, 12) : round(CARD2, 12), 12));
    }

    /// Вигляд перемикача: вимкнений — сіра плашка, увімкнений — кольорова з рамкою.
    static void chipState(TextView chip, String text, boolean on, int onColor) {
        chip.setTextColor(on ? onColor : TEXT);
        chip.setBackground(ripple(on ? outlined(alpha(onColor, 0x30), onColor, 19) : round(CARD2, 19), 19));
        chip.setContentDescription(text);
        Object tag = chip.getTag();
        if (tag instanceof Integer) chip.setText(withIcon(chip.getContext(), (Integer) tag, on ? onColor : DIM, 17, text));
        else chip.setText(text);
    }

    /// Пігулка стану над чи під карткою: «ЗАЛ», «ДАЛІ».
    static TextView pill(Context c, String text, int color) {
        TextView t = label(c, text, 10.5f, 0xFFFFFFFF);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setAllCaps(true);
        t.setLetterSpacing(0.08f);
        t.setBackground(round(color, 9));
        t.setPadding(dp(8), dp(2), dp(8), dp(2));
        t.setMaxLines(1);
        return t;
    }

    static LinearLayout row(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setBaselineAligned(false);
        return l;
    }

    static LinearLayout col(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    /// Картка: піднята плашка із заокругленими кутами.
    static LinearLayout card(Context c) {
        LinearLayout l = col(c);
        l.setBackground(round(CARD, 16));
        return l;
    }

    static LinearLayout.LayoutParams lp(int w, int h, float weight) {
        return new LinearLayout.LayoutParams(w, h, weight);
    }

    /// Те саме з полями довкола, dp.
    static LinearLayout.LayoutParams lp(int w, int h, float weight, int margin) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h, weight);
        int m = dp(margin);
        p.setMargins(m, m, m, m);
        return p;
    }

    static LinearLayout.LayoutParams lp(int w, int h, float weight, int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h, weight);
        p.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return p;
    }

    static FrameLayout.LayoutParams fill() { return new FrameLayout.LayoutParams(FILL, FILL); }

    /// Розпірка в ряду: забирає вільне місце. Висота нульова — порожній вид із
    /// висотою «за вмістом» у ряду кнопок бере всю доступну висоту.
    static View gap(Context c) {
        View v = new View(c);
        v.setLayoutParams(new LinearLayout.LayoutParams(0, 0, 1));
        return v;
    }

    static EditText field(Context c, String hint, boolean multiline) {
        EditText e = new EditText(c);
        e.setHint(hint);
        e.setTextColor(TEXT);
        e.setHintTextColor(FAINT);
        e.setTextSize(16);
        e.setBackground(round(CARD2, 12));
        e.setPadding(dp(14), dp(10), dp(14), dp(10));
        if (multiline) {
            e.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
            e.setGravity(Gravity.TOP | Gravity.START);
            e.setHorizontallyScrolling(false);
        } else {
            e.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            e.setSingleLine(true);
        }
        return e;
    }

    /// Поле пошуку зі значком лупи всередині.
    static EditText search(Context c, String hint) {
        EditText e = field(c, hint, false);
        e.setCompoundDrawablesRelative(icon(c, R.drawable.ic_search, DIM, 20), null, null, null);
        e.setCompoundDrawablePadding(dp(8));
        e.setPadding(dp(12), dp(10), dp(12), dp(10));
        return e;
    }

    /// Повзунок у кольорах програми.
    static SeekBar seek(Context c, int max) {
        SeekBar s = new SeekBar(c);
        s.setMax(max);
        s.setProgressTintList(ColorStateList.valueOf(ACCENT));
        s.setThumbTintList(ColorStateList.valueOf(ACCENT));
        s.setProgressBackgroundTintList(ColorStateList.valueOf(0xFF4A5568));
        return s;
    }

    static View line(Context c) {
        View v = new View(c);
        v.setBackgroundColor(LINE);
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(FILL, dp(1));
        p.setMargins(dp(14), 0, dp(14), 0);
        v.setLayoutParams(p);
        return v;
    }

    static TextView heading(Context c, String text) {
        TextView t = label(c, text, 13, DIM);
        t.setTypeface(MEDIUM);
        t.setAllCaps(true);
        t.setLetterSpacing(0.06f);
        t.setPadding(dp(20), dp(18), dp(20), dp(8));
        return t;
    }

    /// Рядок-підказка: дрібний сірий текст зі значком «і».
    static TextView hint(Context c, String text) {
        TextView t = label(c, text, 12.5f, DIM);
        t.setLineSpacing(dp(1), 1f);
        t.setPadding(dp(14), dp(4), dp(14), dp(6));
        return t;
    }

    /// Порожній стан: великий значок, пояснення й кнопка «що зробити».
    static LinearLayout empty(Context c, int iconRes, String title, String text, String action, Runnable run) {
        EmptyBox box = new EmptyBox(c);
        box.setGravity(Gravity.CENTER);
        box.setPadding(dp(28), dp(24), dp(28), dp(24));
        ImageView icon = image(c, iconRes, ACCENT, 34);
        icon.setBackground(round(alpha(ACCENT, 0x26), 36));
        box.addView(icon, lp(dp(72), dp(72), 0));
        TextView head = label(c, title, 18, TEXT);
        head.setTypeface(MEDIUM);
        head.setGravity(Gravity.CENTER);
        head.setPadding(0, dp(14), 0, dp(6));
        box.addView(head);
        TextView body = label(c, text, 14.5f, DIM);
        body.setGravity(Gravity.CENTER);
        body.setLineSpacing(dp(2), 1f);
        box.addView(body);
        box.icon = icon;
        box.body = body;
        if (action != null) {
            TextView b = primary(c, 0, action, run);
            b.setPadding(dp(22), dp(8), dp(22), dp(8));
            b.setMaxLines(1);
            box.addView(b, lp(WRAP, WRAP, 0, 0, 18, 0, 0));
        }
        return box;
    }

    /// Порожній стан, що вміщається у своє місце. Власник 27.11 (знімок телефона з великим
    /// шрифтом): «часть текста ушло за границу отображения» — під карткою зали й плитками
    /// лишилося мало місця, і кнопка «Завантажити файл…» обрізалася навпіл. Тепер, коли
    /// місця бракує, спершу зникає значок, далі пояснення; заголовок і кнопка — цілі.
    /// Місця досить знову (поворот, менший шрифт) — усе повертається.
    static final class EmptyBox extends LinearLayout {
        View icon, body;
        /// 0 — усе; 1 — без значка (і з меншими полями); 2 — ще й без пояснення.
        private int level;

        EmptyBox(Context c) {
            super(c);
            setOrientation(VERTICAL);
        }

        @Override
        protected void onMeasure(int widthSpec, int heightSpec) {
            int want = 0;
            if (MeasureSpec.getMode(heightSpec) != MeasureSpec.UNSPECIFIED) {
                // Висоти частин міряємо незалежно від того, що зараз сховано: вигляд
                // міняється лише тоді, коли міняється рішення, — інакше кожне вимірювання
                // ховало б і показувало значок, і вікно перемальовувалося б без кінця.
                int room = MeasureSpec.getSize(heightSpec);
                int free = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED);
                int rest = 0, iconHeight = 0, bodyHeight = 0;
                for (int i = 0; i < getChildCount(); i++) {
                    View child = getChildAt(i);
                    measureChildWithMargins(child, widthSpec, 0, free, 0);
                    LayoutParams params = (LayoutParams) child.getLayoutParams();
                    int height = child.getMeasuredHeight() + params.topMargin + params.bottomMargin;
                    if (child == icon) iconHeight = height;
                    else if (child == body) bodyHeight = height;
                    else rest += height;
                }
                if (dp(48) + rest + iconHeight + bodyHeight > room) want = dp(16) + rest + bodyHeight > room ? 2 : 1;
            }
            if (want != level) {
                level = want;
                if (icon != null) icon.setVisibility(level >= 1 ? GONE : VISIBLE);
                if (body != null) body.setVisibility(level >= 2 ? GONE : VISIBLE);
                int pad = dp(level >= 1 ? 8 : 24);
                setPadding(getPaddingLeft(), pad, getPaddingRight(), pad);
            }
            super.onMeasure(widthSpec, heightSpec);
        }
    }

    static void toast(Context c, String text) {
        Toast.makeText(c.getApplicationContext(), text, Toast.LENGTH_LONG).show();
    }

    static void hideKeyboard(View v) {
        if (v == null) return;
        InputMethodManager im = (InputMethodManager) v.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (im != null) im.hideSoftInputFromWindow(v.getWindowToken(), 0);
        v.clearFocus();
    }

    // MARK: Пояснення до кнопок

    private static PopupWindow tip;

    /// Довгий дотик на кнопці — що вона робить. Пояснення — своєю плашкою над
    /// кнопкою, а не `Toast`: той малює система, внизу й дрібно, і на частині
    /// пристроїв його не видно зовсім. Сама зникає за три з половиною секунди.
    static void explain(View view, String text) {
        if (view == null || text == null || text.isEmpty()) return;
        view.setOnLongClickListener(v -> {
            v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            showTip(v, text);
            return true;
        });
    }

    static void showTip(View anchor, String text) {
        if (tip != null) {
            try { tip.dismiss(); } catch (Exception ignored) { }
        }
        Context c = anchor.getContext();
        TextView label = label(c, text, 14.5f, 0xFFFFFFFF);
        label.setMaxWidth(dp(420));
        label.setPadding(dp(14), dp(9), dp(14), dp(9));
        label.setBackground(outlined(0xF61D2531, ACCENT, 12));
        label.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
        int[] at = new int[2];
        anchor.getLocationOnScreen(at);
        int width = c.getResources().getDisplayMetrics().widthPixels;
        int x = at[0] + anchor.getWidth() / 2 - label.getMeasuredWidth() / 2;
        x = Math.max(dp(4), Math.min(x, width - label.getMeasuredWidth() - dp(4)));
        int y = at[1] - label.getMeasuredHeight() - dp(6);
        if (y < dp(24)) y = at[1] + anchor.getHeight() + dp(6);
        PopupWindow shown = new PopupWindow(label, WRAP, WRAP, false);
        shown.setOutsideTouchable(true);
        try {
            shown.showAtLocation(anchor, Gravity.NO_GRAVITY, x, y);
        } catch (Exception gone) {
            return;
        }
        tip = shown;
        anchor.postDelayed(() -> {
            try { if (shown.isShowing()) shown.dismiss(); } catch (Exception ignored) { }
        }, 3500);
    }

    // MARK: Вікна, що виїжджають знизу

    /// Рамка, не вища за 82 % екрана: довгий список гортається всередині вікна.
    private static final class Capped extends FrameLayout {
        Capped(Context c) { super(c); }

        @Override
        protected void onMeasure(int widthSpec, int heightSpec) {
            int max = Math.round(getResources().getDisplayMetrics().heightPixels * 0.82f);
            super.onMeasure(widthSpec, MeasureSpec.makeMeasureSpec(max, MeasureSpec.AT_MOST));
        }
    }

    /// Вікно знизу з заголовком і довільним вмістом.
    static Dialog sheet(Context c, String title, View body) {
        Dialog d = new Dialog(c, R.style.Theme_Slovo_Sheet);
        LinearLayout box = col(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD);
        float r = dp(24);
        bg.setCornerRadii(new float[] {r, r, r, r, 0, 0, 0, 0});
        box.setBackground(bg);
        box.setPadding(0, dp(10), 0, dp(14));
        View handle = new View(c);
        handle.setBackground(round(0xFF3A4556, 3));
        LinearLayout.LayoutParams hp = new LinearLayout.LayoutParams(dp(42), dp(5));
        hp.gravity = Gravity.CENTER_HORIZONTAL;
        hp.bottomMargin = dp(6);
        box.addView(handle, hp);
        if (title != null && !title.isEmpty()) {
            TextView t = label(c, title, 18, TEXT);
            t.setTypeface(MEDIUM);
            t.setPadding(dp(22), dp(8), dp(22), dp(10));
            box.addView(t);
        }
        box.addView(body, lp(FILL, WRAP, 0));
        Capped cap = new Capped(c);
        cap.addView(box, new FrameLayout.LayoutParams(FILL, WRAP));
        d.setContentView(cap);
        Window w = d.getWindow();
        if (w != null) {
            w.setGravity(Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
            int screen = c.getResources().getDisplayMetrics().widthPixels;
            w.setLayout(Math.min(screen, dp(600)), WRAP);
        }
        d.setCanceledOnTouchOutside(true);
        try {
            d.show();
        } catch (Exception gone) {
            // Вікно програми вже закрили — показувати нема на чому.
        }
        return d;
    }

    /// Сторінка на весь екран зі стрілкою «назад» і заголовком.
    static Dialog page(Context c, String title, View body) {
        Dialog d = new Dialog(c, R.style.Theme_Slovo_Page);
        LinearLayout root = col(c);
        root.setBackgroundColor(BG);
        root.setFitsSystemWindows(true);
        LinearLayout bar = row(c);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(6), dp(4), dp(12), dp(4));
        bar.addView(iconButton(c, R.drawable.ic_back, 0x00000000, d::dismiss), lp(dp(48), dp(48), 0));
        TextView t = label(c, title, 20, TEXT);
        t.setTypeface(MEDIUM);
        t.setPadding(dp(8), 0, 0, 0);
        t.setMaxLines(1);
        t.setEllipsize(TextUtils.TruncateAt.END);
        bar.addView(t, lp(0, WRAP, 1));
        root.addView(bar);
        root.addView(body, lp(FILL, 0, 1));
        d.setContentView(root);
        Window w = d.getWindow();
        if (w != null) w.setLayout(FILL, FILL);
        try {
            d.show();
        } catch (Exception gone) {
            // Вікно програми вже закрили.
        }
        return d;
    }

    private static ListView choiceList(Context c, String[] items, int checked, Dialog[] holder, Pick done) {
        ListView list = new ListView(c);
        list.setDivider(null);
        list.setSelector(new ColorDrawable(Color.TRANSPARENT));
        list.setAdapter(new BaseAdapter() {
            @Override
            public int getCount() { return items.length; }

            @Override
            public Object getItem(int i) { return items[i]; }

            @Override
            public long getItemId(int i) { return i; }

            @Override
            public View getView(int i, View convert, ViewGroup parent) {
                TextView t = convert instanceof TextView ? (TextView) convert : label(c, "", 16, TEXT);
                t.setMinHeight(dp(52));
                t.setGravity(Gravity.CENTER_VERTICAL);
                t.setPadding(dp(22), dp(8), dp(22), dp(8));
                t.setText(items[i]);
                t.setTextColor(i == checked ? ACCENT : TEXT);
                t.setTypeface(i == checked ? MEDIUM : Typeface.DEFAULT);
                t.setCompoundDrawablesRelative(null, null, i == checked ? icon(c, R.drawable.ic_check, ACCENT, 22) : null, null);
                t.setBackground(pressable(i == checked ? alpha(ACCENT, 0x1E) : 0x00000000, 0));
                return t;
            }
        });
        list.setOnItemClickListener((p, v, i, id) -> {
            if (holder[0] != null) holder[0].dismiss();
            done.on(i);
        });
        if (checked > 3) list.setSelection(checked - 2);
        return list;
    }

    /// Вибір одного з варіантів; вибраний позначено галочкою.
    static void pick(Context c, String title, String[] items, int checked, Pick done) {
        Dialog[] holder = new Dialog[1];
        holder[0] = sheet(c, title, choiceList(c, items, checked, holder, done));
    }

    /// Перелік дій.
    static void menu(Context c, String title, String[] items, Pick done) {
        Dialog[] holder = new Dialog[1];
        holder[0] = sheet(c, title, choiceList(c, items, -1, holder, done));
    }

    /// Перелік дій із поясненням над ним (довге пояснення прокручується, дії лишаються видні).
    static void menu(Context c, String title, String text, String[] items, Pick done) {
        LinearLayout box = col(c);
        TextView body = label(c, text, 14, DIM);
        body.setLineSpacing(dp(3), 1f);
        body.setPadding(dp(22), 0, dp(22), dp(8));
        body.setTextIsSelectable(true);
        android.widget.ScrollView scroll = new android.widget.ScrollView(c);
        scroll.addView(body);
        box.addView(scroll, lp(FILL, text.length() > 360 ? dp(250) : WRAP, 0));
        Dialog[] holder = new Dialog[1];
        for (int i = 0; i < items.length; i++) {
            int index = i;
            TextView t = label(c, items[i], 16, i == 0 ? ACCENT : TEXT);
            t.setTypeface(i == 0 ? MEDIUM : Typeface.DEFAULT);
            t.setMinHeight(dp(50));
            t.setGravity(Gravity.CENTER_VERTICAL);
            t.setPadding(dp(22), dp(6), dp(22), dp(6));
            t.setBackground(ripple(new ColorDrawable(Color.TRANSPARENT), 0));
            t.setOnClickListener(v -> {
                holder[0].dismiss();
                done.on(index);
            });
            box.addView(t, lp(FILL, WRAP, 0));
        }
        holder[0] = sheet(c, title, box);
    }

    /// Вибір кількох: рядки з галочками й кнопки «Скасувати» / `yes`.
    static void multi(Context c, String title, String[] items, String yes, Picks done) {
        boolean[] checked = new boolean[items.length];
        LinearLayout box = col(c);
        ListView list = new ListView(c);
        list.setDivider(null);
        list.setSelector(new ColorDrawable(Color.TRANSPARENT));
        BaseAdapter adapter = new BaseAdapter() {
            @Override
            public int getCount() { return items.length; }

            @Override
            public Object getItem(int i) { return items[i]; }

            @Override
            public long getItemId(int i) { return i; }

            @Override
            public View getView(int i, View convert, ViewGroup parent) {
                TextView t = convert instanceof TextView ? (TextView) convert : label(c, "", 16, TEXT);
                t.setMinHeight(dp(52));
                t.setGravity(Gravity.CENTER_VERTICAL);
                t.setPadding(dp(22), dp(8), dp(22), dp(8));
                t.setText(items[i]);
                t.setTextColor(checked[i] ? ACCENT : TEXT);
                t.setCompoundDrawablesRelative(null, null, icon(c, R.drawable.ic_check, checked[i] ? ACCENT : 0x00000000, 22), null);
                t.setBackground(pressable(checked[i] ? alpha(ACCENT, 0x1E) : 0x00000000, 0));
                return t;
            }
        };
        list.setAdapter(adapter);
        list.setOnItemClickListener((p, v, i, id) -> {
            checked[i] = !checked[i];
            adapter.notifyDataSetChanged();
        });
        box.addView(list, lp(FILL, 0, 1));
        Dialog[] holder = new Dialog[1];
        box.addView(buttons(c, holder, Lang.t("Скасувати", "Cancel"), yes, () -> done.on(checked)));
        holder[0] = sheet(c, title, box);
    }

    private static LinearLayout buttons(Context c, Dialog[] holder, String no, String yes, Runnable onYes) {
        LinearLayout row = row(c);
        row.setPadding(dp(16), dp(14), dp(16), dp(2));
        row.addView(button(c, no, CARD2, () -> holder[0].dismiss()), lp(0, dp(50), 1, 4));
        TextView ok = primary(c, 0, yes, () -> {
            holder[0].dismiss();
            onYes.run();
        });
        row.addView(ok, lp(0, dp(50), 1, 4));
        return row;
    }

    static void prompt(Context c, String title, String initial, boolean multiline, Text done) {
        LinearLayout box = col(c);
        EditText e = field(c, "", multiline);
        e.setText(initial == null ? "" : initial);
        e.setSelection(e.getText().length());
        if (multiline) {
            e.setMinLines(5);
            e.setMaxLines(12);
        }
        box.addView(e, lp(FILL, WRAP, 0, 18, 2, 18, 0));
        Dialog[] holder = new Dialog[1];
        box.addView(buttons(c, holder, Lang.t("Скасувати", "Cancel"), Lang.t("Гаразд", "OK"), () -> done.on(e.getText().toString())));
        holder[0] = sheet(c, title, box);
        Window w = holder[0].getWindow();
        if (w != null) w.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        e.requestFocus();
    }

    /// Запитання з двома відповідями; `yes` — назва дії («Скинути», «Прибрати»).
    static void confirm(Context c, String title, String text, String yes, Runnable onYes) {
        LinearLayout box = col(c);
        if (text != null && !text.isEmpty()) {
            TextView body = label(c, text, 15, DIM);
            body.setLineSpacing(dp(3), 1f);
            body.setPadding(dp(22), 0, dp(22), dp(2));
            box.addView(body);
        }
        Dialog[] holder = new Dialog[1];
        box.addView(buttons(c, holder, Lang.t("Скасувати", "Cancel"), yes, onYes));
        holder[0] = sheet(c, title, box);
    }

    static void confirm(Context c, String text, Runnable yes) {
        LinearLayout box = col(c);
        Dialog[] holder = new Dialog[1];
        box.addView(buttons(c, holder, Lang.t("Ні", "No"), Lang.t("Так", "Yes"), yes));
        holder[0] = sheet(c, text, box);
    }

    static Dialog info(Context c, String title, String text) { return info(c, title, text, Lang.t("Гаразд", "OK"), null); }

    /// Повідомлення з однією кнопкою; `then` виконується після неї.
    static Dialog info(Context c, String title, String text, String ok, Runnable then) {
        LinearLayout box = col(c);
        TextView body = label(c, text, 15, DIM);
        body.setLineSpacing(dp(3), 1f);
        body.setPadding(dp(22), 0, dp(22), dp(6));
        body.setTextIsSelectable(true);
        android.widget.ScrollView scroll = new android.widget.ScrollView(c);
        scroll.addView(body);
        box.addView(scroll, lp(FILL, text.length() > 500 ? dp(280) : WRAP, 0));
        Dialog[] holder = new Dialog[1];
        TextView button = then == null ? button(c, ok, CARD2, () -> holder[0].dismiss())
            : primary(c, 0, ok, () -> {
                holder[0].dismiss();
                then.run();
            });
        box.addView(button, lp(FILL, dp(50), 0, 18, 10, 18, 0));
        holder[0] = sheet(c, title, box);
        return holder[0];
    }

    // MARK: Списки

    /// Список рядків: номер-значок, назва, дрібний підпис. Вибраний рядок —
    /// підсвічена картка з кольоровою рамкою.
    abstract static class Rows<T> extends BaseAdapter {
        final ArrayList<T> items = new ArrayList<>();
        int selected = -1;

        abstract String title(T item);

        String sub(T item) { return ""; }

        /// Номер чи позначка зліва («16», «♪»); `null` — без неї.
        String badge(T item) { return null; }

        /// Колір назви: за умовчанням звичайний.
        int color(T item) { return TEXT; }

        /// Рядок-заголовок («Старий Заповіт»): не натискається, дрібний і сірий.
        boolean header(T item) { return false; }

        /// Мініатюра рядка: ключ для `Thumbs` (`null` — без мініатюри) і самі мініатюри.
        String thumb(T item) { return null; }

        /// Меню рядка — кнопка «⋮» праворуч (`null` — без неї).
        Runnable more(T item) { return null; }

        Thumbs thumbs;

        /// Чи рядок вибрано (за умовчанням — один, `selected`).
        boolean chosen(int position) { return position == selected; }

        void set(List<T> list) {
            items.clear();
            if (list != null) items.addAll(list);
            notifyDataSetChanged();
        }

        void select(int index) {
            selected = index;
            notifyDataSetChanged();
        }

        @Override
        public int getCount() { return items.size(); }

        @Override
        public T getItem(int position) { return items.get(position); }

        @Override
        public long getItemId(int position) { return position; }

        @Override
        public boolean areAllItemsEnabled() { return false; }

        @Override
        public boolean isEnabled(int position) { return position < items.size() && !header(items.get(position)); }

        @Override
        public View getView(int position, View convert, ViewGroup parent) {
            FrameLayout outer = (FrameLayout) convert;
            if (outer == null) {
                Context c = parent.getContext();
                outer = new FrameLayout(c);
                outer.setPadding(dp(6), dp(2), dp(6), dp(2));
                LinearLayout card = row(c);
                card.setGravity(Gravity.CENTER_VERTICAL);
                card.setPadding(dp(10), dp(9), dp(12), dp(9));
                TextView badge = label(c, "", 13, ACCENT);
                badge.setTypeface(MEDIUM);
                badge.setGravity(Gravity.CENTER);
                badge.setMinWidth(dp(34));
                badge.setMinHeight(dp(28));
                badge.setPadding(dp(6), 0, dp(6), 0);
                LinearLayout texts = col(c);
                TextView a = label(c, "", 16, TEXT);
                a.setLineSpacing(dp(2), 1f);
                TextView b = label(c, "", 12.5f, DIM);
                b.setMaxLines(2);
                b.setEllipsize(TextUtils.TruncateAt.END);
                texts.addView(a);
                texts.addView(b);
                // Мініатюра 16:9 — для сторінок показу й фото.
                ImageView picture = new ImageView(c);
                picture.setScaleType(ImageView.ScaleType.FIT_CENTER);
                picture.setBackground(round(0xFF000000, 8));
                picture.setClipToOutline(true);
                // «⋮» — дії з рядком. Не фокусується: інакше ListView перестає ловити дотик по рядку.
                ImageView dots = image(c, R.drawable.ic_more, DIM, 22);
                dots.setBackground(pressable(0x00000000, 20));
                dots.setFocusable(false);
                card.addView(badge, lp(WRAP, WRAP, 0, 0, 0, 10, 0));
                card.addView(picture, lp(dp(96), dp(54), 0, 0, 0, 12, 0));
                card.addView(texts, lp(0, WRAP, 1));
                card.addView(dots, lp(dp(44), dp(44), 0, 6, 0, -6, 0));
                outer.addView(card, new FrameLayout.LayoutParams(FILL, WRAP));
            }
            LinearLayout card = (LinearLayout) outer.getChildAt(0);
            TextView badge = (TextView) card.getChildAt(0);
            ImageView picture = (ImageView) card.getChildAt(1);
            LinearLayout texts = (LinearLayout) card.getChildAt(2);
            ImageView dots = (ImageView) card.getChildAt(3);
            TextView a = (TextView) texts.getChildAt(0), b = (TextView) texts.getChildAt(1);
            T item = items.get(position);
            boolean head = header(item);
            boolean on = !head && chosen(position);
            a.setText(title(item));
            a.setTextColor(head ? DIM : color(item));
            a.setTextSize(head ? 12.5f : 16);
            a.setAllCaps(head);
            a.setTypeface(head ? MEDIUM : Typeface.DEFAULT);
            a.setLetterSpacing(head ? 0.06f : 0f);
            String s = head ? "" : sub(item);
            b.setText(s);
            b.setVisibility(s == null || s.isEmpty() ? View.GONE : View.VISIBLE);
            String mark = head ? null : badge(item);
            badge.setVisibility(mark == null ? View.GONE : View.VISIBLE);
            if (mark != null) {
                badge.setText(mark);
                badge.setTextColor(on ? 0xFFFFFFFF : ACCENT);
                badge.setBackground(round(on ? ACCENT : alpha(ACCENT, 0x24), 8));
            }
            Runnable menu = more(item);
            dots.setVisibility(menu == null ? View.GONE : View.VISIBLE);
            dots.setOnClickListener(menu == null ? null : v -> {
                v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
                menu.run();
            });
            dots.setClickable(menu != null);
            dots.setContentDescription(Lang.t("Дії", "Actions"));
            String key = head ? null : thumb(item);
            picture.setVisibility(key == null ? View.GONE : View.VISIBLE);
            if (key != null) picture.setImageBitmap(thumbs == null ? null : thumbs.get(key));
            card.setPadding(dp(10), dp(head ? 14 : 9), dp(12), dp(head ? 4 : 9));
            card.setBackground(on ? outlined(SELECT, alpha(ACCENT, 0xB0), 12) : null);
            return outer;
        }
    }

    static ListView list(Context c, BaseAdapter adapter) {
        ListView l = new ListView(c);
        l.setAdapter(adapter);
        l.setDivider(null);
        l.setCacheColorHint(Color.TRANSPARENT);
        l.setSelector(new ColorDrawable(0x18FFFFFF));
        l.setDrawSelectorOnTop(false);
        l.setPadding(0, dp(4), 0, dp(8));
        l.setClipToPadding(false);
        return l;
    }

    /// Рамка зі сталим відношенням сторін 16:9 — картки «Зал» і «Далі».
    static class RatioFrame extends FrameLayout {
        private float ratio = 16f / 9f;
        private int cap;

        RatioFrame(Context c) { super(c); }

        /// Найбільша висота кадру, px (0 — без межі): вищий кадр звужується, зберігаючи пропорції.
        void cap(int maxHeightPx) {
            if (cap == maxHeightPx) return;
            cap = maxHeightPx;
            requestLayout();
        }

        /// Відношення сторін кадру (ширина до висоти): слайд 4:3 має право на вищий кадр.
        void ratio(float value) {
            float wanted = Math.max(1.2f, Math.min(2.4f, value));
            if (Math.abs(wanted - ratio) < 0.01f) return;
            ratio = wanted;
            requestLayout();
        }

        @Override
        protected void onMeasure(int widthSpec, int heightSpec) {
            int w = MeasureSpec.getSize(widthSpec), h = MeasureSpec.getSize(heightSpec);
            int hMode = MeasureSpec.getMode(heightSpec);
            // Висота не обмежена — беремо всю ширину; обмежена — вписуємо кадр у те, що дали.
            int fitW = hMode == MeasureSpec.UNSPECIFIED || h <= 0 ? w : Math.min(w, Math.round(h * ratio));
            int fitH = Math.round(fitW / ratio);
            if (cap > 0 && fitH > cap) {
                fitH = cap;
                fitW = Math.round(cap * ratio);
            }
            super.onMeasure(MeasureSpec.makeMeasureSpec(fitW, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(fitH, MeasureSpec.EXACTLY));
        }
    }

    /// Час «м:сс» або «г:мм:сс».
    static String clock(double seconds) {
        long s = Math.max(0, Math.round(seconds)), h = s / 3600, m = (s / 60) % 60;
        s %= 60;
        return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s);
    }

    private static String two(long v) { return v < 10 ? "0" + v : String.valueOf(v); }
}
