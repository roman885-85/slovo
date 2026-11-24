# Знімок головного вікна тестового «Слова» у ВМ: вивести наперед і зняти його прямокутник
# (вікно консолі, через яку йдуть команди, інакше закриває програму). Ім'я файла — $name.
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  // Найбільше видиме вікно процесу з точним заголовком (головне — «Слово»; інше — за $title).
  public static IntPtr Find(uint pid, string title) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString() != title) return true;
      RECT r; GetWindowRect(h, out r); long a = (long)(r.R - r.L) * (r.B - r.T);
      if (a > area) { area = a; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
'@
[W]::SetProcessDPIAware() | Out-Null
if (-not $title) { $title = 'Слово' }
$p = Get-Process | Where-Object { $_.Path -like '*slovo-test-backing*' } | Select-Object -First 1
if (-not $p) { 'no process'; return }
$h = [W]::Find([uint32]$p.Id, $title)
if ($h -eq [IntPtr]::Zero) { "no window '$title'"; return }
[W]::ShowWindow($h, 9) | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shell.SendKeys('%') ; [W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700
$r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L; $ht = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
$out = "\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm\$name.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); "saved $name $w x $ht foreground=$([W]::GetForegroundWindow() -eq $h)"
