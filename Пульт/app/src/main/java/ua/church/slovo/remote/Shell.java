package ua.church.slovo.remote;

import android.app.Activity;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/// Каркас головного вікна — один на пульт і планшет, складений так само, як
/// головне вікно «Слова» для Android.
///
/// Угорі — знак програми, стан зв'язку й «Налаштування». Далі блок показу:
/// картки «Далі» й «Зал», під ними «Показати» / «Сховати» зі стрілками й ряд
/// плиток. Нижче — вміст розділу й розділи смугою внизу. На широкому екрані
/// (планшет, телефон лежачи) розділи стоять стовпчиком ліворуч, а блок
/// показу — стовпчиком праворуч.
///
/// Нічого не ховається за краєм: плитки стоять рівним рядом на всю ширину,
/// а згорнуті картки лишають смужку «Зал · Далі» з кнопкою «Екрани».
final class Shell {

    static final class Tab {
        final int icon;
        final String title;

        Tab(int icon, String title) {
            this.icon = icon;
            this.title = title;
        }
    }

    interface Host {
        void onTab(int index);
        void onSettings();
        /// Дотик до стану зв'язку вгорі.
        void onStatus();
        void onPrev();
        void onNext();
        void onShow();
        void onHide();
    }

    private final Activity a;
    private final Host host;
    private final Settings settings;
    private final List<Tab> tabs = new ArrayList<>();

    boolean wide, stack;
    int active;
    /// Розділ, на якому зараз стоїть сама програма на комп'ютері (−1 — не показувати):
    /// позначається зеленою цяткою.
    int marked = -1;

    FrameLayout content;
    TextView showBtn, hideBtn;
    private LinearLayout nav, monitorsBox;
    private TextView statusPill, banner, stripLive, stripNext, fold;
    private View strip, stripSpacer;
    private final Runnable hideBanner = () -> note("");

    Shell(Activity activity, Host host) {
        a = activity;
        this.host = host;
        settings = new Settings(activity);
    }

    void tab(int icon, String title) { tabs.add(new Tab(icon, title)); }

    /// Широка розкладка (планшет, телефон лежачи): розділи ліворуч, зал праворуч.
    static boolean wide(Activity a) {
        DisplayMetrics m = a.getResources().getDisplayMetrics();
        float w = m.widthPixels / m.density, h = m.heightPixels / m.density;
        return w >= 640 && w > h * 1.15f;
    }

    static float heightDp(Activity a) {
        DisplayMetrics m = a.getResources().getDisplayMetrics();
        return m.heightPixels / m.density;
    }

