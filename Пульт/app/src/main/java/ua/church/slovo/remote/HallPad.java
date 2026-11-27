package ua.church.slovo.remote;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.widget.ImageView;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/// Картинка залу (чи слайда) як пульт указки й наближення — спільна для
/// пульта й планшета. Раніше той самий код жив двічі, у кожному вікні свій.
///
/// Палець по картинці — указка на стіні й тут же під пальцем; щипок двома
/// пальцями наближає зал до місця між пальцями; подвійний дотик знімає
/// наближення. Картинка показує те саме вікно, що й зал (`SlideFocus.rect`
/// у програмі: сторона 1/кратність, середина в точці, притиснуте до країв),
/// тому й указка, і щипок міряються в частках ПОКАЗАНОГО кадру — рівно так,
/// як їх чекає програма.
final class HallPad implements View.OnTouchListener {

    interface Host {
        Api api();
        State state();
    }

    private final Settings settings;
    private final Host host;
    private final ImageView image;
    private final PointerView pointer;
    private final ExecutorService queue = Executors.newSingleThreadExecutor();
    private final ScaleGestureDetector detector;

    private Bitmap full;
    private String shownCrop = "";
    /// Показане вікно наближення {ліво, верх, сторона}: їде до цілі плавно за
    /// 280 мс, а не стрибає. Власник: «переход в исходное состояние не резко, а
    /// плавно… подтягивание слайда — пусть это будет тоже плавно». Під щипком
    /// і з новою картинкою — одразу.
    private double[] shownWindow = {0, 0, 1};
    private android.animation.ValueAnimator ride;
    private int shownBitmapId;

    /// Скільки мілісекунд між точками указки: 25 на секунду. Власник: «постоянные
    /// обрывы связи при использовании указки и зума». Указка йшла так швидко, як
    /// поверталися відповіді, — до 63 запитів на секунду, кожен своїм з'єднанням
    /// (так показав журнал «Слова» 27.11), і Wi-Fi телефона захлинався. Стіна й
    /// NDI оновлюються 25–30 разів на секунду — частіше слати нема чого.
    private static final long POINTER_STEP = 40;
    /// Те саме для наближення: щипок дає подію на кожен кадр.
    private static final long ZOOM_STEP = 50;

    private volatile boolean zooming, touching;
    private long zoomEndedAt, touchEndedAt, lastTapAt;
    private volatile long lastPointerAt, lastZoomAt;
    private double zoomNow = 1;
    private volatile boolean zoomBusy, pointerBusy;
    private volatile double pendingX = -1, pendingY = -1;
    /// Наближення, яке ще треба надіслати: {кратність, x, y}; `null` — нічого.
    private volatile double[] pendingZoom;

    /// Змінилося наближення чи картинка — вікно оновлює кнопку «Вихідний вигляд».
    Runnable onChange;

