# Step CA Demo Lab

Reproducible Docker Compose lab for step-ca, PostgreSQL, Caddy, OpenLDAP/LDAPS, phpLDAPadmin, LDAP-enabled StepCA Web, Keycloak, InfluxDB, and Portainer.

v1.1 extends the lab into a broader FactoryTalk Optix integration toolbox: directly-exposed PostgreSQL, MySQL, and Microsoft SQL Server, a CloudBeaver web UI for all three, Eclipse Mosquitto with MQTTS and MQTT-over-WebSocket, MQTTX Web, and a read-only Certificate Download Portal.

## Architecture

![Architecture diagram: clients reach web UIs through Caddy's automatic HTTPS, while step-ca issues certificates for every TLS-protected service across the pki, database, and directly-exposed network segments](docs/architecture.svg)

## Quick Start

```bash
cp .env.example .env
nano .env
dos2unix install.sh prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh
chmod +x install.sh prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh
./install.sh
```

`install.sh` generates `Caddyfile` from `Caddyfile.template`, so changing `HOSTNAME_FQDN` in `.env` is sufficient for all Caddy hostnames.

Before touching Docker at all, `install.sh` validates every value in `.env`: every required variable is set (no leftover `CHANGE_ME` placeholders), `HOSTNAME_FQDN`/`HOST_IP`/the `*_BIND_IP` variables are well-formed, password/key fields meet their minimum length (including SQL Server's own complexity rule for `MSSQL_SA_PASSWORD`), and identifier-style fields like `MYSQL_DATABASE`/`MYSQL_USER` are valid. Every problem found is reported together and the script exits without changing anything, so you can fix `.env` once instead of one error at a time.

## After Installation

1. Copy the generated `root_ca.crt` to every client and import it into the trusted Root CA store.
2. Configure DNS, or download `add-hosts-entries.ps1` (Windows) / `add-hosts-entries.sh` (Linux/macOS) and run it on each client to add all lab hostnames to its local hosts file in one step. You don't need any DNS/hosts entry to get these in the first place: browse to `http://<HOST_IP>` (plain HTTP, no certificate warning) and the Certificate Portal loads directly, with everything downloadable from there.
3. Sign in to Portainer at `https://portainer.<HOSTNAME_FQDN>` with user `admin` and `PORTAINER_ADMIN_PASSWORD` from `.env` (auto-provisioned; the manual setup-token wizard is skipped).
4. Sign in to phpLDAPadmin with `uid=webadmin,ou=Internal,ou=Users,dc=<HOSTNAME_FQDN>` and `LDAP_ADMIN_PASSWORD`.
5. Sign in to StepCA Web with `webadmin` and `LDAP_ADMIN_PASSWORD`.
6. Sign in to CloudBeaver at `https://cloudbeaver.<HOSTNAME_FQDN>` with `CLOUDBEAVER_ADMIN_USER` / `CLOUDBEAVER_ADMIN_PASSWORD` from `.env` (auto-provisioned; the manual first-run wizard is skipped), then add connections for PostgreSQL, MySQL, and SQL Server using the parameters in [docs/DATABASES.md](docs/DATABASES.md).
7. Connect FactoryTalk Optix or other MQTT clients to `mqtt.<HOSTNAME_FQDN>:8883` over TLS using `MQTT_USERNAME` / `MQTT_PASSWORD` and the imported root CA, or to `<HOST_IP>:1883` with no TLS and no credentials for quick anonymous testing (see [docs/MQTT.md](docs/MQTT.md)).
8. Download the Root CA, other public certificates, and the hosts-file scripts from `http://<HOST_IP>` (works immediately on a brand-new client, no DNS/hosts entry or certificate warning) or `https://certificates.<HOSTNAME_FQDN>` once that name resolves, if a client cannot reach the Docker host directly.

## Services Exposed Directly (v1.1)

| Service               | Port | Bind variable       |
|-----------------------|------|----------------------|
| PostgreSQL            | 5432 | `POSTGRES_BIND_IP`   |
| MySQL                 | 3306 | `MYSQL_BIND_IP`      |
| Microsoft SQL Server  | 1433 | `MSSQL_BIND_IP`      |
| Mosquitto MQTTS (TLS, authenticated) | 8883 | `MQTT_BIND_IP` |
| Mosquitto plain MQTT (no TLS, anonymous) | 1883 | `MQTT_BIND_IP` |
| OpenLDAP / LDAPS      | 389 / 636 | (unchanged from v1.0) |

Each `*_BIND_IP` variable defaults to `0.0.0.0`; set it to a specific VM interface address in `.env` to restrict exposure.

## Documentation

- [Installation](docs/INSTALLATION.md)
- [Root CA](docs/ROOT_CA.md)
- [LDAP](docs/LDAP.md)
- [Databases and CloudBeaver](docs/DATABASES.md)
- [MQTT and Mosquitto](docs/MQTT.md)
- [Certificate Download Portal](docs/CERTIFICATE_PORTAL.md)
- [Portainer](docs/PORTAINER.md)
- [Adding a Web Application](docs/ADDING_WEB_APP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Security](docs/SECURITY.md)
- [v1.1 Validation Checklist](docs/VALIDATION_CHECKLIST.md)

## Important JWK File

`jwk_key.json` is required by StepCA Web, but it is no longer a static file shipped in this repository. `install.sh` generates it automatically (via `prepare-jwk.sh`) by extracting and decrypting the private key material of step-ca's own JWK admin provisioner, using `STEPCA_PASSWORD` as the decryption password. This removes the need for a fixed, committed private key: every fresh install and every destructive rebuild produces its own `jwk_key.json`, tied to that installation's own CA.

The generated file still contains private JWK material. It is `chmod 600` by `prepare-jwk.sh`, listed in `.gitignore`, and must never be committed.
