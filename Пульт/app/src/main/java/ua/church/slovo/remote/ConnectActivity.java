package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/// Екран підключення: знайдені в мережі комп'ютери й ручне введення адреси.
/// Вигляд — картки й кнопки «Слова» для Android (див. `Ui`).
public final class ConnectActivity extends Activity {

    private Settings settings;
    private Discovery discovery;
    private LinearLayout foundList;
    private TextView searchStatus;
    private EditText host;
    private EditText port;
    private EditText pin;
    private int foundCount;

    /// Мова й масштаб інтерфейсу (див. `Lang`, `UiScale`) — до того, як вікно візьме ресурси.
    @Override
    protected void attachBaseContext(android.content.Context base) {
        super.attachBaseContext(base);
        applyOverrideConfiguration(Lang.override(base, UiScale.override(base)));
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        Ui.init(this);
        UiScale.applyOrientation(this);
        settings = new Settings(this);

        LinearLayout root = Ui.col(this);
        root.setBackgroundColor(Ui.BG);
        root.setFitsSystemWindows(true);

        LinearLayout bar = Ui.row(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(14), 0, Ui.dp(10), 0);
        ImageView mark = Ui.image(this, R.drawable.ic_bible, 0xFFFFFFFF, 18);
        mark.setBackground(Ui.gradient(Ui.ACCENT, Ui.ACCENT2, 9));
        bar.addView(mark, Ui.lp(Ui.dp(30), Ui.dp(30), 0));
        TextView name = Ui.label(this, getString(R.string.app_name), 19, Ui.TEXT);
        name.setTypeface(Typeface.DEFAULT_BOLD);
        name.setMaxLines(1);
        name.setPadding(Ui.dp(10), 0, Ui.dp(10), 0);
        bar.addView(name, Ui.lp(0, Ui.WRAP, 1));
        // Двомовний підпис: його знайде і той, хто не читає поточною мовою.
        bar.addView(Ui.chip(this, R.drawable.ic_language, "Мова / Language", () -> Lang.showChooser(this)), Ui.lp(Ui.WRAP, Ui.dp(38), 0));
        root.addView(bar, Ui.lp(Ui.FILL, Ui.dp(52), 0));

        LinearLayout page = Ui.col(this);
        page.setPadding(Ui.dp(10), 0, Ui.dp(10), Ui.dp(24));
        // Не ширше за 640 dp: на планшеті поля на весь екран виглядають порожньо.
        LinearLayout centre = Ui.col(this);
        centre.setGravity(Gravity.CENTER_HORIZONTAL);
        centre.addView(page, Ui.lp(Math.min(getResources().getDisplayMetrics().widthPixels, Ui.dp(640)), Ui.WRAP, 0));
        ScrollView scroll = new ScrollView(this);
        scroll.setVerticalScrollBarEnabled(false);
        scroll.addView(centre);
        root.addView(scroll, Ui.lp(Ui.FILL, 0, 1));

        TextView title = Ui.label(this, getString(R.string.connect_title), 22, Ui.TEXT);
        title.setTypeface(Ui.MEDIUM);
        title.setPadding(Ui.dp(10), Ui.dp(10), Ui.dp(10), 0);
        page.addView(title);

        // Планшет: план проповіді складають і без підключення, тож вхід до
        // нього є й тут. У пульта для телефона екрана плану немає — рядок
        // `sermon_activity` у нього порожній, і кнопки не буде.
        String sermon = getString(R.string.sermon_activity);
        if (!sermon.isEmpty()) {
            TextView button = Ui.button(this, R.drawable.ic_plan_add, Ui.plain(getString(R.string.sermon_open)), Ui.CARD2, () -> {
                Intent intent = new Intent();
                intent.setClassName(this, sermon);
                startActivity(intent);
            });
            page.addView(button, Ui.lp(Ui.FILL, Ui.dp(50), 0, 0, 14, 0, 0));
            page.addView(Ui.hint(this, Lang.t("План складають заздалегідь, без зв'язку з програмою.", "The plan is prepared in advance, with no connection needed.")));
        }

        page.addView(heading(getString(R.string.found_title)));
        LinearLayout found = Ui.card(this);
        found.setPadding(0, Ui.dp(4), 0, Ui.dp(4));
        foundList = Ui.col(this);
        found.addView(foundList);
        searchStatus = Ui.label(this, "", 14, Ui.DIM);
        searchStatus.setLineSpacing(Ui.dp(2), 1f);
        searchStatus.setPadding(Ui.dp(16), Ui.dp(12), Ui.dp(16), Ui.dp(12));
        found.addView(searchStatus);
        page.addView(found);
        page.addView(Ui.button(this, R.drawable.ic_refresh, getString(R.string.rescan), Ui.CARD2, this::restartDiscovery),
            Ui.lp(Ui.FILL, Ui.dp(48), 0, 0, 8, 0, 0));

        page.addView(heading(getString(R.string.manual_title)));
        LinearLayout manual = Ui.card(this);
        manual.setPadding(Ui.dp(12), Ui.dp(12), Ui.dp(12), Ui.dp(12));
        host = Ui.field(this, getString(R.string.host_hint), false);
        host.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        port = Ui.field(this, getString(R.string.port_hint), false);
        port.setInputType(InputType.TYPE_CLASS_NUMBER);
        pin = Ui.field(this, getString(R.string.pin_hint), false);
        host.setText(settings.host());
        port.setText(String.valueOf(settings.port()));
        pin.setText(settings.pin());
        manual.addView(host, Ui.lp(Ui.FILL, Ui.dp(50), 0));
        LinearLayout pair = Ui.row(this);
        pair.addView(port, Ui.lp(0, Ui.dp(50), 1, 0, 8, 4, 0));
        pair.addView(pin, Ui.lp(0, Ui.dp(50), 2.2f, 4, 8, 0, 0));
        manual.addView(pair);
        manual.addView(Ui.primary(this, R.drawable.ic_wifi, getString(R.string.connect), this::connectManually),
            Ui.lp(Ui.FILL, Ui.dp(54), 0, 0, 12, 0, 0));
        page.addView(manual);

        setContentView(root);
    }

