package ua.church.slovo.remote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.AttributeSet;
import android.view.View;

/// Пляма указки поверх картинки слайда на телефоні.
///
/// Малюється тим самим правилом, що й у програмі (`SlidePointer.draw`):
/// заливка з прозорістю і тонкий обідок, радіус — частка висоти намальованої
/// картинки. Тому те, що оператор бачить під пальцем, збігається з тим, що
/// горить на стіні. Дотиків вид не ловить — вони йдуть до картинки під ним.
public final class PointerView extends View {

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
    /// Де всередині виду лежить сама картинка: по боках бувають поля.
    private final RectF image = new RectF();
    private boolean shown;
    private float x = 0.5f, y = 0.5f;
    private int colour = Settings.DEFAULT_POINTER_COLOUR;
    private float size = Settings.DEFAULT_POINTER_SIZE;
    private float opacity = 0.45f;

    public PointerView(Context context) { super(context); init(); }
    public PointerView(Context context, AttributeSet attrs) { super(context, attrs); init(); }

    private void init() {
        ring.setStyle(Paint.Style.STROKE);
        setWillNotDraw(false);
    }

    void setImageRect(RectF rect) {
        if (rect == null) image.setEmpty(); else image.set(rect);
        invalidate();
    }

    /// Вигляд: колір ARGB, розмір як частка висоти картинки, яскравість —
    /// непрозорість заливки.
    void setLook(int colour, float size, float opacity) {
        this.colour = colour;
        this.size = Math.max(Settings.MIN_POINTER_SIZE, Math.min(Settings.MAX_POINTER_SIZE, size));
        this.opacity = Math.max(0.05f, Math.min(1f, opacity));
        invalidate();
    }

    int colour() { return colour; }
    float size() { return size; }

    /// Показати пляму в частках ширини і висоти картинки, вісь Y униз.
    void show(float x, float y) {
        shown = true;
        this.x = Math.max(0f, Math.min(1f, x));
        this.y = Math.max(0f, Math.min(1f, y));
        invalidate();
    }

    void hide() {
        if (!shown) return;
        shown = false;
        invalidate();
    }

    boolean isShown_() { return shown; }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (!shown || image.width() <= 0 || image.height() <= 0) return;
        float radius = Math.max(2f, size * image.height() / 2f);
        float cx = image.left + x * image.width();
        float cy = image.top + y * image.height();
        int rgb = colour & 0xFFFFFF;
        fill.setColor((Math.round(opacity * 255) << 24) | rgb);
        // Тонкий обідок: заливку з малою яскравістю на світлому слайді інакше не видно.
        ring.setColor((Math.round(Math.min(1f, opacity + 0.4f) * 255) << 24) | rgb);
        ring.setStrokeWidth(Math.max(1.5f, radius * 0.08f));
        canvas.drawCircle(cx, cy, radius, fill);
        canvas.drawCircle(cx, cy, radius - 1f, ring);
    }
}
