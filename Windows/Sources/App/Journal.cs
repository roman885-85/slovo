// =============================================================================
//  Journal.cs — щоденник програми (journal.txt у теці даних)
// =============================================================================
//  Як NativeTrace.say на Mac: короткі рядки про те, що сталося, — їх читають,
//  коли людина каже «пусто» чи «не те в залі».
// =============================================================================

namespace Slovo.App;

public static class Journal
{
    static readonly object Lock = new();

    public static string FilePath => Path.Combine(Defaults.Folder, "journal.txt");

    public static void Say(string line)
    {
        var stamped = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}";
        System.Diagnostics.Debug.WriteLine(stamped);
        lock (Lock)
        {
            try
            {
                Directory.CreateDirectory(Defaults.Folder);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 2_000_000)
                    File.Move(FilePath, FilePath + ".old", true);
                File.AppendAllText(FilePath, stamped + Environment.NewLine);
            }
            catch { }
        }
    }
}
