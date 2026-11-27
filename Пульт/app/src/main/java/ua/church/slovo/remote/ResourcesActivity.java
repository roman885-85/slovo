package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Ресурси програми з телефона: переклади, пісенники, фони, шаблони, шрифти.
///
/// Власник: «доступ к загрузке ресурсов с программы и всех источников,
/// которые есть в распоряжении программы». Список джерел і каталоги дає сама
/// програма (`/api/resources`), вона ж і завантажує: телефон лише каже, що
/// брати, і бачить хід. Так файли одразу лягають туди, де програма їх шукає,
/// і нічого не треба переносити з телефона.
public final class ResourcesActivity extends Activity {

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService work = Executors.newSingleThreadExecutor();

    private Settings settings;
    private Api api;

    private TextView kindButton, sourceButton, installButton;
    private EditText search;
    private TextView status;
    private ListView list;

    private final List<Item> items = new ArrayList<>();
    private final Set<String> chosen = new HashSet<>();
    private final List<String> sourceIds = new ArrayList<>();
    private final List<String> sourceNames = new ArrayList<>();
    private final List<List<String>> sourceKinds = new ArrayList<>();

    private String kind = "bible";
    private String source = "slovo";
    private boolean watching;

    private static final class Item {
        final String id, title, subtitle, language;
        final long size;
        final boolean installed;
        Item(String id, String title, String subtitle, String language, long size, boolean installed) {
            this.id = id; this.title = title; this.subtitle = subtitle;
            this.language = language; this.size = size; this.installed = installed;
        }
    }

