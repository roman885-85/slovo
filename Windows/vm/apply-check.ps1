# =============================================================================
#  apply-check.ps1 — «Параметри → Гаразд» діє одразу (NDI), і подвійний дотик виводить вірш у зал
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-ui'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
$ndi = [Environment]::GetEnvironmentVariable('NDI_RUNTIME_DIR_V6', 'Machine'); if ($ndi) { $env:NDI_RUNTIME_DIR_V6 = $ndi }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-nondi') $d -Recurse -Force
$code = Get-Content '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\ui-check.ps1' -Raw -Encoding UTF8
Add-Type -TypeDefinition ([regex]::Match($code, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
[U]::SetProcessDPIAware() | Out-Null
function PostApp($cmd, $body) { $bytes = [Text.Encoding]::UTF8.GetBytes($body); try { $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 30 ("http://127.0.0.1:8103/api/" + $cmd); return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } catch { return "ERR " + $_.Exception.Message } }
function State { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:8103/api/state'; return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json) } catch { return $null } }
function Ndi { ((PostApp 'audio-sessions' '{}') | ConvertFrom-Json).ndi.status }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
$up = $false; for ($i = 0; $i -lt 90 -and -not $up; $i++) { Start-Sleep 1; if (State) { $up = $true } }
Start-Sleep 6
"NDI до: «$(Ndi)»"
"settings: " + (PostApp 'window-open' '{"text":"settings:1"}'); Start-Sleep 2
"галочка NDI: " + (PostApp 'window-open' '{"text":"settings-ndi"}')
"Гаразд: " + (PostApp 'window-open' '{"text":"settings-ok"}'); Start-Sleep 4
"NDI після «Гаразд»: «$(Ndi)»"
# Подвійний дотик по вірші — у зал.
"mode: " + (PostApp 'mode' '{"text":"bible"}'); Start-Sleep 2
$main = [U]::Find([uint32]$app.Id, 'Слово'); $scale = [U]::GetDpiForWindow($main) / 96.0
$o = New-Object U+POINT; [U]::ClientToScreen($main, [ref]$o) | Out-Null; $c = New-Object U+RECT; [U]::GetClientRect($main, [ref]$c) | Out-Null
"InitializeTouchInjection: $([U]::Init())"
$x = [int]($o.X + $c.R * 0.85); $y = [int]($o.Y + $c.B * 0.40)
$s0 = State; "до: зал=$($s0.live) «$($s0.slide.reference)»"
[U]::Tap($x, $y) | Out-Null; Start-Sleep -Milliseconds 80; [U]::Tap($x, $y) | Out-Null; Start-Sleep 2
$s1 = State; "подвійний дотик: зал=$($s1.live) «$($s1.slide.reference)», вибрано $($s1.bible.verses)"
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; $app.WaitForExit(10000) | Out-Null; Start-Sleep 2
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "параметри|NDI:" | Select-Object -Last 6 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
