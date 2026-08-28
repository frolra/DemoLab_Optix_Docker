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

if [[ ! -f root_ca.crt ]]; then
  echo "ERROR: root_ca.crt not found. Run install.sh from the beginning."
  exit 1
fi

mkdir -p mosquitto/certs

# Self-heal from a bug in earlier v1.1 builds: the password-file generation
# step used to bind-mount the whole mosquitto/secrets directory read-write
# into a container, and eclipse-mosquitto's own entrypoint unconditionally
# chowns /mosquitto (and everything under it) to its internal "mosquitto"
# user whenever it runs as root - which silently reassigned ownership of
# this HOST directory away from the current user. If that happened here
# previously, this user can no longer even chmod/remove it without help.
if [[ -e mosquitto/secrets && ! -O mosquitto/secrets ]]; then
  echo "mosquitto/secrets is owned by another user, most likely from the bind-mount ownership bug in an earlier build of this script. Removing it (sudo) so it can be recreated cleanly..."
  sudo rm -rf mosquitto/secrets
fi
mkdir -p mosquitto/secrets
chmod 700 mosquitto/secrets

# If an earlier failed attempt started the mosquitto container before these
# files existed, Docker may have created empty directories in their place
# for the bind mounts below - and the container itself may still be using
# those stale directory mounts even after the files are regenerated
# correctly, since bind mounts are resolved once at container creation,
# not on every restart. Clean up both possibilities before regenerating.
for path in mosquitto/certs/server.crt mosquitto/certs/ca.crt mosquitto/certs/server.key mosquitto/secrets/mosquitto.passwd; do
  if [[ -d "$path" ]]; then
    echo "Removing stale directory Docker created at $path (a file was expected there)"
    rmdir "$path" 2>/dev/null || rm -rf "$path"
  fi
done
docker compose rm -sf mosquitto >/dev/null 2>&1 || true

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
  rm -f /tmp/mqtt.crt /tmp/mqtt.key

docker exec step-ca step ca certificate \
  "mqtt.${HOSTNAME_FQDN}" \
  /tmp/mqtt.crt \
  /tmp/mqtt.key \
  --ca-url https://localhost:9000 \
  --root /home/step/certs/root_ca.crt \
  --provisioner "$JWK_PROVISIONER" \
  --provisioner-password-file /tmp/provisioner-password \
  --san "mqtt.${HOSTNAME_FQDN}" \
  --san mosquitto \
  --san localhost \
  --not-after 8760h

docker cp \
  step-ca:/tmp/mqtt.crt \
  ./mosquitto/certs/server.crt

docker cp \
  step-ca:/tmp/mqtt.key \
  ./mosquitto/certs/server.key

cp ./root_ca.crt ./mosquitto/certs/ca.crt

chmod 644 mosquitto/certs/server.crt mosquitto/certs/ca.crt
chmod 600 mosquitto/certs/server.key

# Mosquitto's broker process calls drop_privileges() immediately after
# parsing its config - before it opens ANY other file, including TLS
# certificates and the password file (confirmed directly in the upstream
# source, src/mosquitto.c: "Drop privileges permanently immediately after
# the config is loaded... This requires the user to ensure that all
# certificates... are accessible my the `mosquitto` or other unprivileged
# user."). By default it drops to the "mosquitto" user, UID/GID 1883 in
# this image (see its Dockerfile). Every file this script generates is
# owned by the host user running it, so without this step Mosquitto could
# never read its own private key, regardless of any bind-mount or
# ownership fix - this is not a mount problem, it's a genuine permission
# requirement of how Mosquitto itself starts up.
#
# ca.crt/server.crt are world-readable (644) already, so they need no
# change. Grant the "mosquitto" group read access to server.key here
# (chgrp only, not chown, so the host user remains the owner and can still
# manage the file normally) via a container that bind-mounts only this
# single file read-write - never the whole directory, which is what
# caused the directory-ownership bug fixed earlier in this script.
docker run --rm --entrypoint sh \
  -v "$PWD/mosquitto/certs/server.key:/target" \
  eclipse-mosquitto:2.0 \
  -c 'chgrp mosquitto /target'
chmod 640 mosquitto/certs/server.key

rm -f .stepca-password

docker exec step-ca \
  rm -f \
  /tmp/provisioner-password \
  /tmp/mqtt.crt \
  /tmp/mqtt.key

echo "Creating the Mosquitto password file..."

# Remove any stale file from a previous run so this step is idempotent.
rm -f mosquitto/secrets/mosquitto.passwd

# Never bind-mount the whole mosquitto/secrets directory read-write into a
# container to generate this file: eclipse-mosquitto's own entrypoint
# (docker-entrypoint.sh) runs as root and unconditionally runs
# `chown -R mosquitto:mosquitto /mosquitto` whenever /mosquitto/data exists
# (which it always does, built into the image) - through a writable bind
# mount this silently reassigns ownership of the HOST directory to
# mosquitto's internal UID, breaking every later step (including this
# script's own chmod/rm) and even the real broker container's ability to
# use it, in some Docker configurations. Avoid that class of bug entirely:
# generate the file inside an ephemeral, unmounted container instead
# (--entrypoint sh also skips the image's own entrypoint script, so the
# automatic chown never runs at all), then copy the result out with
# `docker cp`, which - per Docker's own documented behavior - always sets
# ownership to the host user who invoked it. Same safe pattern already
# used above for the LDAP/MQTT certificates.
MOSQUITTO_PASSWD_CONTAINER="mosquitto-passwd-tmp-$$"
trap 'docker rm -f "$MOSQUITTO_PASSWD_CONTAINER" >/dev/null 2>&1 || true' EXIT
docker run \
  --name "$MOSQUITTO_PASSWD_CONTAINER" \
  --entrypoint sh \
  -e MQTT_USERNAME="$MQTT_USERNAME" \
  -e MQTT_PASSWORD="$MQTT_PASSWORD" \
  eclipse-mosquitto:2.0 \
  -c 'mosquitto_passwd -b -c /tmp/mosquitto.passwd "$MQTT_USERNAME" "$MQTT_PASSWORD"'

docker cp "$MOSQUITTO_PASSWD_CONTAINER":/tmp/mosquitto.passwd ./mosquitto/secrets/mosquitto.passwd

# Same reasoning as server.key above: Mosquitto opens its password file as
# the "mosquitto" user (UID/GID 1883), after already dropping root
# privileges, so the file must be group-readable by "mosquitto" - chgrp
# only, via a container that mounts just this single file, not the
# directory.
docker run --rm --entrypoint sh \
  -v "$PWD/mosquitto/secrets/mosquitto.passwd:/target" \
  eclipse-mosquitto:2.0 \
  -c 'chgrp mosquitto /target'
chmod 640 mosquitto/secrets/mosquitto.passwd

echo "MQTT certificate and credentials created successfully."
