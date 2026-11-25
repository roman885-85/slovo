# =============================================================================
#  mdns-check.ps1 — чи піднімається відповідач slovotest.local поруч зі службою DNS Windows
# =============================================================================
#  Справжня програма у звичайному режимі (test-data-net: пульт, ім'я slovotest); через 25 с —
#  хто слухає UDP 5353, що пише журнал про ім'я, і чи розпізнає ім'я сама Windows. Брандмауер
#  не змінюється. Тека стирається; %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-mdns'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-net') $d -Recurse -Force
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
Start-Sleep 25
"A жива: $(-not $app.HasExited)"
"UDP 5353: " + ((Get-NetUDPEndpoint -LocalPort 5353 -ErrorAction SilentlyContinue | ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "$($_.LocalAddress)/$($p.ProcessName)#$($_.OwningProcess)" }) -join ', ')
"TCP Slovo: " + ((Get-NetTCPConnection -State Listen -OwningProcess $app.Id -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', ')
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "ім'я|mDNS|пульт" | Select-Object -Last 8 | ForEach-Object { "журнал: $($_.Line)" }
$clock = [Diagnostics.Stopwatch]::StartNew()
try { $r = Resolve-DnsName slovotest.local -Type A -ErrorAction Stop; "Resolve-DnsName: $(($r | ForEach-Object { $_.IPAddress }) -join ', ') за $($clock.ElapsedMilliseconds) мс" } catch { "Resolve-DnsName: не вийшло за $($clock.ElapsedMilliseconds) мс" }
Start-Sleep 2
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "mDNS|запит" | Select-Object -Last 4 | ForEach-Object { "журнал після: $($_.Line)" }
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; $app.WaitForExit(10000) | Out-Null; Start-Sleep 2
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
