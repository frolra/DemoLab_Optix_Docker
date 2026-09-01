"""Configuration for the CSR Generator, once it needed to talk to step-ca
and OpenLDAP.

Reuses the same settings.json this repository's install.sh already
generates for stepca-web (ca.url / ca.fingerprint / ca.admin_provisioner_name
and ldap.url / ldap.base_dn / ldap.ldap_required_group_dn) as the single
source of truth for CA/LDAP connection details, instead of duplicating
those values into a second set of .env variables. Secrets that never belong
in settings.json (STEPCA_PASSWORD, this app's own Flask SECRET_KEY) always
come from the environment instead - the same split stepca-web itself uses.
"""

import json
import os
from pathlib import Path

_SETTINGS_PATH = Path(os.environ.get("SETTINGS_JSON_PATH", "settings.json"))


def _load_settings():
    try:
        return json.loads(_SETTINGS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}


_settings = _load_settings()


def _setting(*path, default=None):
    node = _settings
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node


SECRET_KEY = os.environ["SECRET_KEY"]
STEPCA_PASSWORD = os.environ["STEPCA_PASSWORD"]

CA_URL = os.environ.get("CA_URL") or _setting("ca", "url")
CA_FINGERPRINT = os.environ.get("CA_FINGERPRINT") or _setting("ca", "fingerprint")
CA_ADMIN_PROVISIONER_NAME = os.environ.get("CA_ADMIN_PROVISIONER_NAME") or _setting("ca", "admin_provisioner_name")
CA_BUNDLE = os.environ.get("CA_BUNDLE", "/etc/ssl/certs/root_ca.crt")

LDAP_URL = os.environ.get("LDAP_URL") or _setting("ldap", "url")
LDAP_BASE_DN = os.environ.get("LDAP_BASE_DN") or _setting("ldap", "base_dn")
LDAP_REQUIRED_GROUP_DN = os.environ.get("LDAP_REQUIRED_GROUP_DN") or _setting("ldap", "ldap_required_group_dn")
