#!/bin/bash
# =============================================================================
#  core-compare.sh — звірка ядра Windows-«Слова» з Mac рядок у рядок
# =============================================================================
#  Обидві програми друкують усе, що вміє ядро, у тому самому вигляді:
#    • Mac — tools/slovo-ref (Swift поверх справжнього Sources/SlovoCore);
#    • Windows — `Slovo.dll --core-check` (C#; на Mac через dotnet).
#  Дані — копія Службові/core-data (тека даних із Slovo.ini, hotkeys.ini, модулями,
#  пісенниками, шаблонами, .lng); оригінал не змінюється. Еталонові тека даних
#  підставляється домашньою (CFFIXED_USER_HOME/Library/Application Support/Slovo),
#  як у справжнього «Слова». Випадкові UUID і тимчасові шляхи вирівнюються.
#  Очікувана розбіжність одна: ourwords (у Windows свої слова й вбудований en.json).
#
#  Виклик: tools/core-compare.sh [тека для виводу]   (за замовчанням — тимчасова)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$(mktemp -d -t slovo-core-compare)}"
REF=tools/slovo-ref/.build/release/slovo-ref
[ -x "$REF" ] || swift build -c release --package-path tools/slovo-ref >/dev/null
[ -d Службові/core-data ] || { echo "немає Службові/core-data"; exit 1; }
rm -rf "$OUT/data" "$OUT/home" "$OUT/ref" "$OUT/win"; mkdir -p "$OUT/home/Library/Application Support" "$OUT/ref" "$OUT/win"
cp -R Службові/core-data "$OUT/data"
ln -s "$OUT/data" "$OUT/home/Library/Application Support/Slovo"
CFFIXED_USER_HOME="$OUT/home" "$REF" "$OUT/data" > "$OUT/ref.txt" 2> "$OUT/ref.err" || { echo "еталон упав:"; tail -3 "$OUT/ref.err"; exit 1; }
./dev.sh run --core-check "$OUT/data" > "$OUT/win.txt" 2> "$OUT/win.err" || { echo "core-check упав:"; tail -3 "$OUT/win.err"; exit 1; }
split() { awk -v d="$2" 'BEGIN{n="000-head"} /^# /{n=substr($0,3); gsub(/[^A-Za-z0-9_-]/,"_",n)} {print > (d "/" n ".txt")}' "$1"; }
split "$OUT/ref.txt" "$OUT/ref"; split "$OUT/win.txt" "$OUT/win"
norm() { sed -E 's#\\/#/#g' "$1" | sed -E 's/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/UUID/g;
  s#(/private)?/var/folders/[^"]*/slovo-core-check-[0-9a-f]+/Slovo#DATA#g; s#\\/var\\/folders\\/[^"]*\\/slovo-core-check-[0-9a-f]+\\/Slovo#DATA#g;
  s#(/private)?'"$OUT"'/data#DATA#g; s#(/private)?/var/folders/[^ ]*/slovo-check-res-[0-9A-F-]+#TMP#g'; }
fail=0
for f in "$OUT"/ref/*.txt; do
  n=$(basename "$f" .txt)
  if [ ! -f "$OUT/win/$n.txt" ]; then echo "✗ $n: у Windows немає розділу"; fail=1; continue; fi
  d=$(diff <(norm "$f") <(norm "$OUT/win/$n.txt") | grep -c '^[<>]' || true)
  if [ "$d" = "0" ]; then echo "✓ $n ($(wc -l < "$f" | tr -d ' ') рядків)";
  elif [ "$n" = "ourwords" ]; then echo "≈ $n: $d рядків — очікувано (свої слова Windows і вбудований en.json)";
  else echo "✗ $n: розбіжних $d"; fail=1; fi
done
for f in "$OUT"/win/*.txt; do n=$(basename "$f" .txt); [ -f "$OUT/ref/$n.txt" ] || echo "• $n: лише у Windows (звіряється окремим еталоном)"; done
echo "вивід: $OUT"
exit $fail
