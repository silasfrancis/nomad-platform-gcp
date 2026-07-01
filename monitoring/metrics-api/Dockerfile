# Dockerfile for: metrics-api (Python / Flask)
# Custom platform-engineering demo service — see main.py docstring and the
# project README for the full rationale on why this service exists.

FROM python:3.12-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends wget && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --break-system-packages

COPY main.py .

EXPOSE 8080
ENTRYPOINT ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "main:app"]
