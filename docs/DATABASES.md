# Databases and CloudBeaver

v1.1 adds MySQL and Microsoft SQL Server alongside the existing PostgreSQL instance, plus CloudBeaver as a single web UI for all three.

## Direct access

| Service    | Container    | Host port | Bind variable      | Default credentials source |
|------------|--------------|-----------|---------------------|------------------------------|
| PostgreSQL | `stepca-db`  | 5432      | `POSTGRES_BIND_IP`  | `POSTGRES_PASSWORD` (user `stepca`, database `stepca`) |
| MySQL      | `mysql-db`   | 3306      | `MYSQL_BIND_IP`     | `MYSQL_ROOT_PASSWORD`, `MYSQL_USER` / `MYSQL_PASSWORD`, `MYSQL_DATABASE` |
| SQL Server | `mssql-db`   | 1433      | `MSSQL_BIND_IP`     | `MSSQL_SA_PASSWORD` (user `sa`) |

All three variables default to `0.0.0.0` in `.env.example`. Set them to a specific VM interface address to avoid exposing the database on every interface.

PostgreSQL remains on the internal `pki` network for step-ca and is additionally attached to the `database` network for CloudBeaver.

## CloudBeaver

CloudBeaver is reachable at `https://cloudbeaver.<HOSTNAME_FQDN>` behind Caddy.

### Administrator account (auto-provisioned)

CloudBeaver's administrator account is created automatically on first start, and the manual "Configure Server" setup wizard never appears, using two mechanisms that work together but serve different purposes:

1. **Automatic server configuration** (the mechanism that actually creates the account and exits "configuration mode", skipping the wizard) — `docker-compose.yml` sets `CB_ADMIN_NAME` / `CB_ADMIN_PASSWORD` (plus `CB_SERVER_NAME` / `CB_SERVER_URL`) as container environment variables, fed from `CLOUDBEAVER_ADMIN_USER` / `CLOUDBEAVER_ADMIN_PASSWORD` in `.env`. CloudBeaver reads these as real OS environment variables, so `${...}` is not involved here at all.
2. **Initial data configuration** — `cloudbeaver/initial-data.conf` (bind-mounted read-only to `/opt/cloudbeaver/conf/initial-data.conf`, CloudBeaver's own default path for this file) pre-seeds an `Administrators` team (permission `admin`) and a `Users` team into CloudBeaver's internal database the first time it initializes. It does **not** create the admin account itself — that's mechanism 1's job — and its `teams` entries deliberately do **not** include `adminName`/`adminPassword`.

Two non-obvious pitfalls, found by reading CloudBeaver's own server source directly (`CBDatabase`, `CBEmbeddedSecurityController`) since no local Docker was available to test-run it in development:

- **`initial-data.conf` does not support `${ENV_VAR}` substitution.** Unlike `cloudbeaver.conf`, this file is parsed with a plain JSON reader — a literal `"${CLOUDBEAVER_ADMIN_USER}"` string here becomes the actual (broken) username, not the real value. This is why `adminName`/`adminPassword` are intentionally absent from this file; only mechanism 1 above can see real environment variable values.
- **Users and teams share one ID namespace.** CloudBeaver's own `isSubjectExists()` check treats user IDs and team IDs as the same kind of "subject", and both are lowercased on creation. The `Administrators` team here uses `subjectId: "administrators"`, not `"admin"` — using `"admin"` would collide with an admin *user* named `admin` (the default `CLOUDBEAVER_ADMIN_USER`), causing CloudBeaver to fail with `User or team 'admin' already exists` the moment mechanism 1 tries to create that user, aborting the whole auto-configuration and leaving the setup wizard stuck on screen forever. The `Users` team keeps `subjectId: "user"` deliberately, since that must match CloudBeaver's own `defaultUserTeam` default (`CLOUDBEAVER_APP_DEFAULT_USER_TEAM`, `user` by default) or CloudBeaver refuses to start.

Just sign in at `https://cloudbeaver.<HOSTNAME_FQDN>` with `CLOUDBEAVER_ADMIN_USER` / `CLOUDBEAVER_ADMIN_PASSWORD` from `.env`; there is no setup wizard to complete. The admin account still ends up with full `admin` permissions, granted through membership in the `administrators` team.

If, after an install, the credentials in `.env` don't work, CloudBeaver may have fallen back to its normal first-run wizard (for example, if `cloudbeaver_data` already contained a workspace from an older install, so CloudBeaver considers itself already initialized and ignores both mechanisms above). In that case, complete the wizard once with the same values so `.env` stays the source of truth, or remove the `cloudbeaver_data` volume for a full reset.

### Adding the three database connections

Full automatic connection provisioning (so PostgreSQL/MySQL/SQL Server would already appear in CloudBeaver with no manual step) is intentionally not implemented in this repository. CloudBeaver Community Edition does not document a reliable, version-stable file format for pre-seeding connections, and the alternative (driving its internal admin API blind, without a live instance to verify against) risks shipping automation that silently fails. Add the three connections manually once after logging in — it takes under a minute:

| Connection | Host       | Port | Driver      |
|------------|------------|------|-------------|
| PostgreSQL | `postgres` | 5432 | PostgreSQL  |
| MySQL      | `mysql`    | 3306 | MySQL       |
| SQL Server | `mssql`    | 1433 | Microsoft SQL Server |

Use the Compose service name as the host, not `localhost` or the bind IP, since CloudBeaver reaches these services over the private `database` network. Credentials are the same `MYSQL_USER`/`MYSQL_PASSWORD`, `MSSQL_SA_PASSWORD` (user `sa`), and `POSTGRES_PASSWORD` (user `stepca`, database `stepca`) values already in `.env`.

## Network model

```text
web       Caddy and web UIs
pki       step-ca and PostgreSQL dependency path
database  CloudBeaver plus database servers
```

`database` is a dedicated bridge network kept separate from `web`. Caddy never joins `database`, so it has no direct path to any database port; CloudBeaver is the only web-facing service with a leg on both `web` and `database`. The network is a normal (non-internal) bridge so that published host ports for PostgreSQL, MySQL, and SQL Server work reliably, the same way `step-ca` already publishes port 9000 while also belonging to the internal `pki` network.