    /// Скласти вікно. `tools` — плитки під кнопками показу (плитку «Екрани» каркас додає сам),
    /// `extras` — кнопки-значки у верхній смузі перед «Налаштуваннями».
    View build(String name, TextView[] tools, View... extras) {
        wide = wide(a);
        stack = wide && heightDp(a) >= 600;
        LinearLayout root = Ui.col(a);
        root.setBackgroundColor(Ui.BG);
        root.setFitsSystemWindows(true);
        content = new FrameLayout(a);
        nav = wide ? Ui.col(a) : Ui.row(a);
        nav.setBackgroundColor(Ui.RAIL);
        LinearLayout stage = buildStage(tools);

        root.addView(topBar(name, extras), Ui.lp(Ui.FILL, Ui.dp(52), 0));
        // Повідомлення (зв'язок, хід надсилання) — плашкою ПОВЕРХ вікна, внизу, а не
        // смугою у розкладці: смуга зсувала все вниз, і картка залу посеред указки
        // з'їжджала з-під пальця.
        FrameLayout area = new FrameLayout(a);
        banner = Ui.label(a, "", 13.5f, Ui.TEXT);
        banner.setBackground(Ui.outlined(0xF21D2531, Ui.alpha(Ui.ACCENT, 0x90), 14));
        banner.setPadding(Ui.dp(16), Ui.dp(10), Ui.dp(16), Ui.dp(10));
        banner.setMaxLines(3);
        banner.setEllipsize(TextUtils.TruncateAt.END);
        banner.setElevation(Ui.dp(6));
        banner.setVisibility(View.GONE);
        banner.setOnClickListener(v -> note(""));
        if (wide) {
            LinearLayout body = Ui.row(a);
            ScrollView rail = new ScrollView(a);
            rail.setBackgroundColor(Ui.RAIL);
            rail.setVerticalScrollBarEnabled(false);
            rail.addView(nav);
            body.addView(rail, Ui.lp(Ui.dp(86), Ui.FILL, 0));
            // Телефон лежачи: блок показу ширший, ніж на планшеті, — інакше підписи кнопок не вміщаються.
            body.addView(content, Ui.lp(0, Ui.FILL, stack ? 1.5f : 1.2f));
            stage.setBackgroundColor(0xFF0E1218);
            body.addView(stage, Ui.lp(0, Ui.FILL, 1f));
            area.addView(body, Ui.fill());
        } else {
            LinearLayout body = Ui.col(a);
            body.addView(stage, Ui.lp(Ui.FILL, Ui.WRAP, 0));
            body.addView(content, Ui.lp(Ui.FILL, 0, 1));
            View edge = new View(a);
            edge.setBackgroundColor(Ui.LINE);
            body.addView(edge, Ui.lp(Ui.FILL, Ui.dp(1), 0));
            body.addView(nav, Ui.lp(Ui.FILL, Ui.dp(62), 0));
            area.addView(body, Ui.fill());
        }
        FrameLayout.LayoutParams under = new FrameLayout.LayoutParams(Ui.FILL, Ui.WRAP, Gravity.BOTTOM);
        int side = Ui.dp(12);
        under.setMargins(side, 0, side, Ui.dp(wide ? 12 : 62 + 10));
        if (wide) {
            // Лише над колонкою вмісту: плитки під залом праворуч лишаються відкритими.
            int body = a.getResources().getDisplayMetrics().widthPixels - Ui.dp(86);
            float content = stack ? 1.5f : 1.2f;
            under.leftMargin = Ui.dp(86 + 12);
            under.rightMargin = Math.round(body / (content + 1f)) + Ui.dp(12);
        }
        area.addView(banner, under);
        root.addView(area, Ui.lp(Ui.FILL, 0, 1));
        fillNav();
        return root;
    }

    /// Верхня смуга: знак програми, стан зв'язку й «Налаштування».
    private View topBar(String appName, View[] extras) {
        LinearLayout bar = Ui.row(a);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(14), 0, Ui.dp(6), 0);
        ImageView mark = Ui.image(a, R.drawable.ic_bible, 0xFFFFFFFF, 18);
        mark.setBackground(Ui.gradient(Ui.ACCENT, Ui.ACCENT2, 9));
        bar.addView(mark, Ui.lp(Ui.dp(30), Ui.dp(30), 0));
        TextView name = Ui.label(a, appName, 19, Ui.TEXT);
        name.setTypeface(Typeface.DEFAULT_BOLD);
        name.setMaxLines(1);
        name.setPadding(Ui.dp(10), 0, Ui.dp(10), 0);
        bar.addView(name, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        FrameLayout room = new FrameLayout(a);
        statusPill = Ui.label(a, "", 12.5f, Ui.DIM);
        statusPill.setTypeface(Ui.MEDIUM);
        statusPill.setMaxLines(1);
        statusPill.setEllipsize(TextUtils.TruncateAt.END);
        statusPill.setGravity(Gravity.CENTER_VERTICAL);
        statusPill.setPadding(Ui.dp(12), 0, Ui.dp(12), 0);
        statusPill.setClickable(true);
        statusPill.setFocusable(true);
        statusPill.setOnClickListener(v -> host.onStatus());
        room.addView(statusPill, new FrameLayout.LayoutParams(Ui.WRAP, Ui.dp(32), Gravity.END | Gravity.CENTER_VERTICAL));
        bar.addView(room, Ui.lp(0, Ui.FILL, 1, 0, 0, 4, 0));
        if (extras != null) for (View extra : extras) bar.addView(extra, Ui.lp(Ui.dp(46), Ui.dp(46), 0));
        ImageView gear = Ui.iconButton(a, R.drawable.ic_settings, 0x00000000, host::onSettings);
        gear.setContentDescription(Lang.t("Налаштування", "Settings"));
        Ui.explain(gear, Lang.t("Налаштування: підключення, указка, масштаб, мова, оновлення", "Settings: connection, pointer, scale, language, updates"));
        bar.addView(gear, Ui.lp(Ui.dp(46), Ui.dp(46), 0));
        status(statusText, statusColor);
        return bar;
    }

    private String statusText = "";
    private int statusColor = Ui.DIM;

