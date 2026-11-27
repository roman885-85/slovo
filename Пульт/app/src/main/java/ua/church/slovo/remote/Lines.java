package ua.church.slovo.remote;

import android.view.HapticFeedbackConstants;
import android.widget.ListView;

/// Список рядків пульта й планшета: кожен рядок сам знає, що написати, чи він
/// поточний і що робить дотик. Вигляд — `Ui.Rows`.
final class Lines extends Ui.Rows<Lines.Line> {

    static final class Line {
        /// Номер чи позначка зліва; `null` — без неї.
        final String badge;
        final String title, sub;
        /// Поточний рядок (підсвічена картка), назва акцентом, рядок-заголовок.
        final boolean current, strong, header;
        final Runnable tap, longTap;
        /// Ключ мініатюри (див. `Thumbs`); `null` — рядок без неї.
        String thumb;
        /// Меню «⋮» праворуч; `null` — без нього.
        Runnable menu;

        Line(String badge, String title, String sub, boolean current, boolean strong, boolean header, Runnable tap, Runnable longTap) {
            this.badge = badge;
            this.title = title == null ? "" : title;
            this.sub = sub == null ? "" : sub;
            this.current = current;
            this.strong = strong;
            this.header = header;
            this.tap = tap;
            this.longTap = longTap;
        }

        Line(String badge, String title, String sub, boolean current, boolean strong, boolean header, Runnable tap) {
            this(badge, title, sub, current, strong, header, tap, null);
        }

        /// Звичайний рядок.
        static Line of(String badge, String title, String sub, boolean current, Runnable tap) {
            return new Line(badge, title, sub, current, false, false, tap, null);
        }

        /// Той самий рядок із мініатюрою.
        Line thumb(String key) {
            thumb = key;
            return this;
        }

        /// Той самий рядок із меню «⋮».
        Line menu(Runnable actions) {
            menu = actions;
            return this;
        }

        /// Рядок-заголовок: не натискається.
        static Line head(String title) {
            return new Line(null, title, "", false, false, true, null, null);
        }
    }

    @Override
    String title(Line l) { return l.title; }

    @Override
    String sub(Line l) { return l.sub; }

    @Override
    String badge(Line l) { return l.badge; }

    @Override
    int color(Line l) { return l.strong ? Ui.ACCENT : Ui.TEXT; }

    @Override
    boolean header(Line l) { return l.header; }

    @Override
    String thumb(Line l) { return l.thumb; }

    @Override
    Runnable more(Line l) { return l.menu; }

    /// Підпис усього списку — щоб не перебудовувати його, коли нічого не змінилося:
    /// стан приходить до дванадцяти разів на секунду, поки ведуть указку.
    static String signature(java.util.List<Line> rows) {
        StringBuilder out = new StringBuilder();
        for (Line l : rows) {
            out.append(l.badge).append('|').append(l.title).append('|').append(l.sub).append('|')
               .append(l.current).append(l.strong).append(l.header).append('|').append(l.thumb)
               .append(l.menu != null).append('\n');
        }
        return out.toString();
    }

    @Override
    boolean chosen(int position) { return items.get(position).current; }

    /// Місце першого поточного рядка (−1 — немає).
    int current() {
        for (int i = 0; i < items.size(); i++) if (items.get(i).current) return i;
        return -1;
    }

    /// Дотик і довгий дотик по рядку списку — те, що рядок каже сам.
    static void wire(ListView list, Lines lines) {
        list.setOnItemClickListener((parent, view, position, id) -> {
            if (position < 0 || position >= lines.items.size()) return;
            Runnable tap = lines.items.get(position).tap;
            if (tap == null) return;
            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            tap.run();
        });
        list.setOnItemLongClickListener((parent, view, position, id) -> {
            if (position < 0 || position >= lines.items.size()) return false;
            Runnable held = lines.items.get(position).longTap;
            if (held == null) return false;
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            held.run();
            return true;
        });
    }
}
