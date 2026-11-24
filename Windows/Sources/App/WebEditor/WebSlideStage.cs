// =============================================================================
//  WebSlideStage.cs — живий передпоказ сторінки (за NativeWebSlideStage.swift)
// =============================================================================
//  Два правила, заради яких його написано окремо.
//  Перше: перезавантаження лише при зміні розмітки. Значення змінної доїжджає до
//  сторінки скриптом `setProperty` (інлайновий стиль на `documentElement` б'є
//  будь-яке правило `:root`), тож картинка міняється одразу й без блимання.
//  Друге: миша над передпоказом належить редакторові — вона перетягує блок
//  тексту до однієї з дев'яти точок прив'язки (плюс тонкий зсув).
//  Сцена чорна на всю панель, сторінка — кадром 16:9 посередині (як зал).
//  «Своя картинка…» лягає під сторінку: видно, як титри стануть на кадр із залу.
// =============================================================================

using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebSlideStage : LayoutPanel
{
    readonly WebSlideEditorModel _model;
    readonly Canvas _canvas;
    readonly WebPreviewHost? _web;
    readonly BottomCaption _note = new() { FontSize = 11, Align = TextAlignment.Center, Color = () => Color.FromArgb(150, 255, 255, 255) };
    string _key = "";
    Dictionary<string, string> _applied = new(StringComparer.Ordinal);
    int _tick;
    bool _loading;
    Point? _dragTo;
    string? _lastPlaced;
    /// Своя картинка під сторінкою: з нею видно, що перекриває титр.
    string? _backdrop;
    Bitmap? _backdropImage;

    public WebSlideStage(WebSlideEditorModel model)
    {
        _model = model;
        // Миша над усією сценою — редакторові (і над чорними полями довкола кадру).
        Background = Brushes.Transparent;
        _canvas = new Canvas(this);
        Children.Add(_canvas);
        if (OperatingSystem.IsWindows())
        {
            if (WebPreviewHost.RuntimeVersion() != null)
            {
                _web = new WebPreviewHost();
                _web.Loaded += () => { _loading = false; Push(); };
                _web.Message += Received;
                _web.Failed += reason => { _note.Text = reason; Children.Remove(_web); };
                Children.Add(_web);
            }
            else _note.Text = Captions.T("Предпросмотр недоступен: в Windows нет Microsoft Edge WebView2 Runtime. Установите его с сайта Microsoft — или откройте страницу в браузере.");
        }
        Children.Add(_note);
        Layout = size =>
        {
            Place(_canvas, new Rect(size));
            var frame = StageFrame(size);
            if (_web != null && Children.Contains(_web)) Place(_web, frame);
            Place(_note, new Rect(frame.X + 16, frame.Center.Y - 30, Math.Max(0, frame.Width - 32), 60));
        };
    }

    /// Ctrl+S, поки клавіатура в передпоказі.
    public Action? SaveShortcut { set { if (_web != null) _web.SaveShortcut = value; } }

    /// Кадр 16:9 усередині панелі — ті самі пропорції, що в екрана в залі.
    static Rect StageFrame(Size size)
    {
        var side = WebSlidePlacement.Frame(size);
        return new Rect((size.Width - side.Width) / 2, (size.Height - side.Height) / 2, side.Width, side.Height);
    }

    /// Підкласти свій файл (або прибрати, якщо null).
    public void SetBackdrop(string? file)
    {
        _backdrop = file;
        _backdropImage?.Dispose();
        _backdropImage = null;
        if (file != null)
        {
            try { _backdropImage = new Bitmap(file); } catch { _backdrop = null; }
        }
        _canvas.InvalidateVisual();
        // Під справжньою сторінкою картинка лягає фоном самої сторінки — перезавантажити.
        if (_web != null) { _key = ""; Refresh(); }
    }

    // ── Оновлення ─────────────────────────────────────────────────────────────

    public void Refresh()
    {
        if (_key != _model.PreviewReloadKey)
        {
            _key = _model.PreviewReloadKey;
            // Після перезавантаження сторінка візьме значення з власного блоку.
            _applied = new Dictionary<string, string>(_model.PreviewValues, StringComparer.Ordinal);
            _loading = true;
            Load();
            return;
        }
        Push();
        if (_tick != _model.Command.Tick)
        {
            _tick = _model.Command.Tick;
            Run(_model.Command.Script);
        }
    }

    void Load()
    {
        if (_web == null) { _loading = false; return; }
        var html = Decorated(_model.PreviewHtml);
        var folder = _model.PreviewFolder ?? Path.Combine(Path.GetTempPath(), "Слово-предпросмотр");
        try
        {
            Directory.CreateDirectory(folder);
            var backdropName = "";
            if (_backdrop != null && File.Exists(_backdrop))
            {
                backdropName = "slovo-backdrop" + Path.GetExtension(_backdrop);
                File.Copy(_backdrop, Path.Combine(folder, backdropName), true);
            }
            var file = Path.Combine(folder, "preview.html");
            File.WriteAllText(file, backdropName.Length == 0 ? html : WithBackdrop(html, backdropName), new UTF8Encoding(false));
            _web.Navigate(new Uri(file).AbsoluteUri);
        }
        catch (Exception error) { Journal.Say("веб-редактор: передпоказ не записався — " + error.Message); }
    }

    /// Своя картинка — фоном кореня сторінки: прозора сторінка показує її, непрозора — ховає
    /// (як шар під WKWebView на Mac). Лише в рядку для показу, у файлі — ні байта.
    static string WithBackdrop(string html, string name)
    {
        var style = $"<style>html {{ background: url(\"{name}\") center / cover no-repeat #000 !important; }}</style>";
        var close = html.LastIndexOf("</head>", StringComparison.OrdinalIgnoreCase);
        return close >= 0 ? html[..close] + style + html[close..] : style + html;
    }

    /// Завіса миші й точки прив'язки — лише в передпоказі: миша належить редакторові.
    static string Decorated(string html)
    {
        const string script = """
            <script>
            (function () {
              if (!window.chrome || !window.chrome.webview) return;
              var dots = [], down = false;
              function send(kind, e) {
                window.chrome.webview.postMessage(kind + " " + (e.clientX / Math.max(1, window.innerWidth))
                  + " " + (e.clientY / Math.max(1, window.innerHeight)));
              }
              function build() {
                var shield = document.createElement("div");
                shield.style.cssText = "position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483647;background:transparent;cursor:default";
                for (var i = 0; i < 9; i++) {
                  var dot = document.createElement("div");
                  dot.style.cssText = "position:absolute;border-radius:50%;display:none;pointer-events:none";
                  shield.appendChild(dot);
                  dots.push(dot);
                }
                shield.addEventListener("mousedown", function (e) { if (e.button !== 0) return; down = true; send("down", e); e.preventDefault(); });
                window.addEventListener("mousemove", function (e) { if (down) send("move", e); });
                window.addEventListener("mouseup", function (e) { if (!down) return; down = false; send("up", e); });
                shield.addEventListener("contextmenu", function (e) { e.preventDefault(); });
                document.documentElement.appendChild(shield);
              }
              /* Дев'ять точок прив'язки — видно, куди стане блок. */
              window.slovoDots = function (column, row) {
                for (var i = 0; i < 9; i++) {
                  var dot = dots[i];
                  if (!dot) continue;
                  if (column < 0) { dot.style.display = "none"; continue; }
                  var live = (i % 3) === column && Math.floor(i / 3) === row;
                  var size = live ? 14 : 8;
                  dot.style.display = "block";
                  dot.style.width = dot.style.height = size + "px";
                  dot.style.left = ((i % 3) * 50) + "%";
                  dot.style.top = (Math.floor(i / 3) * 50) + "%";
                  dot.style.marginLeft = dot.style.marginTop = (-size / 2) + "px";
                  dot.style.background = live ? "#0A84FF" : "rgba(255,255,255,0.35)";
                }
              };
              if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", build); else build();
            })();
            </script>
            """;
        var close = html.LastIndexOf("</body>", StringComparison.OrdinalIgnoreCase);
        return close >= 0 ? html[..close] + script + html[close..] : html + script;
    }

    /// Дописати сторінці лише значення, що змінилися.
    void Push()
    {
        if (_loading) return;
        var script = new StringBuilder();
        foreach (var (name, value) in _model.PreviewValues)
        {
            if (_applied.TryGetValue(name, out var was) && was == value) continue;
            script.Append("document.documentElement.style.setProperty('").Append(name).Append("','")
                  .Append(value.Replace("\\", "\\\\").Replace("'", "\\'")).Append("');");
        }
        if (script.Length == 0) return;
        _applied = new Dictionary<string, string>(_model.PreviewValues, StringComparer.Ordinal);
        // Після кожної правки просимо сторінку перерахувати кегль: підібраний розмір інакше
        // лишався від попереднього показу, і повзунок «Розмір тексту» здавався мертвим.
        script.Append("if (window.slovoRefit) window.slovoRefit();");
        Run(script.ToString());
    }

    void Run(string script)
    {
        if (script.Length == 0 || _loading) return;
        _web?.Run(script);
    }

    // ── Перетягування блоку ───────────────────────────────────────────────────

    /// Повідомлення завіси сторінки: «down|move|up x y» у частках кадру.
    void Received(string message)
    {
        var parts = message.Split(' ');
        if (parts.Length != 3 || SwiftText.ParseDouble(parts[1]) is not { } x || SwiftText.ParseDouble(parts[2]) is not { } y) return;
        var point = new Point(x, y);
        switch (parts[0])
        {
            case "down": Down(point); break;
            case "move": Drag(point); break;
            case "up": Up(); break;
        }
    }

    void Down(Point point)
    {
        if (!_model.Sheet.Placement.CanDrag) return;
        _dragTo = point;
        ShowDots();
    }

    void Drag(Point point)
    {
        if (!_model.Sheet.Placement.CanDrag || _dragTo == null) return;
        _dragTo = point;
        var title = _model.PlacementTitle(point);
        // Поки точка прив'язки та сама — файл чіпати нема чого.
        if (title != _lastPlaced)
        {
            _lastPlaced = title;
            _model.Place(point);
        }
        ShowDots();
    }

    void Up()
    {
        _dragTo = null;
        _lastPlaced = null;
        ShowDots();
    }

    void ShowDots()
    {
        _canvas.InvalidateVisual();
        if (_web == null) return;
        if (_dragTo is { } point)
        {
            var target = WebSlidePlacement.Drop(point);
            _web.Run($"if (window.slovoDots) window.slovoDots({target.Column},{target.Row});");
        }
        else _web.Run("if (window.slovoDots) window.slovoDots(-1,-1);");
    }

    Point Fraction(PointerEventArgs e)
    {
        var frame = StageFrame(Bounds.Size);
        var position = e.GetPosition(this);
        if (frame.Width <= 0 || frame.Height <= 0) return default;
        return new Point((position.X - frame.X) / frame.Width, (position.Y - frame.Y) / frame.Height);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        e.Pointer.Capture(this);
        Down(Fraction(e));
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_dragTo != null) Drag(Fraction(e));
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (_dragTo == null) return;
        e.Pointer.Capture(null);
        Up();
    }

    /// Чорна сцена, своя картинка й точки прив'язки (коли сторінки не видно).
    sealed class Canvas : Control
    {
        readonly WebSlideStage _stage;
        public Canvas(WebSlideStage stage) { _stage = stage; IsHitTestVisible = false; }

        public override void Render(DrawingContext g)
        {
            var bounds = new Rect(Bounds.Size);
            g.FillRectangle(Brushes.Black, bounds);
            var frame = StageFrame(Bounds.Size);
            if (_stage._backdropImage is { } image && image.Size.Width > 0 && image.Size.Height > 0)
            {
                // Заповнити кадр, обрізавши зайве (resizeAspectFill).
                var scale = Math.Max(frame.Width / image.Size.Width, frame.Height / image.Size.Height);
                var size = new Size(image.Size.Width * scale, image.Size.Height * scale);
                using (g.PushClip(frame))
                    g.DrawImage(image, new Rect(frame.Center.X - size.Width / 2, frame.Center.Y - size.Height / 2, size.Width, size.Height));
            }
            if (_stage._dragTo is not { } point) return;
            var target = WebSlidePlacement.Drop(point);
            for (var index = 0; index < 9; index++)
            {
                int column = index % 3, row = index / 3;
                var dot = WebSlidePlacement.Fraction(column, row);
                var live = target.Column == column && target.Row == row;
                var centre = new Point(frame.X + dot.X * frame.Width, frame.Y + dot.Y * frame.Height);
                var radius = (live ? 14 : 8) / 2.0;
                g.DrawEllipse(Palette.Brush(live ? Palette.Accent : Color.FromArgb(89, 255, 255, 255)), null, centre, radius, radius);
            }
        }
    }
}
