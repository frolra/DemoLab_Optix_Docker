"""CSR Generator: a self-service portal, restricted to LDAP administrators,
that builds a PKCS#10 Certificate Signing Request and matching private key
from form fields, signs it directly through this lab's own step-ca (using
the CA's admin JWK provisioner - see stepca_client.py), and offers the
result in several formats (PEM, DER, and a password-protectable PKCS#12
bundle).

Only members of the LDAP group configured as LDAP_REQUIRED_GROUP_DN (see
auth.py) can reach any route here: unlike the original, anonymous version of
this tool - which only ever built an unsigned CSR/key pair with zero
connection to the CA - this version can mint a real, trusted certificate for
any name on its own, so an authenticated, authorized admin session is a hard
requirement, not an option. See docs/CSR_GENERATOR.md and docs/SECURITY.md.

Nothing is persisted server-side: the private key, the signed certificate,
and every derived format (DER, PKCS#12) exist only in this process's memory
for the duration of a single request/response cycle - never written to
disk, never cached, never logged. Only the LDAP session cookie (just a
username, signed with SECRET_KEY) survives between requests.

Uses the `cryptography` library to build the CSR programmatically (rather
than shelling out to the `openssl` CLI) so that user-supplied fields (CN,
SANs, etc.) can never influence a command line - there is no command line
to influence.
"""

import base64
import ipaddress
import os
import re
from functools import wraps

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID
from flask import Flask, make_response, redirect, render_template, request, session, url_for

import cert_formats
import config
from auth import LdapAuthError, authenticate_admin
from stepca_client import SigningError, sign_csr

app = Flask(__name__)
app.secret_key = config.SECRET_KEY
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

HOSTNAME_FQDN = os.environ.get("HOSTNAME_FQDN", "")

CN_MAX_LEN = 64
FIELD_MAX_LEN = 128

# Same hostname-label shape used elsewhere in this project (install.sh's
# env_require_hostname), plus an optional leading "*." since wildcard SANs
# are common on TLS certificates.
_DNS_NAME_RE = re.compile(
    r"^(\*\.)?"
    r"([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*"
    r"[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"
)
_COUNTRY_RE = re.compile(r"^[A-Za-z]{2}$")

KEY_TYPES = {
    "rsa2048": ("RSA", 2048),
    "rsa4096": ("RSA", 4096),
    "ecp256": ("EC", ec.SECP256R1()),
    "ecp384": ("EC", ec.SECP384R1()),
}
KEY_TYPE_LABELS = {
    "rsa2048": "RSA 2048",
    "rsa4096": "RSA 4096",
    "ecp256": "ECDSA P-256",
    "ecp384": "ECDSA P-384",
}


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("username"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template("login.html", hostname=HOSTNAME_FQDN)

    username = request.form.get("username", "")
    password = request.form.get("password", "")
    try:
        user = authenticate_admin(
            username,
            password,
            ldap_url=config.LDAP_URL,
            base_dn=config.LDAP_BASE_DN,
            required_group_dn=config.LDAP_REQUIRED_GROUP_DN,
            ca_cert_file=config.CA_BUNDLE,
        )
    except LdapAuthError:
        # Deliberately generic: never reveal whether the failure was a bad
        # password vs. a real account that just isn't in the admin group.
        return render_template("login.html", hostname=HOSTNAME_FQDN, error="Invalid credentials."), 401

    session.clear()
    session["username"] = user["username"]
    next_path = request.args.get("next") or url_for("index")
    return redirect(next_path)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


def generate_private_key(key_type):
    kind, spec = KEY_TYPES[key_type]
    if kind == "RSA":
        return rsa.generate_private_key(public_exponent=65537, key_size=spec)
    return ec.generate_private_key(spec)


def signature_hash_for(key_type):
    # SHA-384 is the conventional pairing for P-384; SHA-256 is fine for
    # everything else, including P-256 and both RSA sizes.
    return hashes.SHA384() if key_type == "ecp384" else hashes.SHA256()


def sanitize_filename(name):
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._")
    return (safe or "request")[:80]


def parse_sans(types, values):
    sans = []
    errors = []
    for i, (san_type, raw_value) in enumerate(zip(types, values), start=1):
        value = (raw_value or "").strip()
        if not value:
            continue
        if san_type == "ip":
            try:
                sans.append(x509.IPAddress(ipaddress.ip_address(value)))
            except ValueError:
                errors.append(f"Subject Alternative Name #{i}: '{value}' is not a valid IP address.")
        else:
            if len(value) > 253 or not _DNS_NAME_RE.match(value):
                errors.append(f"Subject Alternative Name #{i}: '{value}' is not a valid DNS name.")
            else:
                sans.append(x509.DNSName(value))
    return sans, errors


def sans_as_strings(sans):
    """Flattens the SAN GeneralName objects into plain strings for step-ca's
    JWT "sans" claim, which - like the CSR itself - must list every SAN
    (DNS names AND IP addresses) or the CA rejects the request (see
    docs/TROUBLESHOOTING.md for the bug this exact mistake caused in
    stepca-web)."""
    return [s.value if isinstance(s, x509.DNSName) else str(s.value) for s in sans]


def build_name_attributes(fields):
    attrs = []
    if fields["country"]:
        attrs.append(x509.NameAttribute(NameOID.COUNTRY_NAME, fields["country"]))
    if fields["state"]:
        attrs.append(x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, fields["state"]))
    if fields["locality"]:
        attrs.append(x509.NameAttribute(NameOID.LOCALITY_NAME, fields["locality"]))
    if fields["organization"]:
        attrs.append(x509.NameAttribute(NameOID.ORGANIZATION_NAME, fields["organization"]))
    if fields["organizational_unit"]:
        attrs.append(x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, fields["organizational_unit"]))
    attrs.append(x509.NameAttribute(NameOID.COMMON_NAME, fields["common_name"]))
    return attrs


