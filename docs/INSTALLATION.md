# Installation

Configure `.env` from `.env.example`, then run `./install.sh`. The installer generates the environment-specific `Caddyfile`, initializes step-ca, configures PostgreSQL and ACME, generates `jwk_key.json` from the CA's own JWK provisioner, generates the LDAP certificate, creates `webadmin`, issues the Mosquitto MQTT certificate and credentials, stages the certificate download portal, builds StepCA Web, and starts all services.

## Complete Rebuild

```bash
docker compose down -v --remove-orphans
rm -rf ldap/certs ldap/secrets mosquitto/certs mosquitto/secrets certs-portal/public
rm -f Caddyfile root_ca.crt jwk_key.json ca.generated.json ca.generated.updated.json .stepca-password
./install.sh
```

A complete rebuild creates a new Root CA, a new `jwk_key.json` (tied to the new CA's own JWK provisioner), and resets Portainer, MySQL, SQL Server, PostgreSQL, CloudBeaver, and Mosquitto data volumes if you also remove their named volumes. Copy and import the new CA; Portainer's and CloudBeaver's administrator accounts are both auto-provisioned again from `.env`, no wizard to repeat for either.

## Updating an Existing Deployment

`./install.sh` is safe to re-run against a deployment it already installed — you don't need a complete rebuild just to pick up a new service or a config change. It detects what's already done (an existing ACME provisioner, an existing `webadmin` LDAP entry, etc.) and skips those steps, while still regenerating `Caddyfile`, re-staging the Certificate Portal, and running `docker compose up -d --build` to build/start anything new and recreate any container whose configuration changed. See [Adding a Web Application](ADDING_WEB_APP.md#adding-a-service-to-an-already-running-deployment) for the exact workflow this enables (for example, this is how the CSR Generator itself would be added to a deployment that installed an earlier version of this repository).

## v1.1 Additions

`install.sh` now performs several additional steps beyond the v1.0 flow:

- `[4/12]` calls `prepare-jwk.sh`, which discovers the JWK admin provisioner created by step-ca's own initialization, decrypts its private key using `STEPCA_PASSWORD`, and writes it to `jwk_key.json`. `jwk_key.json` is no longer a static file committed to the repository; it is regenerated on every install and is tied to that installation's own CA. The exact provisioner name discovered here is also written into `settings.json`'s `admin_provisioner_name`, so StepCA Web always signs its JWTs with the correct `iss` for the key it was given.
- `[9/12]` calls `prepare-mqtt.sh`, which issues the Mosquitto server certificate directly from step-ca (the same pattern used for the LDAP certificate) and creates the Mosquitto password file from `MQTT_USERNAME` / `MQTT_PASSWORD`.
- `[10/12]` stages the Certificate Download Portal under `certs-portal/public/`: public certificates (`root_ca.crt`, `root_ca.der`, `intermediate_ca.crt`, `ca_chain.crt`, `mqtt_server.crt`), a fingerprint manifest, and the two hosts-file helper scripts rendered from `scripts/*.template` with this installation's real `HOSTNAME_FQDN`/`HOST_IP`. No private keys, no `jwk_key.json`, and no step-ca secrets are ever staged there.

MySQL, SQL Server, and CloudBeaver do not require a bootstrap step; Docker Compose brings them up directly using the credentials from `.env`. CloudBeaver's administrator account is auto-provisioned from `CLOUDBEAVER_ADMIN_USER` / `CLOUDBEAVER_ADMIN_PASSWORD` via its `CB_ADMIN_NAME`/`CB_ADMIN_PASSWORD` automatic server configuration plus `cloudbeaver/initial-data.conf` — see [docs/DATABASES.md](DATABASES.md).

The CSR Generator (`csr-generator`) also needs no bootstrap step and no secret of its own: Docker Compose builds it from `./csr-generator` like `stepca-web`, but unlike `stepca-web` it needs no LDAP/database credentials, no JWK key, and no `.env` variable beyond `HOSTNAME_FQDN` — see [docs/CSR_GENERATOR.md](CSR_GENERATOR.md).
