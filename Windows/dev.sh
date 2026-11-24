#!/bin/bash
# =============================================================================
#  dev.sh — збирати й запускати «Слово» для Windows на Mac (для перевірок)
# =============================================================================
#  ./dev.sh build                 — Debug-збірка (dotnet build)
#  ./dev.sh run [ключі…]          — запустити Debug-збірку (dotnet Slovo.dll …)
#  Інструмент — спільний із «Проповідником»: ../Проповідник/toolchain
#  (SLOVO_TOOLCHAIN=/шлях — інший). Для робочих копій (git worktree) шлях
#  до інструменту беремо з основної копії.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
TOOLCHAIN="${SLOVO_TOOLCHAIN:-$HOME/Documents/Слово/Исходники/Проповідник/toolchain}"
export DOTNET_ROOT="$TOOLCHAIN/dotnet"
export NUGET_PACKAGES="$TOOLCHAIN/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_CLI_UI_LANGUAGE=en
export PATH="$DOTNET_ROOT:$PATH"
case "${1:-build}" in
  build) shift || true; dotnet build -c Debug -v q --nologo "$@" ;;
  run)   shift; exec dotnet bin/Debug/net10.0/Slovo.dll "$@" ;;
  *)     echo "./dev.sh build | run [ключі…]"; exit 2 ;;
esac
