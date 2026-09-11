#!/bin/bash
#
# Сборка пульта «Слова» в один .apk — без Gradle и без Android Studio.
#
# У пульта нет ни одной сторонней зависимости, поэтому хватает инструментов
# Android SDK и Java: aapt2 → javac → d8 → zipalign → apksigner. Gradle
# добавил бы сотни мегабайт загрузок и свои требования к версии Java ради
# семи файлов. Так же собирается «Панель сервера» — способ проверен.
#
#   ./build.sh
#
# Результат — «Пульт Слова.apk» рядом с этим файлом.

set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
OUT="Пульт Слова.apk"
WORK="Службові"

say() { printf '\033[36m›\033[0m %s\n' "$1"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ -d "$SDK" ] || die "Не найден Android SDK в $SDK. Задайте ANDROID_SDK=путь"
# Свежайшие build-tools и платформа: привязка к номеру ломала бы сборку при
# каждом обновлении SDK.
BT=$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)
[ -n "$BT" ] || die "В SDK нет build-tools"
PLATFORM=$(ls -d "$SDK"/platforms/android-*/ 2>/dev/null | sort -V | tail -1)
[ -n "$PLATFORM" ] || die "В SDK нет ни одной платформы (platforms/android-NN)"
JAR="$PLATFORM/android.jar"
[ -f "$JAR" ] || die "Нет $JAR"

if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /usr/local/opt/openjdk /opt/homebrew/opt/openjdk \
                   "$(/usr/libexec/java_home 2>/dev/null || true)"; do
    [ -x "${candidate:-}/bin/javac" ] && { JAVA_HOME="$candidate"; break; }
  done
fi
[ -x "${JAVA_HOME:-}/bin/javac" ] || die "Не найдена Java. Поставьте: brew install openjdk"
export JAVA_HOME
PATH="$JAVA_HOME/bin:$PATH"

say "SDK         $SDK"
say "build-tools $(basename "$(dirname "$BT/x")")"
say "платформа   $(basename "$(dirname "$PLATFORM/x")")"
say "Java        $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

rm -rf "$WORK/build"
mkdir -p "$WORK/build/classes" "$WORK/build/gen" "$WORK/build/dex"

# Ключ подписи заводится один раз и лежит рядом. С другим ключом телефон
# сочтёт сборку чужой программой и потребует сперва удалить старую — терять
# «Службові/ключ.jks» нельзя.
KEYSTORE="$WORK/ключ.jks"
if [ ! -f "$KEYSTORE" ]; then
  say "Создаю ключ подписи (один раз)"
  keytool -genkeypair -v -keystore "$KEYSTORE" -alias slovo \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass slovoslovo -keypass slovoslovo \
    -dname "CN=Slovo Remote, OU=Church, O=Slovo, L=Kyiv, C=UA" >/dev/null 2>&1
fi

say "Собираю ресурсы"
"$BT/aapt2" compile --dir app/src/main/res -o "$WORK/build/res.zip"

say "Складываю ресурсы с манифестом"
"$BT/aapt2" link \
  -o "$WORK/build/base.apk" \
  -I "$JAR" \
  --manifest app/src/main/AndroidManifest.xml \
  --java "$WORK/build/gen" \
  --min-sdk-version 23 \
  --target-sdk-version 36 \
  "$WORK/build/res.zip"

say "Компилирую код"
find app/src/main/java "$WORK/build/gen" -name '*.java' > "$WORK/build/sources.txt"
javac --release 17 -nowarn -encoding UTF-8 \
  -classpath "$JAR" \
  -d "$WORK/build/classes" \
  @"$WORK/build/sources.txt" 2>&1 | grep -v '^Note:' || true
[ -f "$WORK/build/classes/ua/church/slovo/remote/RemoteActivity.class" ] || die "Компиляция не прошла"

say "Перевожу в dex"
"$BT/d8" --release --min-api 23 --lib "$JAR" \
  --output "$WORK/build/dex" \
  $(find "$WORK/build/classes" -name '*.class')

say "Складываю пакет"
cp "$WORK/build/base.apk" "$WORK/build/unsigned.apk"
(cd "$WORK/build/dex" && zip -q -X ../unsigned.apk classes*.dex)
"$BT/zipalign" -f -p 4 "$WORK/build/unsigned.apk" "$WORK/build/aligned.apk"

say "Подписываю"
"$BT/apksigner" sign \
  --ks "$KEYSTORE" --ks-pass pass:slovoslovo --key-pass pass:slovoslovo \
  --ks-key-alias slovo \
  --min-sdk-version 23 \
  --v4-signing-enabled false \
  --out "$OUT" \
  "$WORK/build/aligned.apk"
"$BT/apksigner" verify --min-sdk-version 23 "$OUT" >/dev/null

VERSION=$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' app/src/main/AndroidManifest.xml | head -1)
SIZE=$(ls -lh "$OUT" | awk '{print $5}')
printf '\033[32m✓ Готово:\033[0m %s (%s, версия %s)\n' "$OUT" "$SIZE" "$VERSION"
