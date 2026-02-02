# syntax=docker/dockerfile:1

# ---------------------------
# Build stage
# ---------------------------
FROM rust:1.93-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    build-essential \
    git \
    ca-certificates \
    libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache dependencies first (copy manifest and source)
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY README.md ./README.md

# Build release binary
RUN cargo build --release

# ---------------------------
# Runtime stage
# ---------------------------
FROM debian:12-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
 && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -u 10002 -m -s /usr/sbin/nologin portero-agent

WORKDIR /opt/portero-agent

# Copy binary from builder
COPY --from=builder /app/target/release/portero-agent /usr/local/bin/portero-agent

# Environment defaults (overridable)
ENV PORTERO_AGENT_LOG=info
ENV PORTERO_REGISTER_URL=http://127.0.0.1:18080/register
ENV PORTERO_SERVICE_NAME=api.example.com
ENV PORTERO_IPV6=::1
ENV PORTERO_IFACE=
ENV PORTERO_PORT=443
ENV PORTERO_USE_TLS=true
ENV PORTERO_TTL_SECONDS=3600
ENV PORTERO_REGISTER_SECRET=changeme
ENV PORTERO_JWT_HMAC_KEY=changeme
ENV PORTERO_RENEWAL_FRACTION=0.7

# Expose no ports (agent is outbound-only); kept for visibility if needed
# EXPOSE <none>

# Run as non-root
USER portero-agent

# Entrypoint/command: use environment to configure the agent
# Note: if PORTERO_IFACE is set, the agent will attempt IPv6 autodiscovery and override PORTERO_IPV6.
CMD ["/usr/local/bin/portero-agent"]
