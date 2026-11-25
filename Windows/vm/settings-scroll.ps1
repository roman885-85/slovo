# =============================================================================
#  settings-scroll.ps1 — чи гортається сторінка «Параметрів» колесом і пальцем (Windows 1.4.3)
# =============================================================================
#  Справжня програма (test-data-hall); «Параметри» → «Медіа»; клацання по заголовку вікна
#  (активувати), колесо над правою частиною сторінки, знімки до/після; потім протяжка пальцем.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\settings-scroll'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-ui'
$exe = Join-Path $root 'Slovo.exe'
foreach ($p0 in @($back, $root)) { if (Test-Path $p0) { Remove-Item $p0 -Recurse -Force -ErrorAction SilentlyContinue } }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-hall') $d -Recurse -Force
Add-Type -AssemblyName System.Drawing
$code = Get-Content '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\ui-check.ps1' -Raw -Encoding UTF8
$typeDef = [regex]::Match($code, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition $typeDef
[U]::SetProcessDPIAware() | Out-Null
function PostApp($cmd, $body) { $bytes = [Text.Encoding]::UTF8.GetBytes($body); try { $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 30 ("http://127.0.0.1:8103/api/" + $cmd); return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } catch { return "ERR " + $_.Exception.Message } }
function Shot($h, $name) {
    $r = New-Object U+RECT; [U]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $ht; $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht)); $file = Join-Path $back "$name.png"; $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    return (Get-FileHash $file -Algorithm MD5).Hash.Substring(0, 8) }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
$up = $false
for ($i = 0; $i -lt 90 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:8103/api/state' | Out-Null; $up = $true } catch {} }
Start-Sleep 6
"settings: " + (PostApp 'window-open' '{"text":"settings:1"}')
$set = [IntPtr]::Zero; for ($i = 0; $i -lt 40 -and $set -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $set = [U]::Find([uint32]$app.Id, 'Параметри') }
Start-Sleep 2
$r = New-Object U+RECT; [U]::GetWindowRect($set, [ref]$r) | Out-Null
# Активувати: клацання по заголовку вікна (праворуч від назви, де немає кнопок).
[U]::Click([int](($r.L + $r.R) / 2), $r.T + 20); Start-Sleep 1
$x = $r.R - 900; $y = [int](($r.T + $r.B) / 2)
$a = Shot $set 'колесо-до'
[U]::Wheel($x, $y, -600); Start-Sleep 1
$b = Shot $set 'колесо-після'
"колесо: $a → $b (прокрутилось — якщо різні)"
[U]::Wheel($x, $y, 600); Start-Sleep 1
"InitializeTouchInjection: $([U]::Init())"
$c = Shot $set 'палець-до'
[U]::Drag($x, $y + 300, $y - 300, 20) | Out-Null; Start-Sleep 1
$e = Shot $set 'палець-після'
"палець: $c → $e (прокрутилось — якщо різні)"
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; $app.WaitForExit(10000) | Out-Null; Start-Sleep 2
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
