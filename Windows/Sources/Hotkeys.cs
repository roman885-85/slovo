// =============================================================================
//  Hotkeys.cs — гарячі клавіші в записі VisioBible (hotkeys.ini)
// =============================================================================
//  Перенесено з HotkeyMap.swift: файл `hotkeys.ini` — це кілька іменованих
//  наборів (`[VB Version 2.2]`, `[VB Version 2.3]`, `[VB Version 2.4]`), у
//  кожному — ключ функції і сполучення виду `Ctrl+Alt+B`, `F5`, `Esc`.
//  Умовчання — з того самого файла, що й у пакеті для Mac (вшитий ресурс).
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Avalonia.Input;

namespace Slovo;

/// Одне сполучення клавіш.
public sealed record Hotkey(bool Control, bool Alt, bool Shift, string Key)
{
    /// Розбір рядка з `hotkeys.ini`. null — клавішу не призначено.
    public static Hotkey? Parse(string text)
    {
        bool control = false, alt = false, shift = false;
        var key = "";
        foreach (var raw in text.Split('+'))
        {
            var part = raw.Trim();
            switch (part.ToLowerInvariant())
            {
                case "ctrl": case "control": control = true; break;
                case "alt": alt = true; break;
                case "shift": shift = true; break;
                case "": break;
                default: key = CanonicalKey(part); break;
            }
        }
        return key.Length == 0 ? null : new Hotkey(control, alt, shift, key);
    }

    /// Назад у запис оригіналу — порядок модифікаторів Ctrl, Alt, Shift.
    public string Text
    {
        get
        {
            var parts = new List<string>();
            if (Control) parts.Add("Ctrl");
            if (Alt) parts.Add("Alt");
            if (Shift) parts.Add("Shift");
            parts.Add(Key);
            return string.Join("+", parts);
        }
    }

    public override string ToString() => Text;

    static readonly Dictionary<string, string> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        ["esc"] = "Esc", ["escape"] = "Esc", ["space"] = "Space", ["enter"] = "Enter", ["return"] = "Enter",
        ["tab"] = "Tab", ["backspace"] = "BackSpace", ["ins"] = "Ins", ["insert"] = "Ins", ["del"] = "Del",
        ["delete"] = "Del", ["home"] = "Home", ["end"] = "End", ["pgup"] = "PgUp", ["pageup"] = "PgUp",
        ["pgdn"] = "PgDn", ["pagedown"] = "PgDn", ["up"] = "Up", ["down"] = "Down", ["left"] = "Left", ["right"] = "Right",
    };

    /// Зводимо написання до того, в якому клавіші записані в `hotkeys.ini`.
    public static string CanonicalKey(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 1) return trimmed.ToUpperInvariant();
        var lower = trimmed.ToLowerInvariant();
        if (lower.Length >= 2 && lower[0] == 'f' && int.TryParse(lower[1..], out _)) return "F" + lower[1..];
        if (Known.TryGetValue(lower, out var known)) return known;
        return char.ToUpperInvariant(trimmed[0]) + trimmed[1..];
    }

    /// Чи це сполучення натиснули. Літери й цифри — за клавішею, а не за
    /// розкладкою: Ctrl+B діє і в українській розкладці.
    public bool Matches(Key key, KeyModifiers modifiers)
    {
        var control = modifiers.HasFlag(KeyModifiers.Control) || modifiers.HasFlag(KeyModifiers.Meta);
        if (control != Control) return false;
        if (modifiers.HasFlag(KeyModifiers.Alt) != Alt) return false;
        if (modifiers.HasFlag(KeyModifiers.Shift) != Shift) return false;
        return KeyName(key) == Key;
    }

    /// Назва клавіші Avalonia в записі `hotkeys.ini`; порожньо — не записується.
    public static string KeyName(Key key)
    {
        if (key >= Avalonia.Input.Key.F1 && key <= Avalonia.Input.Key.F24) return "F" + (key - Avalonia.Input.Key.F1 + 1);
        if (key >= Avalonia.Input.Key.A && key <= Avalonia.Input.Key.Z) return ((char)('A' + (key - Avalonia.Input.Key.A))).ToString();
        if (key >= Avalonia.Input.Key.D0 && key <= Avalonia.Input.Key.D9) return ((char)('0' + (key - Avalonia.Input.Key.D0))).ToString();
        return key switch
        {
            Avalonia.Input.Key.Escape => "Esc",
            Avalonia.Input.Key.Space => "Space",
            Avalonia.Input.Key.Enter => "Enter",
            Avalonia.Input.Key.Tab => "Tab",
            Avalonia.Input.Key.Back => "BackSpace",
            Avalonia.Input.Key.Insert => "Ins",
            Avalonia.Input.Key.Delete => "Del",
            Avalonia.Input.Key.Home => "Home",
            Avalonia.Input.Key.End => "End",
            Avalonia.Input.Key.PageUp => "PgUp",
            Avalonia.Input.Key.PageDown => "PgDn",
            Avalonia.Input.Key.Up => "Up",
            Avalonia.Input.Key.Down => "Down",
            Avalonia.Input.Key.Left => "Left",
            Avalonia.Input.Key.Right => "Right",
            _ => "",
        };
    }

    public static Hotkey? From(Key key, KeyModifiers modifiers)
    {
        var name = KeyName(key);
        if (name.Length == 0) return null;
        return new Hotkey(modifiers.HasFlag(KeyModifiers.Control) || modifiers.HasFlag(KeyModifiers.Meta),
                          modifiers.HasFlag(KeyModifiers.Alt), modifiers.HasFlag(KeyModifiers.Shift), name);
    }
}

