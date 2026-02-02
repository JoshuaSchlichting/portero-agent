use std::net::IpAddr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use env_logger;
use if_addrs::{get_if_addrs, IfAddr};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use log::{error, info};
use reqwest::Client;
use serde::Serialize;
use tokio::signal;
use tokio::time::sleep;

#[derive(Debug, Parser)]
#[command(
    name = "portero-agent",
    about = "Registers and renews a backend with Portero"
)]
struct Cli {
    #[arg(
        long,
        env = "PORTERO_REGISTER_URL",
        default_value = "http://127.0.0.1:18080/register"
    )]
    register_url: String,

    #[arg(long, env = "PORTERO_SERVICE_NAME")]
    service_name: String,

    #[arg(long, env = "PORTERO_IP", default_value = "::1")]
    ip: String,

    /// Optional network interface name to auto-discover IPv6 (overrides PORTERO_IP) (e.g., "eth0"). If provided, overrides PORTERO_IP.
    #[arg(long, env = "PORTERO_IFACE")]
    iface: Option<String>,

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
    env_logger::Builder::from_env(
        env_logger::Env::default().filter_or("PORTERO_AGENT_LOG", "info"),
    )
    .init();
    let cli = Cli::parse();

    // Resolve IP via optional interface autodiscovery; fallback to configured IPv6
    let selected_ip_str = if let Some(iface) = &cli.iface {
        // Try to find the first global/unicast IPv6 address on the specified interface
        match get_if_addrs() {
            Ok(addrs) => {
                let found = addrs
                    .into_iter()
                    .find(|ifa| ifa.name == *iface && matches!(ifa.addr, IfAddr::V6(_)));
                if let Some(ifa) = found {
                    if let IfAddr::V6(inet6) = ifa.addr {
                        inet6.ip.to_string()
                    } else {
                        cli.ip.clone()
                    }
                } else {
                    cli.ip.clone()
                }
            }
            Err(_) => cli.ip.clone(),
        }
    } else {
        cli.ip.clone()
    };

    // Validate IP address
    let ip: IpAddr = selected_ip_str
        .parse()
        .context("Selected IP must be a valid IP address")?;

    // HTTP client
    let client = Client::builder().build()?;

    // Renewal cadence
    let renew_secs = (cli.ttl_seconds as f32 * cli.renewal_fraction)
        .clamp(1.0, cli.ttl_seconds as f32 - 1.0) as u64;

    info!(
        "starting agent for {} at [{}]:{} use_tls={} ttl={}s renew={}s (iface={})",
        cli.service_name,
        ip,
        cli.port,
        cli.use_tls,
        cli.ttl_seconds,
        renew_secs,
        cli.iface.as_deref().unwrap_or("-")
    );

    // Run until SIGINT/SIGTERM
    tokio::select! {
        _ = renew_loop(&client, &cli, renew_secs, selected_ip_str.clone()) => {},
        _ = shutdown_signal() => {
            info!("shutdown signal received, exiting");
        }
    }

    Ok(())
}

async fn renew_loop(client: &Client, cli: &Cli, renew_secs: u64, selected_ip: String) {
    loop {
        if let Err(e) = register_once(client, cli, &selected_ip).await {
            error!("registration failed: {e:?}");
        }
        sleep(Duration::from_secs(renew_secs)).await;
    }
}

async fn register_once(client: &Client, cli: &Cli, selected_ip: &str) -> Result<()> {
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
        host: selected_ip,
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
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("register failed: {} - {}", status, text));
    }

    info!(
        "registered {} [{}]:{} use_tls={} ttl={}s",
        cli.service_name, cli.ip, cli.port, cli.use_tls, cli.ttl_seconds
    );
    Ok(())
}

async fn shutdown_signal() {
    let _ = signal::ctrl_c().await;
}
