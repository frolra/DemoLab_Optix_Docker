"""Direct dialogue with step-ca: fetch the admin JWK provisioner's public
key material, decrypt its private half with STEPCA_PASSWORD, build a
one-time signing token (the same "ott" mechanism step-ca's own `step` CLI
and StepCA Web both use), and submit a CSR to /1.0/sign.

This mirrors the exact flow already used (and already fixed for its own
bugs) in the separate `frolra/stepca-web` repository's `StepCAClient.sign`
and `CAToken` - see that project's app/libs/stepapi.py - but reimplemented
here directly rather than imported, since stepca-web is a distinct
container/codebase this project only pulls via `git clone` in install.sh.

Unlike stepca-web, this module never needs `templateData` to carry the
CSR's subject fields through: the admin JWK provisioner's x509 template
(configured by this repository's own install.sh) already reads the CSR's
real subject via `.Insecure.CR.Subject`, so nothing needs to be duplicated
into a side-channel template variable here.
"""

import json
import uuid
from datetime import datetime, timedelta, timezone

import jwt as pyjwt
import requests
from jwcrypto import jwa, jwe as jwcrypto_jwe, jwk as jwcrypto_jwk

jwa.default_max_pbkdf2_iterations = 10000000


class SigningError(Exception):
    """Raised for any failure to sign a CSR through step-ca. The message is
    safe to show to an already-authenticated admin user (it never contains
    the provisioner passphrase or key material)."""


def _fetch_provisioner(ca_url, provisioner_name, ca_bundle, timeout):
    try:
        resp = requests.get(f"{ca_url.rstrip('/')}/provisioners", verify=ca_bundle, timeout=timeout)
    except requests.RequestException as exc:
        raise SigningError(f"Could not reach the CA at {ca_url}: {exc}") from exc

    if not resp.ok:
        raise SigningError(f"The CA rejected the provisioner list request ({resp.status_code}).")

    try:
        provisioners = resp.json().get("provisioners", [])
    except ValueError as exc:
        raise SigningError("The CA returned an unexpected (non-JSON) response.") from exc

    for provisioner in provisioners:
        if provisioner.get("name") == provisioner_name:
            return provisioner

    raise SigningError(f"Provisioner '{provisioner_name}' was not found on the CA.")


def _decrypt_provisioner_key(provisioner, passphrase):
    encrypted_key = provisioner.get("encryptedKey")
    public_key = provisioner.get("key")
    if not encrypted_key or not public_key:
        raise SigningError("The CA's provisioner is missing its key material.")

    try:
        jwe_token = jwcrypto_jwe.JWE()
        jwe_token.deserialize(encrypted_key)
        jwe_token.decrypt(jwcrypto_jwk.JWK.from_password(passphrase))
        private_bits = json.loads(jwe_token.plaintext.decode("utf-8"))
    except Exception as exc:
        # jwcrypto raises a generic exception on a wrong password (there is
        # no dedicated "wrong password" type to catch), so this is the only
        # way to surface it - but STEPCA_PASSWORD is this container's own
        # internal secret (see docs/CSR_GENERATOR.md), never typed by the
        # end user, so in practice this only fires if STEPCA_PASSWORD in
        # .env doesn't match the one step-ca was actually initialized with.
        raise SigningError(
            "Could not decrypt the CA provisioner's key - STEPCA_PASSWORD does not match this CA."
        ) from exc

    full_jwk = dict(public_key)
    full_jwk["d"] = private_bits["d"]
    return full_jwk


def _build_signing_token(full_jwk, ca_url, ca_fingerprint, provisioner_name, common_name, sans):
    key = jwcrypto_jwk.JWK(**full_jwk)
    private_pem = key.export_to_pem(private_key=True, password=None)

    now = datetime.now(tz=timezone.utc)
    payload = {
        "aud": f"{ca_url.rstrip('/')}/1.0/sign",
        "sha": ca_fingerprint,
        "exp": now + timedelta(minutes=5),
        "iat": now,
        "nbf": now,
        "jti": str(uuid.uuid4()),
        "iss": provisioner_name,
        "sub": common_name,
    }
    if sans:
        payload["sans"] = sans

    return pyjwt.encode(payload, private_pem, algorithm="ES256", headers={"kid": full_jwk.get("kid")})


def _extract_error_message(resp):
    try:
        data = resp.json()
    except ValueError:
        return resp.text or f"HTTP {resp.status_code}"
    return data.get("message") or data.get("error") or resp.text or f"HTTP {resp.status_code}"


def sign_csr(
    csr_pem,
    common_name,
    sans,
    *,
    ca_url,
    ca_fingerprint,
    provisioner_name,
    passphrase,
    ca_bundle,
    timeout=20,
):
    """Signs csr_pem through step-ca's admin JWK provisioner and returns a
    dict with the leaf certificate (PEM) and any intermediate certificates
    in the chain (PEM strings, root excluded - matching how this project
    already distributes the root CA separately via the Certificate Portal).
    Raises SigningError with a human-readable reason on any failure."""
    provisioner = _fetch_provisioner(ca_url, provisioner_name, ca_bundle, timeout)
    full_jwk = _decrypt_provisioner_key(provisioner, passphrase)
    token = _build_signing_token(full_jwk, ca_url, ca_fingerprint, provisioner_name, common_name, sans)

    try:
        resp = requests.post(
            f"{ca_url.rstrip('/')}/1.0/sign",
            json={"csr": csr_pem, "ott": token},
            verify=ca_bundle,
            timeout=timeout,
        )
    except requests.RequestException as exc:
        raise SigningError(f"Could not reach the CA at {ca_url}: {exc}") from exc

    if resp.status_code != 201:
        raise SigningError(_extract_error_message(resp))

    try:
        data = resp.json()
    except ValueError as exc:
        raise SigningError("The CA returned an unexpected (non-JSON) response.") from exc

    cert_chain = data.get("certChain") or []
    # certChain[0] is the leaf itself (identical to data["crt"]); certChain[1],
    # when present, is the immediate issuing (intermediate) certificate -
    # confirmed by reading step-ca's own SoftCAS implementation (the default
    # CA engine this lab uses), where the signing response's certificate
    # chain is [leaf, *issuer_chain] and issuer_chain starts with the
    # intermediate. Any further entries (a root, if the CA includes one)
    # are deliberately dropped: this project already distributes the root
    # CA separately and independently (see the Certificate Portal), and a
    # server's own TLS chain should never need to bundle its own root.
    intermediate = [cert_chain[1]] if len(cert_chain) > 1 and cert_chain[1] else []

    return {
        "leaf_pem": data.get("crt", ""),
        "chain_pem": intermediate,
    }
