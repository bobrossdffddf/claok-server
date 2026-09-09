# Two stages so the shipped image carries no toolchain.
FROM rust:1-bookworm AS build
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /var/lib/cloak --create-home cloak
COPY --from=build /build/target/release/cloak-server /usr/local/bin/cloak-server

ENV CLOAK_DB=/data/cloak.sqlite \
    CLOAK_KEY=/data/cloak-signing.key \
    CLOAK_DDI_DIR=/data/ddi \
    CLOAK_PORT=8787

VOLUME ["/data"]
EXPOSE 8787
USER cloak
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
    CMD curl -fsS http://127.0.0.1:8787/v1/health || exit 1
ENTRYPOINT ["/usr/local/bin/cloak-server"]
