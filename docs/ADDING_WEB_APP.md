# Adding a Web Application Behind Caddy

The backend must share the `web` network with Caddy. It does not need the `pki` network unless it must communicate directly with a PKI-side service. It does not need the `database` network unless it must connect directly to PostgreSQL, MySQL, or SQL Server (CloudBeaver is the intended path for interactive database access; Caddy itself never joins `database`).

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

The installer regenerates `Caddyfile` from the template.

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
