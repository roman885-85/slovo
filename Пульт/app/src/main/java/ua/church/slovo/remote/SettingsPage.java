package ua.church.slovo.remote;

import android.app.Activity;
import android.app.Dialog;
import android.content.Intent;
import android.graphics.RectF;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/// «Налаштування» пульта й планшета — сторінкою з розділами-картками, як у
/// «Слові» для Android, замість меню ⋮ / ☰, де все лежало одним списком.
///
/// Розділи: підключення, керування, указка, вигляд (масштаб, положення
/// екрана, мова), програма (ресурси, оновлення, скидання). У планшета до них
/// додаються «Мій перегляд», підказки й план проповіді.
final class SettingsPage {

    interface Host {
        /// Змінилося те, що вікно має врахувати одразу: екран не гасити, указка, підказки, мій перегляд.
        void settingsChanged();
        void resetZoom();
        /// Стан зв'язку словами — під назвою комп'ютера.
        String linkState();
        /// Відкрити план проповіді (лише планшет; пульт нічого не робить).
        void openSermon();
    }

    private SettingsPage() { }

    static void show(Activity a, Host host) {
        Settings s = new Settings(a);
        boolean tablet = UiScale.tabletApp(a);
        Form f = new Form(a);
        Dialog[] page = new Dialog[1];
        Runnable close = () -> { if (page[0] != null) page[0].dismiss(); };

        f.heading(Lang.t("Підключення", "Connection"));
        f.entry(R.drawable.ic_wifi, s.name().isEmpty() ? s.host() : s.name(),
            () -> s.host() + ":" + s.port() + (host.linkState().isEmpty() ? "" : "\n" + host.linkState()),
            () -> {
                close.run();
                a.startActivity(new Intent(a, ConnectActivity.class));
                a.finish();
            });
        f.note(Lang.t("Дотик — інший комп'ютер, адреса чи PIN.", "Tap to pick another computer, address or PIN."));

        f.heading(Lang.t("Керування", "Control"));
        if (!tablet) {
            f.toggle(R.drawable.ic_volume, a.getString(R.string.menu_volume_keys), s::volumeKeys,
                () -> s.setVolumeKeys(!s.volumeKeys()), null);
            f.toggle(R.drawable.ic_repeat, a.getString(R.string.menu_volume_reversed), s::volumeReversed,
                () -> s.setVolumeReversed(!s.volumeReversed()), s::volumeKeys);
        }
        f.toggle(R.drawable.ic_eye, a.getString(R.string.menu_keep_awake), s::keepAwake, () -> {
            s.setKeepAwake(!s.keepAwake());
            host.settingsChanged();
        }, null);

        f.heading(a.getString(R.string.pointer_title));
        f.row(R.drawable.ic_pointer, Lang.t("Колір, розмір, яскравість", "Colour, size, brightness"),
            () -> Math.round(s.pointerSize() * 100) + " % · " + Math.round(s.pointerOpacity() * 100) + " %",
            () -> pointer(a, () -> {
                host.settingsChanged();
                f.refresh();
            }));
        f.row(R.drawable.ic_refresh, a.getString(R.string.menu_zoom_off), null, () -> {
            host.resetZoom();
            Ui.toast(a, Lang.t("Наближення знято", "Zoom removed"));
        });
        f.note(Lang.t("Палець по картинці залу — указка на стіні. Двома пальцями — наближення, подвійний дотик повертає вихідний вигляд.",
                      "A finger on the hall picture is the pointer on the wall. Two fingers zoom in, a double tap resets the view."));

        f.heading(Lang.t("Вигляд", "Appearance"));
        if (tablet) {
            f.row(R.drawable.ic_palette, Lang.t("Мій перегляд", "My view"),
                () -> s.previewText() ? Lang.t("текстом", "as text") : Lang.t("як у залі", "as in the hall"),
                () -> view(a, () -> {
                    host.settingsChanged();
                    f.refresh();
                }));
            f.toggle(R.drawable.ic_help, Lang.t("Підказки на екрані", "On-screen hints"), s::hints, () -> {
                s.setHints(!s.hints());
                host.settingsChanged();
            }, null);
        }
        f.row(R.drawable.ic_fullscreen, Lang.t("Масштаб інтерфейсу", "Interface scale"), () -> UiScale.label(a, s.uiScale()), () -> {
            String[] labels = new String[UiScale.CHOICES.length];
            int checked = 0;
            for (int i = 0; i < UiScale.CHOICES.length; i++) {
                labels[i] = UiScale.label(a, UiScale.CHOICES[i]);
                if (Math.abs(UiScale.CHOICES[i] - s.uiScale()) < 0.01f) checked = i;
            }
            Ui.pick(a, Lang.t("Масштаб: менше — більше вміщається", "Scale: smaller fits more"), labels, checked, which -> {
                if (Math.abs(UiScale.CHOICES[which] - s.uiScale()) < 0.01f) return;
                s.setUiScale(UiScale.CHOICES[which]);
                close.run();
                a.recreate();
            });
        });
        f.row(R.drawable.ic_phone, Lang.t("Положення екрана", "Screen orientation"), () -> {
            String[] names = UiScale.orientationNames(a);
            String name = names[Math.max(0, Math.min(names.length - 1, s.orientation()))];
            int cut = name.indexOf(':');
            return cut > 0 ? name.substring(0, cut) : name;
        }, () -> Ui.pick(a, Lang.t("Положення екрана", "Screen orientation"), UiScale.orientationNames(a), s.orientation(), which -> {
            s.setOrientation(which);
            UiScale.applyOrientation(a);
            f.refresh();
        }));
        f.row(R.drawable.ic_language, "Мова / Language", () -> Lang.choiceName(a), () -> Lang.showChooser(a, close));

        f.heading(Lang.t("Програма", "Application"));
        if (tablet) {
            f.entry(R.drawable.ic_plan_add, Lang.t("План проповіді", "Sermon plan"),
                () -> Lang.t("Скласти заздалегідь, без зв'язку, і завантажити в «Слово»", "Prepare in advance, offline, and upload to Slovo"),
                () -> {
                    close.run();
                    host.openSermon();
                });
        }
        f.entry(R.drawable.ic_extension, Ui.plain(a.getString(R.string.menu_resources)).replace("…", ""),
            () -> Lang.t("Із загальної бази — у «Слово»: переклади, пісенники, фони, шаблони, шрифти",
                         "From the common catalog into Slovo: translations, songbooks, backgrounds, templates, fonts"),
            () -> a.startActivity(new Intent(a, ResourcesActivity.class)));
        f.row(R.drawable.ic_download, Ui.plain(a.getString(R.string.menu_update)).replace("…", ""),
            () -> Lang.t("версія ", "version ") + Updates.ours(a), () -> Updates.checkNow(a));
        f.row(R.drawable.ic_delete, Ui.plain(a.getString(R.string.menu_reset)).replace("…", ""), null,
            () -> Ui.confirm(a, a.getString(R.string.reset_title), a.getString(R.string.reset_message), a.getString(R.string.reset), () -> {
                s.resetPreferences();
                Ui.toast(a, a.getString(R.string.reset_done));
                close.run();
                a.recreate();
            }));

        // На планшеті рядки на всю ширину екрана читаються погано — сторінка не ширша за 760 dp, по центру.
        FrameLayout holder = new FrameLayout(a);
        int width = Math.min(a.getResources().getDisplayMetrics().widthPixels, Ui.dp(760));
        holder.addView(f.scroll(), new FrameLayout.LayoutParams(width, Ui.FILL, Gravity.CENTER_HORIZONTAL));
        page[0] = Ui.page(a, Lang.t("Налаштування", "Settings"), holder);
    }

