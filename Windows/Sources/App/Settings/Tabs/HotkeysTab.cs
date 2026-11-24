// =============================================================================
//  HotkeysTab.cs — вкладка «Гарячі клавіші» (як NativeSettingsHotkeysTab на Mac)
// =============================================================================
//  Набір клавіш (список, «зберегти/додати», «видалити», «За умовчанням») · по
//  клавіші на кожну дію (зайнята іншою дією — питаємо, чи забрати) · пульт
//  Logitech R400.
// =============================================================================

using Avalonia.Controls;
using Slovo.Core;

namespace Slovo.App;

public sealed class HotkeysTab
{
    readonly SettingsStore _store;
    PopupButton? _sets;
    readonly Dictionary<string, PopupButton> _pickers = new();

    public HotkeysTab(SettingsStore store) { _store = store; }
    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "SettingsForm") ?? Captions.T(fallback);
    SlovoSettings S => _store.Settings;

    public Control Page() => new Form.Page(new[] { Sets(), Columns(), Pointer() });

    Form.Group Sets()
    {
        var names = S.HotkeySets.Order;
        _sets = Form.Popup(names, new Tie<int>(() => Math.Max(0, names.IndexOf(S.HotkeySetName)),
            i => { var all = S.HotkeySets.Order; if (i < 0 || i >= all.Count) return; S.HotkeySetName = all[i]; ReloadPickers(); }), 240);
        ToolTip.SetTip(_sets, Hint("CBHotKeys", "Наборы горячих клавиш"));
        return new Form.Group("", new Control[]
        {
            new Form.Row("", new Control[]
            {
                _sets,
                Form.Button("⤓", Hint("PSBSaveHotKeys", "Сохранить/добавить набор горячих клавиш"), SaveSet),
                Form.Button("🗑", Hint("PSBDelHotKeys", "Удалить набор горячих клавиш"), DeleteSet),
                Form.Button(Vb("PngSBDefaultHotKey", Captions.T("По умолчанию")), Hint("PngSBDefaultHotKey", "Установить горячие клавиши по умолчанию"), () =>
                {
                    var name = HotkeySets.FactoryDefault.Order.FirstOrDefault() ?? "VB Version 2.4";
                    S.HotkeySets.Replace(S.HotkeySetName, HotkeySets.FactoryDefault.Hotkeys(name));
                    ReloadPickers();
                }),
            }),
        });
    }

    Form.Group Columns() => new("", HotkeyAction.All.Select(action =>
    {
        var picker = Form.Popup(Choices(action), new Tie<int>(
            () => Math.Max(0, Choices(action).IndexOf(_store.Hotkeys.TryGetValue(action.IniKey, out var h) ? h.Text : "—")),
            i => { var list = Choices(action); if (i >= 0 && i < list.Count) Assign(list[i], action); }), 140);
        _pickers[action.IniKey] = picker;
        return (Control)new Form.Row(Caption(action), new Control[] { picker }, 300);
    }).ToList());

    Form.Group Pointer() => new("", new Control[]
    {
        new Form.Row("", new Control[]
        {
            Form.Check(Vb("CBUseRCPointer", "Использовать Wireless Presenter R400"), new Tie<bool>(() => S.Options.UseRCPointer, v => S.Options.UseRCPointer = v),
                       Captions.T("Настройка пульта Logitech R400 из прежней программы; листать пультом докладчика можно и без неё")),
        }),
    });

    static string Caption(HotkeyAction action)
    {
        var text = Vb(action.CaptionKey, Captions.T(action.Fallback));
        return text.EndsWith(':') ? text[..^1] : text;
    }

    void Assign(string text, HotkeyAction action)
    {
        if (text.Length == 0 || text == "—" || Hotkey.Parse(text) is not { } hotkey) { _store.SetHotkey(null, action.IniKey); return; }
        var taken = HotkeyAction.All.FirstOrDefault(a => a.IniKey != action.IniKey && _store.Hotkeys.TryGetValue(a.IniKey, out var h) && h.Equals(hotkey));
        if (taken.IniKey == null) { _store.SetHotkey(hotkey, action.IniKey); return; }
        Alert.Ask(Vb("TextMessages24", "Внимание"),
                  $"{Vb("TextMessages21", "Комбинация")} {hotkey.Text} {Vb("TextMessages22", "занята в")} «{Caption(taken)}»\n{Vb("TextMessages23", "Использовать для новой функции?")}",
                  new[] { Vb("TextMessages6", "Да"), Vb("TextMessages7", "Нет") },
                  answer => { if (answer == 0) _store.SetHotkey(hotkey, action.IniKey, taken.IniKey); ReloadPickers(); });
    }

    void SaveSet() => Prompt.Ask(Vb("TextMessages20", "Сохранение набора горячих клавиш"), Vb("TextMessages19", "Сохранить набор:"), S.HotkeySetName, name =>
    {
        name = name.Trim();
        if (name.Length == 0) return;
        S.HotkeySets.Replace(name, new Dictionary<string, Hotkey>(_store.Hotkeys));
        S.HotkeySetName = name;
        RebuildSets();
    });

    void DeleteSet()
    {
        if (S.HotkeySets.Order.Count <= 1) return;
        Alert.Ask(Vb("TextMessages18", "Удаление набора горячих клавиш"), $"{Vb("TextMessages17", "Удалить набор:")} {S.HotkeySetName}",
                  new[] { Vb("TextMessages6", "Да"), Vb("TextMessages7", "Нет") }, answer =>
                  {
                      if (answer != 0) return;
                      S.HotkeySets.Remove(S.HotkeySetName);
                      S.HotkeySetName = S.HotkeySets.PreferredSetName ?? "";
                      RebuildSets();
                  });
    }

    void RebuildSets()
    {
        if (_sets == null) return;
        _sets.SetItems(S.HotkeySets.Order);
        _sets.SelectedIndex = Math.Max(0, S.HotkeySets.Order.IndexOf(S.HotkeySetName));
        ReloadPickers();
    }

    List<string> Choices(HotkeyAction action)
    {
        var result = new List<string> { "—" };
        result.AddRange(Candidates);
        if (_store.Hotkeys.TryGetValue(action.IniKey, out var h) && !result.Contains(h.Text)) result.Insert(1, h.Text);
        return result;
    }

    void ReloadPickers()
    {
        foreach (var action in HotkeyAction.All)
        {
            if (!_pickers.TryGetValue(action.IniKey, out var picker)) continue;
            var list = Choices(action);
            picker.SetItems(list);
            var current = _store.Hotkeys.TryGetValue(action.IniKey, out var h) ? h.Text : "—";
            picker.SelectedIndex = Math.Max(0, list.IndexOf(current));
        }
    }

    static readonly List<string> Candidates = Build();
    static List<string> Build()
    {
        var functions = Enumerable.Range(1, 12).Select(n => "F" + n).ToList();
        var letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".Select(c => c.ToString()).ToList();
        var result = new List<string>();
        result.AddRange(functions);
        result.AddRange(new[] { "Esc", "Space", "Ins", "Del", "Home", "End", "PgUp", "PgDn" });
        result.AddRange(functions.Select(f => "Ctrl+" + f));
        result.AddRange(letters.Select(l => "Ctrl+" + l));
        result.AddRange(functions.Select(f => "Ctrl+Shift+" + f));
        result.AddRange(letters.Select(l => "Ctrl+Alt+" + l));
        return result;
    }
}
