// =============================================================================
//  WindowDrop.cs — файли, кинуті у вікно програми (NativeWindowDrop Mac 1.3.9)
// =============================================================================
//  На служінні файл найчастіше вже лежить на столі: фотографія, презентація,
//  фільм. Вікно приймає файл як є і саме вирішує, якій вкладці він належить —
//  за розширенням (тип від системи буває не присвоєно, а розширення є завжди).
//  Те, що приймає свої файли саме (список фонограм, кадр плеєра), бере їх
//  раніше: подія до вікна тоді не доходить.
// =============================================================================

using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;

namespace Slovo.App;

public static class WindowDrop
{
    public enum Kind { Pictures, Presentation, Media, Nothing }

    /// Кому належить кинуте. Презентація старша за картинки (картинки в ній і так усередині);
    /// теку з картинками кидають цілком; усе інше — плеєрові, якщо він це грає.
    public static (Kind Kind, List<string> Paths) Route(IReadOnlyList<string> paths, Func<string, bool> playable)
    {
        static string Ext(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (paths.FirstOrDefault(p => ShowModel.Extensions(ShowModel.Kind.Presentation).Contains(Ext(p))) is { } slides)
            return (Kind.Presentation, new List<string> { slides });
        var pictures = paths.Where(p => ShowModel.Extensions(ShowModel.Kind.Pictures).Contains(Ext(p)) || Directory.Exists(p)).ToList();
        if (pictures.Count > 0) return (Kind.Pictures, pictures);
        if (paths.FirstOrDefault(playable) is { } media) return (Kind.Media, new List<string> { media });
        return (Kind.Nothing, new List<string>());
    }

    /// Прийняти кинуте. false — серед файлів немає нічого нашого.
    public static bool Accept(IReadOnlyList<string> paths)
    {
        var state = AppState.Shared;
        if (paths.Count == 0) return false;
        var (kind, chosen) = Route(paths, state.Media.Filters.Accepts);
        switch (kind)
        {
            case Kind.Presentation:
                ShowWorkspace.Presentation.Open(chosen);
                Switch(state, WorkMode.Presentation);
                return true;
            case Kind.Pictures:
                ShowWorkspace.Pictures.Open(chosen);
                Switch(state, WorkMode.Pictures);
                return true;
            case Kind.Media:
                state.Media.Open(chosen[0]);
                Switch(state, WorkMode.Media);
                return true;
            default:
                return false;
        }
    }

    static void Switch(AppState state, WorkMode mode)
    {
        if (state.Mode == mode) return;
        state.Mode = mode;
        Signals.Shared.Send(Signals.Kind.Mode);
    }

    /// Підключити до вікна: копіювання, а не переміщення — файл лишається на місці.
    public static void Install(Window window)
    {
        DragDrop.SetAllowDrop(window, true);
        window.AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            if (e.Handled) return;
            e.DragEffects = Files(e).Count > 0 ? DragDropEffects.Copy : DragDropEffects.None;
        });
        window.AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            if (e.Handled) return;
            if (Accept(Files(e))) e.Handled = true;
        });
    }

#pragma warning disable CS0618
    static List<string> Files(DragEventArgs e) => e.Data.GetFiles()?.Select(f => f.TryGetLocalPath()).OfType<string>().ToList() ?? new();
#pragma warning restore CS0618
}