    @Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        applyOverrideConfiguration(Lang.override(base, UiScale.override(base)));
    }

    /// Відкрити одразу на потрібному роді («bible», «songbook»…) — з вибору перекладу чи
    /// пісенника. Власник 27.11: «пульт тоже должен иметь возможность загружать модули и
    /// дополнения из общей базы» — каталог уже був, але лише в «Налаштуваннях»; тепер і
    /// там, де людина вибирає переклад чи пісенник («усе має бути на виду»).
    static void open(Context context, String kind) {
        android.content.Intent intent = new android.content.Intent(context, ResourcesActivity.class);
        if (kind != null) intent.putExtra("kind", kind);
        context.startActivity(intent);
    }

    private static final String[] KINDS = { "bible", "songbook", "backgrounds", "templates", "fonts", "web" };

    private String kindName(String id) {
        switch (id) {
            case "songbook": return getString(R.string.resources_kind_songbook);
            case "backgrounds": return getString(R.string.resources_kind_backgrounds);
            case "templates": return getString(R.string.resources_kind_templates);
            case "fonts": return getString(R.string.resources_kind_fonts);
            case "web": return getString(R.string.resources_kind_web);
            default: return getString(R.string.resources_kind_bible);
        }
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        String wanted = getIntent() == null ? null : getIntent().getStringExtra("kind");
        if (wanted != null && java.util.Arrays.asList(KINDS).contains(wanted)) kind = wanted;
        settings = new Settings(this);
        if (!settings.hasHost()) { finish(); return; }
        api = new Api(settings.host(), settings.port(), settings.pin());
        Ui.init(this);
        UiScale.applyOrientation(this);

        LinearLayout root = Ui.col(this);
        root.setBackgroundColor(Ui.BG);
        root.setFitsSystemWindows(true);

        LinearLayout bar = Ui.row(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(Ui.dp(6), Ui.dp(4), Ui.dp(12), Ui.dp(4));
        bar.addView(Ui.iconButton(this, R.drawable.ic_back, 0x00000000, this::finish), Ui.lp(Ui.dp(48), Ui.dp(48), 0));
        TextView title = Ui.label(this, getString(R.string.resources_title), 20, Ui.TEXT);
        title.setTypeface(Ui.MEDIUM);
        title.setMaxLines(1);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        title.setPadding(Ui.dp(8), 0, 0, 0);
        bar.addView(title, Ui.lp(0, Ui.WRAP, 1));
        root.addView(bar);

        LinearLayout head = Ui.row(this);
        head.setPadding(Ui.dp(8), 0, Ui.dp(8), 0);
        kindButton = Ui.button(this, R.drawable.ic_extension, kindName(kind), Ui.CARD2, this::chooseKind);
        sourceButton = Ui.button(this, R.drawable.ic_download, getString(R.string.resources_source), Ui.CARD2, this::chooseSource);
        kindButton.setMaxLines(1);
        sourceButton.setMaxLines(1);
        Ui.explain(kindButton, getString(R.string.resources_kind));
        Ui.explain(sourceButton, getString(R.string.resources_source));
        head.addView(kindButton, Ui.lp(0, Ui.dp(46), 1, 3));
        head.addView(sourceButton, Ui.lp(0, Ui.dp(46), 1, 3));
        root.addView(head);

        search = Ui.search(this, getString(R.string.resources_search));
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void afterTextChanged(Editable s) { loadLater(); }
        });
        root.addView(search, Ui.lp(Ui.FILL, Ui.dp(46), 0, 11, 3, 11, 3));

        status = Ui.hint(this, "");
        root.addView(status);

        list = Ui.list(this, adapter);
        root.addView(list, Ui.lp(Ui.FILL, 0, 1));
        list.setOnItemClickListener((parent, view, position, id) -> toggle(position));

        installButton = Ui.primary(this, R.drawable.ic_download, getString(R.string.resources_install), this::install);
        Ui.enable(installButton, false);
        root.addView(installButton, Ui.lp(Ui.FILL, Ui.dp(54), 0, 11, 6, 11, 10));
        setContentView(root);

        loadSources();
        load();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        watching = false;
        work.shutdownNow();
    }

    // MARK: Списки

    private void loadSources() {
        work.execute(() -> {
            try {
                JSONObject answer = api.get("/api/resources/sources");
                JSONArray all = answer.optJSONArray("sources");
                final List<String> ids = new ArrayList<>(), names = new ArrayList<>();
                final List<List<String>> kinds = new ArrayList<>();
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject one = all.optJSONObject(i);
                        if (one == null) continue;
                        ids.add(one.optString("id"));
                        names.add(one.optString("name", one.optString("id")));
                        List<String> own = new ArrayList<>();
                        JSONArray kindsJson = one.optJSONArray("kinds");
                        if (kindsJson != null) {
                            for (int k = 0; k < kindsJson.length(); k++) own.add(kindsJson.optString(k));
                        }
                        kinds.add(own);
                    }
                }
                main.post(() -> {
                    sourceIds.clear(); sourceIds.addAll(ids);
                    sourceNames.clear(); sourceNames.addAll(names);
                    sourceKinds.clear(); sourceKinds.addAll(kinds);
                    showSourceName();
                });
            } catch (Exception ignored) { }
        });
    }

    private void showSourceName() {
        int at = sourceIds.indexOf(source);
        Ui.setText(sourceButton, at >= 0 ? sourceNames.get(at) : getString(R.string.resources_source));
    }

    private Runnable pending;

    /// Пошук набирають літера за літерою — питаємо каталог, коли пальці стали.
    private void loadLater() {
        if (pending != null) main.removeCallbacks(pending);
        pending = this::load;
        main.postDelayed(pending, 400);
    }

    private void load() {
        final String q = search.getText().toString().trim();
        final String askedSource = source, askedKind = kind;
        status.setText(R.string.resources_reading);
        work.execute(() -> {
            try {
                String path = "/api/resources?source=" + askedSource + "&kind=" + askedKind;
                if (!q.isEmpty()) path += "&q=" + android.net.Uri.encode(q);
                JSONObject answer = api.get(path);
                JSONArray all = answer.optJSONArray("items");
                final List<Item> fresh = new ArrayList<>();
                if (all != null) {
                    for (int i = 0; i < all.length(); i++) {
                        JSONObject one = all.optJSONObject(i);
                        if (one == null) continue;
                        fresh.add(new Item(one.optString("id"), one.optString("title"),
                                           one.optString("subtitle", ""), one.optString("language", ""),
                                           one.optLong("size", 0), one.optBoolean("installed", false)));
                    }
                }
                final int total = answer.optInt("total", fresh.size());
                main.post(() -> {
                    items.clear();
                    items.addAll(fresh);
                    chosen.clear();
                    Ui.enable(installButton, false);
                    Ui.setText(installButton, getString(R.string.resources_install));
                    adapter.set(fresh);
                    status.setText(total > fresh.size()
                                   ? getString(R.string.resources_shown, fresh.size(), total)
                                   : getString(R.string.resources_count, fresh.size()));
                });
            } catch (Exception error) {
                final String why = Api.describe(error);
                main.post(() -> status.setText(getString(R.string.resources_failed, why)));
            }
        });
    }

    private void chooseKind() {
        final String[] ids = KINDS;
        final String[] names = new String[ids.length];
        for (int i = 0; i < ids.length; i++) names[i] = kindName(ids[i]);
        int checked = 0;
        for (int i = 0; i < ids.length; i++) if (ids[i].equals(kind)) checked = i;
        Ui.pick(this, getString(R.string.resources_kind), names, checked, which -> {
            kind = ids[which];
            Ui.setText(kindButton, names[which]);
            // Джерело може не давати цього роду — тоді беремо своє.
            int at = sourceIds.indexOf(source);
            if (at < 0 || !sourceKinds.get(at).contains(kind)) {
                source = "slovo";
                showSourceName();
            }
            load();
        });
    }

    private void chooseSource() {
        final List<String> ids = new ArrayList<>(), names = new ArrayList<>();
        for (int i = 0; i < sourceIds.size(); i++) {
            if (!sourceKinds.get(i).contains(kind)) continue;
            ids.add(sourceIds.get(i));
            names.add(sourceNames.get(i));
        }
        if (ids.isEmpty()) return;
        Ui.pick(this, getString(R.string.resources_source), names.toArray(new String[0]), ids.indexOf(source), which -> {
            source = ids.get(which);
            Ui.setText(sourceButton, names.get(which));
            load();
        });
    }

    private void toggle(int position) {
        if (position < 0 || position >= items.size()) return;
        Item item = items.get(position);
        if (!chosen.remove(item.id)) chosen.add(item.id);
        Ui.enable(installButton, !chosen.isEmpty());
        Ui.setText(installButton, getString(R.string.resources_install) + (chosen.isEmpty() ? "" : " (" + chosen.size() + ")"));
        adapter.notifyDataSetChanged();
    }

    // MARK: Завантаження

    private void install() {
        if (chosen.isEmpty()) return;
        final JSONArray ids = new JSONArray();
        for (String id : chosen) ids.put(id);
        final JSONObject body = new JSONObject();
        try {
            body.put("source", source);
            body.put("ids", ids);
        } catch (Exception ignored) { }
        Ui.enable(installButton, false);
        status.setText(R.string.resources_starting);
        work.execute(() -> {
            try {
                api.command("resource-install", body);
                main.post(this::watch);
            } catch (Exception error) {
                final String why = Api.describe(error);
                main.post(() -> {
                    status.setText(getString(R.string.resources_failed, why));
                    Ui.enable(installButton, true);
                });
            }
        });
    }

    /// Хід завантаження: програма качає й розкладає, телефон лише питає, де вона.
    private void watch() {
        if (watching) return;
        watching = true;
        final Runnable tick = new Runnable() {
            @Override public void run() {
                if (!watching) return;
                work.execute(() -> {
                    try {
                        JSONObject progress = api.get("/api/resources/progress");
                        final boolean busy = progress.optBoolean("busy", false);
                        final String title = progress.optString("title", "");
                        final int percent = progress.optInt("percent", 0);
                        final int done = progress.optInt("done", 0);
                        final int total = progress.optInt("total", 0);
                        final JSONArray failures = progress.optJSONArray("failures");
                        main.post(() -> {
                            if (busy) {
                                status.setText(getString(R.string.resources_progress, title, percent, done, total));
                                main.postDelayed(this, 1000);
                                return;
                            }
                            watching = false;
                            Ui.enable(installButton, true);
                            String note = failures != null && failures.length() > 0
                                ? getString(R.string.resources_partly, failures.optString(0))
                                : getString(R.string.resources_done, done);
                            status.setText(note);
                            Ui.toast(ResourcesActivity.this, note);
                            load();
                        });
                    } catch (Exception error) {
                        main.post(() -> main.postDelayed(this, 2000));
                    }
                });
            }
        };
        main.postDelayed(tick, 700);
    }

    // MARK: Рядки

    private final Ui.Rows<Item> adapter = new Ui.Rows<Item>() {
        @Override
        String title(Item item) { return item.title; }

        @Override
        /// Вибране до завантаження — «●» (і рядок підсвічено), уже встановлене в «Слові» — «✓»,
        /// решта — «+». Раніше встановлене теж стояло з «+», і не видно було, що воно вже є.
        String badge(Item item) { return chosen.contains(item.id) ? "●" : item.installed ? "✓" : "+"; }

        @Override
        boolean chosen(int position) { return chosen.contains(items.get(position).id); }

        @Override
        String sub(Item item) {
            StringBuilder note = new StringBuilder();
            if (!item.subtitle.isEmpty()) note.append(item.subtitle);
            if (!item.language.isEmpty()) {
                if (note.length() > 0) note.append(" · ");
                note.append(item.language);
            }
            if (item.size > 0) {
                if (note.length() > 0) note.append(" · ");
                note.append(Math.max(1, item.size / (1024 * 1024))).append(" ").append(getString(R.string.update_mb));
            }
            if (item.installed) {
                if (note.length() > 0) note.append(" · ");
                note.append(getString(R.string.resources_present));
            }
            return note.toString();
        }
    };
}