    /// Стан зв'язку у верхній смузі: зелений — на зв'язку, бурштиновий — з'єднуюся, червоний — немає.
    void status(String text, int color) {
        statusText = text == null ? "" : text;
        statusColor = color;
        if (statusPill == null) return;
        statusPill.setText(Ui.withIcon(a, R.drawable.ic_wifi, color, 15, statusText));
        statusPill.setTextColor(color);
        statusPill.setBackground(Ui.ripple(Ui.round(color == Ui.DIM ? Ui.CARD2 : Ui.alpha(color, 0x26), 16), 16));
        statusPill.setContentDescription(statusText);
    }

    /// Смужка під верхньою смугою: хід надсилання, помилка, порада. `sticky` — лишається,
    /// доки її не замінять чи не приберуть; інакше сама зникає за шість секунд.
    void note(String text, boolean sticky) {
        if (banner == null) return;
        banner.removeCallbacks(hideBanner);
        boolean has = text != null && !text.isEmpty();
        banner.setText(has ? text : "");
        banner.setVisibility(has ? View.VISIBLE : View.GONE);
        if (has && !sticky) banner.postDelayed(hideBanner, 6000);
    }

    void note(String text) { note(text, false); }

    // MARK: Блок показу

    private LinearLayout buildStage(TextView[] tools) {
        LinearLayout stage = Ui.col(a);
        stage.setPadding(Ui.dp(10), Ui.dp(2), Ui.dp(10), Ui.dp(8));
        monitorsBox = stack ? Ui.col(a) : Ui.row(a);
        if (stack) monitorsBox.setGravity(Gravity.CENTER_HORIZONTAL);
        // Обидва варіанти в розкладці, видно один (applyFold): картки або смужка «Зал · Далі».
        stage.addView(monitorsBox, stack ? Ui.lp(Ui.FILL, 0, 1) : Ui.lp(Ui.FILL, Ui.WRAP, 0));
        strip = foldedStrip();
        stage.addView(strip, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 4, 0, 8));
        stripSpacer = new View(a);
        if (stack) stage.addView(stripSpacer, Ui.lp(Ui.FILL, 0, 1));