/// Функція, якій можна призначити клавішу — склад і порядок вкладки
/// «Гарячі клавіші» оригіналу.
public sealed record HotkeyAction(string IniKey, string Uk, string En)
{
    public string Title => Lang.T(Uk, En);

    public static readonly HotkeyAction[] All =
    {
        new("ShowSlide", "Показати слайд", "Show slide"),
        new("HideSlide", "Сховати слайд", "Hide slide"),
        new("Search", "Пошук", "Search"),
        new("FastInput", "Швидкий вибір", "Quick input"),
        new("Plan", "Фокус на План", "Focus on Plan"),
        new("MainWin", "Фокус на Вірші/Текст", "Focus on Verses/Text"),
        new("ScreenShot", "Знімок екрана", "Screenshot"),
        new("FastSearchWindow", "Результати пошуку", "Search results"),
        new("ShowBackGrOnSlide", "Спільний фон", "Common background"),
        new("FastInputBook", "Швидкий вибір книги/пісні", "Quick choice of book/song"),
        new("FastInputChapter", "Швидкий вибір розділу", "Quick choice of chapter"),
        new("FastInputVers", "Швидкий вибір вірша чи частини пісні", "Quick choice of verse or song part"),
        new("ShowBlackScreen", "Затемнення екрана", "Black screen"),
        new("ShowBlankSlide", "Показати порожній слайд", "Show blank slide"),
        new("ShowMediaPlayer", "Відкрити медіаплеєр", "Open media player"),
        new("MediaPlayerPlayPause", "Медіаплеєр: відтворити/пауза", "Media player: play/pause"),
        new("OpenCommonBG", "Вибрати спільний фон", "Choose common background"),
        new("OpenSlideBG", "Вибрати фон слайда", "Choose slide background"),
        new("ReactionOnCtrlE", "Режим редагування/перегляду", "Edit/view mode"),
    };
}

/// Уміст `hotkeys.ini`: кілька іменованих наборів клавіш.
public sealed class HotkeySets
{
    public List<string> Order { get; } = new();
    public Dictionary<string, Dictionary<string, string>> Sets { get; } = new();

