"""Certificate format conversions for the signed-certificate download
options: DER (binary, single certificate - what tools like FactoryTalk
Optix's "PKI/Own/Certs" require, and what a plain file-rename from .pem to
.der does NOT produce, see docs/CSR_GENERATOR.md) and PKCS#12/.pfx (a single
password-protectable bundle containing the certificate, its private key,
and the issuing intermediate certificate - the format most Windows and
industrial-automation tools expect when they need the private key alongside
the certificate, not just the certificate alone).
"""

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12


def pem_cert_to_der(cert_pem):
    """Converts a single PEM certificate to DER bytes. DER can only ever
    hold one certificate (a single ASN.1 SEQUENCE) - unlike PEM, which can
    concatenate several - so this is only ever used on the leaf certificate,
    never a chain."""
    cert = x509.load_pem_x509_certificate(cert_pem.encode("utf-8"))
    return cert.public_bytes(serialization.Encoding.DER)


def build_pkcs12(common_name, private_key, leaf_cert_pem, chain_pem_list, passphrase):
    """Bundles the private key, the signed leaf certificate, and any
    intermediate certificates into a single PKCS#12 (.pfx) file, protected
    by passphrase (or unencrypted if passphrase is empty - matching this
    app's existing behavior for the standalone private key download)."""
    leaf_cert = x509.load_pem_x509_certificate(leaf_cert_pem.encode("utf-8"))
    chain_certs = [x509.load_pem_x509_certificate(pem.encode("utf-8")) for pem in chain_pem_list if pem]

    encryption = (
        serialization.BestAvailableEncryption(passphrase.encode("utf-8"))
        if passphrase
        else serialization.NoEncryption()
    )

    return pkcs12.serialize_key_and_certificates(
        name=common_name.encode("utf-8"),
        key=private_key,
        cert=leaf_cert,
        cas=chain_certs or None,
        encryption_algorithm=encryption,
    )
