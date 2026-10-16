#!/bin/sh
# Creates the project's signing certificate (once) and stores it as the
# repository secrets the release workflow signs every build with. macOS ties
# the app's permissions to that certificate, so they survive updates.
#
#   sh scripts/signing-cert.sh [folder]   (default ~/gandarfh/kuroneko-signing)
#
# The private key never enters the repository: it stays in the folder as
# signing.p12 + password.txt. Keep both in a password manager; a new
# certificate makes macOS ask for the permissions again once.
set -eu

DIR="${1:-$HOME/gandarfh/kuroneko-signing}"
REPO="gandarfh/kuroneko"
NAME="Kuroneko Release Signing"
# LibreSSL, from macOS: its .p12 imports with `security` (OpenSSL 3's does not).
OPENSSL=/usr/bin/openssl

command -v gh >/dev/null || { echo "erro: precisa do gh (GitHub CLI)" >&2; exit 1; }
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

if [ ! -f signing.p12 ] || [ ! -f password.txt ]; then
  cat > cert.cnf <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${NAME}
O = ${REPO}
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  "$OPENSSL" req -x509 -newkey rsa:3072 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf </dev/null
  "$OPENSSL" rand -base64 24 | tr -d '\n' > password.txt
  "$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out signing.p12 -passout file:password.txt </dev/null
  rm -f key.pem
  chmod 600 ./*
  echo "Certificado criado em ${DIR}."
fi

base64 -i signing.p12 | gh secret set KURONEKO_SIGNING_P12 --repo "$REPO"
gh secret set KURONEKO_SIGNING_PASSWORD --repo "$REPO" < password.txt
echo "Secrets KURONEKO_SIGNING_P12 e KURONEKO_SIGNING_PASSWORD gravados em ${REPO}."
echo "Guarde ${DIR}/signing.p12 e ${DIR}/password.txt no seu gerenciador de senhas."
