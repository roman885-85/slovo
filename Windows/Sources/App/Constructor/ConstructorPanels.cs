// =============================================================================
//  ConstructorPanels.cs — панелі властивостей «Конструктора» (NativeConstructorPanels)
// =============================================================================
//  Праворуч, з прокруткою: «Параметри» (ім'я, сцена 2, видимість), «Розміри й
//  місце» (у відсотках полотна, прив'язки, прозорість 0…255), «Тінь» (заготовки,
//  зсув, згладжування, напрямок, прозорість, колір), «Текст» (вирівнювання,
//  шрифт, розмір, Ж/К/Ч, колір, контур) або «Зображення» (файл і маска),
//  «Анімація». Числа — ті самі, що в автора: прозорість — байт, контур — пункти
//  кадру 1080.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed class ConstructorPanels : ScrollViewer
{
    readonly SlideConstructorModel _model;
    readonly Func<string, string, string> _text;
    readonly Func<string, string, string> _hint;
    readonly StackPanel _body = new() { Spacing = 8, Margin = new Thickness(8) };
    public Action? OnChange;

    public ConstructorPanels(SlideConstructorModel model, Func<string, string, string> text, Func<string, string, string> hint)
    {
        _model = model;
        _text = text;
        _hint = hint;
        Content = _body;
        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
    }

    string T(string key, string fallback) => _text(key, fallback);

    public void RefreshValues() => Form.RefreshValues(_body);

    public void Rebuild()
    {
        _body.Children.Clear();
        if (_model.SelectedObject is not { } obj)
        {
            _body.Children.Add(new Form.Group("", new Control[] { new Form.Row("", new Control[] { Form.Label(Captions.T("Объект не выбран")) }) }));
            return;
        }
        _body.Children.Add(Common());
        _body.Children.Add(Geometry());
        _body.Children.Add(ShadowGroup());
        _body.Children.Add(obj.Kind == SlideObjectKind.Image ? ImageFiles(obj) : Appearance());
        _body.Children.Add(Animation());
        foreach (var group in _body.Children.OfType<Form.Group>()) group.Height = group.NeededHeight;
    }

    void Changed() => OnChange?.Invoke();

    // --- Ім'я, сцена 2, видимість ---------------------------------------------------------

    Form.Group Common() => new(T("Panel2", "Параметры"), new Control[]
    {
        new Form.Row(T("Label31", "Имя:"), new Control[]
        {
            Form.Text(new Tie<string>(() => _model.SelectedObject?.Name ?? "", v => { _model.Edit(o => { o.Name = v; return o; }); Changed(); }), 170),
        }, 120),
        new Form.Row("", new Control[]
        {
            Form.Check(T("CBEnableVariant", "Разрешить сцену 2"), new Tie<bool>(() => _model.SecondSceneEnabled, v => { _model.SecondSceneEnabled = v; Changed(); }),
                       _hint("CBEnableVariant", "Активировать независимые настройки сцен для объекта (Вкл/Выкл)")),
        }),
        new Form.Row(T("Label46", "Видимость:"), new Control[]
        {
            Form.Popup(Enum.GetValues<SlideConstructorModel.Personalization>()
                           .Select(p => T(SlideConstructorModel.PersonalizationKey(p), SlideConstructorModel.PersonalizationTitle(p))).ToList(),
                       new Tie<int>(() => (int)_model.Visibility, i => { _model.Visibility = (SlideConstructorModel.Personalization)i; Changed(); }), 170),
        }, 120),
    });

    // --- Розміри, відступи, прив'язки, прозорість ---------------------------------------------

    Form.Group Geometry() => new(Captions.T("Размеры и место"), new Control[]
    {
        PercentRow(T("Label17", "Ширина:"), v => v.Frame.Width, (v, x) => { v.Frame = v.Frame with { Width = x }; return v; }, 0, 400),
        PercentRow(T("Label18", "Высота:"), v => v.Frame.Height, (v, x) => { v.Frame = v.Frame with { Height = x }; return v; }, 0, 400),
        // Відступ буває й від'ємним: об'єкт навмисно виводять за край.
        PercentRow(T("Label19", "Отст. X:"), v => v.Frame.X, (v, x) => { v.Frame = v.Frame with { X = x }; return v; }, -200, 200),
        PercentRow(T("Label20", "Отст. Y:"), v => v.Frame.Y, (v, x) => { v.Frame = v.Frame with { Y = x }; return v; }, -200, 200),
        new Form.Row(T("Label21", "Привязка по X:"), new Control[]
        {
            Form.Popup(new[] { T("AlignXText0", "Левая"), T("AlignXText2", "Центр"), T("AlignXText1", "Правая") },
                       SceneChoice(v => v.Frame.AnchorX, (v, a) => { v.Frame = v.Frame with { AnchorX = a }; return v; },
                                   new[] { HorizontalAnchor.Left, HorizontalAnchor.Center, HorizontalAnchor.Right }), 150),
        }, 120),
        // У автора вертикальна прив'язка двозначна: у .sch це один біт.
        new Form.Row(T("Label22", "Привязка по Y:"), new Control[]
        {
            Form.Popup(new[] { T("AlignYObjText0", "Верх"), T("AlignYObjText1", "Низ") },
                       SceneChoice(v => v.Frame.AnchorY, (v, a) => { v.Frame = v.Frame with { AnchorY = a }; return v; },
                                   new[] { VerticalAnchor.Top, VerticalAnchor.Bottom }), 150),
        }, 120),
        // Прозорість у автора — байт 0…255.
        new Form.Row(T("Label23", "Прозрачность:"), new Control[]
        {
            Form.Slider(SceneDouble(v => v.Opacity * 255, (v, x) => { v.Opacity = x / 255; return v; }), 0, 255, x => ((int)x).ToString(), 130),
        }, 120),
    });

    // --- Тінь ---------------------------------------------------------------------------------

    Form.Group ShadowGroup() => new("", new Control[]
    {
        new Form.Row("", new Control[]
        {
            Form.Check(T("CBObjShadowActive", "Тень"), new Tie<bool>(() => _model.SelectedValues?.Shadow.IsEnabled ?? false,
                v => { _model.EditScene(s => { s.Shadow = s.Shadow with { IsEnabled = v }; return s; }); Changed(); })),
        }),
        // Заготовки м'якості: кнопка ставить усі чотири числа разом.
        new Form.Row(Captions.T("Заготовка:"), new Control[]
        {
            ShadowPreset("Без тени", 0, 0, 1, false), ShadowPreset("Лёгкая", 1.5, 8, 0.45), ShadowPreset("Мягкая", 2.7, 14, 0.6), ShadowPreset("Глубокая", 4.5, 20, 0.8),
        }, 120),
        new Form.Row(T("Label33", "Смещение (%):"), new Control[]
        {
            Form.Slider(SceneDouble(v => v.Shadow.OffsetPercent, (v, x) => { v.Shadow = v.Shadow with { OffsetPercent = x }; return v; }), -20, 20, F1, 130),
            Form.Decimal(SceneDouble(v => v.Shadow.OffsetPercent, (v, x) => { v.Shadow = v.Shadow with { OffsetPercent = x }; return v; }), -50, 50, 0.1, 60),
        }, 120),
        new Form.Row(T("Label34", "Сглаживание(%):"), new Control[]
        {
            Form.Slider(SceneDouble(v => v.Shadow.BlurPercent, (v, x) => { v.Shadow = v.Shadow with { BlurPercent = x }; return v; }), 0, 40, F1, 130),
            Form.Decimal(SceneDouble(v => v.Shadow.BlurPercent, (v, x) => { v.Shadow = v.Shadow with { BlurPercent = x }; return v; }), 0, 60, 0.1, 60),
        }, 120),
        new Form.Row(Captions.T("Направление:"), new Control[]
        {
            Form.Slider(SceneDouble(v => v.Shadow.AngleDegrees, (v, x) => { v.Shadow = v.Shadow with { AngleDegrees = x }; return v; }), 0, 360, Direction, 130),
        }, 120),
        new Form.Row(T("Label35", "Прозрачность:"), new Control[]
        {
            Form.Slider(SceneDouble(v => v.Shadow.Opacity * 255, (v, x) => { v.Shadow = v.Shadow with { Opacity = x / 255 }; return v; }), 0, 255, x => ((int)x).ToString(), 130),
        }, 120),
        new Form.Row(T("Label42", "Цвет:"), new Control[]
        {
            Form.Colour(new Tie<Color>(() => ToColor(_model.SelectedValues?.Shadow.Color ?? SlideStyle.RGBA.Black),
                v => { _model.EditScene(s => { s.Shadow = s.Shadow with { Color = ToRgba(v, s.Shadow.Color.Alpha) }; return s; }); Changed(); })),
        }, 120),
    });

    static string F1(double v) => v.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);

    static string Direction(double degrees)
    {
        string[] arrows = { "→", "↘", "↓", "↙", "←", "↖", "↑", "↗" };
        var index = (int)Math.Round(((degrees % 360) + 360) % 360 / 45) % 8;
        return arrows[index] + " " + (int)Math.Round(degrees) + "°";
    }

    Control ShadowPreset(string title, double offset, double blur, double opacity, bool on = true) =>
        Form.Button(Captions.T(title), null, () =>
        {
            _model.EditScene(s =>
            {
                s.Shadow = on ? s.Shadow with { IsEnabled = true, OffsetPercent = offset, BlurPercent = blur, Opacity = opacity } : s.Shadow with { IsEnabled = false };
                return s;
            });
            Changed();
            RefreshValues();
        });

    // --- Вирівнювання й текст -------------------------------------------------------------------

    Form.Group Appearance()
    {
        // Сім'ї шрифтів — усі шрифти системи.
        var families = SKFontManager.Default.FontFamilies.Distinct().OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase).ToList();
        return new Form.Group(Captions.T("Текст"), new Control[]
        {
            new Form.Row(T("Label36", "Выравн. по X:"), new Control[]
            {
                Form.Popup(new[] { T("AlignXText0", "Левая"), T("AlignXText2", "Центр"), T("AlignXText1", "Правая") },
                           SceneChoice(v => v.Alignment, (v, a) => { v.Alignment = a; return v; },
                                       new[] { ParagraphAlignment.Leading, ParagraphAlignment.Center, ParagraphAlignment.Trailing }), 150),
            }, 120),
            new Form.Row(T("Label37", "Выравн. по Y:"), new Control[]
            {
                Form.Popup(new[] { T("AlignYText0", "Верх"), T("AlignYText1", "Центр"), T("AlignYText2", "Низ") },
                           SceneChoice(v => v.VerticalAlignment, (v, a) => { v.VerticalAlignment = a; return v; },
                                       new[] { SlideStyle.VerticalAlignment.Top, SlideStyle.VerticalAlignment.Center, SlideStyle.VerticalAlignment.Bottom }), 150),
            }, 120),
            new Form.Row(Captions.T("Шрифт:"), new Control[]
            {
                Form.Popup(families, new Tie<int>(() => Math.Max(0, families.IndexOf(_model.SelectedObject?.Text.FontName ?? "")),
                    i => { if (i < 0 || i >= families.Count) return; _model.Edit(o => { o.Text = o.Text with { FontName = families[i] }; return o; }); Changed(); }), 170),
            }, 120),
            new Form.Row(Captions.T("Размер:"), new Control[]
            {
                Form.Number(new Tie<int>(() => (int)Math.Round((_model.SelectedObject?.Text.FontSize ?? 0.06) * 100),
                    v => { _model.Edit(o => { o.Text = o.Text with { FontSize = v / 100.0 }; return o; }); Changed(); }), 1, 40),
            }, 120),
            new Form.Row("", new Control[]
            {
                Form.Check(T("JvgSBObjBold", "Ж"), new Tie<bool>(() => _model.SelectedObject?.Text.IsBold ?? false, v => { _model.Edit(o => { o.Text = o.Text with { IsBold = v }; return o; }); Changed(); })),
                Form.Check(T("JvgSBObjItalik", "К"), new Tie<bool>(() => _model.SelectedObject?.Text.IsItalic ?? false, v => { _model.Edit(o => { o.Text = o.Text with { IsItalic = v }; return o; }); Changed(); })),
                Form.Check(T("JvgSBObjUnderline", "Ч"), new Tie<bool>(() => _model.SelectedObject?.IsUnderlined ?? false, v => { _model.Edit(o => { o.IsUnderlined = v; return o; }); Changed(); })),
            }),
            new Form.Row(T("Label40", "Текст:"), new Control[]
            {
                Form.Colour(new Tie<Color>(() => ToColor(_model.SelectedObject?.Text.Color ?? SlideStyle.RGBA.White),
                    v => { _model.Edit(o => { o.Text = o.Text with { Color = ToRgba(v, o.Text.Color.Alpha) }; return o; }); Changed(); })),
            }, 120),
            new Form.Row("", new Control[]
            {
                Form.Check(T("CBObjOutLineActive", "Контур"), new Tie<bool>(() => _model.SelectedObject?.Text.IsOutlined ?? false,
                    v => { _model.Edit(o => { o.Text = o.Text with { IsOutlined = v }; return o; }); Changed(); })),
                Form.Colour(new Tie<Color>(() => ToColor(_model.SelectedObject?.Text.OutlineColor ?? SlideStyle.RGBA.Black),
                    v => { _model.Edit(o => { o.Text = o.Text with { OutlineColor = ToRgba(v, o.Text.OutlineColor.Alpha) }; return o; }); Changed(); })),
            }),
            // У пунктах кадру заввишки 1080, як QuoteOutLineWidth автора.
            new Form.Row(T("Label39", "Толщина контура:") + " " + Captions.T("(пт)"), new Control[]
            {
                Form.Slider(ObjectPoints(), 0, 20, x => x.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture), 130),
                Form.Decimal(ObjectPoints(), 0, 60, 0.25, 60),
            }, 120),
            new Form.Row(Captions.T("Прозрачность контура:"), new Control[]
            {
                Form.Slider(new Tie<double>(() => (_model.SelectedObject?.Text.OutlineColor.Alpha ?? 1) * 255,
                    v => { _model.Edit(o => { o.Text = o.Text with { OutlineColor = o.Text.OutlineColor with { Alpha = Math.Clamp(v / 255, 0, 1) } }; return o; }); Changed(); }),
                    0, 255, x => ((int)x).ToString(), 130),
            }, 120),
        });
    }

    Tie<double> ObjectPoints() => new(() => Math.Round((_model.SelectedObject?.Text.OutlineThickness ?? 0.004) * 1080 * 4) / 4,
        v => { _model.Edit(o => { o.Text = o.Text with { OutlineThickness = v / 1080 }; return o; }); Changed(); });

    // --- Картинка й маска -------------------------------------------------------------------

    Form.Group ImageFiles(SlideObject obj) => new(Captions.T("Изображение"), new Control[]
    {
        FileRow(T("Label15", "Имя файла изображения:"), obj.ImagePath, path => _model.Edit(o => { o.ImagePath = path; return o; })),
        FileRow(T("Label16", "Имя файла маски:"), obj.MaskPath, path => _model.Edit(o => { o.MaskPath = path; return o; })),
    });

    Control FileRow(string title, string? path, Action<string?> apply)
    {
        var name = Form.Label(path != null ? Path.GetFileName(path) : T("TextMessages10", "Нет"), false);
        return new Form.Row(title, new Control[]
        {
            name,
            Form.Button("…", null, () => _ = Choose(title, chosen => { apply(chosen); name.Text = Path.GetFileName(chosen); Changed(); })),
            Form.Button("✕", null, () => { apply(null); name.Text = "—"; Changed(); }),
        }, 170);
    }

    async Task Choose(string title, Action<string> done)
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } storage) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title, AllowMultiple = false,
            FileTypeFilter = new[] { FilePickerFileTypes.ImageAll },
            SuggestedStartLocation = _model.SourceFolder is { } folder ? await storage.TryGetFolderFromPathAsync(folder) : null,
        });
        if (files.Count > 0 && files[0].TryGetLocalPath() is { } path) done(path);
    }

    // --- Анімація ---------------------------------------------------------------------------

    Form.Group Animation()
    {
        var directions = Enum.GetValues<ObjectAnimation.Direction>();
        return new Form.Group(T("Panel5", "Анимация"), new Control[]
        {
            new Form.Row("", new Control[]
            {
                Form.Check(T("CBAnimEnabl", "Включить"), new Tie<bool>(() => _model.SelectedValues?.Animation.IsAnimated ?? false, on =>
                {
                    // Вимкнена анімація — «нікуди не летить, не росте й не проявляється»;
                    // тривалість і затримку не стираємо.
                    _model.EditScene(v =>
                    {
                        var a = v.Animation;
                        if (on)
                        {
                            if (a.Duration <= 0) a.Duration = 350;
                            if (a.Move == ObjectAnimation.Direction.None && !a.AnimatesScale && !a.AnimatesOpacity) a.AnimatesOpacity = true;
                        }
                        else { a.Move = ObjectAnimation.Direction.None; a.AnimatesScale = false; a.AnimatesOpacity = false; }
                        v.Animation = a;
                        return v;
                    });
                    Changed();
                })),
            }),
            new Form.Row(T("Label24", "Перемещение:"), new Control[]
            {
                Form.Popup(directions.Select((d, i) => T($"FXDirectText{i}", d.Title())).ToList(),
                           new Tie<int>(() => Math.Max(0, Array.IndexOf(directions, _model.SelectedValues?.Animation.Move ?? ObjectAnimation.Direction.None)),
                                        i => { if (i < 0 || i >= directions.Length) return; _model.EditScene(v => { v.Animation = v.Animation with { Move = directions[i] }; return v; }); Changed(); }), 150),
            }, 120),
            new Form.Row(T("Label2", "Отст. X:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.PointX * 100, (v, x) => { v.Animation = v.Animation with { PointX = x / 100 }; return v; }), -200, 200),
            }, 120),
            new Form.Row(T("Label4", "Отст. Y:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.PointY * 100, (v, x) => { v.Animation = v.Animation with { PointY = x / 100 }; return v; }), -200, 200),
            }, 120),
            new Form.Row("", new Control[]
            {
                Form.Check(T("CBFXScale", "Масштаб"), new Tie<bool>(() => _model.SelectedValues?.Animation.AnimatesScale ?? false,
                    v => { _model.EditScene(s => { s.Animation = s.Animation with { AnimatesScale = v }; return s; }); Changed(); })),
                Form.Check(T("CBFXOpacity", "Прозрачность"), new Tie<bool>(() => _model.SelectedValues?.Animation.AnimatesOpacity ?? false,
                    v => { _model.EditScene(s => { s.Animation = s.Animation with { AnimatesOpacity = v }; return s; }); Changed(); })),
            }),
            new Form.Row(T("Label6", "Начальный:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.StartScale * 100, (v, x) => { v.Animation = v.Animation with { StartScale = x / 100 }; return v; }), 0, 400),
            }, 120),
            new Form.Row(T("Label8", "Начальная:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.StartOpacity * 255, (v, x) => { v.Animation = v.Animation with { StartOpacity = x / 255 }; return v; }), 0, 255),
            }, 120),
            new Form.Row(T("Label9", "Длительность:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.Duration, (v, x) => { v.Animation = v.Animation with { Duration = x }; return v; }), 0, 10000),
                Form.Label(T("Label10", "мс")),
            }, 120),
            new Form.Row(T("Label11", "Задержка:"), new Control[]
            {
                Form.Number(SceneInt(v => v.Animation.Delay, (v, x) => { v.Animation = v.Animation with { Delay = x }; return v; }), 0, 10000),
                Form.Label(T("Label12", "мс")),
            }, 120),
        });
    }

    // --- Зв'язки ------------------------------------------------------------------------------

    Control PercentRow(string title, Func<ObjectVariant, double> get, Func<ObjectVariant, double, ObjectVariant> set, int min, int max) =>
        new Form.Row(title, new Control[] { Form.Number(SceneInt(v => get(v) * 100, (v, x) => set(v, x / 100)), min, max) }, 120);

    Tie<int> SceneInt(Func<ObjectVariant, double> get, Func<ObjectVariant, double, ObjectVariant> set) =>
        new(() => _model.SelectedValues is { } v ? (int)Math.Round(get(v)) : 0, x => { _model.EditScene(v => set(v, x)); Changed(); });

    Tie<double> SceneDouble(Func<ObjectVariant, double> get, Func<ObjectVariant, double, ObjectVariant> set) =>
        new(() => _model.SelectedValues is { } v ? get(v) : 0, x => { _model.EditScene(v => set(v, x)); Changed(); });

    Tie<int> SceneChoice<TValue>(Func<ObjectVariant, TValue> get, Func<ObjectVariant, TValue, ObjectVariant> set, TValue[] values) =>
        new(() => _model.SelectedValues is { } v ? Math.Max(0, Array.IndexOf(values, get(v))) : 0,
            i => { if (i < 0 || i >= values.Length) return; _model.EditScene(v => set(v, values[i])); Changed(); });

    static Color ToColor(SlideStyle.RGBA c) => Color.FromArgb(255, (byte)Math.Round(c.Red * 255), (byte)Math.Round(c.Green * 255), (byte)Math.Round(c.Blue * 255));
    static SlideStyle.RGBA ToRgba(Color c, double alpha) => new(c.R / 255.0, c.G / 255.0, c.B / 255.0, alpha);
}
