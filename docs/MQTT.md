# MQTT and Mosquitto

v1.1 adds Eclipse Mosquitto for MQTT connectivity (for example, FactoryTalk Optix) plus MQTTX Web for browser-based testing.

## Listeners

| Listener | Port | Transport                | Audience | Authentication |
|----------|------|---------------------------|----------|----------------|
| MQTTS    | 8883 | MQTT over TLS, published to the host | External MQTT clients (FactoryTalk Optix, `mosquitto_pub`/`mosquitto_sub`, etc.) | `MQTT_USERNAME` / `MQTT_PASSWORD` required |
| Plain MQTT | 1883 | Unencrypted MQTT, published to the host | Quick local testing, or FactoryTalk Optix scenarios without TLS | Anonymous (no credentials) |
| WebSocket | 9001 | MQTT over WebSocket, internal only | MQTTX Web, reverse-proxied by Caddy over WSS | `MQTT_USERNAME` / `MQTT_PASSWORD` required |

`per_listener_settings true` in `mosquitto.conf` lets each listener have its own authentication policy: MQTTS and the WebSocket listener still require `MQTT_USERNAME` / `MQTT_PASSWORD` from `.env`, while the plain MQTT listener on 1883 is intentionally open (`allow_anonymous true`, no `password_file`) so it can be used to quickly test both authenticated and anonymous connection scenarios — for example from FactoryTalk Optix — without needing to import the CA certificate first.

**Security trade-off:** the 1883 listener has no encryption and no authentication whatsoever — anyone who can reach `MQTT_BIND_IP:1883` can publish/subscribe to any topic. This is a deliberate choice for lab convenience, not a production-safe default. Set `MQTT_BIND_IP` in `.env` to a specific, trusted network interface (never `0.0.0.0` on a network you don't fully control), and see [Security](SECURITY.md).

## Certificate issuance

The Mosquitto server certificate is issued directly by step-ca, the same way the LDAP certificate is issued in v1.0:

1. `prepare-mqtt.sh` detects the JWK provisioner.
2. It requests a certificate for `mqtt.<HOSTNAME_FQDN>` (SANs: `mqtt.<HOSTNAME_FQDN>`, `mosquitto`, `localhost`).
3. The certificate and key are copied from the `step-ca` container to `mosquitto/certs/server.crt` and `mosquitto/certs/server.key` on the host, then bind-mounted read-only into the `mosquitto` container.
4. `root_ca.crt` is copied to `mosquitto/certs/ca.crt` so Mosquitto (and MQTT clients) can validate the chain.

`prepare-mqtt.sh` also creates `mosquitto/secrets/mosquitto.passwd` using `mosquitto_passwd`.

### File permissions

Mosquitto's broker process drops root privileges to its own internal `mosquitto` user (UID/GID `1883` in this image) immediately after parsing its config — before it opens any certificate or the password file. Since every file `prepare-mqtt.sh` generates is owned by whichever host user ran it, `server.key` and `mosquitto.passwd` are `chgrp`'d to the `mosquitto` group and set to `640` so that user can actually read them; `server.crt`/`ca.crt` are left world-readable (`644`) and need no such change. This is a genuine requirement of how Mosquitto itself starts up, not a workaround for a Docker quirk — see [Troubleshooting](TROUBLESHOOTING.md) if you ever see `Error: Unable to open pwfile`.

`install.sh` calls `./prepare-mqtt.sh` automatically. Re-run it manually after changing `MQTT_USERNAME` or `MQTT_PASSWORD` in `.env`.

## Suggested FactoryTalk Optix connections

TLS, authenticated (recommended for anything beyond quick local testing):

```text
Host: mqtt.<HOSTNAME_FQDN>
Port: 8883
TLS: enabled
CA: root_ca.crt
Username: MQTT_USERNAME
Password: MQTT_PASSWORD
```

Plain, anonymous (no TLS, no credentials — for quick testing only):

```text
Host: <HOST_IP> (or mqtt.<HOSTNAME_FQDN>)
Port: 1883
TLS: disabled
Username: (leave blank)
Password: (leave blank)
```

## MQTTX Web

MQTTX Web is available at `https://mqtt.<HOSTNAME_FQDN>`. Configure a new connection with:

```text
Host: mqttws.<HOSTNAME_FQDN>
Port: 443
Path: /
TLS: enabled (WSS, terminated by Caddy)
Username: MQTT_USERNAME
Password: MQTT_PASSWORD
```

The connection cannot be pre-provisioned for you. The official `emqx/mqttx-web` image is a static single-page app: its only configurable default (`VUE_APP_DEFAULT_HOST`) is baked in at build time by the upstream project, not adjustable via container environment variables, and every connection a user creates is stored only in that browser's local storage, never on the server. Pre-seeding it server-side would require forking and rebuilding the image ourselves, which this repository intentionally avoids to keep using the official upstream image.

## Notes

- A later version may add mutual TLS with a dedicated Optix client certificate; v1.1 uses username/password authentication only.
- Mosquitto persists retained messages and subscriptions in the `mosquitto_data` named volume.
