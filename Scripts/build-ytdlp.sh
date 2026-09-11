#!/bin/zsh
# Собрать yt-dlp в один файл, чтобы он ехал внутри «Слово.app».
#
# Владелец просил: программа должна работать без внешних дополнений. yt-dlp
# из исходников требует Python 3.10+ на машине; собранный PyInstaller'ом
# файл несёт Python в себе и ставить ничего не надо. JavaScript-движок
# (deno/node) ему не нужен: HLS-дорожки YouTube, которыми играет «Слово»,
# отдаются и без него — проверено.
#
# Исходники yt-dlp кладёт владелец: папка yt-dlp-master рядом с пакетом.
set -e
DEST="$HOME/Documents/Слово"
SRC="${1:-$DEST/yt-dlp-master}"
[ -f "$SRC/yt_dlp/__main__.py" ] || { echo "нет исходников yt-dlp: $SRC"; exit 1; }
PY=""
for candidate in /opt/homebrew/opt/python@3.14/bin/python3.14 /usr/local/opt/python@3.14/bin/python3.14 \
                 /opt/homebrew/opt/python@3.13/bin/python3.13 /usr/local/opt/python@3.13/bin/python3.13 \
                 /opt/homebrew/opt/python@3.12/bin/python3.12 /usr/local/opt/python@3.12/bin/python3.12 \
                 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
  [ -x "$candidate" ] || continue
  if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)'; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || { echo "нужен Python 3.10+ (brew install python@3.12)"; exit 1; }
echo "Python: $PY"
# Homebrew не даёт ставить пакеты в свой Python (PEP 668) — собираем в
# отдельном окружении, оно лежит в папке программы и никому не мешает.
VENV="$HOME/Library/Application Support/Slovo/ytdlp-build"
[ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --upgrade pip pyinstaller
cd "$SRC"
"$VENV/bin/python" -m pip install --quiet -r requirements.txt 2>/dev/null || true
if [ -f pyinst.py ]; then "$VENV/bin/python" pyinst.py; else "$VENV/bin/python" -m bundle.pyinstaller; fi
OUT="$(ls dist/yt-dlp_macos* 2>/dev/null | head -1)"
[ -n "$OUT" ] || { echo "сборка не дала файла в dist/"; exit 1; }
cp "$OUT" "$DEST/yt-dlp_macos"
chmod +x "$DEST/yt-dlp_macos"
echo "готово: $DEST/yt-dlp_macos ($(du -h "$DEST/yt-dlp_macos" | cut -f1)); deploy.sh положит его внутрь пакета"
