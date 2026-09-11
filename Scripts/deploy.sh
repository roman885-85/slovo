#!/bin/zsh
# Собрать «Слово» и положить готовое в папку проекта.
#
# Заведён потому, что дважды выходило одно и то же: правки есть в исходниках,
# а владелец запускает вчерашнюю копию и видит старое. Теперь один сценарий
# делает всё разом и пишет, что именно обновил.
#
#   Scripts/deploy.sh            — собрать и обновить ~/Documents/Слово/Слово.app
#   SLOVO_DEST=~/Слово Scripts/deploy.sh — те саме в іншу теку
#
# Порядок внутри — не случайный: сначала пакет собирается целиком (двоичный
# файл, Info.plist, значок, данные, библиотеки), и только потом подписывается.
# Подпись, поставленная раньше, чем в пакет докладывали библиотеки, была
# порченой — macOS терпела это лишь потому, что подпись своя.
set -e
cd "$(dirname "$0")/.."
# Тека призначення: у власника — ~/Documents/Слово, у будь-кого іншого —
# своя, через SLOVO_DEST.
DEST="${SLOVO_DEST:-$HOME/Documents/Слово}"
APP="$DEST/Слово.app"
TOOLCHAIN="$(xcode-select -p)"

echo "== сборка =="
# Две архитектуры: своя — обычной сборкой, другая — кросс-сборкой по тройке.
# Полного Xcode нет, и `--arch` дважды не работает (нужен xcbuild), а по
# тройке Command Line Tools собирают. На Apple Silicon с Big Sur программа
# тогда идёт своим ходом, без Rosetta.
NATIVE="$(uname -m)"
if [ "$NATIVE" = "arm64" ]; then OTHER="x86_64"; else OTHER="arm64"; fi
# Останавливаемся по коду самой сборки, а не по наличию файла: вчерашний
# двоичный файл в `.build` лежит и после неудачной сборки, и однажды он так
# и уехал в пакет — с ошибками компиляции на экране и старым кодом внутри.
# Вывод сборки — в файл, а на экран только ошибки: под `set -e` конвейер с
# grep без совпадений сам ронял сценарий.
mkdir -p .build
# SLOVO_DEBUG=1 — отладочная сборка вместо release: она инкрементальная и
# идёт минуту, а release собирает мишень целиком по 10–15 минут на каждую
# правку. Годится только для проверок здесь же; пакет владельцу — без ключа.
CONFIG="release"
if [ -n "$SLOVO_DEBUG" ]; then CONFIG="debug"; echo "ОТЛАДОЧНАЯ сборка (SLOVO_DEBUG): не для владельца"; fi
# `|| NATIVE_STATUS=$?`, а не отдельной строкой: под `set -e` неудачная
# сборка обрывала сценарий раньше, чем он успевал сказать об ошибке.
NATIVE_STATUS=0
swift build -c "$CONFIG" > .build/native-build.log 2>&1 || NATIVE_STATUS=$?
grep -E "error:" .build/native-build.log || true
if [ "$NATIVE_STATUS" -ne 0 ]; then echo "сборка не прошла — пакет не трогаем (см. .build/native-build.log)"; exit 1; fi
BIN_NATIVE=".build/$NATIVE-apple-macosx/$CONFIG/Slovo"
[ -f "$BIN_NATIVE" ] || { echo "нет двоичного файла — сборка не прошла"; exit 1; }
# Кросс-сборка — в своей папке. В общей `.build` она подменяла описание
# сборки, и родная после этого не пересобиралась («command … not
# registered»): в пакет уходил вчерашний слой.
# SLOVO_FAST=1 пропускает кросс-сборку: при разборе одной поломки правка
# проверяется здесь же, на этой машине, и вторая архитектура — лишние
# минуты на каждый круг. Пакет для владельца собирается без этого ключа.
BIN_OTHER=".build/cross-$OTHER/$OTHER-apple-macosx/release/Slovo"
if [ -n "$SLOVO_FAST" ]; then
  echo "быстрая сборка: кросс-сборка под $OTHER пропущена (SLOVO_FAST)"
  rm -f "$BIN_OTHER"
else
  swift build -c release --triple "$OTHER-apple-macosx11.0" --scratch-path ".build/cross-$OTHER" 2>&1 | grep -E "error:" || true
fi
if [ -f "$BIN_OTHER" ] && lipo -create "$BIN_NATIVE" "$BIN_OTHER" -output ".build/Slovo-universal" 2>/dev/null; then
  BIN=".build/Slovo-universal"
  echo "двоичный файл универсальный: $NATIVE + $OTHER"
else
  BIN="$BIN_NATIVE"
  echo "двоичный файл только $NATIVE — сборка под $OTHER не прошла"
fi

echo "== раскладка =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Slovo"
# Info.plist и значок — из репозитория: пакет должен собираться и на пустом
# столе, а не только поверх вчерашнего.
cp Scripts/Info.plist "$APP/Contents/Info.plist"
# Значок — лише якщо він є: у відкритому коді зображень немає.
[ -f Scripts/Slovo.icns ] && cp Scripts/Slovo.icns "$APP/Contents/Resources/Slovo.icns"
# Наши подписи на других языках — файлами: правятся без пересборки.
rm -rf "$APP/Contents/Resources/OurWords"
if [ -d Resources/OurWords ]; then
  cp -R Resources/OurWords "$APP/Contents/Resources/OurWords"
  echo "словари наших подписей: $(ls Resources/OurWords/*.json 2>/dev/null | wc -l | tr -d ' ') языков"
