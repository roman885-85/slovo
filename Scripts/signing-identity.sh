#!/bin/zsh
# Постоянная подпись для «Слова».
#
# Зачем: пакет подписывался временной («ad hoc») подписью, которая меняется
# при каждой сборке. Для macOS каждая сборка — новая программа, и разрешения
# (запись звука системы для NDI, доступ к файлам) спрашиваются заново, а
# данные — не действуют. Свой сертификат подписи один раз создаётся здесь,
# дальше `deploy.sh` подписывает им, и разрешения переживают сборки.
#
# Запускает владелец: при добавлении доверия macOS спросит пароль входа —
# это её окно, в скрипте пароля нет.
set -e
NAME="Slovo"
DIR="$(mktemp -d)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "сертификат «$NAME» уже есть"; exit 0
fi

cat > "$DIR/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/ext.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -out "$DIR/identity.p12" -passout pass:slovo >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -out "$DIR/identity.p12" -passout pass:slovo
security import "$DIR/identity.p12" -k "$KEYCHAIN" -P slovo -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Доверие сертификату для подписи кода — здесь macOS спросит пароль входа.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
rm -rf "$DIR"
echo "сертификат «$NAME» создан; следующая сборка подпишется им"
security find-identity -v -p codesigning | grep "$NAME" || true