        // Показати / Сховати і крок назад-уперед.
        LinearLayout actions = Ui.row(a);
        actions.setGravity(Gravity.CENTER_VERTICAL);
        ImageView prev = Ui.iconButton(a, R.drawable.ic_left, Ui.CARD2, host::onPrev);
        prev.setContentDescription(Lang.t("Назад", "Back"));
        Ui.explain(prev, Lang.t("Попередній вірш, куплет чи слайд", "Previous verse, part or slide"));
        int arrow = wide && !stack ? 44 : 52;
        actions.addView(prev, Ui.lp(Ui.dp(arrow), Ui.dp(54), 0));
        showBtn = Ui.primary(a, R.drawable.ic_play, Lang.t("Показати", "Show"), host::onShow);
        showBtn.setAllCaps(true);
        showBtn.setLetterSpacing(0.04f);
        showBtn.setMaxLines(1);
        showBtn.setPadding(Ui.dp(6), 0, Ui.dp(6), 0);
        fit(showBtn, 11, 16);
        Ui.explain(showBtn, Lang.t("Вивести в зал те, що в передпоказі", "Send the preview to the hall"));
        actions.addView(showBtn, Ui.lp(0, Ui.dp(54), 1.6f, 6, 0, 0, 0));
        hideBtn = Ui.button(a, R.drawable.ic_close, Lang.t("Сховати", "Hide"), Ui.CARD2, host::onHide);
        hideBtn.setMaxLines(1);
        hideBtn.setPadding(Ui.dp(4), 0, Ui.dp(4), 0);
        fit(hideBtn, 10, 14);
        Ui.explain(hideBtn, Lang.t("Прибрати слайд із залу — фон лишається", "Remove the slide from the hall — the background stays"));
        actions.addView(hideBtn, Ui.lp(0, Ui.dp(54), 1f, 6, 0, 6, 0));
        ImageView next = Ui.iconButton(a, R.drawable.ic_right, Ui.CARD2, host::onNext);
        next.setContentDescription(Lang.t("Далі", "Next"));
        Ui.explain(next, Lang.t("Наступний вірш, куплет чи слайд", "Next verse, part or slide"));
        actions.addView(next, Ui.lp(Ui.dp(arrow), Ui.dp(54), 0));
        stage.addView(actions, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 2, 0, 8));

        // Ряд плиток: усе видно одразу, без прокрутки.
        fold = Ui.tool(a, R.drawable.ic_up, Lang.t("Екрани", "Screens"), this::toggleMonitors);
        Ui.explain(fold, Lang.t("Згорнути чи розгорнути картки «Зал» і «Далі» — коли потрібне місце для списку",
                               "Fold or unfold the Hall and Next cards — when the list needs room"));
        View[] all = new View[tools.length + 1];
        System.arraycopy(tools, 0, all, 0, tools.length);
        all[tools.length] = fold;
        // До п'яти плиток — один ряд; більше на телефоні — два ряди (вісім в один ряд не читаються).
        int perRow = wide || all.length <= 5 ? all.length : (all.length + 1) / 2;
        for (int from = 0; from < all.length; from += perRow) {
            LinearLayout line = Ui.row(a);
            int to = Math.min(all.length, from + perRow);
            for (int i = from; i < to; i++) {
                line.addView(all[i], Ui.lp(0, Ui.dp(wide ? 56 : 52), 1, i == from ? 0 : 3, 0, i == to - 1 ? 0 : 3, 0));
            }
            stage.addView(line, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, from == 0 ? 0 : 6, 0, 0));
        }
        applyFold();
        return stage;
    }

    /// Підпис кнопки зменшується, а не обрізається, коли блок показу вузький (телефон лежачи).
    private static void fit(TextView button, int minSp, int maxSp) {
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            button.setEllipsize(null);
            button.setAutoSizeTextTypeUniformWithConfiguration(minSp, maxSp, 1, android.util.TypedValue.COMPLEX_UNIT_SP);
        }
    }

    /// Поставити картки в блок показу: одну велику (слайд презентації) або дві («Далі» й «Зал»).
    void cards(SlideCard... cards) {
        monitorsBox.removeAllViews();
        for (int i = 0; i < cards.length; i++) {
            View v = cards[i].view;
            if (v.getParent() != null) ((ViewGroup) v.getParent()).removeView(v);
            boolean first = i == 0, last = i == cards.length - 1;
            // Стовпчиком картки ділять висоту, що лишилась над кнопками, і тримають свої
            // пропорції — нічого не обрізається; рядом — ділять ширину.
            if (stack) {
                monitorsBox.addView(v, Ui.lp(Ui.WRAP, 0, 1, 0, 4, 0, last ? 6 : 4));
            } else {
                // Висока картка (слайд 4:3, сторінка PDF) не має права виштовхнути кнопки й список
                // за край: телефон лежачи — не вища за те, що лишається над кнопками й плитками;
                // телефон стоячи — не вища за 38 % екрана.
                float h = heightDp(a);
                cards[i].frame.cap(Ui.dp(wide ? Math.max(90f, h - 252f) : h * 0.38f));
                monitorsBox.addView(v, Ui.lp(0, Ui.WRAP, 1, first ? 0 : 4, 4, last ? 0 : 4, 6));
            }
        }
    }

    boolean folded() { return !settings.monitors(); }

    private void applyFold() {
        if (monitorsBox == null || strip == null) return;
        boolean f = folded();
        monitorsBox.setVisibility(f ? View.GONE : View.VISIBLE);
        strip.setVisibility(f ? View.VISIBLE : View.GONE);
        stripSpacer.setVisibility(f ? View.VISIBLE : View.GONE);
        fold.setTag(f ? R.drawable.ic_down : R.drawable.ic_up);
        Ui.toolState(fold, Lang.t("Екрани", "Screens"), f, Ui.ACCENT);
    }

    /// Згорнути чи розгорнути картки — коли на малому екрані потрібне місце для списку.
    private void toggleMonitors() {
        settings.setMonitors(folded());
        applyFold();
    }

    /// Смужка замість згорнутих карток: що в залі, що далі — і «Екрани ▾», щоб розгорнути.
    private View foldedStrip() {
        LinearLayout box = Ui.row(a);
        box.setGravity(Gravity.CENTER_VERTICAL);
        box.setPadding(Ui.dp(10), Ui.dp(6), Ui.dp(6), Ui.dp(6));
        box.setBackground(Ui.pressable(Ui.CARD, 12));
        box.setClickable(true);
        box.setFocusable(true);
        box.setOnClickListener(v -> toggleMonitors());
        LinearLayout texts = Ui.col(a);
        stripLive = Ui.label(a, "", 12.5f, Ui.TEXT);
        stripLive.setMaxLines(1);
        stripLive.setEllipsize(TextUtils.TruncateAt.END);
        stripNext = Ui.label(a, "", 12, Ui.DIM);
        stripNext.setMaxLines(1);
        stripNext.setEllipsize(TextUtils.TruncateAt.END);
        texts.addView(stripLive);
        texts.addView(stripNext);
        box.addView(texts, Ui.lp(0, Ui.WRAP, 1));
        TextView open = Ui.label(a, "", 12.5f, Ui.ACCENT);
        open.setText(Ui.withIcon(a, R.drawable.ic_down, Ui.ACCENT, 16, Lang.t("Екрани", "Screens")));
        open.setPadding(Ui.dp(8), 0, Ui.dp(4), 0);
        box.addView(open, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
        return box;
    }

    /// Що написати на смужці згорнутих карток.
    void strip(String live, boolean onAir, String next) {
        if (stripLive == null) return;
        stripLive.setText(Ui.withIcon(a, R.drawable.ic_black, onAir ? Ui.LIVE : Ui.DIM, 14, live));
        stripNext.setText(next);
    }

    // MARK: Розділи

    /// Розділи: на телефоні — смуга внизу, на широкому екрані — стовпчик ліворуч.
    void fillNav() {
        if (nav == null) return;
        nav.removeAllViews();
        boolean rail = nav.getOrientation() == LinearLayout.VERTICAL;
        for (int i = 0; i < tabs.size(); i++) {
            Tab tab = tabs.get(i);
            int index = i;
            boolean on = i == active;
            LinearLayout item = Ui.col(a);
            item.setGravity(Gravity.CENTER);
            item.setClickable(true);
            item.setFocusable(true);
            item.setBackground(Ui.pressable(0x00000000, 14));
            item.setContentDescription(tab.title);
            FrameLayout mark = new FrameLayout(a);
            ImageView icon = Ui.image(a, tab.icon, on ? Ui.ACCENT : Ui.DIM, 22);
            icon.setBackground(on ? Ui.round(Ui.alpha(Ui.ACCENT, 0x2E), 15) : null);
            mark.addView(icon, Ui.fill());
            if (i == marked) {
                View dot = new View(a);
                dot.setBackground(Ui.round(Ui.GREEN, 4));
                FrameLayout.LayoutParams dp = new FrameLayout.LayoutParams(Ui.dp(8), Ui.dp(8), Gravity.TOP | Gravity.END);
                dp.setMargins(0, Ui.dp(1), Ui.dp(rail ? 8 : 4), 0);
                mark.addView(dot, dp);
            }
            item.addView(mark, Ui.lp(Ui.dp(rail ? 56 : 46), Ui.dp(30), 0));
            TextView t = Ui.label(a, tab.title, rail ? 11.5f : 10.5f, on ? Ui.TEXT : Ui.DIM);
            t.setTypeface(on ? Ui.MEDIUM : Typeface.DEFAULT);
            t.setMaxLines(1);
            t.setGravity(Gravity.CENTER);
            t.setPadding(0, Ui.dp(3), 0, 0);
            item.addView(t, Ui.lp(Ui.FILL, Ui.WRAP, 0));
            item.setOnClickListener(v -> host.onTab(index));
            if (rail) nav.addView(item, Ui.lp(Ui.FILL, Ui.dp(66), 0, 4, 2, 4, 2));
            else nav.addView(item, Ui.lp(0, Ui.FILL, 1, 1, 3, 1, 3));
        }
    }

    /// Показати розділ: підсвітити його в переліку й поставити його вид у вікно.
    void open(int index, View v) {
        View focus = a.getCurrentFocus();
        if (focus instanceof EditText) Ui.hideKeyboard(focus);
        boolean changed = active != index || content.getChildCount() == 0 || content.getChildAt(0) != v;
        active = index;
        fillNav();
        if (!changed) return;
        ViewGroup parent = (ViewGroup) v.getParent();
        if (parent != null) parent.removeView(v);
        content.removeAllViews();
        content.addView(v, Ui.fill());
        v.setAlpha(0f);
        v.animate().alpha(1f).setDuration(140).start();
    }

    /// Позначити розділ, на якому стоїть програма.
    void mark(int index) {
        if (marked == index) return;
        marked = index;
        fillNav();
    }
}
