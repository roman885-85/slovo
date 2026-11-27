package ua.church.slovo.remote;

import org.json.JSONObject;
import java.util.Arrays;

/// Перевірка справжнього Api.java на справжніх запитах до tools/fake-slovo.py.
public final class Harness {
    static int ok, bad;

    static void check(String what, Runnable step) {
        long t = System.currentTimeMillis();
        try {
            step.run();
            ok++;
            System.out.println("✓ " + what + " (" + (System.currentTimeMillis() - t) + " мс)");
        } catch (Throwable e) {
            bad++;
            Throwable c = e.getCause() != null ? e.getCause() : e;
            System.out.println("✗ " + what + ": " + c);
        }
    }

    interface Io { void run() throws Exception; }
    static Runnable io(Io body) { return () -> { try { body.run(); } catch (Exception e) { throw new RuntimeException(e); } }; }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(args[0]);
        Api api = new Api("127.0.0.1", port, "");
        JSONObject tab = new JSONObject().put("tab", "show");
        check("команда show (з тілом tab)", io(() -> api.command("show", tab)));
        check("команда next", io(() -> api.command("next", new JSONObject().put("tab", "bible"))));
        check("сторінка 3 (command з номером)", io(() -> api.command("page", 3)));
        check("фото 1 (picture)", io(() -> api.command("picture", 1)));
        check("Біблія: bible-select у зал", io(() -> api.bibleSelect(42, 3, Arrays.asList(16, 17), true)));
        check("пісня 2 (command з рядком)", io(() -> api.command("songs-book", "test")));
        check("указка ×5", io(() -> { for (int i = 0; i < 5; i++) api.pointer(0.1 * i, 0.5, "#FFD91A", 0.14, 0.45); }));
        check("указка геть", io(api::pointerOff));
        check("наближення 2×", io(() -> api.zoom(2, 0.4, 0.4)));
        check("стан: сторінка 3, фото 1, наближення 2", io(() -> {
            State s = api.state(0);
            if (s.pageIndex != 3) throw new IllegalStateException("сторінка " + s.pageIndex);
            if (!"pictures".equals(s.mode) || s.showIndex != 1) throw new IllegalStateException("режим " + s.mode + " фото " + s.showIndex);
            if (Math.abs(s.zoom - 2) > 0.01) throw new IllegalStateException("наближення " + s.zoom);
            if (s.hallSeq < 0) throw new IllegalStateException("hallSeq не прочитано");
        }));
        // Власник 27.11: «после начала показа фото невозможно отобразить документ, вместо него
        // показывается фото» — `page` у «Слові» бере сторінку з відкритого списку.
        check("сторінка PDF після фото (спершу вкладка «Презентація»)", io(() -> {
            api.command("picture", 0);
            api.presentationPage(2);
            State s = api.state(0);
            if (!"presentation".equals(s.mode) || s.pageIndex != 2) throw new IllegalStateException("режим " + s.mode + ", сторінка " + s.pageIndex);
        }));
        // Власник 27.11: «показ слайдов и текстов происходить должен исключительно по кнопке
        // показа» — дотик вибирає (`live: false`), зал міняє лише «Показати».
        check("вибрати без показу, у зал — лише «Показати»", io(() -> {
            api.presentationPage(1, true);
            String before = api.state(0).hallTitle;
            api.presentationPage(3, false);
            State s = api.state(0);
            if (s.pageIndex != 3) throw new IllegalStateException("сторінку не вибрано: " + s.pageIndex);
            if (!before.equals(s.hallTitle)) throw new IllegalStateException("зал змінився від дотику: " + s.hallTitle);
            api.choose("picture", 2);
            s = api.state(0);
            if (!"pictures".equals(s.mode) || s.showIndex != 2) throw new IllegalStateException("фото не вибрано: " + s.mode + " " + s.showIndex);
            if (!before.equals(s.hallTitle)) throw new IllegalStateException("зал змінився від дотику по фото: " + s.hallTitle);
            api.command("show", new JSONObject().put("tab", "show"));
            s = api.state(0);
            if (!"IMG_0003.jpg".equals(s.hallTitle)) throw new IllegalStateException("після «Показати» в залі «" + s.hallTitle + "»");
        }));
        check("картинка сторінки", io(() -> { if (api.pageImage(2, 280).length < 500) throw new IllegalStateException("мала"); }));
        check("список фото", io(() -> { if (api.get("/api/pictures").optJSONArray("pages").length() != 4) throw new IllegalStateException("не 4"); }));
        check("прибрати фото 1 (picture-remove)", io(() -> {
            JSONObject answer = api.command("picture-remove", new JSONObject().put("index", 1));
            if (answer.optInt("count", -1) != 3) throw new IllegalStateException("лишилося " + answer.optInt("count", -1));
            if (api.get("/api/pictures").optJSONArray("pages").length() != 3) throw new IllegalStateException("список не 3");
        }));
        check("очистити фото (pictures-clear)", io(() -> {
            String before = api.state(0).pictures;
            api.command("pictures-clear", new JSONObject());
            if (api.get("/api/pictures").optJSONArray("pages").length() != 0) throw new IllegalStateException("список не порожній");
            // Стан каже про список фото й на іншій вкладці — пульт помітить і перечитає.
            String after = api.state(0).pictures;
            if (!after.startsWith("0:") || after.equals(before)) throw new IllegalStateException("стан про фото: " + before + " → " + after);
        }));
        // Власник 27.11: «документ pdf pptx и другие тоже должны иметь опции для удаления из
        // списка» і «кнопка должна быть очистить список (полностью)».
        check("другий файл (deck 1)", io(() -> {
            api.command("deck", 1);
            State s = api.state(0);
            if (s.decks.size() != 2 || s.deck != 1 || s.pageIndex != 12) throw new IllegalStateException("файлів " + s.decks.size() + ", файл " + s.deck + ", сторінка " + s.pageIndex);
        }));
        check("прибрати файл 1 (deck-remove)", io(() -> {
            JSONObject answer = api.command("deck-remove", new JSONObject().put("index", 0));
            if (answer.optInt("count", -1) != 1) throw new IllegalStateException("лишилося " + answer.optInt("count", -1));
            State s = api.state(0);
            if (s.decks.size() != 1 || !"Оголошення.pptx".equals(s.decks.get(0).title) || s.pageIndex != 0)
                throw new IllegalStateException("лишилося " + s.decks.size() + ", сторінка " + s.pageIndex);
        }));
        check("чужий номер файла — відмова", io(() -> {
            try {
                api.command("deck-remove", new JSONObject().put("index", 99));
            } catch (java.io.IOException expected) {
                return;
            }
            throw new IllegalStateException("пройшло");
        }));
        check("очистити презентації (decks-clear)", io(() -> {
            api.command("decks-clear", new JSONObject());
            State s = api.state(0);
            if (!s.decks.isEmpty() || !s.pages.isEmpty()) throw new IllegalStateException("файлів " + s.decks.size());
        }));
        System.out.println("тиша після відповідей: " + api.silentFor() + " мс");
        // Порт, де нікого немає: команда мусить спробувати двічі й чесно впасти.
        Api dead = new Api("127.0.0.1", port + 1, "");
        long t = System.currentTimeMillis();
        try {
            dead.command("next", new JSONObject().put("tab", "show"));
            bad++;
            System.out.println("✗ мертвий порт: команда «пройшла»");
        } catch (java.io.IOException expected) {
            ok++;
            System.out.println("✓ мертвий порт: " + Api.describe(expected) + " за " + (System.currentTimeMillis() - t) + " мс");
        }
        System.out.println("лічильники клієнта: " + Api.meterLine());
        System.out.println("ПІДСУМОК: " + ok + " ✓, " + bad + " ✗");
        System.exit(bad == 0 ? 0 : 1);
    }
}
