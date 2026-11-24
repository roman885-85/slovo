// =============================================================================
//  HelpWindow.cs — довідка «Слова» (як NativeHelpWindow на Mac)
// =============================================================================
//  Та сама сторінка, що в пакеті Mac (Resources/Help: index.html + uk.html +
//  en.html, без інтернету), українською чи англійською за мовою інтерфейсу,
//  з адресою теки даних цього комп'ютера й темою (keys, trouble). Вбудованого
//  веб-вікна в Avalonia немає — сторінка відкривається в браузері.
//
//  Кілька місць довідки — про macOS: для Windows вони замінюються на свої
//  (клавіші Alt/Ctrl замість ⌘, Провідник замість Finder, брандмауер Windows
//  замість дозволів macOS, Слово.exe замість Слово.app).
// =============================================================================

using System.Diagnostics;
using System.Reflection;
using System.Text;
using Slovo.Core;

namespace Slovo.App;

public static class HelpWindow
{
    static string? Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name);
        if (stream == null) return null;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    /// Мова довідки: українська для uk і ru, решта — англійська.
    public static string Language(string interfaceLanguage) => interfaceLanguage is "uk" or "ru" ? "uk" : "en";

    public static string? Page(string language, string? topic)
    {
        if (Resource("help-index.html") is not { } page) return null;
        foreach (var code in new[] { "uk", "en" })
            page = page.Replace($"<!--SECTIONS-{code}-->", ForWindows(Resource($"help-{code}.html") ?? "", code));
        var safeTopic = new string((topic ?? "").Where(c => char.IsLetterOrDigit(c) || c == '-').ToArray());
        // Адреса теки з даними — жива, з цього комп'ютера, а не приклад у тексті.
        return page.Replace("{{LANG}}", language).Replace("{{TOPIC}}", safeTopic).Replace("{{DATA}}", System.Net.WebUtility.HtmlEncode(DataHome.DisplayPath));
    }

    /// Місця про macOS — своїми для Windows. Чого не знайшли — лишається, як є.
    static string ForWindows(string html, string code)
    {
        if (code == "uk")
        {
            html = html.Replace("Тримайте «Слово.app» у теці «Програми» (Applications): звідти оновлення може замінити програму. Встановити «Слово» на інший Mac — <a href=\"https://github.com/roman885-85/slovo/blob/main/Документація/ЗАПУСК.md\">",
                                "Тримайте «Слово.exe» у теці, куди у вас є право запису (наприклад, «Документи»): звідти оновлення може замінити програму. Встановити «Слово» на інший комп'ютер — <a href=\"https://github.com/roman885-85/slovo/blob/main/Windows/ЧИТАТЬ.md\">")
                       .Replace(" Уперше macOS попросить дозвіл <b>«Записування системного звуку й екрана»</b> — див. <a href=\"#trouble\">«Якщо щось не так»</a>.", "")
                       .Replace("«Показати у Finder»", "«Показати в Провіднику»")
                       .Replace("Щоб оновлення могло замінити програму, тримайте «Слово.app» у теці «Програми» (Applications), а не в «Завантаженнях».",
                                "Щоб оновлення могло замінити програму, тримайте «Слово.exe» у теці, куди у вас є право запису (не на флешці й не в теці лише для читання).")
                       .Replace("«Том лише для читання» — програму запущено просто із «Завантажень» чи з образу диска. Перенесіть «Слово.app» у «Програми» й запустіть звідти.",
                                "«Немає доступу» — програма лежить у теці лише для читання (наприклад, Program Files без прав адміністратора). Перенесіть «Слово.exe» у «Документи» й запустіть звідти.")
                       .Replace("Оновлення замінює лише «Слово.app». Тека з даними лишається на місці, і macOS не питає дозволів наново — запис екрана й локальна мережа працюють далі.",
                                "Оновлення замінює лише «Слово.exe». Тека з даними лишається на місці.");
            html = ReplaceSection(html, "<h3>Дозволи macOS</h3>", "</ul>",
                "<h3>Брандмауер Windows</h3>\n<p>Коли пульт уперше слухає мережу, Windows питає, чи дозволити «Слову» зв'язок. Позначте «Приватні мережі» й натисніть «Дозволити», інакше телефон і планшет не під'єднаються.</p>\n<ul>\n"
                + "<li>Якщо колись заборонили: «Параметри» → «Конфіденційність і захист» → «Безпека Windows» → «Брандмауер і захист мережі» → «Дозволити роботу з програмою через брандмауер» — позначка «Приватна» біля «Слово».</li>\n"
                + "<li>Мережа має бути «приватною», а не «загальнодоступною»: «Параметри» → «Мережа й Інтернет» → властивості Wi-Fi.</li>\n"
                + "<li>Перевірити — кнопкою «Перевірити зв'язок» у <span class=\"menu\">Налаштування… → Remote API</span>.</li>\n</ul>");
        }
        else
        {
            html = html.Replace("Keep “Слово.app” in the Applications folder: from there an update can replace the app. To install Slovo on another Mac, use the <a href=\"https://github.com/roman885-85/slovo/blob/main/Документація/ЗАПУСК.md#english\">",
                                "Keep “Слово.exe” in a folder you can write to (for example, Documents): from there an update can replace the app. To install Slovo on another computer, use the <a href=\"https://github.com/roman885-85/slovo/blob/main/Windows/ЧИТАТЬ.md\">")
                       .Replace("since this help is not available on a Mac where the app has not started yet.", "since this help is not available on a computer where the app has not started yet.")
                       .Replace(" The first time, macOS asks for the <b>Screen &amp; System Audio Recording</b> permission — see <a href=\"#trouble\">“Troubleshooting”</a>.", "")
                       .Replace("So that the update can replace the app, keep “Слово.app” in the Applications folder, not in Downloads.",
                                "So that the update can replace the app, keep “Слово.exe” in a folder you can write to (not on a flash drive or in a read-only folder).")
                       .Replace("“Read-only volume” — the app was started straight from Downloads or from a disk image. Move “Слово.app” to Applications and start it from there.",
                                "“Access denied” — the app sits in a read-only folder (for example, Program Files without administrator rights). Move “Слово.exe” to Documents and start it from there.")
                       .Replace("“Show in Finder”", "“Show in Explorer”")
                       .Replace("An update replaces only the app. The data folder stays where it is, and macOS does not ask for permissions again — screen recording and local network keep working.",
                                "An update replaces only Слово.exe. The data folder stays where it is.");
            html = ReplaceSection(html, "<h3>macOS permissions</h3>", "</ul>",
                "<h3>Windows Firewall</h3>\n<p>The first time the remote listens on the network, Windows asks whether to allow Slovo. Tick “Private networks” and click “Allow”, otherwise the phone and the tablet cannot connect.</p>\n<ul>\n"
                + "<li>If you once refused: Settings → Privacy &amp; security → Windows Security → Firewall &amp; network protection → Allow an app through firewall — tick “Private” next to Slovo.</li>\n"
                + "<li>The network must be “Private”, not “Public”: Settings → Network &amp; internet → Wi-Fi properties.</li>\n"
                + "<li>To check, use “Check the connection” in <span class=\"menu\">Settings… → Remote API</span>.</li>\n</ul>");
        }
        // Клавіші: на Windows вірш і розділ — Alt зі стрілками, налаштування — Ctrl+, (меню «Дії»).
        return html.Replace("<kbd>⌘</kbd>+<kbd>→</kbd> <kbd>⌘</kbd>+<kbd>←</kbd>", "<kbd>Alt</kbd>+<kbd>→</kbd> <kbd>Alt</kbd>+<kbd>←</kbd>")
                   .Replace("<kbd>⌘</kbd>+<kbd>↓</kbd> <kbd>⌘</kbd>+<kbd>↑</kbd>", "<kbd>Alt</kbd>+<kbd>↓</kbd> <kbd>Alt</kbd>+<kbd>↑</kbd>")
                   .Replace("<kbd>⌘</kbd>", "<kbd>Ctrl</kbd>");
    }

    static string ReplaceSection(string html, string start, string end, string replacement)
    {
        var from = html.IndexOf(start, StringComparison.Ordinal);
        if (from < 0) return html;
        var to = html.IndexOf(end, from, StringComparison.Ordinal);
        if (to < 0) return html;
        return html[..from] + replacement + html[(to + end.Length)..];
    }

    /// Відкрити довідку (тема — keys, trouble або порожньо).
    public static void Open(string? topic = null)
    {
        var language = Language(OurWords.Language);
        if (Page(language, topic) is not { } html)
        {
            // Збірка без довідки — хоч документація в мережі.
            Open("https://github.com/roman885-85/slovo/blob/main/Windows/ЧИТАТЬ.md", true);
            return;
        }
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "Slovo-help");
            Directory.CreateDirectory(folder);
            var file = Path.Combine(folder, $"slovo-{language}{(string.IsNullOrEmpty(topic) ? "" : "-" + topic)}.html");
            File.WriteAllText(file, html, new UTF8Encoding(false));
            Open(file, false);
        }
        catch (Exception error) { Journal.Say($"довідка не відкрилась: {error.Message}"); }
    }

    static void Open(string target, bool online)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception error) { Journal.Say($"{(online ? "посилання" : "довідка")} не відкрилось: {error.Message}"); }
    }
}
