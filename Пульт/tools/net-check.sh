#!/bin/bash
# Замір мережі пульта й планшета на емуляторі з несправжнім «Словом» (tools/fake-slovo.py).
#
#   tools/net-check.sh <тека для знімків і журналів>
#
# Що робить: ставить обидві збірки, з'єднує їх із 10.0.2.2:18199, веде указку пальцем
# (adb input swipe, 3 × 3 с) і щипок (стенд `--es pinch 1`), пише лічильники телефона
# (`adb logcat -s SlovoNet`) і сервера (за секундами), знімає екрани. Розмір екрана
# емулятора повертає, яким був. Працює лише при ввімкненому налагодженні USB.
set -uo pipefail
OUT="${1:?тека для результатів}"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
A="$HOME/Library/Android/sdk/platform-tools/adb"
SIZE=$("$A" shell wm size | awk '/Override/{print $3}'); DENS=$("$A" shell wm density | awk '/Override/{print $3}')
/usr/bin/python3 "$HERE/fake-slovo.py" --port 18199 --log "$OUT/server-totals.json" > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; [ -n "$SIZE" ] && "$A" shell wm size "$SIZE" || "$A" shell wm size reset; [ -n "$DENS" ] && "$A" shell wm density "$DENS" || "$A" shell wm density reset' EXIT
sleep 1
"$A" install -r "$ROOT/Пульт/Пульт Слова.apk" | tail -1
"$A" install -r "$ROOT/Планшет/Планшет Слова.apk" | tail -1
"$A" logcat -c
"$A" logcat -s SlovoNet:V > "$OUT/phone.log" 2>&1 &
LOGCAT=$!
mark() { echo "=== $1 $(date +%T)" | tee -a "$OUT/server.log" >> "$OUT/marks.log"; }

# --- пульт, телефон 411 dp, масштаб 100 %
"$A" shell wm size 1080x2280; "$A" shell wm density 420; sleep 3
"$A" shell am start -n ua.church.slovo.remote/.RemoteActivity --es host 10.0.2.2 --ei port 18199 --es scale 1.0 >/dev/null; sleep 20
"$A" shell am start -n ua.church.slovo.remote/.RemoteActivity --es tab show --es meter 1 >/dev/null; sleep 12
"$A" exec-out screencap -p > "$OUT/pult-slides.png"
mark "пульт: указка 3 × 3 с"
for i in 1 2 3; do "$A" shell input swipe 250 450 850 750 3000; sleep 1.5; done
mark "пульт: щипок 2 × 1,2 с"
for i in 1 2; do "$A" shell am start -n ua.church.slovo.remote/.RemoteActivity --es pinch 1 >/dev/null; sleep 4; done
"$A" exec-out screencap -p > "$OUT/pult-zoomed.png"
mark "пульт: фото — дотик по першому фото у списку"
"$A" shell am start -n ua.church.slovo.remote/.RemoteActivity --es tab show >/dev/null; sleep 3
"$A" exec-out uiautomator dump --compressed /dev/tty > "$OUT/pult-ui.xml" 2>/dev/null
mark "пульт: кінець"
sleep 3
"$A" shell am force-stop ua.church.slovo.remote

# --- планшет, 1280×800 dp
"$A" shell wm size reset; "$A" shell wm density reset; sleep 3
"$A" shell am start -n ua.church.slovo.tablet/ua.church.slovo.remote.TabletActivity --es host 10.0.2.2 --ei port 18199 --es scale 1.0 >/dev/null; sleep 25
"$A" shell am start -n ua.church.slovo.tablet/ua.church.slovo.remote.TabletActivity --es tab presentation --es meter 1 >/dev/null; sleep 10
"$A" exec-out screencap -p > "$OUT/tablet.png"
mark "планшет: указка 3 × 3 с"
for i in 1 2 3; do "$A" shell input swipe 1450 250 1800 450 3000; sleep 1.5; done
mark "планшет: щипок 2 × 1,2 с"
for i in 1 2; do "$A" shell am start -n ua.church.slovo.tablet/ua.church.slovo.remote.TabletActivity --es pinch 1 >/dev/null; sleep 4; done
mark "планшет: кінець"
sleep 3
"$A" shell am force-stop ua.church.slovo.tablet
kill $LOGCAT 2>/dev/null
echo "готово: $OUT"
