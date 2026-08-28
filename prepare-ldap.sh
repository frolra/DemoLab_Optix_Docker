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

mkdir -p ldap/certs ldap/secrets
chmod 700 ldap/secrets

printf '%s' "$LDAP_ADMIN_PASSWORD" \
  > ldap/secrets/ldap-admin-password

chmod 600 ldap/secrets/ldap-admin-password

echo "Detecting the JWK provisioner..."

JWK_PROVISIONER=$(
  docker exec step-ca step ca provisioner list \
    --ca-url https://localhost:9000 \
    --root /home/step/certs/root_ca.crt |
  jq -r '.[] | select(.type == "JWK") | .name' |
  head -n 1
)

if [[ -z "$JWK_PROVISIONER" ]]; then
  echo "ERROR: no JWK provisioner was found."
  echo "Available provisioners:"

  docker exec step-ca step ca provisioner list \
    --ca-url https://localhost:9000 \
    --root /home/step/certs/root_ca.crt |
  jq '.[] | {name, type}'

  exit 1
fi

echo "Using JWK provisioner: $JWK_PROVISIONER"

printf '%s\n' "$STEPCA_PASSWORD" > .stepca-password
chmod 600 .stepca-password

docker cp \
  .stepca-password \
  step-ca:/tmp/provisioner-password

docker exec -u root step-ca \
  chown step:step /tmp/provisioner-password

docker exec step-ca \
  chmod 600 /tmp/provisioner-password

docker exec step-ca \
  rm -f /tmp/ldap.crt /tmp/ldap.key

docker exec step-ca step ca certificate \
  "ldap.${HOSTNAME_FQDN}" \
  /tmp/ldap.crt \
  /tmp/ldap.key \
  --ca-url https://localhost:9000 \
  --root /home/step/certs/root_ca.crt \
  --provisioner "$JWK_PROVISIONER" \
  --provisioner-password-file /tmp/provisioner-password \
  --san "ldap.${HOSTNAME_FQDN}" \
  --san openldap \
  --san localhost \
  --not-after 8760h

docker cp \
  step-ca:/tmp/ldap.crt \
  ./ldap/certs/ldap.crt

docker cp \
  step-ca:/tmp/ldap.key \
  ./ldap/certs/ldap.key

chmod 644 ldap/certs/ldap.crt
chmod 600 ldap/certs/ldap.key

rm -f .stepca-password

docker exec step-ca \
  rm -f \
  /tmp/provisioner-password \
  /tmp/ldap.crt \
  /tmp/ldap.key

echo "LDAP secret and certificate created successfully."