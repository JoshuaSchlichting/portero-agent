#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="/home/josh/repos/portero-agent"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

# Initialize Rust crate
cargo init --bin

# Update Cargo.toml
cat > Cargo.toml <<'EOF'
[package]
name = "portero-agent"
version = "0.1.0"
edition = "2021"
license = "Apache-2.0"
description = "Agent that registers a backend with Portero and renews periodically"

[dependencies]
tokio = { version = "1", features = ["macros", "rt-multi-thread", "signal", "time"] }
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.11", features = ["json", "rustls-tls"] }
jsonwebtoken = { version = "9", default-features = false, features = ["use_pem"] }
anyhow = "1"
log = "0.4"
env_logger = "0.10"
EOF

# Main source
cat > src/main.rs <<'EOF'
use std::net::Ipv6Addr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use env_logger;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use log::{error, info};
use reqwest::Client;
use serde::Serialize;
use tokio::signal;
use tokio::time::sleep;

#[derive(Debug, Parser)]
#[command(name = "portero-agent", about = "Registers and renews a backend with Portero")]
struct Cli {
    #[arg(long, env = "PORTERO_REGISTER_URL", default_value = "http://127.0.0.1:18080/register")]
    register_url: String,

    #[arg(long, env = "PORTERO_SERVICE_NAME")]
    service_name: String,

    #[arg(long, env = "PORTERO_IPV6", default_value = "::1")]
    ipv6: String,

    #[arg(long, env = "PORTERO_PORT")]
    port: u16,

    #[arg(long, env = "PORTERO_USE_TLS", default_value_t = true)]
    use_tls: bool,

    #[arg(long, env = "PORTERO_TTL_SECONDS", default_value_t = 3600)]
    ttl_seconds: u64,

    #[arg(long, env = "PORTERO_REGISTER_SECRET")]
    register_secret: String,

    #[arg(long, env = "PORTERO_JWT_HMAC_KEY")]
    jwt_hmac_key: String,

    /// Renew when this fraction of TTL has elapsed (0.5..0.9 recommended)
    #[arg(long, env = "PORTERO_RENEWAL_FRACTION", default_value_t = 0.7)]
    renewal_fraction: f32,
}

#[derive(Debug, Serialize)]
struct RegisterPayload<'a> {
    service_name: &'a str,
    host: &'a str,
    port: u16,
    ttl_seconds: u64,
    use_tls: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().filter_or("PORTERO_AGENT_LOG", "info"))
        .init();
    let cli = Cli::parse();

    // Validate IPv6
    let ipv6: Ipv6Addr = cli
        .ipv6
        .parse()
        .context("PORTERO_IPV6 must be a valid IPv6 address")?;

    // HTTP client
    let client = Client::builder().build()?;

    // Renewal cadence
    let renew_secs = (cli.ttl_seconds as f32 * cli.renewal_fraction)
        .clamp(1.0, cli.ttl_seconds as f32 - 1.0) as u64;

    info!(
        "starting agent for {} at [{}]:{} use_tls={} ttl={}s renew={}s",
        cli.service_name, ipv6, cli.port, cli.use_tls, cli.ttl_seconds, renew_secs
    );

    // Run until SIGINT/SIGTERM
    tokio::select! {
        _ = renew_loop(&client, &cli, renew_secs) => {},
        _ = shutdown_signal() => {
            info!("shutdown signal received, exiting");
        }
    }

    Ok(())
}

async fn renew_loop(client: &Client, cli: &Cli, renew_secs: u64) {
    loop {
        if let Err(e) = register_once(client, cli).await {
            error!("registration failed: {e:?}");
        }
        sleep(Duration::from_secs(renew_secs)).await;
    }
}

async fn register_once(client: &Client, cli: &Cli) -> Result<()> {
    // JWT exp: now + 10 minutes
    let exp = (SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + 600) as usize;
    let claims = serde_json::json!({
        "service_name": cli.service_name,
        "exp": exp
    });
    let token = encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(cli.jwt_hmac_key.as_bytes()),
    )?;

    let payload = RegisterPayload {
        service_name: &cli.service_name,
        host: &cli.ipv6,
        port: cli.port,
        ttl_seconds: cli.ttl_seconds,
        use_tls: cli.use_tls,
    };

    let resp = client
        .post(&cli.register_url)
        .header("Content-Type", "application/json")
        .header("X-Register-Secret", &cli.register_secret)
        .header("Authorization", format!("Bearer {}", token))
        .json(&payload)
        .send()
        .await?;

    if !resp.status().is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("register failed: {} - {}", resp.status(), text));
    }

    info!(
        "registered {} [{}]:{} use_tls={} ttl={}s",
        cli.service_name, cli.ipv6, cli.port, cli.use_tls, cli.ttl_seconds
    );
    Ok(())
}

async fn shutdown_signal() {
    let _ = signal::ctrl_c().await;
}
EOF

# README
cat > README.md <<'EOF'
# Portero Agent

A lightweight agent that registers a backend with Portero and periodically renews its registration.

## Configuration

Environment variables or CLI flags:
- PORTERO_REGISTER_URL (default: http://127.0.0.1:18080/register)
- PORTERO_SERVICE_NAME (e.g., api.example.com)
- PORTERO_IPV6 (default: ::1)
- PORTERO_PORT
- PORTERO_USE_TLS (default: true)
- PORTERO_TTL_SECONDS (default: 3600)
- PORTERO_REGISTER_SECRET
- PORTERO_JWT_HMAC_KEY
- PORTERO_RENEWAL_FRACTION (default: 0.7)

## Run

cargo run -- \
  --service-name api.example.com \
  --ipv6 ::1 \
  --port 443 \
  --use-tls true \
  --ttl-seconds 3600 \
  --register-secret changeme \
  --jwt-hmac-key changeme

## Notes

- The agent renews its registration before TTL expiry to keep the backend active in Portero’s registry.
- Use short-lived JWTs and secure storage for secrets.
EOF

# GitHub Actions CI
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'EOF'
name: CI
on:
  push:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-rust@v1
        with:
          rust-version: stable
      - run: cargo build --verbose
      - run: cargo test --verbose
EOF

echo "Initialized portero-agent at $AGENT_DIR"

