#!/bin/bash
# Стенд: торкнутися елемента за підписом (content-desc) чи текстом — через дерево uiautomator.
#   tools/tap.sh "Дії" [номер-збігу, з 1]      tools/tap.sh text:"Прибрати зі списку"
set -uo pipefail
A="$HOME/Library/Android/sdk/platform-tools/adb"
WANT="$1"; NTH="${2:-1}"
"$A" shell uiautomator dump --compressed /data/local/tmp/ui.xml >/dev/null 2>&1
"$A" shell cat /data/local/tmp/ui.xml > "${TMPDIR:-/tmp}/ui-tap.xml"
POINT=$(/usr/bin/python3 - "$WANT" "$NTH" "${TMPDIR:-/tmp}/ui-tap.xml" <<'PY'
import re, sys
want, nth, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
xml = open(path, encoding="utf-8", errors="replace").read()
key, value = ("text", want[5:]) if want.startswith("text:") else ("content-desc", want)
hits = []
for node in re.finditer(r"<node [^>]*>", xml):
    n = node.group(0)
    m = re.search(r'%s="([^"]*)"' % key, n)
    if not m or m.group(1) != value:
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if b:
        x1, y1, x2, y2 = map(int, b.groups())
        hits.append(((x1 + x2) // 2, (y1 + y2) // 2))
if len(hits) >= nth:
    print("%d %d" % hits[nth - 1])
PY
)
[ -n "$POINT" ] || { echo "✗ не знайдено: $WANT ($NTH)"; exit 1; }
"$A" shell input tap $POINT
echo "дотик: $WANT → $POINT"
