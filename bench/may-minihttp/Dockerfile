FROM rust:1.87

RUN apt-get update -yqq && apt-get install -yqq cmake g++

WORKDIR /may
RUN cargo init --name may-minihttp

# Write Cargo.toml with dependencies
COPY Cargo.toml /may/Cargo.toml

# Write source
COPY main.rs /may/src/main.rs

# Build
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

EXPOSE 8080
CMD ["./target/release/may-minihttp"]
