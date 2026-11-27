package android.util;
public final class Log {
    public static int i(String tag, String text) { System.out.println("  [лог " + tag + "] " + text); return 0; }
    public static int w(String tag, String text) { System.out.println("  [лог " + tag + " ЗБІЙ] " + text); return 0; }
}
