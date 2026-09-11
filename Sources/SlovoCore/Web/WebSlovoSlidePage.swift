import Foundation

/// Сторінка «як на проекторі»: малює об'єкти шаблону, а не лише текст.
///
/// Сторінки автора (`VBWebSlide.html` і її рідня) кладуть надісланий текст у
/// свою верстку і про шаблон не знають нічого — їм його й не надсилали. Ця
/// сторінка отримує розкладку (`Layout`) і ставить об'єкти за тими самими частками
/// полотна, за якими їх малює проектор: фон, написи, логотип, підкладки,
/// контур, тінь.
///
/// Сторінка лежить у коді, а не файлом у теці `RemoteAPI`. Причин дві: тека
/// з даними чужа — це тека VisioBible, і класти в неї свої файли не можна;
/// а текст, що лежить поруч із кодом, не роз'їдеться з ним при оновленні.
///
/// Підгонка кегля зроблена так само, як на слайді: рядок стискається, поки не
/// влізе в рамку, але не дрібніше за `MinimumScale`. Рахує це сам браузер —
/// двійковим пошуком за висотою, за пару десятків проб; на зміну вірша йдуть
/// частки мілісекунди, і текст не «стрибає».
enum WebSlovoSlidePage {

    static let fileName = "slovo-slide.html"

