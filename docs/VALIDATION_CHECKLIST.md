# v1.1 Validation Checklist

Run this checklist before handing off a build for testing, and again after a destructive rebuild.

## Static validation

```bash
bash -n install.sh prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh
docker compose config -q
```

Validate `.env.example`, `settings.json`, `realm.json`, and any generated JSON with a JSON parser. Confirm `Caddyfile.template` contains no unresolved `${...}` variables other than `${HOSTNAME_FQDN}` and `${HOST_IP}`, and no HTML anchor markup.

## Fresh install

```bash
cp .env.example .env
nano .env
dos2unix install.sh prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh
chmod +x install.sh prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh
./install.sh
docker compose ps
```

Confirm every service reports `running`/`healthy` as applicable.

## Functional checks

- [ ] Deliberately break `.env` (an empty required variable, a leftover `CHANGE_ME`, an out-of-range `HOST_IP` octet, a too-short `PORTAINER_ADMIN_PASSWORD`/`STEPCA_WEB_SECRET_KEY`, a weak `MSSQL_SA_PASSWORD`) and confirm `./install.sh` reports every problem at once under `ERROR: .env failed pre-flight validation` and exits before creating any files or containers; fix `.env` and confirm the rest of this checklist still passes
- [ ] step-ca health: `docker exec step-ca step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt`
- [ ] `jwk_key.json` was generated (not present before install), is `chmod 600`, contains `kty`/`kid`/`crv`/`x`/`y`/`d`, and `settings.json`'s `admin_provisioner_name` matches the provisioner name printed by `prepare-jwk.sh`
- [ ] StepCA Web can issue a certificate through the admin JWK provisioner (exercise the certificate issuance page/API)
- [ ] PostgreSQL tables: `docker exec stepca-db psql -U stepca -d stepca -c '\dt'`
- [ ] LDAP `webadmin` bind (see `docs/LDAP.md`)
- [ ] Caddy logs are free of certificate errors: `docker compose logs --tail=100 caddy`
- [ ] Portainer reachable at `https://portainer.<HOSTNAME_FQDN>`; sign in with user `admin` and `PORTAINER_ADMIN_PASSWORD` from `.env` (no setup-token wizard should appear); the local Docker environment is already selected
- [ ] CloudBeaver reachable at `https://cloudbeaver.<HOSTNAME_FQDN>`; sign in with `CLOUDBEAVER_ADMIN_USER` / `CLOUDBEAVER_ADMIN_PASSWORD` from `.env` (no first-run wizard should appear); add connections for PostgreSQL, MySQL, and SQL Server and confirm each connects
- [ ] Certificate Portal renders with the Apple-style light theme and automatically switches to dark when the OS/browser is set to dark mode (`prefers-color-scheme`)
- [ ] Certificate Portal serves `scripts/add-hosts-entries.ps1` and `scripts/add-hosts-entries.sh` with the correct `HOSTNAME_FQDN`/`HOST_IP` already filled in (no `${...}` placeholders remaining)
- [ ] `add-hosts-entries.ps1` (elevated PowerShell) and `add-hosts-entries.sh` (sudo) each add all lab hostnames to the client's hosts file, back up the original file first, and are idempotent on a second run
- [ ] On a client with no pre-existing DNS/hosts entry for this lab, `http://<HOST_IP>` loads the Certificate Portal directly (no warning, no certificate involved) and lets you download `root_ca.crt` and both hosts-file scripts
- [ ] Running a hosts-file script against a hosts file that already has manually-added, non-marker-block entries for these hostnames does not leave duplicates — the pre-existing lines are replaced, not added to
- [ ] PostgreSQL reachable directly on `POSTGRES_BIND_IP:5432` from an external client
- [ ] MySQL reachable directly on `MYSQL_BIND_IP:3306` from an external client
- [ ] SQL Server reachable directly on `MSSQL_BIND_IP:1433` from an external client
- [ ] Mosquitto container reports `healthy`, not restarting, and `docker compose logs mosquitto` shows no `Unable to open pwfile` or config parse errors (only the harmless `chown: ... Read-only file system` lines are expected)
- [ ] `mosquitto/certs/server.key` and `mosquitto/secrets/mosquitto.passwd` are group-owned by `mosquitto` (GID 1883) and mode `640`; `mosquitto/certs/server.crt`/`ca.crt` are mode `644`
- [ ] Mosquitto MQTTS publish/subscribe over `MQTT_BIND_IP:8883` using `MQTT_USERNAME` / `MQTT_PASSWORD` and the imported root CA
- [ ] Mosquitto plain MQTT publish/subscribe over `MQTT_BIND_IP:1883` with no TLS and no credentials (anonymous), and confirm a connection with the *wrong* credentials on 8883 is still rejected (per-listener auth didn't leak into the anonymous listener or vice versa)
- [ ] MQTTX Web at `https://mqtt.<HOSTNAME_FQDN>` connects over WSS via `mqttws.<HOSTNAME_FQDN>`
- [ ] Certificate Portal at `http://<HOST_IP>` (first-boot path) or `https://certificates.<HOSTNAME_FQDN>` (once hostnames resolve) serves `root_ca.crt`, `root_ca.der`, `intermediate_ca.crt`, `ca_chain.crt`, `mqtt_server.crt`, and `certificate-manifest.txt`, plus the "Web Portals" links to every other UI
- [ ] Web Portal links on the Certificate Portal each open their target in a new tab and load correctly (once `root_ca.crt` is imported)
- [ ] CSR Generator at `https://csr.<HOSTNAME_FQDN>` requires no login; generating a CSR produces a signature-valid CSR (verify with `step certificate inspect` or `openssl req -verify -noout` if available) whose Subject/SANs match the form input, and a matching, parseable private key; the `/generate` response has `Cache-Control: no-store`
- [ ] The CSR produced by the CSR Generator can be pasted into StepCA Web's **X.509 → Active Certificates → Submit CSR** form (JWK provisioner + `STEPCA_PASSWORD`) and signed successfully, and the resulting certificate downloads correctly
- [ ] No CA or service private key (`root_ca_key`, `intermediate_ca_key`, `jwk_key.json`, `mosquitto/certs/server.key`) is reachable from the Certificate Portal
- [ ] `jwk_key.json` is absent from `git status`/`git ls-files` (generated and gitignored, never committed)
- [ ] No database, MQTT, JWK, or private-key secret appears in `install.sh` output

## Destructive rebuild

```bash
docker compose down -v --remove-orphans
rm -rf ldap/certs ldap/secrets mosquitto/certs mosquitto/secrets certs-portal/public
rm -f Caddyfile root_ca.crt jwk_key.json ca.generated.json ca.generated.updated.json .stepca-password
./install.sh
```

Repeat the functional checks above. A destructive rebuild generates a new Root CA, a new `jwk_key.json` tied to the new CA's own JWK provisioner, and resets Portainer, CloudBeaver, MySQL, SQL Server, and PostgreSQL data if their named volumes were removed with `-v`.
