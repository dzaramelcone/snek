FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# Build tools, profiling, Go, Rust
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl git ca-certificates unzip \
    linux-perf valgrind strace \
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# Rust (minimal)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

RUN ln -sf /usr/bin/perf_* /usr/local/bin/perf 2>/dev/null || true

# wrk
RUN git clone --depth 1 https://github.com/wg/wrk.git /tmp/wrk \
    && cd /tmp/wrk && make -j$(nproc) && cp wrk /usr/local/bin/ \
    && rm -rf /tmp/wrk

# FlameGraph
RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph.git /opt/FlameGraph

# FastAPI control
RUN pip install --no-cache-dir fastapi 'uvicorn[standard]'

WORKDIR /snek

# Copy everything
COPY bench/ /snek/bench/
COPY python/ /snek/python/
COPY example/ /snek/example/
COPY pyproject.toml setup.py /snek/
COPY zig-out/lib/lib_snek.so /usr/local/lib/_snek.so

# Build Go control
RUN cd /snek/bench/controls/go && go build -o /usr/local/bin/bench-go .

# Build Rust control
RUN cd /snek/bench/controls/rust && cargo build --release \
    && cp target/release/snek-bench-rust /usr/local/bin/bench-rust

# Make _snek importable
RUN cp /usr/local/lib/_snek.so /snek/python/snek/_snek.so

# Install snek Python package
RUN pip install --no-cache-dir -e /snek/ 2>/dev/null || true

CMD ["bash"]
