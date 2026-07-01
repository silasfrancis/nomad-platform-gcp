FROM python:3.12-slim AS base

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt --break-system-packages || \
    pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

RUN useradd --create-home --uid 1000 agent && \
    chown -R agent:agent /app
USER agent

WORKDIR /app/src

# HTTP server: GET /health (liveness), GET /summary (on-demand cluster summary).
# Port is also configurable via HTTP_PORT env var — keep in sync with config.py default.
EXPOSE 8090

ENTRYPOINT ["python", "main.py"]
