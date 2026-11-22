# =============================================================================
#  4-cleanup.ps1 — прибрати за собою
# =============================================================================
#  Закрити програму, забрати journal.txt, стерти %LOCALAPPDATA%\slovo-test і
#  показати, що лишилося на екрані. Запит брандмауера Windows і два його правила
#  (Inbound/Block для тестового шляху) сценарій НЕ чіпає — це налаштування безпеки
#  власника.
# =============================================================================
$ErrorActionPreference = 'Continue'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test'; $data = Join-Path $root 'data'
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
Copy-Item (Join-Path $data 'journal.txt') (Join-Path $back 'journal.txt') -Force -ErrorAction SilentlyContinue
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
"тестову теку прибрано: $(-not (Test-Path $root)); справжня %APPDATA%\Slovo існує: $(Test-Path (Join-Path $env:APPDATA 'Slovo'))"
"процесів Slovo: $((Get-Process Slovo -ErrorAction SilentlyContinue | Measure-Object).Count)"
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W2 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
"@
$titles = New-Object System.Collections.ArrayList
[W2]::EnumWindows({ param($h, $l) if ([W2]::IsWindowVisible($h)) { $sb = New-Object System.Text.StringBuilder 256; [void][W2]::GetWindowTextW($h, $sb, 256); if ($sb.Length -gt 0) { [void]$titles.Add($sb.ToString()) } }; return $true }, [IntPtr]::Zero) | Out-Null
"видимі вікна: " + ($titles -join ' | ')
"правила брандмауера для тестового шляху: " + ((Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -like '*slovo-test*' } | Get-NetFirewallRule | ForEach-Object { "$($_.DisplayName):$($_.Direction)/$($_.Action)/$($_.Profile)" }) -join '; ')
