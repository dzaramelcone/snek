FROM python:3.14-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# oha - Rust HTTP load generator (what granian uses)
RUN curl -sSfL https://github.com/hatoo/oha/releases/download/v1.14.0/oha-linux-arm64 \
    -o /usr/local/bin/oha && chmod +x /usr/local/bin/oha

RUN pip install --no-cache-dir granian uvloop

WORKDIR /bench
COPY app.py /bench/app.py
