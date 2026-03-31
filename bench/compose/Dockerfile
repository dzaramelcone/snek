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

# Export Python headers + lib for cross-compile sysroot
# After building, extract with:
#   docker compose run --rm bench tar czf - -C / usr/local/include/python3.14 usr/local/lib/libpython3.14.so | \
#     tar xzf - -C sysroot/linux-aarch64 --strip-components=2
# When cross-building the extension for this container on macOS, prefer:
#   zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
# Plain `aarch64-linux` can emit a `.so` with a `libc.so` dependency that
# will not load in this Debian userspace.
RUN mkdir -p /sysroot/include /sysroot/lib && \
    cp -r /usr/local/include/python3.14 /sysroot/include/ && \
    cp /usr/local/lib/libpython3.14.so /sysroot/lib/ 2>/dev/null || \
    cp /usr/local/lib/libpython3.so /sysroot/lib/ 2>/dev/null || true