def validate_fields(form):
    fields = {
        "common_name": (form.get("common_name") or "").strip(),
        "organization": (form.get("organization") or "").strip(),
        "organizational_unit": (form.get("organizational_unit") or "").strip(),
        "country": (form.get("country") or "").strip().upper(),
        "state": (form.get("state") or "").strip(),
        "locality": (form.get("locality") or "").strip(),
        "key_type": form.get("key_type") or "rsa2048",
        "key_passphrase": form.get("key_passphrase") or "",
    }

    errors = []
    if not fields["common_name"]:
        errors.append("Common Name (CN) is required.")
    elif len(fields["common_name"]) > CN_MAX_LEN:
        errors.append(f"Common Name must be {CN_MAX_LEN} characters or fewer.")

    for label, key in (
        ("Organization", "organization"),
        ("Organizational Unit", "organizational_unit"),
        ("State/Province", "state"),
        ("Locality", "locality"),
    ):
        if len(fields[key]) > FIELD_MAX_LEN:
            errors.append(f"{label} must be {FIELD_MAX_LEN} characters or fewer.")

    if fields["country"] and not _COUNTRY_RE.match(fields["country"]):
        errors.append("Country must be a 2-letter code (e.g. IT, US).")

    if fields["key_type"] not in KEY_TYPES:
        errors.append("Invalid key type selected.")

    sans, san_errors = parse_sans(form.getlist("san_type[]"), form.getlist("san_value[]"))
    errors.extend(san_errors)

    return fields, sans, errors


@app.route("/")
@login_required
def index():
    return render_template("index.html", hostname=HOSTNAME_FQDN, key_types=KEY_TYPE_LABELS, username=session["username"])


@app.route("/generate", methods=["POST"])
@login_required
def generate():
    fields, sans, errors = validate_fields(request.form)

    if errors:
        return (
            render_template(
                "index.html",
                hostname=HOSTNAME_FQDN,
                key_types=KEY_TYPE_LABELS,
                username=session["username"],
                error=" ".join(errors),
                form=fields,
            ),
            400,
        )

    try:
        private_key = generate_private_key(fields["key_type"])
        builder = x509.CertificateSigningRequestBuilder().subject_name(x509.Name(build_name_attributes(fields)))
        if sans:
            builder = builder.add_extension(x509.SubjectAlternativeName(sans), critical=False)
        csr = builder.sign(private_key, signature_hash_for(fields["key_type"]))

        csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode("ascii")
        encryption = (
            serialization.BestAvailableEncryption(fields["key_passphrase"].encode("utf-8"))
            if fields["key_passphrase"]
            else serialization.NoEncryption()
        )
        key_pem = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=encryption,
        ).decode("ascii")
    except Exception as exc:  # noqa: BLE001 - surface as a normal form error, never a 500 with a stack trace
        return (
            render_template(
                "index.html",
                hostname=HOSTNAME_FQDN,
                key_types=KEY_TYPE_LABELS,
                username=session["username"],
                error=f"Could not generate the CSR: {exc}",
                form=fields,
            ),
            400,
        )

    result = {
        "csr_pem": csr_pem,
        "key_pem": key_pem,
        "filename": sanitize_filename(fields["common_name"]),
        "signed": None,
        "signing_error": None,
    }

    try:
        signed = sign_csr(
            csr_pem,
            fields["common_name"],
            sans_as_strings(sans),
            ca_url=config.CA_URL,
            ca_fingerprint=config.CA_FINGERPRINT,
            provisioner_name=config.CA_ADMIN_PROVISIONER_NAME,
            passphrase=config.STEPCA_PASSWORD,
            ca_bundle=config.CA_BUNDLE,
        )
        der_bytes = cert_formats.pem_cert_to_der(signed["leaf_pem"])
        pfx_bytes = cert_formats.build_pkcs12(
            fields["common_name"], private_key, signed["leaf_pem"], signed["chain_pem"], fields["key_passphrase"]
        )
        result["signed"] = {
            "cert_pem": signed["leaf_pem"],
            "cert_der_b64": base64.b64encode(der_bytes).decode("ascii"),
            "pfx_b64": base64.b64encode(pfx_bytes).decode("ascii"),
            "pfx_has_passphrase": bool(fields["key_passphrase"]),
        }
    except SigningError as exc:
        # The CSR and private key were still generated successfully; only
        # the automatic signing step failed. Surface the reason (this is an
        # authenticated admin session, so the CA's own error message is safe
        # and useful to show, unlike a public-facing form) and still let the
        # admin keep the CSR/key rather than losing them.
        result["signing_error"] = str(exc)

    response = make_response(
        render_template(
            "index.html", hostname=HOSTNAME_FQDN, key_types=KEY_TYPE_LABELS, username=session["username"], result=result
        )
    )
    # The response body contains a freshly generated private key; make sure
    # nothing between here and the browser keeps a copy of it.
    response.headers["Cache-Control"] = "no-store"
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
