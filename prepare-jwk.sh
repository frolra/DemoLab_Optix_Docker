#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: file .env not found."
  exit 1
fi

set -a
source ./.env
set +a

echo "Detecting the JWK provisioner..."

PROVISIONER_LIST=$(
  docker exec step-ca step ca provisioner list \
    --ca-url https://localhost:9000 \
    --root /home/step/certs/root_ca.crt
)

JWK_PROVISIONER=$(
  echo "$PROVISIONER_LIST" |
  jq -r '.[] | select(.type == "JWK") | .name' |
  head -n 1
)

if [[ -z "$JWK_PROVISIONER" ]]; then
  echo "ERROR: no JWK provisioner was found."
  echo "Available provisioners:"
  echo "$PROVISIONER_LIST" | jq '.[] | {name, type}'
  exit 1
fi

echo "Using JWK provisioner: $JWK_PROVISIONER"

ENCRYPTED_KEY=$(
  echo "$PROVISIONER_LIST" |
  jq -r --arg name "$JWK_PROVISIONER" '.[] | select(.name == $name) | .encryptedKey'
)

if [[ -z "$ENCRYPTED_KEY" || "$ENCRYPTED_KEY" == "null" ]]; then
  echo "ERROR: provisioner $JWK_PROVISIONER has no encryptedKey; cannot derive jwk_key.json."
  exit 1
fi

# Decrypt the provisioner's own encryptedKey (a password-protected JWE) using
# the same STEPCA_PASSWORD already used elsewhere as the provisioner
# password. This reproduces, non-interactively, the manual procedure
# documented by the stepca-web fork itself:
#   step ca provisioner list | jq -r '...encryptedKey' | step crypto jwe decrypt | jq
printf '%s\n' "$STEPCA_PASSWORD" > .stepca-password
chmod 600 .stepca-password

docker cp .stepca-password step-ca:/tmp/provisioner-password
docker exec -u root step-ca chown step:step /tmp/provisioner-password
docker exec step-ca chmod 600 /tmp/provisioner-password

printf '%s' "$ENCRYPTED_KEY" > .jwk-encrypted-key.jwe
chmod 600 .jwk-encrypted-key.jwe
docker cp .jwk-encrypted-key.jwe step-ca:/tmp/jwk-encrypted-key.jwe
rm -f .jwk-encrypted-key.jwe

docker exec -u root step-ca rm -f /tmp/jwk_key.json

docker exec step-ca sh -c \
  'step crypto jwe decrypt --password-file /tmp/provisioner-password < /tmp/jwk-encrypted-key.jwe > /tmp/jwk_key.json'

docker cp step-ca:/tmp/jwk_key.json ./jwk_key.json
chmod 600 jwk_key.json

rm -f .stepca-password
docker exec step-ca rm -f /tmp/provisioner-password /tmp/jwk-encrypted-key.jwe /tmp/jwk_key.json

python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path("jwk_key.json").read_text(encoding="utf-8"))
required = {"kty", "kid", "crv", "x", "y", "d"}
missing = required - data.keys()
if missing:
    raise SystemExit(f"ERROR: generated jwk_key.json is missing fields: {sorted(missing)}")
PY

printf '%s' "$JWK_PROVISIONER" > .jwk-provisioner-name

echo "jwk_key.json generated from the '$JWK_PROVISIONER' provisioner."
