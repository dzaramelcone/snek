FROM python:3.12-slim

# System dependencies for benchmarking tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    libssl-dev \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install wrk.
RUN git clone --depth 1 https://github.com/wg/wrk.git /tmp/wrk \
    && cd /tmp/wrk && make -j$(nproc) && cp wrk /usr/local/bin/ \
    && rm -rf /tmp/wrk

# Install h2load (nghttp2).
RUN apt-get update && apt-get install -y --no-install-recommends nghttp2-client \
    && rm -rf /var/lib/apt/lists/*

# Python frameworks for comparison.
RUN pip install --no-cache-dir \
    uvicorn[standard] \
    fastapi \
    starlette \
    blacksheep \
    pydantic \
    httptools \
    uvloop

# Install snek (from local copy).
WORKDIR /bench
COPY . /bench/

# Default: run all benchmarks.
CMD ["bash", "run.sh"]
