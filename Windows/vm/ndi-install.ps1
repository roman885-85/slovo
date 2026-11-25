# =============================================================================
#  ndi-install.ps1 — NDI 6 Runtime у тестову ВМ (з дозволу власника 25.11.2026)
# =============================================================================
#  Від імені користувача: установник (офіційний, downloads.ndi.tv) — у локальну теку,
#  перевірка підпису Authenticode. Саме встановлення (Inno Setup /VERYSILENT, ліцензію
#  NDI прийнято власником) запускає vm/ndi-check.sh від SYSTEM — без вікна UAC.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\ndi\NDI 6 Runtime.exe'
$dir = 'C:\Users\Public\slovo-ndi'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -LiteralPath $src (Join-Path $dir 'ndi-runtime.exe') -Force
$sig = Get-AuthenticodeSignature (Join-Path $dir 'ndi-runtime.exe')
"підпис: $($sig.Status); $($sig.SignerCertificate.Subject)"
"sha256: $((Get-FileHash (Join-Path $dir 'ndi-runtime.exe') -Algorithm SHA256).Hash.ToLower())"
"NDI до встановлення: $([Environment]::GetEnvironmentVariable('NDI_RUNTIME_DIR_V6','Machine'))"
