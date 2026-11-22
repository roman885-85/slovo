# =============================================================================
#  2-drive.ps1 — керування: пульт, справжні кнопки й клавіші, знімки
# =============================================================================
#  Стан і команди — через пульт (127.0.0.1:8103); кнопки «Сховати», «Показати»,
#  «Чорний» натискаються через UI Automation, клавіші Esc/F5/F12/→ — SendKeys;
#  знімки екрана робляться зсередини Windows (prlctl capture дає чорний кадр,
#  коли вікно Parallels не на екрані). Усе лягає в Службові/vm на Mac.
#  У меню й у вкладках є однакова назва «Пісні»: UIA знаходить першим меню.
# =============================================================================
$ErrorActionPreference = 'Continue'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
New-Item -ItemType Directory -Force -Path $back | Out-Null
$api = 'http://127.0.0.1:8103/api'
function Post($cmd, $body) {
    try { Invoke-RestMethod -Method Post -Uri "$api/$cmd" -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 }
    catch { "  ! $cmd — $($_.Exception.Message)" }
}
function State() { Invoke-RestMethod -Uri "$api/state?since=0" -TimeoutSec 20 }
function Shot($name) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $back $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    "  знімок екрана $name ($($b.Width)x$($b.Height)), моніторів: $([System.Windows.Forms.Screen]::AllScreens.Count)"
}
"процесів Slovo: $((Get-Process Slovo -ErrorAction SilentlyContinue | Measure-Object).Count); пам'ять: $([int]((Get-Process Slovo | Measure-Object WorkingSet64 -Sum).Sum / 1MB)) МБ"
$s = State
"state: mode=$($s.mode) name=$($s.name) live=$($s.live)"
$books = Invoke-RestMethod -Uri "$api/bible/books" -TimeoutSec 20
"books: $($books.books.Count); translations: $(($books.translations | ForEach-Object { $_.name }) -join ' | ')"
$john = ($books.books | Where-Object { $_.name -like 'Іван*' -or $_.name -like '*Івана*' -or $_.name -like 'Ів*' } | Select-Object -First 1).position
"john position: $john"
Shot 'screen-1-start.png'
Post 'bible-select' ('{"book":' + $john + ',"chapter":3,"verses":[16],"live":true}') | Out-Null
Start-Sleep -Seconds 2
$s = State; "after bible-select: live=$($s.live) reference=$($s.slide.reference) text=$($s.slide.text.Substring(0, [Math]::Min(40, $s.slide.text.Length)))"
Shot 'screen-2-bible.png'
$snap = Post 'window-snapshot' '{}'
Copy-Item $snap.snapshot (Join-Path $back 'win-bible.png') -Force
Copy-Item $snap.'зал' (Join-Path $back 'hall-bible.png') -Force

# Справжні клацання й клавіші: UI Automation і SendKeys.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$rootEl = [System.Windows.Automation.AutomationElement]::RootElement
$win = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Слово')))
"головне вікно в UIA: $($null -ne $win)"
function Click($name) {
    $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)))
    if ($null -eq $el) { "  ! кнопки «$name» не знайдено"; return }
    $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 900
}
if ($null -ne $win) {
    Click 'Сховати';  $s = State; "кнопка «Сховати»: live=$($s.live) hall=$($s.hall.kind)"
    Click 'Показати'; $s = State; "кнопка «Показати»: live=$($s.live) hall=$($s.hall.kind)"
    Click 'Чорний';   $s = State; "кнопка «Чорний»: black=$($s.black) hall=$($s.hall.kind)"
    Click 'Чорний';   $s = State; "кнопка «Чорний» ще раз: black=$($s.black) hall=$($s.hall.kind)"
    Click 'Пісні';    $s = State; "вкладка «Пісні»: mode=$($s.mode)"
    Click 'Біблія';   $s = State; "вкладка «Біблія»: mode=$($s.mode)"
}
$wsh = New-Object -ComObject WScript.Shell
$activated = $wsh.AppActivate('Слово')
Start-Sleep -Milliseconds 700
"вікно активовано для клавіш: $activated"
$wsh.SendKeys('{ESC}');  Start-Sleep -Milliseconds 900; $s = State; "Esc: live=$($s.live)"
$wsh.SendKeys('{F5}');   Start-Sleep -Milliseconds 900; $s = State; "F5: live=$($s.live)"
$wsh.SendKeys('{F12}');  Start-Sleep -Milliseconds 900; $s = State; "F12: black=$($s.black)"
$wsh.SendKeys('{F12}');  Start-Sleep -Milliseconds 900; $s = State; "F12 ще раз: black=$($s.black)"
$wsh.SendKeys('{RIGHT}'); Start-Sleep -Milliseconds 900; $s = State; "стрілка →: reference=$($s.slide.reference)"

# Пісні, шаблон, зображення.
$songBooks = Invoke-RestMethod -Uri "$api/songs/books" -TimeoutSec 20
"songbooks: $(($songBooks.books | ForEach-Object { $_.title }) -join ' | ')"
Post 'mode' '{"text":"songs"}' | Out-Null
Post 'songs-book' ('{"text":"' + $songBooks.books[0].id + '"}') | Out-Null
Post 'song' '{"index":4}' | Out-Null
Post 'part' '{"index":1}' | Out-Null
Start-Sleep -Seconds 2
$s = State; "song: $($s.song.title) | hall: $($s.slide.reference)"
Shot 'screen-3-songs.png'
$snap = Post 'window-snapshot' '{}'
Copy-Item $snap.snapshot (Join-Path $back 'win-songs.png') -Force
Copy-Item $snap.'зал' (Join-Path $back 'hall-song.png') -Force
$pics = Invoke-RestMethod -Uri "$api/pictures" -TimeoutSec 20
"pictures: $($pics.count)"
Post 'picture' '{"index":3}' | Out-Null
Start-Sleep -Seconds 2
Shot 'screen-4-picture.png'
$hall = Invoke-WebRequest -Uri "$api/hall.jpg?w=640" -UseBasicParsing -TimeoutSec 20
"hall.jpg: $($hall.StatusCode), $($hall.RawContentLength) байт"
try { $web = Invoke-WebRequest -Uri 'http://127.0.0.1:8105/' -UseBasicParsing -TimeoutSec 20; "web page: $($web.StatusCode), $($web.Content.Length) знаків" } catch { "web page: $($_.Exception.Message)" }
# Брандмауер: чи є правило для програми і чи слухають порти.
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 8103,8105,80 } | ForEach-Object { "слухає: $($_.LocalAddress):$($_.LocalPort)" }
(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -like '*slovo-test*' } | Measure-Object).Count | ForEach-Object { "правил брандмауера для програми: $_" }
