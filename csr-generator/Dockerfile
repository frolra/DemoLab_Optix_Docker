FROM python:3.12-alpine

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

# Runs as a stateless HTTP service: it never writes to disk (no volume is
# mounted, and the app itself never opens a file for writing), so every
# generated key/CSR only ever exists in this process's memory for the
# lifetime of a single request.
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
