#!/bin/bash
# =============================================================================
#  build.sh — збирає «Проповідник Слова» для Windows в один .exe
# =============================================================================
#  Збирається на Mac, працює у Windows 10/11: .NET кладе всю потрібну обслугу
#  всередину файлу, на цільовому комп'ютері ставити нічого не треба.
#  Результат: ~/Documents/Слово/Проповідник Слова.exe
#  Інше місце: PROPOVIDNYK_OUT=/шлях ./build.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

OUT="${PROPOVIDNYK_OUT:-$HOME/Documents/Слово}"
NAME="Проповідник Слова"
TOOLCHAIN="$PWD/toolchain"
export DOTNET_ROOT="$TOOLCHAIN/dotnet"
export NUGET_PACKAGES="$TOOLCHAIN/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
if [ -x "$DOTNET_ROOT/dotnet" ]; then
  export PATH="$DOTNET_ROOT:$PATH"
else
  echo "Немає toolchain/dotnet. Отримати .NET SDK у теку проєкту:"
  echo "  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh"
  echo "  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir \"$TOOLCHAIN/dotnet\""
  exit 1
fi

echo "▶ Іконка"
# Значок — той самий, що в «Слова» на Mac: з Slovo.icns береться 1024-піксельний
# кадр, make-ico.swift складає з нього .ico на сім розмірів.
if [ -f ../Scripts/Slovo.icns ] && command -v swiftc >/dev/null; then
  sips -s format png ../Scripts/Slovo.icns --out /tmp/propovidnyk-icon.png >/dev/null 2>&1 \
    && swiftc -O make-ico.swift -o /tmp/propovidnyk-make-ico 2>/dev/null \
    && /tmp/propovidnyk-make-ico /tmp/propovidnyk-icon.png Resources/AppIcon.ico Resources/AppIcon-256.png \
    && echo "  значок зібрано з Slovo.icns" || echo "  значок не зібрався — беру готовий"
fi

echo "▶ Збірка win-x64 (один самодостатній файл)"
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none \
  -o "$PWD/Службові/publish" -v q --nologo
[ -f "Службові/publish/Propovidnyk.exe" ] || { echo "✗ Propovidnyk.exe не з'явився"; exit 1; }
mkdir -p "$OUT"
cp "Службові/publish/Propovidnyk.exe" "$OUT/$NAME.exe"
echo "✓ $(du -h "$OUT/$NAME.exe" | cut -f1) — $OUT/$NAME.exe"
