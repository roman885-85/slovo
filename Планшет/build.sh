#!/bin/bash
#
# Збірка «Планшета Слова» — окремої програми для планшета — без Gradle.
#
# Спільний код і ресурси бере з пульта для телефона (../Пульт): з'єднання,
# пошук комп'ютера, Біблія, указка, фото. Свої тут лише екран планшета, його
# рядки й маніфест. Так виправлення в спільному коді йдуть в обидві
# програми одразу, а не розходяться копіями.
#
# Пакет ресурсів лишається ua.church.slovo.remote — інакше спільний код не
# знайшов би свого R, — а в систему програма ставиться під своїм іменем
# ua.church.slovo.tablet: на одному пристрої уживаються і пульт, і планшет.
#
#   ./build.sh
#
# Результат — «Планшет Слова.apk» поруч із цим файлом. Працює з Android 5
# (API 21): спільний код пульта перевірено на це скриптом за таблицею
# версій SDK — нічого новішого за API 21 у ньому немає.

set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
PHONE="../Пульт/app/src/main"
OUT="Планшет Слова.apk"
WORK="Службові"

say() { printf '\033[36m›\033[0m %s\n' "$1"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[ -d "$SDK" ] || die "Не знайдено Android SDK у $SDK. Задайте ANDROID_SDK=шлях"
[ -d "$PHONE/java" ] || die "Не знайдено спільного коду пульта: $PHONE"
BT=$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)
[ -n "$BT" ] || die "У SDK немає build-tools"
PLATFORM=$(ls -d "$SDK"/platforms/android-*/ 2>/dev/null | sort -V | tail -1)
[ -n "$PLATFORM" ] || die "У SDK немає жодної платформи (platforms/android-NN)"
JAR="$PLATFORM/android.jar"
[ -f "$JAR" ] || die "Немає $JAR"

if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /usr/local/opt/openjdk /opt/homebrew/opt/openjdk \
                   "$(/usr/libexec/java_home 2>/dev/null || true)"; do
    [ -x "${candidate:-}/bin/javac" ] && { JAVA_HOME="$candidate"; break; }
  done
fi
[ -x "${JAVA_HOME:-}/bin/javac" ] || die "Не знайдено Java. Поставте: brew install openjdk"
export JAVA_HOME
PATH="$JAVA_HOME/bin:$PATH"

say "SDK         $SDK"
say "build-tools $(basename "$(dirname "$BT/x")")"
say "платформа   $(basename "$(dirname "$PLATFORM/x")")"

rm -rf "$WORK/build"
mkdir -p "$WORK/build/classes" "$WORK/build/gen" "$WORK/build/dex"

# Свій ключ: планшет — окрема програма, і підпис у неї свій. Губити
# «Службові/ключ.jks» не можна — інакше оновлення не стане поверх.
KEYSTORE="$WORK/ключ.jks"
if [ ! -f "$KEYSTORE" ]; then
  say "Створюю ключ підпису (один раз)"
  keytool -genkeypair -v -keystore "$KEYSTORE" -alias slovo \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass slovoslovo -keypass slovoslovo \
    -dname "CN=Slovo Tablet, OU=Church, O=Slovo, L=Kyiv, C=UA" >/dev/null 2>&1
fi

say "Збираю ресурси: спільні й свої поверх них"
"$BT/aapt2" compile --dir "$PHONE/res" -o "$WORK/build/phone-res.zip"
"$BT/aapt2" compile --dir app/src/main/res -o "$WORK/build/tablet-res.zip"

say "Складаю ресурси з маніфестом"
"$BT/aapt2" link \
  -o "$WORK/build/base.apk" \
  -I "$JAR" \
  --manifest app/src/main/AndroidManifest.xml \
  --rename-manifest-package ua.church.slovo.tablet \
  --java "$WORK/build/gen" \
  --min-sdk-version 21 \
  --target-sdk-version 36 \
  --auto-add-overlay \
  "$WORK/build/phone-res.zip" -R "$WORK/build/tablet-res.zip"

say "Компілюю код"
find "$PHONE/java" app/src/main/java "$WORK/build/gen" -name '*.java' > "$WORK/build/sources.txt"
javac --release 17 -nowarn -encoding UTF-8 \
  -classpath "$JAR" \
  -d "$WORK/build/classes" \
  @"$WORK/build/sources.txt" 2>&1 | grep -v '^Note:' || true
[ -f "$WORK/build/classes/ua/church/slovo/remote/TabletActivity.class" ] || die "Компіляція не пройшла"

say "Перекладаю в dex"
"$BT/d8" --release --min-api 21 --lib "$JAR" \
  --output "$WORK/build/dex" \
  $(find "$WORK/build/classes" -name '*.class')

say "Складаю пакет"
cp "$WORK/build/base.apk" "$WORK/build/unsigned.apk"
(cd "$WORK/build/dex" && zip -q -X ../unsigned.apk classes*.dex)
"$BT/zipalign" -f -p 4 "$WORK/build/unsigned.apk" "$WORK/build/aligned.apk"

say "Підписую"
"$BT/apksigner" sign \
  --ks "$KEYSTORE" --ks-pass pass:slovoslovo --key-pass pass:slovoslovo \
  --ks-key-alias slovo \
  --min-sdk-version 21 \
  --v4-signing-enabled false \
  --out "$OUT" \
  "$WORK/build/aligned.apk"
"$BT/apksigner" verify --min-sdk-version 21 "$OUT" >/dev/null

VERSION=$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' app/src/main/AndroidManifest.xml | head -1)
SIZE=$(ls -lh "$OUT" | awk '{print $5}')
printf '\033[32m✓ Готово:\033[0m %s (%s, версія %s)\n' "$OUT" "$SIZE" "$VERSION"
