#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "ERROR: .env not found"; exit 1; }
set -a
source ./.env
set +a

# --- .env pre-flight validation --------------------------------------------
# Runs entirely before any side effect (no files written, no containers
# started). Every problem is collected and reported together, then the
# script exits with nothing changed, so a single run tells you everything
# that needs fixing in .env instead of one error at a time.
declare -a ENV_ERRORS=()

env_require_set() {
  local name="$1" val="${!1:-}"
  if [[ -z "$val" || "$val" == CHANGE_ME* ]]; then
    ENV_ERRORS+=("$name is not set (or still has a CHANGE_ME placeholder)")
    return 1
  fi
}

env_require_min_length() {
  local name="$1" min="$2" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  (( ${#val} >= min )) || ENV_ERRORS+=("$name must be at least $min characters (currently ${#val})")
}

env_require_ipv4() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  if [[ ! "$val" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    ENV_ERRORS+=("$name must be a valid IPv4 address (got: $val)")
    return
  fi
  local octet
  for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
    (( octet <= 255 )) || { ENV_ERRORS+=("$name must be a valid IPv4 address (octet $octet out of range)"); return; }
  done
}

env_require_hostname() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  local label label_re='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' ok=1
  local -a labels
  IFS='.' read -ra labels <<<"$val"
  for label in "${labels[@]}"; do
    [[ "$label" =~ $label_re ]] || ok=0
  done
  (( ok == 1 )) || ENV_ERRORS+=("$name must be a valid hostname: letters/digits/hyphens, dot-separated labels (got: $val)")
}

env_require_identifier() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  [[ "$val" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ENV_ERRORS+=("$name must start with a letter/underscore and contain only letters, digits, underscores (got: $val)")
}

env_require_no_whitespace() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  [[ "$val" != *[[:space:]]* ]] || ENV_ERRORS+=("$name must not contain whitespace")
}

env_require_url() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || return 0
  [[ "$val" =~ ^(https?://|git@|ssh://) ]] || ENV_ERRORS+=("$name must look like a git URL (https://, ssh://, or git@...) (got: $val)")
}

# SQL Server enforces this itself and simply refuses to start otherwise, so
# check it up front rather than after the stack is already deployed.
env_require_mssql_complexity() {
  local val="${MSSQL_SA_PASSWORD:-}" classes=0
  [[ -n "$val" ]] || return 0
  # classes=$((classes+1)) (an assignment) always exits 0, unlike ((classes++))
  # which exits 1 (and would trip "set -e") the first time classes is still 0.
  [[ "$val" =~ [a-z] ]] && classes=$((classes + 1))
  [[ "$val" =~ [A-Z] ]] && classes=$((classes + 1))
  [[ "$val" =~ [0-9] ]] && classes=$((classes + 1))
  [[ "$val" =~ [^a-zA-Z0-9] ]] && classes=$((classes + 1))
  if (( ${#val} < 8 || classes < 3 )); then
    ENV_ERRORS+=("MSSQL_SA_PASSWORD must be at least 8 characters and include at least 3 of: lowercase, uppercase, digit, symbol (SQL Server's own requirement)")
  fi
}

required=(HOSTNAME_FQDN HOST_IP CA_NAME STEPCA_PASSWORD POSTGRES_PASSWORD LDAP_ADMIN_PASSWORD
  LDAP_INIT_ORG_NAME KEYCLOAK_ADMIN_PASSWORD INFLUXDB_ADMIN_PASSWORD INFLUXDB_ORG
  STEPCA_WEB_SECRET_KEY PHPLDAPADMIN_APP_KEY STEPCA_WEB_REPOSITORY MYSQL_ROOT_PASSWORD
  MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MSSQL_SA_PASSWORD MQTT_USERNAME MQTT_PASSWORD
  CLOUDBEAVER_ADMIN_USER CLOUDBEAVER_ADMIN_PASSWORD PORTAINER_ADMIN_PASSWORD)
for var in "${required[@]}"; do
  env_require_set "$var" || true
done

env_require_hostname HOSTNAME_FQDN
env_require_ipv4 HOST_IP
env_require_min_length STEPCA_PASSWORD 8
env_require_min_length POSTGRES_PASSWORD 8
env_require_min_length LDAP_ADMIN_PASSWORD 8
env_require_min_length KEYCLOAK_ADMIN_PASSWORD 8
env_require_min_length INFLUXDB_ADMIN_PASSWORD 8
env_require_min_length STEPCA_WEB_SECRET_KEY 32
env_require_min_length PHPLDAPADMIN_APP_KEY 32
env_require_url STEPCA_WEB_REPOSITORY
env_require_min_length MYSQL_ROOT_PASSWORD 8
env_require_identifier MYSQL_DATABASE
env_require_identifier MYSQL_USER
env_require_min_length MYSQL_PASSWORD 8
env_require_mssql_complexity
env_require_no_whitespace MQTT_USERNAME
env_require_min_length MQTT_PASSWORD 8
env_require_no_whitespace CLOUDBEAVER_ADMIN_USER
env_require_min_length CLOUDBEAVER_ADMIN_PASSWORD 8
# Portainer rejects a shorter admin password at startup and silently leaves
# the instance uninitialized (falling back to the manual setup wizard).
env_require_min_length PORTAINER_ADMIN_PASSWORD 12
for var in POSTGRES_BIND_IP MYSQL_BIND_IP MSSQL_BIND_IP MQTT_BIND_IP; do
  env_require_ipv4 "$var"
done

if (( ${#ENV_ERRORS[@]} > 0 )); then
  echo "ERROR: .env failed pre-flight validation (nothing was changed):" >&2
  for e in "${ENV_ERRORS[@]}"; do echo "  - $e" >&2; done
  exit 1
fi
# --- end .env pre-flight validation -----------------------------------------

command -v docker >/dev/null || { echo "ERROR: Docker not found"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: Python 3 not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found"; exit 1; }
docker compose version >/dev/null

for file in Caddyfile.template settings.json realm.json prepare-ldap.sh prepare-jwk.sh prepare-mqtt.sh mosquitto/config/mosquitto.conf certs-portal/nginx.conf scripts/add-hosts-entries.ps1.template scripts/add-hosts-entries.sh.template; do
  [[ -f "$file" ]] || { echo "ERROR: required file $file is missing or is not a regular file"; exit 1; }
done

python3 <<'PY_CADDY'
import os
from pathlib import Path
src = Path("Caddyfile.template").read_text(encoding="utf-8")
for name in ("HOSTNAME_FQDN", "HOST_IP"):
    src = src.replace("${" + name + "}", os.environ[name])
if "${" in src:
    raise SystemExit("ERROR: unresolved variable in Caddyfile.template")
Path("Caddyfile").write_text(src, encoding="utf-8")
PY_CADDY

mkdir -p ldap/certs ldap/secrets mosquitto/certs mosquitto/secrets certs-portal/public portainer/secrets
: > ldap/certs/ldap.crt
: > ldap/certs/ldap.key
: > root_ca.crt
chmod 600 .env ldap/certs/ldap.key

printf '%s' "$LDAP_ADMIN_PASSWORD" > ldap/secrets/ldap-admin-password
chmod 600 ldap/secrets/ldap-admin-password

printf '%s' "$PORTAINER_ADMIN_PASSWORD" > portainer/secrets/admin_password
chmod 600 portainer/secrets/admin_password

echo "[1/12] Starting PostgreSQL and initializing step-ca..."
docker compose up -d postgres step-ca
until docker exec step-ca test -s /home/step/config/ca.json 2>/dev/null; do sleep 2; done

echo "[2/12] Adding ACME offline and configuring PostgreSQL..."
docker compose stop step-ca

docker run --rm --volumes-from step-ca smallstep/step-cli:latest \
  step ca provisioner add acme \
  --type ACME \
  --x509-max-dur=8760h \
  --x509-default-dur=2160h \
  --ca-config /home/step/config/ca.json

docker cp step-ca:/home/step/config/ca.json ./ca.generated.json
python3 <<'PY'
import json, os
from pathlib import Path
src=Path('ca.generated.json')
dst=Path('ca.generated.updated.json')
config=json.loads(src.read_text(encoding='utf-8'))
pw=os.environ['POSTGRES_PASSWORD']
config['db']={'type':'postgresql','dataSource':f'postgresql://stepca:{pw}@postgres:5432/stepca?sslmode=disable'}
claims=config.setdefault('authority',{}).setdefault('claims',{})
claims.update({'minTLSCertDuration':'5m','maxTLSCertDuration':'8760h','defaultTLSCertDuration':'2160h'})
dst.write_text(json.dumps(config,indent=2)+'\n',encoding='utf-8')
PY

docker cp ./ca.generated.updated.json step-ca:/home/step/config/ca.json
rm -f ca.generated.json ca.generated.updated.json

echo "[3/12] Starting step-ca with PostgreSQL..."
docker compose start step-ca
until docker exec step-ca step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1; do sleep 2; done

echo "[4/12] Generating jwk_key.json from the CA's own JWK provisioner..."
./prepare-jwk.sh
JWK_PROVISIONER=$(cat .jwk-provisioner-name)
rm -f .jwk-provisioner-name

echo "[5/12] Exporting root CA and updating settings.json..."
docker cp step-ca:/home/step/certs/root_ca.crt ./root_ca.crt
chmod 644 root_ca.crt
FINGERPRINT=$(docker run --rm -v "$PWD:/work:ro" smallstep/step-cli:latest step certificate fingerprint /work/root_ca.crt)
python3 - "$FINGERPRINT" "$JWK_PROVISIONER" <<'PY'
import json, os, sys
from pathlib import Path
p=Path('settings.json')
d=json.loads(p.read_text(encoding='utf-8'))
h=os.environ['HOSTNAME_FQDN']
d['database'].update({'host':'postgres','port':'5432','user':'stepca','password':os.environ['POSTGRES_PASSWORD'],'name':'stepca'})
d['ca'].update({'url':'https://step-ca:9000','fingerprint':sys.argv[1],'admin_provisioner_name':sys.argv[2]})
d['ldap'].update({'url':'ldaps://openldap:636','base_dn':f'dc={h}','domain':h,'user_search_base':f'dc={h}','ldap_required_group_dn':f'cn=ldap-admins,ou=Groups,dc={h}'})
p.write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8')
PY

echo "[6/12] Creating the LDAP certificate..."
./prepare-ldap.sh

echo "[7/12] Starting OpenLDAP..."
docker compose up -d openldap
until [[ "$(docker inspect -f '{{.State.Health.Status}}' openldap 2>/dev/null || true)" == healthy ]]; do sleep 3; done

echo "[8/12] Synchronizing RootDN and creating webadmin..."
ROOT_HASH=$(docker exec openldap slappasswd -s "$LDAP_ADMIN_PASSWORD")
WEBADMIN_HASH=$(docker exec openldap slappasswd -s "$LDAP_ADMIN_PASSWORD")

cat > /tmp/ldap-bootstrap.ldif <<EOF_LDIF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${ROOT_HASH}
EOF_LDIF

docker cp /tmp/ldap-bootstrap.ldif openldap:/tmp/ldap-bootstrap.ldif
docker exec openldap ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/ldap-bootstrap.ldif

cat > /tmp/webadmin-add.ldif <<EOF_LDIF
dn: uid=webadmin,ou=Internal,ou=Users,dc=${HOSTNAME_FQDN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: webadmin
cn: Web Administrator
sn: Administrator
givenName: Web
mail: webadmin@${HOSTNAME_FQDN}
description: Web administration account
userPassword: ${WEBADMIN_HASH}
pwdReset: FALSE
EOF_LDIF

docker cp /tmp/webadmin-add.ldif openldap:/tmp/webadmin-add.ldif
if ! docker exec openldap sh -c 'LDAPTLS_CACERT=/run/secrets/ldap/ca.crt ldapsearch -x -H ldaps://localhost:636 -D "uid=admin,dc='"${HOSTNAME_FQDN}"'" -y /run/secrets/ldap-admin-password -b "uid=webadmin,ou=Internal,ou=Users,dc='"${HOSTNAME_FQDN}"'" -s base dn >/dev/null 2>&1'; then
  docker exec openldap sh -c 'LDAPTLS_CACERT=/run/secrets/ldap/ca.crt ldapadd -x -H ldaps://localhost:636 -D "uid=admin,dc='"${HOSTNAME_FQDN}"'" -y /run/secrets/ldap-admin-password -f /tmp/webadmin-add.ldif'
fi

cat > /tmp/webadmin-group.ldif <<EOF_LDIF
dn: cn=ldap-admins,ou=Groups,dc=${HOSTNAME_FQDN}
changetype: modify
add: uniqueMember
uniqueMember: uid=webadmin,ou=Internal,ou=Users,dc=${HOSTNAME_FQDN}
EOF_LDIF

docker cp /tmp/webadmin-group.ldif openldap:/tmp/webadmin-group.ldif
if ! docker exec openldap sh -c 'LDAPTLS_CACERT=/run/secrets/ldap/ca.crt ldapsearch -x -H ldaps://localhost:636 -D "uid=admin,dc='"${HOSTNAME_FQDN}"'" -y /run/secrets/ldap-admin-password -b "cn=ldap-admins,ou=Groups,dc='"${HOSTNAME_FQDN}"'" "(uniqueMember=uid=webadmin,ou=Internal,ou=Users,dc='"${HOSTNAME_FQDN}"')" dn | grep -q "^dn:"'; then
  docker exec openldap sh -c 'LDAPTLS_CACERT=/run/secrets/ldap/ca.crt ldapmodify -x -H ldaps://localhost:636 -D "uid=admin,dc='"${HOSTNAME_FQDN}"'" -y /run/secrets/ldap-admin-password -f /tmp/webadmin-group.ldif'
fi

rm -f /tmp/ldap-bootstrap.ldif /tmp/webadmin-add.ldif /tmp/webadmin-group.ldif
docker exec openldap rm -f /tmp/ldap-bootstrap.ldif /tmp/webadmin-add.ldif /tmp/webadmin-group.ldif

docker exec openldap sh -c 'LDAPTLS_CACERT=/run/secrets/ldap/ca.crt ldapwhoami -x -H ldaps://localhost:636 -D "uid=webadmin,ou=Internal,ou=Users,dc='"${HOSTNAME_FQDN}"'" -y /run/secrets/ldap-admin-password'

echo "[9/12] Creating the MQTT certificate and credentials..."
./prepare-mqtt.sh

echo "[10/12] Staging the certificate download portal..."
mkdir -p certs-portal/public/downloads/ca certs-portal/public/downloads/mqtt

docker cp step-ca:/home/step/certs/intermediate_ca.crt ./certs-portal/public/downloads/ca/intermediate_ca.crt
cp ./root_ca.crt ./certs-portal/public/downloads/ca/root_ca.crt
cat ./certs-portal/public/downloads/ca/intermediate_ca.crt ./certs-portal/public/downloads/ca/root_ca.crt \
  > ./certs-portal/public/downloads/ca/ca_chain.crt

docker run --rm -v "$PWD/certs-portal/public/downloads/ca:/work" smallstep/step-cli:latest \
  step certificate format /work/root_ca.crt --out /work/root_ca.der --force >/dev/null

cp ./mosquitto/certs/server.crt ./certs-portal/public/downloads/mqtt/mqtt_server.crt

INTERMEDIATE_FINGERPRINT=$(docker run --rm -v "$PWD/certs-portal/public/downloads/ca:/work:ro" smallstep/step-cli:latest \
  step certificate fingerprint /work/intermediate_ca.crt)
MQTT_FINGERPRINT=$(docker run --rm -v "$PWD/certs-portal/public/downloads/mqtt:/work:ro" smallstep/step-cli:latest \
  step certificate fingerprint /work/mqtt_server.crt)

mkdir -p certs-portal/public/downloads/scripts

python3 <<'PY_HOSTS_SCRIPTS'
import os
from pathlib import Path
values = {"HOSTNAME_FQDN": os.environ["HOSTNAME_FQDN"], "HOST_IP": os.environ["HOST_IP"]}
for template, out in (
    ("scripts/add-hosts-entries.ps1.template", "certs-portal/public/downloads/scripts/add-hosts-entries.ps1"),
    ("scripts/add-hosts-entries.sh.template", "certs-portal/public/downloads/scripts/add-hosts-entries.sh"),
):
    src = Path(template).read_text(encoding="utf-8")
    for name, value in values.items():
        src = src.replace("${" + name + "}", value)
    # Only check that OUR placeholders were resolved. The .sh template
    # legitimately keeps other ${VAR} bash syntax (e.g. ${HOSTS_FILE},
    # ${TMP_FILE}) that must remain untouched for the generated script to
    # work at runtime on the client machine.
    unresolved = [name for name in values if "${" + name + "}" in src]
    if unresolved:
        raise SystemExit(f"ERROR: unresolved variable(s) {unresolved} in {template}")
    Path(out).write_text(src, encoding="utf-8")
PY_HOSTS_SCRIPTS

chmod +x certs-portal/public/downloads/scripts/add-hosts-entries.sh

cat > certs-portal/public/downloads/certificate-manifest.txt <<EOF_MANIFEST
Certificate Download Portal manifest
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

root_ca.crt           SHA256:${FINGERPRINT}
intermediate_ca.crt   SHA256:${INTERMEDIATE_FINGERPRINT}
ca_chain.crt          intermediate_ca.crt + root_ca.crt (PEM concatenation)
root_ca.der           DER-encoded root_ca.crt
mqtt_server.crt       SHA256:${MQTT_FINGERPRINT}
scripts/add-hosts-entries.ps1   Windows hosts-file helper for ${HOSTNAME_FQDN} (run as Administrator)
scripts/add-hosts-entries.sh    Linux/macOS hosts-file helper for ${HOSTNAME_FQDN} (run with sudo)

Only public certificates are published here. No private keys, no jwk_key.json,
and no step-ca secrets are ever staged in this portal.
EOF_MANIFEST

cat > certs-portal/public/index.html <<EOF_HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Certificate Download Portal &middot; ${HOSTNAME_FQDN}</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f5f5f7;
    --surface: rgba(255, 255, 255, 0.72);
    --text: #1d1d1f;
    --text-secondary: #6e6e73;
    --accent: #0071e3;
    --accent-tint: rgba(0, 113, 227, 0.12);
    --accent-tint-hover: rgba(0, 113, 227, 0.06);
    --border: rgba(0, 0, 0, 0.08);
    --shadow: 0 1px 2px rgba(0, 0, 0, 0.04), 0 8px 24px rgba(0, 0, 0, 0.06);
    --code-bg: rgba(0, 0, 0, 0.05);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #000000;
      --surface: rgba(28, 28, 30, 0.72);
      --text: #f5f5f7;
      --text-secondary: #98989d;
      --accent: #0a84ff;
      --accent-tint: rgba(10, 132, 255, 0.16);
      --accent-tint-hover: rgba(10, 132, 255, 0.08);
      --border: rgba(255, 255, 255, 0.1);
      --shadow: 0 1px 2px rgba(0, 0, 0, 0.3), 0 8px 24px rgba(0, 0, 0, 0.4);
      --code-bg: rgba(255, 255, 255, 0.08);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    line-height: 1.47059;
  }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 64px 24px 96px; }
  header { text-align: center; margin-bottom: 56px; }
  header h1 {
    font-size: 40px;
    font-weight: 600;
    letter-spacing: -0.015em;
    margin: 0 0 12px;
  }
  header p {
    font-size: 19px;
    color: var(--text-secondary);
    margin: 0 auto;
    max-width: 560px;
  }
  .badge {
    display: inline-block;
    margin-top: 20px;
    padding: 6px 14px;
    font-size: 13px;
    font-weight: 590;
    color: var(--accent);
    background: var(--accent-tint);
    border-radius: 980px;
  }
  section { margin-bottom: 40px; }
  section h2 {
    font-size: 22px;
    font-weight: 600;
    margin: 0 0 16px;
    letter-spacing: -0.01em;
  }
  .card {
    background: var(--surface);
    backdrop-filter: saturate(180%) blur(20px);
    -webkit-backdrop-filter: saturate(180%) blur(20px);
    border: 1px solid var(--border);
    border-radius: 18px;
    box-shadow: var(--shadow);
    overflow: hidden;
  }
  .item {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 16px 20px;
    text-decoration: none;
    color: inherit;
    border-bottom: 1px solid var(--border);
    transition: background-color 0.15s ease;
  }
  .item:last-child { border-bottom: none; }
  .item:hover { background: var(--accent-tint-hover); }
  .icon {
    flex: 0 0 auto;
    width: 36px;
    height: 36px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 18px;
    background: var(--accent-tint);
  }
  .meta { flex: 1 1 auto; min-width: 0; }
  .meta .name { font-size: 16px; font-weight: 590; }
  .meta .desc { font-size: 13px; color: var(--text-secondary); margin-top: 2px; }
  .chevron { color: var(--text-secondary); font-size: 20px; }
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0 40px;
    align-items: start;
  }
  @media (max-width: 720px) {
    .grid { grid-template-columns: 1fr; }
  }
  footer {
    margin-top: 64px;
    text-align: center;
    font-size: 13px;
    color: var(--text-secondary);
  }
  code {
    background: var(--code-bg);
    padding: 2px 6px;
    border-radius: 6px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 0.92em;
  }
  .chip-note {
    font-size: 12px;
    color: var(--text-secondary);
    margin: 10px 4px 0;
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Certificate Download Portal</h1>
    <p>Public certificates and client setup helpers for <code>${HOSTNAME_FQDN}</code>. No private keys or CA secrets are ever published here.</p>
    <span class="badge">Read-only &middot; no secrets</span>
  </header>

  <div class="grid">
  <div>

  <section>
    <h2>Root &amp; Intermediate CA</h2>
    <div class="card">
      <a class="item" href="downloads/ca/root_ca.crt">
        <span class="icon">&#128220;</span>
        <span class="meta"><span class="name">Root CA certificate (PEM)</span><span class="desc">root_ca.crt &mdash; import into your OS or browser trust store</span></span>
        <span class="chevron">&#8964;</span>
      </a>
      <a class="item" href="downloads/ca/root_ca.der">
        <span class="icon">&#128220;</span>
        <span class="meta"><span class="name">Root CA certificate (DER)</span><span class="desc">root_ca.der &mdash; binary format</span></span>
        <span class="chevron">&#8964;</span>
      </a>
      <a class="item" href="downloads/ca/intermediate_ca.crt">
        <span class="icon">&#128220;</span>
        <span class="meta"><span class="name">Intermediate CA certificate (PEM)</span><span class="desc">intermediate_ca.crt</span></span>
        <span class="chevron">&#8964;</span>
      </a>
      <a class="item" href="downloads/ca/ca_chain.crt">
        <span class="icon">&#128279;</span>
        <span class="meta"><span class="name">CA chain</span><span class="desc">ca_chain.crt &mdash; intermediate + root, concatenated</span></span>
        <span class="chevron">&#8964;</span>
      </a>
    </div>
  </section>

  <section>
    <h2>MQTT</h2>
    <div class="card">
      <a class="item" href="downloads/mqtt/mqtt_server.crt">
        <span class="icon">&#128225;</span>
        <span class="meta"><span class="name">Mosquitto server certificate</span><span class="desc">mqtt_server.crt</span></span>
        <span class="chevron">&#8964;</span>
      </a>
    </div>
  </section>

  <section>
    <h2>Client Setup Helpers</h2>
    <div class="card">
      <a class="item" href="downloads/scripts/add-hosts-entries.ps1">
        <span class="icon">&#128187;</span>
        <span class="meta"><span class="name">Windows hosts-file script</span><span class="desc">add-hosts-entries.ps1 &mdash; run from an elevated PowerShell prompt</span></span>
        <span class="chevron">&#8964;</span>
      </a>
      <a class="item" href="downloads/scripts/add-hosts-entries.sh">
        <span class="icon">&#128421;</span>
        <span class="meta"><span class="name">Linux / macOS hosts-file script</span><span class="desc">add-hosts-entries.sh &mdash; run with sudo</span></span>
        <span class="chevron">&#8964;</span>
      </a>
    </div>
  </section>

  <section>
    <h2>Verification</h2>
    <div class="card">
      <a class="item" href="downloads/certificate-manifest.txt">
        <span class="icon">&#9989;</span>
        <span class="meta"><span class="name">Certificate manifest</span><span class="desc">SHA-256 fingerprints for everything above</span></span>
        <span class="chevron">&#8964;</span>
      </a>
    </div>
  </section>

  </div>
  <div>

  <section>
    <h2>Web Portals</h2>
    <div class="card">
      <a class="item" href="https://stepca.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128421;</span>
        <span class="meta"><span class="name">StepCA Web</span><span class="desc">stepca.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://portainer.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128230;</span>
        <span class="meta"><span class="name">Portainer</span><span class="desc">portainer.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://keycloak.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128273;</span>
        <span class="meta"><span class="name">Keycloak</span><span class="desc">keycloak.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://influxdb.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128200;</span>
        <span class="meta"><span class="name">InfluxDB UI</span><span class="desc">influxdb.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://ldapadmin.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128193;</span>
        <span class="meta"><span class="name">phpLDAPadmin</span><span class="desc">ldapadmin.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://cloudbeaver.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#129446;</span>
        <span class="meta"><span class="name">CloudBeaver</span><span class="desc">cloudbeaver.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
      <a class="item" href="https://mqtt.${HOSTNAME_FQDN}" target="_blank" rel="noopener noreferrer">
        <span class="icon">&#128172;</span>
        <span class="meta"><span class="name">MQTTX Web</span><span class="desc">mqtt.${HOSTNAME_FQDN}</span></span>
        <span class="chevron">&#8599;</span>
      </a>
    </div>
    <p class="chip-note">Links open in a new tab. Each site uses the same private CA, so import <code>root_ca.crt</code> first to avoid a browser warning.</p>
  </section>

  </div>
  </div>

  <footer>
    Step CA Demo Lab &middot; ${HOSTNAME_FQDN} &middot; generated automatically by install.sh
  </footer>
</div>
</body>
</html>
EOF_HTML

chmod -R a+rX certs-portal/public

echo "[11/12] Preparing stepca-web and starting the complete stack..."
if [[ ! -d stepca-web ]]; then
  [[ -n "${STEPCA_WEB_REPOSITORY:-}" ]] || { echo "ERROR: STEPCA_WEB_REPOSITORY is empty"; exit 1; }
  git clone "$STEPCA_WEB_REPOSITORY" stepca-web
fi
docker compose up -d --build

echo "[12/12] Validation..."
docker compose config -q
docker compose ps

printf '\nInstallation completed.\nRoot CA fingerprint: %s\nphpLDAPadmin DN: uid=webadmin,ou=Internal,ou=Users,dc=%s\nphpLDAPadmin password: LDAP_ADMIN_PASSWORD from .env\n' \
  "$FINGERPRINT" "$HOSTNAME_FQDN"

printf 'Portainer URL: https://portainer.%s (auto-provisioned; sign in with user "admin" and PORTAINER_ADMIN_PASSWORD from .env)\n' \
  "$HOSTNAME_FQDN"

printf '\nv1.1 services:\nPostgreSQL: %s:5432 (user stepca)\nMySQL: %s:3306 (database %s, user %s)\nSQL Server: %s:1433 (user sa)\nMosquitto MQTTS (TLS, authenticated): %s:8883 (user %s)\nMosquitto plain MQTT (no TLS, anonymous): %s:1883\nCloudBeaver: https://cloudbeaver.%s (complete the first-run admin setup)\nMQTTX Web: https://mqtt.%s\nMQTT WebSocket (WSS): wss://mqttws.%s\nCertificate Portal: http://%s\n' \
  "${POSTGRES_BIND_IP:-0.0.0.0}" "${MYSQL_BIND_IP:-0.0.0.0}" "$MYSQL_DATABASE" "$MYSQL_USER" \
  "${MSSQL_BIND_IP:-0.0.0.0}" "${MQTT_BIND_IP:-0.0.0.0}" "$MQTT_USERNAME" "${MQTT_BIND_IP:-0.0.0.0}" \
  "$HOSTNAME_FQDN" "$HOSTNAME_FQDN" "$HOSTNAME_FQDN" "$HOST_IP"