fi
rm -rf "$APP/Contents/_CodeSignature"
# Остаток прерванной подписи (*.cstemp) ломает любую следующую: «invalid or
# unsupported format for signature» — и пакет оставался неподписанным вовсе.
find "$APP" -name "*.cstemp" -delete 2>/dev/null

# Данные программы (Resources/app: модули, страницы автора, шаблоны) в
# репозитории не лежат — сотни мегабайт. Если пакет собирается с нуля, берём
# их клоном из соседнего пакета на столе: клон APFS не занимает места.
if [ ! -d "$APP/Contents/Resources/app" ]; then
  for sibling in "$DEST"/*.app; do
    [ "$sibling" = "$APP" ] && continue
    if [ -d "$sibling/Contents/Resources/app" ]; then
      cp -Rc "$sibling/Contents/Resources/app" "$APP/Contents/Resources/app" 2>/dev/null \
        || cp -R "$sibling/Contents/Resources/app" "$APP/Contents/Resources/app"
      echo "данные Resources/app взяты из $(basename "$sibling")"
      break
    fi
  done
fi
[ -d "$APP/Contents/Resources/app" ] || echo "ВНИМАНИЕ: в пакете нет Resources/app — ни модулей, ни страниц автора"
# Файл умовчань програми та розкладка клавіш — з репозиторію, щоразу: це
# частина програми, а не дані користувача. Саме з них програма стартує на
# новому комп'ютері, нічого не питаючи в установленого VisioBible.
mkdir -p "$APP/Contents/Resources/app"
cp Resources/Defaults/Slovo.ini "$APP/Contents/Resources/app/Slovo.ini"
cp Resources/Defaults/hotkeys.ini "$APP/Contents/Resources/app/hotkeys.ini"
echo "умовчання в пакеті: Slovo.ini ($(grep -c '^\[' Resources/Defaults/Slovo.ini) секцій), hotkeys.ini"

# Програми для Android — усередині «Слова»: людина зберігає їх з програми
# на комп'ютер або завантажує зі сторінки пульта в браузері просто на
# телефон чи планшет. Версії беремо з самих пакетів, щоб сторінка й вікно
# показували правду, а не число, забуте в коді.
rm -rf "$APP/Contents/Resources/Android"
mkdir -p "$APP/Contents/Resources/Android"
BT_ANDROID=$(ls -d "$HOME/Library/Android/sdk/build-tools"/*/ 2>/dev/null | sort -V | tail -1)
APPS_JSON="{"
for pair in "phone:Пульт/Пульт Слова.apk" "tablet:Планшет/Планшет Слова.apk"; do
  id="${pair%%:*}"; file="${pair#*:}"
  if [ -f "$file" ]; then
    cp "$file" "$APP/Contents/Resources/Android/"
    version=""; minsdk=""
    if [ -n "$BT_ANDROID" ]; then
      badging=$("$BT_ANDROID/aapt2" dump badging "$file" 2>/dev/null)
      version=$(printf '%s' "$badging" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)
      minsdk=$(printf '%s' "$badging" | sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" | head -1)
    fi
    [ "$APPS_JSON" = "{" ] || APPS_JSON="$APPS_JSON,"
    APPS_JSON="$APPS_JSON\"$id\":{\"file\":\"$(basename "$file")\",\"version\":\"$version\",\"minSdk\":${minsdk:-0}}"
  else
    echo "ВНИМАНИЕ: нет $file — в пакет не попал"
  fi
done
printf '%s}\n' "$APPS_JSON" > "$APP/Contents/Resources/Android/apps.json"
echo "программы для Android в пакете: $(ls "$APP/Contents/Resources/Android" | grep -c '\.apk$') — $(cat "$APP/Contents/Resources/Android/apps.json")"

# Swift Concurrency: на macOS 12 и новее библиотека есть в системе, а в
# Big Sur (11) её нет, и dyld не запустит программу. Кладём копию из тулчейна
# и добавляем путь поиска; на новых системах dyld всё равно возьмёт системную,
# потому что /usr/lib/swift стоит в списке первым.
BACKDEPLOY=""
for candidate in "$TOOLCHAIN/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib" \
                 "$TOOLCHAIN/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib"; do
  [ -f "$candidate" ] && { BACKDEPLOY="$candidate"; break; }
done
if [ -n "$BACKDEPLOY" ]; then
  cp "$BACKDEPLOY" "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
  echo "libswift_Concurrency внутри пакета: да"
else
  echo "libswift_Concurrency: НЕ НАЙДЕНА в тулчейне — на macOS 11 программа не запустится"
fi
if ! otool -l "$APP/Contents/MacOS/Slovo" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Slovo"
fi
MINOS="$(otool -l "$APP/Contents/MacOS/Slovo" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
echo "минимальная система: macOS $MINOS; архитектуры: $(lipo -archs "$APP/Contents/MacOS/Slovo")"

# Библиотека NDI внутри пакета: без неё трансляция — «только предпросмотр»,
# а на чужой машине NDI Tools может не быть. Берём копию из папки программы
# или из установленных NDI Tools / SDK на этой машине.
NDI_SRC=""
for candidate in "$DEST/libndi.dylib" "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib" "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi.dylib" /Applications/NDI*.app/Contents/Frameworks/libndi.dylib; do
  [ -f "$candidate" ] && { NDI_SRC="$candidate"; break; }
done
if [ -n "$NDI_SRC" ]; then
  cp "$NDI_SRC" "$APP/Contents/Frameworks/libndi.dylib"
  NDI_MINOS="$(otool -arch x86_64 -l "$NDI_SRC" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{f=1} f&&/minos|version /{print $2; exit}')"
  echo "libndi внутри пакета: да ($(du -h "$NDI_SRC" | cut -f1) из $NDI_SRC; требует macOS $NDI_MINOS)"
else
  echo "libndi внутри пакета: нет — положите libndi.dylib в $DEST"
fi
# NDI 6.x требует macOS 13, и на Big Sur dyld её не загружает. Вторая
# библиотека — NDI 5.x, которую владелец кладёт рядом сам как
# libndi-bigsur.dylib, — едет в пакет под именем libndi.5.dylib: загрузчик
# программы перебирает имена по очереди и берёт ту, что открылась.
if [ -f "$DEST/libndi-bigsur.dylib" ]; then
  # Имя — по выпуску внутри файла (libndi.4.dylib, libndi.5.dylib): загрузчик
  # программы перебирает именно такие имена после libndi.dylib.
  OLD_MAJOR="$(strings -a "$DEST/libndi-bigsur.dylib" | grep -E '^NDI SDK APPLE' | head -1 | awk '{print $NF}' | cut -d. -f1)"
  [ -n "$OLD_MAJOR" ] || OLD_MAJOR="5"
  cp "$DEST/libndi-bigsur.dylib" "$APP/Contents/Frameworks/libndi.$OLD_MAJOR.dylib"
  OLD_MINOS="$(otool -arch x86_64 -l "$DEST/libndi-bigsur.dylib" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{f=1} f&&/minos|version /{print $2; exit}')"
  echo "libndi для Big Sur внутри пакета: да, как libndi.$OLD_MAJOR.dylib (требует macOS $OLD_MINOS, архитектуры: $(lipo -archs "$DEST/libndi-bigsur.dylib"))"
else
  echo "libndi для Big Sur: нет — на macOS 11–12 NDI работать не будет; положите libndi 5.x в $DEST как libndi-bigsur.dylib"
fi

# yt-dlp внутри пакета: собранный в один файл (Scripts/build-ytdlp.sh) —
# программа тогда не зависит ни от Python, ни от чего-либо ещё на машине.
if [ -f "$DEST/yt-dlp_macos" ]; then
  cp "$DEST/yt-dlp_macos" "$APP/Contents/Resources/yt-dlp"
  chmod +x "$APP/Contents/Resources/yt-dlp"
  echo "yt-dlp внутри пакета: да"
else
  echo "yt-dlp внутри пакета: нет (соберите Scripts/build-ytdlp.sh)"
fi

echo "== подпись =="
# Своим сертификатом, если он есть (Scripts/signing-identity.sh): временная
# подпись меняется с каждой сборкой, и macOS каждый раз заново спрашивает
# разрешения — на запись звука системы для NDI в первую очередь.
if security find-identity -v -p codesigning | grep -q '"Slovo"'; then
  # Первый вызов codesign с новым ключом macOS может остановить диалогом
  # доступа к ключу — сборка не должна висеть на нём: ждём 40 с и подписываем
  # временно, а владелец подтверждает диалог, когда увидит.
  codesign --force --deep --sign "Slovo" "$APP" >/dev/null 2>&1 &
  CS=$!
  for i in $(seq 1 40); do kill -0 $CS 2>/dev/null || break; sleep 1; done
  if kill -0 $CS 2>/dev/null; then
    kill $CS 2>/dev/null; wait $CS 2>/dev/null
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "подпись временная: codesign ждал диалога связки ключей — нажмите в нём «Дозволити завжди» и повторите deploy"
  elif codesign -dvv "$APP" 2>&1 | grep -q "Authority=Slovo"; then
    echo "подписано сертификатом «Slovo»"
  else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "подпись временная: сертификат «Slovo» не принят"
  fi
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "подпись временная: разрешения macOS не переживут пересборку — запустите Scripts/signing-identity.sh"
fi

# Исходники лежат рядом с программой — в этой же папке на столе, и
# копировать их больше некуда: копия затёрла бы саму рабочую папку.
echo "== исходники =="
echo "рабочая копия: $PWD"

echo "готово: $APP"
ls -l "$APP/Contents/MacOS/Slovo" | awk '{print $6, $7, $8, $9}'
find Sources -name "*.swift" | wc -l | xargs echo "файлов Swift:"
