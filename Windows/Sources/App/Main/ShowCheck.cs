// =============================================================================
//  ShowCheck.cs — перевірка «Показ за вкладками» (showTabsSection, Diagnostics+Tour Mac)
// =============================================================================
//  Кроки власника: Біблія → Презентація (сторінка, «Показати», «Сховати») → знову
//  Біблія → вірш у залі → друга сторінка поверх → вірш поверх картинки →
//  презентація поверх вірша. На кожному кроці звіряється, що в передпоказі
//  (вірш чи картинка) і що в залі (картинка чи текст). Саме тут на Mac жила
//  поломка «передпоказ відстає на один». Ключ знімка --show-check.
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public static class ShowCheck
{
    public static string Run(string folder)
    {
        var state = AppState.Shared;
        var window = MainWindow.Shared;
        if (window == null) { window = new MainWindow(state) { Width = 1600, Height = 1000 }; window.Show(); }
        Snapshot.WaitForLibrary();
        var driver = window.Output;
        if (driver == null) return "Показ за вкладками: немає виводу";
        var pdf = Path.Combine(folder, "проба-показу.pdf");
        MakePdf(pdf, 2);
        var presentation = ShowWorkspace.Presentation;
        var steps = new List<string>();
        var faults = new List<string>();

        void Settle(double seconds = 0.4)
        {
            var until = DateTime.Now.AddSeconds(seconds);
            do { Snapshot.Pump(2); Thread.Sleep(15); } while (DateTime.Now < until || !SlideRenderQueue.Shared.IsIdle);
            Snapshot.Pump(2);
        }
        void Go(WorkMode mode)
        {
            state.Mode = mode;
            Signals.Shared.Send(Signals.Kind.Mode);
            Settle();
        }
        (bool Still, string Text) Hall() => (state.IsLive && state.LiveStill != null, state.HallSlide.MainText);
        void Check(string step, Func<string, bool> previewIs, string previewWant, bool? hallStill, string? hallText)
        {
            var shown = driver.PreviewShowing;
            var (still, text) = Hall();
            var line = $"{step}: передпоказ — {(shown.StartsWith("slide:") ? "слайд «" + Short(shown[6..]) + "»" : shown == "still" ? "картинка" : "порожньо")}; зал — картинка {(still ? "є" : "немає")}, текст «{Short(text)}»";
            var wrong = new List<string>();
            if (!previewIs(shown)) wrong.Add("у передпоказі чекали " + previewWant);
            if (hallStill is { } wantStill && still != wantStill) wrong.Add("у залі картинка " + (wantStill ? "має бути" : "не має бути"));
            if (hallText is { } wantText)
            {
                if (wantText.Length == 0 && text.Length > 0) wrong.Add("у залі не має бути тексту");
                if (wantText.Length > 0 && text != wantText) wrong.Add($"у залі чекали текст «{Short(wantText)}»");
            }
            if (wrong.Count > 0) { line += " — НЕ ТАК: " + string.Join(", ", wrong); faults.Add(step); }
            steps.Add(line);
        }
        static bool IsStill(string shown) => shown == "still";
        Func<string, bool> IsSlide(string text) => shown => shown == "slide:" + text;

        // 1. Біблія, показ вимкнено: у передпоказі — підготовлений вірш.
        state.HideSlide();
        state.ClearStill();
        Go(WorkMode.Bible);
        var verse = state.Slide.MainText;
        if (verse.Length == 0) return "Показ за вкладками: у передпоказі немає вірша — немає з чим порівнювати";
        Check("1. Біблія, вірш підготовлено", IsSlide(verse), "вірш", false, "");
        // 2. Презентація відкрита, сторінку вибрано: передпоказ — картинка.
        Go(WorkMode.Presentation);
        presentation.Open(new[] { pdf });
        Settle(1.0);
        presentation.SelectPage(0);
        Settle();
        Check("2. Презентація, сторінку 1 вибрано", IsStill, "картинку", false, "");
        // 3. «Показати»: картинка в залі, тексту під нею немає.
        presentation.ShowCurrentPage();
        Settle();
        Check("3. Презентація в залі", IsStill, "картинку", true, "");
        // 4. «Сховати» картинку.
        presentation.HideCurrentPage();
        Settle();
        Check("4. Презентацію сховано", _ => true, "будь-що", false, "");
        // 5. Знову Біблія: передпоказ мусить показати вірш, а не закриту картинку.
        Go(WorkMode.Bible);
        Check("5. Знову Біблія", IsSlide(verse), "вірш", false, "");
        // 6. «Показати» вірш: у залі текст, картинки немає.
        state.ShowCurrentSlide();
        Settle();
        Check("6. Вірш у залі", IsSlide(verse), "вірш", false, verse);
        // 7–8. Сховати вірш, презентація, друга сторінка, «Показати».
        state.HideSlide();
        Settle(0.2);
        Go(WorkMode.Presentation);
        presentation.SelectPage(1);
        Settle();
        Check("7. Презентація, сторінку 2 вибрано", IsStill, "картинку", false, "");
        presentation.ShowCurrentPage();
        Settle();
        Check("8. Сторінка 2 в залі", IsStill, "картинку", true, "");
        // 9–10. У Біблію, не ховаючи картинки, і «Показати»: текст змінює картинку.
        Go(WorkMode.Bible);
        Check("9. Біблія при картинці в залі", IsSlide(verse), "вірш", true, "");
        state.ShowCurrentSlide();
        Settle(0.8);
        Check("10. Вірш поверх картинки", IsSlide(verse), "вірш", false, verse);
        // 11. І знову презентація без ховання: картинка змінює текст.
        Go(WorkMode.Presentation);
        presentation.ShowCurrentPage();
        Settle(0.8);
        Check("11. Презентація поверх вірша", IsStill, "картинку", true, "");

        state.HideSlide();
        state.ClearStill();
        Go(WorkMode.Bible);
        return "Показ за вкладками: " + (faults.Count == 0 ? "усі кроки зійшлися" : "розійшлися кроки: " + string.Join("; ", faults))
               + "\n    " + string.Join("\n    ", steps);
    }

    static string Short(string text) => text.Length > 24 ? text[..24] + "…" : text;

    /// Пробний PDF на кілька сторінок (різні кольори й номер сторінки).
    static void MakePdf(string path, int pages)
    {
        using var stream = File.Create(path);
        using var document = SKDocument.CreatePdf(stream);
        for (var i = 0; i < pages; i++)
        {
            var canvas = document.BeginPage(800, 450);
            canvas.Clear(i % 2 == 0 ? new SKColor(0x2A, 0x5D, 0xB0) : new SKColor(0xB0, 0x5D, 0x2A));
            using var paint = new SKPaint { Color = SKColors.White, TextSize = 96, IsAntialias = true };
            canvas.DrawText($"Сторінка {i + 1}", 120, 260, paint);
            document.EndPage();
        }
        document.Close();
    }
}
