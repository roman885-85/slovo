// =============================================================================
//  ShowDocuments.cs — презентація PowerPoint і PDF для показу
// =============================================================================
//  Презентацію розбирає й малює ядро (PPTXDocument, PPTXRenderer — як на Mac).
//  PDF на Mac малює CoreGraphics; тут — PDFium (пакет PDFtoImage) на білому
//  аркуші, з власним поворотом сторінки, у висоту залу.
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public static class ShowDocuments
{
    /// Підключити відкривачі до моделі показу — раз на запуск.
    public static void Install()
    {
        ShowModel.OpenPresentation = path => new Presentation(path);
        ShowModel.OpenPdf = path => new Portable(path);
    }

    static SKImage? Freeze(SKBitmap? bitmap)
    {
        if (bitmap == null) return null;
        using (bitmap)
        {
            using var pixels = bitmap.PeekPixels();
            return pixels == null ? null : SKImage.FromPixelCopy(pixels);
        }
    }

    sealed class Presentation : IShowDocument
    {
        readonly PPTXDocument _document;
        public Presentation(string path) { _document = new PPTXDocument(path); }
        public int Count => _document.Count;

        /// Сторінка презентації у висоту залу: менше — мило на проекторі, більше — даремно.
        public SKImage? Render(int page, int height)
        {
            if (page < 0 || page >= _document.Slides.Count) return null;
            var canvas = _document.CanvasSize;
            var width = height * (canvas.Width / Math.Max(canvas.Height, 1));
            return Freeze(PPTXRenderer.Image(_document.Slides[page], _document, new SizeD(width, height)));
        }

        public void Dispose() { }
    }

    sealed class Portable : IShowDocument
    {
        readonly byte[] _bytes;
        public Portable(string path)
        {
            _bytes = File.ReadAllBytes(path);
#pragma warning disable CA1416
            Count = PDFtoImage.Conversion.GetPageCount(_bytes);
#pragma warning restore CA1416
        }
        public int Count { get; }

        /// Сторінка PDF — білим, а не прозорим: сторінка PDF завжди на білому аркуші.
        public SKImage? Render(int page, int height)
        {
            if (page < 0 || page >= Count) return null;
#pragma warning disable CA1416
            var bitmap = PDFtoImage.Conversion.ToImage(_bytes, page, null,
                new PDFtoImage.RenderOptions { Height = height, WithAspectRatio = true, BackgroundColor = SKColors.White, WithAnnotations = true });
#pragma warning restore CA1416
            return Freeze(bitmap);
        }

        public void Dispose() { }
    }
}
