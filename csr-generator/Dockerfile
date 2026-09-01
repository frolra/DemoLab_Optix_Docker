FROM python:3.12-alpine

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py auth.py config.py stepca_client.py cert_formats.py .
COPY templates/ templates/

# Never writes to disk: settings.json and root_ca.crt are mounted read-only
# (CA/LDAP connection details and TLS trust, nothing secret), and the app
# itself never opens a file for writing. Every generated private key, signed
# certificate, and derived format (DER, PKCS#12) only ever exists in this
# process's memory for the lifetime of a single request.
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
