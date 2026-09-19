package ua.church.slovo.remote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

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

    private Button kindButton, sourceButton, installButton;
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
        applyOverrideConfiguration(Lang.override(base, null));
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        settings = new Settings(this);
        if (!settings.hasHost()) { finish(); return; }
        api = new Api(settings.host(), settings.port(), settings.pin());
        setTitle(R.string.resources_title);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(8), dp(8), dp(8), dp(8));

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        kindButton = button(getString(R.string.resources_kind_bible), v -> chooseKind());
        sourceButton = button(getString(R.string.resources_source), v -> chooseSource());
        head.addView(kindButton, weight());
        head.addView(sourceButton, weight());
        root.addView(head, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                         ViewGroup.LayoutParams.WRAP_CONTENT));

        search = new EditText(this);
        search.setHint(R.string.resources_search);
        search.setSingleLine(true);
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void afterTextChanged(Editable s) { loadLater(); }
        });
        root.addView(search);

        status = new TextView(this);
        status.setTextColor(Color.parseColor("#9AA4B2"));
        status.setPadding(0, dp(4), 0, dp(4));
        root.addView(status);

        list = new ListView(this);
        list.setDivider(null);
        LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1);
        root.addView(list, listParams);
        list.setAdapter(adapter);
        list.setOnItemClickListener((parent, view, position, id) -> toggle(position));

        installButton = button(getString(R.string.resources_install), v -> install());
        installButton.setEnabled(false);
        root.addView(installButton, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                                  ViewGroup.LayoutParams.WRAP_CONTENT));
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

    private LinearLayout.LayoutParams weight() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
    }

    private Button button(String text, View.OnClickListener click) {
        Button button = new Button(this, null, 0, R.style.SmallButton);
        button.setText(text);
        button.setAllCaps(false);
        button.setOnClickListener(click);
        return button;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
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
        sourceButton.setText(at >= 0 ? sourceNames.get(at) : getString(R.string.resources_source));
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
                    installButton.setEnabled(false);
                    adapter.notifyDataSetChanged();
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
        final String[] ids = { "bible", "songbook", "backgrounds", "templates", "fonts", "web" };
        final String[] names = {
            getString(R.string.resources_kind_bible), getString(R.string.resources_kind_songbook),
            getString(R.string.resources_kind_backgrounds), getString(R.string.resources_kind_templates),
            getString(R.string.resources_kind_fonts), getString(R.string.resources_kind_web),
        };
        new AlertDialog.Builder(this)
            .setTitle(R.string.resources_kind)
            .setItems(names, (dialog, which) -> {
                kind = ids[which];
                kindButton.setText(names[which]);
                // Джерело може не давати цього роду — тоді беремо своє.
                int at = sourceIds.indexOf(source);
                if (at < 0 || !sourceKinds.get(at).contains(kind)) {
                    source = "slovo";
                    showSourceName();
                }
                load();
            })
            .show();
    }

    private void chooseSource() {
        final List<String> ids = new ArrayList<>(), names = new ArrayList<>();
        for (int i = 0; i < sourceIds.size(); i++) {
            if (!sourceKinds.get(i).contains(kind)) continue;
            ids.add(sourceIds.get(i));
            names.add(sourceNames.get(i));
        }
        if (ids.isEmpty()) return;
        new AlertDialog.Builder(this)
            .setTitle(R.string.resources_source)
            .setItems(names.toArray(new String[0]), (dialog, which) -> {
                source = ids.get(which);
                sourceButton.setText(names.get(which));
                load();
            })
            .show();
    }

    private void toggle(int position) {
        if (position < 0 || position >= items.size()) return;
        Item item = items.get(position);
        if (!chosen.remove(item.id)) chosen.add(item.id);
        installButton.setEnabled(!chosen.isEmpty());
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
        installButton.setEnabled(false);
        status.setText(R.string.resources_starting);
        work.execute(() -> {
            try {
                api.command("resource-install", body);
                main.post(this::watch);
            } catch (Exception error) {
                final String why = Api.describe(error);
                main.post(() -> {
                    status.setText(getString(R.string.resources_failed, why));
                    installButton.setEnabled(true);
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
                            installButton.setEnabled(true);
                            String note = failures != null && failures.length() > 0
                                ? getString(R.string.resources_partly, failures.optString(0))
                                : getString(R.string.resources_done, done);
                            status.setText(note);
                            Toast.makeText(ResourcesActivity.this, note, Toast.LENGTH_LONG).show();
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

    private final BaseAdapter adapter = new BaseAdapter() {
        @Override public int getCount() { return items.size(); }
        @Override public Object getItem(int position) { return items.get(position); }
        @Override public long getItemId(int position) { return position; }

        @Override
        public View getView(int position, View recycled, ViewGroup parent) {
            LinearLayout row;
            if (recycled instanceof LinearLayout) {
                row = (LinearLayout) recycled;
            } else {
                row = new LinearLayout(ResourcesActivity.this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setGravity(Gravity.CENTER_VERTICAL);
                row.setPadding(dp(4), dp(8), dp(4), dp(8));
                CheckBox box = new CheckBox(ResourcesActivity.this);
                box.setClickable(false);
                box.setFocusable(false);
                row.addView(box);
                LinearLayout texts = new LinearLayout(ResourcesActivity.this);
                texts.setOrientation(LinearLayout.VERTICAL);
                TextView title = new TextView(ResourcesActivity.this);
                title.setTextSize(16);
                TextView note = new TextView(ResourcesActivity.this);
                note.setTextSize(12);
                note.setTextColor(Color.parseColor("#9AA4B2"));
                texts.addView(title);
                texts.addView(note);
                row.addView(texts, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            }
            Item item = items.get(position);
            ((CheckBox) row.getChildAt(0)).setChecked(chosen.contains(item.id));
            LinearLayout texts = (LinearLayout) row.getChildAt(1);
            ((TextView) texts.getChildAt(0)).setText(item.title);
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
            ((TextView) texts.getChildAt(1)).setText(note.toString());
            return row;
        }
    };
}
