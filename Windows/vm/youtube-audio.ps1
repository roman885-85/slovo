# =============================================================================
#  youtube-audio.ps1 — звук вбудованого YouTube (WebView2) у «Відео по Wi-Fi»,
#  і дзеркало проектора окремим вікном у справжній Windows
# =============================================================================
#  Справжня програма на тестових даних (test-data-yt: Wi-Fi-відео ввімкнено, шлях
#  до yt-dlp — неіснуючий, тож YouTube іде вбудованим програвачем). Ролик із
#  безперервним звуком; через 12 с — службова команда пульта audio-sessions:
#  хто грає на пристрої виводу (процес, пік), процес рушія WebView2 і чи він у
#  дереві «Слова», що каже програвач (гучність, без звуку), що прийшло в канал.
#  Шматки Wi-Fi — на Mac для ffmpeg. Потім — «⤢» (window-open mirror): знімок вікна.
#  Тека стирається; %APPDATA%\Slovo не чіпається (час зміни звіряється).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\yt-audio'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-yt'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
"sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower().Substring(0,16))"
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-yt') $d -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function Fetch($url) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 $url; return , $r.RawContentStream.ToArray() } catch { return $null } }
function Media { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18103/api/media'; return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json) } catch { return $null } }
function Tree($id) {
    $chain = @(); $seen = @{}
    while ($id -and -not $seen.ContainsKey($id)) {
        $seen[$id] = 1
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p) { $chain += "$id(нема)"; break }
        $chain += "$($p.Name)#$id"; $id = $p.ParentProcessId
    }
    return ($chain -join ' ← ')
}
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--quiet-start', '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up; «Слово» #$($app.Id)"
Start-Sleep 3
"media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}')
$wifi = Join-Path $back 'wifi'
New-Item -ItemType Directory -Force -Path $wifi | Out-Null
$order = New-Object System.Collections.ArrayList; $seen = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
$asked = $false
while ($clock.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 700
    $list = Fetch 'http://127.0.0.1:18200/wifi/stream.m3u8'
    if ($list) {
        foreach ($name in ([Text.Encoding]::UTF8.GetString($list) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '*.ts' })) {
            if (-not $seen.ContainsKey($name)) { $bytes = Fetch "http://127.0.0.1:18200/wifi/$name"; if ($bytes) { [IO.File]::WriteAllBytes((Join-Path $wifi $name), $bytes); $seen[$name] = 1; [void]$order.Add($name) } }
        }
    }
    if (-not $asked -and $clock.Elapsed.TotalSeconds -gt 20) {
        $asked = $true
        $m = Media
        "{0:N0} с: «{1}» грає={2} {3:N1}/{4:N1} гучність={5} без звуку={6}" -f $clock.Elapsed.TotalSeconds, $m.title, $m.playing, $m.position, $m.duration, $m.volume, $m.muted
        $a = Post 'audio-sessions' '{}'
        "audio-sessions: $a"
        $j = $a | ConvertFrom-Json
        if ($j.embed -and $j.embed.browserPid) { "рушій WebView2: " + (Tree ([int]$j.embed.browserPid)) }
        foreach ($s in $j.sessions) { if ($s.pid) { "сесія $($s.name)#$($s.pid) ($($s.state), пік $($s.peak)): " + (Tree ([int]$s.pid)) } }
        Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object {
            $type = if ($_.CommandLine -match '--type=(\S+)') { $Matches[1] } else { 'browser' }
            $sub = if ($_.CommandLine -match '--utility-sub-type=(\S+)') { ' ' + $Matches[1] } else { '' }
            "  msedgewebview2#$($_.ProcessId) $type$sub ← батько #$($_.ParentProcessId)"
        }
    }
}
$order -join "`n" | Set-Content (Join-Path $wifi 'order.txt') -Encoding ASCII
"шматків Wi-Fi: $($order.Count)"
"після: " + (Post 'audio-sessions' '{}')
# Дзеркало проектора окремим вікном.
"media-pause: " + (Post 'media-pause' '{}')
"mirror: " + (Post 'window-open' '{"text":"mirror"}')
Start-Sleep 3
$name = 'yt-audio\дзеркало-вікно-windows'; $proc = 'slovo-test-yt'; $title = 'Дзеркало проектора'
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\shot-window.ps1'
"close: " + (Post 'window-open' '{"text":"close"}')
Start-Sleep 1
"програма жива: $(-not $app.HasExited)"
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$journal = Join-Path $d 'journal.txt'
if (Test-Path $journal) { Get-Content $journal -Encoding UTF8 | Select-Object -Last 15 | ForEach-Object { "журнал: $_" } }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