    static func html(webSocketPort: Int, host: String) -> String {
        let address = "ws://\(host):\(webSocketPort)/ws"
        return """
        <!DOCTYPE html>
        <html lang="uk">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Слово — слайд</title>
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
          #stage { position: relative; width: 100vw; height: 100vh; overflow: hidden;
                   background-position: center; background-repeat: no-repeat; }
          #stage.tile { background-repeat: repeat; }
          .obj { position: absolute; display: flex; box-sizing: border-box;
                 overflow: hidden; white-space: pre-wrap; }
          .obj > span { display: block; width: 100%; }
          .obj img { width: 100%; height: 100%; object-fit: contain; }
          #idle { position: absolute; left: 0; right: 0; bottom: 2vh; text-align: center;
                  color: rgba(255,255,255,.35); font: 400 1.6vh -apple-system, system-ui, sans-serif; }
        </style>
        </head>
        <body>
        <div id="stage"></div>
        <div id="idle">\(OurWords.t("Слово — ожидаем слайд…"))</div>
        <script>
        (function () {
          var stage = document.getElementById('stage');
          var idle = document.getElementById('idle');
          var layout = null, hidden = false;

          function px(share) { return share * stage.clientHeight; }

          // Кегль добирається так само, як на слайді: стискаємо, поки не влізе,
          // але не дрібніше, ніж дозволяє шаблон.
          function fit(box, span, base, minimumScale) {
            var low = Math.max(0.05, minimumScale || 1), high = 1;
            span.style.fontSize = base + 'px';
            if (span.scrollHeight <= box.clientHeight && span.scrollWidth <= box.clientWidth) return;
            for (var i = 0; i < 18 && high - low > 0.01; i++) {
              var middle = (low + high) / 2;
              span.style.fontSize = (base * middle) + 'px';
              if (span.scrollHeight <= box.clientHeight && span.scrollWidth <= box.clientWidth) {
                low = middle;
              } else {
                high = middle;
              }
            }
            span.style.fontSize = (base * low) + 'px';
          }

          // Шрифти шаблону в браузера не встановлено — беремо файлом із
          // сервера. Правило додаємо один раз на родину: перезапис стирав
          // би вже завантажений шрифт і на зміну вірша блимав би текст.
          var loaded = {};
          function fonts(table) {
            Object.keys(table).forEach(function (family) {
              if (loaded[family]) return;
              loaded[family] = true;
              var rule = document.createElement('style');
              rule.textContent = '@font-face { font-family: "' + family
                + '"; src: url("/slide-font/' + table[family] + '"); font-display: swap; }';
              document.head.appendChild(rule);
            });
          }

          function draw() {
            stage.innerHTML = '';
            if (!layout || hidden) { idle.style.display = ''; stage.style.background = '#000'; return; }
            idle.style.display = 'none';

            fonts(layout.Fonts || {});
            stage.style.backgroundColor = overlay ? 'transparent' : (layout.Background.Color || '#000');
            stage.className = layout.Background.FillMode === 'repeat' ? 'tile' : '';
            if (layout.Background.Image) {
              stage.style.backgroundImage = 'url("/slide-image/' + layout.Background.Image + '")';
              stage.style.backgroundSize =
                layout.Background.FillMode === 'repeat' ? 'auto' : layout.Background.FillMode;
            } else {
              stage.style.backgroundImage = 'none';
            }

            (layout.Objects || []).forEach(function (item) {
              var box = document.createElement('div');
              box.className = 'obj';
              box.style.left = (item.X * 100) + '%';
              box.style.top = (item.Y * 100) + '%';
              box.style.width = (item.Width * 100) + '%';
              box.style.height = (item.Height * 100) + '%';
              box.style.opacity = item.Opacity;
              box.style.background = item.Background;
              if (item.CornerRadius) box.style.borderRadius = px(item.CornerRadius) + 'px';
              if (item.Blur) box.style.backdropFilter = 'blur(' + px(item.Blur) + 'px)';
              box.style.alignItems = item.VerticalAlign;
              box.style.justifyContent =
                item.Align === 'left' ? 'flex-start' : (item.Align === 'right' ? 'flex-end' : 'center');

              if (item.Image) {
                var picture = document.createElement('img');
                picture.src = '/slide-image/' + item.Image;
                box.appendChild(picture);
                stage.appendChild(box);
                return;
              }

              var span = document.createElement('span');
              span.textContent = item.Text;
              span.style.color = item.Color;
              span.style.fontFamily = '"' + item.FontFamily + '", system-ui, sans-serif';
              span.style.fontWeight = item.Bold ? '700' : '400';
              span.style.fontStyle = item.Italic ? 'italic' : 'normal';
              span.style.textDecoration = item.Underline ? 'underline' : 'none';
              span.style.textAlign = item.Align;
              // У шаблоні це ДОБАВКА до рядка, а не множник: у слайда
              // `paragraph.lineSpacing = кегль × значення` поверх звичайної
              // висоти рядка. У CSS висота задається множником, тому
              // додаємо: звичайний рядок ≈ 1,2 кегля плюс добавка.
              span.style.lineHeight = 1.2 + (item.LineSpacing > 0 ? item.LineSpacing : 0);

              var effects = [];
              if (item.ShadowBlur || item.ShadowOffset) {
                effects.push(px(item.ShadowOffset) + 'px ' + px(item.ShadowOffset) + 'px '
                             + px(item.ShadowBlur) + 'px ' + item.ShadowColor);
              }
              if (effects.length) span.style.textShadow = effects.join(', ');
              if (item.OutlineWidth > 0) {
                span.style.webkitTextStrokeWidth = px(item.OutlineWidth) + 'px';
                span.style.webkitTextStrokeColor = item.OutlineColor;
                // Обведення в браузері малюється ПОВЕРХ літер і з'їдає їхні тонкі
                // місця. Фарбуємо його під текстом — так само, як на слайді.
                span.style.paintOrder = 'stroke fill';
              }

              box.appendChild(span);
              stage.appendChild(box);
              fit(box, span, px(item.FontSize), item.MinimumScale);
            });
          }

          function apply(data) {
            if (data.Event && data.Event.Name === 'HideSlide') { hidden = true; draw(); return; }
            hidden = false;
            if (data.Layout) layout = data.Layout;
            draw();
          }

          function connect() {
            var socket = new WebSocket('\(address)');
            socket.onopen = function () {
              socket.send(JSON.stringify({ Cmd: 'SubscribeToSlideChanges', Params: 'Out0' }));
            };
            socket.onmessage = function (event) {
              try { apply(JSON.parse(event.data)); } catch (e) { /* чужой пакет — не наш */ }
            };
            // Обрив зв'язку посеред служіння не має лишати чорний екран
            // назавжди: пробуємо знову, поки не вийде.
            socket.onclose = function () { setTimeout(connect, 1500); };
            socket.onerror = function () { socket.close(); };
          }

          window.addEventListener('resize', draw);
          connect();
        })();
        </script>
        </body>
        </html>
        """
    }
}
