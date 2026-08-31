# Certificate Download Portal

The Certificate Download Portal is a minimal, read-only `nginx:1.27-alpine` container behind Caddy, reachable at `http://<HOST_IP>` (the recommended first stop on a brand-new client — see below) and, once hostnames resolve, at `https://certificates.<HOSTNAME_FQDN>`. It exists so clients that cannot reach the Docker host's filesystem (or an administrator's copy of `root_ca.crt`) can still retrieve the certificates they need to trust the lab's PKI, and it presents them through an Apple-style page that automatically follows the visiting browser's light/dark appearance setting (`prefers-color-scheme`).

The page is a two-column layout: the left column has the certificate/script downloads described below, and the right column, "Web Portals", links directly to every other web UI in the lab (StepCA Web, Portainer, Keycloak, InfluxDB UI, phpLDAPadmin, CloudBeaver, MQTTX Web, CSR Generator) built from `HOSTNAME_FQDN`, each opening in a new browser tab (`target="_blank"`) so this portal stays open as a jumping-off point.

## Why it stays on HTTPS (and the warning you'll see on first visit)

The portal is deliberately kept behind Caddy on HTTPS, like every other web UI in this lab, rather than served over plain HTTP. This has one unavoidable consequence: on a client that hasn't imported `root_ca.crt` yet, the browser will show a "connection is not private" warning the first time it visits `https://certificates.<HOSTNAME_FQDN>` — because the portal's own certificate is issued by the same private CA the client is there to bootstrap trust in. This is expected, not a misconfiguration.

Putting this portal on plain HTTP instead would remove that warning, but at a real cost: HTTP gives no protection against an on-path attacker (ARP/DNS spoofing, a compromised network device) silently swapping in a different root CA certificate during the download. Since importing a root CA is exactly the moment a client decides what to trust from then on, that integrity guarantee matters more than avoiding a one-time click-through warning — and it's consistent with this lab's own design rule that every browser-facing service, including this one, stays behind Caddy's local-CA-issued HTTPS.

### Verifying what you downloaded

Because of that warning, don't rely on the browser padlock alone the first time. Verify the certificate you downloaded against an out-of-band source:

1. `install.sh` prints the root CA's SHA-256 fingerprint directly in the administrator's own terminal at the end of installation ("Root CA fingerprint: ..."). This is trustworthy because it never travels over the network the client is bootstrapping trust on.
2. The same fingerprint is in `downloads/certificate-manifest.txt` on the portal itself.
3. Compare the two (have the administrator relay the terminal fingerprint over a separate channel — chat, email, verbally) before importing the certificate into a client's trust store.

Once `root_ca.crt` is imported once, every other `*.<HOSTNAME_FQDN>` site — including this portal on subsequent visits — loads with no warning at all.

## Bootstrapping without any DNS/hosts entry first

A brand-new client has no reason to know `certificates.<HOSTNAME_FQDN>` resolves anywhere — that hostname is exactly what the hosts-file scripts on this portal are meant to configure, so requiring it first would be circular. To break that loop, Caddy also serves the same portal directly on the VM's raw IP address, which every client can already reach with zero configuration:

- `http://<HOST_IP>` — plain HTTP, no certificate involved at all, so there's no security warning and no bootstrap problem. This is the recommended first stop on a brand-new client: open it, download `root_ca.crt` and the hosts-file script for your OS, verify the fingerprint (see above), then run the script.
- `https://<HOST_IP>` — served the same way as every other site, best-effort. It depends on step-ca's ACME provisioner accepting an IP address as a certificate identifier; if that doesn't succeed, it simply won't have a certificate to offer, while the plain-HTTP path above keeps working regardless.

Once you've imported `root_ca.crt` and added the hostnames to your hosts file, use the normal `https://certificates.<HOSTNAME_FQDN>` address from then on.

## What is published

`install.sh` stages the portal content under `certs-portal/public/` on every run:

```text
certs-portal/public/index.html
certs-portal/public/downloads/ca/root_ca.crt
certs-portal/public/downloads/ca/root_ca.der
certs-portal/public/downloads/ca/intermediate_ca.crt
certs-portal/public/downloads/ca/ca_chain.crt
certs-portal/public/downloads/mqtt/mqtt_server.crt
certs-portal/public/downloads/scripts/add-hosts-entries.ps1
certs-portal/public/downloads/scripts/add-hosts-entries.sh
certs-portal/public/downloads/certificate-manifest.txt
```

`certificate-manifest.txt` lists the SHA-256 fingerprint of each published certificate so a client can independently verify what it downloaded.

## Hosts-file helper scripts

`scripts/add-hosts-entries.ps1.template` and `scripts/add-hosts-entries.sh.template` (repository root) are rendered by `install.sh` the same way `Caddyfile.template` is: `${HOSTNAME_FQDN}` and `${HOST_IP}` are substituted with this installation's real values, so the downloaded scripts are ready to run as-is on a client machine, with no editing required.

- `add-hosts-entries.ps1` — run from an elevated PowerShell prompt on Windows.
- `add-hosts-entries.sh` — run with `sudo` on Linux or macOS.

Both scripts back up the existing hosts file before changing it, and are idempotent: before writing their managed block, they strip out any pre-existing line for these hostnames — whether from a previous run of the script itself or added manually (for example, while bootstrapping access to the portal before the script existed on that client) — so re-running them never leaves duplicate entries.

## What is never published

- `root_ca_key`, `intermediate_ca_key`, or any other step-ca private key material.
- `jwk_key.json`.
- `mosquitto/certs/server.key` (the Mosquitto private key).
- Database or MQTT credentials, or any other `.env` secret.
- The complete `step` Docker volume or `/home/step/secrets`.

The `cert-portal` container only bind-mounts `certs-portal/public/` (read-only) and `certs-portal/nginx.conf`. It never mounts the `step` volume, `ldap/`, `mosquitto/certs/`, or `mosquitto/secrets/`.

## Regenerating portal content

The portal content is regenerated on every `./install.sh` run. To refresh it without a full reinstall, re-run the relevant portion manually or simply re-run `./install.sh`, which is idempotent for this step.

## Future work

If mutual TLS client credentials are added in a later version, protect the private portal area separately and package private keys only in password-protected PKCS#12 files — never as plain `.key` files reachable from this portal.