    public static HotkeySets Parse(string text)
    {
        var sets = new HotkeySets();
        var current = "";
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('﻿');
            if (line.Length == 0 || line.StartsWith(';')) continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                current = line[1..^1];
                if (!sets.Sets.ContainsKey(current)) { sets.Order.Add(current); sets.Sets[current] = new(); }
                continue;
            }
            var eq = line.IndexOf('=');
            if (current.Length == 0 || eq < 0) continue;
            sets.Sets[current][line[..eq].Trim()] = line[(eq + 1)..].Trim();
        }
        return sets;
    }

    /// Набір, який треба показати при відкритті: останній у файлі — найновіший.
    public string? PreferredSetName => Order.Count == 0 ? null : Order[^1];

    public Dictionary<string, Hotkey> Hotkeys(string name)
    {
        var result = new Dictionary<string, Hotkey>();
        if (!Sets.TryGetValue(name, out var set)) return result;
        foreach (var (key, value) in set)
        {
            var hotkey = Hotkey.Parse(value);
            if (hotkey != null) result[key] = hotkey;
        }
        return result;
    }

    public void Replace(string name, Dictionary<string, Hotkey> hotkeys)
    {
        if (!Sets.ContainsKey(name)) Order.Add(name);
        Sets[name] = hotkeys.ToDictionary(p => p.Key, p => p.Value.Text);
    }

    /// Запис у форматі оригіналу — щоб файл лишився придатним і для нього.
    public string Serialized()
    {
        var lines = new List<string>();
        foreach (var name in Order)
        {
            lines.Add("[" + name + "]");
            var set = Sets[name];
            foreach (var action in HotkeyAction.All)
                if (set.TryGetValue(action.IniKey, out var value)) lines.Add(action.IniKey + "=" + value);
            foreach (var (key, value) in set.OrderBy(p => p.Key, StringComparer.Ordinal))
                if (HotkeyAction.All.All(a => a.IniKey != key)) lines.Add(key + "=" + value);
            lines.Add("");
        }
        return string.Join("\n", lines);
    }

    /// Умовчання — файл `hotkeys.ini` із пакета «Слова» (вшитий у програму).
    public static HotkeySets FactoryDefault()
    {
        var text = Embedded.Text("hotkeys.ini");
        var sets = text.Length > 0 ? Parse(text) : new HotkeySets();
        if (sets.Order.Count > 0) return sets;
        sets.Replace("VB Version 2.4", new Dictionary<string, Hotkey>
        {
            ["ShowSlide"] = Hotkey.Parse("F5")!, ["HideSlide"] = Hotkey.Parse("Esc")!, ["Search"] = Hotkey.Parse("F3")!,
            ["FastInput"] = Hotkey.Parse("F4")!, ["Plan"] = Hotkey.Parse("F2")!, ["MainWin"] = Hotkey.Parse("F6")!,
            ["ScreenShot"] = Hotkey.Parse("F11")!, ["FastSearchWindow"] = Hotkey.Parse("Ctrl+F3")!,
            ["ShowBackGrOnSlide"] = Hotkey.Parse("Ctrl+F9")!, ["FastInputBook"] = Hotkey.Parse("F7")!,
            ["FastInputChapter"] = Hotkey.Parse("F8")!, ["FastInputVers"] = Hotkey.Parse("F9")!,
            ["ShowBlackScreen"] = Hotkey.Parse("F12")!, ["ShowBlankSlide"] = Hotkey.Parse("Ctrl+F5")!,
            ["ShowMediaPlayer"] = Hotkey.Parse("Ctrl+M")!, ["MediaPlayerPlayPause"] = Hotkey.Parse("Ctrl+P")!,
            ["OpenCommonBG"] = Hotkey.Parse("Ctrl+B")!, ["OpenSlideBG"] = Hotkey.Parse("Ctrl+Alt+B")!,
            ["ReactionOnCtrlE"] = Hotkey.Parse("Ctrl+E")!,
        });
        return sets;
    }

    /// Набори з особистого файла, а якщо його немає — умовчання.
    public static HotkeySets Load()
    {
        try
        {
            if (File.Exists(Paths.HotkeysFile))
            {
                var loaded = Parse(File.ReadAllText(Paths.HotkeysFile, Encoding.UTF8));
                if (loaded.Order.Count > 0) return loaded;
            }
        }
        catch (Exception error)
        {
            Paths.Say("hotkeys.ini не прочитався: " + error.Message);
        }
        return FactoryDefault();
    }

    public void Save()
    {
        try { File.WriteAllText(Paths.HotkeysFile, Serialized(), new UTF8Encoding(false)); }
        catch (Exception error) { Paths.Say("hotkeys.ini не записався: " + error.Message); }
    }
}

/// Вшиті в програму файли умовчань.
public static class Embedded
{
    public static string Text(string name)
    {
        try
        {
            using var stream = typeof(Embedded).Assembly.GetManifestResourceStream(name);
            if (stream == null) return "";
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            return reader.ReadToEnd();
        }
        catch
        {
            return "";
        }
    }
}