    HallPad(Context c, Host host, ImageView image, PointerView pointer) {
        this.settings = new Settings(c);
        this.host = host;
        this.image = image;
        this.pointer = pointer;
        detector = new ScaleGestureDetector(c, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override
            public boolean onScaleBegin(ScaleGestureDetector d) {
                zooming = true;
                pointer.hide();
                Api current = host.api();
                if (current != null) queue.execute(() -> { try { current.pointerOff(); } catch (Exception ignored) { } });
                return true;
            }

            @Override
            public boolean onScale(ScaleGestureDetector d) {
                RectF shown = imageRect();
                if (shown == null || shown.width() <= 0 || shown.height() <= 0) return true;
                zoomNow = Math.max(1.0, Math.min(6.0, zoomNow * d.getScaleFactor()));
                double x = Math.max(0, Math.min(1, (d.getFocusX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (d.getFocusY() - shown.top) / shown.height()));
                queueZoom(zoomNow, x, y);
                return true;
            }

            @Override
            public void onScaleEnd(ScaleGestureDetector d) { zoomEndedAt = System.currentTimeMillis(); }
        });
        image.setOnTouchListener(this);
        image.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> pointer.setImageRect(imageRect()));
        look();
    }

    /// Вигляд плями під пальцем — цілком із налаштувань: колір, розмір і яскравість.
    void look() {
        pointer.setLook(settings.pointerColour(), settings.pointerSize(), settings.pointerOpacity());
    }

    Bitmap bitmap() { return full; }

    /// Нова картинка цілком (`null` — прибрати: затемнення, відео, нічого не відкрито).
    void set(Bitmap bitmap) {
        full = bitmap;
        shownCrop = "";
        if (bitmap == null) {
            if (ride != null) { ride.cancel(); ride = null; }
            shownWindow = new double[] {0, 0, 1};
            image.setImageBitmap(null);
            pointer.setImageRect(imageRect());
            pointer.hide();
            return;
        }
        show();
    }

    boolean zoomed() {
        State s = host.state();
        return s != null && s.zoomOn && s.zoom > 1.001;
    }

    /// Поставити картинку так, як її бачить зал: при наближенні — вирізане вікно.
    void show() {
        State state = host.state();
        // Наступний щипок починається з тієї кратності, що справді в залі:
        // її могли змінити мишею з комп'ютера.
        if (!zooming && state != null) zoomNow = state.zoomOn ? state.zoom : 1;
        if (onChange != null) onChange.run();
        Bitmap bitmap = full;
        if (bitmap == null) return;
        double[] target = window();
        boolean fresh = System.identityHashCode(bitmap) != shownBitmapId;
        shownBitmapId = System.identityHashCode(bitmap);
        boolean same = Math.abs(target[0] - shownWindow[0]) + Math.abs(target[1] - shownWindow[1])
            + Math.abs(target[2] - shownWindow[2]) < 1e-4;
        if (ride != null) { ride.cancel(); ride = null; }
        if (fresh || zooming || same) {
            shownWindow = target;
            draw(bitmap, target);
            return;
        }
        final double[] from = shownWindow.clone();
        android.animation.ValueAnimator move = android.animation.ValueAnimator.ofFloat(0f, 1f);
        move.setDuration(280);
        move.setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator());
        move.addUpdateListener(a -> {
            float e = (float) a.getAnimatedValue();
            shownWindow = new double[] { from[0] + (target[0] - from[0]) * e,
                                        from[1] + (target[1] - from[1]) * e,
                                        from[2] + (target[2] - from[2]) * e };
            Bitmap now = full;
            if (now != null) draw(now, shownWindow);
        });
        ride = move;
        move.start();
    }

    /// Вікно наближення в частках цілого кадру: {ліво, верх, сторона}.
    private double[] window() {
        State state = host.state();
        if (state == null || !state.zoomOn || state.zoom <= 1.001) return new double[] {0, 0, 1};
        double side = 1.0 / Math.max(1.0, Math.min(6.0, state.zoom));
        double left = Math.min(1 - side, Math.max(0, state.zoomX - side / 2));
        double top = Math.min(1 - side, Math.max(0, state.zoomY - side / 2));
        return new double[] {left, top, side};
    }

    /// Вирізати вікно з картинки й поставити у вид.
    private void draw(Bitmap bitmap, double[] window) {
        String signature = window[0] + ":" + window[1] + ":" + window[2] + ":" + System.identityHashCode(bitmap);
        if (signature.equals(shownCrop)) return;
        shownCrop = signature;
        Bitmap shown = bitmap;
        if (window[2] < 0.999) {
            int x = (int) Math.round(window[0] * bitmap.getWidth());
            int y = (int) Math.round(window[1] * bitmap.getHeight());
            int w = Math.min(Math.max(2, (int) Math.round(window[2] * bitmap.getWidth())), bitmap.getWidth() - x);
            int h = Math.min(Math.max(2, (int) Math.round(window[2] * bitmap.getHeight())), bitmap.getHeight() - y);
            if (w > 1 && h > 1) shown = Bitmap.createBitmap(bitmap, x, y, w, h);
        }
        image.setImageBitmap(shown);
        pointer.setImageRect(imageRect());
        syncPointer();
    }

    /// Де всередині виду намальовано саму картинку: по боках бувають поля.
    /// `null` — картинки ще немає.
    private RectF imageRect() {
        Drawable drawable = image.getDrawable();
        if (drawable == null) return null;
        RectF shown = new RectF(0, 0, drawable.getIntrinsicWidth(), drawable.getIntrinsicHeight());
        Matrix matrix = image.getImageMatrix();
        matrix.mapRect(shown);
        return shown.width() <= 0 || shown.height() <= 0 ? null : shown;
    }

    /// Чужа указка (мишею з комп'ютера або з іншого пристрою) — теж на
    /// картинці, кольором і розміром, які віддала програма. Поки палець на
    /// екрані, своя пляма важливіша; луна власної указки зі стану ще секунду
    /// приходить як «увімкнена» — її теж не малюємо, інакше пляма блимала б.
    void syncPointer() {
        State state = host.state();
        if (touching || state == null) return;
        boolean ownEcho = Settings.POINTER_SOURCE_PHONE.equals(state.pointerSource)
            && System.currentTimeMillis() - touchEndedAt < 1500;
        if (!state.pointerOn || ownEcho || full == null) {
            pointer.hide();
            return;
        }
        int colour = settings.pointerColour();
        try {
            if (!state.pointerColour.isEmpty()) colour = Color.parseColor(state.pointerColour);
        } catch (IllegalArgumentException ignored) { }
        float size = state.pointerSize > 0 ? (float) state.pointerSize : settings.pointerSize();
        pointer.setLook(colour, size, (float) state.pointerOpacity);
        pointer.show((float) state.pointerX, (float) state.pointerY);
    }

    @Override
    public boolean onTouch(View view, MotionEvent event) {
        RectF shown = imageRect();
        // Картинки немає — затемнення чи відео: указці нема куди лягти, і без
        // цієї перевірки пляма падала в кут чорного екрана.
        if (shown == null || full == null) return false;
        if (view.getParent() != null) view.getParent().requestDisallowInterceptTouchEvent(true);
        detector.onTouchEvent(event);
        // Поки пальців більше одного — це наближення, а не указка. І ще
        // чверть секунди після: піднімаючи щипок, один палець відривається
        // раніше за другий, і без цієї паузи в залі спалахувала пляма.
        if (zooming) {
            if (event.getActionMasked() == MotionEvent.ACTION_UP || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                zooming = false;
            }
            return true;
        }
        if (event.getPointerCount() > 1 || System.currentTimeMillis() - zoomEndedAt < 250) return true;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: {
                long now = System.currentTimeMillis();
                if (now - lastTapAt < 300 && zoomed()) {
                    lastTapAt = 0;
                    resetZoom();
                    return true;
                }
                lastTapAt = now;
            }
            // fall through
            case MotionEvent.ACTION_MOVE: {
                double x = Math.max(0, Math.min(1, (event.getX() - shown.left) / shown.width()));
                double y = Math.max(0, Math.min(1, (event.getY() - shown.top) / shown.height()));
                if (!touching) {
                    touching = true;
                    look();
                    pointer.setImageRect(shown);
                }
                pointer.show((float) x, (float) y);
                queuePointer(x, y);
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL: {
                touching = false;
                touchEndedAt = System.currentTimeMillis();
                pointer.hide();
                pendingX = -1;
                pendingY = -1;
                Api current = host.api();
                if (current != null) queue.execute(() -> { try { current.pointerOff(); } catch (Exception ignored) { } });
                return true;
            }
            default:
                return false;
        }
    }

    /// Стенд (`Stand`): щипок без пальців — події кожні 16 мс упродовж 1,2 с від 1× до 3×,
    /// як дає справжній жест. На емуляторі дотик лише одним пальцем, а перевірити
    /// треба саме те, що робить щипок, — чергу наближення й мережу.
    void rehearsePinch() {
        if (full == null) return;
        zooming = true;
        final long start = System.currentTimeMillis();
        image.post(new Runnable() {
            @Override
            public void run() {
                long t = System.currentTimeMillis() - start;
                if (t > 1200) {
                    zooming = false;
                    zoomEndedAt = System.currentTimeMillis();
                    return;
                }
                zoomNow = 1 + 2 * t / 1200.0;
                queueZoom(zoomNow, 0.4, 0.4);
                image.postDelayed(this, 16);
            }
        });
    }

    /// Чи веде людина зараз указку пальцем (не щипок).
    boolean pointing() { return touching && !zooming; }

    /// Кратність шлемо не частіше двадцяти разів на секунду і без черги: щипок
    /// сипле подіями сотнями, а залу досить бачити останню. Остання — дійде
    /// завжди: раніше подія, що прийшла, поки попередня була в дорозі, губилася,
    /// і зал міг лишитися не на тому наближенні, де зупинилися пальці.
    private void queueZoom(double zoom, double x, double y) {
        pendingZoom = new double[] {zoom, x, y};
        if (zoomBusy) return;
        Api current = host.api();
        if (current == null) return;
        zoomBusy = true;
        queue.execute(() -> {
            try {
                while (true) {
                    double[] next = pendingZoom;
                    if (next == null) break;
                    pause(lastZoomAt + ZOOM_STEP);
                    next = pendingZoom;
                    pendingZoom = null;
                    if (next == null) break;
                    lastZoomAt = System.currentTimeMillis();
                    try { current.zoom(next[0], next[1], next[2]); } catch (Exception ignored) { }
                }
            } finally {
                zoomBusy = false;
            }
            // Нове прийшло саме тоді, коли черга закінчувалась, — не загубити.
            if (pendingZoom != null) image.post(() -> {
                double[] last = pendingZoom;
                if (last != null && !zoomBusy) queueZoom(last[0], last[1], last[2]);
            });
        });
    }

    /// Почекати до моменту `until` (мс), якщо він ще не настав.
    private static void pause(long until) {
        long wait = until - System.currentTimeMillis();
        if (wait <= 0) return;
        try { Thread.sleep(wait); } catch (InterruptedException stop) { Thread.currentThread().interrupt(); }
    }

    /// Зняти наближення.
    void resetZoom() {
        zoomNow = 1;
        pendingZoom = null;
        Api current = host.api();
        if (current == null) return;
        queue.execute(() -> { try { current.zoom(1, 0.5, 0.5); } catch (Exception ignored) { } });
    }

    /// Не частіше одного запиту в польоті й не частіше `POINTER_STEP`: поки
    /// попередній не пішов, нові точки лише запам'ятовуються, і в мережу йде
    /// остання. Остання точка жесту доходить завжди.
    private void queuePointer(double x, double y) {
        pendingX = x;
        pendingY = y;
        if (pointerBusy) return;
        final Api current = host.api();
        if (current == null) return;
        final String colour = settings.pointerColourHex();
        final double size = settings.pointerSize();
        final double opacity = settings.pointerOpacity();
        pointerBusy = true;
        queue.execute(() -> {
            double sentX = Double.NaN, sentY = Double.NaN;
            try {
                while (true) {
                    if (pendingX < 0) break;
                    pause(lastPointerAt + POINTER_STEP);
                    double px = pendingX, py = pendingY;
                    if (px < 0 || (px == sentX && py == sentY)) break;
                    lastPointerAt = System.currentTimeMillis();
                    try { current.pointer(px, py, colour, size, opacity); } catch (Exception error) { break; }
                    sentX = px;
                    sentY = py;
                }
            } finally {
                pointerBusy = false;
            }
            // Палець зрушив саме тоді, коли черга закінчувалась, — не загубити точку.
            final double lastX = sentX, lastY = sentY;
            if (pendingX >= 0 && (pendingX != lastX || pendingY != lastY)) {
                image.post(() -> { if (!pointerBusy && pendingX >= 0) queuePointer(pendingX, pendingY); });
            }
        });
    }

    void shutdown() {
        if (ride != null) { ride.cancel(); ride = null; }
        queue.shutdown();
    }
}
