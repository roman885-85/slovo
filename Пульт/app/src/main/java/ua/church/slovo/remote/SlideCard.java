package ua.church.slovo.remote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/// Картка-монітор, як у «Слові» для Android: кадр зі сталим відношенням
/// сторін у кольоровій рамці, під ним — пігулка стану («ЗАЛ», «ДАЛІ») і назва.
///
/// Усередині — або картинка (слайд презентації, зал) з плямою указки поверх,
/// або текст, намальований як слайд: адреса місця Писання згори, слова
/// посередині, розмір підбирається сам. Підпис стоїть під кадром, а не на
/// ньому: текст унизу кадру має бути видно цілком.
final class SlideCard {

    final LinearLayout view;
    final Ui.RatioFrame frame;
    final ImageView image;
    final PointerView pointer;
    private final TextSlide text;
    private final TextView note, pill, title;
    private final FrameLayout border;

    /// `fit` — картка вписується у висоту, яку їй дали (картки стовпчиком на планшеті), а не бере її за шириною.
    SlideCard(Context c, boolean fit) {
        border = new FrameLayout(c);
        border.setPadding(Ui.dp(2), Ui.dp(2), Ui.dp(2), Ui.dp(2));
        frame = new Ui.RatioFrame(c);
        frame.setBackground(Ui.round(0xFF000000, 11));
        frame.setClipToOutline(true);
        text = new TextSlide(c);
        frame.addView(text, Ui.fill());
        image = new ImageView(c);
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        image.setVisibility(View.GONE);
        frame.addView(image, Ui.fill());
        pointer = new PointerView(c);
        pointer.setVisibility(View.GONE);
        frame.addView(pointer, Ui.fill());
        note = Ui.label(c, "", 14, Ui.DIM);
        note.setGravity(Gravity.CENTER);
        note.setPadding(Ui.dp(14), Ui.dp(8), Ui.dp(14), Ui.dp(8));
        note.setVisibility(View.GONE);
        frame.addView(note, Ui.fill());
        border.addView(frame, new FrameLayout.LayoutParams(Ui.FILL, Ui.WRAP, Gravity.CENTER));

        LinearLayout caption = Ui.row(c);
        caption.setGravity(Gravity.CENTER_VERTICAL);
        caption.setPadding(Ui.dp(2), Ui.dp(4), Ui.dp(2), 0);
        pill = Ui.pill(c, "", Ui.CARD3);
        caption.addView(pill, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        title = Ui.label(c, "", 11.5f, Ui.TEXT);
        title.setMaxLines(1);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setPadding(Ui.dp(7), 0, 0, 0);
        caption.addView(title, Ui.lp(0, Ui.WRAP, 1));

        view = Ui.col(c);
        view.setGravity(Gravity.CENTER_HORIZONTAL);
        // Рамка завжди облягає кадр: кадр буває вужчим за картку, коли його висоту обмежено.
        view.addView(border, fit ? Ui.lp(Ui.WRAP, 0, 1) : Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        view.addView(caption, Ui.lp(Ui.FILL, Ui.WRAP, 0));
        border(Ui.CARD3);
    }

    void border(int color) { border.setBackground(Ui.round(color, 13)); }

    void pill(String text, int color) {
        pill.setText(text);
        pill.setBackground(Ui.round(color, 9));
    }

    void title(String text) { title.setText(text == null ? "" : text); }

    /// Показати текст як слайд; порожній — підказка сірим посередині.
    void text(String reference, String body, String whenEmpty) {
        image.setVisibility(View.GONE);
        pointer.setVisibility(View.GONE);
        boolean empty = (reference == null || reference.isEmpty()) && (body == null || body.isEmpty());
        text.setVisibility(View.VISIBLE);
        text.set(empty ? "" : reference, empty ? "" : body);
        note(empty ? whenEmpty : "");
    }

    /// Показувати картинку (і пляму указки поверх неї).
    void picture() {
        text.set("", "");
        image.setVisibility(View.VISIBLE);
        pointer.setVisibility(View.VISIBLE);
    }

    /// Напис посередині кадру: «У залі відео», «Презентацію не відкрито».
    void note(String message) {
        boolean has = message != null && !message.isEmpty();
        note.setText(has ? message : "");
        note.setVisibility(has ? View.VISIBLE : View.GONE);
    }

    /// Кнопка в кутку кадру («Вихідний вигляд»).
    void corner(View v, int gravity) {
        FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(Ui.WRAP, Ui.WRAP, gravity);
        p.setMargins(Ui.dp(6), Ui.dp(6), Ui.dp(6), Ui.dp(6));
        frame.addView(v, p);
    }

    /// Кнопка «↺ Вихідний вигляд» у кутку кадру: видна, лише поки зал наближено.
    static TextView zoomBack(Context c, Runnable reset) {
        TextView t = Ui.label(c, "", 11.5f, 0xFFFFFFFF);
        t.setTypeface(Ui.MEDIUM);
        t.setBackground(Ui.ripple(Ui.round(0xE0FF5A5F, 14), 14));
        t.setPadding(Ui.dp(10), Ui.dp(5), Ui.dp(10), Ui.dp(5));
        t.setText(Ui.withIcon(c, R.drawable.ic_refresh, 0xFFFFFFFF, 14, Lang.t("Вихідний вигляд", "Reset view")));
        t.setOnClickListener(v -> reset.run());
        t.setVisibility(View.GONE);
        return t;
    }

    /// Текст, намальований як слайд у залі: темне тло, адреса згори, слова по центру.
    static final class TextSlide extends View {
        private String reference = "", body = "";
        private final TextPaint words = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        private final TextPaint head = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        private final Paint back = new Paint();
        private StaticLayout laid;
        private int laidFor;

        TextSlide(Context c) {
            super(c);
            words.setColor(0xFFFFFFFF);
            words.setTypeface(Typeface.DEFAULT_BOLD);
            head.setColor(0xFFFFD166);
            head.setTypeface(Ui.MEDIUM);
            head.setTextAlign(Paint.Align.CENTER);
        }

        void set(String ref, String text) {
            String r = ref == null ? "" : ref.trim(), b = text == null ? "" : text.trim();
            if (r.equals(reference) && b.equals(body)) return;
            reference = r;
            body = b;
            laid = null;
            invalidate();
        }

        @Override
        protected void onSizeChanged(int w, int h, int oldW, int oldH) {
            back.setShader(new LinearGradient(0, 0, 0, h, 0xFF11203D, 0xFF05080F, Shader.TileMode.CLAMP));
            laid = null;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            if (w <= 0 || h <= 0) return;
            canvas.drawRect(0, 0, w, h, back);
            float top = h * 0.06f;
            if (!reference.isEmpty()) {
                head.setTextSize(Math.max(Ui.dp(8), h * 0.075f));
                CharSequence line = TextUtils.ellipsize(reference, head, w * 0.9f, TextUtils.TruncateAt.END);
                canvas.drawText(line, 0, line.length(), w / 2f, top - head.ascent(), head);
                top += head.getTextSize() * 1.5f;
            }
            if (body.isEmpty()) return;
            int width = Math.round(w * 0.9f);
            float room = h - top - h * 0.05f;
            if (laid == null || laidFor != w * 31 + h) {
                // Найбільший розмір, з яким текст уміщається: від 13 % висоти вниз.
                float size = h * 0.13f, least = Math.max(Ui.dp(6), h * 0.035f);
                StaticLayout fit;
                while (true) {
                    words.setTextSize(size);
                    fit = new StaticLayout(body, words, width, Layout.Alignment.ALIGN_CENTER, 1.08f, 0f, false);
                    if (fit.getHeight() <= room || size <= least) break;
                    size = Math.max(least, size * 0.92f);
                }
                laid = fit;
                laidFor = w * 31 + h;
            }
            canvas.save();
            canvas.clipRect(0, top, w, h);
            canvas.translate((w - width) / 2f, top + Math.max(0, (room - laid.getHeight()) / 2f));
            laid.draw(canvas);
            canvas.restore();
        }
    }
}
