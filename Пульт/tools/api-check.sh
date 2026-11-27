#!/bin/bash
# Справжній мережевий код пульта й планшета (Api.java, State.java) — проти несправжнього
# «Слова» (fake-slovo.py), на Mac, без емулятора: кожна команда, указка, наближення, стан,
# картинки й мертвий порт. Запускає build.sh пульта й планшета; провал — збірки немає.
#
# Навіщо: збірка 27.11 11:10 ставила тіло запиту після connect() — «Already connected», і
# ЖОДНА команда не доходила до програми, а опит стану працював, тож зв'язок здавався живим.
# Ця перевірка ловить саме таке.
#
#   tools/api-check.sh            (порт 18299 — щоб не заважати fake-slovo.py стенда)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../app/src/main/java/ua/church/slovo/remote"
# org.json — той самий, що в Android (AOSP, Apache 2.0, копія з SDK sources/android-29 у api-check/json).
JAVA="${JAVA_HOME:-/usr/local/opt/openjdk}/bin"
PORT="${API_CHECK_PORT:-18299}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/api-check.XXXXXX")
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT
{ find "$HERE/api-check" -name "*.java"; echo "$SRC/Api.java"; echo "$SRC/State.java"; } > "$WORK/sources.txt"
"$JAVA/javac" -nowarn -encoding UTF-8 -d "$WORK/classes" @"$WORK/sources.txt" 2>&1 | grep -v '^Note:' >&2
[ -f "$WORK/classes/ua/church/slovo/remote/Harness.class" ] || { echo "✗ api-check: не зібралося"; exit 1; }
/usr/bin/python3 "$HERE/fake-slovo.py" --port "$PORT" > "$WORK/server.log" 2>&1 &
SERVER=$!
disown "$SERVER" 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.3; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; done
"$JAVA/java" -cp "$WORK/classes" ua.church.slovo.remote.Harness "$PORT" > "$WORK/run.log" 2>&1
CODE=$?
grep -E "^(✓|✗)|ПІДСУМОК" "$WORK/run.log"
exit $CODE
