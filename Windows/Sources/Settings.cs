// =============================================================================
//  Settings.cs — налаштування програми (settings.json у теці даних)
// =============================================================================
//  Склад — вікно «Параметри» оригіналу й «Слова» на Mac: монітор слайда,
//  вигляд кожного режиму (Біблія / Пісні / Текст), переклади й пісенники,
//  фони, адреса, гарячі клавіші, пульт, мова. Умовчання — ті, що в Slovo.ini
//  пакета для Mac. Читання терпить відсутні поля: файл правлять і руками.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Slovo;

/// Вигляд одного режиму — стиль слайда плюс те, як режим ділить текст.
public sealed class ModeLook
{
    public SlideStyle Style { get; set; } = new();
    /// Ім'я шаблону `.sch` з теки Templates; порожньо — стиль як є.
    public string TemplateName { get; set; } = "";
    /// `PageSubDivide` — довгий текст на сторінки.
    public bool PageSubDivide { get; set; } = true;
    /// `VersSubDivide` — на вірші (у пісень — ділити довгу частину).
    public bool VersSubDivide { get; set; }
    /// `WordWrap` — автоперенос слів.
    public bool WordWrap { get; set; } = true;
    /// `fontminsize` у відсотках висоти слайда — межа стискання довгого тексту
    /// (кегль тексту за умовчанням 8,5 %; оригінал стискає до 11 % від 20 %).
    public double FontMinPercent { get; set; } = 3.5;

    public static ModeLook Default(string section)
    {
        var look = new ModeLook { Style = SlideStyle.Default(section) };
        if (section == "Songs") { look.VersSubDivide = false; look.PageSubDivide = true; }
        if (section == "Text") { look.VersSubDivide = false; }
        if (section == "Bible") { look.VersSubDivide = true; }
        return look;
    }
}