    // MARK: Указка: колір, розмір і яскравість

    /// Кольори на вибір: помітні на будь-якому слайді. Перший — початковий,
    /// той самий, що в програмі.
    private static final int[] POINTER_COLOURS = {
        Settings.DEFAULT_POINTER_COLOUR, 0xFFFF3B30, 0xFF34C759, 0xFF3B82F6,
        0xFF22D3EE, 0xFFE040FB, 0xFFFF9500, 0xFFFFFFFF,
    };

    /// Вікно «Указка»: кольори, повзунки розміру й яскравості та жива проба плями.
    /// Те, що вибрано тут, так само світиться в залі. «Початкові» повертає жовту
    /// пляму в 14 %, не закриваючи вікна: людина бачить пробу й може ще передумати.
    static void pointer(Activity a, Runnable changed) {
        Settings settings = new Settings(a);
        final int[] chosen = { settings.pointerColour() };
        final float[] size = { settings.pointerSize() };
        final float[] opacity = { settings.pointerOpacity() };

        LinearLayout root = Ui.col(a);
        root.setPadding(Ui.dp(18), 0, Ui.dp(18), 0);
        root.addView(Ui.label(a, a.getString(R.string.pointer_colour), 13, Ui.DIM));

        // Вісім кольорів у два ряди по чотири: в один ряд на вузькому телефоні
        // крайні ховалися за краєм.
        final LinearLayout swatches = Ui.col(a);
        swatches.setGravity(Gravity.CENTER_HORIZONTAL);
        swatches.setPadding(0, Ui.dp(6), 0, Ui.dp(8));
        root.addView(swatches);

        final PointerView sample = new PointerView(a);
        FrameLayout stage = new FrameLayout(a);
        stage.setBackground(Ui.round(0xFF4A5568, 12));
        stage.setClipToOutline(true);
        stage.addView(sample, Ui.fill());

        final TextView sizeLabel = Ui.label(a, "", 13, Ui.DIM);
        final int minPercent = Math.round(Settings.MIN_POINTER_SIZE * 100);
        final int maxPercent = Math.round(Settings.MAX_POINTER_SIZE * 100);
        final SeekBar seek = Ui.seek(a, maxPercent - minPercent);

        // Яскравість — другий повзунок: у світлому залі пляма має бути
        // щільнішою, у темному — ледь помітною.
        final TextView brightLabel = Ui.label(a, "", 13, Ui.DIM);
        final int minBright = Math.round(Settings.MIN_POINTER_OPACITY * 100);
        final int maxBright = Math.round(Settings.MAX_POINTER_OPACITY * 100);
        final SeekBar bright = Ui.seek(a, maxBright - minBright);

        final List<View> swatchViews = new ArrayList<>();
        Runnable refresh = () -> {
            for (int i = 0; i < swatchViews.size(); i++) {
                int colour = POINTER_COLOURS[i];
                GradientDrawable circle = new GradientDrawable();
                circle.setShape(GradientDrawable.OVAL);
                circle.setColor(colour);
                circle.setStroke(Ui.dp(colour == chosen[0] ? 3 : 1), colour == chosen[0] ? Ui.ACCENT : 0x66FFFFFF);
                swatchViews.get(i).setBackground(circle);
            }
            int percent = Math.round(size[0] * 100);
            sizeLabel.setText(a.getString(R.string.pointer_size, percent));
            if (seek.getProgress() != percent - minPercent) seek.setProgress(percent - minPercent);
            int shine = Math.round(opacity[0] * 100);
            brightLabel.setText(a.getString(R.string.pointer_brightness, shine));
            if (bright.getProgress() != shine - minBright) bright.setProgress(shine - minBright);
            sample.setLook(chosen[0], size[0], opacity[0]);
            sample.show(0.5f, 0.5f);
        };

        LinearLayout row = null;
        for (int i = 0; i < POINTER_COLOURS.length; i++) {
            final int colour = POINTER_COLOURS[i];
            if (i % 4 == 0) {
                row = Ui.row(a);
                swatches.addView(row, Ui.lp(Ui.WRAP, Ui.WRAP, 0));
            }
            View swatch = new View(a);
            swatch.setOnClickListener(v -> {
                chosen[0] = colour;
                refresh.run();
            });
            row.addView(swatch, Ui.lp(Ui.dp(44), Ui.dp(44), 0, 8, 4, 8, 4));
            swatchViews.add(swatch);
        }

        root.addView(sizeLabel);
        root.addView(seek, Ui.lp(Ui.FILL, Ui.dp(40), 0));
        root.addView(brightLabel);
        root.addView(bright, Ui.lp(Ui.FILL, Ui.dp(40), 0));
        root.addView(stage, Ui.lp(Ui.FILL, Ui.dp(110), 0, 0, 4, 0, 0));
        stage.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> sample.setImageRect(new RectF(0, 0, r - l, b - t)));

        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser) return;
                size[0] = (progress + minPercent) / 100f;
                refresh.run();
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) { }

            @Override
            public void onStopTrackingTouch(SeekBar bar) { }
        });
        bright.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser) return;
                opacity[0] = (progress + minBright) / 100f;
                refresh.run();
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) { }

            @Override
            public void onStopTrackingTouch(SeekBar bar) { }
        });
        refresh.run();

        Dialog[] holder = new Dialog[1];
        LinearLayout buttons = Ui.row(a);
        buttons.setPadding(0, Ui.dp(14), 0, Ui.dp(2));
        buttons.addView(Ui.button(a, a.getString(R.string.pointer_defaults), Ui.CARD2, () -> {
            chosen[0] = Settings.DEFAULT_POINTER_COLOUR;
            size[0] = Settings.DEFAULT_POINTER_SIZE;
            opacity[0] = Settings.DEFAULT_POINTER_OPACITY;
            refresh.run();
        }), Ui.lp(0, Ui.dp(50), 1, 0, 0, 4, 0));
        buttons.addView(Ui.button(a, a.getString(R.string.cancel), Ui.CARD2, () -> holder[0].dismiss()), Ui.lp(0, Ui.dp(50), 1, 4, 0, 4, 0));
        buttons.addView(Ui.primary(a, 0, a.getString(R.string.done), () -> {
            settings.setPointer(chosen[0], size[0], opacity[0]);
            holder[0].dismiss();
            if (changed != null) changed.run();
        }), Ui.lp(0, Ui.dp(50), 1, 4, 0, 0, 0));
        root.addView(buttons);
        holder[0] = Ui.sheet(a, a.getString(R.string.pointer_title), root);
    }

    // MARK: Мій перегляд (планшет)

    /// «Мій перегляд»: зал на планшеті — картинкою, точно як на стіні, або
    /// текстом у своєму оформленні й розмірі. Діє одразу.
    static void view(Activity a, Runnable changed) {
        Settings s = new Settings(a);
        LinearLayout box = Ui.col(a);
        box.setPadding(Ui.dp(18), 0, Ui.dp(18), 0);

        TextView asHall = Ui.chip(a, R.drawable.ic_image, Lang.t("Як у залі — картинкою", "As in the hall — a picture"), null);
        TextView asText = Ui.chip(a, R.drawable.ic_text, Lang.t("Текстом — зручно читати", "As text — easy to read"), null);
        String[] keys = { "dark", "light", "sepia" };
        String[] titles = { Lang.t("Темне", "Dark"), Lang.t("Світле", "Light"), Lang.t("Сепія", "Sepia") };
        TextView[] themes = new TextView[keys.length];
        TextView sizeLabel = Ui.label(a, "", 13, Ui.DIM);
        SeekBar size = Ui.seek(a, 80 - 14);
        size.setProgress(Math.round(s.previewSize()) - 14);

        Runnable paint = () -> {
            Ui.chipState(asHall, Lang.t("Як у залі — картинкою", "As in the hall — a picture"), !s.previewText(), Ui.ACCENT);
            Ui.chipState(asText, Lang.t("Текстом — зручно читати", "As text — easy to read"), s.previewText(), Ui.ACCENT);
            for (int i = 0; i < keys.length; i++) Ui.chipState(themes[i], titles[i], keys[i].equals(s.previewTheme()), Ui.ACCENT);
            sizeLabel.setText(Lang.t("Розмір тексту: ", "Text size: ") + Math.round(s.previewSize()));
            for (TextView theme : themes) theme.setAlpha(s.previewText() ? 1f : 0.45f);
            size.setAlpha(s.previewText() ? 1f : 0.45f);
        };
        asHall.setOnClickListener(v -> {
            s.setPreview(false, s.previewTheme(), s.previewSize());
            paint.run();
            changed.run();
        });
        asText.setOnClickListener(v -> {
            s.setPreview(true, s.previewTheme(), s.previewSize());
            paint.run();
            changed.run();
        });
        box.addView(asHall, Ui.lp(Ui.FILL, Ui.dp(44), 0, 0, 0, 0, 6));
        box.addView(asText, Ui.lp(Ui.FILL, Ui.dp(44), 0, 0, 0, 0, 12));

        LinearLayout row = Ui.row(a);
        for (int i = 0; i < keys.length; i++) {
            String key = keys[i];
            themes[i] = Ui.chip(a, 0, titles[i], null);
            themes[i].setOnClickListener(v -> {
                s.setPreview(s.previewText(), key, s.previewSize());
                paint.run();
                changed.run();
            });
            row.addView(themes[i], Ui.lp(0, Ui.dp(40), 1, i == 0 ? 0 : 3, 0, i == keys.length - 1 ? 0 : 3, 0));
        }
        box.addView(row);
        box.addView(sizeLabel, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 14, 0, 0));
        box.addView(size, Ui.lp(Ui.FILL, Ui.dp(40), 0));
        size.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar bar, int value, boolean user) {
                if (!user) return;
                s.setPreview(s.previewText(), s.previewTheme(), 14 + value);
                paint.run();
                changed.run();
            }

            @Override
            public void onStartTrackingTouch(SeekBar bar) { }

            @Override
            public void onStopTrackingTouch(SeekBar bar) { }
        });
        TextView note = Ui.label(a, Lang.t("Картинки й презентації завжди видно такими, як на стіні.",
                                           "Pictures and presentations always look as on the wall."), 13, Ui.DIM);
        box.addView(note, Ui.lp(Ui.FILL, Ui.WRAP, 0, 0, 6, 0, 0));
        Dialog[] holder = new Dialog[1];
        box.addView(Ui.button(a, a.getString(R.string.done), Ui.CARD2, () -> holder[0].dismiss()), Ui.lp(Ui.FILL, Ui.dp(50), 0, 0, 14, 0, 0));
        paint.run();
        holder[0] = Ui.sheet(a, Lang.t("Мій перегляд", "My view"), box);
    }
}
