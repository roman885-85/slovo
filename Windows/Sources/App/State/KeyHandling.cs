// =============================================================================
//  KeyHandling.cs — клавіатура головного вікна (як ArrowNavigator, монітор
//  DeskModel, NativeWindowHotkeys і клавіші меню на Mac)
// =============================================================================
//  Сполучення — з hotkeys.ini («Параметри → Гарячі клавіші», ядро
//  EffectiveHotkeys); поки файл не прочитано — звичні запасні (F5, Esc, F12…).
//  Стрілки: ↑↓ ведуть і зал (за ввімкненої «Активна»), ←→ — лише передпоказ;
//  Ctrl міняє пари місцями; Shift — розсунути виділення. PageUp/PageDown,
//  Home/End (пульт доповідача) — завжди в зал; «.» і «b» — затемнення.
//  Цифри над списком — набір номера вірша (Enter — перейти й показати).
//  Поки курсор у полі вводу, стрілки й літери належать полю.
// =============================================================================

using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public static class KeyHandling
{
    /// Хто відповідає за поля (смуга перекладів і колонки Біблії ставлять себе).
    public static Func<QuickFieldKind, bool>? FocusQuick;
    public static Func<QuickFieldKind?>? FocusedQuick;
    public static Action? FocusAddress, FocusPlan, FocusVerses;
    /// Клавіші вкладки «Пісні» (Ctrl+S, Ins, Del, Ctrl+Enter) — поза полями вводу.
    public static Func<Hotkey, bool>? SongKey;

    public enum QuickFieldKind { Book, Chapter, Verse }

    static string _typed = "";
    static DispatcherTimer? _typedTimeout;

    public static void Install(Window window, AppState state)
    {
        window.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            if (e.Handled) return;
            var typing = window.FocusManager?.GetFocusedElement() is TextBox;
            if (Handle(e, state, typing)) e.Handled = true;
        }, RoutingStrategies.Tunnel);
    }

    static string KeyName(Key key) => key switch
    {
        >= Key.F1 and <= Key.F24 => "F" + (key - Key.F1 + 1),
        Key.Escape => "Esc", Key.Space => "Space", Key.Insert => "Ins", Key.Delete => "Del",
        Key.Home => "Home", Key.End => "End", Key.PageUp => "PgUp", Key.PageDown => "PgDn",
        Key.Enter => "Enter", Key.Tab => "Tab", Key.Back => "BackSpace",
        Key.Up => "Up", Key.Down => "Down", Key.Left => "Left", Key.Right => "Right",
        >= Key.A and <= Key.Z => ((char)('A' + (key - Key.A))).ToString(),
        >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => ((char)('0' + (key - Key.NumPad0))).ToString(),
        _ => key.ToString(),
    };

    /// Запасні сполучення меню (як Keys.* на Mac), поки hotkeys.ini немає.
    static readonly Dictionary<string, Hotkey> Fallback = new()
    {
        ["ShowSlide"] = new Hotkey(false, false, false, "F5"),
        ["HideSlide"] = new Hotkey(false, false, false, "Esc"),
        ["ShowBlankSlide"] = new Hotkey(true, false, false, "F5"),
        ["ShowBlackScreen"] = new Hotkey(false, false, false, "F12"),
        ["ShowBackGrOnSlide"] = new Hotkey(true, false, false, "F9"),
        ["ScreenShot"] = new Hotkey(false, false, false, "F11"),
        ["MainWin"] = new Hotkey(false, false, false, "F6"),
        ["Search"] = new Hotkey(false, false, false, "F3"),
        ["FastSearchWindow"] = new Hotkey(true, false, false, "F3"),
        ["FastInput"] = new Hotkey(false, false, false, "F4"),
        ["Plan"] = new Hotkey(false, false, false, "F2"),
    };

    static Hotkey? Assigned(string action) =>
        EffectiveHotkeys.Layout.TryGetValue(action, out var key) ? key : Fallback.TryGetValue(action, out var spare) ? spare : null;

    static bool Matches(string action, Hotkey pressed) => Assigned(action) is { } key && key.Equals(pressed);

    static bool Handle(KeyEventArgs e, AppState state, bool typing)
    {
        var name = KeyName(e.Key);
        var control = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        var pressed = new Hotkey(control, alt, shift, name);
        // У полі вводу без модифікаторів — лише функціональні клавіші та Esc.
        if (!typing && PlanKey(e, state, control || alt || shift)) return true;
        if (!typing && (SongKey?.Invoke(pressed) ?? false)) return true;
        var reserved = !control && !alt && !(name.Length > 1 && name[0] == 'F' && char.IsDigit(name[1])) && name != "Esc";
        if (!(typing && reserved) && MenuKey(pressed, state)) return true;
        if (!(typing && reserved) && DeskKey(pressed, state)) return true;
        if (typing) return QuickTab(e, shift);
        if (WindowKey(pressed, state)) return true;
        if (TypedVerse(e, state, control || alt)) return true;
        return Arrows(e, state, control, shift, alt);
    }

    /// Пункти меню «Дії» зі своїми клавішами.
    static bool MenuKey(Hotkey pressed, AppState state)
    {
        if (Matches("ShowSlide", pressed)) { state.ShowCurrent?.Invoke(); return true; }
        if (Matches("HideSlide", pressed))
        {
            if (_typed.Length > 0) { ClearTyped(); return true; }
            if (!state.IsLive) return false;
            state.HideSlide();
            return true;
        }
        if (Matches("ShowBlankSlide", pressed)) { state.ShowBlankSlide(); return true; }
        if (Matches("ShowBlackScreen", pressed)) { state.ShowBlackScreen(); return true; }
        if (Matches("ShowBackGrOnSlide", pressed)) { state.ToggleBackground(); return true; }
        if (Matches("ScreenShot", pressed)) { state.SaveScreenshot(); return true; }
        if (Matches("MainWin", pressed)) { FocusVerses?.Invoke(); return true; }
        // Ctrl+M «Відкрити медіаплеєр» і Ctrl+P «Медіаплеєр: відтворити/пауза» (MediaHotkeys на Mac):
        // у hotkeys.ini автора вони є, а обробника в оригіналі не було.
        if (Matches("ShowMediaPlayer", pressed)) { ToggleMediaTab(state); return true; }
        if (Matches("MediaPlayerPlayPause", pressed)) { state.Media.PlayPause(); return true; }
        return false;
    }

    /// Вкладка «Медіа» — і назад, звідки прийшли (ModeBeforeMedia).
    static void ToggleMediaTab(AppState state)
    {
        state.Mode = state.Mode == WorkMode.Media ? state.ModeBeforeMedia : WorkMode.Media;
        Signals.Shared.Send(Signals.Kind.Mode);
    }

    /// Монітор «Стола»: пошук, швидкий вибір, План.
    static bool DeskKey(Hotkey pressed, AppState state)
    {
        if (Matches("FastSearchWindow", pressed)) { state.ToggleSearchResults(); return true; }
        if (Matches("Search", pressed)) { state.FocusSearchField(); return true; }
        if (Matches("FastInput", pressed)) { FocusAddress?.Invoke(); return true; }
        if (Matches("Plan", pressed)) { FocusPlan?.Invoke(); return true; }
        if (Matches("FastInputBook", pressed)) { FocusQuick?.Invoke(QuickFieldKind.Book); return true; }
        if (Matches("FastInputChapter", pressed)) { FocusQuick?.Invoke(QuickFieldKind.Chapter); return true; }
        if (Matches("FastInputVers", pressed)) { FocusQuick?.Invoke(QuickFieldKind.Verse); return true; }
        return false;
    }

    /// Поки фокус на Плані (F2), стрілки гортають його пункти, Enter подає виділений,
    /// Del і Backspace видаляють (3.1) — інакше стрілки гортали б вірші.
    static bool PlanKey(KeyEventArgs e, AppState state, bool modified)
    {
        if (modified || !state.IsPlanFocused || state.Plan.IsEmpty) return false;
        switch (e.Key)
        {
            case Key.Up: state.StepPlanSelection(-1); return true;
            case Key.Down: state.StepPlanSelection(1); return true;
            case Key.Enter:
                if (state.FocusedPlanItem is { } item) state.ActivatePlanItem(item);
                return true;
            case Key.Delete or Key.Back: state.DeletePlanSelection(); return true;
        }
        return false;
    }

    /// Tab у полях швидкого вибору — по колу, як в оригіналі (5.1.6).
    static bool QuickTab(KeyEventArgs e, bool shift)
    {
        if (e.Key != Key.Tab || FocusedQuick?.Invoke() is not { } current) return false;
        var next = (QuickFieldKind)(((int)current + (shift ? 2 : 1)) % 3);
        return FocusQuick?.Invoke(next) ?? false;
    }

    /// Вибір фонів клавішами (Ctrl+B, Ctrl+Alt+B) і Ctrl+E у пісеннику — не під час набору.
    static bool WindowKey(Hotkey pressed, AppState state)
    {
        if (Matches("OpenCommonBG", pressed)) { state.ChooseCommonBackgroundRequested?.Invoke(); return true; }
        if (Matches("OpenSlideBG", pressed)) { state.ChooseSlideBackgroundRequested?.Invoke(); return true; }
        if (Matches("ReactionOnCtrlE", pressed) && state.Mode == WorkMode.Songs) return state.ToggleSongEditMode?.Invoke() ?? false;
        return false;
    }

    /// Номер вірша, набраний над списком: Enter — перейти й показати, Backspace —
    /// стерти цифру, Esc — передумали; пауза 3 с — набір забуто.
    static bool TypedVerse(KeyEventArgs e, AppState state, bool modified)
    {
        if (_typed.Length > 0 && !modified)
        {
            switch (e.Key)
            {
                case Key.Enter:
                    CommitTyped(state);
                    state.ShowCurrent?.Invoke();
                    return true;
                case Key.Back:
                    _typed = _typed[..^1];
                    return true;
                case Key.Escape:
                    ClearTyped();
                    return true;
            }
        }
        if (modified || state.Mode == WorkMode.Songs || state.Mode != WorkMode.Bible) return false;
        var digit = e.Key switch
        {
            >= Key.D0 and <= Key.D9 => (char)('0' + (e.Key - Key.D0)),
            >= Key.NumPad0 and <= Key.NumPad9 => (char)('0' + (e.Key - Key.NumPad0)),
            _ => '\0',
        };
        if (digit == '\0' || e.KeyModifiers.HasFlag(KeyModifiers.Shift)) return false;
        // Чотирьох цифр більше не буває ні в якому розділі; зайве — промах.
        if (_typed.Length >= 4) _typed = "";
        _typed += digit;
        _typedTimeout?.Stop();
        _typedTimeout = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Normal, (s, _) => { ((DispatcherTimer)s!).Stop(); _typed = ""; });
        _typedTimeout.Start();
        return true;
    }

    static void CommitTyped(AppState state)
    {
        if (int.TryParse(_typed, out var number) && state.CurrentChapter?.VerseNumbered(number) != null)
            state.SelectVerse(number, false);
        ClearTyped();
    }

    static void ClearTyped()
    {
        _typedTimeout?.Stop();
        _typedTimeout = null;
        _typed = "";
    }

    /// Стрілки (як ArrowNavigator на Mac).
    static bool Arrows(KeyEventArgs e, AppState state, bool control, bool shift, bool alt)
    {
        var bare = !control && !shift && !alt;
        if (!(bare || (control && !shift && !alt) || (shift && !control && !alt))) return false;
        if (control && e.Key == Key.A) { if (state.Mode == WorkMode.Bible) state.SelectAllVerses(); return true; }
        // Ctrl міняє, яка пара веде зал.
        var linked = state.ArrowsLinked != control;
        if (e.Key == Key.Enter) { state.ShowCurrent?.Invoke(); return true; }
        switch (e.Key)
        {
            case Key.PageDown: case Key.End: Step(state, 1, true); return true;    // пульт доповідача — завжди в зал
            case Key.PageUp: case Key.Home: Step(state, -1, true); return true;
            case Key.OemPeriod: case Key.B:                                       // «затемнити» з пульта
                if (!bare) return false;
                state.ShowBlackScreen();
                return true;
        }
        bool vertical;
        switch (e.Key)
        {
            case Key.Up: case Key.Down: vertical = true; break;
            case Key.Left: case Key.Right: vertical = false; break;
            default: return false;
        }
        var forward = e.Key is Key.Down or Key.Right;
        var live = state.ArrowsShowLive && (linked ? vertical : !vertical);
        if (shift) { if (state.Mode == WorkMode.Bible) state.ExtendSelection(forward ? 1 : -1, live && state.IsLive); }
        else Step(state, forward ? 1 : -1, live);
        return true;
    }

    static void Step(AppState state, int delta, bool live)
    {
        // У показі картинок і презентацій стрілки гортають сторінки: обидві пари
        // ведуть і зал, поки «Активна» ввімкнена; пульт доповідача — завжди.
        if (state.ShowTabs.TryGetValue(state.Mode, out var show))
        {
            show.Step(delta, (live || state.ArrowsShowLive) && state.IsLive);
            return;
        }
        state.StepVerse(delta, live && state.IsLive);
    }
}
