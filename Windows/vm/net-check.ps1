# =============================================================================
#  net-check.ps1 — NDI і slovotest.local у звичайному запуску (відповідач mDNS увімкнено)
# =============================================================================
#  Власник (1.4.2): «ndi не работает вообще — по сети не видится» (NDI Runtime стоїть, доступи
#  є) і «slovo.local в windows не работает». Справжня програма A у звичайному режимі (пульт,
#  ім'я slovotest.local, NDI) + окремий процес B шукає джерела NDI; Windows розпізнає ім'я.
#  Потім A без пульта (без відповідача mDNS) — B шукає ще раз. Брандмауер лише читається.
#  Тека стирається; %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-net'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
$ndi = [Environment]::GetEnvironmentVariable('NDI_RUNTIME_DIR_V6', 'Machine'); if ($ndi) { $env:NDI_RUNTIME_DIR_V6 = $ndi }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
"IPv4: " + ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }) -join ', ')
"профіль мережі: " + ((Get-NetConnectionProfile | ForEach-Object { "$($_.InterfaceAlias):$($_.NetworkCategory)" }) -join ', ')
function Listen5353 { (Get-NetUDPEndpoint -LocalPort 5353 -ErrorAction SilentlyContinue | ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "$($_.LocalAddress)/$($p.ProcessName)#$($_.OwningProcess)" }) -join ', ' }
function Lister($tag) {
    $d = Join-Path $root "data-b-$tag"
    Copy-Item -LiteralPath (Join-Path $src 'vm-new\bench-data') $d -Recurse -Force
    $out = Join-Path $root "list-$tag.txt"
    $p = Start-Process -FilePath $exe -ArgumentList '--snapshot', (Join-Path $root "shots-$tag"), '--only', 'заставка', '--data', $d, '--ndi-list', '10' -PassThru -NoNewWindow -RedirectStandardOutput $out
    $null = $p.Handle; $p.WaitForExit(120000) | Out-Null
    Get-Content $out -Encoding UTF8 | Where-Object { $_ -match 'NDI джерела' } | ForEach-Object { "   B: $($_.Trim())" }
}
function RunA($tag, $data) {
    $d = Join-Path $root "data-a-$tag"
    Copy-Item -LiteralPath (Join-Path $src "vm-new\$data") $d -Recurse -Force
    $app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
    Start-Sleep 25
    "[$tag] A #$($app.Id) жива: $(-not $app.HasExited)"
    "   UDP 5353: $(Listen5353)"
    Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "ім'я|mDNS|NDI|пульт: слухаю|пульт у браузері" | Select-Object -Last 8 | ForEach-Object { "   журнал A: $($_.Line)" }
    return $app
}
# 1) Звичайний запуск: пульт і відповідач mDNS увімкнено.
$a = RunA 'mdns' 'test-data-net'
"A-READY"
$clock = [Diagnostics.Stopwatch]::StartNew()
try { $r = Resolve-DnsName slovotest.local -Type A -ErrorAction Stop; "   Resolve-DnsName slovotest.local: $(($r | ForEach-Object { $_.IPAddress }) -join ', ') за $($clock.ElapsedMilliseconds) мс" } catch { "   Resolve-DnsName slovotest.local: НЕ ВИЙШЛО за $($clock.ElapsedMilliseconds) мс — $($_.Exception.Message)" }
try { $w = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 'http://slovotest.local:8105/'; "   http://slovotest.local:8105/ → $($w.StatusCode), $($w.RawContentLength) байт" } catch { "   http://slovotest.local:8105/ → $($_.Exception.Message)" }
Lister 'mdns'
Start-Sleep 30
"A-DONE"
Stop-Process -Id $a.Id -Force -ErrorAction SilentlyContinue; $a.WaitForExit(10000) | Out-Null; Start-Sleep 3
# 2) Без пульта — відповідача mDNS немає.
$dn = Join-Path $src 'vm-new\test-data-net'
$d2 = Join-Path $root 'data-a-nomdns-src'
Copy-Item -LiteralPath $dn $d2 -Recurse -Force
$json = Get-Content (Join-Path $d2 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$json.options.remoteEnabled = $false; $json.options.remoteWebEnabled = $false
$json | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $d2 'settings.json') -Encoding UTF8
$app2 = Start-Process -FilePath $exe -ArgumentList '--data', $d2 -PassThru
Start-Sleep 25
"[nomdns] A #$($app2.Id) жива: $(-not $app2.HasExited)"
"   UDP 5353: $(Listen5353)"
Get-Content (Join-Path $d2 'journal.txt') -Encoding UTF8 | Select-String "ім'я|mDNS|NDI" | Select-Object -Last 4 | ForEach-Object { "   журнал A: $($_.Line)" }
Lister 'nomdns'
Stop-Process -Id $app2.Id -Force -ErrorAction SilentlyContinue; $app2.WaitForExit(10000) | Out-Null; Start-Sleep 2
"брандмауер (лише читання): " + ((Get-NetFirewallApplicationFilter -Program $exe -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | ForEach-Object { "$($_.DisplayName)/$($_.Direction)/$($_.Action)/$($_.Profile)/$($_.Enabled)" }) -join '; ')
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