public sealed class Settings
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    // Мова й вікно
    public string Language { get; set; } = "auto";
    public double ListFontSize { get; set; } = 13;
    public int WindowX { get; set; } = -1;
    public int WindowY { get; set; } = -1;
    public int WindowWidth { get; set; } = 1420;
    public int WindowHeight { get; set; } = 860;
    public bool WindowMaximized { get; set; }
    public double BottomRowHeight { get; set; } = 250;
    public double PlanWidth { get; set; } = 320;
    public bool TabNamesLong { get; set; }

    // Монітор слайда
    /// Номер монітора (з одиниці) для слайда; 0 — будь-який, крім того, де вікно програми.
    public int MonitorIndex { get; set; } = 0;
    /// Ручна настройка: вікно слайда за своїми координатами, навіть без монітора.
    public bool ManualPlacement { get; set; }
    public int CustomLeft { get; set; }
    public int CustomTop { get; set; }
    public int CustomWidth { get; set; } = 800;
    public int CustomHeight { get; set; } = 600;
    /// Розміри «за умовчанням», коли вибраного монітора нема і слайд іде вікном.
    public int DefaultWidth { get; set; } = 1024;
    public int DefaultHeight { get; set; } = 768;
    /// Відкривати вікно слайда разом із програмою (вимкнути — відкривати кнопкою «Вікно слайда»).
    public bool SlideWindowAtStart { get; set; } = true;
    /// Висота слайда, під яку в шаблонах `.sch` записано пікселі контуру й тіні.
    public int DesignHeight { get; set; } = 600;

    // Вигляд режимів
    public ModeLook Bible { get; set; } = ModeLook.Default("Bible");
    public ModeLook Songs { get; set; } = ModeLook.Default("Songs");
    public ModeLook Text { get; set; } = ModeLook.Default("Text");
    /// Спільний фон — важливіший за фон шаблону, коли ввімкнено.
    public string CommonBackground { get; set; } = "";
    public bool ShowCommonBackground { get; set; } = true;
    /// Фон слайда, вибраний людиною поверх шаблону (на всі режими).
    public string SlideBackground { get; set; } = "";

    // Переклади й пісенники
    /// Увімкнені переклади в порядку вкладок.
    public List<string> ModuleOrder { get; set; } = new();
    public string PrimaryModule { get; set; } = "";
    public List<string> SecondaryModules { get; set; } = new();
    public string SongBook { get; set; } = "";
    /// Теки з картинками для вкладки «Зображення» (і для вибору фону).
    public List<string> PicturePaths { get; set; } = new();

    // Показ
    /// Стрілки гортають і передпоказ, і зал («Зв'язати навігацію»).
    public bool ArrowsLinked { get; set; } = true;
    /// «Активна»: стрілки й перегортання одразу виводять у зал.
    public bool ArrowsShowLive { get; set; } = true;
    public string ShowTransition { get; set; } = "fade";
    public double ShowTransitionSeconds { get; set; } = 0.35;
    /// Плавне гасіння залу («Сховати», затемнення): секунди й крива.
    public double HideFadeSeconds { get; set; } = 0.5;
    public string HideFadeEasing { get; set; } = "easeOut";
    public bool ShowVerseNumbers { get; set; }
    public bool ShowSecondaryVerseNumbers { get; set; }
    public bool SeparatorTenVerses { get; set; } = true;
    /// `percentfillingpage` — мінімальний відсоток заповнення нової сторінки.
    public int PercentFillingPage { get; set; } = 30;
    /// Вірші на слайді — кожен зі свого рядка.
    public bool VersesOnOwnLines { get; set; } = true;

    // Адреса
    public bool RefAllMainShort { get; set; }
    public bool RefAllSecShort { get; set; } = true;
    public bool RefMainShort { get; set; }
    public bool RefSecShort { get; set; }

    // Пісні
    public bool SongNumberPP { get; set; }
    public bool SongNumberInCollection { get; set; } = true;
    public bool SongNumberInBrackets { get; set; }
    public bool SongDotAfterNumber { get; set; } = true;
    public string SongsEndMarker { get; set; } = "";

    // Гарячі клавіші
    public string HotkeySet { get; set; } = "";

    // Пульт
    public bool RemoteEnabled { get; set; } = true;
    public int RemotePort { get; set; } = 8103;
    public string RemotePin { get; set; } = "";
    public bool WebEnabled { get; set; } = true;
    public int WebPort { get; set; } = 8105;
    public string WebPassword { get; set; } = "";
    public string WebName { get; set; } = "slovo";
    public bool WebViewOnly { get; set; }
    public bool WebNoPort { get; set; } = true;
    public string PointerColour { get; set; } = "#FFD400";
    public double PointerSize { get; set; } = 0.05;
    public double PointerOpacity { get; set; } = 0.85;

    // Оновлення
    public long LastUpdateCheck { get; set; }
    public string SkippedUpdate { get; set; } = "";
    public int UpdateIntervalDays { get; set; } = 7;

    // Пам'ять між запусками
    public string LastPlan { get; set; } = "";
    public string LastMode { get; set; } = "bible";
    public int LastBook { get; set; }
    public int LastChapter { get; set; } = 1;

    public ModeLook Look(string mode) => mode switch { "songs" => Songs, "text" => Text, _ => Bible };

    public static Settings Load()
    {
        try
        {
            if (File.Exists(Paths.SettingsFile))
            {
                var loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(Paths.SettingsFile), JsonOptions);
                if (loaded != null) return loaded;
            }
        }
        catch (Exception error)
        {
            Paths.Say("налаштування не прочиталися: " + error.Message);
        }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            var temp = Paths.SettingsFile + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(temp, Paths.SettingsFile, true);
        }
        catch (Exception error)
        {
            Paths.Say("налаштування не записалися: " + error.Message);
        }
    }

    public Settings Clone() => JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(this, JsonOptions), JsonOptions) ?? new Settings();
}
