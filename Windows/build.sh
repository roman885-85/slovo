#!/bin/bash
# =============================================================================
#  build.sh — збирає «Слово» для Windows в один .exe
# =============================================================================
#  Збирається на Mac, працює у Windows 10/11 (64-розрядних): .NET кладе всю
#  потрібну обслугу всередину файлу, на цільовому комп'ютері ставити нічого
#  не треба. Інструмент — спільний із «Проповідником Слова»:
#  ../Проповідник/toolchain (у git не йде; як отримати — друкує сценарій).
#  Результат: ~/Documents/Слово/Слово.exe
#  Інше місце: SLOVO_WIN_OUT=/шлях ./build.sh
#  Лише перевірити збірку без .exe: ./build.sh check
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

OUT="${SLOVO_WIN_OUT:-$HOME/Documents/Слово}"
NAME="Слово"
TOOLCHAIN="${SLOVO_TOOLCHAIN:-$PWD/../Проповідник/toolchain}"
export DOTNET_ROOT="$TOOLCHAIN/dotnet"
export NUGET_PACKAGES="$TOOLCHAIN/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_UI_LANGUAGE=en
if [ -x "$DOTNET_ROOT/dotnet" ]; then
  export PATH="$DOTNET_ROOT:$PATH"
else
  echo "Немає $TOOLCHAIN/dotnet. Отримати .NET SDK у теку інструменту:"
  echo "  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh"
  echo "  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir \"$TOOLCHAIN/dotnet\""
  exit 1
fi

if [ "${1:-}" = "check" ]; then
  dotnet build -c Release -v q --nologo
  exit $?
fi

echo "▶ Значок"
# Значок — той самий, що в «Слова» на Mac: з Slovo.icns береться 1024-піксельний
# кадр, make-ico.swift складає з нього .ico на сім розмірів і AppIcon-256.png.
if [ -f ../Scripts/Slovo.icns ] && command -v swiftc >/dev/null; then
  sips -s format png ../Scripts/Slovo.icns --out /tmp/slovo-win-icon.png >/dev/null 2>&1 \
    && swiftc -O make-ico.swift -o /tmp/slovo-win-make-ico 2>/dev/null \
    && /tmp/slovo-win-make-ico /tmp/slovo-win-icon.png Resources/AppIcon.ico Resources/AppIcon-256.png \
    && echo "  значок зібрано з Slovo.icns" || echo "  значок не зібрався — беру готовий"
fi

echo "▶ Збірка win-x64 (один самодостатній файл)"
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:IncludeAllContentForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none \
  -o "$PWD/Службові/publish" -v q --nologo
[ -f "Службові/publish/Slovo.exe" ] || { echo "✗ Slovo.exe не з'явився"; exit 1; }
mkdir -p "$OUT"
cp "Службові/publish/Slovo.exe" "$OUT/$NAME.exe"
echo "✓ $(du -h "$OUT/$NAME.exe" | cut -f1) — $OUT/$NAME.exe"
