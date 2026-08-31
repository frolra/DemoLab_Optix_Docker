# Adding a Web Application Behind Caddy

The backend must share the `web` network with Caddy. It does not need the `pki` network unless it must communicate directly with a PKI-side service. It does not need the `database` network unless it must connect directly to PostgreSQL, MySQL, or SQL Server (CloudBeaver is the intended path for interactive database access; Caddy itself never joins `database`).

## Adding a Service to an Already-Running Deployment

`./install.sh` is safe to re-run against a deployment it already fully installed — this is the normal way to add a new service (like the CSR Generator, or your own `myapp`) without touching anything that already works. On a re-run it:

- **Skips** re-adding the ACME provisioner, re-running the LDAP bootstrap, and regenerating credentials that already exist — every one of those steps checks first and does nothing if there's nothing to do.
- **Does** regenerate `Caddyfile` from `Caddyfile.template` (picking up any new site block you added), re-stage the Certificate Portal (picking up any new "Web Portals" grid entry), and run `docker compose up -d --build`, which builds/starts any new service you added to `docker-compose.yml` and recreates any existing container whose configuration changed (for example, Caddy itself, if you added a new network alias) — while leaving every other already-running container untouched.

So the workflow for adding a new service to a deployment that's already up and serving real traffic is exactly the same as a fresh install:

1. Add the new service to `docker-compose.yml` (own `networks: [web]`, `expose`, and — if it's built from source like `stepca-web` — its own `Dockerfile`), and its hostname to Caddy's `networks.web.aliases` list.
2. Add the matching site block to `Caddyfile.template` (see below).
3. Re-run `./install.sh`.

If you ever hit `ERROR: .env failed pre-flight validation`, that's the *new* `.env` requirements (if the service you're adding needs one) rejecting a value you haven't set yet — not a sign that re-running is unsafe.

## In the Main Compose File

```yaml
services:
  myapp:
    image: nginx:alpine
    restart: unless-stopped
    networks: [web]
    expose: ["80"]
```

Add `myapp.${HOSTNAME_FQDN}` to the Caddy aliases in `docker-compose.yml`, then add this to `Caddyfile.template`:

```caddy
myapp.${HOSTNAME_FQDN} {
    import stepca
    reverse_proxy myapp:80
}
```

Add DNS or a hosts-file entry that points the hostname to the Docker host, then run:

```bash
./install.sh
```

The installer regenerates `Caddyfile` from the template and brings up the new container — see "Adding a Service to an Already-Running Deployment" above for exactly what does and doesn't happen on a re-run.

## In a Separate Compose Project

Find the actual web network name:

```bash
docker network ls | grep _web
```

It is normally `stepca_web`. Use it as an external network:

```yaml
services:
  myapp:
    image: nginx:alpine
    restart: unless-stopped
    networks: [stepca-web]
    expose: ["80"]

networks:
  stepca-web:
    external: true
    name: stepca_web
```

The main repository still needs the public hostname in the Caddy aliases and the site block in `Caddyfile.template`.

## HTTPS Backend

```caddy
myapp.${HOSTNAME_FQDN} {
    import stepca
    reverse_proxy https://myapp:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

Use `tls_insecure_skip_verify` only in a controlled lab.
