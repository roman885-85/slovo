# =============================================================================
#  3-windows.ps1 — вікно слайда: повний екран, ручна настройка, звичайний запуск
# =============================================================================
#  Справжні прямокутники вікон (EnumWindows, процес DPI-aware): слайд без рамки
#  на весь екран (змінна SLOVO_SLIDE_FULLSCREEN=1 — службова, для машини з одним
#  монітором), ручна настройка за координатами, звичайний запуск — головне вікно
#  в межах робочої області.
# =============================================================================
$ErrorActionPreference = 'Continue'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test'; $data = Join-Path $root 'data'; $exe = Join-Path $root 'Slovo.exe'
$api = 'http://127.0.0.1:8103/api'
function Post($cmd, $body) { try { Invoke-RestMethod -Method Post -Uri "$api/$cmd" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 } catch { "  ! $cmd — $($_.Exception.Message)" } }
function WaitApi() { for ($i = 0; $i -lt 30; $i++) { try { $null = Invoke-RestMethod -Uri "$api/state?since=0" -TimeoutSec 3; return $true } catch { Start-Sleep -Seconds 1 } }; return $false }
function Shot($name) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $back $name), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
[void][W]::SetProcessDPIAware()
function Windows-Of-Slovo() {
    $ids = (Get-Process Slovo -ErrorAction SilentlyContinue).Id
    $list = New-Object System.Collections.ArrayList
    [W]::EnumWindows({ param($h, $l)
        $procId = 0; [void][W]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($ids -contains $procId -and [W]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256; [void][W]::GetWindowTextW($h, $sb, 256)
            $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
            $style = [W]::GetWindowLong($h, -16); $ex = [W]::GetWindowLong($h, -20)
            [void]$list.Add("«$($sb.ToString())» $($r.L),$($r.T) $($r.R - $r.L)x$($r.B - $r.T) caption=$(($style -band 0x00C00000) -eq 0x00C00000) topmost=$(($ex -band 0x8) -ne 0)")
        }
        return $true }, [IntPtr]::Zero) | Out-Null
    $list
}
Add-Type -AssemblyName System.Windows.Forms
"екран (справжні пікселі): $([System.Windows.Forms.Screen]::PrimaryScreen.Bounds); робоча область: $([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea)"

# 1. Слайд без рамки на весь екран (як на проекторі) — службовий перемикач для машини з одним монітором.
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2
Copy-Item '\\Mac\Home\Documents\Слово\Слово.exe' $exe -Force
$env:SLOVO_SLIDE_FULLSCREEN = '1'
Start-Process -FilePath $exe -ArgumentList '--data',"`"$data`""
"api (повний екран): $(WaitApi)"
$books = Invoke-RestMethod -Uri "$api/bible/books" -TimeoutSec 20
Post 'bible-select' '{"book":42,"chapter":3,"verses":[16],"live":true}' | Out-Null
Start-Sleep -Seconds 3
Shot 'screen-5-fullscreen.png'
Add-Type -AssemblyName System.Windows.Forms
"екран: $([System.Windows.Forms.Screen]::PrimaryScreen.Bounds)"
"вікна (повний екран): "; Windows-Of-Slovo | ForEach-Object { "   $_" }

# 2. Ручна настройка: вікно без рамки за координатами 200,150 1280x720.
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2
$settingsFile = Join-Path $data 'settings.json'
$json = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$json.ManualPlacement = $true; $json.CustomLeft = 200; $json.CustomTop = 150; $json.CustomWidth = 1280; $json.CustomHeight = 720
[IO.File]::WriteAllText($settingsFile, ($json | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))

Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2
Copy-Item '\\Mac\Home\Documents\Слово\Слово.exe' $exe -Force
$env:SLOVO_SLIDE_FULLSCREEN = $null
Start-Process -FilePath $exe -ArgumentList '--data',"`"$data`""
"api (ручна настройка): $(WaitApi)"
Post 'bible-select' '{"book":42,"chapter":3,"verses":[16,17],"live":true}' | Out-Null
Start-Sleep -Seconds 3
"вікна (ручна настройка 200,150 1280x720): "; Windows-Of-Slovo | ForEach-Object { "   $_" }
Shot 'screen-6-manual.png'

# 3. Звичайний запуск: головне вікно в межах робочої області.
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2
$settingsFile = Join-Path $data 'settings.json'
$json = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$json.ManualPlacement = $false; $json.WindowX = -1; $json.WindowY = -1
[IO.File]::WriteAllText($settingsFile, ($json | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
Start-Process -FilePath $exe -ArgumentList '--data',"`"$data`""
"api (звичайний запуск): $(WaitApi)"
Start-Sleep -Seconds 3
"вікна (звичайний запуск): "; Windows-Of-Slovo | ForEach-Object { "   $_" }
Shot 'screen-7-normal.png'
