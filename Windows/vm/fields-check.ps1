# =============================================================================
#  fields-check.ps1 — поля введення й меню «Дії» у справжній Windows
# =============================================================================
#  1) Знімки вітрини полів (--snapshot --only поля --focus 3) у світлій і темній
#     темі — поле «Додати посилання» з курсором і вставленим текстом.
#  2) Справжня програма на тестових даних (--data, свої порти): службова команда
#     пульта відкриває вікно «Додати посилання», текст вставляється з буфера
#     (Ctrl+V), вікно знімається; далі меню «Дії» — знімок екрана.
#  Тека — %LOCALAPPDATA%\slovo-test-fields, після перевірки стирається;
#  %APPDATA%\Slovo не чіпається (час зміни звіряється до й після).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-fields'
$exe = Join-Path $root 'Slovo.exe'; $data = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'Слово.exe') $exe -Force
Copy-Item -LiteralPath (Join-Path $src 'bench-data') $data -Recurse -Force
"sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower().Substring(0,16))"
foreach ($theme in @('light', 'dark')) {
    $argv = @('--snapshot', (Join-Path $root "shots-$theme"), '--only', 'поля', '--focus', '3', '--data', $data)
    if ($theme -eq 'dark') { $argv += '--dark' }
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root "snap-$theme.txt")
    $null = $p.Handle
    if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force }
    $png = Get-ChildItem (Join-Path $root "shots-$theme") -Filter *.png | Select-Object -First 1
    if ($png) { Copy-Item $png.FullName (Join-Path $back "поля-$theme-windows.png") -Force; "поля ($theme): код $($p.ExitCode), $($png.Name)" } else { "поля ($theme): знімка нема, код $($p.ExitCode)" }
}
# Справжня програма.
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
$app = Start-Process -FilePath $exe -ArgumentList '--data', $data, '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"програма: пульт відповідає=$up"
Start-Sleep 3
"links: " + (Post 'window-open' '{"text":"links"}')
Start-Sleep 2
Set-Clipboard -Value "https://www.youtube.com/watch?v=M07ezmR1FII`r`nhttps://youtu.be/IjjWtx2At1U"
$shell = New-Object -ComObject WScript.Shell
$title = 'Додати посилання'
$ok = $shell.AppActivate($title); "AppActivate '$title': $ok"
Start-Sleep -Milliseconds 1500
$shell.SendKeys('^v')
Start-Sleep 2
# Якщо вставку з буфера Windows від цього процесу не пропускає — набрати адресу клавішами.
$shell.SendKeys('https://youtu.be/IjjWtx2At1U{ENTER}https://www.youtube.com/watch?v=M07ezmR1FII')
Start-Sleep 2
# Що потрапило в поле — через UI Automation (поле Avalonia — Edit із ValuePattern).
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$dialog = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $title)))
if ($dialog) {
    $edit = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
    if ($edit) { "у полі: '" + ($edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -replace "`r?`n", ' | ') + "'" } else { 'поля Edit у вікні не знайдено' }
} else { "вікна '$title' в UIA не знайдено" }
$name = 'посилання-windows'; $proc = 'slovo-test-fields'
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\shot-window.ps1'
"close: " + (Post 'window-open' '{"text":"close"}')
Start-Sleep 1
"menu: " + (Post 'window-open' '{"text":"menu:Actions"}')
Start-Sleep 2
# Меню — окреме спливне вікно: знімок усього екрана.
Add-Type -AssemblyName System.Windows.Forms
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save((Join-Path $back 'меню-дії-windows.png'), [System.Drawing.Imaging.ImageFormat]::Png); "екран: $($b.Width)x$($b.Height)"
$shell.SendKeys('{ESC}')
Start-Sleep 1
"програма жива: $(-not $app.HasExited)"
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
$journal = Join-Path $data 'journal.txt'
if (Test-Path $journal) { Get-Content $journal -Encoding UTF8 | Select-String -Pattern 'виняток|Exception|помилк' | Select-Object -First 5 | ForEach-Object { "журнал: $($_.Line)" } }
for ($i = 0; $i -lt 10 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
