package ua.church.slovo.remote;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/// План проповіді: назва й пункти в порядку подачі.
///
/// Кожен план — окремий файл у пам'яті планшета (`files/plans/*.json`):
/// проповідник може скласти кілька наперед і взяти на служіння потрібний.
/// Пункт везе з собою не лише посилання, а й сам текст — вірші чи слова
/// пісні. Якщо в програмі на служінні не виявиться того перекладу чи
/// пісенника, пункт усе одно покажеться — текстом.
final class SermonPlan {

    static final String SCRIPTURE = "scripture";
    static final String SONG = "song";
    static final String TEXT = "text";
    static final String FILE = "file";

    static final class Item {
        String type = TEXT;
        /// Рядок у списку: «Ів 3:16-18», назва пісні, заголовок, ім'я файла.
        String title = "";

        // Уривок.
        String module = "";
        String moduleName = "";
        String bookName = "";
        int canon;
        int book;
        int chapter;
        final List<Integer> verses = new ArrayList<>();
        String text = "";

        // Пісня.
        String songBook = "";
        int song;
        final List<String[]> parts = new ArrayList<>();

        // Довільний текст.
        String heading = "";
        String body = "";

        // Файл: копія в пам'яті планшета і його справжнє ім'я.
        String path = "";
        String name = "";

        /// Друга половина рядка списку — початок тексту.
        String subtitle() {
            String value;
            switch (type) {
                case SCRIPTURE: value = text; break;
                case SONG: value = parts.isEmpty() ? "" : parts.get(0)[1]; break;
                case TEXT: value = body; break;
                default: value = name; break;
            }
            value = value.replace('\n', ' ').trim();
            return value.length() > 120 ? value.substring(0, 120) + "…" : value;
        }

        JSONObject toJson() throws JSONException {
            JSONObject json = new JSONObject();
            json.put("type", type);
            json.put("title", title);
            switch (type) {
                case SCRIPTURE:
                    json.put("module", module);
                    json.put("moduleName", moduleName);
                    json.put("bookName", bookName);
                    json.put("canon", canon);
                    json.put("book", book);
                    json.put("chapter", chapter);
                    JSONArray numbers = new JSONArray();
                    for (Integer verse : verses) numbers.put(verse);
                    json.put("verses", numbers);
                    json.put("text", text);
                    break;
                case SONG:
                    json.put("module", module);
                    json.put("songBook", songBook);
                    json.put("song", song);
                    JSONArray list = new JSONArray();
                    for (String[] part : parts) {
                        JSONObject item = new JSONObject();
                        item.put("kind", part[0]);
                        item.put("text", part[1]);
                        list.put(item);
                    }
                    json.put("parts", list);
                    break;
                case TEXT:
                    json.put("heading", heading);
                    json.put("body", body);
                    break;
                default:
                    json.put("path", path);
                    json.put("name", name);
                    break;
            }
            return json;
        }

        static Item fromJson(JSONObject json) {
            Item item = new Item();
            item.type = json.optString("type", TEXT);
            item.title = json.optString("title", "");
            item.module = json.optString("module", "");
            item.moduleName = json.optString("moduleName", "");
            item.bookName = json.optString("bookName", "");
            item.canon = json.optInt("canon");
            item.book = json.optInt("book");
            item.chapter = json.optInt("chapter");
            JSONArray numbers = json.optJSONArray("verses");
            if (numbers != null) for (int i = 0; i < numbers.length(); i++) item.verses.add(numbers.optInt(i));
            item.text = json.optString("text", "");
            item.songBook = json.optString("songBook", "");
            item.song = json.optInt("song");
            JSONArray list = json.optJSONArray("parts");
            if (list != null) {
                for (int i = 0; i < list.length(); i++) {
                    JSONObject part = list.optJSONObject(i);
                    if (part != null) item.parts.add(new String[] { part.optString("kind"), part.optString("text") });
                }
            }
            item.heading = json.optString("heading", "");
            item.body = json.optString("body", "");
            item.path = json.optString("path", "");
            item.name = json.optString("name", "");
            return item;
        }
    }

    String id = UUID.randomUUID().toString();
    String title = "";
    long updated;
    final List<Item> items = new ArrayList<>();

    static File folder(Context context) {
        File folder = new File(context.getFilesDir(), "plans");
        //noinspection ResultOfMethodCallIgnored
        folder.mkdirs();
        return folder;
    }

    /// Копії файлів плану: презентацію мають відвезти й тоді, коли вихідний
    /// файл на планшеті вже прибрали.
    static File filesFolder(Context context) {
        File folder = new File(context.getFilesDir(), "plan-files");
        //noinspection ResultOfMethodCallIgnored
        folder.mkdirs();
        return folder;
    }

    /// Усі плани, свіжіші зверху.
    static List<SermonPlan> all(Context context) {
        List<SermonPlan> result = new ArrayList<>();
        File[] files = folder(context).listFiles();
        if (files != null) {
            for (File file : files) {
                if (!file.getName().endsWith(".json")) continue;
                SermonPlan plan = load(file);
                if (plan != null) result.add(plan);
            }
        }
        Collections.sort(result, (a, b) -> Long.compare(b.updated, a.updated));
        return result;
    }

    static SermonPlan load(File file) {
        try {
            JSONObject json = new JSONObject(new String(ModuleReaders.readAll(file), StandardCharsets.UTF_8));
            SermonPlan plan = new SermonPlan();
            plan.id = json.optString("id", file.getName().replace(".json", ""));
            plan.title = json.optString("title", "");
            plan.updated = json.optLong("updated", file.lastModified());
            JSONArray items = json.optJSONArray("items");
            if (items != null) {
                for (int i = 0; i < items.length(); i++) {
                    JSONObject item = items.optJSONObject(i);
                    if (item != null) plan.items.add(Item.fromJson(item));
                }
            }
            return plan;
        } catch (IOException | JSONException error) {
            return null;
        }
    }

    static SermonPlan load(Context context, String id) {
        return id == null || id.isEmpty() ? null : load(new File(folder(context), id + ".json"));
    }

    void save(Context context) throws IOException {
        updated = System.currentTimeMillis();
        JSONObject json = new JSONObject();
        try {
            json.put("id", id);
            json.put("title", title);
            json.put("updated", updated);
            JSONArray list = new JSONArray();
            for (Item item : items) list.put(item.toJson());
            json.put("items", list);
        } catch (JSONException error) {
            throw new IOException(error.getMessage());
        }
        File target = new File(folder(context), id + ".json");
        File temp = new File(folder(context), id + ".tmp");
        try (OutputStream out = new FileOutputStream(temp)) {
            out.write(json.toString().getBytes(StandardCharsets.UTF_8));
        }
        if (!temp.renameTo(target)) throw new IOException(Lang.t("Не вдалося записати план", "Could not save the plan"));
    }

    /// Прибрати план разом із копіями його файлів.
    void delete(Context context) {
        for (Item item : items) {
            if (FILE.equals(item.type) && !item.path.isEmpty()) {
                //noinspection ResultOfMethodCallIgnored
                new File(item.path).delete();
            }
        }
        //noinspection ResultOfMethodCallIgnored
        new File(folder(context), id + ".json").delete();
    }
}
