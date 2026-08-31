# CSR Generator

A small, standalone web tool at `https://csr.<HOSTNAME_FQDN>` that builds a PKCS#10 Certificate Signing Request (CSR) and a matching private key from a form, so you don't need `openssl` or `step` installed locally to produce a well-formed CSR.

## What it does, and does not, do

- **Generates** a private key and CSR from the fields you fill in (Common Name, Organization, Subject Alternative Names, key type, etc.), entirely in memory.
- **Does not** talk to step-ca, does not know any CA secret, and cannot issue or sign a certificate by itself. Signing still happens exclusively through StepCA Web (see [docs/DATABASES.md](DATABASES.md)-style admin flow below), which requires an authenticated LDAP admin session and the CA's own JWK provisioner password.
- **Does not** require a login and applies no restriction on the Common Name or Subject Alternative Names you request — anyone who can reach the portal can generate a CSR/key pair for any name. This is deliberate and, unlike a signing service, has no real-world consequence by itself: a CSR and its private key are inert until an authenticated admin chooses to sign that CSR in StepCA Web. See [docs/SECURITY.md](SECURITY.md) for the full reasoning.
- **Does not persist anything.** No database, no volume, nothing written to disk. Every key and CSR exists only for the lifetime of a single HTTP request/response. Refreshing the page or navigating away loses it permanently — save it before you do.

## End-to-end workflow

1. Open `https://csr.<HOSTNAME_FQDN>` and fill in the Subject fields (only Common Name is required) and any Subject Alternative Names (DNS names and/or IP addresses) the certificate needs to match.
2. Choose a key type (RSA 2048/4096 or ECDSA P-256/P-384) and, optionally, a passphrase to encrypt the downloaded private key.
3. Click **Generate CSR & Key**. The result page shows the CSR in a copyable text box and the private key (blurred until you click **Show**), plus download buttons for both. The private key offers both **Download .key** and **Download .pem** — identical content, different filename extension, since some tools expect one or the other.
4. **Save the private key now** — it is never stored server-side and cannot be recovered once you leave the page.
5. Sign in to StepCA Web (`https://stepca.<HOSTNAME_FQDN>`, `webadmin` / `LDAP_ADMIN_PASSWORD`) and open **X.509 → Active Certificates → Submit CSR**.
6. Paste the CSR, pick the JWK provisioner (its name is in `settings.json`'s `ca.admin_provisioner_name`), enter `STEPCA_PASSWORD` as the provisioner passphrase, and submit.
7. Download the signed certificate from the Active Certificates list, and pair it with the private key you saved in step 4.

## Implementation notes

- Built with Flask and the `cryptography` library — the CSR is constructed programmatically (subject name and SAN objects), never by shelling out to `openssl` with user-supplied strings, so there is no command-injection surface regardless of what a user types into the form.
- Runs on the `web` network only; it has no route to `pki` or `database`, and needs no secret of any kind (no `.env` variable, no mounted credential file).
- Every response containing key material is sent with `Cache-Control: no-store`.
- See [docs/ADDING_WEB_APP.md](ADDING_WEB_APP.md) for the general pattern this service follows (its own `Dockerfile`, a `web`-only network, an entry in Caddy's aliases, and a site block in `Caddyfile.template`).
