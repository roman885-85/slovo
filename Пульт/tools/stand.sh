#!/bin/bash
# Стенд пульта й планшета на емуляторі `tablet` — без дотиків, де можна.
#
#   tools/stand.sh shot <файл.png>            знімок екрана (і зменшена копія <файл>-s.png)
#   tools/stand.sh phone | tablet             розмір екрана: телефон 411 dp або планшет 1280×800 dp
#   tools/stand.sh remote [tab] [open]        запустити пульт: --es tab bible, --es open settings
#   tools/stand.sh tabletapp [tab] [open]     запустити планшет
#   tools/stand.sh lang uk|en                 мова пристрою
#
# «Слово» для перевірки — ізольована копія на портах 8199/8198 (див. Docs/ЖУРНАЛ.md),
# з емулятора вона видна як 10.0.2.2:8199.
set -euo pipefail
A="$HOME/Library/Android/sdk/platform-tools/adb"
HOST="${SLOVO_HOST:-10.0.2.2}"; PORT="${SLOVO_PORT:-8199}"
case "${1:-}" in
  shot)
    "$A" exec-out screencap -p > "$2"
    sips -Z "${3:-1100}" "$2" --out "${2%.png}-s.png" >/dev/null
    ;;
  phone)  "$A" shell wm size 1080x2280; "$A" shell wm density 420 ;;
  tablet) "$A" shell wm size reset; "$A" shell wm density reset ;;
  remote|tabletapp)
    if [ "$1" = remote ]; then C=ua.church.slovo.remote/.RemoteActivity; else C=ua.church.slovo.tablet/ua.church.slovo.remote.TabletActivity; fi
    ARGS=(--es host "$HOST" --ei port "$PORT")
    [ -n "${2:-}" ] && ARGS+=(--es tab "$2")
    [ -n "${3:-}" ] && ARGS+=(--es open "$3")
    "$A" shell am start -n "$C" "${ARGS[@]}" >/dev/null
    ;;
  lang)
    "$A" shell "settings put system system_locales ${2}-$( [ "$2" = uk ] && echo UA || echo US )" ;;
  *) sed -n '2,12p' "$0" ;;
esac
