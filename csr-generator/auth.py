"""LDAP authentication + group-membership gate.

Only members of the LDAP group configured as LDAP_REQUIRED_GROUP_DN (this
lab's `cn=ldap-admins,ou=Groups,dc=<HOSTNAME_FQDN>` - the same group
`install.sh` already creates and adds `webadmin` to, and the same group
StepCA Web's own settings.json points at) may use this portal at all: this
portal now signs certificates directly through step-ca's admin JWK
provisioner (see stepca_client.py), so reaching the generate form is
equivalent to being able to mint a certificate for any name - unlike the
previous, anonymous "build a CSR and paste it into StepCA Web" version, an
LDAP identity check is now a hard requirement, not an option.

Uses ldap3 (a pure-Python LDAP client, same library used by stepca-web's own
LDAP backend) to bind as the submitted user's own DN (proving they know
their password) and then, over that same authenticated connection, checks
the required group's `uniqueMember` attribute for that DN (the exact
attribute/value shape `install.sh` itself writes when bootstrapping
`webadmin` into the group - see the "Synchronizing RootDN and creating
webadmin" step).
"""

import re
import ssl

from ldap3 import BASE, SIMPLE, Connection, Server, Tls
from ldap3.utils.conv import escape_filter_chars

# Deliberately strict: this becomes part of an LDAP DN string built by
# straightforward interpolation below, so it must never be allowed to
# contain DN/filter metacharacters (",", "=", "+", etc.) that could let a
# submitted "username" escape the intended `uid=...` component. A real LDAP
# uid in this project is always created by install.sh itself (e.g.
# "webadmin") and never needs anything beyond this shape.
_USERNAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class LdapAuthError(Exception):
    """Raised for any authentication/authorization failure. The message is
    safe to log but intentionally generic when shown to the end user (never
    reveals whether the username exists, only bind vs. group-membership
    failed a single check)."""


def authenticate_admin(username, password, *, ldap_url, base_dn, required_group_dn, ca_cert_file):
    """Returns a small dict describing the authenticated admin on success,
    or raises LdapAuthError otherwise. Never returns a falsy-but-not-raised
    value, so callers can't accidentally treat a failure as success."""
    username = (username or "").strip()
    password = password or ""

    if not username or not password:
        raise LdapAuthError("Username and password are required.")
    if not _USERNAME_RE.match(username):
        raise LdapAuthError("Invalid username.")

    user_dn = f"uid={username},ou=Internal,ou=Users,{base_dn}"

    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=ca_cert_file)
    server = Server(ldap_url, use_ssl=True, tls=tls, connect_timeout=10, get_info=None)

    try:
        conn = Connection(
            server,
            user=user_dn,
            password=password,
            authentication=SIMPLE,
            auto_bind=True,
            receive_timeout=10,
        )
    except Exception as exc:
        raise LdapAuthError("Invalid credentials.") from exc

    try:
        if not conn.bound:
            raise LdapAuthError("Invalid credentials.")

        try:
            conn.search(
                search_base=required_group_dn,
                search_filter=f"(uniqueMember={escape_filter_chars(user_dn)})",
                search_scope=BASE,
                attributes=["cn"],
            )
        except LdapAuthError:
            raise
        except Exception as exc:
            # A malformed/misconfigured LDAP_REQUIRED_GROUP_DN, a transient
            # connection drop, etc. - never let a raw ldap3 exception surface
            # as an unhandled 500; a login failure should always be a clean,
            # generic message.
            raise LdapAuthError("Could not verify group membership.") from exc

        if not conn.entries:
            raise LdapAuthError("Your account is not a member of the required admin group.")
    finally:
        conn.unbind()

    return {"username": username, "dn": user_dn}