    private TextView heading(String text) {
        TextView t = Ui.heading(this, text);
        t.setPadding(Ui.dp(10), Ui.dp(20), Ui.dp(10), Ui.dp(8));
        return t;
    }

    @Override
    protected void onResume() {
        super.onResume();
        Ui.init(this);
        restartDiscovery();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (discovery != null) discovery.stop();
    }

    private void restartDiscovery() {
        if (discovery != null) discovery.stop();
        foundList.removeAllViews();
        foundCount = 0;
        searchStatus.setText(Ui.withIcon(this, R.drawable.ic_search, Ui.DIM, 16, getString(R.string.searching)));
        searchStatus.setVisibility(android.view.View.VISIBLE);
        discovery = new Discovery(this, new Discovery.Listener() {
            @Override
            public void found(String name, String address, int found) {
                foundCount++;
                searchStatus.setVisibility(android.view.View.GONE);
                foundList.addView(row(name, address, found));
            }

            @Override
            public void finished() {
                if (foundCount == 0) searchStatus.setText(getString(R.string.nothing_found));
            }
        });
        discovery.start();
    }

    /// Знайдений комп'ютер: значок, назва, адреса; дотик — підключитися.
    private LinearLayout row(String name, String address, int found) {
        LinearLayout r = Ui.row(this);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(Ui.dp(14), Ui.dp(10), Ui.dp(14), Ui.dp(10));
        r.setMinimumHeight(Ui.dp(64));
        r.setBackground(Ui.pressable(0x00000000, 12));
        r.setClickable(true);
        r.setFocusable(true);
        ImageView icon = Ui.image(this, R.drawable.ic_black, Ui.GREEN, 22);
        icon.setBackground(Ui.round(Ui.alpha(Ui.GREEN, 0x22), 12));
        r.addView(icon, Ui.lp(Ui.dp(40), Ui.dp(40), 0, 0, 0, 12, 0));
        LinearLayout texts = Ui.col(this);
        TextView title = Ui.label(this, name, 16.5f, Ui.TEXT);
        title.setTypeface(Ui.MEDIUM);
        texts.addView(title);
        texts.addView(Ui.label(this, address + ":" + found, 13, Ui.DIM));
        r.addView(texts, Ui.lp(0, Ui.WRAP, 1));
        r.addView(Ui.image(this, R.drawable.ic_right, Ui.FAINT, 20), Ui.lp(Ui.dp(22), Ui.dp(22), 0));
        r.setOnClickListener(v -> finishWith(address, found, pin.getText().toString(), name));
        return r;
    }

    private void connectManually() {
        String address = host.getText().toString().trim();
        if (address.isEmpty()) {
            Ui.toast(this, getString(R.string.host_missing));
            return;
        }
        int number;
        try {
            number = Integer.parseInt(port.getText().toString().trim());
        } catch (NumberFormatException error) {
            number = 8103;
        }
        finishWith(address, number, pin.getText().toString(), "");
    }

    private void finishWith(String address, int number, String code, String name) {
        settings.save(address, number, code, name);
        // Куди далі — каже сама програма: у пульта й планшета вікно
        // з'єднання спільне, а робочі екрани різні.
        Intent intent = new Intent();
        intent.setClassName(this, getString(R.string.work_activity));
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(intent);
        finish();
    }
}
