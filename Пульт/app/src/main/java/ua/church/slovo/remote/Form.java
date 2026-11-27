package ua.church.slovo.remote;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

import java.util.ArrayList;

/// Сторінка налаштувань: розділи-картки з рядками «значок — назва — значення»
/// і справжніми перемикачами. Перенесено зі «Слова» для Android.
///
/// Кожен рядок сам знає, як показати своє значення, тож після будь-якої
/// зміни досить `refresh()` — і вся сторінка відповідає стану програми.
final class Form {

    interface Value { String get(); }
    interface Flag { boolean get(); }

    final LinearLayout box;
    private final Context c;
    private LinearLayout card;
    private final ArrayList<Runnable> refreshers = new ArrayList<>();

    Form(Context context) {
        c = context;
        box = Ui.col(c);
        box.setPadding(Ui.dp(10), 0, Ui.dp(10), Ui.dp(28));
    }

    ScrollView scroll() {
        ScrollView s = new ScrollView(c);
        s.setVerticalScrollBarEnabled(false);
        s.addView(box);
        return s;
    }

    /// Новий розділ: заголовок і картка під ним.
    void heading(String text) {
        TextView t = Ui.heading(c, text);
        t.setPadding(Ui.dp(10), Ui.dp(18), Ui.dp(10), Ui.dp(8));
        box.addView(t);
        card = Ui.card(c);
        card.setPadding(0, Ui.dp(4), 0, Ui.dp(4));
        box.addView(card);
    }

    private LinearLayout target() {
        if (card == null) heading("");
        return card;
    }

    /// Пояснення дрібним шрифтом усередині картки.
    TextView note(String text) {
        TextView t = Ui.label(c, text, 13, Ui.DIM);
        t.setLineSpacing(Ui.dp(2), 1f);
        t.setPadding(Ui.dp(16), Ui.dp(8), Ui.dp(16), Ui.dp(10));
        target().addView(t);
        return t;
    }

    private LinearLayout line(int icon, String title) {
        LinearLayout r = Ui.row(c);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(Ui.dp(14), Ui.dp(8), Ui.dp(14), Ui.dp(8));
        r.setMinimumHeight(Ui.dp(54));
        if (icon != 0) {
            ImageView i = Ui.image(c, icon, Ui.ACCENT, 20);
            i.setBackground(Ui.round(Ui.alpha(Ui.ACCENT, 0x22), 10));
            r.addView(i, Ui.lp(Ui.dp(36), Ui.dp(36), 0, 0, 0, 12, 0));
        }
        TextView name = Ui.label(c, title, 15.5f, Ui.TEXT);
        r.addView(name, Ui.lp(0, Ui.WRAP, 1));
        return r;
    }

    /// Рядок: значок, назва, значення праворуч; дотик відкриває вибір.
    void row(int icon, String title, Value value, Runnable click) {
        LinearLayout r = line(icon, title);
        TextView val = Ui.label(c, "", 14, Ui.DIM);
        val.setGravity(Gravity.END);
        val.setMaxWidth(Ui.dp(190));
        val.setPadding(Ui.dp(10), 0, 0, 0);
        r.addView(val, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        if (click != null) {
            r.setBackground(Ui.pressable(0x00000000, 12));
            r.setFocusable(true);
            r.setOnClickListener(v -> click.run());
            r.addView(Ui.image(c, R.drawable.ic_right, Ui.FAINT, 20), Ui.lp(Ui.dp(22), Ui.dp(22), 0));
        }
        target().addView(r);
        if (value != null) {
            Runnable update = () -> {
                String text = value.get();
                val.setText(text);
                val.setVisibility(text == null || text.isEmpty() ? View.GONE : View.VISIBLE);
            };
            refreshers.add(update);
            update.run();
        } else {
            val.setVisibility(View.GONE);
        }
    }

    /// Перемикач: `state` каже, чи ввімкнено, `flip` перемикає. `enabled` (може бути `null`) —
    /// чи рядок зараз має сенс («Плюс гортає назад» — лише коли клавіші гучності гортають).
    void toggle(int icon, String title, Flag state, Runnable flip, Flag enabled) {
        LinearLayout r = line(icon, title);
        Switch s = new Switch(c);
        s.setChecked(state.get());
        s.setClickable(false);
        s.setFocusable(false);
        r.addView(s, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        r.setBackground(Ui.pressable(0x00000000, 12));
        r.setFocusable(true);
        r.setOnClickListener(v -> {
            if (enabled != null && !enabled.get()) return;
            flip.run();
            refresh();
        });
        target().addView(r);
        refreshers.add(() -> {
            s.setChecked(state.get());
            r.setAlpha(enabled == null || enabled.get() ? 1f : 0.45f);
        });
        r.setAlpha(enabled == null || enabled.get() ? 1f : 0.45f);
    }

    /// Рядок у два поверхи: назва й під нею пояснення чи стан.
    void entry(int icon, String title, Value below, Runnable click) {
        LinearLayout r = Ui.row(c);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(Ui.dp(14), Ui.dp(10), Ui.dp(14), Ui.dp(10));
        r.setMinimumHeight(Ui.dp(62));
        if (icon != 0) {
            ImageView i = Ui.image(c, icon, Ui.ACCENT, 22);
            i.setBackground(Ui.round(Ui.alpha(Ui.ACCENT, 0x22), 12));
            r.addView(i, Ui.lp(Ui.dp(40), Ui.dp(40), 0, 0, 0, 12, 0));
        }
        LinearLayout texts = Ui.col(c);
        TextView name = Ui.label(c, title, 16, Ui.TEXT);
        name.setTypeface(Ui.MEDIUM);
        texts.addView(name);
        TextView sub = Ui.label(c, "", 13, Ui.DIM);
        sub.setLineSpacing(Ui.dp(1), 1f);
        texts.addView(sub, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 2, 0, 0));
        r.addView(texts, Ui.lp(0, Ui.WRAP, 1));
        if (click != null) {
            r.setBackground(Ui.pressable(0x00000000, 12));
            r.setFocusable(true);
            r.setOnClickListener(v -> click.run());
            r.addView(Ui.image(c, R.drawable.ic_right, Ui.FAINT, 20), Ui.lp(Ui.dp(22), Ui.dp(22), 0, 8, 0, 0, 0));
        }
        target().addView(r);
        if (below != null) {
            Runnable update = () -> {
                String text = below.get();
                sub.setText(text);
                sub.setVisibility(text == null || text.isEmpty() ? View.GONE : View.VISIBLE);
            };
            refreshers.add(update);
            update.run();
        } else {
            sub.setVisibility(View.GONE);
        }
    }

    /// Довільний вид усередині поточної картки.
    void add(View v) { target().addView(v); }

    void refresh() {
        for (Runnable r : refreshers) r.run();
    }
}
