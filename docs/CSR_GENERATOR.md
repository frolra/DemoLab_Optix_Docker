# CSR Generator

A self-service certificate portal at `https://csr.<HOSTNAME_FQDN>`, restricted to members of this lab's LDAP admin group (`cn=ldap-admins,ou=Groups,dc=<HOSTNAME_FQDN>` - the same group `webadmin` belongs to), that builds a PKCS#10 Certificate Signing Request and a matching private key from a form, signs it **directly and automatically** through this lab's own step-ca, and offers the signed certificate in several formats.

## What it does, and does not, do

- **Requires an LDAP admin login.** The portal binds to OpenLDAP as the submitted username/password and additionally checks that the account is a member of the required admin group before showing anything - see [docs/SECURITY.md](SECURITY.md) for why this changed from the original, anonymous version of this tool.
- **Generates** a private key and CSR from the fields you fill in (Common Name, Organization, Subject Alternative Names, key type, etc.), entirely in memory.
- **Signs the CSR immediately** through step-ca's admin JWK provisioner (the same provisioner `jwk_key.json`/StepCA Web use), decrypting its key with `STEPCA_PASSWORD` (held internally by the container - the LDAP admin-group login is the only authorization check; you are not separately prompted for the CA provisioner passphrase). No copy-pasting into another tool is needed any more.
- **Does not persist anything.** No database, no volume for generated material, nothing written to disk. Every key, CSR, and signed certificate exists only for the lifetime of a single HTTP request/response. Refreshing the page or navigating away loses it permanently - save it before you do. Only the LDAP session cookie (your username, signed with `CSR_GENERATOR_SECRET_KEY`) survives between requests.

## End-to-end workflow

1. Open `https://csr.<HOSTNAME_FQDN>` and sign in with your LDAP admin account (`webadmin` / `LDAP_ADMIN_PASSWORD`, or any other account in the `ldap-admins` group).
2. Fill in the Subject fields (only Common Name is required) and any Subject Alternative Names (DNS names and/or IP addresses) the certificate needs to match.
3. Choose a key type (RSA 2048/4096 or ECDSA P-256/P-384) and, optionally, a passphrase. If set, this passphrase both encrypts the downloaded private key **and** protects the downloaded `.pfx` bundle - the same value is reused for both.
4. Click **Generate CSR & Key**. The CSR and key are built, then the CSR is immediately submitted to step-ca and signed.
5. The result page shows the signed certificate, the CSR, and the private key (blurred until you click **Show**), with download buttons for each:
   - **Signed Certificate:** `.pem` (text), `.der` (binary - required by tools that reject a merely-renamed `.pem`, such as FactoryTalk Optix's `PKI/Own/Certs`; see [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md)), and `.pfx` (a PKCS#12 bundle containing the certificate, its private key, and the issuing intermediate certificate in one password-protectable file - the format most Windows and industrial-automation tools expect when they need the certificate and its key together).
   - **CSR:** `.csr`, kept for reference/audit even though it's already been signed.
   - **Private Key:** `.key` / `.pem` (identical content, different extension).
6. **Save everything now** - none of it is stored server-side and none of it can be recovered once you leave the page.
7. If automatic signing fails for any reason (the CA is unreachable, `STEPCA_PASSWORD` no longer matches, a policy rejects the request, etc.), the CSR and private key are still shown along with the CA's own error message - nothing is lost, only the signed-certificate section is missing.

## Implementation notes

- Built with Flask, `cryptography` (CSR/key/DER/PKCS#12 construction), `ldap3` (LDAP bind + group check), `jwcrypto` (decrypting the provisioner's encrypted JWK), and `PyJWT` (the ES256 signing token sent to step-ca) - see `csr-generator/requirements.txt`.
- The CSR itself is still constructed programmatically (subject name and SAN objects), never by shelling out to `openssl` with user-supplied strings, so there is no command-injection surface regardless of what a user types into the form.
- Runs on the `web` network only (it reaches both `step-ca` and `openldap` there, since both containers are also attached to `web`); it has no route to `pki` or `database` as internal-only networks, but does make outbound HTTPS/LDAPS calls to `step-ca`/`openldap` over `web`.
- Reuses `settings.json`'s `ca.*`/`ldap.*` fields (mounted read-only, the same file StepCA Web already uses) for CA/LDAP connection details, and `root_ca.crt` (mounted read-only) to verify both step-ca's HTTPS endpoint and OpenLDAP's LDAPS endpoint. `STEPCA_PASSWORD` and `CSR_GENERATOR_SECRET_KEY` (a new required `.env` variable, at least 32 characters, validated by `install.sh` the same way `STEPCA_WEB_SECRET_KEY` is) come from the environment.
- Every response containing key material is sent with `Cache-Control: no-store`.
- See [docs/ADDING_WEB_APP.md](ADDING_WEB_APP.md) for the general pattern this service follows (its own `Dockerfile`, a `web`-network service, an entry in Caddy's aliases, and a site block in `Caddyfile.template`).
